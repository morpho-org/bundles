// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IBuyerAssetsBound} from "../../lib/midnight/src/interfaces/ICallbacks.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {TakeAmountsLib} from "../../lib/midnight/src/periphery/libraries/TakeAmountsLib.sol";
import {ConsumableUnitsLib} from "../../lib/midnight/src/periphery/libraries/ConsumableUnitsLib.sol";
import {OfferFill} from "../midnight/interfaces/IMidnightBundlesV2.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMidnightAdapter} from "./interfaces/IMidnightAdapter.sol";
import {IMidnightAdapterBundlesV1} from "./interfaces/IMidnightAdapterBundlesV1.sol";

/// @dev Lets an allocator of a Vault V2 take several Midnight offers through the vault's MidnightAdapter in one
/// transaction, with slippage protection. The take side of MidnightBundlesV2, pointed at MidnightAdapter.take.
/// @dev The only access rule: msg.sender must be an allocator of adapter.parentVault(). The vault is always read from
/// the adapter. Every other rule (the bundle being an allocator, caps, maxTtm, rate guardrails, shortfall allowance)
/// is enforced by the adapter and the vault; a take they reject reverts and is skipped.
/// @dev This contract must be an allocator of the vault: MidnightAdapter.take only accepts vault allocators.
/// @dev Holds no tokens, gives no approvals, has no storage besides the transient lock. Nothing is authorized on
/// Midnight. Its only state-changing calls are Midnight.touchMarket and MidnightAdapter.take.
/// @dev The vault pays and receives through the adapter's callbacks.
contract MidnightAdapterBundlesV1 is IMidnightAdapterBundlesV1 {
    using UtilsLib for uint256;

    address public immutable MIDNIGHT;

    bool internal transient locked;

    constructor(address _midnight) {
        MIDNIGHT = _midnight;
    }

    modifier nonReentrant() {
        require(!locked, Reentrancy());
        locked = true;
        _;
        locked = false;
    }

    /// EXTERNAL FUNCTIONS ///

    // Offers are taken in the order they are passed. Only touched offers are checked to point to the given market.
    // The functions below skip an offer if its take reverted, including reverts from the adapter's and the vault's
    // checks (caps, maxTtm, minNetBuyRate, maxNetSellRate, shortfallAllowance, forceSellable). This avoids reverting
    // the whole call when other offers passed as argument still have liquidity.
    // The vault is always read from the adapter, never passed by the caller.
    // For the buy functions below, the current market continuous fee must be at most maxContinuousFee when taking offers.

    /// @dev Buys credit for the adapter's parent vault by taking sell offers.
    /// @dev The vault spends exactly targetBuyerAssets (settlement fee included), or the call reverts with OutOfOffers.
    /// @dev The adapter gains at least minUnits, or the call reverts with UnitsTooLow.
    /// @dev takerCallbackData is forwarded to the adapter and selects the funding source:
    /// abi.encode(address(0), "") for the vault's idle assets.
    function midnightAdapterBundlesV1BuyWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        OfferFill[] memory offerFills,
        bytes memory takerCallbackData,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(IMidnightAdapter(adapter).parentVault()).isAllocator(msg.sender), Unauthorized());
        // touchMarket to have the correct settlement fees.
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        uint256 filledUnits;
        uint256 filledBuyerAssets;
        for (uint256 i; i < offerFills.length && filledBuyerAssets < targetBuyerAssets; i++) {
            OfferFill memory fill = offerFills[i];
            require(!fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                TakeAmountsLib.buyerAssetsToUnits(MIDNIGHT, id, fill.offer, targetBuyerAssets - filledBuyerAssets),
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer),
                fill.offer.reduceOnly ? credit(market, id, fill.offer.maker) : type(uint256).max
            );
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapter(adapter).take(fill.offer, fill.ratifierData, unitsToTake, takerCallbackData) returns (
                uint256 resBuyerAssets, uint256
            ) {
                filledUnits += unitsToTake;
                filledBuyerAssets += resBuyerAssets;
            } catch {}
        }

        require(filledBuyerAssets == targetBuyerAssets, OutOfOffers());
        require(filledUnits >= minUnits, UnitsTooLow());
    }

    /// @dev Buys exactly targetUnits of credit for the adapter's parent vault by taking sell offers.
    /// @dev The vault spends at most maxBuyerAssets, or the call reverts with BuyerAssetsTooHigh.
    /// @dev takerCallbackData is forwarded to the adapter and selects the funding source.
    function midnightAdapterBundlesV1BuyWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        OfferFill[] memory offerFills,
        bytes memory takerCallbackData,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(IMidnightAdapter(adapter).parentVault()).isAllocator(msg.sender), Unauthorized());
        // touchMarket to have the correct settlement fees.
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        uint256 filledUnits;
        uint256 filledBuyerAssets;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            OfferFill memory fill = offerFills[i];
            require(!fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            require(IMidnight(MIDNIGHT).continuousFee(id) <= maxContinuousFee, ContinuousFeeAboveMax());
            uint256 unitsToTake = min(
                targetUnits - filledUnits,
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer),
                fill.offer.reduceOnly ? credit(market, id, fill.offer.maker) : type(uint256).max
            );
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapter(adapter).take(fill.offer, fill.ratifierData, unitsToTake, takerCallbackData) returns (
                uint256 resBuyerAssets, uint256
            ) {
                filledUnits += unitsToTake;
                filledBuyerAssets += resBuyerAssets;
            } catch {}
        }

        require(filledUnits == targetUnits, OutOfOffers());
        require(filledBuyerAssets <= maxBuyerAssets, BuyerAssetsTooHigh());
    }

    /// @dev Sells credit of the adapter's parent vault by taking buy offers until the vault has received exactly
    /// targetSellerAssets, or the call reverts with OutOfOffers.
    /// @dev The adapter sells at most maxUnits, or the call reverts with UnitsTooHigh.
    /// @dev Does not withdraw already-repaid credit first.
    function midnightAdapterBundlesV1SellWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(IMidnightAdapter(adapter).parentVault()).isAllocator(msg.sender), Unauthorized());
        // touchMarket to have the correct settlement fees.
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        uint256 filledUnits;
        uint256 filledSellerAssets;
        for (uint256 i; i < offerFills.length && filledSellerAssets < targetSellerAssets; i++) {
            OfferFill memory fill = offerFills[i];
            require(fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            uint256 unitsToTake = min(
                TakeAmountsLib.sellerAssetsToUnits(MIDNIGHT, id, fill.offer, targetSellerAssets - filledSellerAssets),
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer),
                fill.offer.reduceOnly ? IMidnight(MIDNIGHT).debt(id, fill.offer.maker) : type(uint256).max,
                TakeAmountsLib.buyerAssetsToUnits(MIDNIGHT, id, fill.offer, buyerAssetsBound(id, fill.offer))
            );
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapter(adapter).take(fill.offer, fill.ratifierData, unitsToTake, "") returns (
                uint256, uint256 resSellerAssets
            ) {
                filledUnits += unitsToTake;
                filledSellerAssets += resSellerAssets;
            } catch {}
        }

        require(filledSellerAssets == targetSellerAssets, OutOfOffers());
        require(filledUnits <= maxUnits, UnitsTooHigh());
    }

    /// @dev Sells exactly targetUnits of credit of the adapter's parent vault by taking buy offers.
    /// @dev targetUnits = type(uint256).max targets the adapter's credit in the market at execution.
    /// @dev The vault receives at least minSellerAssets, or the call reverts with SellerAssetsTooLow.
    /// @dev Does not withdraw already-repaid credit first.
    function midnightAdapterBundlesV1SellWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(IMidnightAdapter(adapter).parentVault()).isAllocator(msg.sender), Unauthorized());
        // touchMarket to have the correct settlement fees.
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        if (targetUnits == type(uint256).max) targetUnits = credit(market, id, adapter);

        uint256 filledUnits;
        uint256 filledSellerAssets;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            OfferFill memory fill = offerFills[i];
            require(fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            uint256 unitsToTake = min(
                targetUnits - filledUnits,
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer),
                fill.offer.reduceOnly ? IMidnight(MIDNIGHT).debt(id, fill.offer.maker) : type(uint256).max,
                TakeAmountsLib.buyerAssetsToUnits(MIDNIGHT, id, fill.offer, buyerAssetsBound(id, fill.offer))
            );
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapter(adapter).take(fill.offer, fill.ratifierData, unitsToTake, "") returns (
                uint256, uint256 resSellerAssets
            ) {
                filledUnits += unitsToTake;
                filledSellerAssets += resSellerAssets;
            } catch {}
        }

        require(filledUnits == targetUnits, OutOfOffers());
        require(filledSellerAssets >= minSellerAssets, SellerAssetsTooLow());
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns user's credit on market, after fee accrual and slashing.
    function credit(Market memory market, bytes32 id, address user) internal view returns (uint256) {
        (uint128 userCredit,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, user);
        return userCredit;
    }

    /// @dev Returns the maker's callback funding cap in buyer assets for a buy offer.
    function buyerAssetsBound(bytes32 id, Offer memory offer) internal view returns (uint256) {
        if (offer.callback == address(0)) return type(uint128).max;
        try IBuyerAssetsBound(offer.callback)
            .buyerAssetsBound(id, offer.market, offer.maker, offer.callbackData) returns (
            uint256 bound
        ) {
            return UtilsLib.min(bound, type(uint128).max);
        } catch {
            return type(uint128).max;
        }
    }

    /// @dev Returns min(x, y, z, w).
    function min(uint256 x, uint256 y, uint256 z, uint256 w) internal pure returns (uint256) {
        return UtilsLib.min(UtilsLib.min(x, y), UtilsLib.min(z, w));
    }

    /// @dev Returns min(x, y, z, w, v).
    function min(uint256 x, uint256 y, uint256 z, uint256 w, uint256 v) internal pure returns (uint256) {
        return UtilsLib.min(min(x, y, z, w), v);
    }
}
