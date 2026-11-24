// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Vm} from "../lib/forge-std/src/Test.sol";
import {Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {IMidnight} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {EventsLib} from "../lib/midnight/src/libraries/EventsLib.sol";
import {TickLib} from "../lib/midnight/src/libraries/TickLib.sol";
import {
    CALLBACK_SUCCESS,
    WAD,
    ORACLE_PRICE_SCALE,
    DEFAULT_TICK_SPACING,
    maxSettlementFee
} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ITestToken, TokenTest} from "./helpers/TokenTest.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {MidnightAdapterBundlesV1} from "../src/midnight-adapter/MidnightAdapterBundlesV1.sol";
import {IMidnightAdapterBundlesV1} from "../src/midnight-adapter/interfaces/IMidnightAdapterBundlesV1.sol";
import {OfferFill} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";

/// @dev The parts of MidnightAdapter the tests use, typed with this repo's copy of Midnight's types.
interface ITestMidnightAdapter {
    function parentVault() external view returns (address);
    function submit(bytes calldata data) external;
    function increaseMaxTtm(uint256 newMaxTtm) external;
    function increaseMaxNetSellRate(uint256 newMaxNetSellRate) external;
    function increaseShortfallAllowance(uint256 allowanceIncrease) external;
    function ids(Market memory market) external view returns (bytes32[] memory);
}

interface ITestMidnightAdapterFactory {
    function createMidnightAdapter(
        address parentVault,
        uint256[] calldata durations,
        address enterGateFactory,
        bytes32 preSalt
    ) external returns (address);
}

/// @dev Seller callback of a sell offer that tries to re-enter the bundle, and records how it was refused.
contract ReenteringSellCallback {
    MidnightAdapterBundlesV1 internal immutable bundle;
    address internal immutable adapter;
    bytes public lastRevertData;
    bool public reentered;

    constructor(MidnightAdapterBundlesV1 _bundle, address _adapter) {
        bundle = _bundle;
        adapter = _adapter;
    }

    function onSell(bytes32, Market memory market, uint256, uint256, uint256, address, address, bytes memory)
        external
        returns (bytes32)
    {
        reentered = true;
        try bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            adapter, market, 1, 0, new OfferFill[](0), abi.encode(address(0), bytes("")), 0, block.timestamp
        ) {}
        catch (bytes memory data) {
            lastRevertData = data;
        }
        return CALLBACK_SUCCESS;
    }
}

contract MidnightAdapterBundlesV1Test is TokenTest {
    using UtilsLib for uint256;

    uint256 internal constant VAULT_ASSETS = 1_000_000e18;
    uint256 internal constant OFFER_UNITS = 20_000e18;

    IMidnight internal midnight;
    IVaultV2Factory internal vaultFactory;
    ITestMidnightAdapterFactory internal adapterFactory;
    IVaultV2 internal vault;
    ITestMidnightAdapter internal adapter;
    MidnightAdapterBundlesV1 internal bundle;
    ITestToken internal loanToken;
    ITestToken internal collateralToken;
    Oracle internal oracle;
    DummyRatifier internal dummyRatifier;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal sentinel = makeAddr("sentinel");
    address internal stranger = makeAddr("stranger");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal depositor = makeAddr("depositor");

    Market internal market;
    bytes32 internal id;
    uint256 internal sellTick;
    uint256 internal buyTick;

    function setUp() public {
        midnight = IMidnight(deployCode("Midnight"));
        dummyRatifier = new DummyRatifier();
        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));
        midnight.enableLltv(0.77e18);
        midnight.enableLiquidationCursor(0.25e18);

        loanToken = deployToken("loan");
        collateralToken = deployToken("collat");
        oracle = new Oracle();

        // Settlement fees at their max, so the computed amounts exercise the fee.
        midnight.setFeeClaimer(makeAddr("feeClaimer"));
        for (uint256 i; i <= 6; i++) {
            midnight.setDefaultSettlementFee(address(loanToken), i, maxSettlementFee(i));
        }

        market.loanToken = address(loanToken);
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.maturity = vm.getBlockTimestamp() + 30 days;
        market.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken), lltv: 0.77e18, liquidationCursor: 0.25e18, oracle: address(oracle)
                })
            );
        id = midnight.touchMarket(market);
        sellTick = TickLib.priceToTick(0.98e18, DEFAULT_TICK_SPACING);
        buyTick = TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING);

        vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
        adapterFactory = ITestMidnightAdapterFactory(
            deployCode("MidnightAdapterFactory.sol:MidnightAdapterFactory", abi.encode(address(midnight)))
        );
        bundle = new MidnightAdapterBundlesV1(address(midnight));
        assertEq(bundle.MIDNIGHT(), address(midnight));

        (vault, adapter) = deployVaultWithAdapter(owner, curator, allocator, bytes32(0));
        submitAndExec(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(bundle), true)));
        vm.prank(owner);
        vault.setIsSentinel(sentinel, true);

        deal(address(loanToken), depositor, VAULT_ASSETS);
        vm.startPrank(depositor);
        safeApprove(loanToken, address(vault), VAULT_ASSETS);
        vault.deposit(VAULT_ASSETS, depositor);
        vm.stopPrank();

        // The borrower makes sell offers, the lender makes buy offers. Both use the DummyRatifier.
        vm.prank(borrower);
        midnight.setIsAuthorized(address(dummyRatifier), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(dummyRatifier), true, lender);
        collateralize(borrower, 2 * OFFER_UNITS);
        deal(address(loanToken), lender, type(uint128).max);
        vm.prank(lender);
        safeApprove(loanToken, address(midnight), type(uint256).max);
    }

    /// SETUP HELPERS ///

    /// @dev A real Vault V2 with a real MidnightAdapter, set up as in vault-v2's Midnight adapter integration test.
    function deployVaultWithAdapter(address _owner, address _curator, address _allocator, bytes32 salt)
        internal
        returns (IVaultV2 _vault, ITestMidnightAdapter _adapter)
    {
        _vault = IVaultV2(vaultFactory.createVaultV2(_owner, address(loanToken), salt));
        vm.prank(_owner);
        _vault.setCurator(_curator);
        // No duration caps: durations are empty.
        _adapter = ITestMidnightAdapter(
            adapterFactory.createMidnightAdapter(address(_vault), new uint256[](0), address(0), salt)
        );

        submitAndExecAdapter(_adapter, abi.encodeCall(ITestMidnightAdapter.increaseMaxTtm, (365 days)));
        submitAndExec(_vault, abi.encodeCall(IVaultV2.addAdapter, (address(_adapter))));
        submitAndExec(_vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(_adapter), true)));
        submitAndExec(_vault, abi.encodeCall(IVaultV2.setIsAllocator, (_allocator, true)));

        increaseCaps(_vault, abi.encode("this", address(_adapter)));
        increaseCaps(
            _vault,
            abi.encode(
                "collateralParams/rcfThreshold/liquidatorGate/enterGate",
                market.collateralParams,
                market.rcfThreshold,
                market.liquidatorGate,
                market.enterGate
            )
        );
        for (uint256 i; i < market.collateralParams.length; i++) {
            increaseCaps(_vault, abi.encode("collateralToken", market.collateralParams[i].token));
        }

        // The ids capped above are exactly the adapter's ids for the market.
        bytes32[] memory adapterIds = _adapter.ids(market);
        for (uint256 i; i < adapterIds.length; i++) {
            assertEq(_vault.absoluteCap(adapterIds[i]), type(uint128).max, "cap set");
        }
    }

    function submitAndExec(IVaultV2 _vault, bytes memory data) internal {
        vm.prank(_vault.curator());
        _vault.submit(data);
        (bool success, bytes memory returnData) = address(_vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    function submitAndExecAdapter(ITestMidnightAdapter _adapter, bytes memory data) internal {
        vm.prank(IVaultV2(_adapter.parentVault()).curator());
        _adapter.submit(data);
        (bool success, bytes memory returnData) = address(_adapter).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    function increaseCaps(IVaultV2 _vault, bytes memory idData) internal {
        submitAndExec(_vault, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        submitAndExec(_vault, abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, WAD)));
    }

    /// @dev Lets the adapter sell at any price, as in vault-v2's setUpRealVault.
    function relaxSaleGuardrails() internal {
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.increaseMaxNetSellRate, (type(uint64).max)));
        submitAndExecAdapter(
            adapter, abi.encodeCall(ITestMidnightAdapter.increaseShortfallAllowance, (type(uint128).max))
        );
    }

    function collateralize(address _borrower, uint256 debt) internal {
        uint256 collateral =
            debt.mulDivUp(WAD, market.collateralParams[0].lltv).mulDivUp(ORACLE_PRICE_SCALE, oracle.price());
        deal(address(collateralToken), _borrower, collateral);
        vm.startPrank(_borrower);
        safeApprove(collateralToken, address(midnight), collateral);
        midnight.supplyCollateral(market, 0, collateral, _borrower);
        vm.stopPrank();
    }

    function sellOffer(bytes32 group) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = false;
        offer.maker = borrower;
        offer.start = vm.getBlockTimestamp();
        offer.expiry = market.maturity;
        offer.tick = sellTick;
        offer.group = group;
        offer.receiverIfMakerIsSeller = borrower;
        offer.ratifier = address(dummyRatifier);
        offer.maxUnits = uint128(OFFER_UNITS);
        offer.continuousFeeCap = type(uint256).max;
    }

    function buyOffer(bytes32 group) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = lender;
        offer.start = vm.getBlockTimestamp();
        offer.expiry = market.maturity;
        offer.tick = buyTick;
        offer.group = group;
        offer.ratifier = address(dummyRatifier);
        offer.maxUnits = uint128(OFFER_UNITS);
        offer.continuousFeeCap = type(uint256).max;
    }

    function twoSellFills(uint256 unitsEach) internal view returns (OfferFill[] memory fills) {
        fills = new OfferFill[](2);
        fills[0] = OfferFill({offer: sellOffer(bytes32(uint256(1))), ratifierData: "", units: unitsEach});
        fills[1] = OfferFill({offer: sellOffer(bytes32(uint256(2))), ratifierData: "", units: unitsEach});
    }

    function twoBuyFills(uint256 unitsEach) internal view returns (OfferFill[] memory fills) {
        fills = new OfferFill[](2);
        fills[0] = OfferFill({offer: buyOffer(bytes32(uint256(11))), ratifierData: "", units: unitsEach});
        fills[1] = OfferFill({offer: buyOffer(bytes32(uint256(12))), ratifierData: "", units: unitsEach});
    }

    /// CALL HELPERS ///

    function buyWithAssets(address caller, uint256 targetBuyerAssets, uint256 minUnits, OfferFill[] memory fills)
        internal
    {
        vm.prank(caller);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(adapter),
            market,
            targetBuyerAssets,
            minUnits,
            fills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
    }

    function creditOf(address user) internal view returns (uint256) {
        (uint128 userCredit,,) = midnight.updatePositionView(market, id, user);
        return userCredit;
    }

    struct TakeTotals {
        uint256 count;
        uint256 units;
        uint256 buyerAssets;
        uint256 sellerAssets;
    }

    /// @dev Sums Midnight's Take events in the recorded logs.
    function sumTakeEvents() internal view returns (TakeTotals memory totals) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(midnight) || logs[i].topics[0] != EventsLib.Take.selector) continue;
            (,,,,,, uint256 units, uint256 buyerAssets, uint256 sellerAssets,,,,,) = abi.decode(
                logs[i].data,
                (
                    address,
                    bytes32,
                    bool,
                    bytes32,
                    address,
                    bytes,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    int256,
                    address
                )
            );
            totals.count++;
            totals.units += units;
            totals.buyerAssets += buyerAssets;
            totals.sellerAssets += sellerAssets;
        }
    }

    function assertBundleHoldsNothing() internal view {
        assertEq(loanToken.balanceOf(address(bundle)), 0, "bundle loan balance");
        assertEq(collateralToken.balanceOf(address(bundle)), 0, "bundle collateral balance");
        assertEq(loanToken.allowance(address(bundle), address(midnight)), 0, "bundle allowance midnight");
        assertEq(loanToken.allowance(address(bundle), address(adapter)), 0, "bundle allowance adapter");
    }

    /// MILESTONE 1: BUY WITH ASSETS TARGET ACROSS TWO OFFERS ///

    function testBuyWithAssetsTargetTwoOffers() public {
        // 10k units per offer at ~0.98: 15k assets needs the whole first offer and part of the second.
        uint256 targetBuyerAssets = 15_000e18;
        OfferFill[] memory fills = twoSellFills(10_000e18);

        uint256 creditBefore = creditOf(address(adapter));
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        vm.recordLogs();
        buyWithAssets(allocator, targetBuyerAssets, 0, fills);
        TakeTotals memory totals = sumTakeEvents();

        uint256 creditGained = creditOf(address(adapter)) - creditBefore;
        assertEq(totals.count, 2, "two takes");
        assertEq(creditGained, totals.units, "credit gained = units taken");
        assertGt(creditGained, targetBuyerAssets, "bought below face value");
        assertEq(vaultBalanceBefore - loanToken.balanceOf(address(vault)), targetBuyerAssets, "vault spent target");
        // The bundle's computed buyer assets equal Midnight's: the target is met exactly, and Midnight's events add up
        // to the same amount.
        assertEq(totals.buyerAssets, targetBuyerAssets, "computed buyer assets = sum of Take events");
        assertBundleHoldsNothing();
    }

    /// ACCESS ///

    function testBuyUnauthorizedStranger() public {
        vm.expectRevert(IMidnightAdapterBundlesV1.Unauthorized.selector);
        buyWithAssets(stranger, 15_000e18, 0, twoSellFills(10_000e18));
    }

    function testBuyUnauthorizedSentinel() public {
        vm.expectRevert(IMidnightAdapterBundlesV1.Unauthorized.selector);
        buyWithAssets(sentinel, 15_000e18, 0, twoSellFills(10_000e18));
    }

    function testBuyUnauthorizedCurator() public {
        vm.expectRevert(IMidnightAdapterBundlesV1.Unauthorized.selector);
        buyWithAssets(curator, 15_000e18, 0, twoSellFills(10_000e18));
    }

    function testBuyUnauthorizedAllocatorOfOtherVault() public {
        address otherAllocator = makeAddr("otherAllocator");
        (IVaultV2 otherVault,) = deployVaultWithAdapter(owner, curator, otherAllocator, bytes32(uint256(1)));
        submitAndExec(otherVault, abi.encodeCall(IVaultV2.setIsAllocator, (address(bundle), true)));
        assertTrue(otherVault.isAllocator(otherAllocator));

        vm.expectRevert(IMidnightAdapterBundlesV1.Unauthorized.selector);
        buyWithAssets(otherAllocator, 15_000e18, 0, twoSellFills(10_000e18));
    }

    function testSellUnauthorizedStranger() public {
        vm.prank(stranger);
        vm.expectRevert(IMidnightAdapterBundlesV1.Unauthorized.selector);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, type(uint256).max, 0, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
    }

    function testDeadlinePassed() public {
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.DeadlinePassed.selector);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(adapter),
            market,
            1e18,
            0,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp() - 1
        );
    }

    /// SKIPPING AND FINAL CHECKS ///

    function testBuySkipsConsumedFirstOffer() public {
        OfferFill[] memory fills = twoSellFills(OFFER_UNITS);
        vm.prank(borrower);
        midnight.setConsumed(fills[0].offer.group, type(uint128).max, borrower);

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        buyWithAssets(allocator, 15_000e18, 0, fills);
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.count, 1, "one take");
        assertEq(totals.buyerAssets, 15_000e18, "event buyer assets");
        assertEq(midnight.consumed(borrower, fills[1].offer.group), totals.units, "filled from second offer");
        assertEq(vaultBalanceBefore - loanToken.balanceOf(address(vault)), 15_000e18, "vault spent target");
    }

    function testBuySkipsRevertingFirstOffer() public {
        OfferFill[] memory fills = twoSellFills(OFFER_UNITS);
        // The adapter rejects a take whose maker has not authorized the ratifier: Midnight reverts.
        fills[0].offer.ratifier = makeAddr("unauthorizedRatifier");

        vm.recordLogs();
        buyWithAssets(allocator, 15_000e18, 0, fills);
        TakeTotals memory totals = sumTakeEvents();
        assertEq(totals.count, 1, "one take");
        assertEq(totals.buyerAssets, 15_000e18, "event buyer assets");
    }

    function testBuyOutOfOffers() public {
        // Two offers of 10k units each at ~0.98 cannot absorb 30k assets.
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 30_000e18, 0, twoSellFills(10_000e18));
    }

    function testBuyUnitsTooLow() public {
        vm.expectRevert(IMidnightAdapterBundlesV1.UnitsTooLow.selector);
        buyWithAssets(allocator, 15_000e18, 15_000e18 * 2, twoSellFills(10_000e18));
    }

    function testBuyInconsistentSide() public {
        OfferFill[] memory fills = twoSellFills(10_000e18);
        fills[0].offer.buy = true;
        vm.expectRevert(IMidnightAdapterBundlesV1.InconsistentSide.selector);
        buyWithAssets(allocator, 15_000e18, 0, fills);
    }

    function testBuyInconsistentMarket() public {
        OfferFill[] memory fills = twoSellFills(10_000e18);
        fills[0].offer.market.maturity += 1;
        vm.expectRevert(IMidnightAdapterBundlesV1.InconsistentMarket.selector);
        buyWithAssets(allocator, 15_000e18, 0, fills);
    }

    function testBundleNotAllocatorEveryTakeRejected() public {
        submitAndExec(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(bundle), false)));
        assertTrue(vault.isAllocator(allocator));

        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
    }

    /// RE-ENTRY ///

    function testReentryFromMakerCallback() public {
        ReenteringSellCallback reenterer = new ReenteringSellCallback(bundle, address(adapter));
        // The re-entering contract is an allocator, so only the lock can stop it.
        submitAndExec(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(reenterer), true)));

        OfferFill[] memory fills = twoSellFills(10_000e18);
        fills[0].offer.callback = address(reenterer);

        vm.recordLogs();
        buyWithAssets(allocator, 15_000e18, 0, fills);
        TakeTotals memory totals = sumTakeEvents();

        assertTrue(reenterer.reentered(), "callback ran");
        assertEq(
            reenterer.lastRevertData(),
            abi.encodeWithSelector(IMidnightAdapterBundlesV1.Reentrancy.selector),
            "re-entry refused with Reentrancy"
        );
        assertEq(totals.count, 2, "both takes went through");
        assertEq(totals.buyerAssets, 15_000e18, "event buyer assets");
    }

    /// SELL ///

    function testSellWithUnitsTargetFullExitAfterBuy() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        uint256 credit = creditOf(address(adapter));
        assertGt(credit, 0, "credit after buy");

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, type(uint256).max, 0, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
        TakeTotals memory totals = sumTakeEvents();

        // The bundle's computed seller assets equal the sum of Midnight's Take events: one more is refused.
        vm.revertToState(snapshot);
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.SellerAssetsTooLow.selector);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter),
            market,
            type(uint256).max,
            totals.sellerAssets + 1,
            twoBuyFills(10_000e18),
            vm.getBlockTimestamp()
        );
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter),
            market,
            type(uint256).max,
            totals.sellerAssets,
            twoBuyFills(10_000e18),
            vm.getBlockTimestamp()
        );

        assertEq(totals.count, 2, "two takes");
        assertEq(totals.units, credit, "sold all credit");
        assertEq(creditOf(address(adapter)), 0, "no credit left");
        assertEq(
            loanToken.balanceOf(address(vault)) - vaultBalanceBefore, totals.sellerAssets, "vault received proceeds"
        );
        assertBundleHoldsNothing();
    }

    function testSellWithUnitsTargetSellerAssetsTooLow() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        uint256 credit = creditOf(address(adapter));

        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.SellerAssetsTooLow.selector);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, credit, credit, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
    }

    function testSellRejectedByDefaultGuardrails() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        // maxNetSellRate is 0 by default: a sale below face value is rejected by the adapter and skipped.
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, type(uint256).max, 0, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
    }

    function testSellWithAssetsTarget() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        uint256 creditBefore = creditOf(address(adapter));
        uint256 targetSellerAssets = 12_000e18;

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter),
            market,
            targetSellerAssets,
            type(uint256).max,
            twoBuyFills(10_000e18),
            vm.getBlockTimestamp()
        );
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.count, 2, "two takes");
        assertEq(totals.sellerAssets, targetSellerAssets, "computed seller assets = sum of Take events");
        assertEq(loanToken.balanceOf(address(vault)) - vaultBalanceBefore, targetSellerAssets, "vault received");
        assertEq(creditBefore - creditOf(address(adapter)), totals.units, "credit sold");
        assertBundleHoldsNothing();
    }

    function testSellWithAssetsTargetUnitsTooHigh() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();

        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.UnitsTooHigh.selector);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter), market, 12_000e18, 12_000e18, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
    }

    /// BUY WITH UNITS TARGET ///

    function testBuyWithUnitsTarget() public {
        uint256 targetUnits = 15_000e18;
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            targetUnits,
            targetUnits,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
        TakeTotals memory totals = sumTakeEvents();

        // The bundle's computed buyer assets equal the sum of Midnight's Take events: one less is refused.
        vm.revertToState(snapshot);
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.BuyerAssetsTooHigh.selector);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            targetUnits,
            totals.buyerAssets - 1,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            targetUnits,
            totals.buyerAssets,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );

        assertEq(totals.count, 2, "two takes");
        assertEq(totals.units, targetUnits, "units");
        assertEq(creditOf(address(adapter)), targetUnits, "credit");
        assertEq(vaultBalanceBefore - loanToken.balanceOf(address(vault)), totals.buyerAssets, "vault spent");
        assertBundleHoldsNothing();
    }

    function testBuyWithUnitsTargetBuyerAssetsTooHigh() public {
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.BuyerAssetsTooHigh.selector);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            15_000e18,
            14_000e18,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
    }

    /// FUZZ ///

    function testBuyWithAssetsTargetFuzz(uint256 targetBuyerAssets, uint256 unitsFirst) public {
        unitsFirst = bound(unitsFirst, 1, OFFER_UNITS);
        // The second offer can absorb the rest: at most OFFER_UNITS units at a buyer price below 1.
        targetBuyerAssets = bound(targetBuyerAssets, 1e6, OFFER_UNITS * 9 / 10);
        OfferFill[] memory fills = twoSellFills(OFFER_UNITS);
        fills[0].units = unitsFirst;

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        buyWithAssets(allocator, targetBuyerAssets, 0, fills);
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.buyerAssets, targetBuyerAssets, "computed buyer assets = sum of Take events");
        assertEq(vaultBalanceBefore - loanToken.balanceOf(address(vault)), targetBuyerAssets, "vault spent target");
        assertEq(creditOf(address(adapter)), totals.units, "credit");
        assertBundleHoldsNothing();
    }

    function testSellWithUnitsTargetFuzz(uint256 buyAssets, uint256 sellUnits) public {
        buyAssets = bound(buyAssets, 1e6, OFFER_UNITS * 9 / 10);
        buyWithAssets(allocator, buyAssets, 0, twoSellFills(OFFER_UNITS));
        relaxSaleGuardrails();
        uint256 credit = creditOf(address(adapter));
        // A sale too small to pay out a single asset is rejected by the adapter's maxNetSellRate check.
        sellUnits = bound(sellUnits, 1e6, credit);

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, sellUnits, 0, twoBuyFills(OFFER_UNITS / 2), vm.getBlockTimestamp()
        );
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.units, sellUnits, "units sold");
        assertEq(creditOf(address(adapter)), credit - sellUnits, "credit left");
        assertEq(
            loanToken.balanceOf(address(vault)) - vaultBalanceBefore, totals.sellerAssets, "vault received proceeds"
        );
        assertBundleHoldsNothing();
    }

    function testSellWithAssetsTargetFuzz(uint256 buyAssets, uint256 targetSellerAssets) public {
        buyAssets = bound(buyAssets, 1e18, OFFER_UNITS * 9 / 10);
        buyWithAssets(allocator, buyAssets, 0, twoSellFills(OFFER_UNITS));
        relaxSaleGuardrails();
        uint256 credit = creditOf(address(adapter));
        // Stay below what the credit can fetch at the buy offers' seller price (< 0.99).
        targetSellerAssets = bound(targetSellerAssets, 1e6, credit * 98 / 100);

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter), market, targetSellerAssets, credit, twoBuyFills(OFFER_UNITS / 2), vm.getBlockTimestamp()
        );
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.sellerAssets, targetSellerAssets, "computed seller assets = sum of Take events");
        assertEq(loanToken.balanceOf(address(vault)) - vaultBalanceBefore, targetSellerAssets, "vault received");
        assertEq(creditOf(address(adapter)), credit - totals.units, "credit left");
        assertBundleHoldsNothing();
    }
}
