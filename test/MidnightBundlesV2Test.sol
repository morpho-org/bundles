// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IMidnight, Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {ISetterRatifier} from "../lib/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {SetterRatifier} from "../lib/midnight/src/ratifiers/SetterRatifier.sol";
import {HashLib} from "../lib/midnight/src/ratifiers/libraries/HashLib.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {BlueBuyCallback} from "../lib/midnight/src/periphery/blue-buy-callback/BlueBuyCallback.sol";
import {BlueBuyCallbackFactory} from "../lib/midnight/src/periphery/blue-buy-callback/BlueBuyCallbackFactory.sol";
import {IBlueBuyCallback} from "../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallback.sol";
import {Log} from "../lib/midnight/src/periphery/log/Log.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {IMorpho, MarketParams} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";
import {MidnightBundlesV2} from "../src/midnight/MidnightBundlesV2.sol";
import {IMidnightBundlesV2, CollateralSupply} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";

contract MidnightBundlesV2Test is Test {
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV = 0.8e18;
    uint128 internal constant PARKED_ASSETS = 1_000e18;
    bytes32 internal constant CALLBACK_SALT = keccak256("callback salt");

    IMidnight internal midnight;
    IMorpho internal morpho;
    SetterRatifier internal setterRatifier;
    BlueBuyCallbackFactory internal blueBuyCallbackFactory;
    Log internal offerLog;
    MidnightBundlesV2 internal midnightBundles;

    ERC20Permit internal loanToken;
    ERC20Permit internal collateralToken;
    Oracle internal midnightOracle;
    OracleMock internal blueOracle;

    Market internal midnightMarket;
    MarketParams internal blueMarket;

    address internal owner;
    address internal lender;
    address internal borrower;

    function setUp() public {
        owner = makeAddr("owner");
        lender = makeAddr("lender");
        borrower = makeAddr("borrower");

        midnight = IMidnight(deployCode("Midnight"));
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        setterRatifier = new SetterRatifier(address(midnight));
        blueBuyCallbackFactory = new BlueBuyCallbackFactory(address(midnight), address(morpho));
        offerLog = new Log();
        midnightBundles = new MidnightBundlesV2(
            address(midnight), address(blueBuyCallbackFactory), address(offerLog), address(setterRatifier)
        );

        assertEq(midnightBundles.MIDNIGHT(), address(midnight));
        assertEq(midnightBundles.BLUE(), address(morpho));
        assertEq(midnightBundles.BLUE_BUY_CALLBACK_FACTORY(), address(blueBuyCallbackFactory));
        assertEq(midnightBundles.LOG(), address(offerLog));
        assertEq(midnightBundles.SETTER_RATIFIER(), address(setterRatifier));

        loanToken = new ERC20Permit("loan", "loan");
        collateralToken = new ERC20Permit("collateral", "collateral");
        midnightOracle = new Oracle();
        blueOracle = new OracleMock();
        blueOracle.setPrice(ORACLE_PRICE_SCALE);

        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));
        midnight.enableLltv(LLTV);
        midnight.enableLiquidationCursor(0.25e18);

        midnightMarket.chainId = block.chainid;
        midnightMarket.midnight = address(midnight);
        midnightMarket.loanToken = address(loanToken);
        midnightMarket.maturity = block.timestamp + 100 days;
        midnightMarket.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken),
                    lltv: LLTV,
                    liquidationCursor: 0.25e18,
                    oracle: address(midnightOracle)
                })
            );
        midnight.touchMarket(midnightMarket);

        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(LLTV);
        vm.stopPrank();

        blueMarket = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(blueOracle),
            irm: address(0),
            lltv: LLTV
        });
        morpho.createMarket(blueMarket);

        deal(address(loanToken), lender, 2 * PARKED_ASSETS);
        deal(address(collateralToken), borrower, 3 * PARKED_ASSETS);

        vm.startPrank(lender);
        loanToken.approve(address(midnightBundles), type(uint256).max);
        midnight.setIsAuthorized(address(midnightBundles), true, lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(midnightMarket, 0, 3 * PARKED_ASSETS, borrower);
        vm.stopPrank();
    }

    /// HELPERS ///

    function noBytes32s() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function noCollateralSupplies() internal pure returns (CollateralSupply[] memory) {
        return new CollateralSupply[](0);
    }

    function callbackOf(address callbackOwner) internal view returns (address) {
        bytes32 initCodeHash = keccak256(
            bytes.concat(
                type(BlueBuyCallback).creationCode, abi.encode(callbackOwner, address(midnight), address(morpho))
            )
        );
        return vm.computeCreate2Address(CALLBACK_SALT, initCodeHash, address(blueBuyCallbackFactory));
    }

    function makeOffer(bytes32 group, uint128 maxAssets, uint256 tick) internal view returns (Offer memory offer) {
        offer.market = midnightMarket;
        offer.buy = true;
        offer.maker = lender;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = tick;
        offer.group = group;
        offer.callback = callbackOf(lender);
        offer.callbackData = abi.encode(blueMarket);
        offer.ratifier = address(setterRatifier);
        offer.maxAssets = maxAssets;
        offer.continuousFeeCap = type(uint256).max;
    }

    function makeBorrowOffer(Market memory market, bytes32 group, uint128 maxAssets, uint256 tick)
        internal
        view
        returns (Offer memory offer)
    {
        offer.market = market;
        offer.buy = false;
        offer.maker = borrower;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = tick;
        offer.group = group;
        offer.receiverIfMakerIsSeller = borrower;
        offer.ratifier = address(setterRatifier);
        offer.maxAssets = maxAssets;
        offer.continuousFeeCap = type(uint256).max;
    }

    function makeMultiCollateralMarket(ERC20Permit firstCollateral, ERC20Permit secondCollateral)
        internal
        view
        returns (Market memory market, uint256 firstCollateralIndex, uint256 secondCollateralIndex)
    {
        CollateralParams[] memory collateralParams = new CollateralParams[](2);
        CollateralParams memory firstParams = CollateralParams({
            token: address(firstCollateral), lltv: LLTV, liquidationCursor: 0.25e18, oracle: address(midnightOracle)
        });
        CollateralParams memory secondParams = CollateralParams({
            token: address(secondCollateral), lltv: LLTV, liquidationCursor: 0.25e18, oracle: address(midnightOracle)
        });

        if (address(firstCollateral) < address(secondCollateral)) {
            collateralParams[0] = firstParams;
            collateralParams[1] = secondParams;
            firstCollateralIndex = 0;
            secondCollateralIndex = 1;
        } else {
            collateralParams[0] = secondParams;
            collateralParams[1] = firstParams;
            firstCollateralIndex = 1;
            secondCollateralIndex = 0;
        }

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collateralParams,
            maturity: block.timestamp + 100 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function makeLendLimit(Offer memory offer, uint256 assetsToPark) internal returns (bytes32 root) {
        root = HashLib.hashOffer(offer);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket,
            assetsToPark,
            CALLBACK_SALT,
            root,
            noBytes32s(),
            noBytes32s(),
            abi.encode(offer),
            block.timestamp
        );
    }

    function ratifierData(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(root, 0, new bytes32[](0));
    }

    function take(Offer memory offer, bytes32 root, uint256 units) internal returns (uint256, uint256) {
        vm.prank(borrower);
        return midnight.take(offer, ratifierData(root), units, borrower, borrower, address(0), "");
    }

    function testMakeParksFundsAndRatifiesRoot() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = makeLendLimit(offer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        assertEq(blueBuyCallbackFactory.callbackOf(lender, CALLBACK_SALT), callback, "factory callback");
        assertEq(BlueBuyCallback(callback).OWNER(), lender, "callback owner");
        assertTrue(morpho.isAuthorized(callback, lender), "owner Blue authorization");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), PARKED_ASSETS, "parked assets");
        assertEq(morpho.expectedSupplyAssets(blueMarket, lender), 0, "lender Blue position");
        assertTrue(midnight.isAuthorized(lender, address(setterRatifier)), "ratifier authorization");
        assertTrue(setterRatifier.isRootRatified(lender, root), "root ratification");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundle balance");
    }

    function testMakePublishesPayload() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory payload = abi.encode(offer);

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket, PARKED_ASSETS, CALLBACK_SALT, root, noBytes32s(), noBytes32s(), payload, block.timestamp
        );
    }

    function testMakeIsAtomicWhenLogReverts() public {
        RevertingLog revertingLog = new RevertingLog();
        MidnightBundlesV2 revertingBundles = new MidnightBundlesV2(
            address(midnight), address(blueBuyCallbackFactory), address(revertingLog), address(setterRatifier)
        );
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.startPrank(lender);
        loanToken.approve(address(revertingBundles), type(uint256).max);
        midnight.setIsAuthorized(address(revertingBundles), true, lender);
        vm.expectRevert(RevertingLog.Reverted.selector);
        revertingBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            root,
            noBytes32s(),
            noBytes32s(),
            abi.encode(offer),
            block.timestamp
        );
        vm.stopPrank();

        assertEq(callbackOf(lender).code.length, 0, "callback deployment rolled back");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), 0, "supply rolled back");
        assertFalse(midnight.isAuthorized(lender, address(setterRatifier)), "ratifier authorization rolled back");
        assertFalse(setterRatifier.isRootRatified(lender, root), "root rolled back");
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS, "funding rolled back");
    }

    function testConstructorRevertsWhenFactoryMidnightIsInconsistent() public {
        BlueBuyCallbackFactory inconsistentFactory =
            new BlueBuyCallbackFactory(makeAddr("otherMidnight"), address(morpho));

        vm.expectRevert(IMidnightBundlesV2.InconsistentMidnight.selector);
        new MidnightBundlesV2(
            address(midnight), address(inconsistentFactory), address(offerLog), address(setterRatifier)
        );
    }

    function testPartialFillsWithdrawFromBlue() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = makeLendLimit(offer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        uint256 firstUnits = 100e18;
        (uint256 firstBuyerAssets, uint256 firstSellerAssets) = take(offer, root, firstUnits);

        assertEq(
            morpho.expectedSupplyAssets(blueMarket, callback), PARKED_ASSETS - firstBuyerAssets, "first Blue withdrawal"
        );
        assertEq(midnight.credit(IdLib.toId(midnightMarket), lender), firstUnits, "first lender credit");
        assertEq(midnight.debt(IdLib.toId(midnightMarket), borrower), firstUnits, "first borrower debt");
        assertEq(loanToken.balanceOf(borrower), firstSellerAssets, "first borrower proceeds");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "first bundle balance");

        uint256 secondUnits = 150e18;
        (uint256 secondBuyerAssets, uint256 secondSellerAssets) = take(offer, root, secondUnits);

        assertEq(
            morpho.expectedSupplyAssets(blueMarket, callback),
            PARKED_ASSETS - firstBuyerAssets - secondBuyerAssets,
            "second Blue withdrawal"
        );
        assertEq(loanToken.balanceOf(borrower), firstSellerAssets + secondSellerAssets, "cumulative borrower proceeds");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "second bundle balance");
    }

    function testRepostDisablesOldRootAndEnablesNewRoot() public {
        bytes32 group = keccak256("group");
        Offer memory oldOffer = makeOffer(group, PARKED_ASSETS, MAX_TICK);
        bytes32 oldRoot = makeLendLimit(oldOffer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        (uint256 buyerAssets,) = take(oldOffer, oldRoot, 100e18);
        uint256 supplyBeforeRepost = morpho.expectedSupplyAssets(blueMarket, callback);
        assertEq(supplyBeforeRepost, PARKED_ASSETS - buyerAssets, "supply before repost");

        Offer memory newOffer = makeOffer(group, PARKED_ASSETS, MAX_TICK - 4);
        bytes32 newRoot = HashLib.hashOffer(newOffer);
        bytes32[] memory rootsToCancel = new bytes32[](1);
        rootsToCancel[0] = oldRoot;

        vm.prank(lender);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket, 0, CALLBACK_SALT, newRoot, rootsToCancel, noBytes32s(), abi.encode(newOffer), block.timestamp
        );

        assertEq(blueBuyCallbackFactory.callbackOf(lender, CALLBACK_SALT), callback, "reused callback");
        assertFalse(setterRatifier.isRootRatified(lender, oldRoot), "old root");
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), supplyBeforeRepost, "reused Blue position");

        vm.prank(borrower);
        vm.expectRevert(ISetterRatifier.NotRatified.selector);
        midnight.take(oldOffer, ratifierData(oldRoot), 1e18, borrower, borrower, address(0), "");

        take(newOffer, newRoot, 1e18);
    }

    function testRepostCancelsGroupsWithoutDisablingTheirRoots() public {
        bytes32 firstGroup = keccak256("first group");
        Offer memory firstOldOffer = makeOffer(firstGroup, PARKED_ASSETS, MAX_TICK);
        bytes32 firstOldRoot = makeLendLimit(firstOldOffer, PARKED_ASSETS);

        bytes32 secondGroup = keccak256("second group");
        Offer memory secondOldOffer = makeOffer(secondGroup, PARKED_ASSETS, MAX_TICK - 4);
        bytes32 secondOldRoot = HashLib.hashOffer(secondOldOffer);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket,
            0,
            CALLBACK_SALT,
            secondOldRoot,
            noBytes32s(),
            noBytes32s(),
            abi.encode(secondOldOffer),
            block.timestamp
        );

        Offer memory newOffer = makeOffer(keccak256("new group"), PARKED_ASSETS, MAX_TICK - 8);
        bytes32 newRoot = HashLib.hashOffer(newOffer);
        bytes32[] memory groupsToCancel = new bytes32[](2);
        groupsToCancel[0] = firstGroup;
        groupsToCancel[1] = secondGroup;

        vm.prank(lender);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket, 0, CALLBACK_SALT, newRoot, noBytes32s(), groupsToCancel, abi.encode(newOffer), block.timestamp
        );

        assertTrue(setterRatifier.isRootRatified(lender, firstOldRoot), "first old root retained");
        assertTrue(setterRatifier.isRootRatified(lender, secondOldRoot), "second old root retained");
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(midnight.consumed(lender, firstGroup), type(uint128).max, "first group cancelled");
        assertEq(midnight.consumed(lender, secondGroup), type(uint128).max, "second group cancelled");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(firstOldOffer, ratifierData(firstOldRoot), 1e18, borrower, borrower, address(0), "");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(secondOldOffer, ratifierData(secondOldRoot), 1e18, borrower, borrower, address(0), "");

        take(newOffer, newRoot, 1e18);
    }

    function testRepostCannotCancelNewRoot() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 newRoot = HashLib.hashOffer(offer);
        bytes32[] memory rootsToCancel = new bytes32[](1);
        rootsToCancel[0] = newRoot;

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.NewRootCannotBeCancelled.selector);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            newRoot,
            rootsToCancel,
            noBytes32s(),
            abi.encode(offer),
            block.timestamp
        );

        assertFalse(setterRatifier.isRootRatified(lender, newRoot), "new root rolled back");
        assertEq(callbackOf(lender).code.length, 0, "callback deployment rolled back");
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS, "funding rolled back");
    }

    function testMakeIsAtomicWhenBundleIsNotAuthorizedOnMidnight() public {
        address unauthorizedLender = makeAddr("unauthorizedLender");
        deal(address(loanToken), unauthorizedLender, PARKED_ASSETS);

        Offer memory offer = makeOffer(keccak256("unauthorized"), PARKED_ASSETS, MAX_TICK);
        offer.maker = unauthorizedLender;
        offer.callback = callbackOf(unauthorizedLender);
        bytes32 root = HashLib.hashOffer(offer);

        vm.startPrank(unauthorizedLender);
        loanToken.approve(address(midnightBundles), type(uint256).max);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            root,
            noBytes32s(),
            noBytes32s(),
            abi.encode(offer),
            block.timestamp
        );
        vm.stopPrank();

        address callback = callbackOf(unauthorizedLender);
        assertEq(callback.code.length, 0, "rolled-back callback deployment");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), 0, "rolled-back supply");
        assertEq(loanToken.balanceOf(unauthorizedLender), PARKED_ASSETS, "rolled-back transfer");
        assertFalse(setterRatifier.isRootRatified(unauthorizedLender, root), "rolled-back root");
    }

    function testTakeRevertsWhenParkedAssetsAreInsufficient() public {
        Offer memory offer = makeOffer(keccak256("group"), 2 * PARKED_ASSETS, MAX_TICK);
        bytes32 root = makeLendLimit(offer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(offer, ratifierData(root), PARKED_ASSETS + 1, borrower, borrower, address(0), "");

        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), PARKED_ASSETS, "rolled-back Blue withdrawal");
        assertEq(midnight.debt(IdLib.toId(midnightMarket), borrower), 0, "rolled-back Midnight take");
    }

    function testBuyerAssetsBoundUsesParkedBluePosition() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        makeLendLimit(offer, PARKED_ASSETS);

        uint256 bound = IBlueBuyCallback(callbackOf(lender))
            .buyerAssetsBound(IdLib.toId(midnightMarket), midnightMarket, lender, abi.encode(blueMarket));

        assertEq(bound, PARKED_ASSETS);
    }

    function testBorrowLimitSuppliesMultipleCollateralAndMakesSellOffer() public {
        ERC20Permit firstCollateral = new ERC20Permit("first collateral", "FIRST");
        ERC20Permit secondCollateral = new ERC20Permit("second collateral", "SECOND");
        (Market memory market, uint256 firstCollateralIndex, uint256 secondCollateralIndex) =
            makeMultiCollateralMarket(firstCollateral, secondCollateral);
        bytes32 id = midnight.touchMarket(market);

        uint256 firstAssets = 400e18;
        uint256 secondAssets = 600e18;
        deal(address(firstCollateral), borrower, firstAssets);
        deal(address(secondCollateral), borrower, secondAssets);

        vm.startPrank(borrower);
        firstCollateral.approve(address(midnightBundles), type(uint256).max);
        secondCollateral.approve(address(midnightBundles), type(uint256).max);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);
        vm.stopPrank();

        CollateralSupply[] memory collateralSupplies = new CollateralSupply[](2);
        collateralSupplies[0] = CollateralSupply({collateralIndex: firstCollateralIndex, assets: firstAssets});
        collateralSupplies[1] = CollateralSupply({collateralIndex: secondCollateralIndex, assets: secondAssets});

        Offer memory offer = makeBorrowOffer(market, keccak256("borrow group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory payload = abi.encode(offer);

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BorrowLimit(
            market, collateralSupplies, root, noBytes32s(), noBytes32s(), payload, block.timestamp
        );

        assertEq(midnight.collateral(id, borrower, firstCollateralIndex), firstAssets, "first collateral");
        assertEq(midnight.collateral(id, borrower, secondCollateralIndex), secondAssets, "second collateral");
        assertEq(firstCollateral.balanceOf(address(midnightBundles)), 0, "first bundle balance");
        assertEq(secondCollateral.balanceOf(address(midnightBundles)), 0, "second bundle balance");
        assertTrue(setterRatifier.isRootRatified(borrower, root), "root ratification");

        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        (, uint256 sellerAssets) = midnight.take(offer, ratifierData(root), 100e18, lender, address(0), address(0), "");
        vm.stopPrank();

        assertEq(loanToken.balanceOf(borrower), sellerAssets, "borrower proceeds");
        assertEq(midnight.debt(id, borrower), 100e18, "borrower debt");
    }

    function testBorrowLimitRepostsWithoutSupplyingCollateral() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);

        Offer memory oldOffer = makeBorrowOffer(midnightMarket, keccak256("borrow group"), PARKED_ASSETS, MAX_TICK);
        bytes32 oldRoot = HashLib.hashOffer(oldOffer);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BorrowLimit(
            midnightMarket,
            noCollateralSupplies(),
            oldRoot,
            noBytes32s(),
            noBytes32s(),
            abi.encode(oldOffer),
            block.timestamp
        );

        Offer memory newOffer = oldOffer;
        newOffer.tick = MAX_TICK - 4;
        bytes32 newRoot = HashLib.hashOffer(newOffer);
        bytes32[] memory rootsToCancel = new bytes32[](1);
        rootsToCancel[0] = oldRoot;

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BorrowLimit(
            midnightMarket,
            noCollateralSupplies(),
            newRoot,
            rootsToCancel,
            noBytes32s(),
            abi.encode(newOffer),
            block.timestamp
        );

        assertFalse(setterRatifier.isRootRatified(borrower, oldRoot), "old root");
        assertTrue(setterRatifier.isRootRatified(borrower, newRoot), "new root");
        assertEq(midnight.collateral(IdLib.toId(midnightMarket), borrower, 0), 3 * PARKED_ASSETS, "collateral");
    }

    function testBorrowLimitSupportsMultiMarketOfferRoot() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);

        Market memory secondMarket = midnightMarket;
        secondMarket.maturity += 1 days;
        midnight.touchMarket(secondMarket);
        deal(address(collateralToken), borrower, PARKED_ASSETS);
        vm.prank(borrower);
        midnight.supplyCollateral(secondMarket, 0, PARKED_ASSETS, borrower);

        Offer memory firstOffer =
            makeBorrowOffer(midnightMarket, keccak256("first borrow group"), PARKED_ASSETS, MAX_TICK);
        Offer memory secondOffer =
            makeBorrowOffer(secondMarket, keccak256("second borrow group"), PARKED_ASSETS, MAX_TICK - 4);
        bytes32 firstHash = HashLib.hashOffer(firstOffer);
        bytes32 secondHash = HashLib.hashOffer(secondOffer);
        bytes32 root = HashLib.hashNode(firstHash, secondHash);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2BorrowLimit(
            midnightMarket,
            noCollateralSupplies(),
            root,
            noBytes32s(),
            noBytes32s(),
            abi.encode(firstOffer, secondOffer),
            block.timestamp
        );

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = secondHash;
        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.take(firstOffer, abi.encode(root, 0, proof), 1e18, lender, address(0), address(0), "");
        proof[0] = firstHash;
        midnight.take(secondOffer, abi.encode(root, 1, proof), 1e18, lender, address(0), address(0), "");
        vm.stopPrank();

        assertEq(midnight.debt(IdLib.toId(midnightMarket), borrower), 1e18, "first market debt");
        assertEq(midnight.debt(IdLib.toId(secondMarket), borrower), 1e18, "second market debt");
    }

    function testCancelAndMakeRepostsAndCancelsGroups() public {
        bytes32 oldRoot = keccak256("old root");
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            oldRoot, noBytes32s(), noBytes32s(), abi.encode("old payload"), block.timestamp
        );

        bytes32 newRoot = keccak256("new root");
        bytes32 cancelledGroup = keccak256("cancelled group");
        bytes32[] memory rootsToCancel = new bytes32[](1);
        rootsToCancel[0] = oldRoot;
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = cancelledGroup;
        bytes memory payload = abi.encode("new payload");

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(newRoot, rootsToCancel, groupsToCancel, payload, block.timestamp);

        assertFalse(setterRatifier.isRootRatified(lender, oldRoot), "old root");
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(midnight.consumed(lender, cancelledGroup), type(uint128).max, "cancelled group");
    }

    function testTakeRevertsWhenCallbackLoanTokenIsInconsistent() public {
        MarketParams memory inconsistentBlueMarket = blueMarket;
        inconsistentBlueMarket.loanToken = address(collateralToken);
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        offer.callbackData = abi.encode(inconsistentBlueMarket);
        bytes32 root = makeLendLimit(offer, PARKED_ASSETS);

        vm.prank(borrower);
        vm.expectRevert(IBlueBuyCallback.InconsistentLoanToken.selector);
        midnight.take(offer, ratifierData(root), 1e18, borrower, borrower, address(0), "");
    }

    function testMakeRevertsAfterDeadline() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);
        uint256 deadline = block.timestamp - 1;

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2LendLimitWithBlueBuyCallback(
            blueMarket, PARKED_ASSETS, CALLBACK_SALT, root, noBytes32s(), noBytes32s(), abi.encode(offer), deadline
        );
    }
}

contract RevertingLog {
    error Reverted();

    fallback() external {
        revert Reverted();
    }
}
