// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import {ISetterRatifier} from "../../lib/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {TakeAmountsLib} from "../../lib/midnight/src/periphery/libraries/TakeAmountsLib.sol";
import {ConsumableUnitsLib} from "../../lib/midnight/src/periphery/libraries/ConsumableUnitsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {
    IMidnightBundlesV2,
    CollateralSupply,
    CollateralSupplyWithPermit,
    CollateralWithdrawal,
    OfferFill
} from "./interfaces/IMidnightBundlesV2.sol";

/// @dev Maker-side Midnight offer creation and reposting, including callback-funded lend offers and collateralized borrow offers.
/// @dev Taker-side buying and selling against Midnight offers, including collateral supply/withdrawal and debt repayment.
/// @dev Inherits the token safety requirements of Midnight and Morpho Blue.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
contract MidnightBundlesV2 is IMidnightBundlesV2 {
    using UtilsLib for uint256;

    address public immutable MIDNIGHT;
    address public immutable BLUE;
    address public immutable BLUE_BUY_CALLBACK_FACTORY;
    address public immutable LOG;
    address public immutable SETTER_RATIFIER;

    constructor(
        address _midnight,
        address _blue,
        address _blueBuyCallbackFactory,
        address _log,
        address _setterRatifier
    ) {
        require(
            IBlueBuyCallbackFactory(_blueBuyCallbackFactory).MIDNIGHT() == _midnight
                && ISetterRatifier(_setterRatifier).MIDNIGHT() == _midnight,
            InconsistentMidnight()
        );
        require(IBlueBuyCallbackFactory(_blueBuyCallbackFactory).BLUE() == _blue, InconsistentBlue());

        MIDNIGHT = _midnight;
        BLUE = _blue;
        BLUE_BUY_CALLBACK_FACTORY = _blueBuyCallbackFactory;
        LOG = _log;
        SETTER_RATIFIER = _setterRatifier;
    }

    /// MAKE-SIDE EXTERNAL FUNCTIONS ///

    /// @dev Optionally parks loan assets on Blue for msg.sender's derived callback.
    /// @dev Buy offers intended to be funded by the assets supplied to Blue must set Offer.callback to the derived BlueBuyCallback address and Offer.callbackData to abi.encode(blueMarket).
    /// @dev Optionally supplies collateral to msg.sender on Midnight.
    /// @dev Cancels each group in groupsToCancel for msg.sender. Pass an empty array to skip cancellation.
    /// @dev If newRoot is non-zero, authorizes SETTER_RATIFIER, activates newRoot, and publishes payload. Otherwise payload is ignored and SETTER_RATIFIER authorization is unchanged.
    /// @dev Set assetsToPark to zero and pass an empty collateralSupplies array to repost or cancel without moving assets. blueMarket and callbackSalt are unused when assetsToPark is zero; market is unused when all collateral supplies are zero.
    /// @dev msg.sender must approve this contract for all supplied loan and collateral assets beforehand.
    /// @dev The new root may contain offers for multiple markets.
    /// @dev Share-price slippage when parking assets on Blue is not checked. Users must only use markets protected against supply-share-price inflation attacks.
    /// @dev This bundle does not check that:
    /// - Offers in newRoot or payload match the intended use case (lend limit or borrow limit) and the supplied funding or collateral inputs.
    /// - newRoot corresponds to the offers described by payload. The payload posted to LOG is not validated against any on-chain state or bundle inputs.
    /// @dev Cancel prior offers before reposting to avoid leaving both old and new offers takeable. Include their group IDs in groupsToCancel and use fresh group IDs for the new offers.
    /// @dev The maker must authorize this contract on Midnight beforehand.
    function midnightBundlesV2CancelAndMake(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        Market memory market,
        CollateralSupply[] memory collateralSupplies,
        bytes32 newRoot,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        if (assetsToPark > 0) {
            address blueBuyCallback =
                IBlueBuyCallbackFactory(BLUE_BUY_CALLBACK_FACTORY).createBlueBuyCallback(msg.sender, callbackSalt);
            SafeTransferLib.safeTransferFrom(blueMarket.loanToken, msg.sender, address(this), assetsToPark);
            TokenLib.forceApproveMax(blueMarket.loanToken, BLUE);
            IMorpho(BLUE).supply(blueMarket, assetsToPark, 0, blueBuyCallback, "");
        }

        for (uint256 i; i < collateralSupplies.length; i++) {
            CollateralSupply memory collateralSupply = collateralSupplies[i];
            if (collateralSupply.assets > 0) {
                address collateralToken = market.collateralParams[collateralSupply.collateralIndex].token;
                SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), collateralSupply.assets);
                TokenLib.forceApproveMax(collateralToken, MIDNIGHT);
                IMidnight(MIDNIGHT)
                    .supplyCollateral(market, collateralSupply.collateralIndex, collateralSupply.assets, msg.sender);
            }
        }

        for (uint256 i; i < groupsToCancel.length; i++) {
            IMidnight(MIDNIGHT).setConsumed(groupsToCancel[i], type(uint128).max, msg.sender);
        }

        if (newRoot != bytes32(0)) {
            IMidnight(MIDNIGHT).setIsAuthorized(SETTER_RATIFIER, true, msg.sender);
            ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, newRoot, true);

            (bool success, bytes memory returndata) = LOG.call(payload);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
    }

    /// TAKE-SIDE EXTERNAL FUNCTIONS ///

    // For each offer, the buy/sell functions below will take min("units needed to fill target units / assets", offerFills[i].units, "units still consumable in offerFills[i].offer") units.
    // Only touched offers are checked to point to the given market.
    // The buy/sell functions below skip the offer if the take reverted. This avoids reverting the whole call when other offers passed as argument still have liquidity.
    // This bundler and the msg.sender (if different from the taker/onBehalf) should be authorized by taker/onBehalf on Midnight for the buy/sell functions below.
    // msg.sender is always the tokens payer (for buy, supplyCollateral and repay), and receiver is always the tokens receiver (for sell, withdraw and withdraw collateral).
    // The bundler contract must have an allowance to pull enough tokens from msg.sender for the buy/sell functions below.
    // Offers are taken in the order they are passed. One sensible strategy is to sort them by price (increasing to buy, decreasing to sell).
    // offerFills[i].units should prevent taking more than what is takeable w.r.t. the callback / the balances / the health.
    // For the buy/sell functions below, the current market continuous fee must be at most maxContinuousFee when taking offers. Pass type(uint256).max to disable.

    /// @dev This function pulls maxBuyerAssets from the msg.sender and transfers back the remaining tokens at the end.
    /// @dev The msg.sender will pay at most maxBuyerAssets.
    /// @dev If repayEnabled and the taker has debt, the remaining amount not covered by the take loop is repaid.
    /// @dev Total loan assets transferred from msg.sender is filledBuyerAssets + filledBuyerAssets * referralFeePct / (WAD - referralFeePct).
    /// @dev The collateralReceiver will receive collateralWithdrawals[0].assets of the first token of collateralWithdrawals, etc.
    function midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        address taker,
        bool reduceOnly,
        bool repayEnabled,
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
        if (repayEnabled) {
            uint256 repayUnits = UtilsLib.min(targetUnits - filledUnits, IMidnight(MIDNIGHT).debt(id, taker));
            IMidnight(MIDNIGHT).repay(market, repayUnits, taker, address(0), "");
            filledUnits += repayUnits;
            filledBuyerAssets += repayUnits;
        }

        require(filledUnits == targetUnits, OutOfOffers());

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

        uint256 referralFeeAssets = filledBuyerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(loanToken, msg.sender, maxBuyerAssets - filledBuyerAssets - referralFeeAssets);
    }

    /// @dev The receiver will receive at least minSellerAssets.
    /// @dev If the taker has credit, as much credit as possible is withdrawn before the take loop.
    /// @dev Total loan assets received by the receiver is filledSellerAssets - filledSellerAssets * referralFeePct / WAD.
    /// @dev msg.sender will pay collateralSupplies[0].assets of the first token of collateralSupplies, etc.
    function midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        address taker,
        bool reduceOnly,
        address receiver,
        CollateralSupplyWithPermit[] memory collateralSupplies,
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

        (uint128 takerCreditBefore,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, taker);
        uint256 withdrawUnits = min(targetUnits, takerCreditBefore, IMidnight(MIDNIGHT).withdrawable(id));
        IMidnight(MIDNIGHT).withdraw(market, withdrawUnits, taker, address(this));
        uint256 filledUnits = withdrawUnits;
        uint256 filledSellerAssets = withdrawUnits;
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

        uint256 referralFeeAssets = filledSellerAssets.mulDivDown(referralFeePct, WAD);
        require(filledSellerAssets - referralFeeAssets >= minSellerAssets, SellerAssetsTooLow());
        address loanToken = market.loanToken;
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(loanToken, receiver, filledSellerAssets - referralFeeAssets);
    }

    /// @dev Total loan assets transferred from msg.sender is targetBuyerAssets.
    /// @dev If repayEnabled and the taker has debt, the remaining amount not covered by the take loop is repaid.
    /// @dev The taker will gain at least minUnits.
    /// @dev The referral fee changes the amount that must be filled, which can change the average taking price.
    /// @dev The collateralReceiver will receive collateralWithdrawals[0].assets of the first token of collateralWithdrawals, etc.
    function midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        address taker,
        bool reduceOnly,
        bool repayEnabled,
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
        uint256 targetFilledBuyerAssets = targetBuyerAssets - referralFeeAssets;

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
        if (repayEnabled) {
            uint256 repayAssets =
                UtilsLib.min(targetFilledBuyerAssets - filledBuyerAssets, IMidnight(MIDNIGHT).debt(id, taker));
            IMidnight(MIDNIGHT).repay(market, repayAssets, taker, address(0), "");
            filledUnits += repayAssets;
            filledBuyerAssets += repayAssets;
        }

        require(filledBuyerAssets == targetFilledBuyerAssets, OutOfOffers());
        require(filledUnits >= minUnits, UnitsTooLow());

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
    /// @dev If the taker has credit, as much credit as possible is withdrawn before the take loop.
    /// @dev The taker will lose at most maxUnits.
    /// @dev The referral fee changes the amount that must be filled, which can change the average taking price.
    /// @dev msg.sender will pay collateralSupplies[0].assets of the first token of collateralSupplies, etc.
    function midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        address taker,
        bool reduceOnly,
        address receiver,
        CollateralSupplyWithPermit[] memory collateralSupplies,
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

        uint256 referralFeeAssets = targetSellerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 targetFilledSellerAssets = targetSellerAssets + referralFeeAssets;

        (uint128 takerCreditBefore,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, taker);
        uint256 withdrawUnits = min(targetFilledSellerAssets, takerCreditBefore, IMidnight(MIDNIGHT).withdrawable(id));
        IMidnight(MIDNIGHT).withdraw(market, withdrawUnits, taker, address(this));
        uint256 filledUnits = withdrawUnits;
        uint256 filledSellerAssets = withdrawUnits;
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

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns min(x, y, z).
    function min(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return UtilsLib.min(UtilsLib.min(x, y), z);
    }
}
