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
    function decreaseMaxTtm(uint256 newMaxTtm) external;
    function maxNetSellRate() external view returns (uint128);
    function increaseMinNetBuyRate(uint256 newMinNetBuyRate) external;
    function setForceSellable(bytes32 marketId) external;
    function forceRemove(bytes32 marketId) external;
    function shortfallAllowance() external view returns (uint128);
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

/// @dev An adapter that names a real vault and does nothing on take.
contract FakeAdapter {
    address public parentVault;

    constructor(address _parentVault) {
        parentVault = _parentVault;
    }

    function take(Offer memory, bytes calldata, uint256, bytes calldata) external {}
}

/// @dev A vault that says everyone is an allocator.
contract FakeVault {
    function isAllocator(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Buyer callback of a buy offer: pays from its own balance and reports a funding bound, or reverts on it.
contract BoundedBuyCallback {
    uint256 public bound;
    bool public reverts;

    constructor(address token, address midnight, uint256 _bound, bool _reverts) {
        bound = _bound;
        reverts = _reverts;
        (bool success,) = token.call(abi.encodeWithSignature("approve(address,uint256)", midnight, type(uint256).max));
        require(success);
    }

    function buyerAssetsBound(bytes32, Market memory, address, bytes memory) external view returns (uint256) {
        require(!reverts, "no bound");
        return bound;
    }

    function onBuy(bytes32, Market memory, uint256, uint256, uint256, address, bytes memory)
        external
        pure
        returns (bytes32)
    {
        return CALLBACK_SUCCESS;
    }
}

/// @dev Deploys Midnight, a real Vault V2 with a real MidnightAdapter, and the bundle. Shared with the invariant test.
abstract contract MidnightAdapterBundlesV1Setup is TokenTest {
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

    function setUp() public virtual {
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
    /// @dev vm.recordLogs also records the logs of reverted sub-calls, so a take that the adapter rejected after
    /// Midnight emitted Take still shows up. Such events are left out by skipping offers whose group is unconsumed.
    /// This assumes every recorded take of a group either all succeeded or all reverted, as in these tests.
    function sumTakeEvents() internal view returns (TakeTotals memory totals) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(midnight) || logs[i].topics[0] != EventsLib.Take.selector) continue;
            // Static head words of the event data: group is the 4th, units, buyerAssets and sellerAssets the 7th to 9th.
            bytes memory data = logs[i].data;
            bytes32 group = bytes32(word(data, 3));
            uint256 units = word(data, 6);
            uint256 buyerAssets = word(data, 7);
            uint256 sellerAssets = word(data, 8);
            address maker = address(uint160(uint256(logs[i].topics[2])));
            if (midnight.consumed(maker, group) == 0) continue;
            totals.count++;
            totals.units += units;
            totals.buyerAssets += buyerAssets;
            totals.sellerAssets += sellerAssets;
        }
    }

    struct TakeRecord {
        bytes32 group;
        uint256 units;
        uint256 buyerAssets;
        uint256 sellerAssets;
    }

    /// @dev Midnight's Take events in the recorded logs, in order, with the same filter as sumTakeEvents.
    function recordedTakes() internal view returns (TakeRecord[] memory takes) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        takes = new TakeRecord[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(midnight) || logs[i].topics[0] != EventsLib.Take.selector) continue;
            bytes memory data = logs[i].data;
            bytes32 group = bytes32(word(data, 3));
            if (midnight.consumed(address(uint160(uint256(logs[i].topics[2]))), group) == 0) continue;
            takes[n++] = TakeRecord(group, word(data, 6), word(data, 7), word(data, 8));
        }
        assembly ("memory-safe") {
            mstore(takes, n)
        }
    }

    /// @dev Returns the i-th 32-byte word of data.
    function word(bytes memory data, uint256 i) internal pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), mul(i, 32)))
        }
    }

    function assertBundleHoldsNothing() internal view {
        assertEq(loanToken.balanceOf(address(bundle)), 0, "bundle loan balance");
        assertEq(collateralToken.balanceOf(address(bundle)), 0, "bundle collateral balance");
        assertEq(loanToken.allowance(address(bundle), address(midnight)), 0, "bundle allowance midnight");
        assertEq(loanToken.allowance(address(bundle), address(adapter)), 0, "bundle allowance adapter");
    }
}

contract MidnightAdapterBundlesV1Test is MidnightAdapterBundlesV1Setup {
    using UtilsLib for uint256;

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

    /// GUARDRAIL HELPERS ///

    function tickAt(uint256 price) internal pure returns (uint256) {
        return TickLib.priceToTick(price, DEFAULT_TICK_SPACING);
    }

    function sellFillAt(bytes32 group, uint256 price, uint256 units) internal view returns (OfferFill memory fill) {
        fill.offer = sellOffer(group);
        fill.offer.tick = tickAt(price);
        fill.units = units;
    }

    function buyFillAt(bytes32 group, uint256 price, uint256 units) internal view returns (OfferFill memory fill) {
        fill.offer = buyOffer(group);
        fill.offer.tick = tickAt(price);
        fill.units = units;
    }

    function pair(OfferFill memory a, OfferFill memory b) internal pure returns (OfferFill[] memory fills) {
        fills = new OfferFill[](2);
        fills[0] = a;
        fills[1] = b;
    }

    function sellWithUnits(uint256 targetUnits, OfferFill[] memory fills) internal {
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, targetUnits, 0, fills, vm.getBlockTimestamp()
        );
    }

    /// @dev The first offer (at 0.5) needs about twice the units of the second (at 0.98) for the same assets.
    function assertBuyFilledFromSecondOnly(OfferFill[] memory fills, uint256 targetBuyerAssets) internal {
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        buyWithAssets(allocator, targetBuyerAssets, 0, fills);
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.count, 1, "one take");
        assertEq(midnight.consumed(borrower, fills[0].offer.group), 0, "first offer skipped");
        assertEq(midnight.consumed(borrower, fills[1].offer.group), totals.units, "filled from second offer");
        assertEq(totals.buyerAssets, targetBuyerAssets, "event buyer assets");
        assertEq(vaultBalanceBefore - loanToken.balanceOf(address(vault)), targetBuyerAssets, "vault spent target");
        assertBundleHoldsNothing();
    }

    /// BUY GUARDRAILS ///

    function testBuySkipsAbsoluteCapExceeded() public {
        vm.prank(curator);
        vault.decreaseAbsoluteCap(abi.encode("this", address(adapter)), 6_000e18);
        // 5k assets: ~10k units at 0.5 (over the cap), ~5.1k units at 0.98 (under it).
        OfferFill[] memory fills = pair(
            sellFillAt(bytes32(uint256(1)), 0.5e18, OFFER_UNITS), sellFillAt(bytes32(uint256(2)), 0.98e18, OFFER_UNITS)
        );
        assertBuyFilledFromSecondOnly(fills, 5_000e18);
        assertLe(creditOf(address(adapter)), 6_000e18, "within cap");
    }

    function testBuySkipsRelativeCapExceeded() public {
        vm.prank(curator);
        vault.decreaseRelativeCap(abi.encode("this", address(adapter)), 0.006e18);
        // The relative cap is 0.6% of the vault's 1M total assets: 6k units, as in the absolute cap test.
        OfferFill[] memory fills = pair(
            sellFillAt(bytes32(uint256(1)), 0.5e18, OFFER_UNITS), sellFillAt(bytes32(uint256(2)), 0.98e18, OFFER_UNITS)
        );
        assertBuyFilledFromSecondOnly(fills, 5_000e18);
    }

    function testBuySkipsMinNetBuyRate() public {
        // About 3.2% a year. At 0.999 over 30 days the net rate is far below it, at 0.98 it is far above it.
        vm.prank(curator);
        adapter.increaseMinNetBuyRate(1e9);
        OfferFill[] memory fills = pair(
            sellFillAt(bytes32(uint256(1)), 0.999e18, OFFER_UNITS),
            sellFillAt(bytes32(uint256(2)), 0.98e18, OFFER_UNITS)
        );
        assertBuyFilledFromSecondOnly(fills, 5_000e18);
    }

    /// @dev maxTtm is checked against the market's maturity, and every offer of an order is on the same market, so it
    /// rejects every offer: the order reverts OutOfOffers.
    function testBuyMaxTtmRejectsEveryOffer() public {
        vm.prank(curator);
        adapter.decreaseMaxTtm(1 days);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 5_000e18, 0, twoSellFills(OFFER_UNITS));
    }

    /// @dev forceSellable is per market, so it rejects every offer of an order: the order reverts OutOfOffers.
    function testBuyForceSellableRejectsEveryOffer() public {
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.setForceSellable, (id)));
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 5_000e18, 0, twoSellFills(OFFER_UNITS));
    }

    /// @dev forceRemove is per market, so it rejects every offer of an order: the order reverts OutOfOffers.
    function testBuyForceRemovedRejectsEveryOffer() public {
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.forceRemove, (id)));
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        buyWithAssets(allocator, 5_000e18, 0, twoSellFills(OFFER_UNITS));
    }

    /// SELL GUARDRAILS ///

    function testSellSkipsMaxNetSellRate() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        // About 31% a year: over 30 days, sales must pay at least ~0.975 per unit.
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.increaseMaxNetSellRate, (1e10)));
        OfferFill[] memory fills = pair(
            buyFillAt(bytes32(uint256(11)), 0.9e18, OFFER_UNITS), buyFillAt(bytes32(uint256(12)), 0.99e18, OFFER_UNITS)
        );

        uint256 creditBefore = creditOf(address(adapter));
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        vm.recordLogs();
        sellWithUnits(5_000e18, fills);
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.count, 1, "one take");
        assertEq(midnight.consumed(lender, fills[0].offer.group), 0, "first offer skipped");
        assertEq(midnight.consumed(lender, fills[1].offer.group), 5_000e18, "filled from second offer");
        assertEq(creditBefore - creditOf(address(adapter)), 5_000e18, "credit sold");
        assertEq(loanToken.balanceOf(address(vault)) - vaultBalanceBefore, totals.sellerAssets, "vault received");
    }

    function testSellShortfallAllowanceExhaustedMidOrder() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.increaseMaxNetSellRate, (type(uint64).max)));
        // Selling 2k units bought at ~0.98 for ~0.9 costs a shortfall of ~160: the budget covers one such sale.
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.increaseShortfallAllowance, (200e18)));
        OfferFill[] memory cheap =
            pair(buyFillAt(bytes32(uint256(11)), 0.9e18, 2_000e18), buyFillAt(bytes32(uint256(12)), 0.9e18, 2_000e18));

        // A units target above the first fill: the first take uses the budget, the second is rejected.
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.OutOfOffers.selector);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, 4_000e18, 0, cheap, vm.getBlockTimestamp()
        );

        // Same order with a third offer at 0.99: the second offer is skipped mid-order and the third fills the rest.
        OfferFill[] memory fills = new OfferFill[](3);
        fills[0] = cheap[0];
        fills[1] = cheap[1];
        fills[2] = buyFillAt(bytes32(uint256(13)), 0.99e18, 2_000e18);
        vm.recordLogs();
        sellWithUnits(4_000e18, fills);
        TakeTotals memory totals = sumTakeEvents();

        assertEq(totals.count, 2, "two takes");
        assertEq(midnight.consumed(lender, fills[0].offer.group), 2_000e18, "first offer filled");
        assertEq(midnight.consumed(lender, fills[1].offer.group), 0, "second offer skipped");
        assertEq(midnight.consumed(lender, fills[2].offer.group), 2_000e18, "third offer filled");
        assertLt(adapter.shortfallAllowance(), 200e18 - 100e18, "budget mostly used");
    }

    /// FUNDING FROM ANOTHER SOURCE ///

    /// @dev Buys in the 30-day market with funds withdrawn from the adapter's repaid credit in a 1-day market.
    function testBuyFundedFromAdapterCreditInAnotherMarket() public {
        Market memory fundingMarket = market;
        fundingMarket.maturity = vm.getBlockTimestamp() + 1 days;
        bytes32 fundingId = midnight.touchMarket(fundingMarket);
        uint256 collateral = OFFER_UNITS.mulDivUp(WAD, market.collateralParams[0].lltv);
        deal(address(collateralToken), borrower, collateral);
        vm.startPrank(borrower);
        safeApprove(collateralToken, address(midnight), collateral);
        midnight.supplyCollateral(fundingMarket, 0, collateral, borrower);
        vm.stopPrank();

        // Buy credit in the funding market through the bundle.
        Offer memory fundingOffer = sellOffer(bytes32(uint256(21)));
        fundingOffer.market = fundingMarket;
        fundingOffer.expiry = fundingMarket.maturity;
        OfferFill[] memory fundingFills = new OfferFill[](1);
        fundingFills[0] = OfferFill({offer: fundingOffer, ratifierData: "", units: OFFER_UNITS});
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(adapter),
            fundingMarket,
            10_000e18,
            0,
            fundingFills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );

        // The borrower repays after maturity, so the adapter's credit there becomes withdrawable.
        vm.warp(fundingMarket.maturity + 1);
        uint256 debt = midnight.debt(fundingId, borrower);
        deal(address(loanToken), borrower, debt);
        vm.startPrank(borrower);
        safeApprove(loanToken, address(midnight), debt);
        midnight.repay(fundingMarket, debt, borrower, address(0), "");
        vm.stopPrank();

        (uint128 fundingCreditBefore,,) = midnight.updatePositionView(fundingMarket, fundingId, address(adapter));
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        uint256 targetBuyerAssets = 5_000e18;

        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(adapter),
            market,
            targetBuyerAssets,
            0,
            twoSellFills(OFFER_UNITS),
            abi.encode(address(adapter), abi.encode(fundingMarket)),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
        TakeTotals memory totals = sumTakeEvents();

        (uint128 fundingCreditAfter,,) = midnight.updatePositionView(fundingMarket, fundingId, address(adapter));
        assertEq(totals.buyerAssets, targetBuyerAssets, "event buyer assets");
        assertEq(fundingCreditBefore - fundingCreditAfter, targetBuyerAssets, "paid from the funding market");
        assertEq(loanToken.balanceOf(address(vault)), vaultBalanceBefore, "vault idle assets untouched");
        assertEq(creditOf(address(adapter)), totals.units, "credit bought");
        assertBundleHoldsNothing();
    }

    /// FAKE ADAPTERS ///

    /// @dev The bundle counts a take that does not revert as filled, so an adapter whose take does nothing makes the
    /// call succeed with nothing bought. Harmless: the fake adapter only acts as itself, and nothing real moves.
    function testFakeAdapterNamingRealVault() public {
        FakeAdapter fake = new FakeAdapter(address(vault));
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(fake),
            market,
            15_000e18,
            0,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );

        assertEq(sumTakeEvents().count, 0, "no Midnight take");
        assertEq(loanToken.balanceOf(address(vault)), vaultBalanceBefore, "real vault untouched");
        assertEq(creditOf(address(adapter)), 0, "real adapter credit untouched");
        assertEq(creditOf(address(fake)), 0, "fake adapter has no credit");
        assertBundleHoldsNothing();
    }

    function testFakeAdapterWithFakeVaultCalledByStranger() public {
        FakeAdapter fake = new FakeAdapter(address(new FakeVault()));
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        vm.recordLogs();
        vm.prank(stranger);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(fake),
            market,
            15_000e18,
            0,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );

        assertEq(sumTakeEvents().count, 0, "no Midnight take");
        assertEq(loanToken.balanceOf(address(vault)), vaultBalanceBefore, "real vault untouched");
        assertEq(creditOf(address(adapter)), 0, "real adapter credit untouched");
        assertBundleHoldsNothing();
    }

    /// EVERY CHECK ON EVERY ENTRY POINT ///

    /// @dev Calls entry point `kind` (0: buy assets, 1: buy units, 2: sell assets, 3: sell units) with a 1e18 target.
    function callEntry(uint256 kind, address caller, uint256 deadline, OfferFill[] memory fills) internal {
        vm.prank(caller);
        if (kind == 0) {
            bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
                address(adapter), market, 1e18, 0, fills, abi.encode(address(0), bytes("")), type(uint256).max, deadline
            );
        } else if (kind == 1) {
            bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
                address(adapter),
                market,
                1e18,
                type(uint256).max,
                fills,
                abi.encode(address(0), bytes("")),
                type(uint256).max,
                deadline
            );
        } else if (kind == 2) {
            bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
                address(adapter), market, 1e18, type(uint256).max, fills, deadline
            );
        } else {
            bundle.midnightAdapterBundlesV1SellWithUnitsTarget(address(adapter), market, 1e18, 0, fills, deadline);
        }
    }

    /// @dev The offers each entry point expects: sell offers for buys, buy offers for sells.
    function rightSide(uint256 kind) internal view returns (OfferFill[] memory) {
        return kind < 2 ? twoSellFills(10_000e18) : twoBuyFills(10_000e18);
    }

    function testDeadlinePassedEveryEntryPoint() public {
        for (uint256 kind; kind < 4; kind++) {
            vm.expectRevert(IMidnightAdapterBundlesV1.DeadlinePassed.selector);
            callEntry(kind, allocator, vm.getBlockTimestamp() - 1, rightSide(kind));
        }
    }

    function testUnauthorizedEveryEntryPoint() public {
        for (uint256 kind; kind < 4; kind++) {
            vm.expectRevert(IMidnightAdapterBundlesV1.Unauthorized.selector);
            callEntry(kind, stranger, vm.getBlockTimestamp(), rightSide(kind));
        }
    }

    function testInconsistentSideEveryEntryPoint() public {
        for (uint256 kind; kind < 4; kind++) {
            vm.expectRevert(IMidnightAdapterBundlesV1.InconsistentSide.selector);
            callEntry(kind, allocator, vm.getBlockTimestamp(), rightSide(3 - kind));
        }
    }

    function testInconsistentMarketEveryEntryPoint() public {
        for (uint256 kind; kind < 4; kind++) {
            OfferFill[] memory fills = rightSide(kind);
            fills[0].offer.market.maturity += 1;
            vm.expectRevert(IMidnightAdapterBundlesV1.InconsistentMarket.selector);
            callEntry(kind, allocator, vm.getBlockTimestamp(), fills);
        }
    }

    /// REDUCE-ONLY OFFERS ///

    function testReduceOnlySellOfferCappedAtMakerCredit() public {
        // The lender buys 3k units of credit from the borrower, then posts a reduce-only sell offer.
        vm.prank(lender);
        midnight.take(sellOffer(bytes32(uint256(71))), "", 3_000e18, lender, address(0), address(0), "");
        assertEq(creditOf(lender), 3_000e18, "lender credit");
        OfferFill[] memory fills = twoSellFills(10_000e18);
        fills[0].offer.maker = lender;
        fills[0].offer.receiverIfMakerIsSeller = lender;
        fills[0].offer.reduceOnly = true;

        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            5_000e18,
            type(uint256).max,
            fills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );

        assertEq(midnight.consumed(lender, fills[0].offer.group), 3_000e18, "capped at the maker's credit");
        assertEq(midnight.consumed(borrower, fills[1].offer.group), 2_000e18, "rest from the second offer");
        assertEq(creditOf(address(adapter)), 5_000e18, "credit bought");
    }

    function testReduceOnlyBuyOfferCappedAtMakerDebt() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        // The borrower repays down to 5k units of debt, then posts a reduce-only buy offer.
        uint256 debt = midnight.debt(id, borrower);
        deal(address(loanToken), borrower, debt);
        vm.startPrank(borrower);
        safeApprove(loanToken, address(midnight), type(uint256).max);
        midnight.repay(market, debt - 5_000e18, borrower, address(0), "");
        vm.stopPrank();
        OfferFill[] memory fills = twoBuyFills(10_000e18);
        fills[0].offer.maker = borrower;
        fills[0].offer.reduceOnly = true;

        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, 8_000e18, 0, fills, vm.getBlockTimestamp()
        );

        assertEq(midnight.consumed(borrower, fills[0].offer.group), 5_000e18, "capped at the maker's debt");
        assertEq(midnight.consumed(lender, fills[1].offer.group), 3_000e18, "rest from the second offer");
        assertEq(midnight.debt(id, borrower), 0, "maker's debt repaid");
    }

    function testReduceOnlySellOfferCappedAtMakerCreditAssetsTarget() public {
        vm.prank(lender);
        midnight.take(sellOffer(bytes32(uint256(71))), "", 3_000e18, lender, address(0), address(0), "");
        OfferFill[] memory fills = twoSellFills(10_000e18);
        fills[0].offer.maker = lender;
        fills[0].offer.receiverIfMakerIsSeller = lender;
        fills[0].offer.reduceOnly = true;

        buyWithAssets(allocator, 5_000e18, 0, fills);

        assertEq(midnight.consumed(lender, fills[0].offer.group), 3_000e18, "capped at the maker's credit");
        assertGt(midnight.consumed(borrower, fills[1].offer.group), 0, "rest from the second offer");
    }

    function testReduceOnlyBuyOfferCappedAtMakerDebtAssetsTarget() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        uint256 debt = midnight.debt(id, borrower);
        deal(address(loanToken), borrower, debt);
        vm.startPrank(borrower);
        safeApprove(loanToken, address(midnight), type(uint256).max);
        midnight.repay(market, debt - 5_000e18, borrower, address(0), "");
        vm.stopPrank();
        OfferFill[] memory fills = twoBuyFills(10_000e18);
        fills[0].offer.maker = borrower;
        fills[0].offer.reduceOnly = true;

        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter), market, 7_000e18, type(uint256).max, fills, vm.getBlockTimestamp()
        );

        assertEq(midnight.consumed(borrower, fills[0].offer.group), 5_000e18, "capped at the maker's debt");
        assertGt(midnight.consumed(lender, fills[1].offer.group), 0, "rest from the second offer");
    }

    /// CONTINUOUS FEE ///

    function testContinuousFeeAboveMaxOnBuysOnly() public {
        uint256 continuousFee = 1000;
        midnight.setMarketContinuousFee(id, continuousFee);

        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.ContinuousFeeAboveMax.selector);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(adapter),
            market,
            15_000e18,
            0,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            continuousFee - 1,
            vm.getBlockTimestamp()
        );
        vm.prank(allocator);
        vm.expectRevert(IMidnightAdapterBundlesV1.ContinuousFeeAboveMax.selector);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            15_000e18,
            type(uint256).max,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            continuousFee - 1,
            vm.getBlockTimestamp()
        );

        // At the max, the buy goes through.
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            address(adapter),
            market,
            15_000e18,
            0,
            twoSellFills(10_000e18),
            abi.encode(address(0), bytes("")),
            continuousFee,
            vm.getBlockTimestamp()
        );

        // Sells have no continuous fee check.
        relaxSaleGuardrails();
        uint256 credit = creditOf(address(adapter));
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, 1_000e18, 0, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter), market, 1_000e18, type(uint256).max, twoBuyFills(10_000e18), vm.getBlockTimestamp()
        );
        assertLt(creditOf(address(adapter)), credit - 1_000e18, "both sells went through");
    }

    /// BUYER ASSETS BOUND ///

    function boundedBuyFills(uint256 bound_, bool reverts) internal returns (OfferFill[] memory fills) {
        BoundedBuyCallback callback = new BoundedBuyCallback(address(loanToken), address(midnight), bound_, reverts);
        deal(address(loanToken), address(callback), 1e24);
        fills = twoBuyFills(10_000e18);
        fills[0].offer.callback = address(callback);
    }

    function testBuyerAssetsBoundCapsTake() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        OfferFill[] memory fills = boundedBuyFills(2_000e18, false);

        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, 5_000e18, 0, fills, vm.getBlockTimestamp()
        );
        TakeRecord[] memory takes = recordedTakes();

        assertEq(takes.length, 2, "two takes");
        assertEq(takes[0].buyerAssets, 2_000e18, "first take capped at the callback's bound");
        assertEq(takes[0].units + takes[1].units, 5_000e18, "rest from the second offer");
    }

    function testBuyerAssetsBoundRevertIsUnbounded() public {
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));
        relaxSaleGuardrails();
        OfferFill[] memory fills = boundedBuyFills(0, true);

        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, 5_000e18, 0, fills, vm.getBlockTimestamp()
        );
        TakeRecord[] memory takes = recordedTakes();

        assertEq(takes.length, 1, "one take");
        assertEq(takes[0].units, 5_000e18, "uncapped");
    }
}
