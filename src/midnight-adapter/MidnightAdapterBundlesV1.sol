// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IBuyerAssetsBound} from "../../lib/midnight/src/interfaces/ICallbacks.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {TickLib} from "../../lib/midnight/src/libraries/TickLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {TakeAmountsLib} from "../../lib/midnight/src/periphery/libraries/TakeAmountsLib.sol";
import {ConsumableUnitsLib} from "../../lib/midnight/src/periphery/libraries/ConsumableUnitsLib.sol";
import {OfferFill} from "../midnight/interfaces/IMidnightBundlesV2.sol";
import {IMidnightAdapterBundlesV1} from "./interfaces/IMidnightAdapterBundlesV1.sol";

/// @dev Minimal view of a Vault V2 MidnightAdapter, so this contract does not import vault-v2 types.
interface IMidnightAdapterMinimal {
    function parentVault() external view returns (address);
    function take(Offer memory offer, bytes calldata ratifierData, uint256 units, bytes calldata takerCallbackData)
        external;
}

/// @dev Minimal view of a Vault V2.
interface IVaultV2Minimal {
    function isAllocator(address account) external view returns (bool);
}

/// @dev Lets an allocator of a Vault V2 take several Midnight offers through the vault's MidnightAdapter in one
/// transaction, with slippage protection. The take side of MidnightBundlesV2, pointed at MidnightAdapter.take.
/// @dev The only access rule: msg.sender must be an allocator of adapter.parentVault(). The vault is always read from
/// the adapter. Every other rule (the bundle being an allocator, caps, maxTtm, rate guardrails, shortfall allowance)
/// is enforced by the adapter and the vault; a take they reject reverts and is skipped.
/// @dev Holds no tokens, gives no approvals, has no storage besides the transient lock.
/// @dev Offers are taken in the order they are passed. Only touched offers are checked to point to the given market.
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

    /// @inheritdoc IMidnightAdapterBundlesV1
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
        bytes32 id = checkAndTouch(adapter, market, deadline);

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
            // Read right before the take: nothing state-changing runs between this read and Midnight's own.
            (uint256 buyerAssets,) = takeAssets(id, fill.offer, unitsToTake);
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapterMinimal(adapter).take(fill.offer, fill.ratifierData, unitsToTake, takerCallbackData) {
                filledUnits += unitsToTake;
                filledBuyerAssets += buyerAssets;
            } catch {}
        }

        require(filledBuyerAssets == targetBuyerAssets, OutOfOffers());
        require(filledUnits >= minUnits, UnitsTooLow());
    }

    /// @inheritdoc IMidnightAdapterBundlesV1
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
        bytes32 id = checkAndTouch(adapter, market, deadline);

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
            // Read right before the take: nothing state-changing runs between this read and Midnight's own.
            (uint256 buyerAssets,) = takeAssets(id, fill.offer, unitsToTake);
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapterMinimal(adapter).take(fill.offer, fill.ratifierData, unitsToTake, takerCallbackData) {
                filledUnits += unitsToTake;
                filledBuyerAssets += buyerAssets;
            } catch {}
        }

        require(filledUnits == targetUnits, OutOfOffers());
        require(filledBuyerAssets <= maxBuyerAssets, BuyerAssetsTooHigh());
    }

    /// @inheritdoc IMidnightAdapterBundlesV1
    function midnightAdapterBundlesV1SellWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external nonReentrant {
        bytes32 id = checkAndTouch(adapter, market, deadline);

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
            // Read right before the take: nothing state-changing runs between this read and Midnight's own.
            (, uint256 sellerAssets) = takeAssets(id, fill.offer, unitsToTake);
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapterMinimal(adapter).take(fill.offer, fill.ratifierData, unitsToTake, "") {
                filledUnits += unitsToTake;
                filledSellerAssets += sellerAssets;
            } catch {}
        }

        require(filledSellerAssets == targetSellerAssets, OutOfOffers());
        require(filledUnits <= maxUnits, UnitsTooHigh());
    }

    /// @inheritdoc IMidnightAdapterBundlesV1
    function midnightAdapterBundlesV1SellWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external nonReentrant {
        bytes32 id = checkAndTouch(adapter, market, deadline);

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
            // Read right before the take: nothing state-changing runs between this read and Midnight's own.
            (, uint256 sellerAssets) = takeAssets(id, fill.offer, unitsToTake);
            // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the take.
            try IMidnightAdapterMinimal(adapter).take(fill.offer, fill.ratifierData, unitsToTake, "") {
                filledUnits += unitsToTake;
                filledSellerAssets += sellerAssets;
            } catch {}
        }

        require(filledUnits == targetUnits, OutOfOffers());
        require(filledSellerAssets >= minSellerAssets, SellerAssetsTooLow());
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Checks the deadline and that msg.sender is an allocator of the adapter's parent vault, then touches the
    /// market so that settlement fees are up to date, and returns its id.
    function checkAndTouch(address adapter, Market memory market, uint256 deadline) internal returns (bytes32) {
        require(block.timestamp <= deadline, DeadlinePassed());
        address vault = IMidnightAdapterMinimal(adapter).parentVault();
        require(IVaultV2Minimal(vault).isAllocator(msg.sender), Unauthorized());
        // forge-lint: disable-next-line(reentrancy-no-eth) The helper is only called from locked entrypoints.
        return IMidnight(MIDNIGHT).touchMarket(market);
    }

    /// @dev Returns (buyerAssets, sellerAssets) of a take of `units` of `offer`, with Midnight's own formula.
    /// @dev Called right before each take, so the settlement fee read is the one Midnight uses in that take.
    function takeAssets(bytes32 id, Offer memory offer, uint256 units) internal view returns (uint256, uint256) {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        uint256 settlementFee =
            IMidnight(MIDNIGHT).settlementFee(id, UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp));
        uint256 sellerPrice = offer.buy ? offerPrice - settlementFee : offerPrice;
        uint256 buyerPrice = sellerPrice + settlementFee;
        uint256 buyerAssets = offer.buy ? units.mulDivDown(buyerPrice, WAD) : units.mulDivUp(buyerPrice, WAD);
        uint256 sellerAssets = offer.buy ? units.mulDivDown(sellerPrice, WAD) : units.mulDivUp(sellerPrice, WAD);
        return (buyerAssets, sellerAssets);
    }

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
