// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {TickLib, MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {
    WAD,
    ORACLE_PRICE_SCALE,
    DEFAULT_TICK_SPACING,
    maxSettlementFee,
    maxLif
} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";
import {IMidnight} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {MidnightBundlesV1} from "../src/midnight/MidnightBundlesV1.sol";
import {
    IMidnightBundlesV1,
    Take,
    CollateralWithdrawal,
    CollateralSupply
} from "../src/midnight/interfaces/IMidnightBundlesV1.sol";
import {TokenPermit} from "../src/libraries/TokenLib.sol";

contract MidnightBundlesTest is Test {
    using UtilsLib for uint256;

    mapping(address => uint256) internal privateKey;

    IMidnight internal midnight;
    MidnightBundlesV1 internal midnightBundles;
    ERC20 internal loanToken;
    ERC20 internal collateralToken1;
    ERC20 internal collateralToken2;
    Oracle internal oracle1;
    Oracle internal oracle2;
    DummyRatifier internal dummyRatifier;
    address internal borrower;
    address internal lender;

    Market internal market;
    bytes32 internal id;
    Offer[] internal offers;

    function setUp() public {
        midnight = IMidnight(deployCode("Midnight"));
        dummyRatifier = new DummyRatifier();

        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));
        midnight.addLltv(0.77e18);

        uint256 key;
        (borrower, key) = makeAddrAndKey("borrower");
        privateKey[borrower] = key;
        (lender, key) = makeAddrAndKey("lender");
        privateKey[lender] = key;

        vm.prank(borrower);
        midnight.setIsAuthorized(address(dummyRatifier), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(dummyRatifier), true, lender);

        loanToken = new ERC20Permit("loan", "loan");
        collateralToken1 = new ERC20Permit("collat1", "collat1");
        collateralToken2 = new ERC20Permit("collat2", "collat2");
        oracle1 = new Oracle();
        oracle2 = new Oracle();

        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken1.approve(address(midnight), type(uint256).max);
        collateralToken2.approve(address(midnight), type(uint256).max);

        midnightBundles = new MidnightBundlesV1(address(midnight));
        assertEq(midnightBundles.MIDNIGHT(), address(midnight));

        // Set settlement fees to max for all breakpoints.
        midnight.setFeeClaimer(makeAddr("feeClaimer"));
        for (uint256 i; i <= 6; i++) {
            midnight.setDefaultSettlementFee(address(loanToken), i, maxSettlementFee(i));
        }

        market.loanToken = address(loanToken);
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.maturity = vm.getBlockTimestamp() + 100;
        market.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken1),
                    lltv: 0.77e18,
                    maxLif: maxLif(0.77e18, 0.25e18),
                    oracle: address(oracle1)
                })
            );
        market.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken2),
                    lltv: 0.77e18,
                    maxLif: maxLif(0.77e18, 0.25e18),
                    oracle: address(oracle2)
                })
            );
        market.collateralParams = sortCollateralParams(market.collateralParams);
        market.rcfThreshold = 0;

        id = midnight.touchMarket(market);

        offers.push();
        offers[0].buy = true;
        offers[0].maker = lender;
        offers[0].market = market;
        offers[0].ratifier = address(dummyRatifier);
        offers[0].expiry = vm.getBlockTimestamp() + 200;
        offers[0].tick = MAX_TICK;

        offers.push();
        offers[1].buy = true;
        offers[1].maker = lender;
        offers[1].market = market;
        offers[1].ratifier = address(dummyRatifier);
        offers[1].expiry = vm.getBlockTimestamp() + 200;
        offers[1].tick = MAX_TICK;
        offers[1].group = bytes32(uint256(1));

        deal(address(loanToken), lender, type(uint256).max);

        vm.prank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(this), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(midnightBundles), true, lender);
        vm.prank(lender);
        midnight.setIsAuthorized(address(this), true, lender);

        vm.prank(lender);
        loanToken.approve(address(midnightBundles), type(uint256).max);
    }

    function collateralize(Market memory _market, address _borrower, uint256 debt) internal {
        uint256 oraclePrice = Oracle(_market.collateralParams[0].oracle).price();
        uint256 collateral =
            debt.mulDivUp(WAD, _market.collateralParams[0].lltv).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice);
        deal(address(_market.collateralParams[0].token), _borrower, collateral);

        vm.startPrank(_borrower);
        ERC20(_market.collateralParams[0].token).approve(address(midnight), 0);
        ERC20(_market.collateralParams[0].token).approve(address(midnight), collateral);
        midnight.supplyCollateral(_market, 0, collateral, _borrower);
        vm.stopPrank();
    }

    function sortCollateralParams(CollateralParams[] memory arr) internal pure returns (CollateralParams[] memory) {
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 j = i;
            while (j > 0 && bytes20(arr[j].token) < bytes20(arr[j - 1].token)) {
                CollateralParams memory temp = arr[j];
                arr[j] = arr[j - 1];
                arr[j - 1] = temp;
                j--;
            }
        }
        return arr;
    }

    function _noPermit() internal pure returns (TokenPermit memory) {}

    function testUnauthorized() public {
        offers[0].buy = false;
        offers[0].maker = borrower;

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: 100, ratifierData: hex""});

        vm.prank(address(0xdead));
        vm.expectRevert(IMidnightBundlesV1.Unauthorized.selector);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            100,
            0,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );
    }

    function testSellUnitsTarget(uint256 offerUnits0, uint256 offerUnits1, uint256 units) public {
        units = bound(units, 0, uint256(type(uint128).max) * 3 / 4);
        offers[0].maxUnits = offerUnits0;
        offers[1].maxUnits = offerUnits1;
        uint256 fromOffer0 = UtilsLib.min(units, offerUnits0);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: offerUnits0, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: offerUnits1, ratifierData: hex""});

        if (offerUnits1 >= units - fromOffer0) {
            vm.prank(borrower);
            midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
                units, 0, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), block.timestamp
            );

            uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
            uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
            assertEq(consumed0, fromOffer0, "consumed offer 0");
            assertEq(consumed0 + consumed1, midnight.debt(id, borrower), "total consumed");
            assertEq(midnight.debt(id, borrower), units, "debt");
        } else {
            vm.prank(borrower);
            vm.expectRevert(IMidnightBundlesV1.OutOfOffers.selector);
            midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
                units, 0, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), block.timestamp
            );
        }
    }

    function testBuyBuyerAssetsTarget(uint256 offerUnits0, uint256 offerUnits1, uint256 targetBuyerAssets) public {
        targetBuyerAssets = bound(targetBuyerAssets, 1, uint256(type(uint128).max) / 2);

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = offerUnits0;
        offers[1].buy = false;
        offers[1].maker = borrower;
        offers[1].receiverIfMakerIsSeller = borrower;
        offers[1].maxUnits = offerUnits1;

        // Reset settlement fees so buyerPrice = price <= WAD at MAX_TICK.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        // NB: splitting across offers can require 1 extra unit due to per-leg rounding of buyer assets.
        uint256 units = targetBuyerAssets.mulDivUp(WAD, price);
        uint256 fromOffer0 = UtilsLib.min(units, offerUnits0);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: offerUnits0, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: offerUnits1, ratifierData: hex""});

        if (offerUnits1 >= units - fromOffer0) {
            vm.prank(lender);
            midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
                targetBuyerAssets,
                0,
                lender,
                _noPermit(),
                takes,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                block.timestamp
            );

            uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
            uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
            assertEq(consumed0, fromOffer0, "consumed offer 0");
            assertEq(consumed0 + consumed1, midnight.debt(id, borrower), "total consumed");
            assertEq(loanToken.balanceOf(lender), type(uint256).max - targetBuyerAssets, "lender balance");
        } else {
            vm.prank(lender);
            vm.expectRevert(IMidnightBundlesV1.OutOfOffers.selector);
            midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
                targetBuyerAssets,
                0,
                lender,
                _noPermit(),
                takes,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                block.timestamp
            );
        }
    }

    function testBuyUnitsTargetInconsistentMarket() public {
        Market memory otherMarket = market;
        otherMarket.maturity = vm.getBlockTimestamp() + 360 days;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = 1;
        offers[1].buy = false;
        offers[1].maker = borrower;
        offers[1].receiverIfMakerIsSeller = borrower;
        offers[1].market = otherMarket;
        offers[1].maxUnits = 1;

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV1.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            2,
            type(uint256).max,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );
    }

    function testSellUnitsTargetInconsistentMarket() public {
        Market memory otherMarket = market;
        otherMarket.maturity = vm.getBlockTimestamp() + 360 days;

        offers[0].maxUnits = 1;
        offers[1].market = otherMarket;
        offers[1].maxUnits = 1;

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV1.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            2, 0, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), block.timestamp
        );
    }

    function testBuyBuyerAssetsTargetInconsistentMarket() public {
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        Market memory otherMarket = market;
        otherMarket.maturity = vm.getBlockTimestamp() + 360 days;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = 1;
        offers[1].buy = false;
        offers[1].maker = borrower;
        offers[1].receiverIfMakerIsSeller = borrower;
        offers[1].market = otherMarket;
        offers[1].maxUnits = 1;

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV1.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            1000,
            0,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );
    }

    function testSellSellerAssetsTarget(uint256 offerUnits0, uint256 offerUnits1, uint256 targetSellerAssets) public {
        targetSellerAssets = bound(targetSellerAssets, 1, uint256(type(uint128).max) / 2);
        offers[0].maxUnits = offerUnits0;
        offers[1].maxUnits = offerUnits1;

        uint256 fromOffer0;
        uint256 neededFromOffer1;
        {
            uint256 price = TickLib.tickToPrice(MAX_TICK);
            midnight.touchMarket(market);
            uint256 sellerPrice = price - midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
            uint256 units = targetSellerAssets.mulDivUp(WAD, sellerPrice);
            fromOffer0 = UtilsLib.min(units, offerUnits0);
            // Extra collateral headroom for the potential extra unit of debt.
            collateralize(market, borrower, units + 1);
            // Mirror the bundler's exact fill logic to derive units needed from offer1.
            // When offer0 fills everything, filledSellerAssets0 >= targetSellerAssets, zeroFloorSub → 0, so
            // neededFromOffer1 = 0.
            uint256 filledSellerAssets0 = fromOffer0.mulDivDown(sellerPrice, WAD);
            neededFromOffer1 = targetSellerAssets.zeroFloorSub(filledSellerAssets0).mulDivUp(WAD, sellerPrice);
        }

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: offerUnits0, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: offerUnits1, ratifierData: hex""});

        if (offerUnits1 >= neededFromOffer1) {
            vm.prank(borrower);
            midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
                targetSellerAssets,
                type(uint256).max,
                borrower,
                borrower,
                new CollateralSupply[](0),
                takes,
                0,
                address(0),
                block.timestamp
            );

            uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
            uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
            assertEq(consumed0, fromOffer0, "consumed offer 0");
            assertEq(consumed0 + consumed1, midnight.debt(id, borrower), "total consumed");
            assertEq(loanToken.balanceOf(borrower), targetSellerAssets, "borrower balance");
        } else {
            vm.prank(borrower);
            vm.expectRevert(IMidnightBundlesV1.OutOfOffers.selector);
            midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
                targetSellerAssets,
                type(uint256).max,
                borrower,
                borrower,
                new CollateralSupply[](0),
                takes,
                0,
                address(0),
                block.timestamp
            );
        }
    }

    function testSellSellerAssetsTargetInconsistentMarket() public {
        Market memory otherMarket = market;
        otherMarket.maturity = vm.getBlockTimestamp() + 360 days;

        offers[0].maxUnits = 1;
        offers[1].market = otherMarket;
        offers[1].maxUnits = 1;

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV1.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            1000,
            type(uint256).max,
            borrower,
            borrower,
            new CollateralSupply[](0),
            takes,
            0,
            address(0),
            block.timestamp
        );
    }

    // Referral fee.

    function testBuyUnitsTargetWithReferralFee(uint256 units, uint256 referralFeePct) public {
        units = bound(units, 1, uint256(type(uint128).max) / 2);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = type(uint256).max;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 expectedFilledBuyerAssets = units.mulDivUp(price, WAD);
        uint256 expectedFee = expectedFilledBuyerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            units,
            type(uint256).max,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            block.timestamp
        );

        assertEq(midnight.debt(id, borrower), units, "units filled");
        assertEq(loanToken.balanceOf(borrower), expectedFilledBuyerAssets, "maker receipt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(
            type(uint256).max - loanToken.balanceOf(lender), expectedFilledBuyerAssets + expectedFee, "taker total cost"
        );
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testSellUnitsTargetWithReferralFee(uint256 units, uint256 referralFeePct) public {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");
        address receiver = makeAddr("receiver");

        offers[0].maxUnits = type(uint256).max;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        midnight.touchMarket(market);
        uint256 _settlementFee = midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
        uint256 sellerPrice = price - _settlementFee;
        uint256 expectedFilledSellerAssets = units.mulDivDown(sellerPrice, WAD);
        uint256 expectedFee = expectedFilledSellerAssets.mulDivDown(referralFeePct, WAD);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            units, 0, borrower, receiver, new CollateralSupply[](0), takes, referralFeePct, referrer, block.timestamp
        );

        assertEq(midnight.debt(id, borrower), units, "units sold");
        assertEq(loanToken.balanceOf(receiver), expectedFilledSellerAssets - expectedFee, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testBuyBuyerAssetsTargetWithReferralFee(uint256 targetBuyerAssets, uint256 referralFeePct) public {
        targetBuyerAssets = bound(targetBuyerAssets, 1, uint256(type(uint128).max) / 2);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = type(uint256).max;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 expectedFee = targetBuyerAssets.mulDivDown(referralFeePct, WAD);
        uint256 preFeeTarget = targetBuyerAssets - expectedFee;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 units = preFeeTarget.mulDivUp(WAD, price);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets,
            0,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            block.timestamp
        );

        assertEq(type(uint256).max - loanToken.balanceOf(lender), targetBuyerAssets, "taker total cost");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), preFeeTarget, "maker receipt");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testSellSellerAssetsTargetWithReferralFee(uint256 targetSellerAssets, uint256 referralFeePct) public {
        // Bound such that preFeeTarget = target * WAD / (WAD - pct) stays under the uint128 unit ceiling of Midnight.
        targetSellerAssets = bound(targetSellerAssets, 1, uint256(type(uint128).max) / 4);
        referralFeePct = bound(referralFeePct, 0, WAD / 2);
        address referrer = makeAddr("referrer");
        address receiver = makeAddr("receiver");

        offers[0].maxUnits = type(uint256).max;

        uint256 expectedFee = targetSellerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 preFeeTarget = targetSellerAssets + expectedFee;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        midnight.touchMarket(market);
        uint256 _settlementFee = midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
        uint256 sellerPrice = price - _settlementFee;
        uint256 units = preFeeTarget.mulDivUp(WAD, sellerPrice);

        // Extra headroom for per-leg rounding of seller assets.
        collateralize(market, borrower, units + 1);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            targetSellerAssets,
            type(uint256).max,
            borrower,
            receiver,
            new CollateralSupply[](0),
            takes,
            referralFeePct,
            referrer,
            block.timestamp
        );

        assertEq(loanToken.balanceOf(receiver), targetSellerAssets, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testRepayWithReferralFee(uint256 units, uint256 assets, uint256 referralFeePct) public {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = units;

        // Zero settlement fees so the borrower receives exactly units loan tokens for the sale.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        Take[] memory sellTakes = new Take[](1);
        sellTakes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            units, 0, borrower, borrower, new CollateralSupply[](0), sellTakes, 0, address(0), block.timestamp
        );

        // Bound assets so the derived units never exceed outstanding debt.
        uint256 maxAssets = units.mulDivDown(WAD, WAD - referralFeePct);
        assets = bound(assets, 0, maxAssets);
        uint256 expectedFee = assets.mulDivDown(referralFeePct, WAD);
        uint256 expectedUnits = assets - expectedFee;

        // Top up the borrower so they can pay exactly assets.
        deal(address(loanToken), borrower, assets);

        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), assets);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1RepayAndWithdrawCollateral(
            market,
            assets,
            borrower,
            _noPermit(),
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            block.timestamp
        );

        assertEq(midnight.debt(id, borrower), units - expectedUnits, "debt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent assets");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testRepayWithReferralFeeFullDebtInversion(uint256 debt, uint256 referralFeePct) public {
        debt = bound(debt, 1, uint256(type(uint128).max) * 3 / 4);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = debt;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        Take[] memory sellTakes = new Take[](1);
        sellTakes[0] = Take({offer: offers[0], units: debt, ratifierData: hex""});
        collateralize(market, borrower, debt);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            debt, 0, borrower, borrower, new CollateralSupply[](0), sellTakes, 0, address(0), block.timestamp
        );

        uint256 assets = debt.mulDivDown(WAD, WAD - referralFeePct);
        uint256 expectedFee = assets.mulDivDown(referralFeePct, WAD);

        deal(address(loanToken), borrower, assets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), assets);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1RepayAndWithdrawCollateral(
            market,
            assets,
            borrower,
            _noPermit(),
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            block.timestamp
        );

        assertEq(midnight.debt(id, borrower), 0, "debt fully repaid");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent assets");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testPctExceeded() public {
        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});

        offers[0].buy = false;
        Take[] memory buyTakes = new Take[](1);
        buyTakes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});

        vm.startPrank(lender);
        vm.expectRevert(IMidnightBundlesV1.PctExceeded.selector);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            1,
            0,
            lender,
            _noPermit(),
            buyTakes,
            new CollateralWithdrawal[](0),
            address(0),
            WAD,
            address(0),
            block.timestamp
        );
        vm.expectRevert(IMidnightBundlesV1.PctExceeded.selector);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            1,
            0,
            lender,
            _noPermit(),
            buyTakes,
            new CollateralWithdrawal[](0),
            address(0),
            WAD,
            address(0),
            block.timestamp
        );
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(IMidnightBundlesV1.PctExceeded.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            1, 0, borrower, borrower, new CollateralSupply[](0), takes, WAD, address(0), block.timestamp
        );
        vm.expectRevert(IMidnightBundlesV1.PctExceeded.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            1, type(uint256).max, borrower, borrower, new CollateralSupply[](0), takes, WAD, address(0), block.timestamp
        );
        vm.expectRevert(IMidnightBundlesV1.PctExceeded.selector);
        midnightBundles.midnightBundlesV1RepayAndWithdrawCollateral(
            market,
            0,
            borrower,
            _noPermit(),
            new CollateralWithdrawal[](0),
            address(0),
            WAD,
            address(0),
            block.timestamp
        );
        vm.stopPrank();
    }

    function testDeadlinePassed() public {
        uint256 past = block.timestamp - 1;
        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: 1, ratifierData: hex""});

        vm.startPrank(lender);
        vm.expectRevert(IMidnightBundlesV1.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            1, 0, lender, _noPermit(), takes, new CollateralWithdrawal[](0), address(0), 0, address(0), past
        );
        vm.expectRevert(IMidnightBundlesV1.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            1, 0, lender, _noPermit(), takes, new CollateralWithdrawal[](0), address(0), 0, address(0), past
        );
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(IMidnightBundlesV1.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            1, 0, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), past
        );
        vm.expectRevert(IMidnightBundlesV1.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            1, type(uint256).max, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), past
        );
        vm.expectRevert(IMidnightBundlesV1.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV1RepayAndWithdrawCollateral(
            market, 0, borrower, _noPermit(), new CollateralWithdrawal[](0), address(0), 0, address(0), past
        );
        vm.stopPrank();
    }

    // Collateral transfers.

    function _collateralAmount(uint256 collateralIndex, uint256 debt) internal view returns (uint256) {
        uint256 oraclePrice = Oracle(market.collateralParams[collateralIndex].oracle).price();
        return
            debt.mulDivUp(WAD, market.collateralParams[collateralIndex].lltv).mulDivUp(ORACLE_PRICE_SCALE, oraclePrice);
    }

    function _supplyTakerCollateral(address taker, uint256 numCollaterals, uint256 units)
        internal
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            amounts[i] = _collateralAmount(i, units / numCollaterals + 1);
            deal(market.collateralParams[i].token, taker, amounts[i]);
            vm.startPrank(taker);
            ERC20(market.collateralParams[i].token).approve(address(midnight), amounts[i]);
            midnight.supplyCollateral(market, i, amounts[i], taker);
            vm.stopPrank();
        }
    }

    function testBuyUnitsTargetWithCollateralWithdrawals(uint256 numCollaterals) public {
        numCollaterals = bound(numCollaterals, 0, 2);
        uint256 units = 100e18;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        collateralize(market, borrower, units);
        uint256[] memory amounts = _supplyTakerCollateral(lender, numCollaterals, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        address receiver = makeAddr("collateralReceiver");
        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            withdrawals[i] = CollateralWithdrawal({collateralIndex: i, assets: amounts[i] / 4});
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 maxBuyerAssets = units.mulDivUp(price, WAD);

        vm.prank(lender);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            units, maxBuyerAssets, lender, _noPermit(), takes, withdrawals, receiver, 0, address(0), block.timestamp
        );

        for (uint256 i; i < numCollaterals; i++) {
            assertEq(midnight.collateral(id, lender, i), amounts[i] - amounts[i] / 4);
            assertEq(ERC20(market.collateralParams[i].token).balanceOf(receiver), amounts[i] / 4);
        }
    }

    function testBuyBuyerAssetsTargetWithCollateralWithdrawals(uint256 numCollaterals) public {
        numCollaterals = bound(numCollaterals, 0, 2);
        uint256 units = 100e18;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        collateralize(market, borrower, units);
        uint256[] memory amounts = _supplyTakerCollateral(lender, numCollaterals, units);

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 targetBuyerAssets = units.mulDivUp(price, WAD);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        address receiver = makeAddr("collateralReceiver");
        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            withdrawals[i] = CollateralWithdrawal({collateralIndex: i, assets: amounts[i] / 4});
        }

        vm.prank(lender);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets, 0, lender, _noPermit(), takes, withdrawals, receiver, 0, address(0), block.timestamp
        );

        for (uint256 i; i < numCollaterals; i++) {
            assertEq(midnight.collateral(id, lender, i), amounts[i] - amounts[i] / 4);
            assertEq(ERC20(market.collateralParams[i].token).balanceOf(receiver), amounts[i] / 4);
        }
    }

    function testSellUnitsTargetWithCollateralSupplies(uint256 numCollaterals) public {
        numCollaterals = bound(numCollaterals, 1, 2);
        uint256 units = 100e18;

        offers[0].maxUnits = units;

        CollateralSupply[] memory supplies = new CollateralSupply[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            uint256 amount = _collateralAmount(i, units / numCollaterals + 1);
            deal(market.collateralParams[i].token, borrower, amount);
            vm.prank(borrower);
            ERC20(market.collateralParams[i].token).approve(address(midnightBundles), amount);
            supplies[i] = CollateralSupply({collateralIndex: i, assets: amount, permit: _noPermit()});
        }

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            units, 0, borrower, borrower, supplies, takes, 0, address(0), block.timestamp
        );

        for (uint256 i; i < numCollaterals; i++) {
            assertEq(midnight.collateral(id, borrower, i), supplies[i].assets);
        }
        assertEq(midnight.debt(id, borrower), units);
    }

    function testRepay(uint256 units, uint256 repayUnits, uint256 withdrawAssets) public {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        repayUnits = bound(repayUnits, 0, units);

        offers[0].maxUnits = units;

        // Zero settlement fees so the borrower receives exactly `units` loan tokens for the sale,
        // covering any `repayUnits <= units`.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units to get loan token + accumulate debt and collateral on Midnight.
        Take[] memory sellTakes = new Take[](1);
        sellTakes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        uint256 collateralAmount = midnight.collateral(id, borrower, 0);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            units, 0, borrower, borrower, new CollateralSupply[](0), sellTakes, 0, address(0), block.timestamp
        );

        uint256 maxWithdrawable = collateralAmount - _collateralAmount(0, units - repayUnits);
        withdrawAssets = bound(withdrawAssets, 0, maxWithdrawable);
        address collateralReceiver = makeAddr("collateralReceiver");

        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), repayUnits);

        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](1);
        withdrawals[0] = CollateralWithdrawal({collateralIndex: 0, assets: withdrawAssets});

        uint256 borrowerLoanBalanceBefore = loanToken.balanceOf(borrower);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1RepayAndWithdrawCollateral(
            market, repayUnits, borrower, _noPermit(), withdrawals, collateralReceiver, 0, address(0), block.timestamp
        );

        assertEq(midnight.debt(id, borrower), units - repayUnits, "debt");
        assertEq(midnight.collateral(id, borrower, 0), collateralAmount - withdrawAssets, "remaining collateral");
        assertEq(
            ERC20(market.collateralParams[0].token).balanceOf(collateralReceiver), withdrawAssets, "collateral receiver"
        );
        assertEq(loanToken.balanceOf(borrower), borrowerLoanBalanceBefore - repayUnits, "borrower loan balance");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testSellSellerAssetsTargetWithCollateralSupplies(uint256 numCollaterals) public {
        deal(address(loanToken), address(midnightBundles), 0);
        numCollaterals = bound(numCollaterals, 1, 2);
        uint256 units = 100e18;

        offers[0].maxUnits = units;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        midnight.touchMarket(market);
        uint256 _settlementFee = midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
        uint256 sellerPrice = price - _settlementFee;
        uint256 targetSellerAssets = units.mulDivDown(sellerPrice, WAD);

        CollateralSupply[] memory supplies = new CollateralSupply[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            uint256 amount = _collateralAmount(i, units / numCollaterals + 1);
            deal(market.collateralParams[i].token, borrower, amount);
            vm.prank(borrower);
            ERC20(market.collateralParams[i].token).approve(address(midnightBundles), amount);
            supplies[i] = CollateralSupply({collateralIndex: i, assets: amount, permit: _noPermit()});
        }

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            targetSellerAssets, type(uint256).max, borrower, borrower, supplies, takes, 0, address(0), block.timestamp
        );

        for (uint256 i; i < numCollaterals; i++) {
            assertEq(midnight.collateral(id, borrower, i), supplies[i].assets);
        }
        assertEq(loanToken.balanceOf(borrower), targetSellerAssets);
    }

    // Average price.

    function testBuyUnitsTargetAveragePriceExceeded(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units;
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert();
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            units,
            price - 1,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );
    }

    function testSellUnitsTargetAveragePriceTooLow(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].maxUnits = units;
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        uint256 minSellerAssets = units.mulDivDown(price, WAD) + 1;
        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV1.SellerAssetsTooLow.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            units, minSellerAssets, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), block.timestamp
        );
    }

    function testBuyBuyerAssetsTargetAveragePriceExceeded(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units;
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV1.UnitsTooLow.selector);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            units.mulDivUp(price, WAD),
            units + 2,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );
    }

    function testSellSellerAssetsTargetAveragePriceTooLow(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].maxUnits = units;
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);
        uint256 targetSellerAssets = units.mulDivDown(price, WAD);

        collateralize(market, borrower, units);

        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV1.UnitsTooHigh.selector);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            targetSellerAssets,
            price + 1,
            borrower,
            borrower,
            new CollateralSupply[](0),
            takes,
            0,
            address(0),
            block.timestamp
        );
    }

    // Partially consumed offers: _availableUnits caps the units forwarded to take().

    function testSellUnitsTargetPartiallyConsumed() public {
        offers[0].maxUnits = 100;
        offers[1].maxUnits = 100;

        collateralize(market, borrower, 100);

        // Pre-consume 30 of offer 0 (offer.buy=true → maker=lender).
        vm.prank(lender);
        midnight.setConsumed(offers[0].group, 30, lender);

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 100, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 100, ratifierData: hex""});

        // Offer 0 has 70 available; bundler caps and fills 30 from offer 1.
        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(
            100, 0, borrower, borrower, new CollateralSupply[](0), takes, 0, address(0), block.timestamp
        );

        assertEq(midnight.consumed(offers[0].maker, offers[0].group), 100, "consumed offer 0");
        assertEq(midnight.consumed(offers[1].maker, offers[1].group), 30, "consumed offer 1");
        assertEq(midnight.debt(id, borrower), 100, "debt");
    }

    function testSellSellerAssetsTargetPartiallyConsumed() public {
        offers[0].maxUnits = 100;
        offers[1].maxUnits = 100;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        midnight.touchMarket(market);
        uint256 _settlementFee = midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
        uint256 sellerPrice = price - _settlementFee;
        uint256 targetSellerAssets = uint256(100).mulDivDown(sellerPrice, WAD);

        // Extra collateral headroom for the potential extra unit of debt.
        collateralize(market, borrower, 101);

        // Pre-consume 30 of offer 0.
        vm.prank(lender);
        midnight.setConsumed(offers[0].group, 30, lender);

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 100, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 100, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(
            targetSellerAssets,
            type(uint256).max,
            borrower,
            borrower,
            new CollateralSupply[](0),
            takes,
            0,
            address(0),
            block.timestamp
        );

        uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
        uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
        // Offer 0 should hit its cap (consumed 30 + filled up to 70).
        assertEq(consumed0, 100, "consumed offer 0");
        // Total newly filled units equal the borrower's debt.
        assertEq(consumed0 - 30 + consumed1, midnight.debt(id, borrower), "total consumed");
        assertEq(loanToken.balanceOf(borrower), targetSellerAssets, "borrower balance");
    }

    function testBuyUnitsTargetPartiallyConsumed() public {
        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = 100;
        offers[1].buy = false;
        offers[1].maker = borrower;
        offers[1].receiverIfMakerIsSeller = borrower;
        offers[1].maxUnits = 100;

        // Reset settlement fees so buyerPrice = price <= WAD at MAX_TICK.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        collateralize(market, borrower, 100);

        // Pre-consume 30 of offer 0 (offer.buy=false → maker=borrower).
        vm.prank(borrower);
        midnight.setConsumed(offers[0].group, 30, borrower);

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 100, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 100, ratifierData: hex""});

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 maxBuyerAssets = uint256(100).mulDivUp(price, WAD);

        vm.prank(lender);
        midnightBundles.midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(
            100,
            maxBuyerAssets,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );

        assertEq(midnight.consumed(offers[0].maker, offers[0].group), 100, "consumed offer 0");
        assertEq(midnight.consumed(offers[1].maker, offers[1].group), 30, "consumed offer 1");
        assertEq(midnight.debt(id, borrower), 100, "debt");
    }

    function testBuyBuyerAssetsTargetPartiallyConsumed() public {
        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = 100;
        offers[1].buy = false;
        offers[1].maker = borrower;
        offers[1].receiverIfMakerIsSeller = borrower;
        offers[1].maxUnits = 100;

        // Reset settlement fees so buyerPrice = price <= WAD at MAX_TICK.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 targetBuyerAssets = uint256(100).mulDivDown(price, WAD);

        collateralize(market, borrower, 100);

        // Pre-consume 30 of offer 0.
        vm.prank(borrower);
        midnight.setConsumed(offers[0].group, 30, borrower);

        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: offers[0], units: 100, ratifierData: hex""});
        takes[1] = Take({offer: offers[1], units: 100, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets,
            0,
            lender,
            _noPermit(),
            takes,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            block.timestamp
        );

        uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
        uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
        assertEq(consumed0, 100, "consumed offer 0");
        assertEq(consumed0 - 30 + consumed1, midnight.debt(id, borrower), "total consumed");
    }
}
