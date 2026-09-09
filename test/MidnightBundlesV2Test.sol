// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IMidnight, Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {EcrecoverRatifier} from "../lib/midnight/src/ratifiers/EcrecoverRatifier.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "../lib/midnight/src/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {SetterRatifier} from "../lib/midnight/src/ratifiers/SetterRatifier.sol";
import {HashLib} from "../lib/midnight/src/ratifiers/libraries/HashLib.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {CALLBACK_SUCCESS, ORACLE_PRICE_SCALE} from "../lib/midnight/src/libraries/ConstantsLib.sol";
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
    EcrecoverRatifier internal ecrecoverRatifier;
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
    uint256 internal lenderPrivateKey;

    function setUp() public {
        owner = makeAddr("owner");
        (lender, lenderPrivateKey) = makeAddrAndKey("lender");
        borrower = makeAddr("borrower");

        midnight = IMidnight(deployCode("Midnight"));
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        setterRatifier = new SetterRatifier(address(midnight));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));
        blueBuyCallbackFactory = new BlueBuyCallbackFactory(address(midnight), address(morpho));
        offerLog = new Log();
        midnightBundles = new MidnightBundlesV2(
            address(midnight),
            address(morpho),
            address(blueBuyCallbackFactory),
            address(offerLog),
            address(setterRatifier)
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
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            assetsToPark,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
            noBytes32s(),
            abi.encode(offer),
            block.timestamp
        );
    }

    function setterRatifierData(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(root, 0, new bytes32[](0));
    }

    function ecrecoverRatifierData(bytes32 root) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSeparator =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderPrivateKey, digest);
        return abi.encode(Signature({v: v, r: r, s: s}), root, 0, new bytes32[](0));
    }

    function take(Offer memory offer, bytes32 root, uint256 units) internal returns (uint256, uint256) {
        vm.prank(borrower);
        return midnight.take(offer, setterRatifierData(root), units, borrower, borrower, address(0), "");
    }

    function testMakeCombinesFundingCancellationAndPublication() public {
        bytes32 oldRoot = keccak256("old root");
        bytes32 newRoot = keccak256("new root");
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = oldRoot;
        CollateralSupply[] memory supplies = new CollateralSupply[](2);
        supplies[0] = CollateralSupply({collateralIndex: 0, assets: PARKED_ASSETS});
        // Zero supplies must be skipped even if their collateral index is invalid.
        supplies[1] = CollateralSupply({collateralIndex: type(uint256).max, assets: 0});
        deal(address(collateralToken), lender, PARKED_ASSETS);

        vm.startPrank(lender);
        setterRatifier.setIsRootRatified(lender, oldRoot, true);
        collateralToken.approve(address(midnightBundles), PARKED_ASSETS);
        vm.expectEmit(address(offerLog));
        emit Log.Data("combined payload");
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            supplies,
            newRoot,
            groupsToCancel,
            "combined payload",
            block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS);
        assertEq(midnight.collateral(IdLib.toId(midnightMarket), lender, 0), PARKED_ASSETS);
        assertTrue(setterRatifier.isRootRatified(lender, oldRoot));
        assertFalse(ecrecoverRatifier.isRootCanceled(lender, oldRoot));
        assertEq(midnight.consumed(lender, oldRoot), type(uint128).max);
        assertTrue(setterRatifier.isRootRatified(lender, newRoot));
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0);
        assertEq(collateralToken.balanceOf(address(midnightBundles)), 0);
    }

    function testCancelSkipsPublicationWithoutAuthorizingSetter() public {
        MidnightBundlesV2 cancellingBundles = new MidnightBundlesV2(
            address(midnight),
            address(morpho),
            address(blueBuyCallbackFactory),
            address(new RevertingLog()),
            address(setterRatifier)
        );
        bytes32 root = bytes32(0);
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = root;
        MarketParams memory unusedBlueMarket;
        Market memory unusedMarket;

        vm.startPrank(lender);
        midnight.setIsAuthorized(address(cancellingBundles), true, lender);
        setterRatifier.setIsRootRatified(lender, root, true);
        cancellingBundles.midnightBundlesV2Make(
            unusedBlueMarket,
            0,
            bytes32(0),
            unusedMarket,
            noCollateralSupplies(),
            root,
            groupsToCancel,
            "ignored payload",
            block.timestamp
        );
        vm.stopPrank();

        assertTrue(setterRatifier.isRootRatified(lender, root));
        assertEq(midnight.consumed(lender, root), type(uint128).max);
        assertFalse(midnight.isAuthorized(lender, address(setterRatifier)));
        assertEq(callbackOf(lender).code.length, 0);
    }

    function testMakeWithZeroRootSkipsPublication() public {
        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            bytes32(0),
            noBytes32s(),
            "",
            block.timestamp
        );
        assertFalse(setterRatifier.isRootRatified(lender, bytes32(0)));
        assertFalse(midnight.isAuthorized(lender, address(setterRatifier)));
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

    function testMakeWithoutParkingDoesNotCreateCallback() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = makeLendLimit(offer, 0);

        assertEq(blueBuyCallbackFactory.callbackOf(lender, CALLBACK_SALT), address(0), "factory callback");
        assertEq(callbackOf(lender).code.length, 0, "callback code");
        assertTrue(setterRatifier.isRootRatified(lender, root), "root ratification");
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS, "lender balance");
    }

    function testMakePublishesPayload() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory payload = abi.encode(offer);

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
            noBytes32s(),
            payload,
            block.timestamp
        );
    }

    function testMakeIsAtomicWhenLogReverts() public {
        RevertingLog revertingLog = new RevertingLog();
        MidnightBundlesV2 revertingBundles = new MidnightBundlesV2(
            address(midnight),
            address(morpho),
            address(blueBuyCallbackFactory),
            address(revertingLog),
            address(setterRatifier)
        );
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.startPrank(lender);
        loanToken.approve(address(revertingBundles), type(uint256).max);
        midnight.setIsAuthorized(address(revertingBundles), true, lender);
        vm.expectRevert(RevertingLog.Reverted.selector);
        revertingBundles.midnightBundlesV2Make(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
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
            address(midnight), address(morpho), address(inconsistentFactory), address(offerLog), address(setterRatifier)
        );
    }

    function testConstructorRevertsWhenFactoryBlueIsInconsistent() public {
        BlueBuyCallbackFactory inconsistentFactory =
            new BlueBuyCallbackFactory(address(midnight), makeAddr("otherBlue"));

        vm.expectRevert(IMidnightBundlesV2.InconsistentBlue.selector);
        new MidnightBundlesV2(
            address(midnight), address(morpho), address(inconsistentFactory), address(offerLog), address(setterRatifier)
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

    function testRepostCancelsOldGroupAndActivatesNewRoot() public {
        bytes32 group = keccak256("group");
        Offer memory oldOffer = makeOffer(group, PARKED_ASSETS, MAX_TICK);
        bytes32 oldRoot = makeLendLimit(oldOffer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        (uint256 buyerAssets,) = take(oldOffer, oldRoot, 100e18);
        uint256 supplyBeforeRepost = morpho.expectedSupplyAssets(blueMarket, callback);
        assertEq(supplyBeforeRepost, PARKED_ASSETS - buyerAssets, "supply before repost");

        Offer memory newOffer = makeOffer(keccak256("new group"), PARKED_ASSETS, MAX_TICK - 4);
        bytes32 newRoot = HashLib.hashOffer(newOffer);
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = group;

        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newRoot,
            groupsToCancel,
            abi.encode(newOffer),
            block.timestamp
        );

        assertEq(blueBuyCallbackFactory.callbackOf(lender, CALLBACK_SALT), callback, "reused callback");
        assertTrue(setterRatifier.isRootRatified(lender, oldRoot), "old root");
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), supplyBeforeRepost, "reused Blue position");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(oldOffer, setterRatifierData(oldRoot), 1e18, borrower, borrower, address(0), "");

        take(newOffer, newRoot, 1e18);
    }

    function testRepostCancelsGroupsWithoutDeactivatingTheirRoots() public {
        bytes32 firstGroup = keccak256("first group");
        Offer memory firstOldOffer = makeOffer(firstGroup, PARKED_ASSETS, MAX_TICK);
        bytes32 firstOldRoot = makeLendLimit(firstOldOffer, PARKED_ASSETS);

        bytes32 secondGroup = keccak256("second group");
        Offer memory secondOldOffer = makeOffer(secondGroup, PARKED_ASSETS, MAX_TICK - 4);
        bytes32 secondOldRoot = HashLib.hashOffer(secondOldOffer);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            secondOldRoot,
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
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newRoot,
            groupsToCancel,
            abi.encode(newOffer),
            block.timestamp
        );

        assertTrue(setterRatifier.isRootRatified(lender, firstOldRoot), "first old root retained");
        assertTrue(setterRatifier.isRootRatified(lender, secondOldRoot), "second old root retained");
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(midnight.consumed(lender, firstGroup), type(uint128).max, "first group cancelled");
        assertEq(midnight.consumed(lender, secondGroup), type(uint128).max, "second group cancelled");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(firstOldOffer, setterRatifierData(firstOldRoot), 1e18, borrower, borrower, address(0), "");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(secondOldOffer, setterRatifierData(secondOldRoot), 1e18, borrower, borrower, address(0), "");

        take(newOffer, newRoot, 1e18);
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
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
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
        midnight.take(offer, setterRatifierData(root), PARKED_ASSETS + 1, borrower, borrower, address(0), "");

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
        midnightBundles.midnightBundlesV2Make(
            blueMarket, 0, CALLBACK_SALT, market, collateralSupplies, root, noBytes32s(), payload, block.timestamp
        );

        assertEq(midnight.collateral(id, borrower, firstCollateralIndex), firstAssets, "first collateral");
        assertEq(midnight.collateral(id, borrower, secondCollateralIndex), secondAssets, "second collateral");
        assertEq(firstCollateral.balanceOf(address(midnightBundles)), 0, "first bundle balance");
        assertEq(secondCollateral.balanceOf(address(midnightBundles)), 0, "second bundle balance");
        assertTrue(setterRatifier.isRootRatified(borrower, root), "root ratification");

        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        (, uint256 sellerAssets) =
            midnight.take(offer, setterRatifierData(root), 100e18, lender, address(0), address(0), "");
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
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            oldRoot,
            noBytes32s(),
            abi.encode(oldOffer),
            block.timestamp
        );

        Offer memory newOffer = oldOffer;
        newOffer.tick = MAX_TICK - 4;
        bytes32 newRoot = HashLib.hashOffer(newOffer);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newRoot,
            noBytes32s(),
            abi.encode(newOffer),
            block.timestamp
        );

        assertTrue(setterRatifier.isRootRatified(borrower, oldRoot), "old root");
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
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
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

    function testRepostRetainsRootsAndCancelsGroups() public {
        bytes32 oldRoot = keccak256("old root");
        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            oldRoot,
            noBytes32s(),
            abi.encode("old payload"),
            block.timestamp
        );

        bytes32 newRoot = keccak256("new root");
        bytes32 cancelledGroup = keccak256("cancelled group");
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = cancelledGroup;
        bytes memory payload = abi.encode("new payload");

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newRoot,
            groupsToCancel,
            payload,
            block.timestamp
        );

        assertTrue(setterRatifier.isRootRatified(lender, oldRoot), "old root");
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(midnight.consumed(lender, cancelledGroup), type(uint128).max, "cancelled group");
    }

    function testRepostAuthorizesOnlySetterRatifierWhenOnlyBundleIsAuthorized() public {
        Offer memory offer = makeOffer(keccak256("Setter offer"), PARKED_ASSETS, MAX_TICK);
        offer.callback = address(0);
        offer.callbackData = "";
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
            noBytes32s(),
            abi.encode(offer),
            block.timestamp
        );

        assertTrue(midnight.isAuthorized(lender, address(setterRatifier)), "Setter authorization");
        assertFalse(midnight.isAuthorized(lender, address(ecrecoverRatifier)), "Ecrecover authorization");

        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        midnight.take(offer, setterRatifierData(root), 1e18, borrower, borrower, address(0), "");
    }

    function testRepostCancelsEcrecoverOfferGroup() public {
        Offer memory oldOffer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        makeLendLimit(oldOffer, PARKED_ASSETS);
        oldOffer.ratifier = address(ecrecoverRatifier);
        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        bytes32 oldRoot = HashLib.hashOffer(oldOffer);
        bytes memory oldEcrecoverData = ecrecoverRatifierData(oldRoot);

        assertEq(ecrecoverRatifier.isRatified(oldOffer, oldEcrecoverData, address(0)), CALLBACK_SUCCESS);

        Offer memory newOffer = makeOffer(keccak256("replacement group"), PARKED_ASSETS, MAX_TICK - 4);
        bytes32 newRoot = HashLib.hashOffer(newOffer);
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = oldOffer.group;

        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newRoot,
            groupsToCancel,
            abi.encode(newOffer),
            block.timestamp
        );

        assertFalse(ecrecoverRatifier.isRootCanceled(lender, oldRoot), "old Ecrecover root retained");
        assertEq(midnight.consumed(lender, oldOffer.group), type(uint128).max);
        assertTrue(setterRatifier.isRootRatified(lender, newRoot), "new Setter root");

        assertEq(ecrecoverRatifier.isRatified(oldOffer, oldEcrecoverData, address(0)), CALLBACK_SUCCESS);
        take(newOffer, newRoot, 1e18);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(oldOffer, oldEcrecoverData, 1e18, borrower, borrower, address(0), "");
    }

    function testCancelEntrypointInvalidatesOffersOnlyForCaller() public {
        Offer memory firstOffer = makeOffer(keccak256("first group"), PARKED_ASSETS, MAX_TICK);
        bytes32 firstRoot = makeLendLimit(firstOffer, PARKED_ASSETS);
        Offer memory secondOffer = makeOffer(keccak256("second group"), PARKED_ASSETS, MAX_TICK);
        bytes32 secondRoot = makeLendLimit(secondOffer, 0);
        bytes32[] memory groups = new bytes32[](2);
        groups[0] = firstOffer.group;
        groups[1] = secondOffer.group;

        vm.prank(lender);
        midnightBundles.midnightBundlesV2Cancel(groups);

        for (uint256 i; i < groups.length; i++) {
            assertEq(midnight.consumed(lender, groups[i]), type(uint128).max);
            assertEq(midnight.consumed(borrower, groups[i]), 0);
        }
        assertTrue(setterRatifier.isRootRatified(lender, firstRoot));
        assertTrue(setterRatifier.isRootRatified(lender, secondRoot));
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(firstOffer, setterRatifierData(firstRoot), 1e18, borrower, borrower, address(0), "");
        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(secondOffer, setterRatifierData(secondRoot), 1e18, borrower, borrower, address(0), "");
    }

    function testCancelEntrypointRequiresAuthorization() public {
        bytes32[] memory groups = new bytes32[](1);
        groups[0] = keccak256("group");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        midnightBundles.midnightBundlesV2Cancel(groups);

        assertEq(midnight.consumed(borrower, groups[0]), 0);
    }

    function testCancelGroupsRetainsRoots() public {
        bytes32 setterRoot = keccak256("setter root");
        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            setterRoot,
            noBytes32s(),
            abi.encode("payload"),
            block.timestamp
        );

        bytes32 ecrecoverRoot = keccak256("ecrecover root");
        bytes32 group = keccak256("group");
        bytes32[] memory groupsToCancel = new bytes32[](1);
        groupsToCancel[0] = group;

        vm.prank(lender);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            bytes32(0),
            groupsToCancel,
            "",
            block.timestamp
        );

        assertTrue(setterRatifier.isRootRatified(lender, setterRoot), "Setter root");
        assertFalse(ecrecoverRatifier.isRootCanceled(lender, ecrecoverRoot), "Ecrecover root");
        assertEq(midnight.consumed(lender, group), type(uint128).max, "group");
    }

    function testCancelRevertsAfterDeadline() public {
        bytes32 group = keccak256("group");
        bytes32[] memory groups = new bytes32[](1);
        groups[0] = group;

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            bytes32(0),
            groups,
            "",
            block.timestamp - 1
        );

        assertEq(midnight.consumed(lender, group), 0);
    }

    function testTakeRevertsWhenCallbackLoanTokenIsInconsistent() public {
        MarketParams memory inconsistentBlueMarket = blueMarket;
        inconsistentBlueMarket.loanToken = address(collateralToken);
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        offer.callbackData = abi.encode(inconsistentBlueMarket);
        bytes32 root = makeLendLimit(offer, PARKED_ASSETS);

        vm.prank(borrower);
        vm.expectRevert(IBlueBuyCallback.InconsistentLoanToken.selector);
        midnight.take(offer, setterRatifierData(root), 1e18, borrower, borrower, address(0), "");
    }

    function testMakeRevertsAfterDeadline() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);
        uint256 deadline = block.timestamp - 1;

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2Make(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            root,
            noBytes32s(),
            abi.encode(offer),
            deadline
        );
    }
}

contract RevertingLog {
    error Reverted();

    fallback() external {
        revert Reverted();
    }
}
