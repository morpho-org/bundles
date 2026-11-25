// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Offer} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {TickLib, MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {WAD, CBP, DEFAULT_TICK_SPACING, maxSettlementFee} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {TakeAmountsLib} from "../lib/midnight/src/periphery/libraries/TakeAmountsLib.sol";
import {ConsumableUnitsLib} from "../lib/midnight/src/periphery/libraries/ConsumableUnitsLib.sol";
import {IMidnightAdapterBundlesV1} from "../src/midnight-adapter/interfaces/IMidnightAdapterBundlesV1.sol";
import {OfferFill} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";
import {MidnightAdapterBundlesV1Setup} from "./MidnightAdapterBundlesV1Test.sol";

/// @dev Rounding and boundary tests of the four entry points, with fuzzed tick, settlement fees, time to maturity,
/// targets from 1 wei, per-offer caps in units or assets, and fill.units.
/// @dev Sales go through the adapter's guardrails, opened up as in the full-exit test (maxNetSellRate =
/// type(uint64).max, shortfallAllowance = type(uint128).max). The one rule left is in MidnightAdapter.onSell:
/// sellerAssets >= ceil(soldNetCredit * WAD / (WAD + maxNetSellRate * ttm)). With the continuous fee at 0,
/// soldNetCredit is the units sold. It rejects a sale paying 0 assets (one unit at a price below 1, for example), and
/// at maturity (ttm = 0) any sale below face value. Sell fuzz inputs are excluded exactly when a take breaks it.
contract MidnightAdapterBundlesV1RoundingTest is MidnightAdapterBundlesV1Setup {
    using UtilsLib for uint256;

    uint256 internal constant MAX_TARGET = 100_000e18;
    uint256 internal constant MAX_NET_SELL_RATE = type(uint64).max;

    uint256 internal minTick;
    uint256 internal minSaleTick;

    function setUp() public override {
        super.setUp();
        relaxSaleGuardrails();
        // Enough collateral for any sell offer of the borrower in these tests.
        collateralize(borrower, 1e27);
        minTick = tickAt(0.5e18);
        minSaleTick = tickAt(0.52e18);
    }

    /// HELPERS ///

    function tickAt(uint256 price) internal pure returns (uint256) {
        return TickLib.priceToTick(price, DEFAULT_TICK_SPACING);
    }

    /// @dev A tick valid for the market's spacing, with a price in [0.5, 1].
    function fuzzTick(uint256 seed) internal view returns (uint256) {
        uint256 tick = bound(seed, minTick, MAX_TICK);
        return tick - tick % DEFAULT_TICK_SPACING;
    }

    /// @dev A tick valid for the market's spacing, with a price in [0.52, 1]. The vault's credit is bought at 0.5 plus
    /// at most 0.005 of settlement fee, and a buy offer pays its price minus at most 0.005, so sales never fall below
    /// the vault's cost. Sales below cost have a shortfall, and MidnightAdapter.onSell rejects a shortfall larger than
    /// the interest left to earn (ShortfallTooHigh), which shrinks to 0 as the vault sells its last credit.
    function fuzzSaleTick(uint256 seed) internal view returns (uint256) {
        uint256 tick = bound(seed, minSaleTick, MAX_TICK);
        return tick - tick % DEFAULT_TICK_SPACING;
    }

    /// @dev Sets each settlement fee point between zero and its max, and warps to `ttm` before maturity.
    function configure(uint256 feeSeed, uint256 ttm) internal {
        for (uint256 i; i <= 6; i++) {
            uint256 cbps = bound(uint256(keccak256(abi.encode(feeSeed, i))), 0, maxSettlementFee(i) / CBP);
            midnight.setMarketSettlementFee(id, i, cbps * CBP);
        }
        vm.warp(market.maturity - ttm);
    }

    function fee() internal view returns (uint256) {
        return midnight.settlementFee(id, market.maturity.zeroFloorSub(vm.getBlockTimestamp()));
    }

    function capOffer(Offer memory offer, bool capIsAssets, uint256 cap) internal pure returns (Offer memory) {
        offer.maxUnits = capIsAssets ? 0 : uint128(cap);
        offer.maxAssets = capIsAssets ? uint128(cap) : 0;
        return offer;
    }

    /// @dev A capped sell offer with fuzzed fill.units, then an uncapped one: the target can always be filled.
    function sellFills(uint256 tick, bool capIsAssets, uint256 cap, uint256 fillUnits)
        internal
        view
        returns (OfferFill[] memory fills)
    {
        fills = new OfferFill[](2);
        fills[0].offer = capOffer(sellOffer(bytes32(uint256(41))), capIsAssets, cap);
        fills[0].offer.tick = tick;
        fills[0].units = fillUnits;
        fills[1].offer = capOffer(sellOffer(bytes32(uint256(42))), false, type(uint128).max);
        fills[1].offer.tick = tick;
        fills[1].units = type(uint256).max;
    }

    function buyFills(uint256 tick, bool capIsAssets, uint256 cap, uint256 fillUnits)
        internal
        view
        returns (OfferFill[] memory fills)
    {
        fills = new OfferFill[](2);
        fills[0].offer = capOffer(buyOffer(bytes32(uint256(61))), capIsAssets, cap);
        fills[0].offer.tick = tick;
        fills[0].units = fillUnits;
        fills[1].offer = capOffer(buyOffer(bytes32(uint256(62))), false, type(uint128).max);
        fills[1].offer.tick = tick;
        fills[1].units = type(uint256).max;
    }

    function single(OfferFill memory fill) internal pure returns (OfferFill[] memory fills) {
        fills = new OfferFill[](1);
        fills[0] = fill;
    }

    /// @dev Gives the vault credit to sell: buys 50k assets at 0.5 at the current time.
    function preBuy() internal returns (uint256 credit) {
        OfferFill[] memory fills = new OfferFill[](1);
        fills[0].offer = capOffer(sellOffer(bytes32(uint256(51))), false, type(uint128).max);
        fills[0].offer.tick = minTick;
        fills[0].units = type(uint256).max;
        buyWithAssets(allocator, 50_000e18, 0, fills);
        credit = creditOf(address(adapter));
    }

    function sellerAssetsOf(Offer memory offer, uint256 units) internal view returns (uint256) {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        uint256 sellerPrice = offer.buy ? offerPrice - fee() : offerPrice;
        return offer.buy ? units.mulDivDown(sellerPrice, WAD) : units.mulDivUp(sellerPrice, WAD);
    }

    function buyerAssetsOf(Offer memory offer, uint256 units) internal view returns (uint256) {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        uint256 buyerPrice = offer.buy ? offerPrice : offerPrice + fee();
        return offer.buy ? units.mulDivDown(buyerPrice, WAD) : units.mulDivUp(buyerPrice, WAD);
    }

    /// @dev The adapter's sale rule, see the contract's comment.
    function saleAccepted(Offer memory offer, uint256 units) internal view returns (bool) {
        uint256 ttm = market.maturity.zeroFloorSub(vm.getBlockTimestamp());
        return sellerAssetsOf(offer, units) >= units.mulDivUp(WAD, WAD + MAX_NET_SELL_RATE * ttm);
    }

    /// @dev Whether every take of a two-offer sell walk passes the sale rule. Mirrors the walk: if the first take is
    /// rejected, the second offer is asked for the whole target.
    function sellWalkAccepted(OfferFill[] memory fills, uint256 target, bool assetsTarget)
        internal
        view
        returns (bool)
    {
        uint256 first = UtilsLib.min(
            UtilsLib.min(
                assetsTarget
                    ? TakeAmountsLib.sellerAssetsToUnits(address(midnight), id, fills[0].offer, target)
                    : target,
                fills[0].units
            ),
            ConsumableUnitsLib.consumableUnits(address(midnight), id, fills[0].offer)
        );
        uint256 rest;
        if (saleAccepted(fills[0].offer, first)) {
            uint256 filled = assetsTarget ? sellerAssetsOf(fills[0].offer, first) : first;
            if (filled >= target) return true;
            rest = target - filled;
        } else {
            rest = target;
        }
        uint256 second =
            assetsTarget ? TakeAmountsLib.sellerAssetsToUnits(address(midnight), id, fills[1].offer, rest) : rest;
        return saleAccepted(fills[1].offer, second);
    }

    function callBuyUnits(uint256 target, uint256 maxBuyerAssets, OfferFill[] memory fills) internal {
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            target,
            maxBuyerAssets,
            fills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
    }

    function callSellAssets(uint256 target, uint256 maxUnits, OfferFill[] memory fills) internal {
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter), market, target, maxUnits, fills, vm.getBlockTimestamp()
        );
    }

    function callSellUnits(uint256 target, uint256 minSellerAssets, OfferFill[] memory fills) internal {
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, target, minSellerAssets, fills, vm.getBlockTimestamp()
        );
    }

    /// FUZZ: BUY WITH ASSETS TARGET ///

    function testFuzzBuyWithAssetsTarget(
        uint256 tickSeed,
        uint256 feeSeed,
        uint256 ttm,
        uint256 target,
        bool capIsAssets,
        uint256 cap,
        uint256 fillUnits
    ) public {
        ttm = bound(ttm, 0, 30 days);
        configure(feeSeed, ttm);
        uint256 tick = fuzzTick(tickSeed);
        vm.assume(TickLib.tickToPrice(tick) + fee() <= WAD);
        target = bound(target, 1, MAX_TARGET);
        OfferFill[] memory fills =
            sellFills(tick, capIsAssets, bound(cap, 1, 2 * OFFER_UNITS), bound(fillUnits, 0, 2 * OFFER_UNITS));

        if (ttm == 0) {
            // The adapter refuses buys at maturity.
            vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
            buyWithAssets(allocator, target, 0, fills);
            return;
        }

        uint256 snapshot = vm.snapshotState();
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        buyWithAssets(allocator, target, 0, fills);
        TakeTotals memory totals = sumTakeEvents();
        uint256 units = creditOf(address(adapter));

        assertEq(vaultBalanceBefore - loanToken.balanceOf(address(vault)), target, "vault spent exactly the target");
        assertEq(totals.buyerAssets, target, "Take events sum to the target");
        assertEq(totals.units, units, "credit = units taken");
        assertBundleHoldsNothing();

        vm.revertToState(snapshot);
        vm.expectRevert(IMidnightAdapterBundlesV1.UnitsTooLow.selector);
        buyWithAssets(allocator, target, units + 1, fills);
        buyWithAssets(allocator, target, units, fills);
    }

    /// @dev On one uncapped offer, the bundle takes the largest units whose cost is at most the target.
    function testFuzzBuyWithAssetsTargetDirection(uint256 tickSeed, uint256 feeSeed, uint256 ttm, uint256 target)
        public
    {
        configure(feeSeed, bound(ttm, 1, 30 days));
        uint256 tick = fuzzTick(tickSeed);
        vm.assume(TickLib.tickToPrice(tick) + fee() <= WAD);
        target = bound(target, 1, MAX_TARGET);
        OfferFill[] memory fills = sellFills(tick, false, 1, 0);

        buyWithAssets(allocator, target, 0, single(fills[1]));
        uint256 units = creditOf(address(adapter));

        assertEq(buyerAssetsOf(fills[1].offer, units), target, "cost of the units taken is the target");
        assertGt(buyerAssetsOf(fills[1].offer, units + 1), target, "one more unit costs more than the target");
    }

    /// FUZZ: BUY WITH UNITS TARGET ///

    function testFuzzBuyWithUnitsTarget(
        uint256 tickSeed,
        uint256 feeSeed,
        uint256 ttm,
        uint256 target,
        bool capIsAssets,
        uint256 cap,
        uint256 fillUnits
    ) public {
        ttm = bound(ttm, 0, 30 days);
        configure(feeSeed, ttm);
        uint256 tick = fuzzTick(tickSeed);
        vm.assume(TickLib.tickToPrice(tick) + fee() <= WAD);
        target = bound(target, 1, MAX_TARGET);
        OfferFill[] memory fills =
            sellFills(tick, capIsAssets, bound(cap, 1, 2 * OFFER_UNITS), bound(fillUnits, 0, 2 * OFFER_UNITS));

        if (ttm == 0) {
            vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
            callBuyUnits(target, type(uint256).max, fills);
            return;
        }

        uint256 snapshot = vm.snapshotState();
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        callBuyUnits(target, type(uint256).max, fills);
        TakeTotals memory totals = sumTakeEvents();
        uint256 spent = vaultBalanceBefore - loanToken.balanceOf(address(vault));

        assertEq(creditOf(address(adapter)), target, "credit changed by exactly the target");
        assertEq(totals.units, target, "Take events sum to the target");
        assertEq(totals.buyerAssets, spent, "vault spent the Take events' buyer assets");
        assertBundleHoldsNothing();

        vm.revertToState(snapshot);
        vm.expectRevert(IMidnightAdapterBundlesV1.BuyerAssetsTooHigh.selector);
        callBuyUnits(target, spent - 1, fills);
        callBuyUnits(target, spent, fills);
    }

    /// FUZZ: SELL WITH ASSETS TARGET ///

    function testFuzzSellWithAssetsTarget(
        uint256 tickSeed,
        uint256 feeSeed,
        uint256 ttm,
        uint256 target,
        bool capIsAssets,
        uint256 cap,
        uint256 fillUnits
    ) public {
        configure(feeSeed, bound(ttm, 1, 30 days));
        uint256 credit = preBuy();
        uint256 tick = fuzzSaleTick(tickSeed);
        // Sales of up to 40k assets at a seller price of at least 0.495 stay within the ~99k units of credit.
        target = bound(target, 1, 40_000e18);
        OfferFill[] memory fills =
            buyFills(tick, capIsAssets, bound(cap, 1, 2 * OFFER_UNITS), bound(fillUnits, 0, 2 * OFFER_UNITS));
        vm.assume(sellWalkAccepted(fills, target, true));

        uint256 snapshot = vm.snapshotState();
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        callSellAssets(target, type(uint256).max, fills);
        TakeTotals memory totals = sumTakeEvents();
        uint256 units = credit - creditOf(address(adapter));

        assertEq(loanToken.balanceOf(address(vault)) - vaultBalanceBefore, target, "vault received exactly the target");
        assertEq(totals.sellerAssets, target, "Take events sum to the target");
        assertEq(totals.units, units, "credit sold = units taken");
        assertBundleHoldsNothing();

        vm.revertToState(snapshot);
        vm.expectRevert(IMidnightAdapterBundlesV1.UnitsTooHigh.selector);
        callSellAssets(target, units - 1, fills);
        callSellAssets(target, units, fills);
    }

    /// @dev On one uncapped offer, the bundle takes the smallest units whose proceeds reach the target.
    function testFuzzSellWithAssetsTargetDirection(uint256 tickSeed, uint256 feeSeed, uint256 ttm, uint256 target)
        public
    {
        configure(feeSeed, bound(ttm, 1, 30 days));
        uint256 credit = preBuy();
        target = bound(target, 1, 40_000e18);
        OfferFill[] memory fills = buyFills(fuzzSaleTick(tickSeed), false, 1, 0);
        uint256 units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), id, fills[1].offer, target);
        vm.assume(saleAccepted(fills[1].offer, units));

        callSellAssets(target, type(uint256).max, single(fills[1]));
        units = credit - creditOf(address(adapter));

        assertEq(sellerAssetsOf(fills[1].offer, units), target, "proceeds of the units taken are the target");
        assertLt(sellerAssetsOf(fills[1].offer, units - 1), target, "one fewer unit pays less than the target");
    }

    /// FUZZ: SELL WITH UNITS TARGET ///

    function testFuzzSellWithUnitsTarget(
        uint256 tickSeed,
        uint256 feeSeed,
        uint256 ttm,
        uint256 target,
        bool capIsAssets,
        uint256 cap,
        uint256 fillUnits
    ) public {
        configure(feeSeed, bound(ttm, 1, 30 days));
        uint256 credit = preBuy();
        uint256 tick = fuzzSaleTick(tickSeed);
        target = bound(target, 1, credit);
        OfferFill[] memory fills =
            buyFills(tick, capIsAssets, bound(cap, 1, 2 * OFFER_UNITS), bound(fillUnits, 0, 2 * OFFER_UNITS));
        vm.assume(sellWalkAccepted(fills, target, false));

        uint256 snapshot = vm.snapshotState();
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        callSellUnits(target, 0, fills);
        TakeTotals memory totals = sumTakeEvents();
        uint256 received = loanToken.balanceOf(address(vault)) - vaultBalanceBefore;

        assertEq(credit - creditOf(address(adapter)), target, "credit changed by exactly the target");
        assertEq(totals.units, target, "Take events sum to the target");
        assertEq(totals.sellerAssets, received, "vault received the Take events' seller assets");
        assertBundleHoldsNothing();

        vm.revertToState(snapshot);
        vm.expectRevert(IMidnightAdapterBundlesV1.SellerAssetsTooLow.selector);
        callSellUnits(target, received + 1, fills);
        callSellUnits(target, received, fills);
    }

    /// BOUNDARIES ///

    function defaultSellFills() internal view returns (OfferFill[] memory) {
        return sellFills(sellTick, false, OFFER_UNITS, type(uint256).max);
    }

    function defaultBuyFills() internal view returns (OfferFill[] memory) {
        return buyFills(buyTick, false, OFFER_UNITS, type(uint256).max);
    }

    function testOneWeiTargets() public {
        uint256 balance = loanToken.balanceOf(address(vault));
        buyWithAssets(allocator, 1, 0, defaultSellFills());
        assertEq(balance - loanToken.balanceOf(address(vault)), 1, "buy with assets: 1 wei spent");

        uint256 credit = creditOf(address(adapter));
        callBuyUnits(1, type(uint256).max, defaultSellFills());
        assertEq(creditOf(address(adapter)), credit + 1, "buy with units: 1 unit bought");

        credit = preBuy();
        balance = loanToken.balanceOf(address(vault));
        callSellAssets(1, type(uint256).max, defaultBuyFills());
        assertEq(loanToken.balanceOf(address(vault)) - balance, 1, "sell with assets: 1 wei received");
        // Two units at ~0.99 pay 1 wei.
        assertEq(credit - creditOf(address(adapter)), 2, "sell with assets: 2 units sold");

        // One unit at a price below 1 pays 0 assets: the adapter's sale rule rejects it.
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callSellUnits(1, 0, defaultBuyFills());
    }

    function testTargetEqualToOneOfferThenOneWeiAbove() public {
        OfferFill[] memory fills = defaultSellFills();
        uint256 snapshot = vm.snapshotState();

        // Units: exactly the first offer, then one unit more spills into the second.
        vm.recordLogs();
        callBuyUnits(OFFER_UNITS, type(uint256).max, fills);
        assertEq(sumTakeEvents().count, 1, "buy units: one take");
        vm.revertToState(snapshot);
        vm.recordLogs();
        callBuyUnits(OFFER_UNITS + 1, type(uint256).max, fills);
        TakeTotals memory totals = sumTakeEvents();
        assertEq(totals.count, 2, "buy units: spills into the second offer");
        assertEq(midnight.consumed(borrower, fills[1].offer.group), 1, "buy units: one unit from the second offer");

        // Assets: exactly the cost of the first offer, then one wei more.
        uint256 fullCost = buyerAssetsOf(fills[0].offer, OFFER_UNITS);
        vm.revertToState(snapshot);
        vm.recordLogs();
        buyWithAssets(allocator, fullCost, 0, fills);
        assertEq(sumTakeEvents().count, 1, "buy assets: one take");
        assertEq(midnight.consumed(borrower, fills[0].offer.group), OFFER_UNITS, "buy assets: first offer full");
        vm.revertToState(snapshot);
        vm.recordLogs();
        buyWithAssets(allocator, fullCost + 1, 0, fills);
        assertEq(sumTakeEvents().count, 2, "buy assets: spills into the second offer");

        // Sells: exactly the first buy offer, then one more.
        vm.revertToState(snapshot);
        preBuy();
        uint256 sellSnapshot = vm.snapshotState();
        OfferFill[] memory buys = defaultBuyFills();
        vm.recordLogs();
        callSellUnits(OFFER_UNITS, 0, buys);
        assertEq(sumTakeEvents().count, 1, "sell units: one take");
        vm.revertToState(sellSnapshot);
        // One more unit pays 0 assets, which the adapter's sale rule rejects.
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callSellUnits(OFFER_UNITS + 1, 0, buys);

        uint256 fullProceeds = sellerAssetsOf(buys[0].offer, OFFER_UNITS);
        vm.recordLogs();
        callSellAssets(fullProceeds, type(uint256).max, buys);
        assertEq(sumTakeEvents().count, 1, "sell assets: one take");
        vm.revertToState(sellSnapshot);
        vm.recordLogs();
        callSellAssets(fullProceeds + 1, type(uint256).max, buys);
        assertEq(sumTakeEvents().count, 2, "sell assets: spills into the second offer");
    }

    function testZeroTargetsSucceedWithoutTaking() public {
        preBuy();
        uint256 credit = creditOf(address(adapter));
        uint256 balance = loanToken.balanceOf(address(vault));

        vm.recordLogs();
        buyWithAssets(allocator, 0, 0, defaultSellFills());
        callBuyUnits(0, 0, defaultSellFills());
        callSellAssets(0, 0, defaultBuyFills());
        callSellUnits(0, 0, defaultBuyFills());
        // Empty offerFills with a zero target succeed too.
        buyWithAssets(allocator, 0, 0, new OfferFill[](0));
        callSellUnits(0, 0, new OfferFill[](0));

        assertEq(sumTakeEvents().count, 0, "no take");
        assertEq(creditOf(address(adapter)), credit, "credit unchanged");
        assertEq(loanToken.balanceOf(address(vault)), balance, "vault unchanged");
    }

    function testEmptyOfferFillsRevert() public {
        preBuy();
        OfferFill[] memory empty = new OfferFill[](0);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 1, 0, empty);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callBuyUnits(1, type(uint256).max, empty);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callSellAssets(1, type(uint256).max, empty);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callSellUnits(1, 0, empty);
    }

    function testFillUnitsZeroTakesNothing() public {
        preBuy();
        OfferFill[] memory sells = defaultSellFills();
        sells[0].units = 0;
        OfferFill[] memory buys = defaultBuyFills();
        buys[0].units = 0;

        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 1e18, 0, single(sells[0]));
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callSellUnits(1e18, 0, single(buys[0]));

        // With a second offer, the whole order comes from it.
        vm.recordLogs();
        buyWithAssets(allocator, 1e18, 0, sells);
        assertEq(sumTakeEvents().count, 1, "one take");
        assertEq(midnight.consumed(borrower, sells[0].offer.group), 0, "nothing from the first offer");
    }

    function testLastSecondAndAtMaturity() public {
        vm.warp(market.maturity - 1);
        uint256 balance = loanToken.balanceOf(address(vault));
        buyWithAssets(allocator, 1e18, 0, defaultSellFills());
        assertEq(balance - loanToken.balanceOf(address(vault)), 1e18, "buy in the last second");
        callSellAssets(0.5e18, type(uint256).max, defaultBuyFills());

        vm.warp(market.maturity);
        // At maturity the adapter refuses buys, and sales below face value break its sale rule.
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 1e18, 0, defaultSellFills());
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        callSellUnits(0.1e18, 0, defaultBuyFills());
    }
}
