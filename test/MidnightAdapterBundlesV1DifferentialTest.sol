// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {TickLib} from "../lib/midnight/src/libraries/TickLib.sol";
import {DEFAULT_TICK_SPACING} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {MidnightBundlesV2} from "../src/midnight/MidnightBundlesV2.sol";
import {OfferFill, CollateralTransfer} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";
import {MidnightAdapterBundlesV1Setup} from "./MidnightAdapterBundlesV1Test.sol";

contract BlueBuyCallbackFactoryStubForDifferential {
    address public immutable MIDNIGHT;
    address public immutable BLUE;

    constructor(address _midnight, address _blue) {
        MIDNIGHT = _midnight;
        BLUE = _blue;
    }
}

/// @dev Same market, same offers, same target: a plain user through MidnightBundlesV2 and the vault through
/// MidnightAdapterBundlesV1, each from the same snapshot. Every take must have the same units, buyer assets and seller
/// assets.
/// @dev Where the two legitimately differ, the scenario is set up so that it does not apply:
/// - V2's sells first withdraw the taker's withdrawable credit. Nothing is ever repaid here, so nothing is withdrawable.
/// - V2's reduceOnly, repayment, collateral transfers, referral fee and native token handling are all turned off.
/// - The adapter's guardrails (caps, maxTtm, minNetBuyRate, maxNetSellRate, shortfallAllowance) are opened up, and
///   sales are priced at or above what the vault paid, so none of them rejects a take.
/// - V2's units target type(uint256).max means the user's debt (buys) or credit (sells), and this bundle's means the
///   adapter's credit (sells only): it is not used here.
/// - Takers differ (the user, the adapter); amounts in Midnight do not depend on the taker.
contract MidnightAdapterBundlesV1DifferentialTest is MidnightAdapterBundlesV1Setup {
    MidnightBundlesV2 internal bundleV2;
    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();
        relaxSaleGuardrails();
        collateralize(borrower, 1e27);

        address blue = makeAddr("blue");
        bundleV2 = new MidnightBundlesV2(
            address(midnight),
            blue,
            address(new BlueBuyCallbackFactoryStubForDifferential(address(midnight), blue)),
            makeAddr("log")
        );
        deal(address(loanToken), user, 1e27);
        vm.startPrank(user);
        safeApprove(loanToken, address(bundleV2), type(uint256).max);
        midnight.setIsAuthorized(address(bundleV2), true, user);
        vm.stopPrank();
    }

    function fills(uint256 price, bool buyOffers) internal view returns (OfferFill[] memory offerFills) {
        offerFills = buyOffers ? twoBuyFills(10_000e18) : twoSellFills(10_000e18);
        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);
        offerFills[0].offer.tick = tick;
        offerFills[1].offer.tick = tick;
    }

    /// @dev Gives both takers 15k units of credit, from two separate offers so that the compared offers are untouched.
    function giveBothCredit() internal {
        OfferFill[] memory userFill = new OfferFill[](1);
        userFill[0] = OfferFill({offer: sellOffer(bytes32(uint256(91))), ratifierData: "", units: 15_000e18});
        userFill[0].offer.tick = TickLib.priceToTick(0.5e18, DEFAULT_TICK_SPACING);
        vm.prank(user);
        bundleV2.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            15_000e18,
            1e26,
            false,
            false,
            userFill,
            new CollateralTransfer[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            vm.getBlockTimestamp(),
            address(0)
        );
        OfferFill[] memory vaultFill = new OfferFill[](1);
        vaultFill[0] = userFill[0];
        vaultFill[0].offer.group = bytes32(uint256(92));
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            15_000e18,
            type(uint256).max,
            vaultFill,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
        assertEq(creditOf(user), creditOf(address(adapter)), "same credit");
    }

    function assertSameTakes(TakeRecord[] memory a, TakeRecord[] memory b) internal pure {
        assertEq(a.length, b.length, "same number of takes");
        assertGt(a.length, 0, "some take");
        for (uint256 i; i < a.length; i++) {
            assertEq(a[i].group, b[i].group, "same offer");
            assertEq(a[i].units, b[i].units, "same units");
            assertEq(a[i].buyerAssets, b[i].buyerAssets, "same buyer assets");
            assertEq(a[i].sellerAssets, b[i].sellerAssets, "same seller assets");
        }
    }

    function testDifferentialBuyWithAssetsTarget(uint256 target, uint256 price) public {
        // Two offers of 10k units at 0.5 or more absorb at least 10k assets.
        target = bound(target, 1, 10_000e18);
        price = bound(price, 0.5e18, 0.99e18);
        OfferFill[] memory offerFills = fills(price, false);
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        vm.prank(user);
        bundleV2.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            target,
            0,
            false,
            false,
            offerFills,
            new CollateralTransfer[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            vm.getBlockTimestamp(),
            address(0)
        );
        TakeRecord[] memory v2 = recordedTakes();

        vm.revertToState(snapshot);
        vm.recordLogs();
        buyWithAssets(allocator, target, 0, offerFills);
        assertSameTakes(v2, recordedTakes());
    }

    function testDifferentialBuyWithUnitsTarget(uint256 target, uint256 price) public {
        target = bound(target, 1, 20_000e18);
        price = bound(price, 0.5e18, 0.99e18);
        OfferFill[] memory offerFills = fills(price, false);
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        vm.prank(user);
        bundleV2.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            target,
            // V2 pulls maxBuyerAssets up front and refunds the rest.
            1e26,
            false,
            false,
            offerFills,
            new CollateralTransfer[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            vm.getBlockTimestamp(),
            address(0)
        );
        TakeRecord[] memory v2 = recordedTakes();

        vm.revertToState(snapshot);
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1BuyWithUnitsTarget(
            address(adapter),
            market,
            target,
            type(uint256).max,
            offerFills,
            abi.encode(address(0), bytes("")),
            type(uint256).max,
            vm.getBlockTimestamp()
        );
        assertSameTakes(v2, recordedTakes());
    }

    function testDifferentialSellWithAssetsTarget(uint256 target, uint256 price) public {
        giveBothCredit();
        // Up to 7k assets: at most ~14k units at the lowest seller price, within the 15k units of credit.
        target = bound(target, 1, 7_000e18);
        price = bound(price, 0.51e18, 1e18);
        OfferFill[] memory offerFills = fills(price, true);
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        vm.prank(user);
        bundleV2.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            target,
            type(uint256).max,
            false,
            user,
            new CollateralTransfer[](0),
            offerFills,
            0,
            address(0),
            vm.getBlockTimestamp(),
            address(0)
        );
        TakeRecord[] memory v2 = recordedTakes();

        vm.revertToState(snapshot);
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithAssetsTarget(
            address(adapter), market, target, type(uint256).max, offerFills, vm.getBlockTimestamp()
        );
        assertSameTakes(v2, recordedTakes());
    }

    function testDifferentialSellWithUnitsTarget(uint256 target, uint256 price) public {
        giveBothCredit();
        // Every take of at least 2 units pays at least 1 wei at these prices. A take paying 0 is refused by the
        // adapter's sale rule (see the rounding test) and accepted through V2, so such targets are left out.
        target = bound(target, 2, 15_000e18);
        vm.assume(target <= 10_000e18 || target - 10_000e18 >= 2);
        price = bound(price, 0.51e18, 1e18);
        OfferFill[] memory offerFills = fills(price, true);
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        vm.prank(user);
        bundleV2.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            target,
            0,
            false,
            user,
            new CollateralTransfer[](0),
            offerFills,
            0,
            address(0),
            vm.getBlockTimestamp(),
            address(0)
        );
        TakeRecord[] memory v2 = recordedTakes();

        vm.revertToState(snapshot);
        vm.recordLogs();
        vm.prank(allocator);
        bundle.midnightAdapterBundlesV1SellWithUnitsTarget(
            address(adapter), market, target, 0, offerFills, vm.getBlockTimestamp()
        );
        assertSameTakes(v2, recordedTakes());
    }
}
