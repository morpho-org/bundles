// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IZeroExLeverageBundlesV1} from "./interfaces/IZeroExLeverageBundlesV1.sol";
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
import {TokenLib} from "../libraries/TokenLib.sol";

/// @dev Leverage bundle for Morpho Blue that swaps through 0x AllowanceHolder and Settler, using Blue's callbacks instead of flash loans.
/// @dev Prototype: not audited.
/// @dev Inherits the token safety requirements of Morpho Blue (see Morpho.sol).
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
/// @dev swapData is the 0x AllowanceHolder quote's transaction.data, called unchanged on AllowanceHolder; neither the Settler nor its calldata is validated, so each swap is bounded only by the approval of the input cap and the balance-delta checks on input cap and output floor.
/// @dev The swap can make arbitrary calls, so entrypoints stay locked through Blue's callbacks.
contract ZeroExLeverageBundlesV1 is IZeroExLeverageBundlesV1, IMorphoSupplyCollateralCallback, IMorphoRepayCallback {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    address public immutable BLUE;
    address public immutable ALLOWANCE_HOLDER;

    bool internal transient locked;

    constructor(address _blue, address _allowanceHolder) {
        BLUE = _blue;
        ALLOWANCE_HOLDER = _allowanceHolder;
    }

    modifier nonReentrant() {
        require(!locked, Reentrancy());
        locked = true;
        _;
        locked = false;
    }

    /// ENTRYPOINT ///

    /// @dev Pulls collateralAssets from msg.sender and supplies collateralAssets + collateralToBuy for msg.sender; in Blue's callback, borrows maxBorrowAssets and buys collateralToBuy through 0x.
    /// @dev swapData must be a 0x BUY quote with buyAmount = collateralToBuy and maxSellAmount <= maxBorrowAssets.
    /// @dev The unspent borrowed assets are repaid, and the collateral bought above collateralToBuy is supplied for msg.sender.
    /// @dev The msg.sender must have authorized this contract on Blue.
    /// @dev maxLtv caps msg.sender's resulting LTV; type(uint256).max disables it.
    function zeroExLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(collateralToBuy != 0, ZeroCollateralToBuy());

        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + collateralToBuy,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1Open.selector,
                    msg.sender,
                    abi.encode(marketParams, collateralToBuy, maxBorrowAssets, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @dev Repays minRepayAssets of msg.sender's debt; in Blue's callback, withdraws collateralToSell and sells it through 0x for at least minRepayAssets.
    /// @dev swapData must be a 0x SELL quote with sellAmount = collateralToSell and minBuyAmount >= minRepayAssets.
    /// @dev minRepayAssets must not exceed msg.sender's debt, or else Blue reverts.
    /// @dev Unsold collateral is supplied back; the loan assets received above minRepayAssets repay the remaining debt, and the rest is sent to msg.sender.
    /// @dev The msg.sender must have authorized this contract on Blue.
    /// @dev maxLtv caps msg.sender's resulting LTV; type(uint256).max disables it.
    function zeroExLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 collateralToSell,
        uint256 minRepayAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                minRepayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1Delever.selector,
                    msg.sender,
                    abi.encode(marketParams, collateralToSell, minRepayAssets, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @dev Repays all of msg.sender's borrow shares; in Blue's callback, withdraws all collateral and buys the debt through 0x, spending at most maxCollateralIn.
    /// @dev swapData must be a 0x BUY quote with buyAmount = debt plus a buffer for the interest accrued until execution, and maxSellAmount <= maxCollateralIn.
    /// @dev The unspent collateral and the loan assets received above the debt are sent to msg.sender.
    /// @dev Without debt, withdraws all collateral to msg.sender and ignores swapData.
    /// @dev The msg.sender must have authorized this contract on Blue.
    function zeroExLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
            return;
        }

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1Close.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, maxCollateralIn, swapData)
                )
            );
    }

    /// @dev Repays all of msg.sender's borrow shares; in Blue's callback, withdraws all collateral and sells it through 0x for at least max(minLoanOut, debt).
    /// @dev swapData must be a 0x SELL quote with sellAmount = msg.sender's collateral.
    /// @dev The loan assets received above the debt, and any unsold collateral, are sent to msg.sender.
    /// @dev Without debt, withdraws all collateral to msg.sender and ignores swapData.
    /// @dev The msg.sender must have authorized this contract on Blue.
    function zeroExLeverageBundlesV1CloseExactIn(
        MarketParams memory marketParams,
        uint256 minLoanOut,
        bytes calldata swapData,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
            return;
        }

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1CloseExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, minLoanOut, swapData)
                )
            );
    }

    /// CALLBACKS ///

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.zeroExLeverageBundlesV1Open.selector) {
            executeOpen(user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.zeroExLeverageBundlesV1Delever.selector) {
            executeDelever(assets, user, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1Close.selector) {
            executeClose(assets, user, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1CloseExactIn.selector) {
            executeCloseExactIn(assets, user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    /// INTERNAL ///

    function executeOpen(address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateralToBuy, uint256 maxBorrowAssets, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).borrow(marketParams, maxBorrowAssets, 0, user, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.loanToken, marketParams.collateralToken, maxBorrowAssets, collateralToBuy, swapData);

        if (maxBorrowAssets > spent) {
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            IMorpho(BLUE).repay(marketParams, maxBorrowAssets - spent, 0, user, "");
        }
        if (received > collateralToBuy) {
            IMorpho(BLUE).supplyCollateral(marketParams, received - collateralToBuy, user, "");
        }
    }

    function executeDelever(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateralToSell, uint256 minRepayAssets, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateralToSell, user, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.collateralToken, marketParams.loanToken, collateralToSell, minRepayAssets, swapData);

        if (collateralToSell > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, collateralToSell - spent, user, "");
        }
        repaySurplus(marketParams, user, assets, received);
    }

    function repaySurplus(MarketParams memory marketParams, address user, uint256 assets, uint256 received) internal {
        if (received > assets) {
            uint256 excess = received - assets;
            uint256 borrowShares = IMorpho(BLUE).position(marketParams.id(), user).borrowShares;
            Market memory market = IMorpho(BLUE).market(marketParams.id());
            uint256 debt = borrowShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

            if (excess >= debt) {
                if (borrowShares > 0) IMorpho(BLUE).repay(marketParams, 0, borrowShares, user, "");
                excess -= debt;
            } else {
                IMorpho(BLUE).repay(marketParams, excess, 0, user, "");
                excess = 0;
            }

            if (excess > 0) SafeTransferLib.safeTransfer(marketParams.loanToken, user, excess);
        }
    }

    function executeClose(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateral, uint256 maxCollateralIn, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, swapData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function executeCloseExactIn(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateral, uint256 minLoanOut, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        uint256 minOut = minLoanOut > assets ? minLoanOut : assets;
        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.collateralToken, marketParams.loanToken, collateral, minOut, swapData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; type(uint256).max disables the check.
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

    /// @dev Approves AllowanceHolder for maxIn only; the quote's exec amount is not read.
    function swap(address tokenIn, address tokenOut, uint256 maxIn, uint256 minOut, bytes memory swapData)
        internal
        returns (uint256 spent, uint256 received)
    {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TokenLib.safeApprove(tokenIn, ALLOWANCE_HOLDER, maxIn);
        (bool success, bytes memory returnData) = ALLOWANCE_HOLDER.call(swapData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        TokenLib.safeApprove(tokenIn, ALLOWANCE_HOLDER, 0);

        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        require(inAfter <= inBefore, IncompleteFill());
        spent = inBefore - inAfter;
        require(spent <= maxIn, IncompleteFill());

        uint256 outAfter = IERC20(tokenOut).balanceOf(address(this));
        require(outAfter >= outBefore, IncompleteFill());
        received = outAfter - outBefore;
        require(received >= minOut, IncompleteFill());
    }
}
