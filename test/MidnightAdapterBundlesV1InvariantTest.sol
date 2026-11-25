// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Market} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {MidnightAdapterBundlesV1} from "../src/midnight-adapter/MidnightAdapterBundlesV1.sol";
import {OfferFill} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";
import {MidnightAdapterBundlesV1Setup, ITestMidnightAdapter} from "./MidnightAdapterBundlesV1Test.sol";

interface IFills {
    function sellFills(uint256 unitsFirst, uint256 unitsSecond) external view returns (OfferFill[] memory);
    function buyFills(uint256 unitsFirst, uint256 unitsSecond) external view returns (OfferFill[] memory);
    function getMarket() external view returns (Market memory);
}

/// @dev Calls the four entry points with bounded inputs, as an allocator or as a stranger. Failed calls are ignored.
contract MidnightAdapterBundlesV1Handler is Test {
    MidnightAdapterBundlesV1 internal immutable bundle;
    address internal immutable adapter;
    IFills internal immutable fills;
    address internal immutable allocator;
    address internal immutable stranger;

    uint256 public successes;
    uint256 public strangerSuccesses;
    uint256 public calls;

    constructor(
        MidnightAdapterBundlesV1 _bundle,
        address _adapter,
        IFills _fills,
        address _allocator,
        address _stranger
    ) {
        bundle = _bundle;
        adapter = _adapter;
        fills = _fills;
        allocator = _allocator;
        stranger = _stranger;
    }

    function record(bool asStranger) internal {
        if (asStranger) strangerSuccesses++;
        else successes++;
    }

    function caller(bool asStranger) internal returns (address) {
        calls++;
        return asStranger ? stranger : allocator;
    }

    function buyWithAssets(uint256 target, uint256 minUnits, uint256 u0, uint256 u1, bool asStranger) external {
        target = bound(target, 1e6, 30_000e18);
        // Prices are below 1, so a fill always gains more units than it spends assets.
        minUnits = bound(minUnits, 0, target);
        OfferFill[] memory offerFills = fills.sellFills(bound(u0, 0, 20_000e18), bound(u1, 10_000e18, 20_000e18));
        Market memory market = fills.getMarket();
        vm.prank(caller(asStranger));
        try bundle.midnightAdapterBundlesV1BuyWithAssetsTarget(
            adapter,
            market,
            target,
            minUnits,
            offerFills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        ) {
            record(asStranger);
        } catch {}
    }

    function buyWithUnits(uint256 target, uint256 maxAssets, uint256 u0, uint256 u1, bool asStranger) external {
        target = bound(target, 1e6, 30_000e18);
        maxAssets = bound(maxAssets, target, 50_000e18);
        OfferFill[] memory offerFills = fills.sellFills(bound(u0, 0, 20_000e18), bound(u1, 10_000e18, 20_000e18));
        Market memory market = fills.getMarket();
        vm.prank(caller(asStranger));
        try bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            adapter,
            market,
            target,
            maxAssets,
            offerFills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        ) {
            record(asStranger);
        } catch {}
    }

    function sellWithAssets(uint256 target, uint256 maxUnits, uint256 u0, uint256 u1, bool asStranger) external {
        target = bound(target, 1e6, 10_000e18);
        maxUnits = bound(maxUnits, target * 11 / 10, 50_000e18);
        OfferFill[] memory offerFills = fills.buyFills(bound(u0, 0, 20_000e18), bound(u1, 10_000e18, 20_000e18));
        Market memory market = fills.getMarket();
        vm.prank(caller(asStranger));
        try bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            adapter, market, target, maxUnits, offerFills, vm.getBlockTimestamp()
        ) {
            record(asStranger);
        } catch {}
    }

    function sellWithUnits(uint256 target, uint256 minAssets, uint256 u0, uint256 u1, bool all, bool asStranger)
        external
    {
        target = all ? type(uint256).max : bound(target, 1e6, 10_000e18);
        minAssets = all ? 0 : bound(minAssets, 0, target * 9 / 10);
        OfferFill[] memory offerFills = fills.buyFills(bound(u0, 0, 20_000e18), bound(u1, 10_000e18, 20_000e18));
        Market memory market = fills.getMarket();
        vm.prank(caller(asStranger));
        try bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            adapter, market, target, minAssets, offerFills, vm.getBlockTimestamp()
        ) {
            record(asStranger);
        } catch {}
    }
}

contract MidnightAdapterBundlesV1InvariantTest is MidnightAdapterBundlesV1Setup, IFills {
    MidnightAdapterBundlesV1Handler internal handler;

    function setUp() public override {
        super.setUp();
        // Let the adapter sell at any price, so that sells can succeed.
        submitAndExecAdapter(adapter, abi.encodeCall(ITestMidnightAdapter.increaseMaxNetSellRate, (type(uint64).max)));
        submitAndExecAdapter(
            adapter, abi.encodeCall(ITestMidnightAdapter.increaseShortfallAllowance, (type(uint128).max))
        );

        // Give the vault credit to sell from the first call on.
        buyWithAssets(allocator, 15_000e18, 0, twoSellFills(10_000e18));

        handler = new MidnightAdapterBundlesV1Handler(bundle, address(adapter), this, allocator, stranger);
        targetContract(address(handler));
    }

    /// FILLS FOR THE HANDLER ///

    function sellFills(uint256 unitsFirst, uint256 unitsSecond) external view returns (OfferFill[] memory) {
        OfferFill[] memory offerFills = twoSellFills(0);
        offerFills[0].units = unitsFirst;
        offerFills[1].units = unitsSecond;
        return offerFills;
    }

    function buyFills(uint256 unitsFirst, uint256 unitsSecond) external view returns (OfferFill[] memory) {
        OfferFill[] memory offerFills = twoBuyFills(0);
        offerFills[0].units = unitsFirst;
        offerFills[1].units = unitsSecond;
        return offerFills;
    }

    function getMarket() external view returns (Market memory) {
        return market;
    }

    /// INVARIANTS ///

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 16
    function invariantBundleHoldsNothing() public view {
        assertEq(loanToken.balanceOf(address(bundle)), 0, "bundle loan balance");
        assertEq(collateralToken.balanceOf(address(bundle)), 0, "bundle collateral balance");
        address[3] memory others = [address(vault), address(adapter), address(midnight)];
        for (uint256 i; i < others.length; i++) {
            assertEq(loanToken.allowance(address(bundle), others[i]), 0, "allowance from bundle");
            assertEq(loanToken.allowance(others[i], address(bundle)), 0, "allowance to bundle");
            assertEq(collateralToken.allowance(address(bundle), others[i]), 0, "collateral allowance from bundle");
        }
        address[7] memory accounts =
            [address(vault), address(adapter), allocator, stranger, borrower, lender, address(handler)];
        for (uint256 i; i < accounts.length; i++) {
            assertFalse(midnight.isAuthorized(accounts[i], address(bundle)), "bundle authorized on Midnight");
        }
    }

    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 16
    function invariantBundleHasNoPositionAndStrangersNeverSucceed() public view {
        assertEq(handler.strangerSuccesses(), 0, "stranger call succeeded");
        (uint128 bundleCredit,,) = midnight.updatePositionView(market, id, address(bundle));
        assertEq(bundleCredit, 0, "bundle credit");
        assertEq(midnight.debt(id, address(bundle)), 0, "bundle debt");
    }

    function afterInvariant() public {
        emit log_named_uint("successes", handler.successes());
        emit log_named_uint("calls", handler.calls());
    }
}
