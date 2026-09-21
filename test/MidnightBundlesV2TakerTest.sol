// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {
    WAD,
    ORACLE_PRICE_SCALE,
    DEFAULT_TICK_SPACING,
    MAX_CONTINUOUS_FEE,
    maxSettlementFee
} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";
import {IMidnight} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {TokenLib} from "../src/libraries/TokenLib.sol";
import {MidnightBundlesV2} from "../src/midnight/MidnightBundlesV2.sol";
import {
    IMidnightBundlesV2,
    OfferFill,
    CollateralWithdrawal,
    CollateralSupply
} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";

contract MidnightBundlesV2TakerTest is Test {
    using UtilsLib for uint256;

    mapping(address => uint256) internal privateKey;

    IMidnight internal midnight;
    MidnightBundlesV2 internal midnightBundles;
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
        midnight.enableLltv(0.77e18);
        midnight.enableLiquidationCursor(0.25e18);

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

        address blue = makeAddr("blue");
        BlueBuyCallbackFactoryStub blueBuyCallbackFactory = new BlueBuyCallbackFactoryStub(address(midnight), blue);
        midnightBundles =
            new MidnightBundlesV2(address(midnight), blue, address(blueBuyCallbackFactory), makeAddr("log"));
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
                    liquidationCursor: 0.25e18,
                    oracle: address(oracle1)
                })
            );
        market.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken2),
                    lltv: 0.77e18,
                    liquidationCursor: 0.25e18,
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

    function testBuyRequiresBundleAuthorization(bool assetsTarget, bool repayEnabled) public {
        uint256 units = 100e18;
        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units.toUint128();
        offers[0].tick = MAX_TICK / 2;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        collateralize(market, borrower, units);
        uint256 buyerAssets = units.mulDivUp(TickLib.tickToPrice(offers[0].tick), WAD);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.startPrank(lender);
        midnight.setIsAuthorized(address(midnightBundles), false, lender);
        // Unauthorized takes are skipped; the optional repay bubbles Midnight's authorization error.
        vm.expectRevert(repayEnabled ? IMidnight.Unauthorized.selector : IMidnightBundlesV2.OutOfOffers.selector);
        if (assetsTarget) {
            midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
                market,
                buyerAssets,
                units,
                false,
                repayEnabled,
                offerFills,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        } else {
            midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
                market,
                units,
                buyerAssets,
                false,
                repayEnabled,
                offerFills,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        }
        vm.stopPrank();

        assertEq(midnight.credit(id, lender), 0, "caller credit unchanged");
        assertEq(midnight.debt(id, borrower), 0, "maker debt unchanged");
        assertEq(loanToken.balanceOf(lender), type(uint256).max, "funding rolled back");
    }

    function testSellRequiresBundleAuthorization(bool assetsTarget) public {
        vm.startPrank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), false, borrower);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        if (assetsTarget) {
            midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
                market,
                1,
                type(uint256).max,
                false,
                borrower,
                new CollateralSupply[](0),
                new OfferFill[](0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        } else {
            midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
                market,
                1,
                0,
                false,
                borrower,
                new CollateralSupply[](0),
                new OfferFill[](0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        }
        vm.stopPrank();
    }

    function testBuyUnitsTargetRevertsAboveMaxContinuousFee() public {
        uint256 units = 100e18;
        uint256 continuousFee = MAX_CONTINUOUS_FEE;
        midnight.setMarketContinuousFee(id, continuousFee);

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units.toUint128();
        offers[0].continuousFeeCap = continuousFee;
        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.ContinuousFeeAboveMax.selector);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            units,
            type(uint256).max,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            continuousFee - 1,
            block.timestamp,
            address(0)
        );
    }

    function testSellUnitsTargetRevertsWhenCallbackRaisesContinuousFeeBeforeNextTake() public {
        uint256 firstUnits = 40e18;
        uint256 secondUnits = 60e18;
        uint256 targetUnits = firstUnits + secondUnits;
        ContinuousFeeChangingMidnightFake fakeMidnight = new ContinuousFeeChangingMidnightFake();
        address fakeBlue = makeAddr("fakeBlue");
        BlueBuyCallbackFactoryStub fakeFactory = new BlueBuyCallbackFactoryStub(address(fakeMidnight), fakeBlue);
        MidnightBundlesV2 fakeBundles =
            new MidnightBundlesV2(address(fakeMidnight), fakeBlue, address(fakeFactory), makeAddr("fakeLog"));

        Market memory fakeMarket;
        fakeMarket.chainId = block.chainid;
        fakeMarket.midnight = address(fakeMidnight);
        fakeMarket.loanToken = address(loanToken);
        fakeMarket.maturity = block.timestamp + 100;

        Offer memory firstOffer;
        firstOffer.buy = true;
        firstOffer.maker = lender;
        firstOffer.market = fakeMarket;
        firstOffer.maxUnits = firstUnits.toUint128();
        Offer memory secondOffer = firstOffer;
        secondOffer.group = bytes32(uint256(1));
        secondOffer.maxUnits = secondUnits.toUint128();

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: firstOffer, units: firstUnits, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: secondOffer, units: secondUnits, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.ContinuousFeeAboveMax.selector);
        fakeBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            fakeMarket,
            targetUnits,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            MAX_CONTINUOUS_FEE - 1,
            block.timestamp,
            address(0)
        );
    }

    function testSellUnitsTarget(uint256 offerUnits0, uint256 offerUnits1, uint256 units) public {
        offerUnits0 = bound(offerUnits0, 0, type(uint128).max);
        offerUnits1 = bound(offerUnits1, 0, type(uint128).max);
        units = bound(units, 0, uint256(type(uint128).max) * 3 / 4);
        offers[0].maxUnits = offerUnits0.toUint128();
        offers[1].maxUnits = offerUnits1.toUint128();
        uint256 fromOffer0 = UtilsLib.min(units, offerUnits0);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: offerUnits0, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: offerUnits1, ratifierData: hex""});

        if (offerUnits1 >= units - fromOffer0) {
            vm.prank(borrower);
            midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
                market,
                units,
                0,
                false,
                borrower,
                new CollateralSupply[](0),
                offerFills,
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );

            uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
            uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
            assertEq(consumed0, fromOffer0, "consumed offer 0");
            assertEq(consumed0 + consumed1, midnight.debt(id, borrower), "total consumed");
            assertEq(midnight.debt(id, borrower), units, "debt");
        } else {
            vm.prank(borrower);
            vm.expectRevert(IMidnightBundlesV2.OutOfOffers.selector);
            midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
                market,
                units,
                0,
                false,
                borrower,
                new CollateralSupply[](0),
                offerFills,
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        }
    }

    function testBuyBuyerAssetsTarget(uint256 offerUnits0, uint256 offerUnits1, uint256 targetBuyerAssets) public {
        offerUnits0 = bound(offerUnits0, 0, type(uint128).max);
        offerUnits1 = bound(offerUnits1, 0, type(uint128).max);
        targetBuyerAssets = bound(targetBuyerAssets, 1, uint256(type(uint128).max) / 2);

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = offerUnits0.toUint128();
        offers[1].buy = false;
        offers[1].maker = borrower;
        offers[1].receiverIfMakerIsSeller = borrower;
        offers[1].maxUnits = offerUnits1.toUint128();

        // Reset settlement fees so buyerPrice = price <= WAD at MAX_TICK.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        // NB: splitting across offers can require 1 extra unit due to per-leg rounding of buyer assets.
        uint256 units = targetBuyerAssets.mulDivUp(WAD, price);
        uint256 fromOffer0 = UtilsLib.min(units, offerUnits0);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: offerUnits0, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: offerUnits1, ratifierData: hex""});

        if (offerUnits1 >= units - fromOffer0) {
            vm.prank(lender);
            midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
                market,
                targetBuyerAssets,
                0,
                false,
                true,
                offerFills,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );

            uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
            uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
            assertEq(consumed0, fromOffer0, "consumed offer 0");
            assertEq(consumed0 + consumed1, midnight.debt(id, borrower), "total consumed");
            assertEq(loanToken.balanceOf(lender), type(uint256).max - targetBuyerAssets, "lender balance");
        } else {
            vm.prank(lender);
            vm.expectRevert(IMidnightBundlesV2.OutOfOffers.selector);
            midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
                market,
                targetBuyerAssets,
                0,
                false,
                true,
                offerFills,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            2,
            type(uint256).max,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
    }

    function testSellUnitsTargetInconsistentMarket() public {
        Market memory otherMarket = market;
        otherMarket.maturity = vm.getBlockTimestamp() + 360 days;

        offers[0].maxUnits = 1;
        offers[1].market = otherMarket;
        offers[1].maxUnits = 1;

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            2,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            1000,
            0,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
    }

    function testSellSellerAssetsTarget(uint256 offerUnits0, uint256 offerUnits1, uint256 targetSellerAssets) public {
        offerUnits0 = bound(offerUnits0, 0, type(uint128).max);
        offerUnits1 = bound(offerUnits1, 0, type(uint128).max);
        targetSellerAssets = bound(targetSellerAssets, 1, uint256(type(uint128).max) / 2);
        offers[0].maxUnits = offerUnits0.toUint128();
        offers[1].maxUnits = offerUnits1.toUint128();

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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: offerUnits0, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: offerUnits1, ratifierData: hex""});

        if (offerUnits1 >= neededFromOffer1) {
            vm.prank(borrower);
            midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
                market,
                targetSellerAssets,
                type(uint256).max,
                false,
                borrower,
                new CollateralSupply[](0),
                offerFills,
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );

            uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
            uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
            assertEq(consumed0, fromOffer0, "consumed offer 0");
            assertEq(consumed0 + consumed1, midnight.debt(id, borrower), "total consumed");
            assertEq(loanToken.balanceOf(borrower), targetSellerAssets, "borrower balance");
        } else {
            vm.prank(borrower);
            vm.expectRevert(IMidnightBundlesV2.OutOfOffers.selector);
            midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
                market,
                targetSellerAssets,
                type(uint256).max,
                false,
                borrower,
                new CollateralSupply[](0),
                offerFills,
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        }
    }

    function testSellSellerAssetsTargetInconsistentMarket() public {
        Market memory otherMarket = market;
        otherMarket.maturity = vm.getBlockTimestamp() + 360 days;

        offers[0].maxUnits = 1;
        offers[1].market = otherMarket;
        offers[1].maxUnits = 1;

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 1, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.InconsistentMarket.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            1000,
            type(uint256).max,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
    }

    // reduceOnly.

    function testBuyUnitsTargetReduceOnly(uint256 debtUnits, uint256 buyUnits) public {
        debtUnits = bound(debtUnits, 1, uint256(type(uint128).max) / 4);
        buyUnits = bound(buyUnits, 1, uint256(type(uint128).max) / 4);

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Give the taker (borrower) existing debt to reduce.
        offers[0].maxUnits = debtUnits.toUint128();
        collateralize(market, borrower, debtUnits);
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: debtUnits, ratifierData: hex""});
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            debtUnits,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        assertEq(midnight.debt(id, borrower), debtUnits, "initial debt");

        // Offer for the borrower to buy back units from, funded by the lender.
        Offer memory sellOffer = offers[0];
        sellOffer.buy = false;
        sellOffer.maker = lender;
        sellOffer.receiverIfMakerIsSeller = lender;
        sellOffer.maxUnits = type(uint128).max;
        sellOffer.group = bytes32(uint256(2));

        OfferFill[] memory buyOfferFills = new OfferFill[](1);
        buyOfferFills[0] = OfferFill({offer: sellOffer, units: buyUnits, ratifierData: hex""});

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 maxBuyerAssets = buyUnits.mulDivUp(price, WAD);
        deal(address(loanToken), borrower, maxBuyerAssets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), maxBuyerAssets);

        if (buyUnits > debtUnits) {
            vm.prank(borrower);
            vm.expectRevert(IMidnightBundlesV2.NotReduceOnly.selector);
            midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
                market,
                buyUnits,
                maxBuyerAssets,
                true,
                true,
                buyOfferFills,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
        } else {
            vm.prank(borrower);
            midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
                market,
                buyUnits,
                maxBuyerAssets,
                true,
                false,
                buyOfferFills,
                new CollateralWithdrawal[](0),
                address(0),
                0,
                address(0),
                type(uint256).max,
                block.timestamp,
                address(0)
            );
            assertEq(midnight.debt(id, borrower), debtUnits - buyUnits, "debt reduced");
        }
    }

    // Referral fee.

    function testBuyUnitsTargetWithReferralFee(uint256 units, uint256 referralFeePct) public {
        units = bound(units, 1, uint256(type(uint128).max) / 2);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = type(uint128).max;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 expectedFilledBuyerAssets = units.mulDivUp(price, WAD);
        uint256 expectedFee = expectedFilledBuyerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            units,
            type(uint256).max,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
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

        offers[0].maxUnits = type(uint128).max;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        midnight.touchMarket(market);
        uint256 _settlementFee = midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
        uint256 sellerPrice = price - _settlementFee;
        uint256 expectedFilledSellerAssets = units.mulDivDown(sellerPrice, WAD);
        uint256 expectedFee = expectedFilledSellerAssets.mulDivDown(referralFeePct, WAD);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            receiver,
            new CollateralSupply[](0),
            offerFills,
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
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
        offers[0].maxUnits = type(uint128).max;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 expectedFee = targetBuyerAssets.mulDivDown(referralFeePct, WAD);
        uint256 preFeeTarget = targetBuyerAssets - expectedFee;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 units = preFeeTarget.mulDivUp(WAD, price);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            targetBuyerAssets,
            0,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
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

        offers[0].maxUnits = type(uint128).max;

        uint256 expectedFee = targetSellerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 preFeeTarget = targetSellerAssets + expectedFee;

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        midnight.touchMarket(market);
        uint256 _settlementFee = midnight.settlementFee(id, market.maturity - vm.getBlockTimestamp());
        uint256 sellerPrice = price - _settlementFee;
        uint256 units = preFeeTarget.mulDivUp(WAD, sellerPrice);

        // Extra headroom for per-leg rounding of seller assets.
        collateralize(market, borrower, units + 1);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: type(uint256).max, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            targetSellerAssets,
            type(uint256).max,
            false,
            receiver,
            new CollateralSupply[](0),
            offerFills,
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(loanToken.balanceOf(receiver), targetSellerAssets, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testRepayWithReferralFee(uint256 units, uint256 repayUnits, uint256 referralFeePct) public {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        repayUnits = bound(repayUnits, 0, units);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = units.toUint128();

        // Zero settlement fees so the borrower receives exactly units loan tokens for the sale.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 expectedFee = repayUnits.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 assets = repayUnits + expectedFee;

        // Top up the borrower so they can pay exactly assets.
        deal(address(loanToken), borrower, assets);

        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), assets);

        // Repay through the buy function, with no units bought.
        OfferFill[] memory offerFills = new OfferFill[](0);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            repayUnits,
            assets,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), units - repayUnits, "debt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent assets");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testRepayWithReferralFeeFullDebtAndWithdrawAllCollateral(uint256 debt, uint256 referralFeePct) public {
        debt = bound(debt, 1, uint256(type(uint128).max) * 3 / 4);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");
        address collateralReceiver = makeAddr("collateralReceiver");

        offers[0].maxUnits = debt.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: debt, ratifierData: hex""});
        collateralize(market, borrower, debt);
        uint256 collateralAmount = midnight.collateral(id, borrower, 0);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            debt,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 expectedFee = debt.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 assets = debt + expectedFee;

        deal(address(loanToken), borrower, assets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), assets);

        // Withdrawing all the collateral is only possible because the repay is done before the withdrawals.
        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](1);
        withdrawals[0] = CollateralWithdrawal({collateralIndex: 0, assets: collateralAmount});

        OfferFill[] memory offerFills = new OfferFill[](0);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            debt,
            assets,
            false,
            true,
            offerFills,
            withdrawals,
            collateralReceiver,
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), 0, "debt fully repaid");
        assertEq(midnight.collateral(id, borrower, 0), 0, "collateral fully withdrawn");
        assertEq(
            ERC20(market.collateralParams[0].token).balanceOf(collateralReceiver),
            collateralAmount,
            "collateral receiver"
        );
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent assets");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    // Repay and withdraw steps.

    function testBuyUnitsTargetWithRepay(uint256 units, uint256 buyUnits, uint256 repayUnits, uint256 referralFeePct)
        public
    {
        units = bound(units, 1, uint256(type(uint128).max) / 2);
        buyUnits = bound(buyUnits, 0, units);
        repayUnits = bound(repayUnits, 0, units - buyUnits);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = units.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units to accumulate debt, giving the lender credit to sell back.
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        // Offer for the borrower to buy back units from.
        Offer memory sellOffer = offers[0];
        sellOffer.buy = false;
        sellOffer.maker = lender;
        sellOffer.receiverIfMakerIsSeller = lender;
        sellOffer.maxUnits = type(uint128).max;
        sellOffer.group = bytes32(uint256(2));

        OfferFill[] memory buyOfferFills = new OfferFill[](1);
        buyOfferFills[0] = OfferFill({offer: sellOffer, units: buyUnits, ratifierData: hex""});

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 expectedFilledBuyerAssets = buyUnits.mulDivUp(price, WAD);
        uint256 expectedFee = (expectedFilledBuyerAssets + repayUnits).mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 maxBuyerAssets = expectedFilledBuyerAssets + repayUnits + expectedFee;

        deal(address(loanToken), borrower, maxBuyerAssets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), maxBuyerAssets);

        // The offer only covers buyUnits, the remaining repayUnits are repaid.
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            buyUnits + repayUnits,
            maxBuyerAssets,
            false,
            true,
            buyOfferFills,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), units - buyUnits - repayUnits, "debt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent max");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testBuyBuyerAssetsTargetWithRepay(uint256 targetBuyerAssets, uint256 repayUnits, uint256 referralFeePct)
        public
    {
        targetBuyerAssets = bound(targetBuyerAssets, 1, uint256(type(uint128).max) / 4);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        uint256 expectedFee = targetBuyerAssets.mulDivDown(referralFeePct, WAD);
        repayUnits = bound(repayUnits, 0, targetBuyerAssets - expectedFee);
        uint256 targetFilled = targetBuyerAssets - expectedFee - repayUnits;

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 buyUnits = targetFilled.mulDivUp(WAD, price);
        uint256 debtUnits = buyUnits + repayUnits;

        // Borrower sells units to accumulate debt, giving the lender credit to sell back.
        offers[0].maxUnits = debtUnits.toUint128();
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: debtUnits, ratifierData: hex""});
        collateralize(market, borrower, debtUnits);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            debtUnits,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        // Offer for the borrower to buy back units from.
        Offer memory sellOffer = offers[0];
        sellOffer.buy = false;
        sellOffer.maker = lender;
        sellOffer.receiverIfMakerIsSeller = lender;
        sellOffer.maxUnits = type(uint128).max;
        sellOffer.group = bytes32(uint256(2));

        // The offer only covers buyUnits, the remaining repayUnits are repaid.
        OfferFill[] memory buyOfferFills = new OfferFill[](1);
        buyOfferFills[0] = OfferFill({offer: sellOffer, units: buyUnits, ratifierData: hex""});

        deal(address(loanToken), borrower, targetBuyerAssets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), targetBuyerAssets);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            targetBuyerAssets,
            0,
            false,
            true,
            buyOfferFills,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), 0, "debt fully repaid");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent target");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testBuyUnitsTargetRepayDisabled(uint256 units, uint256 buyUnits, uint256 referralFeePct) public {
        units = bound(units, 1, uint256(type(uint128).max) / 2);
        buyUnits = bound(buyUnits, 0, units);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = units.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units to accumulate debt, giving the lender credit to sell back.
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        // Offer for the borrower to buy back units from.
        Offer memory sellOffer = offers[0];
        sellOffer.buy = false;
        sellOffer.maker = lender;
        sellOffer.receiverIfMakerIsSeller = lender;
        sellOffer.maxUnits = type(uint128).max;
        sellOffer.group = bytes32(uint256(2));

        OfferFill[] memory buyOfferFills = new OfferFill[](1);
        buyOfferFills[0] = OfferFill({offer: sellOffer, units: buyUnits, ratifierData: hex""});

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 expectedFilledBuyerAssets = buyUnits.mulDivUp(price, WAD);
        uint256 expectedFee = expectedFilledBuyerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 maxBuyerAssets = expectedFilledBuyerAssets + expectedFee;

        deal(address(loanToken), borrower, maxBuyerAssets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), maxBuyerAssets);

        // The offers cover the whole target, and the repay is disabled: the remaining debt is untouched.
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            buyUnits,
            maxBuyerAssets,
            false,
            false,
            buyOfferFills,
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), units - buyUnits, "debt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(borrower), 0, "borrower spent max");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testBuyUnitsTargetRepayDisabledOutOfOffers(uint256 units, uint256 repayUnits, uint256 referralFeePct)
        public
    {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        repayUnits = bound(repayUnits, 1, units);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = units.toUint128();

        // Zero settlement fees so the borrower receives exactly units loan tokens for the sale.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 expectedFee = repayUnits.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 assets = repayUnits + expectedFee;

        deal(address(loanToken), borrower, assets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), assets);

        // Without offers and with the repay disabled, nothing can fill the target.
        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.OutOfOffers.selector);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            repayUnits,
            assets,
            false,
            false,
            new OfferFill[](0),
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), units, "debt untouched");
        assertEq(loanToken.balanceOf(borrower), assets, "borrower assets untouched");
        assertEq(loanToken.balanceOf(referrer), 0, "no referrer fee");
    }

    function testBuyBuyerAssetsTargetRepayDisabledOutOfOffers(
        uint256 units,
        uint256 targetBuyerAssets,
        uint256 referralFeePct
    ) public {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        targetBuyerAssets = bound(targetBuyerAssets, 1, units);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");

        offers[0].maxUnits = units.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        deal(address(loanToken), borrower, targetBuyerAssets);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), targetBuyerAssets);

        // Without offers and with the repay disabled, nothing can fill the target.
        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.OutOfOffers.selector);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            targetBuyerAssets,
            0,
            false,
            false,
            new OfferFill[](0),
            new CollateralWithdrawal[](0),
            address(0),
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.debt(id, borrower), units, "debt untouched");
        assertEq(loanToken.balanceOf(borrower), targetBuyerAssets, "borrower assets untouched");
        assertEq(loanToken.balanceOf(referrer), 0, "no referrer fee");
    }

    function testSellUnitsTargetWithWithdraw(
        uint256 units,
        uint256 sellUnits,
        uint256 withdrawUnits,
        uint256 referralFeePct
    ) public {
        units = bound(units, 1, uint256(type(uint128).max) / 2);
        sellUnits = bound(sellUnits, 0, units);
        withdrawUnits = bound(withdrawUnits, 0, units - sellUnits);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        address referrer = makeAddr("referrer");
        address receiver = makeAddr("receiver");

        offers[0].maxUnits = units.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units so the lender holds credit.
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 price = TickLib.tickToPrice(MAX_TICK);

        // Borrower repays withdrawUnits to make them withdrawable, and buys back the units sold by the lender.
        deal(address(loanToken), borrower, withdrawUnits + sellUnits.mulDivUp(price, WAD));
        vm.prank(borrower);
        midnight.repay(market, withdrawUnits, borrower, address(0), "");

        // Buy offer from the borrower for the lender to sell into.
        Offer memory buyOffer = offers[0];
        buyOffer.maker = borrower;
        buyOffer.maxUnits = type(uint128).max;
        buyOffer.group = bytes32(uint256(2));

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOffer, units: sellUnits, ratifierData: hex""});

        uint256 expectedFilledSellerAssets = sellUnits.mulDivDown(price, WAD);
        uint256 expectedFee = (expectedFilledSellerAssets + withdrawUnits).mulDivDown(referralFeePct, WAD);

        // withdrawUnits are withdrawable, the remaining sellUnits are sold to the offer.
        vm.prank(lender);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            sellUnits + withdrawUnits,
            0,
            false,
            receiver,
            new CollateralSupply[](0),
            offerFills,
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.credit(id, lender), units - sellUnits - withdrawUnits, "lender credit");
        assertEq(
            loanToken.balanceOf(receiver), expectedFilledSellerAssets + withdrawUnits - expectedFee, "receiver net"
        );
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testSellSellerAssetsTargetWithWithdraw(
        uint256 targetSellerAssets,
        uint256 withdrawUnits,
        uint256 referralFeePct
    ) public {
        targetSellerAssets = bound(targetSellerAssets, 1, uint256(type(uint128).max) / 4);
        referralFeePct = bound(referralFeePct, 0, WAD / 2);
        address referrer = makeAddr("referrer");
        address receiver = makeAddr("receiver");

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        uint256 expectedFee = targetSellerAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 preFeeTarget = targetSellerAssets + expectedFee;
        withdrawUnits = bound(withdrawUnits, 0, preFeeTarget);

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 sellUnits = (preFeeTarget - withdrawUnits).mulDivUp(WAD, price);
        uint256 creditUnits = sellUnits + withdrawUnits;

        // Borrower sells creditUnits so the lender holds credit.
        offers[0].maxUnits = creditUnits.toUint128();
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: creditUnits, ratifierData: hex""});
        collateralize(market, borrower, creditUnits);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            creditUnits,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        // Borrower repays withdrawUnits to make them withdrawable, and buys back the units sold by the lender.
        deal(address(loanToken), borrower, withdrawUnits + sellUnits.mulDivUp(price, WAD));
        vm.prank(borrower);
        midnight.repay(market, withdrawUnits, borrower, address(0), "");

        // Buy offer from the borrower for the lender to sell into.
        Offer memory buyOffer = offers[0];
        buyOffer.maker = borrower;
        buyOffer.maxUnits = type(uint128).max;
        buyOffer.group = bytes32(uint256(2));

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOffer, units: type(uint256).max, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            targetSellerAssets,
            type(uint256).max,
            false,
            receiver,
            new CollateralSupply[](0),
            offerFills,
            referralFeePct,
            referrer,
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        assertEq(midnight.credit(id, lender), 0, "lender credit");
        assertEq(loanToken.balanceOf(receiver), targetSellerAssets, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundler residual");
    }

    function testSellUnitsTargetWithWithdrawAfterFeeAccrual() public {
        uint256 units = 100e18;
        address receiver = makeAddr("receiver");
        midnight.setMarketContinuousFee(id, MAX_CONTINUOUS_FEE);

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units so the lender holds credit, then repays so that the units are withdrawable.
        offers[0].maxUnits = units.toUint128();
        offers[0].continuousFeeCap = MAX_CONTINUOUS_FEE;
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        deal(address(loanToken), borrower, 2 * units);
        vm.prank(borrower);
        midnight.repay(market, units, borrower, address(0), "");

        // Half of the continuous fee accrues: the stored credit is above the actual credit.
        vm.warp(vm.getBlockTimestamp() + 50);
        uint256 storedCredit = midnight.credit(id, lender);
        (uint128 actualCredit,,) = midnight.updatePositionView(market, id, lender);
        assertGt(storedCredit, actualCredit, "no fee accrued");

        // Buy offer from the borrower for the lender to sell the units not covered by the withdraw.
        Offer memory buyOffer = offers[0];
        buyOffer.maker = borrower;
        buyOffer.maxUnits = type(uint128).max;
        buyOffer.group = bytes32(uint256(2));
        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOffer, units: storedCredit - actualCredit, ratifierData: hex""});
        collateralize(market, lender, storedCredit - actualCredit);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            storedCredit,
            0,
            false,
            receiver,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        assertEq(midnight.credit(id, lender), 0, "lender credit");
        assertEq(midnight.debt(id, lender), storedCredit - actualCredit, "lender debt");
        assertEq(
            loanToken.balanceOf(receiver),
            actualCredit + (storedCredit - actualCredit).mulDivDown(price, WAD),
            "receiver assets"
        );
    }

    function testSellSellerAssetsTargetWithWithdrawAfterFeeAccrual() public {
        uint256 units = 100e18;
        address receiver = makeAddr("receiver");
        midnight.setMarketContinuousFee(id, MAX_CONTINUOUS_FEE);

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units so the lender holds credit, then repays so that the units are withdrawable.
        offers[0].maxUnits = units.toUint128();
        offers[0].continuousFeeCap = MAX_CONTINUOUS_FEE;
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        deal(address(loanToken), borrower, 2 * units);
        vm.prank(borrower);
        midnight.repay(market, units, borrower, address(0), "");

        // Half of the continuous fee accrues: the stored credit is above the actual credit.
        vm.warp(vm.getBlockTimestamp() + 50);
        uint256 storedCredit = midnight.credit(id, lender);
        (uint128 actualCredit,,) = midnight.updatePositionView(market, id, lender);
        assertGt(storedCredit, actualCredit, "no fee accrued");

        // Buy offer from the borrower for the lender to sell the assets not covered by the withdraw.
        Offer memory buyOffer = offers[0];
        buyOffer.maker = borrower;
        buyOffer.maxUnits = type(uint128).max;
        buyOffer.group = bytes32(uint256(2));
        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOffer, units: type(uint256).max, ratifierData: hex""});
        collateralize(market, lender, units);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            storedCredit,
            type(uint256).max,
            false,
            receiver,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        assertEq(midnight.credit(id, lender), 0, "lender credit");
        assertEq(midnight.debt(id, lender), (storedCredit - actualCredit).mulDivUp(WAD, price), "lender debt");
        assertEq(loanToken.balanceOf(receiver), storedCredit, "receiver assets");
    }

    function testPctExceeded() public {
        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});

        offers[0].buy = false;
        OfferFill[] memory buyOfferFills = new OfferFill[](1);
        buyOfferFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});

        vm.startPrank(lender);
        vm.expectRevert(IMidnightBundlesV2.PctExceeded.selector);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            1,
            0,
            false,
            true,
            buyOfferFills,
            new CollateralWithdrawal[](0),
            address(0),
            WAD,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        vm.expectRevert(IMidnightBundlesV2.PctExceeded.selector);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            1,
            0,
            false,
            true,
            buyOfferFills,
            new CollateralWithdrawal[](0),
            address(0),
            WAD,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(IMidnightBundlesV2.PctExceeded.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            1,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            WAD,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        vm.expectRevert(IMidnightBundlesV2.PctExceeded.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            1,
            type(uint256).max,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            WAD,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
        vm.stopPrank();
    }

    function testDeadlinePassed() public {
        uint256 past = block.timestamp - 1;
        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: 1, ratifierData: hex""});

        vm.startPrank(lender);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            1,
            0,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            past,
            address(0)
        );
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            1,
            0,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            past,
            address(0)
        );
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            1,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            past,
            address(0)
        );
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            1,
            type(uint256).max,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            past,
            address(0)
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
        offers[0].maxUnits = units.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        collateralize(market, borrower, units);
        uint256[] memory amounts = _supplyTakerCollateral(lender, numCollaterals, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        address receiver = makeAddr("collateralReceiver");
        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            withdrawals[i] = CollateralWithdrawal({collateralIndex: i, assets: amounts[i] / 4});
        }

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 maxBuyerAssets = units.mulDivUp(price, WAD);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            units,
            maxBuyerAssets,
            false,
            true,
            offerFills,
            withdrawals,
            receiver,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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
        offers[0].maxUnits = units.toUint128();

        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        collateralize(market, borrower, units);
        uint256[] memory amounts = _supplyTakerCollateral(lender, numCollaterals, units);

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 targetBuyerAssets = units.mulDivUp(price, WAD);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        address receiver = makeAddr("collateralReceiver");
        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            withdrawals[i] = CollateralWithdrawal({collateralIndex: i, assets: amounts[i] / 4});
        }

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            targetBuyerAssets,
            0,
            false,
            true,
            offerFills,
            withdrawals,
            receiver,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        for (uint256 i; i < numCollaterals; i++) {
            assertEq(midnight.collateral(id, lender, i), amounts[i] - amounts[i] / 4);
            assertEq(ERC20(market.collateralParams[i].token).balanceOf(receiver), amounts[i] / 4);
        }
    }

    function testSellUnitsTargetWithCollateralSupplies(uint256 numCollaterals) public {
        numCollaterals = bound(numCollaterals, 1, 2);
        uint256 units = 100e18;

        offers[0].maxUnits = units.toUint128();

        CollateralSupply[] memory supplies = new CollateralSupply[](numCollaterals);
        for (uint256 i; i < numCollaterals; i++) {
            uint256 amount = _collateralAmount(i, units / numCollaterals + 1);
            deal(market.collateralParams[i].token, borrower, amount);
            vm.prank(borrower);
            ERC20(market.collateralParams[i].token).approve(address(midnightBundles), amount);
            supplies[i] = CollateralSupply({collateralIndex: i, assets: amount});
        }

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            supplies,
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        for (uint256 i; i < numCollaterals; i++) {
            assertEq(midnight.collateral(id, borrower, i), supplies[i].assets);
        }
        assertEq(midnight.debt(id, borrower), units);
    }

    function testRepay(uint256 units, uint256 repayUnits, uint256 withdrawAssets) public {
        units = bound(units, 1, uint256(type(uint128).max) * 3 / 4);
        repayUnits = bound(repayUnits, 0, units);

        offers[0].maxUnits = units.toUint128();

        // Zero settlement fees so the borrower receives exactly `units` loan tokens for the sale,
        // covering any `repayUnits <= units`.
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }

        // Borrower sells units to get loan token + accumulate debt and collateral on Midnight.
        OfferFill[] memory sellOfferFills = new OfferFill[](1);
        sellOfferFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});
        collateralize(market, borrower, units);
        uint256 collateralAmount = midnight.collateral(id, borrower, 0);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            sellOfferFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 maxWithdrawable = collateralAmount - _collateralAmount(0, units - repayUnits);
        withdrawAssets = bound(withdrawAssets, 0, maxWithdrawable);
        address collateralReceiver = makeAddr("collateralReceiver");

        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), repayUnits);

        CollateralWithdrawal[] memory withdrawals = new CollateralWithdrawal[](1);
        withdrawals[0] = CollateralWithdrawal({collateralIndex: 0, assets: withdrawAssets});

        uint256 borrowerLoanBalanceBefore = loanToken.balanceOf(borrower);

        // Repay and withdraw collateral through the buy function, with no units bought.
        OfferFill[] memory offerFills = new OfferFill[](0);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            repayUnits,
            repayUnits,
            false,
            true,
            offerFills,
            withdrawals,
            collateralReceiver,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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

        offers[0].maxUnits = units.toUint128();

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
            supplies[i] = CollateralSupply({collateralIndex: i, assets: amount});
        }

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            targetSellerAssets,
            type(uint256).max,
            false,
            borrower,
            supplies,
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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
        offers[0].maxUnits = units.toUint128();
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert();
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            units,
            price - 1,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
    }

    function testSellUnitsTargetAveragePriceTooLow(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].maxUnits = units.toUint128();
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        uint256 minSellerAssets = units.mulDivDown(price, WAD) + 1;
        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.SellerAssetsTooLow.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            units,
            minSellerAssets,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
    }

    function testBuyBuyerAssetsTargetAveragePriceExceeded(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].buy = false;
        offers[0].maker = borrower;
        offers[0].receiverIfMakerIsSeller = borrower;
        offers[0].maxUnits = units.toUint128();
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.UnitsTooLow.selector);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            units.mulDivUp(price, WAD),
            units + 2,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );
    }

    function testSellSellerAssetsTargetAveragePriceTooLow(uint256 tick) public {
        tick = bound(tick, 1, MAX_TICK / DEFAULT_TICK_SPACING) * DEFAULT_TICK_SPACING;
        uint256 units = 100e18;

        offers[0].maxUnits = units.toUint128();
        offers[0].tick = tick;
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, 0);
        }
        uint256 price = TickLib.tickToPrice(tick);
        uint256 targetSellerAssets = units.mulDivDown(price, WAD);

        collateralize(market, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offers[0], units: units, ratifierData: hex""});

        vm.prank(borrower);
        vm.expectRevert(IMidnightBundlesV2.UnitsTooHigh.selector);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            targetSellerAssets,
            price + 1,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 100, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 100, ratifierData: hex""});

        // Offer 0 has 70 available; bundler caps and fills 30 from offer 1.
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
            market,
            100,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 100, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 100, ratifierData: hex""});

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
            market,
            targetSellerAssets,
            type(uint256).max,
            false,
            borrower,
            new CollateralSupply[](0),
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 100, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 100, ratifierData: hex""});

        uint256 price = TickLib.tickToPrice(MAX_TICK);
        uint256 maxBuyerAssets = uint256(100).mulDivUp(price, WAD);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
            market,
            100,
            maxBuyerAssets,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
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

        OfferFill[] memory offerFills = new OfferFill[](2);
        offerFills[0] = OfferFill({offer: offers[0], units: 100, ratifierData: hex""});
        offerFills[1] = OfferFill({offer: offers[1], units: 100, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
            market,
            targetBuyerAssets,
            0,
            false,
            true,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(0)
        );

        uint256 consumed0 = midnight.consumed(offers[0].maker, offers[0].group);
        uint256 consumed1 = midnight.consumed(offers[1].maker, offers[1].group);
        assertEq(consumed0, 100, "consumed offer 0");
        assertEq(consumed0 - 30 + consumed1, midnight.debt(id, borrower), "total consumed");
    }

    // Native wrapping.

    /// @dev Market whose loan token is the wrapped-native token, so buys can be funded with native tokens.
    function wethLoanMarket(WETHMock weth) internal returns (Market memory wethMarket) {
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token: address(collateralToken1), lltv: 0.77e18, liquidationCursor: 0.25e18, oracle: address(oracle1)
        });

        wethMarket.chainId = block.chainid;
        wethMarket.midnight = address(midnight);
        wethMarket.loanToken = address(weth);
        wethMarket.maturity = vm.getBlockTimestamp() + 100;
        wethMarket.collateralParams = collateralParams;

        bytes32 wethId = midnight.touchMarket(wethMarket);
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(wethId, i, 0);
        }
    }

    function sellOfferOn(Market memory _market, uint256 units) internal view returns (Offer memory offer) {
        offer.buy = false;
        offer.maker = borrower;
        offer.receiverIfMakerIsSeller = borrower;
        offer.market = _market;
        offer.ratifier = address(dummyRatifier);
        offer.expiry = vm.getBlockTimestamp() + 200;
        offer.tick = MAX_TICK;
        offer.maxUnits = units.toUint128();
    }

    function testBuyUnitsTargetWrapNativeAndReturnWrappedRemainder(uint256 extraAssets) public {
        extraAssets = bound(extraAssets, 0, 1e24);
        uint256 units = 100e18;

        WETHMock weth = new WETHMock();
        Market memory wethMarket = wethLoanMarket(weth);
        Offer memory offer = sellOfferOn(wethMarket, units);
        collateralize(wethMarket, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offer, units: units, ratifierData: hex""});

        uint256 expectedFilledBuyerAssets = units.mulDivUp(TickLib.tickToPrice(MAX_TICK), WAD);
        uint256 maxBuyerAssets = expectedFilledBuyerAssets + extraAssets;
        deal(lender, maxBuyerAssets);
        vm.prank(lender);
        weth.approve(address(midnightBundles), type(uint256).max);

        // The native tokens are wrapped for the lender before the regular token pull.
        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral{value: maxBuyerAssets}(
            wethMarket,
            units,
            maxBuyerAssets,
            false,
            false,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(midnight.debt(IdLib.toId(wethMarket), borrower), units, "units bought");
        assertEq(weth.balanceOf(borrower), expectedFilledBuyerAssets, "maker receipt");
        assertEq(lender.balance, 0, "native wrapped");
        assertEq(weth.balanceOf(lender), extraAssets, "wrapped refund");
        assertEq(address(midnightBundles).balance, 0, "bundler native residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
    }

    function testBuyAssetsTargetWrapNative() public {
        uint256 units = 100e18;

        WETHMock weth = new WETHMock();
        Market memory wethMarket = wethLoanMarket(weth);
        Offer memory offer = sellOfferOn(wethMarket, units);
        collateralize(wethMarket, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offer, units: units, ratifierData: hex""});

        uint256 targetBuyerAssets = units.mulDivDown(TickLib.tickToPrice(MAX_TICK), WAD);
        deal(lender, targetBuyerAssets);
        vm.prank(lender);
        weth.approve(address(midnightBundles), type(uint256).max);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral{value: targetBuyerAssets}(
            wethMarket,
            targetBuyerAssets,
            0,
            false,
            false,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(weth.balanceOf(borrower), targetBuyerAssets, "maker receipt");
        assertEq(lender.balance, 0, "lender native residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
    }

    function testSellUnitsTargetWrapNativeCollateral() public {
        uint256 units = 100e18;
        WETHMock weth = new WETHMock();

        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token: address(weth), lltv: 0.77e18, liquidationCursor: 0.25e18, oracle: address(oracle1)
        });

        Market memory wethCollateralMarket;
        wethCollateralMarket.chainId = block.chainid;
        wethCollateralMarket.midnight = address(midnight);
        wethCollateralMarket.loanToken = address(loanToken);
        wethCollateralMarket.maturity = vm.getBlockTimestamp() + 100;
        wethCollateralMarket.collateralParams = collateralParams;

        bytes32 wethCollateralId = midnight.touchMarket(wethCollateralMarket);
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(wethCollateralId, i, 0);
        }

        Offer memory buyOffer;
        buyOffer.buy = true;
        buyOffer.maker = lender;
        buyOffer.market = wethCollateralMarket;
        buyOffer.ratifier = address(dummyRatifier);
        buyOffer.expiry = vm.getBlockTimestamp() + 200;
        buyOffer.tick = MAX_TICK;
        buyOffer.maxUnits = units.toUint128();

        uint256 collateralAssets = units.mulDivUp(WAD, 0.77e18).mulDivUp(ORACLE_PRICE_SCALE, oracle1.price());
        CollateralSupply[] memory supplies = new CollateralSupply[](1);
        supplies[0] = CollateralSupply({collateralIndex: 0, assets: collateralAssets});

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOffer, units: units, ratifierData: hex""});

        deal(borrower, collateralAssets);
        vm.prank(borrower);
        weth.approve(address(midnightBundles), type(uint256).max);

        // The collateral is funded with native tokens, wrapped by the bundler before being supplied.
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget{value: collateralAssets}(
            wethCollateralMarket,
            units,
            0,
            false,
            borrower,
            supplies,
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(midnight.collateral(wethCollateralId, borrower, 0), collateralAssets, "collateral supplied");
        assertEq(midnight.debt(wethCollateralId, borrower), units, "debt");
        assertEq(borrower.balance, 0, "borrower native residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
    }

    /// @dev Market with two collaterals: the wrapped-native token and collateralToken1, sorted by address.
    function wethAndTokenCollateralMarket(WETHMock weth)
        internal
        returns (Market memory wethCollateralMarket, uint256 wethIndex)
    {
        CollateralParams memory wethParams = CollateralParams({
            token: address(weth), lltv: 0.77e18, liquidationCursor: 0.25e18, oracle: address(oracle1)
        });
        CollateralParams memory tokenParams = CollateralParams({
            token: address(collateralToken1), lltv: 0.77e18, liquidationCursor: 0.25e18, oracle: address(oracle1)
        });

        CollateralParams[] memory collateralParams = new CollateralParams[](2);
        wethIndex = address(weth) < address(collateralToken1) ? 0 : 1;
        collateralParams[wethIndex] = wethParams;
        collateralParams[1 - wethIndex] = tokenParams;

        wethCollateralMarket.chainId = block.chainid;
        wethCollateralMarket.midnight = address(midnight);
        wethCollateralMarket.loanToken = address(loanToken);
        wethCollateralMarket.maturity = vm.getBlockTimestamp() + 100;
        wethCollateralMarket.collateralParams = collateralParams;

        bytes32 wethCollateralId = midnight.touchMarket(wethCollateralMarket);
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(wethCollateralId, i, 0);
        }
    }

    function buyOfferOn(Market memory _market, uint256 units) internal view returns (Offer memory offer) {
        offer.buy = true;
        offer.maker = lender;
        offer.market = _market;
        offer.ratifier = address(dummyRatifier);
        offer.expiry = vm.getBlockTimestamp() + 200;
        offer.tick = MAX_TICK;
        offer.maxUnits = units.toUint128();
    }

    function testSellUnitsTargetWrapNativeAndPullBothCollaterals() public {
        uint256 units = 100e18;
        WETHMock weth = new WETHMock();
        (Market memory wethCollateralMarket, uint256 wethIndex) = wethAndTokenCollateralMarket(weth);
        bytes32 wethCollateralId = IdLib.toId(wethCollateralMarket);

        // Each collateral covers half of the debt.
        uint256 collateralAssets = (units / 2 + 1).mulDivUp(WAD, 0.77e18).mulDivUp(ORACLE_PRICE_SCALE, oracle1.price());
        // Both collaterals are pulled from the borrower; the wrapped-native one need not come first.
        CollateralSupply[] memory supplies = new CollateralSupply[](2);
        supplies[0] = CollateralSupply({collateralIndex: 1 - wethIndex, assets: collateralAssets});
        supplies[1] = CollateralSupply({collateralIndex: wethIndex, assets: collateralAssets});

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOfferOn(wethCollateralMarket, units), units: units, ratifierData: hex""});

        deal(borrower, collateralAssets);
        deal(address(collateralToken1), borrower, collateralAssets);
        vm.prank(borrower);
        weth.approve(address(midnightBundles), type(uint256).max);
        vm.prank(borrower);
        collateralToken1.approve(address(midnightBundles), collateralAssets);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget{value: collateralAssets}(
            wethCollateralMarket,
            units,
            0,
            false,
            borrower,
            supplies,
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(midnight.collateral(wethCollateralId, borrower, wethIndex), collateralAssets, "wrapped collateral");
        assertEq(midnight.collateral(wethCollateralId, borrower, 1 - wethIndex), collateralAssets, "pulled collateral");
        assertEq(midnight.debt(wethCollateralId, borrower), units, "debt");
        assertEq(borrower.balance, 0, "borrower native residual");
        assertEq(collateralToken1.balanceOf(borrower), 0, "borrower token residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
        assertEq(collateralToken1.balanceOf(address(midnightBundles)), 0, "bundler token residual");
    }

    function testSellSellerAssetsTargetWrapNativeAndPullBothCollaterals() public {
        uint256 units = 100e18;
        WETHMock weth = new WETHMock();
        (Market memory wethCollateralMarket, uint256 wethIndex) = wethAndTokenCollateralMarket(weth);
        bytes32 wethCollateralId = IdLib.toId(wethCollateralMarket);

        // Each collateral covers half of the debt.
        uint256 collateralAssets = (units / 2 + 1).mulDivUp(WAD, 0.77e18).mulDivUp(ORACLE_PRICE_SCALE, oracle1.price());
        // Both collaterals are pulled from the borrower; the wrapped-native one need not come first.
        CollateralSupply[] memory supplies = new CollateralSupply[](2);
        supplies[0] = CollateralSupply({collateralIndex: 1 - wethIndex, assets: collateralAssets});
        supplies[1] = CollateralSupply({collateralIndex: wethIndex, assets: collateralAssets});

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: buyOfferOn(wethCollateralMarket, units), units: units, ratifierData: hex""});

        deal(borrower, collateralAssets);
        deal(address(collateralToken1), borrower, collateralAssets);
        vm.prank(borrower);
        weth.approve(address(midnightBundles), type(uint256).max);
        vm.prank(borrower);
        collateralToken1.approve(address(midnightBundles), collateralAssets);

        uint256 targetSellerAssets = units.mulDivDown(TickLib.tickToPrice(MAX_TICK), WAD);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget{value: collateralAssets}(
            wethCollateralMarket,
            targetSellerAssets,
            units,
            false,
            borrower,
            supplies,
            offerFills,
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(midnight.collateral(wethCollateralId, borrower, wethIndex), collateralAssets, "wrapped collateral");
        assertEq(midnight.collateral(wethCollateralId, borrower, 1 - wethIndex), collateralAssets, "pulled collateral");
        assertEq(loanToken.balanceOf(borrower), targetSellerAssets, "seller assets");
        assertEq(borrower.balance, 0, "borrower native residual");
        assertEq(collateralToken1.balanceOf(borrower), 0, "borrower token residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
        assertEq(collateralToken1.balanceOf(address(midnightBundles)), 0, "bundler token residual");
    }

    function testBuyUnitsTargetCombinesNativeAndExistingWrappedNative() public {
        uint256 units = 100e18;

        WETHMock weth = new WETHMock();
        Market memory wethMarket = wethLoanMarket(weth);
        Offer memory offer = sellOfferOn(wethMarket, units);
        collateralize(wethMarket, borrower, units);

        OfferFill[] memory offerFills = new OfferFill[](1);
        offerFills[0] = OfferFill({offer: offer, units: units, ratifierData: hex""});

        uint256 maxBuyerAssets = units.mulDivUp(TickLib.tickToPrice(MAX_TICK), WAD);
        deal(lender, maxBuyerAssets);
        deal(address(weth), lender, 1);
        vm.prank(lender);
        weth.approve(address(midnightBundles), type(uint256).max);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral{value: maxBuyerAssets - 1}(
            wethMarket,
            units,
            maxBuyerAssets,
            false,
            false,
            offerFills,
            new CollateralWithdrawal[](0),
            address(0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(weth.balanceOf(lender), 0, "existing wrapped native used");
    }

    function testSellUnitsTargetWrapsNativeWithoutAssetMovement() public {
        WETHMock weth = new WETHMock();
        deal(borrower, 1 ether);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget{value: 1 ether}(
            market,
            0,
            0,
            false,
            borrower,
            new CollateralSupply[](0),
            new OfferFill[](0),
            0,
            address(0),
            type(uint256).max,
            block.timestamp,
            address(weth)
        );

        assertEq(address(midnightBundles).balance, 0, "no native left in the bundle");
        assertEq(borrower.balance, 0, "native wrapped");
        assertEq(weth.balanceOf(borrower), 1 ether, "wrapped native sent to the borrower");
    }
}

contract ContinuousFeeChangingMidnightFake {
    uint256 internal continuousFeeValue;
    uint256 internal takeCalls;

    function touchMarket(Market memory market) external pure returns (bytes32) {
        return IdLib.toId(market);
    }

    function continuousFee(bytes32) external view returns (uint256) {
        return continuousFeeValue;
    }

    function consumed(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function updatePositionView(Market memory, bytes32, address) external pure returns (uint128, uint128, uint128) {
        return (0, 0, 0);
    }

    function withdrawable(bytes32) external pure returns (uint128) {
        return 0;
    }

    function withdraw(Market memory, uint256, address, address) external {}

    function take(Offer memory, bytes memory, uint256, address, address, address, bytes memory)
        external
        returns (uint256, uint256)
    {
        takeCalls++;
        if (takeCalls == 1) continuousFeeValue = MAX_CONTINUOUS_FEE;
        return (0, 0);
    }
}

/// @dev Only satisfies MidnightBundlesV2's constructor check; the taker functions never call the factory.
contract BlueBuyCallbackFactoryStub {
    address public immutable MIDNIGHT;
    address public immutable BLUE;

    constructor(address _midnight, address _blue) {
        MIDNIGHT = _midnight;
        BLUE = _blue;
    }
}

/// @dev Minimal wrapped-native token: deposit() mints 1:1 for the native tokens sent.
contract WETHMock is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
}
