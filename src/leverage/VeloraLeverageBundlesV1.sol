// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVeloraLeverageBundlesV1} from "./interfaces/IVeloraLeverageBundlesV1.sol";
import {IMorpho, MarketParams, Position} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoRepayCallback,
    IMorphoSupplyCollateralCallback
} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {TokenLib} from "../libraries/TokenLib.sol";

/// @notice Executes exact-output swaps using Augustus v6.2 calldata whose beneficiary is this bundle.
contract VeloraLeverageBundlesV1 is IVeloraLeverageBundlesV1, IMorphoSupplyCollateralCallback, IMorphoRepayCallback {
    using MarketParamsLib for MarketParams;
    using UtilsLib for uint256;

    address public immutable override BLUE;
    address public immutable override AUGUSTUS;

    constructor(address blue, address augustus) {
        BLUE = blue;
        AUGUSTUS = augustus;
    }

    /// @notice Opens a leveraged position by supplying caller collateral and swapping borrowed assets.
    /// @param swapData Augustus v6.2 calldata with `beneficiary` set to this bundle and an exact-output target at least the collateral required by the operation.
    function veloraLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 deadline
    ) external override {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(leverage > 1e18, InvalidLeverage());

        uint256 collateralToBuy = collateralAssets.mulDivDown(leverage - 1e18, 1e18);
        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + collateralToBuy,
                msg.sender,
                abi.encode(msg.sender, marketParams, collateralToBuy, maxBorrowAssets, swapData)
            );
    }

    /// @notice Repays part of the caller's debt by withdrawing and swapping collateral.
    /// @param swapData Augustus v6.2 calldata with `beneficiary` set to this bundle and an exact-output target at least `repayAssets`.
    function veloraLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external override {
        require(block.timestamp <= deadline, DeadlinePassed());
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        IMorpho(BLUE)
            .repay(
                marketParams,
                repayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Delever.selector,
                    msg.sender,
                    abi.encode(marketParams, maxCollateralIn, swapData)
                )
            );
    }

    /// @notice Repays all borrow shares and returns the remaining collateral.
    /// @param swapData Augustus v6.2 calldata with `beneficiary` set to this bundle and an exact-output target at least the debt computed by Morpho.
    function veloraLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external override {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
            return;
        }

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Close.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, maxCollateralIn, swapData)
                )
            );
    }

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external override {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (
            address user,
            MarketParams memory marketParams,
            uint256 collateralToBuy,
            uint256 maxBorrowAssets,
            bytes memory swapData
        ) = abi.decode(data, (address, MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).borrow(marketParams, maxBorrowAssets, 0, user, address(this));
        (uint256 spent, uint256 received) = _swapExactOut(
            marketParams.loanToken, marketParams.collateralToken, maxBorrowAssets, collateralToBuy, swapData
        );

        if (maxBorrowAssets > spent) {
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            IMorpho(BLUE).repay(marketParams, maxBorrowAssets - spent, 0, user, "");
        }
        if (received > collateralToBuy) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, received - collateralToBuy);
        }
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external override {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.veloraLeverageBundlesV1Delever.selector) {
            _deleverCallback(assets, user, operationData);
        } else if (selector == this.veloraLeverageBundlesV1Close.selector) {
            _closeCallback(assets, user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function _deleverCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 maxCollateralIn, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, maxCollateralIn, user, address(this));
        (uint256 spent, uint256 received) =
            _swapExactOut(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, swapData);

        if (maxCollateralIn > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, maxCollateralIn - spent, user, "");
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function _closeCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateral, uint256 maxCollateralIn, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            _swapExactOut(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, swapData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 maxIn, uint256 amountOut, bytes memory data)
        internal
        returns (uint256 spent, uint256 received)
    {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TokenLib.safeApprove(tokenIn, AUGUSTUS, maxIn);
        (bool success, bytes memory returnData) = AUGUSTUS.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        TokenLib.safeApprove(tokenIn, AUGUSTUS, 0);

        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        require(inAfter <= inBefore, IncompleteFill());
        spent = inBefore - inAfter;
        require(spent <= maxIn, IncompleteFill());

        uint256 outAfter = IERC20(tokenOut).balanceOf(address(this));
        require(outAfter >= outBefore, IncompleteFill());
        received = outAfter - outBefore;
        require(received >= amountOut, IncompleteFill());
    }
}
