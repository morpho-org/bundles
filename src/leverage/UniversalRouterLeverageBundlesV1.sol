// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IUniversalRouterLeverageBundlesV1} from "./interfaces/IUniversalRouterLeverageBundlesV1.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {BlueLeverageBase} from "./BlueLeverageBase.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {TokenLib} from "../libraries/TokenLib.sol";

contract UniversalRouterLeverageBundlesV1 is
    IUniversalRouterLeverageBundlesV1,
    BlueLeverageBase,
    IMorphoFlashLoanCallback
{
    using UtilsLib for uint256;

    address public immutable UNIVERSAL_ROUTER;

    constructor(address blue, address universalRouter) BlueLeverageBase(blue) {
        UNIVERSAL_ROUTER = universalRouter;
    }

    /// ENTRYPOINTS ///

    /// @dev Supplies caller collateral plus an exact-output route, then borrows enough to repay the flash loan.
    function universalRouterLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(leverage > 1e18, InvalidLeverage());

        uint256 collateralToBuy = collateralAssets.mulDivDown(leverage - 1e18, 1e18);
        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);

        bytes memory operationData =
            abi.encode(marketParams, collateralAssets, collateralToBuy, commands, inputs, deadline);
        IMorpho(BLUE)
            .flashLoan(
                marketParams.loanToken,
                maxBorrowAssets,
                abi.encode(msg.sender, this.universalRouterLeverageBundlesV1Open.selector, operationData)
            );
    }

    /// @dev Routes a collateral flash loan into loan tokens, repays debt, and withdraws the spent collateral.
    function universalRouterLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        bytes memory operationData = abi.encode(marketParams, repayAssets, commands, inputs, deadline);
        IMorpho(BLUE)
            .flashLoan(
                marketParams.collateralToken,
                maxCollateralIn,
                abi.encode(msg.sender, this.universalRouterLeverageBundlesV1Delever.selector, operationData)
            );
    }

    /// @dev Routes a collateral flash loan into enough loan tokens to repay all borrow shares.
    function universalRouterLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        (uint256 borrowShares, uint256 debtAssets, uint256 collateral) = readFullCloseTarget(marketParams);
        if (borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, collateral, msg.sender, msg.sender);
            return;
        }

        bytes memory operationData =
            abi.encode(marketParams, borrowShares, debtAssets, collateral, commands, inputs, deadline);
        IMorpho(BLUE)
            .flashLoan(
                marketParams.collateralToken,
                maxCollateralIn,
                abi.encode(msg.sender, this.universalRouterLeverageBundlesV1Close.selector, operationData)
            );
    }

    /// CALLBACKS ///

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (address user, bytes4 selector, bytes memory operationData) = abi.decode(data, (address, bytes4, bytes));

        if (selector == this.universalRouterLeverageBundlesV1Open.selector) {
            _openCallback(assets, user, operationData);
        } else if (selector == this.universalRouterLeverageBundlesV1Delever.selector) {
            _deleverCallback(assets, user, operationData);
        } else if (selector == this.universalRouterLeverageBundlesV1Close.selector) {
            _closeCallback(assets, user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    /// INTERNALS ///

    function _openCallback(uint256 maxBorrowAssets, address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 collateralAssets,
            uint256 collateralToBuy,
            bytes memory commands,
            bytes[] memory inputs,
            uint256 deadline
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, bytes, bytes[], uint256));

        (uint256 spent, uint256 received) = swapExactOut(
            marketParams.loanToken,
            marketParams.collateralToken,
            maxBorrowAssets,
            collateralToBuy,
            commands,
            inputs,
            deadline
        );

        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(marketParams, collateralAssets + received, user, "");
        IMorpho(BLUE).borrow(marketParams, spent, 0, user, address(this));
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
    }

    function _deleverCallback(uint256 maxCollateralIn, address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 repayAssets,
            bytes memory commands,
            bytes[] memory inputs,
            uint256 deadline
        ) = abi.decode(operationData, (MarketParams, uint256, bytes, bytes[], uint256));

        (uint256 spent, uint256 received) = swapExactOut(
            marketParams.collateralToken,
            marketParams.loanToken,
            maxCollateralIn,
            repayAssets,
            commands,
            inputs,
            deadline
        );

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        IMorpho(BLUE).repay(marketParams, repayAssets, 0, user, "");
        IMorpho(BLUE).withdrawCollateral(marketParams, spent, user, address(this));
        if (received > repayAssets) SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - repayAssets);

        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
    }

    function _closeCallback(uint256 maxCollateralIn, address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 borrowShares,
            uint256 debtAssets,
            uint256 collateral,
            bytes memory commands,
            bytes[] memory inputs,
            uint256 deadline
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, uint256, bytes, bytes[], uint256));

        (uint256 spent, uint256 received) = swapExactOut(
            marketParams.collateralToken,
            marketParams.loanToken,
            maxCollateralIn,
            debtAssets,
            commands,
            inputs,
            deadline
        );

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        IMorpho(BLUE).repay(marketParams, 0, borrowShares, user, "");
        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > debtAssets) SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - debtAssets);

        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
    }

    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 maxIn,
        uint256 amountOut,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline
    ) internal returns (uint256 spent, uint256 received) {
        uint256 outputBalanceBefore = IERC20(tokenOut).balanceOf(address(this));

        SafeTransferLib.safeTransfer(tokenIn, UNIVERSAL_ROUTER, maxIn);
        uint256 inputBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, deadline);

        uint256 inputBalanceAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 outputBalanceAfter = IERC20(tokenOut).balanceOf(address(this));
        require(inputBalanceAfter >= inputBalanceBefore, IncompleteFill());
        uint256 unspent = inputBalanceAfter - inputBalanceBefore;
        require(unspent <= maxIn, IncompleteFill());
        spent = maxIn - unspent;
        received = outputBalanceAfter - outputBalanceBefore;
        require(received >= amountOut, IncompleteFill());
    }
}
