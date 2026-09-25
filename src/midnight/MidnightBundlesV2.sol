// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import {
    IRatifiersV1Common,
    SET_IS_ROOT_RATIFIED_SUCCESS
} from "../../lib/midnight/src/ratifiers/interfaces/IRatifiersV1Common.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {TakeAmountsLib} from "../../lib/midnight/src/periphery/libraries/TakeAmountsLib.sol";
import {ConsumableUnitsLib} from "../../lib/midnight/src/periphery/libraries/ConsumableUnitsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IWNative} from "../libraries/interfaces/IWNative.sol";
import {
    IMidnightBundlesV2,
    GroupCancellation,
    CollateralTransfer,
    OfferFill
} from "./interfaces/IMidnightBundlesV2.sol";

/// @dev This contract enables:
/// - Midnight offer creation and reposting, including BlueBuyCallback-funded lend offers and collateralized borrow offers.
/// - Midnight batch-takes, including collateral supply/withdrawal and repayment at face value.
/// @dev Inherits the token safety requirements of Midnight and Morpho Blue.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev All entrypoints share the same native-token handling: when msg.value is non-zero, it is wrapped using wrappedNative and transferred to msg.sender before the regular ERC20 pulls.
/// @dev Native tokens may be combined with an existing wrappedNative balance and are not required to match any individual transfer amount.
/// @dev msg.sender must approve this contract to pull wrappedNative before using native tokens.
/// @dev The users must authorize this contract on Midnight beforehand.
contract MidnightBundlesV2 is IMidnightBundlesV2 {
    using UtilsLib for uint256;

    address public immutable MIDNIGHT;
    address public immutable BLUE;
    address public immutable BLUE_BUY_CALLBACK_FACTORY;
    address public immutable LOG;

    constructor(address _midnight, address _blue, address _blueBuyCallbackFactory, address _log) {
        require(IBlueBuyCallbackFactory(_blueBuyCallbackFactory).MIDNIGHT() == _midnight, InconsistentMidnight());
        require(IBlueBuyCallbackFactory(_blueBuyCallbackFactory).BLUE() == _blue, InconsistentBlue());

        MIDNIGHT = _midnight;
        BLUE = _blue;
        BLUE_BUY_CALLBACK_FACTORY = _blueBuyCallbackFactory;
        LOG = _log;
    }

    /// MAKE-SIDE EXTERNAL FUNCTIONS ///

    /// @dev Optionally parks loan assets on Blue for msg.sender's derived callback.
    /// @dev Buy offers intended to be funded by the assets supplied to Blue must set Offer.callback to the derived BlueBuyCallback address and Offer.callbackData to abi.encode(blueMarket).
    /// @dev Optionally supplies collateral to msg.sender on Midnight.
    /// @dev First checks consumption limits and cancels the groups in groupsToCancel for msg.sender. Pass an empty array to skip cancellation.
    /// @dev Use consumption limits to avoid reposting oversized offers if additional fills occur before cancellation.
    /// @dev Each group's maxConsumed is the maximum acceptable Midnight consumption before cancellation, in the group's units or assets.
    /// @dev Set a group's maxConsumed to type(uint128).max to disable the limit for that group.
    /// @dev If newRoot is non-zero, this call grants the ratifier full authorization over msg.sender's Midnight account. Users must verify that ratifier is the intended, trusted contract before calling.
    /// @dev If newRoot is non-zero, authorizes ratifier, activates newRoot on it, and publishes payload. Supports PriceRatifierV1 and RateRatifierV1; the selected root setter must return SET_IS_ROOT_RATIFIED_SUCCESS.
    /// @dev Pass v = r = s = 0 to call setIsRootRatified. Otherwise, the signature parameters are passed to setIsRootRatifiedWithSig. The signature deadline is independent of the bundle's deadline.
    /// @dev If newRoot is zero, ratifier, signature parameters, and payload are ignored and ratifier authorizations are unchanged.
    /// @dev Set assetsToPark to zero and pass an empty collateralSupplies array to repost or cancel without moving assets. blueMarket and callbackSalt are unused when assetsToPark is zero.
    /// @dev msg.sender must approve this contract for all supplied loan and collateral assets beforehand.
    /// @dev The new root may contain offers for multiple markets.
    /// @dev Share-price slippage when parking assets on Blue is not checked. Users must only use markets protected against supply-share-price inflation attacks.
    /// @dev This bundle notably does not check that:
    /// - Offers in newRoot or payload match the selected ratifier, the intended use case (lend limit or borrow limit), and the supplied funding or collateral inputs.
    /// - newRoot corresponds to the offers described by payload. The payload posted to LOG is not validated against any on-chain state or bundle inputs.
    /// - Prior offers are cancelled when reposting. Include their group IDs in groupsToCancel and use fresh group IDs for the new offers, otherwise both old and new offers remain takeable.
    function midnightBundlesV2CancelAndMake(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        Market memory market,
        CollateralTransfer[] memory collateralSupplies,
        address ratifier,
        bytes32 newRoot,
        uint256 signatureHeight,
        uint128 signatureNonce,
        uint256 signatureDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        GroupCancellation[] memory groupsToCancel,
        bytes memory payloadToLog,
        uint256 deadline,
        address wrappedNative
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        if (msg.value > 0) wrapNativeToMsgSender(wrappedNative);

        for (uint256 i; i < groupsToCancel.length; i++) {
            GroupCancellation memory cancellation = groupsToCancel[i];
            require(
                IMidnight(MIDNIGHT).consumed(msg.sender, cancellation.group) <= cancellation.maxConsumed,
                ConsumedAboveMax()
            );
            IMidnight(MIDNIGHT).setConsumed(cancellation.group, type(uint128).max, msg.sender);
        }

        for (uint256 i; i < collateralSupplies.length; i++) {
            address collateralToken = market.collateralParams[collateralSupplies[i].collateralIndex].token;
            SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), collateralSupplies[i].assets);
            TokenLib.forceApproveMax(collateralToken, MIDNIGHT);
            IMidnight(MIDNIGHT)
                .supplyCollateral(
                    market, collateralSupplies[i].collateralIndex, collateralSupplies[i].assets, msg.sender
                );
        }

        if (assetsToPark > 0) {
            address blueBuyCallback =
                IBlueBuyCallbackFactory(BLUE_BUY_CALLBACK_FACTORY).createBlueBuyCallback(msg.sender, callbackSalt);
            SafeTransferLib.safeTransferFrom(blueMarket.loanToken, msg.sender, address(this), assetsToPark);
            TokenLib.forceApproveMax(blueMarket.loanToken, BLUE);
            IMorpho(BLUE).supply(blueMarket, assetsToPark, 0, blueBuyCallback, "");
        }

        if (newRoot != bytes32(0)) {
            IMidnight(MIDNIGHT).setIsAuthorized(ratifier, true, msg.sender);
            if (v == 0 && r == 0 && s == 0) {
                bytes32 res = IRatifiersV1Common(ratifier).setIsRootRatified(msg.sender, newRoot, true);
                require(res == SET_IS_ROOT_RATIFIED_SUCCESS, InvalidRatifierResponse());
            } else {
                bytes32 res = IRatifiersV1Common(ratifier)
                    .setIsRootRatifiedWithSig(
                        msg.sender, newRoot, signatureHeight, true, signatureNonce, signatureDeadline, v, r, s
                    );
                require(res == SET_IS_ROOT_RATIFIED_SUCCESS, InvalidRatifierResponse());
            }

            log(payloadToLog);
        }
    }

    /// TAKE-SIDE EXTERNAL FUNCTIONS ///

    // For each offer, the buy/sell functions below will take min("units needed to fill target units / assets", offerFills[i].units, "units still consumable in offerFills[i].offer") units.
    // Only touched offers are checked to point to the given market.
    // The buy/sell functions below skip the offer if the take reverted. This avoids reverting the whole call when other offers passed as argument still have liquidity.
    // msg.sender is always the tokens payer (for buy, supplyCollateral and repay), and receiver is always the tokens receiver (for sell, withdraw and withdraw collateral).
    // The bundler contract must have an allowance to pull enough tokens from msg.sender for the buy/sell functions below.
    // Offers are taken in the order they are passed. One sensible strategy is to sort them by price (increasing to buy, decreasing to sell).
    // offerFills[i].units should prevent taking more than what is takeable w.r.t. the callback / the balances / the health.
    // For the buy functions below, the current market continuous fee must be at most maxContinuousFee when taking offers. Pass type(uint256).max to disable.

    /// @dev This function pulls maxBuyerAssets from the msg.sender and transfers back the remaining tokens at the end.
    /// @dev msg.sender will pay at most maxBuyerAssets.
    /// @dev If repayEnabled and msg.sender has debt, the remaining amount not covered by the take loop is repaid.
    /// @dev Total loan assets transferred from msg.sender is filledBuyerAssets + filledBuyerAssets * referralFeePct / (WAD - referralFeePct).
    /// @dev The collateralReceiver will receive collateralWithdrawals[0].assets of the first token of collateralWithdrawals, etc.
    function midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        bool reduceOnly,
        bool repayEnabled,
        OfferFill[] memory offerFills,
        CollateralTransfer[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline,
        address wrappedNative
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        if (msg.value > 0) wrapNativeToMsgSender(wrappedNative);
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        address loanToken = market.loanToken;
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), maxBuyerAssets);
        TokenLib.forceApproveMax(loanToken, MIDNIGHT);

        uint256 filledUnits;
        uint256 filledBuyerAssets;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            OfferFill memory fill = offerFills[i];
            require(!fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                targetUnits - filledUnits, fill.units, ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer)
            );
            require(!reduceOnly || unitsToTake <= IMidnight(MIDNIGHT).debt(id, msg.sender), NotReduceOnly());
            try IMidnight(MIDNIGHT)
                .take(fill.offer, fill.ratifierData, unitsToTake, msg.sender, address(0), address(0), "") returns (
                uint256 resBuyerAssets, uint256
            ) {
                filledUnits += unitsToTake;
                filledBuyerAssets += resBuyerAssets;
            } catch {}
        }
        if (repayEnabled) {
            uint256 repayUnits = UtilsLib.min(targetUnits - filledUnits, IMidnight(MIDNIGHT).debt(id, msg.sender));
            IMidnight(MIDNIGHT).repay(market, repayUnits, msg.sender, address(0), "");
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
                    msg.sender,
                    collateralReceiver
                );
        }

        uint256 referralFeeAssets = filledBuyerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);

        uint256 remainder = maxBuyerAssets - filledBuyerAssets - referralFeeAssets;
        if (remainder > 0) SafeTransferLib.safeTransfer(loanToken, msg.sender, remainder);
    }

    /// @dev The receiver will receive at least minSellerAssets.
    /// @dev If msg.sender has credit, as much credit as possible is withdrawn before the take loop.
    /// @dev Total loan assets received by the receiver is filledSellerAssets - filledSellerAssets * referralFeePct / WAD.
    /// @dev msg.sender will pay collateralSupplies[0].assets of the first token of collateralSupplies, etc.
    function midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        bool reduceOnly,
        address receiver,
        CollateralTransfer[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline,
        address wrappedNative
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        if (msg.value > 0) wrapNativeToMsgSender(wrappedNative);
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        for (uint256 i; i < collateralSupplies.length; i++) {
            address collateralToken = market.collateralParams[collateralSupplies[i].collateralIndex].token;
            SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), collateralSupplies[i].assets);
            TokenLib.forceApproveMax(collateralToken, MIDNIGHT);
            IMidnight(MIDNIGHT)
                .supplyCollateral(
                    market, collateralSupplies[i].collateralIndex, collateralSupplies[i].assets, msg.sender
                );
        }

        (uint128 takerCreditBefore,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, msg.sender);
        uint256 withdrawUnits = min(targetUnits, takerCreditBefore, IMidnight(MIDNIGHT).withdrawable(id));
        IMidnight(MIDNIGHT).withdraw(market, withdrawUnits, msg.sender, address(this));
        uint256 filledUnits = withdrawUnits;
        uint256 filledSellerAssets = withdrawUnits;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            OfferFill memory fill = offerFills[i];
            require(fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            uint256 unitsToTake = min(
                targetUnits - filledUnits, fill.units, ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer)
            );
            if (reduceOnly) {
                (uint128 takerCredit,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, msg.sender);
                require(unitsToTake <= takerCredit, NotReduceOnly());
            }
            try IMidnight(MIDNIGHT)
                .take(fill.offer, fill.ratifierData, unitsToTake, msg.sender, address(this), address(0), "") returns (
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
    /// @dev If repayEnabled and msg.sender has debt, the remaining amount not covered by the take loop is repaid.
    /// @dev msg.sender will gain at least minUnits.
    /// @dev The referral fee changes the amount that must be filled, which can change the average taking price.
    /// @dev The collateralReceiver will receive collateralWithdrawals[0].assets of the first token of collateralWithdrawals, etc.
    function midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        bool reduceOnly,
        bool repayEnabled,
        OfferFill[] memory offerFills,
        CollateralTransfer[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline,
        address wrappedNative
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        if (msg.value > 0) wrapNativeToMsgSender(wrappedNative);
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        address loanToken = market.loanToken;
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), targetBuyerAssets);
        TokenLib.forceApproveMax(loanToken, MIDNIGHT);

        uint256 referralFeeAssets = targetBuyerAssets.mulDivDown(referralFeePct, WAD);
        uint256 targetFilledBuyerAssets = targetBuyerAssets - referralFeeAssets;

        uint256 filledUnits;
        uint256 filledBuyerAssets;
        for (uint256 i; i < offerFills.length && filledBuyerAssets < targetFilledBuyerAssets; i++) {
            OfferFill memory fill = offerFills[i];
            require(!fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                TakeAmountsLib.buyerAssetsToUnits(
                    MIDNIGHT, id, fill.offer, targetFilledBuyerAssets - filledBuyerAssets
                ),
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer)
            );
            require(!reduceOnly || unitsToTake <= IMidnight(MIDNIGHT).debt(id, msg.sender), NotReduceOnly());
            try IMidnight(MIDNIGHT)
                .take(fill.offer, fill.ratifierData, unitsToTake, msg.sender, address(0), address(0), "") returns (
                uint256 resBuyerAssets, uint256
            ) {
                filledUnits += unitsToTake;
                filledBuyerAssets += resBuyerAssets;
            } catch {}
        }
        if (repayEnabled) {
            uint256 repayAssets =
                UtilsLib.min(targetFilledBuyerAssets - filledBuyerAssets, IMidnight(MIDNIGHT).debt(id, msg.sender));
            IMidnight(MIDNIGHT).repay(market, repayAssets, msg.sender, address(0), "");
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
                    msg.sender,
                    collateralReceiver
                );
        }

        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(loanToken, referralFeeRecipient, referralFeeAssets);
    }

    /// @dev Total loan assets received by the receiver is targetSellerAssets.
    /// @dev If msg.sender has credit, as much credit as possible is withdrawn before the take loop.
    /// @dev msg.sender will lose at most maxUnits.
    /// @dev The referral fee changes the amount that must be filled, which can change the average taking price.
    /// @dev msg.sender will pay collateralSupplies[0].assets of the first token of collateralSupplies, etc.
    function midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        bool reduceOnly,
        address receiver,
        CollateralTransfer[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline,
        address wrappedNative
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        if (msg.value > 0) wrapNativeToMsgSender(wrappedNative);
        require(referralFeePct < WAD, PctExceeded());
        // touchMarket to have the correct settlement fees.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        for (uint256 i; i < collateralSupplies.length; i++) {
            address collateralToken = market.collateralParams[collateralSupplies[i].collateralIndex].token;
            SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), collateralSupplies[i].assets);
            TokenLib.forceApproveMax(collateralToken, MIDNIGHT);
            IMidnight(MIDNIGHT)
                .supplyCollateral(
                    market, collateralSupplies[i].collateralIndex, collateralSupplies[i].assets, msg.sender
                );
        }

        uint256 referralFeeAssets = targetSellerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 targetFilledSellerAssets = targetSellerAssets + referralFeeAssets;

        (uint128 takerCreditBefore,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, msg.sender);
        uint256 withdrawUnits = min(targetFilledSellerAssets, takerCreditBefore, IMidnight(MIDNIGHT).withdrawable(id));
        IMidnight(MIDNIGHT).withdraw(market, withdrawUnits, msg.sender, address(this));
        uint256 filledUnits = withdrawUnits;
        uint256 filledSellerAssets = withdrawUnits;
        for (uint256 i; i < offerFills.length && filledSellerAssets < targetFilledSellerAssets; i++) {
            OfferFill memory fill = offerFills[i];
            require(fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            uint256 unitsToTake = min(
                TakeAmountsLib.sellerAssetsToUnits(
                    MIDNIGHT, id, fill.offer, targetFilledSellerAssets - filledSellerAssets
                ),
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer)
            );
            if (reduceOnly) {
                (uint128 takerCredit,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, msg.sender);
                require(unitsToTake <= takerCredit, NotReduceOnly());
            }
            try IMidnight(MIDNIGHT)
                .take(fill.offer, fill.ratifierData, unitsToTake, msg.sender, address(this), address(0), "") returns (
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

    /// @dev Wraps msg.value into wrappedNative and transfers it to msg.sender.
    // forge-lint: disable-next-item(arbitrary-send-eth) wrappedNative is chosen by msg.sender, who also receives the wrapped tokens.
    function wrapNativeToMsgSender(address wrappedNative) internal {
        IWNative(wrappedNative).deposit{value: msg.value}();
        SafeTransferLib.safeTransfer(wrappedNative, msg.sender, msg.value);
    }

    /// @dev Calls the log contract and bubbles up any revert data.
    function log(bytes memory payload) internal {
        (bool success, bytes memory returndata) = LOG.call(payload);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    /// @dev Returns min(x, y, z).
    function min(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return UtilsLib.min(UtilsLib.min(x, y), z);
    }
}
