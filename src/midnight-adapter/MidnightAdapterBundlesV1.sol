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

/// @dev This contract enables Midnight batch-takes for a Vault V2 through its MidnightAdapter, including the withdrawal of repaid credit at face value.
/// @dev It is the take side of MidnightBundlesV2, with MidnightAdapter.take in place of Midnight.take and VaultV2.deallocate in place of Midnight.withdraw.
/// @dev msg.sender must be an allocator of the adapter's parent vault. The vault is always read from the adapter, never passed by the caller.
/// @dev This contract must be an allocator of the vault beforehand.
/// @dev The adapter must be a MidnightAdapter whose take returns the buyer and seller assets.
/// @dev The adapter's and the vault's checks (caps, maxTtm, minNetBuyRate, maxNetSellRate, shortfallAllowance, forceSellable) apply to every take.
/// @dev This contract holds no tokens and gives no approvals: the vault pays and receives through the adapter.
/// @dev Because takes can make arbitrary calls, all entrypoints remain locked throughout the call to this contract.
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

    // Only touched offers are checked to point to the given market.
    // The buy/sell functions below skip the offer if the take reverted, including when the adapter or the vault rejects it. This avoids reverting the whole call when other offers passed as argument still have liquidity.
    // The vault is always the tokens payer (for buy) and the tokens receiver (for sell and withdraw), through the adapter.
    // Offers are taken in the order they are passed. One sensible strategy is to sort them by price (increasing to buy, decreasing to sell).
    // offerFills[i].units should prevent taking more than what is takeable w.r.t. the callback / the balances / the health.
    // For the buy functions below, the current market continuous fee must be at most maxContinuousFee when taking offers.
    // For the buy functions below, takerCallbackData is forwarded to the adapter and selects the funding source: abi.encode(address(0), "") for the vault's idle assets.

    /// @dev The vault will pay at most maxBuyerAssets.
    /// @dev The adapter will gain exactly targetUnits.
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

    /// @dev The vault will receive at least minSellerAssets.
    /// @dev If the adapter has credit, as much credit as possible is withdrawn to the vault before the take loop.
    /// @dev targetUnits = type(uint256).max targets the adapter's credit before withdrawing and taking offers.
    function midnightAdapterBundlesV1SellWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        // The same vault is used for the allocator check and for the withdrawal.
        address vault = IMidnightAdapter(adapter).parentVault();
        require(IVaultV2(vault).isAllocator(msg.sender), Unauthorized());
        // touchMarket to have the correct settlement fees.
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        uint256 currentCredit = credit(market, id, adapter);
        if (targetUnits == type(uint256).max) targetUnits = currentCredit;

        uint256 withdrawUnits = min(targetUnits, currentCredit, IMidnight(MIDNIGHT).withdrawable(id));
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        if (withdrawUnits > 0) IVaultV2(vault).deallocate(adapter, abi.encode(market), withdrawUnits);
        uint256 filledUnits = withdrawUnits;
        uint256 filledSellerAssets = withdrawUnits;
        for (uint256 i; i < offerFills.length && filledUnits < targetUnits; i++) {
            OfferFill memory fill = offerFills[i];
            require(fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            uint256 unitsToTake = min(
                targetUnits - filledUnits,
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer),
                fill.offer.reduceOnly ? debt(id, fill.offer.maker) : type(uint256).max,
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

    /// @dev Total loan assets paid by the vault is targetBuyerAssets.
    /// @dev The adapter will gain at least minUnits.
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

    /// @dev Total loan assets received by the vault is targetSellerAssets.
    /// @dev If the adapter has credit, as much credit as possible is withdrawn to the vault before the take loop.
    /// @dev The adapter will lose at most maxUnits.
    function midnightAdapterBundlesV1SellWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        // The same vault is used for the allocator check and for the withdrawal.
        address vault = IMidnightAdapter(adapter).parentVault();
        require(IVaultV2(vault).isAllocator(msg.sender), Unauthorized());
        // touchMarket to have the correct settlement fees.
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        bytes32 id = IMidnight(MIDNIGHT).touchMarket(market);

        uint256 withdrawUnits =
            min(targetSellerAssets, credit(market, id, adapter), IMidnight(MIDNIGHT).withdrawable(id));
        // forge-lint: disable-next-line(reentrancy-no-eth) The entrypoint lock remains active.
        if (withdrawUnits > 0) IVaultV2(vault).deallocate(adapter, abi.encode(market), withdrawUnits);
        uint256 filledUnits = withdrawUnits;
        uint256 filledSellerAssets = withdrawUnits;
        for (uint256 i; i < offerFills.length && filledSellerAssets < targetSellerAssets; i++) {
            OfferFill memory fill = offerFills[i];
            require(fill.offer.buy, InconsistentSide());
            require(IdLib.toId(fill.offer.market) == id, InconsistentMarket());
            uint256 unitsToTake = min(
                TakeAmountsLib.sellerAssetsToUnits(MIDNIGHT, id, fill.offer, targetSellerAssets - filledSellerAssets),
                fill.units,
                ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, fill.offer),
                fill.offer.reduceOnly ? debt(id, fill.offer.maker) : type(uint256).max,
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

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns user's credit on market, after fee accrual and slashing.
    function credit(Market memory market, bytes32 id, address user) internal view returns (uint256) {
        (uint128 userCredit,,) = IMidnight(MIDNIGHT).updatePositionView(market, id, user);
        return userCredit;
    }

    /// @dev Returns user's debt on market.
    function debt(bytes32 id, address user) internal view returns (uint256) {
        return IMidnight(MIDNIGHT).debt(id, user);
    }

    /// @dev Returns the maker's callback funding cap in buyer assets for a buy offer.
    /// @dev Buy offers already limit buyer assets to uint128.max through maxAssets or maxUnits and buyerPrice <= WAD.
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

    /// @dev Returns min(x, y, z).
    function min(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return UtilsLib.min(UtilsLib.min(x, y), z);
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
