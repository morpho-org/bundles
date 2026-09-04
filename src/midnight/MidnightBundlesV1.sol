// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {
    IMidnightBundlesV1,
    OfferFill,
    CollateralWithdrawal,
    CollateralSupply
} from "./interfaces/IMidnightBundlesV1.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {TakeAmountsLib} from "../../lib/midnight/src/periphery/TakeAmountsLib.sol";
import {ConsumableUnitsLib} from "../../lib/midnight/src/periphery/ConsumableUnitsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";

/// @dev For each offer, the buy/sell functions will take min("units needed to fill target units / assets", offerFills[i].units, "units still consumable in offerFills[i].offer") units.
/// @dev Only touched offers are checked to point to market.
/// @dev Buy/sell functions skip the offer if the take reverted. This avoids reverting the whole call when other offers passed as argument still have liquidity.
/// @dev This bundler and the msg.sender (if different from the taker/onBehalf) should be authorized by taker/onBehalf on Midnight.
/// @dev msg.sender is always the tokens payer (for buy, supplyCollateral and repay), and receiver is always the tokens receiver (for sell, withdraw and withdraw collateral).
/// @dev The bundler contract must have an allowance to pull enough tokens from msg.sender.
/// @dev Inherits the token safety requirements of Midnight (see Midnight.sol).
/// @dev Offers are taken in the order they are passed. One sensible strategy is to sort them by price (increasing to buy, decreasing to sell).
/// @dev offerFills[i].units should prevent taking more than what is takeable w.r.t. the callback / the balances / the health.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
/// @dev For buy/sell functions, the current market continuous fee must be at most maxContinuousFee. Pass type(uint256).max to disable.
contract MidnightBundlesV1 is IMidnightBundlesV1 {
    using UtilsLib for uint256;

    address public immutable MIDNIGHT;

    constructor(address _midnight) {
        MIDNIGHT = _midnight;
    }

    /// EXTERNAL ///

    /// @dev This function pulls maxBuyerAssets from the msg.sender and transfers back the remaining tokens at the end.
    /// @dev The msg.sender will pay at most maxBuyerAssets.
    /// @dev The taker's debt is additionally repaid by repayUnits after the takes.
    /// @dev Total loan assets transferred from msg.sender is filledBuyerAssets + repayUnits + (filledBuyerAssets + repayUnits) * referralFeePct / (WAD - referralFeePct).
    /// @dev The collateralReceiver will receive collateralWithdrawals[0].assets of the first token of collateralWithdrawals, etc.
    function midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        uint256 repayUnits,
        address taker,
        bool reduceOnly,
        TokenPermit memory loanTokenPermit,
        OfferFill[] memory offerFills,
        CollateralWithdrawal[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(taker == msg.sender || IMidnight(MIDNIGHT).isAuthorized(taker, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        address loanToken = market.loanToken;
        TokenLib.pullToken(loanToken, msg.sender, maxBuyerAssets, loanTokenPermit);
        TokenLib.forceApproveMax(loanToken, MIDNIGHT);

        uint256 filledUnits;
        uint256 filledBuyerAssets;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            require(!offerFills[i].offer.buy, InconsistentSide());
            require(IdLib.toId(offerFills[i].offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                targetUnits - filledUnits,
                offerFills[i].units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, offerFills[i].offer)
            );
            require(!reduceOnly || unitsToTake <= IMidnight(MIDNIGHT).debt(id, taker), NotReduceOnly());
            try IMidnight(MIDNIGHT)
                .take(
                    offerFills[i].offer, offerFills[i].ratifierData, unitsToTake, taker, address(0), address(0), ""
                ) returns (
                uint256 resBuyerAssets, uint256
            ) {
                filledUnits += unitsToTake;
                filledBuyerAssets += resBuyerAssets;
            } catch {}
        }

        require(filledUnits == targetUnits, OutOfOffers());

        if (repayUnits > 0) IMidnight(MIDNIGHT).repay(market, repayUnits, taker, address(0), "");

        for (uint256 i; i < collateralWithdrawals.length; i++) {
            IMidnight(MIDNIGHT)
                .withdrawCollateral(
                    market,
                    collateralWithdrawals[i].collateralIndex,
                    collateralWithdrawals[i].assets,
                    taker,
                    collateralReceiver
                );
        }

        uint256 referralFeeAssets = (filledBuyerAssets + repayUnits).mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(
            loanToken, msg.sender, maxBuyerAssets - filledBuyerAssets - repayUnits - referralFeeAssets
        );
    }

    /// @dev The receiver will receive at least minSellerAssets.
    /// @dev The taker's credit is additionally withdrawn by withdrawUnits before the takes.
    /// @dev Total loan assets received by the receiver is filledSellerAssets + withdrawUnits - (filledSellerAssets + withdrawUnits) * referralFeePct / WAD.
    /// @dev msg.sender will pay collateralSupplies[0].assets of the first token of collateralSupplies, etc.
    function midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        uint256 withdrawUnits,
        address taker,
        bool reduceOnly,
        address receiver,
        CollateralSupply[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(taker == msg.sender || IMidnight(MIDNIGHT).isAuthorized(taker, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        for (uint256 i; i < collateralSupplies.length; i++) {
            address token = market.collateralParams[collateralSupplies[i].collateralIndex].token;
            TokenLib.pullToken(token, msg.sender, collateralSupplies[i].assets, collateralSupplies[i].permit);
            TokenLib.forceApproveMax(token, MIDNIGHT);
            IMidnight(MIDNIGHT)
                .supplyCollateral(market, collateralSupplies[i].collateralIndex, collateralSupplies[i].assets, taker);
        }

        if (withdrawUnits > 0) IMidnight(MIDNIGHT).withdraw(market, withdrawUnits, taker, address(this));

        uint256 filledUnits;
        uint256 filledSellerAssets;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            require(offerFills[i].offer.buy, InconsistentSide());
            require(IdLib.toId(offerFills[i].offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                targetUnits - filledUnits,
                offerFills[i].units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, offerFills[i].offer)
            );
            if (reduceOnly) {
                (uint128 takerCredit,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, taker);
                require(unitsToTake <= takerCredit, NotReduceOnly());
            }
            try IMidnight(MIDNIGHT)
                .take(
                    offerFills[i].offer, offerFills[i].ratifierData, unitsToTake, taker, address(this), address(0), ""
                ) returns (
                uint256, uint256 resSellerAssets
            ) {
                filledUnits += unitsToTake;
                filledSellerAssets += resSellerAssets;
            } catch {}
        }

        require(filledUnits == targetUnits, OutOfOffers());

        uint256 referralFeeAssets = (filledSellerAssets + withdrawUnits).mulDivDown(referralFeePct, WAD);
        require(filledSellerAssets + withdrawUnits - referralFeeAssets >= minSellerAssets, SellerAssetsTooLow());
        address loanToken = market.loanToken;
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(loanToken, receiver, filledSellerAssets + withdrawUnits - referralFeeAssets);
    }

    /// @dev Total loan assets transferred from msg.sender is targetBuyerAssets.
    /// @dev repayUnits loan assets of targetBuyerAssets are used to repay the taker's debt after the takes.
    /// @dev The taker will gain at least minUnits from the takes.
    /// @dev The referral fee changes the amount that must be filled, which can change the average taking price.
    /// @dev The collateralReceiver will receive collateralWithdrawals[0].assets of the first token of collateralWithdrawals, etc.
    function midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        uint256 repayUnits,
        address taker,
        bool reduceOnly,
        TokenPermit memory loanTokenPermit,
        OfferFill[] memory offerFills,
        CollateralWithdrawal[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(taker == msg.sender || IMidnight(MIDNIGHT).isAuthorized(taker, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        address loanToken = market.loanToken;
        TokenLib.pullToken(loanToken, msg.sender, targetBuyerAssets, loanTokenPermit);
        TokenLib.forceApproveMax(loanToken, MIDNIGHT);

        uint256 referralFeeAssets = targetBuyerAssets.mulDivDown(referralFeePct, WAD);
        uint256 targetFilledBuyerAssets = targetBuyerAssets - referralFeeAssets - repayUnits;

        uint256 filledUnits;
        uint256 filledBuyerAssets;
        for (uint256 i; i < offerFills.length && filledBuyerAssets < targetFilledBuyerAssets; i++) {
            require(!offerFills[i].offer.buy, InconsistentSide());
            require(IdLib.toId(offerFills[i].offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                TakeAmountsLib.buyerAssetsToUnits(
                    MIDNIGHT, id, offerFills[i].offer, targetFilledBuyerAssets - filledBuyerAssets
                ),
                offerFills[i].units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, offerFills[i].offer)
            );
            require(!reduceOnly || unitsToTake <= IMidnight(MIDNIGHT).debt(id, taker), NotReduceOnly());
            try IMidnight(MIDNIGHT)
                .take(
                    offerFills[i].offer, offerFills[i].ratifierData, unitsToTake, taker, address(0), address(0), ""
                ) returns (
                uint256 resBuyerAssets, uint256
            ) {
                filledUnits += unitsToTake;
                filledBuyerAssets += resBuyerAssets;
            } catch {}
        }

        require(filledBuyerAssets == targetFilledBuyerAssets, OutOfOffers());
        require(filledUnits >= minUnits, UnitsTooLow());

        if (repayUnits > 0) IMidnight(MIDNIGHT).repay(market, repayUnits, taker, address(0), "");

        for (uint256 i; i < collateralWithdrawals.length; i++) {
            IMidnight(MIDNIGHT)
                .withdrawCollateral(
                    market,
                    collateralWithdrawals[i].collateralIndex,
                    collateralWithdrawals[i].assets,
                    taker,
                    collateralReceiver
                );
        }

        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
    }

    /// @dev Total loan assets received by the receiver is targetSellerAssets.
    /// @dev withdrawUnits of the taker's credit are withdrawn before the takes and count toward targetSellerAssets.
    /// @dev The taker will lose at most maxUnits from the takes.
    /// @dev The referral fee changes the amount that must be filled, which can change the average taking price.
    /// @dev msg.sender will pay collateralSupplies[0].assets of the first token of collateralSupplies, etc.
    function midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        uint256 withdrawUnits,
        address taker,
        bool reduceOnly,
        address receiver,
        CollateralSupply[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(taker == msg.sender || IMidnight(MIDNIGHT).isAuthorized(taker, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        for (uint256 i; i < collateralSupplies.length; i++) {
            address token = market.collateralParams[collateralSupplies[i].collateralIndex].token;
            TokenLib.pullToken(token, msg.sender, collateralSupplies[i].assets, collateralSupplies[i].permit);
            TokenLib.forceApproveMax(token, MIDNIGHT);
            IMidnight(MIDNIGHT)
                .supplyCollateral(market, collateralSupplies[i].collateralIndex, collateralSupplies[i].assets, taker);
        }

        if (withdrawUnits > 0) IMidnight(MIDNIGHT).withdraw(market, withdrawUnits, taker, address(this));

        uint256 referralFeeAssets = targetSellerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 targetFilledSellerAssets = targetSellerAssets + referralFeeAssets - withdrawUnits;

        uint256 filledUnits;
        uint256 filledSellerAssets;
        for (uint256 i; i < offerFills.length && filledSellerAssets < targetFilledSellerAssets; i++) {
            require(offerFills[i].offer.buy, InconsistentSide());
            require(IdLib.toId(offerFills[i].offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                TakeAmountsLib.sellerAssetsToUnits(
                    MIDNIGHT, id, offerFills[i].offer, targetFilledSellerAssets - filledSellerAssets
                ),
                offerFills[i].units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, offerFills[i].offer)
            );
            if (reduceOnly) {
                (uint128 takerCredit,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, taker);
                require(unitsToTake <= takerCredit, NotReduceOnly());
            }
            try IMidnight(MIDNIGHT)
                .take(
                    offerFills[i].offer, offerFills[i].ratifierData, unitsToTake, taker, address(this), address(0), ""
                ) returns (
                uint256, uint256 resSellerAssets
            ) {
                filledUnits += unitsToTake;
                filledSellerAssets += resSellerAssets;
            } catch {}
        }

        require(filledSellerAssets == targetFilledSellerAssets, OutOfOffers());
        require(filledUnits <= maxUnits, UnitsTooHigh());

        address loanToken = market.loanToken;
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(loanToken, receiver, targetSellerAssets);
    }

    /// INTERNAL ///

    /// @dev Returns min(x, y, z).
    function min(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return UtilsLib.min(UtilsLib.min(x, y), z);
    }
}
