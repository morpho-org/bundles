// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IAugustusRegistry} from "./interfaces/IAugustusRegistry.sol";
import {IAugustusV6} from "./interfaces/IAugustusV6.sol";
import {IVeloraLeverageBundlesV1} from "./interfaces/IVeloraLeverageBundlesV1.sol";
import {IMorpho, MarketParams, Position, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoRepayCallback,
    IMorphoSupplyCollateralCallback
} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {Math} from "../../lib/vault-v2/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BytesLib} from "../libraries/BytesLib.sol";
import {TokenLib} from "../libraries/TokenLib.sol";

/// @notice Executes exact-output swaps using an Augustus v6.2 contract listed in Paraswap's Augustus registry.
contract VeloraLeverageBundlesV1 is IVeloraLeverageBundlesV1, IMorphoSupplyCollateralCallback, IMorphoRepayCallback {
    using MarketParamsLib for MarketParams;
    using BytesLib for bytes;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;

    address public immutable override BLUE;
    address public immutable override AUGUSTUS_REGISTRY;

    /// @dev Blocks re-entry from the swap executor into the entrypoints.
    bool internal transient locked;

    constructor(address blue, address augustusRegistry) {
        BLUE = blue;
        AUGUSTUS_REGISTRY = augustusRegistry;
    }

    modifier nonReentrant() {
        _lock();
        _;
        _unlock();
    }

    function _lock() internal {
        require(!locked, Reentrancy());
        locked = true;
    }

    function _unlock() internal {
        locked = false;
    }

    /// @notice Adds caller collateral and purchased collateral to the caller's position using borrowed assets.
    /// @param collateralAssets Collateral-token amount to pull from the caller, in token base units.
    /// @param collateralToBuy Nonzero additional collateral-token amount to acquire and supply, in token base units.
    /// @param maxBorrowAssets Maximum loan-token amount to borrow for the swap; unused assets are repaid.
    /// @param augustus Address of the Augustus contract. Must be in Paraswap's Augustus registry.
    /// @param swapData Calldata for the Augustus v6.2 contract selected by `augustus`, with `beneficiary` set to this bundle and an exact-output target at least `collateralToBuy`.
    /// @param maxLtv Maximum resulting LTV of the caller's position, in WAD; type(uint256).max disables the check.
    function veloraLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        address augustus,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(collateralToBuy != 0, ZeroCollateralToBuy());

        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + collateralToBuy,
                msg.sender,
                abi.encode(msg.sender, marketParams, collateralToBuy, maxBorrowAssets, augustus, swapData)
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays part of the caller's debt by withdrawing and swapping collateral.
    /// @param augustus Address of the Augustus contract. Must be in Paraswap's Augustus registry.
    /// @param swapData Augustus v6.2 calldata with `beneficiary` set to this bundle and an exact-output target at least `repayAssets`.
    /// @param maxLtv Maximum resulting LTV of the caller's position, in WAD; type(uint256).max disables the check.
    function veloraLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        address augustus,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                repayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Delever.selector,
                    msg.sender,
                    abi.encode(marketParams, maxCollateralIn, augustus, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays all borrow shares and returns the remaining collateral.
    /// @param maxCollateralIn Absolute collateral spending cap, including after resizing the swap.
    /// @param augustus Address of the Augustus contract. Must be in Paraswap's Augustus registry.
    /// @param swapData Augustus v6.2 exact-output calldata with `beneficiary` set to this bundle; amount offsets are derived from its selector.
    /// @dev Resizes output to Morpho's callback debt plus one base unit for Augustus's payout rounding.
    /// Maximum and quoted input amounts are scaled proportionally, rounding down; maximum input is capped at `maxCollateralIn`.
    function veloraLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        address augustus,
        bytes calldata swapData,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
            return;
        }

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Close.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, maxCollateralIn, augustus, swapData)
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
            address augustus,
            bytes memory swapData
        ) = abi.decode(data, (address, MarketParams, uint256, uint256, address, bytes));

        IMorpho(BLUE).borrow(marketParams, maxBorrowAssets, 0, user, address(this));
        (uint256 spent, uint256 received) = _swapExactOut(
            marketParams.loanToken, marketParams.collateralToken, maxBorrowAssets, collateralToBuy, augustus, swapData
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
        (MarketParams memory marketParams, uint256 maxCollateralIn, address augustus, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, address, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, maxCollateralIn, user, address(this));
        (uint256 spent, uint256 received) = _swapExactOut(
            marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, augustus, swapData
        );

        if (maxCollateralIn > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, maxCollateralIn - spent, user, "");
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function _closeCallback(uint256 assets, address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 collateral,
            uint256 maxCollateralIn,
            address augustus,
            bytes memory swapData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, address, bytes));

        _resizeSwapData(swapData, assets + 1, maxCollateralIn);

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) = _swapExactOut(
            marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, augustus, swapData
        );

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    /// @dev Updates only the selector-defined amount words; route data must support resizing these amounts.
    function _resizeSwapData(bytes memory data, uint256 amountOut, uint256 maxIn) internal pure {
        (uint256 exactAmount, uint256 limitAmount, uint256 quotedAmount) = _amountOffsets(data);

        uint256 oldAmountOut = data.get(exactAmount);
        require(oldAmountOut != 0, ZeroSwapAmount());

        uint256 newLimitAmount = Math.min(Math.mulDiv(data.get(limitAmount), amountOut, oldAmountOut), maxIn);
        uint256 newQuotedAmount = Math.mulDiv(data.get(quotedAmount), amountOut, oldAmountOut);
        data.set(quotedAmount, newQuotedAmount);
        data.set(limitAmount, newLimitAmount);
        data.set(exactAmount, amountOut);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        require(data.length >= 4, InvalidSelector());
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }

    function _amountOffsets(bytes memory data)
        internal
        pure
        returns (uint256 exactAmount, uint256 limitAmount, uint256 quotedAmount)
    {
        bytes4 selector = _selector(data);

        if (selector == IAugustusV6.swapExactAmountOut.selector) return (132, 100, 164);
        if (
            selector == IAugustusV6.swapExactAmountOutOnUniswapV2.selector
                || selector == IAugustusV6.swapExactAmountOutOnUniswapV3.selector
        ) return (196, 164, 228);
        revert InvalidSelector();
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; type(uint256).max disables the check (and notably skips the oracle call).
    /// @dev Accrues market interest when needed, then mirrors Blue's own health check against maxLtv.
    function requireMaxLtv(MarketParams memory marketParams, address sender, uint256 maxLtv) internal {
        if (maxLtv != type(uint256).max) {
            Position memory position = IMorpho(BLUE).position(marketParams.id(), sender);
            if (position.borrowShares != 0) {
                Market memory market = IMorpho(BLUE).market(marketParams.id());
                if (market.lastUpdate != block.timestamp) {
                    // forge-lint: disable-next-line(reentrancy-no-eth) The helper is only called from locked entrypoints.
                    IMorpho(BLUE).accrueInterest(marketParams);
                    market = IMorpho(BLUE).market(marketParams.id());
                }
                uint256 borrowed =
                    uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
                uint256 price = IOracle(marketParams.oracle).price();
                uint256 maxBorrow =
                    uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
                require(borrowed <= maxBorrow, LtvExceeded());
            }
        }
    }

    /// @dev Only generic, Uniswap V2 and Uniswap V3 exact-output methods are accepted.
    function _swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 maxIn,
        uint256 amountOut,
        address augustus,
        bytes memory data
    ) internal returns (uint256 spent, uint256 received) {
        require(IAugustusRegistry(AUGUSTUS_REGISTRY).isValidAugustus(augustus), InvalidAugustus());
        _amountOffsets(data);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TokenLib.safeApprove(tokenIn, augustus, maxIn);
        (bool success, bytes memory returnData) = augustus.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        TokenLib.safeApprove(tokenIn, augustus, 0);

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
