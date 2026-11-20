// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {
    IZeroExLeverageBundlesV1,
    PublicAllocations,
    IBluePublicAllocator
} from "./interfaces/IZeroExLeverageBundlesV1.sol";
import {IMorpho, MarketParams, Position, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoFlashLoanCallback,
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

/// @dev Leverage bundle for Morpho Blue that swaps through 0x AllowanceHolder and Settler, using Blue's callbacks instead of flash loans (a flash loan is only taken for the public allocator's penalties that loanAssets doesn't cover, and for the part of maxBorrowAssets that cannot be borrowed while staying healthy).
/// @dev Inherits the token safety requirements of Morpho Blue (see Morpho.sol).
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
/// @dev swapData is the 0x AllowanceHolder quote's transaction.data, called unchanged on AllowanceHolder; neither the Settler nor its calldata is validated, so each swap is bounded only by the input cap and the output floor.
/// @dev Because the swap can make arbitrary calls, all entrypoints remain locked throughout the call to this contract.
contract ZeroExLeverageBundlesV1 is
    IZeroExLeverageBundlesV1,
    IMorphoSupplyCollateralCallback,
    IMorphoRepayCallback,
    IMorphoFlashLoanCallback
{
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    address public immutable BLUE;
    address public immutable ALLOWANCE_HOLDER;
    address public immutable PUBLIC_ALLOCATOR;

    bool internal transient locked;

    constructor(address _blue, address _allowanceHolder, address _publicAllocator) {
        BLUE = _blue;
        ALLOWANCE_HOLDER = _allowanceHolder;
        PUBLIC_ALLOCATOR = _publicAllocator;
    }

    modifier nonReentrant() {
        require(!locked, Reentrancy());
        locked = true;
        _;
        locked = false;
    }

    /// ENTRYPOINT ///

    /// @dev Pulls collateralAssets and loanAssets from msg.sender, executes the public reallocations and supplies collateralAssets + collateralToBuy for msg.sender; in Blue's callback, borrows at most maxBorrowAssets and buys collateralToBuy through 0x.
    /// @dev The aggregate penalty P of the reallocations is paid to the public allocator upfront from loanAssets, with P - loanAssets flash loaned if P > loanAssets and repaid from maxBorrowAssets; at most loanAssets + maxBorrowAssets - P is swapped.
    /// @dev All public reallocations execute unconditionally.
    /// @dev swapData is expected to be a 0x BUY quote with buyAmount = collateralToBuy and maxSellAmount = loanAssets + maxBorrowAssets - P.
    /// @dev The surplus of loan assets repays msg.sender's debt and the rest is sent to msg.sender; the collateral bought above collateralToBuy is supplied for msg.sender.
    /// @dev If the swap would spend more than loanAssets + maxBorrowAssets - P or buys less than collateralToBuy, the call reverts.
    /// @dev The assets borrowed are maxBorrowAssets, capped at the most that keeps msg.sender healthy at the oracle price; what is not borrowed is flash loaned, such that loanAssets + maxBorrowAssets - P is still available to the swap.
    /// @dev If the borrow is capped, the call reverts if the swap spends more than loanAssets + the borrowed assets - P.
    /// @dev The msg.sender must have authorized this contract on Blue, and approved it for collateralAssets and loanAssets.
    /// @dev maxLtv caps msg.sender's resulting LTV; type(uint256).max disables it.
    function zeroExLeverageBundlesV1Lever(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 loanAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        PublicAllocations[] calldata reallocations,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(collateralToBuy != 0, ZeroCollateralToBuy());

        if (collateralAssets > 0) {
            SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        }
        if (loanAssets > 0) {
            SafeTransferLib.safeTransferFrom(marketParams.loanToken, msg.sender, address(this), loanAssets);
        }
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        uint256 penaltyAssets = totalPenaltyAssets(reallocations);
        uint256 borrowAssets = maxBorrowAssets > 0
            ? UtilsLib.min(
                maxBorrowAssets, maxHealthyBorrow(marketParams, msg.sender, collateralAssets + collateralToBuy)
            )
            : 0;
        uint256 flashLoanAssets = penaltyAssets.zeroFloorSub(loanAssets) + maxBorrowAssets - borrowAssets;
        bytes memory leverData = abi.encode(
            marketParams,
            msg.sender,
            collateralToBuy,
            borrowAssets,
            loanAssets + maxBorrowAssets - penaltyAssets,
            maxBorrowAssets - borrowAssets,
            swapData
        );

        if (flashLoanAssets > 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
            IMorpho(BLUE)
                .flashLoan(
                    marketParams.loanToken,
                    flashLoanAssets,
                    abi.encode(marketParams, msg.sender, collateralAssets + collateralToBuy, reallocations, leverData)
                );
        } else {
            executePublicAllocations(marketParams.loanToken, reallocations);
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
            IMorpho(BLUE).supplyCollateral(marketParams, collateralAssets + collateralToBuy, msg.sender, leverData);
        }
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @dev Repays minRepayAssets of msg.sender's debt; in Blue's callback, withdraws collateralToSell and sells it through 0x for at least minRepayAssets.
    /// @dev swapData is expected to be a 0x SELL quote with sellAmount = collateralToSell and minBuyAmount >= minRepayAssets.
    /// @dev minRepayAssets must be non-zero and must not exceed msg.sender's debt, or else Blue reverts.
    /// @dev Unsold collateral is supplied back; the loan assets received above minRepayAssets repay the remaining debt, and the rest is sent to msg.sender.
    /// @dev Blue's health check on the withdrawal is performed with minRepayAssets repaid, before the surplus is repaid.
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
                    abi.encode(marketParams, collateralToSell, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @dev Repays all of msg.sender's borrow shares; in Blue's callback, withdraws all collateral and swaps at most maxCollateralIn of it through 0x for at least minLoanOut.
    /// @dev The quote type is not enforced: maxCollateralIn and minLoanOut are expected to be the quote's input cap and output floor.
    /// @dev To keep the collateral left after the repay, swapData is expected to be a 0x BUY quote with buyAmount = debt plus a buffer for the interest accrued until execution, maxSellAmount <= maxCollateralIn, and buyAmount >= minLoanOut.
    /// @dev To exit fully into loan assets, swapData is expected to be a 0x SELL quote with sellAmount = msg.sender's collateral <= maxCollateralIn and minBuyAmount >= minLoanOut.
    /// @dev minLoanOut includes the loan assets used to repay the debt; if the swap returns less than the debt, the repayment reverts on Blue.
    /// @dev The unsold collateral and the loan assets received above the debt are sent to msg.sender.
    /// @dev Without debt, withdraws all collateral to msg.sender and ignores maxCollateralIn, minLoanOut and swapData.
    /// @dev The msg.sender must have authorized this contract on Blue.
    function zeroExLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        uint256 minLoanOut,
        bytes calldata swapData,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active.
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
        } else {
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
                        abi.encode(marketParams, position.collateral, maxCollateralIn, minLoanOut, swapData)
                    )
                );
        }
    }

    /// CALLBACKS ///

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());

        executeLever(data);
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address sender, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.zeroExLeverageBundlesV1Delever.selector) {
            executeDelever(assets, sender, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1Close.selector) {
            executeClose(assets, sender, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function onMorphoFlashLoan(uint256, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (
            MarketParams memory marketParams,
            address sender,
            uint256 supplyAssets,
            PublicAllocations[] memory reallocations,
            bytes memory leverData
        ) = abi.decode(data, (MarketParams, address, uint256, PublicAllocations[], bytes));

        executePublicAllocations(marketParams.loanToken, reallocations);
        IMorpho(BLUE).supplyCollateral(marketParams, supplyAssets, sender, leverData);
    }

    /// INTERNAL ///

    /// @dev maxSwapIn is loanAssets + maxBorrowAssets minus the penalties of the public reallocations, which are paid from loanAssets or stay in this contract to repay the flash loan.
    /// @dev borrowShortfall is the part of maxBorrowAssets that is flash loaned instead of borrowed, which must be left unswapped to repay the flash loan.
    function executeLever(bytes calldata leverData) internal {
        (
            MarketParams memory marketParams,
            address sender,
            uint256 collateralToBuy,
            uint256 borrowAssets,
            uint256 maxSwapIn,
            uint256 borrowShortfall,
            bytes memory swapData
        ) = abi.decode(leverData, (MarketParams, address, uint256, uint256, uint256, uint256, bytes));

        if (borrowAssets > 0) IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, sender, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.loanToken, marketParams.collateralToken, maxSwapIn, collateralToBuy, swapData);

        repaySurplus(marketParams, sender, maxSwapIn - spent - borrowShortfall);
        if (received > collateralToBuy) {
            IMorpho(BLUE).supplyCollateral(marketParams, received - collateralToBuy, sender, "");
        }
    }

    /// @dev All touched markets' loan token must be loanToken, such that all penalties are paid in that same token.
    function executePublicAllocations(address loanToken, PublicAllocations[] memory reallocations) internal {
        if (reallocations.length > 0) {
            TokenLib.forceApproveMax(loanToken, PUBLIC_ALLOCATOR);

            for (uint256 i; i < reallocations.length; i++) {
                PublicAllocations memory reallocation = reallocations[i];
                require(reallocation.marketParams.loanToken == loanToken, InconsistentTokens());

                if (reallocation.fromIdle) {
                    // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active.
                    IBluePublicAllocator(PUBLIC_ALLOCATOR)
                        .allocateFromIdle(
                            reallocation.vault,
                            reallocation.adapter,
                            reallocation.marketParams,
                            reallocation.assets,
                            reallocation.penalty
                        );
                } else {
                    // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active.
                    IBluePublicAllocator(PUBLIC_ALLOCATOR)
                        .reallocate(
                            reallocation.vault,
                            reallocation.sourceAdapter,
                            reallocation.sourceMarketParams,
                            reallocation.adapter,
                            reallocation.marketParams,
                            reallocation.assets,
                            reallocation.penalty
                        );
                }
            }
        }
    }

    function totalPenaltyAssets(PublicAllocations[] calldata reallocations) internal pure returns (uint256) {
        uint256 penaltyAssets;
        for (uint256 i; i < reallocations.length; i++) {
            penaltyAssets += uint256(reallocations[i].assets).mulDivUp(reallocations[i].penalty, WAD);
        }
        return penaltyAssets;
    }

    function executeDelever(uint256 assets, address sender, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateralToSell, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateralToSell, sender, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.collateralToken, marketParams.loanToken, collateralToSell, assets, swapData);

        if (collateralToSell > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, collateralToSell - spent, sender, "");
        }
        repaySurplus(marketParams, sender, received - assets);
    }

    /// @dev Repays sender's debt with the surplus of loan assets, and sends what is left above the debt to sender.
    /// @dev Accrues interest when needed.
    function repaySurplus(MarketParams memory marketParams, address sender, uint256 surplus) internal {
        if (surplus > 0) {
            uint256 borrowShares = IMorpho(BLUE).position(marketParams.id(), sender).borrowShares;
            Market memory market = IMorpho(BLUE).market(marketParams.id());
            if (market.lastUpdate != block.timestamp) {
                IMorpho(BLUE).accrueInterest(marketParams);
                market = IMorpho(BLUE).market(marketParams.id());
            }
            uint256 debt = borrowShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

            if (surplus < debt) {
                IMorpho(BLUE).repay(marketParams, surplus, 0, sender, "");
            } else {
                if (borrowShares > 0) IMorpho(BLUE).repay(marketParams, 0, borrowShares, sender, "");
                SafeTransferLib.safeTransfer(marketParams.loanToken, sender, surplus - debt);
            }
        }
    }

    function executeClose(uint256 assets, address sender, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 collateral,
            uint256 maxCollateralIn,
            uint256 minLoanOut,
            bytes memory swapData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, uint256, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, sender, address(this));
        (uint256 spent, uint256 received) =
            swap(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, minLoanOut, swapData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, sender, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, sender, received - assets);
        }
    }

    /// @dev Returns the most assets that sender can borrow while staying healthy on Blue once addedCollateral is supplied, at the current oracle price.
    /// @dev Accrues interest when needed, then inverts Blue's health check to calculate the maximum assets to borrow.
    /// @dev Borrowing rounds the debt up by at most the value of one share, which is left as a margin.
    function maxHealthyBorrow(MarketParams memory marketParams, address sender, uint256 addedCollateral)
        internal
        returns (uint256)
    {
        Market memory market = IMorpho(BLUE).market(marketParams.id());
        if (market.lastUpdate != block.timestamp) {
            // forge-lint: disable-next-line(reentrancy-no-eth) The helper is only called from locked entrypoints.
            IMorpho(BLUE).accrueInterest(marketParams);
            market = IMorpho(BLUE).market(marketParams.id());
        }
        Position memory position = IMorpho(BLUE).position(marketParams.id(), sender);
        uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = (position.collateral + addedCollateral)
            .mulDivDown(price, ORACLE_PRICE_SCALE)
            .mulDivDown(marketParams.lltv, WAD);
        uint256 margin = uint256(1).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        return maxBorrow.zeroFloorSub(borrowed + margin);
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; type(uint256).max disables the check (and notably skips the oracle call).
    /// @dev Accrues interest when needed, then mirrors Blue's health check against maxLtv.
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

    /// @dev Approves AllowanceHolder for at most maxIn, and checks the balance deltas against maxIn and minOut.
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
        spent = inBefore - inAfter;
        require(spent <= maxIn, ExcessiveInput());

        uint256 outAfter = IERC20(tokenOut).balanceOf(address(this));
        received = outAfter - outBefore;
        require(received >= minOut, InsufficientOutput());
    }
}
