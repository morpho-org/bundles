// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IMidnight, Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {EcrecoverRatifier} from "../lib/midnight/src/ratifiers/EcrecoverRatifier.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "../lib/midnight/src/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {RateRatifierV1} from "../lib/midnight/src/ratifiers/RateRatifierV1.sol";
import {PriceRatifierV1} from "../lib/midnight/src/ratifiers/PriceRatifierV1.sol";
import {IPriceRatifierV1} from "../lib/midnight/src/ratifiers/interfaces/IPriceRatifierV1.sol";
import {IRateRatifierV1} from "../lib/midnight/src/ratifiers/interfaces/IRateRatifierV1.sol";
import {IRatifiersV1Common} from "../lib/midnight/src/ratifiers/interfaces/IRatifiersV1Common.sol";
import {HashLib} from "../lib/midnight/src/ratifiers/libraries/HashLib.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {CALLBACK_SUCCESS, ORACLE_PRICE_SCALE} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {BlueBuyCallback} from "../lib/midnight/src/periphery/blue-buy-callback/BlueBuyCallback.sol";
import {BlueBuyCallbackFactory} from "../lib/midnight/src/periphery/blue-buy-callback/BlueBuyCallbackFactory.sol";
import {IBlueBuyCallback} from "../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallback.sol";
import {Log} from "../lib/midnight/src/periphery/log/Log.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {IMorpho, MarketParams} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";
import {MidnightBundlesV2} from "../src/midnight/MidnightBundlesV2.sol";
import {
    IMidnightBundlesV2,
    GroupCancellation,
    CollateralSupply
} from "../src/midnight/interfaces/IMidnightBundlesV2.sol";

contract MidnightBundlesV2MakerTest is Test {
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV = 0.8e18;
    uint128 internal constant PARKED_ASSETS = 1_000e18;
    bytes32 internal constant CALLBACK_SALT = keccak256("callback salt");
    uint256 internal constant RATE = 1e9;

    IMidnight internal midnight;
    IMorpho internal morpho;
    IPriceRatifierV1 internal priceRatifier;
    IRateRatifierV1 internal rateRatifier;
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
        priceRatifier = IPriceRatifierV1(address(new PriceRatifierV1(address(midnight))));
        rateRatifier = IRateRatifierV1(address(new RateRatifierV1(address(midnight))));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));
        blueBuyCallbackFactory = new BlueBuyCallbackFactory(address(midnight), address(morpho));
        offerLog = new Log();
        midnightBundles = new MidnightBundlesV2(
            address(midnight), address(morpho), address(blueBuyCallbackFactory), address(offerLog)
        );

        assertEq(midnightBundles.MIDNIGHT(), address(midnight));
        assertEq(midnightBundles.BLUE(), address(morpho));
        assertEq(midnightBundles.BLUE_BUY_CALLBACK_FACTORY(), address(blueBuyCallbackFactory));
        assertEq(midnightBundles.LOG(), address(offerLog));

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
        offer.ratifier = address(priceRatifier);
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
        offer.ratifier = address(priceRatifier);
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

    function oneGroup(bytes32 group) internal pure returns (GroupCancellation[] memory groups) {
        return oneGroup(group, type(uint128).max);
    }

    function oneGroup(bytes32 group, uint128 maxConsumed) internal pure returns (GroupCancellation[] memory groups) {
        groups = new GroupCancellation[](1);
        groups[0] = GroupCancellation({group: group, maxConsumed: maxConsumed});
    }

    function makeLendLimit(Offer memory offer, uint256 assetsToPark) internal returns (bytes32 root) {
        root = offerRoot(offer);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            assetsToPark,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            offer.ratifier,
            root,
            "",
            new GroupCancellation[](0),
            offerPayload(offer),
            block.timestamp
        );
    }

    function priceRatifierData(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(root, 0, new bytes32[](0), address(0));
    }

    function offerRoot(Offer memory offer) internal view returns (bytes32) {
        return offer.ratifier == address(rateRatifier)
            ? HashLib.hashRateRatifierV1Offer(offer, RATE, borrower)
            : HashLib.hashPriceRatifierV1Offer(offer, address(0));
    }

    function offerPayload(Offer memory offer) internal view returns (bytes memory) {
        return
            offer.ratifier == address(rateRatifier) ? abi.encode(offer, RATE, borrower) : abi.encode(offer, address(0));
    }

    function offerRatifierData(Offer memory offer, bytes32 root) internal view returns (bytes memory) {
        return offer.ratifier == address(rateRatifier)
            ? abi.encode(root, 0, new bytes32[](0), RATE, borrower)
            : priceRatifierData(root);
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
        bytes memory ratifierData = offerRatifierData(offer, root);
        vm.prank(borrower);
        return midnight.take(offer, ratifierData, units, borrower, borrower, address(0), "");
    }

    function signRoot(
        address ratifier,
        address maker,
        bytes32 root,
        bool newIsRootRatified,
        uint128 nonce,
        uint256 signatureDeadline,
        uint256 signerPrivateKey
    ) internal view returns (bytes memory) {
        return signRoot(ratifier, maker, root, 0, newIsRootRatified, nonce, signatureDeadline, signerPrivateKey);
    }

    function signRoot(
        address ratifier,
        address maker,
        bytes32 root,
        uint256 height,
        bool newIsRootRatified,
        uint128 nonce,
        uint256 signatureDeadline,
        uint256 signerPrivateKey
    ) internal view returns (bytes memory) {
        bytes32 treeTypeHash = ratifier == address(rateRatifier)
            ? HashLib.rateRatifierV1OfferTreeTypeHash(height)
            : HashLib.priceRatifierV1OfferTreeTypeHash(height);
        bytes32 hashStruct =
            keccak256(abi.encode(treeTypeHash, maker, root, newIsRootRatified, nonce, signatureDeadline));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", IPriceRatifierV1(ratifier).DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encode(height, nonce, signatureDeadline, v, r, s);
    }

    function makeRootWithSignature(address ratifier, bytes32 root, bytes memory rootSignature) internal {
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            ratifier,
            root,
            rootSignature,
            oneGroup(keccak256("cancelled group")),
            "signed payload",
            block.timestamp
        );
    }

    function assertSignedMakeRolledBack(address ratifier, bytes32 root) internal view {
        assertEq(callbackOf(lender).code.length, 0, "callback deployment rolled back");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), 0, "supply rolled back");
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS, "funding rolled back");
        assertEq(midnight.consumed(lender, keccak256("cancelled group")), 0, "cancellation rolled back");
        assertFalse(midnight.isAuthorized(lender, ratifier), "ratifier authorization rolled back");
        (bool ratified, uint128 nonce) = IPriceRatifierV1(ratifier).ratification(lender, root);
        assertFalse(ratified, "root rolled back");
        assertEq(nonce, 0, "nonce rolled back");
    }

    function testMakeCombinesFundingCancellationAndPublication(bool useRateRatifier, bool useSignature) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        address otherRatifier = useRateRatifier ? address(priceRatifier) : address(rateRatifier);
        bytes32 oldRoot = keccak256("old root");
        bytes32 newRoot = keccak256("new root");
        bytes memory rootSignature =
            useSignature ? signRoot(ratifier, lender, newRoot, true, 0, block.timestamp, lenderPrivateKey) : bytes("");
        GroupCancellation[] memory groupsToCancel = new GroupCancellation[](3);
        groupsToCancel[0] = GroupCancellation({group: oldRoot, maxConsumed: 0});
        groupsToCancel[1] = GroupCancellation({group: keccak256("second group"), maxConsumed: 0});
        groupsToCancel[2] = GroupCancellation({group: bytes32(0), maxConsumed: 0});

        vm.startPrank(lender);
        IRatifiersV1Common(ratifier).setIsRootRatified(lender, oldRoot, true);
        vm.expectEmit(address(offerLog));
        emit Log.Data("combined payload");
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            ratifier,
            newRoot,
            rootSignature,
            groupsToCancel,
            "combined payload",
            block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS);
        assertTrue(IRatifiersV1Common(ratifier).isRootRatified(lender, oldRoot));
        assertFalse(ecrecoverRatifier.isRootCanceled(lender, oldRoot));
        for (uint256 i; i < groupsToCancel.length; i++) {
            assertEq(midnight.consumed(lender, groupsToCancel[i].group), type(uint128).max);
            assertEq(midnight.consumed(borrower, groupsToCancel[i].group), 0);
        }
        assertTrue(IRatifiersV1Common(ratifier).isRootRatified(lender, newRoot));
        (, uint128 nonce) = IPriceRatifierV1(ratifier).ratification(lender, newRoot);
        assertEq(nonce, useSignature ? 1 : 0);
        assertTrue(midnight.isAuthorized(lender, ratifier));
        assertFalse(midnight.isAuthorized(lender, otherRatifier));
        assertFalse(IRatifiersV1Common(otherRatifier).isRootRatified(lender, newRoot));
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0);
        assertEq(collateralToken.balanceOf(address(midnightBundles)), 0);
    }

    function testMakeWithSignatureCreatesTakeableOffer(bool useRateRatifier, bool useAuthorizedSigner) public {
        Offer memory offer = makeOffer(keccak256("signed group"), PARKED_ASSETS, MAX_TICK / 2);
        offer.start = block.timestamp;
        if (useRateRatifier) offer.ratifier = address(rateRatifier);
        bytes32 root = offerRoot(offer);
        uint256 signerPrivateKey = lenderPrivateKey;
        if (useAuthorizedSigner) {
            (address signer, uint256 privateKey) = makeAddrAndKey("authorized signer");
            vm.prank(lender);
            midnight.setIsAuthorized(signer, true, lender);
            signerPrivateKey = privateKey;
        }
        bytes memory rootSignature =
            signRoot(offer.ratifier, lender, root, true, 0, block.timestamp + 1 days, signerPrivateKey);

        makeRootWithSignature(offer.ratifier, root, rootSignature);
        (uint256 buyerAssets,) = take(offer, root, 100e18);

        assertGt(buyerAssets, 0);
        assertEq(midnight.consumed(lender, offer.group), buyerAssets);
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS - buyerAssets);
    }

    function testMakeWithSignatureRejectsMismatchedAuthorization(bool useRateRatifier, uint8 mismatch) public {
        mismatch = uint8(bound(mismatch, 0, 4));
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        address otherRatifier = useRateRatifier ? address(priceRatifier) : address(rateRatifier);
        bytes32 root = keccak256("signed root");
        (, uint256 otherPrivateKey) = makeAddrAndKey("unauthorized signer");
        bytes memory rootSignature = signRoot(
            mismatch == 0 ? otherRatifier : ratifier,
            mismatch == 1 ? borrower : lender,
            mismatch == 2 ? keccak256("other root") : root,
            mismatch != 3,
            0,
            block.timestamp,
            mismatch == 4 ? otherPrivateKey : lenderPrivateKey
        );

        vm.expectRevert(IPriceRatifierV1.Unauthorized.selector);
        makeRootWithSignature(ratifier, root, rootSignature);

        assertSignedMakeRolledBack(ratifier, root);
    }

    function testMakeWithSignatureRejectsExpiredSignature(bool useRateRatifier) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        bytes32 root = keccak256("signed root");
        bytes memory rootSignature = signRoot(ratifier, lender, root, true, 0, vm.getBlockTimestamp(), lenderPrivateKey);
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.expectRevert(IPriceRatifierV1.DeadlineExpired.selector);
        makeRootWithSignature(ratifier, root, rootSignature);

        assertSignedMakeRolledBack(ratifier, root);
    }

    function testMakeWithSignatureRejectsFutureNonce(bool useRateRatifier, uint128 nonce) public {
        nonce = uint128(bound(nonce, 1, type(uint128).max));
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        bytes32 root = keccak256("signed root");
        bytes memory rootSignature = signRoot(ratifier, lender, root, true, nonce, block.timestamp, lenderPrivateKey);

        vm.expectRevert(IPriceRatifierV1.InvalidNonce.selector);
        makeRootWithSignature(ratifier, root, rootSignature);

        assertSignedMakeRolledBack(ratifier, root);
    }

    function testMakeRejectsMalformedRootSignature(bool useRateRatifier) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        bytes32 root = keccak256("signed root");

        vm.expectRevert();
        makeRootWithSignature(ratifier, root, hex"01");

        assertSignedMakeRolledBack(ratifier, root);
    }

    function testMakeRejectsInvalidRootSignature(bool useRateRatifier) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        bytes32 root = keccak256("signed root");
        bytes memory rootSignature =
            abi.encode(uint256(0), uint128(0), block.timestamp, uint8(0), bytes32(0), bytes32(0));

        vm.expectRevert(IPriceRatifierV1.InvalidSignature.selector);
        makeRootWithSignature(ratifier, root, rootSignature);

        assertSignedMakeRolledBack(ratifier, root);
    }

    function testMakeWithSignatureStillRequiresBundleAuthorization(bool useRateRatifier) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        bytes32 root = keccak256("signed root");
        bytes memory rootSignature = signRoot(ratifier, lender, root, true, 0, block.timestamp, lenderPrivateKey);
        vm.prank(lender);
        midnight.setIsAuthorized(address(midnightBundles), false, lender);

        vm.prank(lender);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            ratifier,
            root,
            rootSignature,
            new GroupCancellation[](0),
            "payload",
            block.timestamp
        );

        assertSignedMakeRolledBack(ratifier, root);
    }

    function testMakeWithSignatureHandlesConsumedNonce(bool useRateRatifier) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        bytes32 root = keccak256("signed root");
        bytes memory rootSignature = signRoot(ratifier, lender, root, true, 0, block.timestamp, lenderPrivateKey);
        (,, uint256 signatureDeadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(rootSignature, (uint256, uint128, uint256, uint8, bytes32, bytes32));
        // An authorized actor may submit the signature before the bundle.
        vm.prank(lender);
        IRatifiersV1Common(ratifier).setIsRootRatifiedWithSig(lender, root, 0, true, 0, signatureDeadline, v, r, s);

        makeRootWithSignature(ratifier, root, rootSignature);

        (, uint128 nonce) = IPriceRatifierV1(ratifier).ratification(lender, root);
        assertEq(nonce, 1, "an already submitted signature does not increment the nonce");
        vm.prank(lender);
        IRatifiersV1Common(ratifier).setIsRootRatified(lender, root, false);

        vm.expectRevert(IPriceRatifierV1.RatifiedStatusChanged.selector);
        makeRootWithSignature(ratifier, root, rootSignature);

        assertFalse(IRatifiersV1Common(ratifier).isRootRatified(lender, root));
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS);
        // A fresh signature at the current nonce can reactivate the root.
        rootSignature = signRoot(ratifier, lender, root, true, 1, block.timestamp, lenderPrivateKey);
        makeRootWithSignature(ratifier, root, rootSignature);

        (bool ratified, uint128 finalNonce) = IPriceRatifierV1(ratifier).ratification(lender, root);
        assertTrue(ratified);
        assertEq(finalNonce, 2);
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), 2 * PARKED_ASSETS);
    }

    function testMakeWithSignatureRatifiesOfferTree(bool useRateRatifier) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        Offer memory firstOffer = makeOffer(keccak256("first group"), PARKED_ASSETS, MAX_TICK);
        Offer memory secondOffer = makeOffer(keccak256("second group"), PARKED_ASSETS, MAX_TICK - 1);
        firstOffer.ratifier = ratifier;
        secondOffer.ratifier = ratifier;
        bytes32 root = HashLib.hashNode(offerRoot(firstOffer), offerRoot(secondOffer));
        // The signature commits to a two-leaf offer tree: the bundle must forward height 1 untouched.
        bytes memory rootSignature = signRoot(ratifier, lender, root, 1, true, 0, block.timestamp, lenderPrivateKey);

        makeRootWithSignature(ratifier, root, rootSignature);

        assertTrue(IRatifiersV1Common(ratifier).isRootRatified(lender, root), "tree root ratified");
        (, uint128 nonce) = IPriceRatifierV1(ratifier).ratification(lender, root);
        assertEq(nonce, 1, "nonce consumed");
    }

    function testMakeRejectsUnexpectedRatifierResponse(bool useSignature) public {
        address ratifier = address(new InvalidResponseRatifier());
        bytes memory rootSignature = useSignature
            ? abi.encode(uint256(0), uint128(0), block.timestamp, uint8(0), bytes32(0), bytes32(0))
            : bytes("");

        vm.expectRevert(IMidnightBundlesV2.InvalidRatifierResponse.selector);
        makeRootWithSignature(ratifier, keccak256("root"), rootSignature);

        assertEq(callbackOf(lender).code.length, 0);
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS);
        assertEq(midnight.consumed(lender, keccak256("cancelled group")), 0);
        assertFalse(midnight.isAuthorized(lender, ratifier));
    }

    function testMakeWithinConsumptionLimits(uint128 consumed, uint128 maxConsumed) public {
        if (maxConsumed < consumed) maxConsumed = consumed;
        bytes32 group = keccak256("group");
        bytes32 secondGroup = keccak256("second group");
        bytes32 root = keccak256("new root");
        vm.prank(lender);
        midnight.setConsumed(group, consumed, lender);
        vm.prank(lender);
        midnight.setConsumed(secondGroup, consumed, lender);
        vm.prank(borrower);
        midnight.setConsumed(group, type(uint128).max, borrower);

        GroupCancellation[] memory groups = new GroupCancellation[](2);
        groups[0] = GroupCancellation({group: group, maxConsumed: maxConsumed});
        groups[1] = GroupCancellation({group: secondGroup, maxConsumed: consumed});

        vm.expectEmit(address(offerLog));
        emit Log.Data("new payload");
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            groups,
            "new payload",
            block.timestamp
        );

        assertEq(midnight.consumed(lender, group), type(uint128).max);
        assertEq(midnight.consumed(lender, secondGroup), type(uint128).max);
        assertTrue(midnight.isAuthorized(lender, address(priceRatifier)));
        assertTrue(priceRatifier.isRootRatified(lender, root));
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS);
    }

    function testMakeRevertsWhenConsumptionExceedsLimit(uint128 maxConsumed, uint128 consumed) public {
        if (maxConsumed == type(uint128).max) maxConsumed--;
        if (consumed <= maxConsumed) consumed = maxConsumed + 1;
        bytes32 exceededGroup = keccak256("exceeded group");
        bytes32 root = keccak256("new root");
        GroupCancellation[] memory groups = new GroupCancellation[](3);
        groups[0] = GroupCancellation({group: keccak256("first group"), maxConsumed: 0});
        groups[1] = GroupCancellation({group: exceededGroup, maxConsumed: maxConsumed});
        groups[2] = GroupCancellation({group: keccak256("last group"), maxConsumed: 0});

        vm.startPrank(lender);
        midnight.setConsumed(exceededGroup, consumed, lender);
        vm.expectRevert(IMidnightBundlesV2.ConsumedAboveMax.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            groups,
            "payload",
            block.timestamp
        );
        vm.stopPrank();

        for (uint256 i; i < groups.length; i++) {
            uint128 expected = i == 1 ? consumed : 0;
            assertEq(midnight.consumed(lender, groups[i].group), expected);
            assertEq(midnight.consumed(borrower, groups[i].group), 0);
        }
        assertEq(callbackOf(lender).code.length, 0);
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), 0);
        assertEq(midnight.collateral(IdLib.toId(midnightMarket), lender, 0), 0);
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS);
        assertFalse(midnight.isAuthorized(lender, address(priceRatifier)));
        assertFalse(priceRatifier.isRootRatified(lender, root));
    }

    function testRepostRevertsAfterAdditionalFill(bool useRateRatifier) public {
        Offer memory oldOffer = makeOffer(keccak256("old group"), PARKED_ASSETS, MAX_TICK / 2);
        oldOffer.start = block.timestamp;
        if (useRateRatifier) oldOffer.ratifier = address(rateRatifier);
        bytes32 oldRoot = makeLendLimit(oldOffer, PARKED_ASSETS);
        take(oldOffer, oldRoot, 100e18);

        uint128 maxConsumed = midnight.consumed(lender, oldOffer.group);
        Offer memory newOffer = makeOffer(keccak256("new group"), PARKED_ASSETS - maxConsumed, MAX_TICK / 2);
        bytes32 newRoot = offerRoot(newOffer);

        // Another take lands after the maker has sized the replacement and captured the limit.
        take(oldOffer, oldRoot, 300e18);
        uint128 consumed = midnight.consumed(lender, oldOffer.group);
        assertGt(consumed, maxConsumed);
        uint256 supplyBefore = morpho.expectedSupplyAssets(blueMarket, callbackOf(lender));
        uint256 borrowerBalanceBefore = loanToken.balanceOf(borrower);
        bool authorizedBefore = midnight.isAuthorized(lender, newOffer.ratifier);

        vm.expectRevert(IMidnightBundlesV2.ConsumedAboveMax.selector);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newOffer.ratifier,
            newRoot,
            "",
            oneGroup(oldOffer.group, maxConsumed),
            offerPayload(newOffer),
            block.timestamp
        );

        assertEq(midnight.consumed(lender, oldOffer.group), consumed);
        assertTrue(IRatifiersV1Common(oldOffer.ratifier).isRootRatified(lender, oldRoot));
        assertFalse(priceRatifier.isRootRatified(lender, newRoot));
        assertEq(midnight.isAuthorized(lender, newOffer.ratifier), authorizedBefore);
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), supplyBefore);
        assertEq(loanToken.balanceOf(lender), PARKED_ASSETS);
        assertEq(loanToken.balanceOf(borrower), borrowerBalanceBefore);

        // The failed cancellation leaves the old offer takeable.
        take(oldOffer, oldRoot, 1e18);
    }

    function testCancelRequiresAuthorization() public {
        bytes32 group = keccak256("group");
        vm.startPrank(lender);
        midnight.setConsumed(group, 1, lender);
        midnight.setIsAuthorized(address(midnightBundles), false, lender);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            bytes32(0),
            "",
            oneGroup(group, 1),
            "payload",
            block.timestamp
        );
        vm.stopPrank();
        assertEq(midnight.consumed(lender, group), 1);
    }

    function testCancelSkipsPublicationWithoutAuthorizingRatifiers(address ignoredRatifier) public {
        MidnightBundlesV2 cancellingBundles = new MidnightBundlesV2(
            address(midnight), address(morpho), address(blueBuyCallbackFactory), address(new RevertingLog())
        );
        bytes32 root = bytes32(0);
        MarketParams memory unusedBlueMarket;
        Market memory unusedMarket;

        vm.startPrank(lender);
        midnight.setIsAuthorized(address(cancellingBundles), true, lender);
        priceRatifier.setIsRootRatified(lender, root, true);
        cancellingBundles.midnightBundlesV2CancelAndMake(
            unusedBlueMarket,
            0,
            bytes32(0),
            unusedMarket,
            noCollateralSupplies(),
            ignoredRatifier,
            root,
            hex"01",
            oneGroup(root),
            "ignored payload",
            block.timestamp
        );
        vm.stopPrank();

        assertTrue(priceRatifier.isRootRatified(lender, root));
        assertEq(midnight.consumed(lender, root), type(uint128).max);
        assertFalse(midnight.isAuthorized(lender, address(priceRatifier)));
        assertFalse(midnight.isAuthorized(lender, address(rateRatifier)));
        assertEq(callbackOf(lender).code.length, 0);
    }

    function testMakeWithZeroRootPreservesAuthorizations(bool priceAuthorized, bool rateAuthorized) public {
        vm.startPrank(lender);
        midnight.setIsAuthorized(address(priceRatifier), priceAuthorized, lender);
        midnight.setIsAuthorized(address(rateRatifier), rateAuthorized, lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(0),
            bytes32(0),
            "",
            new GroupCancellation[](0),
            "",
            block.timestamp
        );
        vm.stopPrank();
        assertEq(midnight.consumed(lender, bytes32(0)), 0, "empty array skips cancellation");
        assertFalse(priceRatifier.isRootRatified(lender, bytes32(0)));
        assertFalse(rateRatifier.isRootRatified(lender, bytes32(0)));
        assertEq(midnight.isAuthorized(lender, address(priceRatifier)), priceAuthorized);
        assertEq(midnight.isAuthorized(lender, address(rateRatifier)), rateAuthorized);
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
        assertTrue(midnight.isAuthorized(lender, address(priceRatifier)), "ratifier authorization");
        assertTrue(priceRatifier.isRootRatified(lender, root), "root ratification");
        assertEq(loanToken.balanceOf(address(midnightBundles)), 0, "bundle balance");
    }

    function testMakeWithoutParkingDoesNotCreateCallback() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = makeLendLimit(offer, 0);

        assertEq(blueBuyCallbackFactory.callbackOf(lender, CALLBACK_SALT), address(0), "factory callback");
        assertEq(callbackOf(lender).code.length, 0, "callback code");
        assertTrue(priceRatifier.isRootRatified(lender, root), "root ratification");
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS, "lender balance");
    }

    function testMakePublishesPayload() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashPriceRatifierV1Offer(offer, address(0));
        bytes memory payload = abi.encode(offer, address(0));

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            payload,
            block.timestamp
        );
    }

    function testMakeIsAtomicWhenLogReverts(bool useRateRatifier, bool useSignature) public {
        address ratifier = useRateRatifier ? address(rateRatifier) : address(priceRatifier);
        RevertingLog revertingLog = new RevertingLog();
        MidnightBundlesV2 revertingBundles = new MidnightBundlesV2(
            address(midnight), address(morpho), address(blueBuyCallbackFactory), address(revertingLog)
        );
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        offer.ratifier = ratifier;
        bytes32 root = offerRoot(offer);
        bytes32 cancelledGroup = keccak256("cancelled group");
        bytes memory rootSignature =
            useSignature ? signRoot(ratifier, lender, root, true, 0, block.timestamp, lenderPrivateKey) : bytes("");

        vm.startPrank(lender);
        loanToken.approve(address(revertingBundles), type(uint256).max);
        midnight.setIsAuthorized(address(revertingBundles), true, lender);
        vm.expectRevert(RevertingLog.Reverted.selector);
        revertingBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            ratifier,
            root,
            rootSignature,
            oneGroup(cancelledGroup),
            offerPayload(offer),
            block.timestamp
        );
        vm.stopPrank();

        assertEq(callbackOf(lender).code.length, 0, "callback deployment rolled back");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), 0, "supply rolled back");
        assertFalse(midnight.isAuthorized(lender, ratifier), "ratifier authorization rolled back");
        assertFalse(IRatifiersV1Common(ratifier).isRootRatified(lender, root), "root rolled back");
        (, uint128 nonce) = IPriceRatifierV1(ratifier).ratification(lender, root);
        assertEq(nonce, 0, "nonce rolled back");
        assertEq(midnight.consumed(lender, cancelledGroup), 0, "cancellation rolled back");
        assertEq(loanToken.balanceOf(lender), 2 * PARKED_ASSETS, "funding rolled back");
    }

    function testConstructorRevertsWhenFactoryMidnightIsInconsistent() public {
        BlueBuyCallbackFactory inconsistentFactory =
            new BlueBuyCallbackFactory(makeAddr("otherMidnight"), address(morpho));

        vm.expectRevert(IMidnightBundlesV2.InconsistentMidnight.selector);
        new MidnightBundlesV2(address(midnight), address(morpho), address(inconsistentFactory), address(offerLog));
    }

    function testConstructorRevertsWhenFactoryBlueIsInconsistent() public {
        BlueBuyCallbackFactory inconsistentFactory =
            new BlueBuyCallbackFactory(address(midnight), makeAddr("otherBlue"));

        vm.expectRevert(IMidnightBundlesV2.InconsistentBlue.selector);
        new MidnightBundlesV2(address(midnight), address(morpho), address(inconsistentFactory), address(offerLog));
    }

    function testMakeAcceptsArbitraryRatifier(bool useRateRatifier) public {
        address ratifier = useRateRatifier
            ? address(new RateRatifierV1(address(midnight)))
            : address(new PriceRatifierV1(address(midnight)));
        bytes32 group = keccak256("cancelled group");
        bytes32 root = keccak256("new root");

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            ratifier,
            root,
            "",
            oneGroup(group),
            "payload",
            block.timestamp
        );

        assertTrue(midnight.isAuthorized(lender, ratifier));
        assertTrue(IRatifiersV1Common(ratifier).isRootRatified(lender, root));
        assertEq(midnight.consumed(lender, group), type(uint128).max);
        assertEq(morpho.expectedSupplyAssets(blueMarket, callbackOf(lender)), PARKED_ASSETS);
    }

    function testPartialFillsWithdrawFromBlue(bool useRateRatifier) public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK / 2);
        offer.start = block.timestamp;
        if (useRateRatifier) offer.ratifier = address(rateRatifier);
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

    function testRepostCancelsOldGroupAndActivatesNewRoot(bool oldUsesRate, bool newUsesRate) public {
        bytes32 group = keccak256("group");
        Offer memory oldOffer = makeOffer(group, PARKED_ASSETS, MAX_TICK / 2);
        oldOffer.start = block.timestamp;
        if (oldUsesRate) oldOffer.ratifier = address(rateRatifier);
        bytes32 oldRoot = makeLendLimit(oldOffer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        (uint256 buyerAssets,) = take(oldOffer, oldRoot, 100e18);
        uint256 supplyBeforeRepost = morpho.expectedSupplyAssets(blueMarket, callback);
        assertEq(supplyBeforeRepost, PARKED_ASSETS - buyerAssets, "supply before repost");

        Offer memory newOffer = makeOffer(keccak256("new group"), PARKED_ASSETS, MAX_TICK / 2 - 4);
        newOffer.start = block.timestamp;
        if (newUsesRate) newOffer.ratifier = address(rateRatifier);
        bytes32 newRoot = offerRoot(newOffer);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            newOffer.ratifier,
            newRoot,
            "",
            oneGroup(group),
            offerPayload(newOffer),
            block.timestamp
        );

        assertEq(blueBuyCallbackFactory.callbackOf(lender, CALLBACK_SALT), callback, "reused callback");
        assertTrue(IRatifiersV1Common(oldOffer.ratifier).isRootRatified(lender, oldRoot), "old root retained");
        assertTrue(IRatifiersV1Common(newOffer.ratifier).isRootRatified(lender, newRoot), "new root");
        assertTrue(midnight.isAuthorized(lender, oldOffer.ratifier), "old authorization retained");
        assertTrue(midnight.isAuthorized(lender, newOffer.ratifier), "new authorization");
        assertEq(midnight.consumed(lender, group), type(uint128).max, "old group cancelled");
        if (oldOffer.ratifier != newOffer.ratifier) {
            assertFalse(IRatifiersV1Common(oldOffer.ratifier).isRootRatified(lender, newRoot), "new root isolated");
        }
        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), supplyBeforeRepost, "reused Blue position");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(oldOffer, offerRatifierData(oldOffer, oldRoot), 1e18, borrower, borrower, address(0), "");

        take(newOffer, newRoot, 1e18);
    }

    function testRepostCancelsGroupWithoutDeactivatingItsRoot() public {
        bytes32 group = keccak256("group");
        Offer memory oldOffer = makeOffer(group, PARKED_ASSETS, MAX_TICK);
        bytes32 oldRoot = makeLendLimit(oldOffer, PARKED_ASSETS);

        Offer memory newOffer = makeOffer(keccak256("new group"), PARKED_ASSETS, MAX_TICK - 4);
        bytes32 newRoot = HashLib.hashPriceRatifierV1Offer(newOffer, address(0));

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            newRoot,
            "",
            oneGroup(group),
            abi.encode(newOffer, address(0)),
            block.timestamp
        );

        assertTrue(priceRatifier.isRootRatified(lender, oldRoot), "old root retained");
        assertTrue(priceRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(midnight.consumed(lender, group), type(uint128).max, "group cancelled");

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(oldOffer, priceRatifierData(oldRoot), 1e18, borrower, borrower, address(0), "");

        take(newOffer, newRoot, 1e18);
    }

    function testMakeIsAtomicWhenBundleIsNotAuthorizedOnMidnight() public {
        address unauthorizedLender = makeAddr("unauthorizedLender");
        deal(address(loanToken), unauthorizedLender, PARKED_ASSETS);

        Offer memory offer = makeOffer(keccak256("unauthorized"), PARKED_ASSETS, MAX_TICK);
        offer.maker = unauthorizedLender;
        offer.callback = callbackOf(unauthorizedLender);
        bytes32 root = HashLib.hashPriceRatifierV1Offer(offer, address(0));

        vm.startPrank(unauthorizedLender);
        loanToken.approve(address(midnightBundles), type(uint256).max);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            abi.encode(offer, address(0)),
            block.timestamp
        );
        vm.stopPrank();

        address callback = callbackOf(unauthorizedLender);
        assertEq(callback.code.length, 0, "rolled-back callback deployment");
        assertEq(morpho.expectedSupplyAssets(blueMarket, callback), 0, "rolled-back supply");
        assertEq(loanToken.balanceOf(unauthorizedLender), PARKED_ASSETS, "rolled-back transfer");
        assertFalse(priceRatifier.isRootRatified(unauthorizedLender, root), "rolled-back root");
    }

    function testTakeRevertsWhenParkedAssetsAreInsufficient() public {
        Offer memory offer = makeOffer(keccak256("group"), 2 * PARKED_ASSETS, MAX_TICK);
        bytes32 root = makeLendLimit(offer, PARKED_ASSETS);
        address callback = callbackOf(lender);

        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(offer, priceRatifierData(root), PARKED_ASSETS + 1, borrower, borrower, address(0), "");

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

        CollateralSupply[] memory collateralSupplies = new CollateralSupply[](3);
        collateralSupplies[0] = CollateralSupply({collateralIndex: firstCollateralIndex, assets: firstAssets});
        collateralSupplies[1] = CollateralSupply({collateralIndex: secondCollateralIndex, assets: secondAssets});
        // Zero supplies are no-ops, but their collateral index must still be valid.
        collateralSupplies[2] = CollateralSupply({collateralIndex: firstCollateralIndex, assets: 0});

        Offer memory offer = makeBorrowOffer(market, keccak256("borrow group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashPriceRatifierV1Offer(offer, address(0));
        bytes memory payload = abi.encode(offer, address(0));

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(borrower);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            market,
            collateralSupplies,
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            payload,
            block.timestamp
        );

        assertEq(midnight.collateral(id, borrower, firstCollateralIndex), firstAssets, "first collateral");
        assertEq(midnight.collateral(id, borrower, secondCollateralIndex), secondAssets, "second collateral");
        assertEq(firstCollateral.balanceOf(address(midnightBundles)), 0, "first bundle balance");
        assertEq(secondCollateral.balanceOf(address(midnightBundles)), 0, "second bundle balance");
        assertTrue(priceRatifier.isRootRatified(borrower, root), "root ratification");

        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        (, uint256 sellerAssets) =
            midnight.take(offer, priceRatifierData(root), 100e18, lender, address(0), address(0), "");
        vm.stopPrank();

        assertEq(loanToken.balanceOf(borrower), sellerAssets, "borrower proceeds");
        assertEq(midnight.debt(id, borrower), 100e18, "borrower debt");
    }

    function testBorrowLimitRepostsWithoutSupplyingCollateral() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);

        Offer memory oldOffer = makeBorrowOffer(midnightMarket, keccak256("borrow group"), PARKED_ASSETS, MAX_TICK);
        bytes32 oldRoot = HashLib.hashPriceRatifierV1Offer(oldOffer, address(0));

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            oldRoot,
            "",
            new GroupCancellation[](0),
            abi.encode(oldOffer, address(0)),
            block.timestamp
        );

        Offer memory newOffer = oldOffer;
        newOffer.tick = MAX_TICK - 4;
        bytes32 newRoot = HashLib.hashPriceRatifierV1Offer(newOffer, address(0));

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            newRoot,
            "",
            new GroupCancellation[](0),
            abi.encode(newOffer, address(0)),
            block.timestamp
        );

        assertTrue(priceRatifier.isRootRatified(borrower, oldRoot), "old root");
        assertTrue(priceRatifier.isRootRatified(borrower, newRoot), "new root");
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
        bytes32 firstHash = HashLib.hashPriceRatifierV1Offer(firstOffer, address(0));
        bytes32 secondHash = HashLib.hashPriceRatifierV1Offer(secondOffer, address(0));
        bytes32 root = HashLib.hashNode(firstHash, secondHash);

        vm.prank(borrower);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            abi.encode(firstOffer, address(0), secondOffer, address(0)),
            block.timestamp
        );

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = secondHash;
        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.take(firstOffer, abi.encode(root, 0, proof, address(0)), 1e18, lender, address(0), address(0), "");
        proof[0] = firstHash;
        midnight.take(secondOffer, abi.encode(root, 1, proof, address(0)), 1e18, lender, address(0), address(0), "");
        vm.stopPrank();

        assertEq(midnight.debt(IdLib.toId(midnightMarket), borrower), 1e18, "first market debt");
        assertEq(midnight.debt(IdLib.toId(secondMarket), borrower), 1e18, "second market debt");
    }

    function testRepostRetainsRootsAndCancelsGroups() public {
        bytes32 oldRoot = keccak256("old root");
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            oldRoot,
            "",
            new GroupCancellation[](0),
            abi.encode("old payload"),
            block.timestamp
        );

        bytes32 newRoot = keccak256("new root");
        bytes32 cancelledGroup = keccak256("cancelled group");
        bytes memory payload = abi.encode("new payload");

        vm.expectEmit(address(offerLog));
        emit Log.Data(payload);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            newRoot,
            "",
            oneGroup(cancelledGroup),
            payload,
            block.timestamp
        );

        assertTrue(priceRatifier.isRootRatified(lender, oldRoot), "old root");
        assertTrue(priceRatifier.isRootRatified(lender, newRoot), "new root");
        assertEq(midnight.consumed(lender, cancelledGroup), type(uint128).max, "cancelled group");
    }

    function testRepostAuthorizesOnlyPriceRatifierV1WhenOnlyBundleIsAuthorized() public {
        Offer memory offer = makeOffer(keccak256("Price offer"), PARKED_ASSETS, MAX_TICK);
        offer.callback = address(0);
        offer.callbackData = "";
        bytes32 root = HashLib.hashPriceRatifierV1Offer(offer, address(0));

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            abi.encode(offer, address(0)),
            block.timestamp
        );

        assertTrue(midnight.isAuthorized(lender, address(priceRatifier)), "Price authorization");
        assertFalse(midnight.isAuthorized(lender, address(ecrecoverRatifier)), "Ecrecover authorization");

        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        midnight.take(offer, priceRatifierData(root), 1e18, borrower, borrower, address(0), "");
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
        bytes32 newRoot = HashLib.hashPriceRatifierV1Offer(newOffer, address(0));

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            newRoot,
            "",
            oneGroup(oldOffer.group),
            abi.encode(newOffer, address(0)),
            block.timestamp
        );

        assertFalse(ecrecoverRatifier.isRootCanceled(lender, oldRoot), "old Ecrecover root retained");
        assertEq(midnight.consumed(lender, oldOffer.group), type(uint128).max);
        assertTrue(priceRatifier.isRootRatified(lender, newRoot), "new Price root");

        assertEq(ecrecoverRatifier.isRatified(oldOffer, oldEcrecoverData, address(0)), CALLBACK_SUCCESS);
        take(newOffer, newRoot, 1e18);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        midnight.take(oldOffer, oldEcrecoverData, 1e18, borrower, borrower, address(0), "");
    }

    function testCancelGroupsRetainsRoots() public {
        bytes32 priceRoot = keccak256("price root");
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            priceRoot,
            "",
            new GroupCancellation[](0),
            abi.encode("payload"),
            block.timestamp
        );

        bytes32 ecrecoverRoot = keccak256("ecrecover root");
        bytes32 group = keccak256("group");

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            bytes32(0),
            "",
            oneGroup(group),
            "",
            block.timestamp
        );

        assertTrue(priceRatifier.isRootRatified(lender, priceRoot), "Price root");
        assertFalse(ecrecoverRatifier.isRootCanceled(lender, ecrecoverRoot), "Ecrecover root");
        assertEq(midnight.consumed(lender, group), type(uint128).max, "group");
    }

    function testCancelRevertsAfterDeadline() public {
        bytes32 group = keccak256("group");

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            bytes32(0),
            "",
            oneGroup(group),
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
        midnight.take(offer, priceRatifierData(root), 1e18, borrower, borrower, address(0), "");
    }

    function testMakeRevertsAfterDeadline() public {
        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashPriceRatifierV1Offer(offer, address(0));
        uint256 deadline = block.timestamp - 1;

        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.DeadlinePassed.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            abi.encode(offer, address(0)),
            deadline
        );
    }

    // Native wrapping.

    function testMakeParksNativeAsWrapped() public {
        WETHMock weth = new WETHMock();
        MarketParams memory wethBlueMarket = MarketParams({
            loanToken: address(weth),
            collateralToken: address(collateralToken),
            oracle: address(blueOracle),
            irm: address(0),
            lltv: LLTV
        });
        morpho.createMarket(wethBlueMarket);

        Offer memory offer = makeOffer(keccak256("group"), PARKED_ASSETS, MAX_TICK);
        bytes32 root = HashLib.hashOffer(offer);

        deal(lender, PARKED_ASSETS);

        // The parked assets are wrapped from msg.value instead of being pulled.
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake{value: PARKED_ASSETS}(
            wethBlueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(priceRatifier),
            root,
            "",
            new GroupCancellation[](0),
            abi.encode(offer),
            block.timestamp
        );

        assertEq(morpho.expectedSupplyAssets(wethBlueMarket, callbackOf(lender)), PARKED_ASSETS, "parked assets");
        assertTrue(priceRatifier.isRootRatified(lender, root), "root ratification");
        assertEq(lender.balance, 0, "lender native residual");
        assertEq(address(midnightBundles).balance, 0, "bundler native residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
    }

    function testMakeSuppliesNativeCollateral() public {
        WETHMock weth = new WETHMock();

        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token: address(weth), lltv: LLTV, liquidationCursor: 0.25e18, oracle: address(midnightOracle)
        });
        Market memory wethCollateralMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collateralParams,
            maturity: block.timestamp + 100 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 wethCollateralId = midnight.touchMarket(wethCollateralMarket);

        CollateralSupply[] memory supplies = new CollateralSupply[](1);
        supplies[0] = CollateralSupply({collateralIndex: 0, assets: PARKED_ASSETS});

        deal(lender, PARKED_ASSETS);

        // With assetsToPark zero, msg.value funds the single collateral supply instead.
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake{value: PARKED_ASSETS}(
            blueMarket,
            0,
            CALLBACK_SALT,
            wethCollateralMarket,
            supplies,
            address(0),
            bytes32(0),
            "",
            new GroupCancellation[](0),
            "",
            block.timestamp
        );

        assertEq(midnight.collateral(wethCollateralId, lender, 0), PARKED_ASSETS, "collateral supplied");
        assertEq(lender.balance, 0, "lender native residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
    }

    function testMakeRevertsWhenParkingAndSupplyingCollateral() public {
        CollateralSupply[] memory supplies = new CollateralSupply[](1);
        supplies[0] = CollateralSupply({collateralIndex: 0, assets: 0});

        // Parking is for buying and supplying collateral is for selling: both at once is rejected, even for zero supplies.
        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.InconsistentInputs.selector);
        midnightBundles.midnightBundlesV2CancelAndMake(
            blueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            supplies,
            address(0),
            bytes32(0),
            "",
            new GroupCancellation[](0),
            "",
            block.timestamp
        );
    }

    function testMakeSuppliesNativeFirstCollateralAndPullsSecond() public {
        WETHMock weth = new WETHMock();
        (Market memory market, uint256 wethIndex, uint256 tokenIndex) =
            makeMultiCollateralMarket(ERC20Permit(address(weth)), collateralToken);
        bytes32 id = midnight.touchMarket(market);

        // The native supply must come first; the second supply is pulled.
        CollateralSupply[] memory supplies = new CollateralSupply[](2);
        supplies[0] = CollateralSupply({collateralIndex: wethIndex, assets: PARKED_ASSETS});
        supplies[1] = CollateralSupply({collateralIndex: tokenIndex, assets: 2 * PARKED_ASSETS});

        deal(lender, PARKED_ASSETS);
        deal(address(collateralToken), lender, 2 * PARKED_ASSETS);
        vm.prank(lender);
        collateralToken.approve(address(midnightBundles), 2 * PARKED_ASSETS);

        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake{value: PARKED_ASSETS}(
            blueMarket,
            0,
            CALLBACK_SALT,
            market,
            supplies,
            address(0),
            bytes32(0),
            "",
            new GroupCancellation[](0),
            "",
            block.timestamp
        );

        assertEq(midnight.collateral(id, lender, wethIndex), PARKED_ASSETS, "wrapped collateral");
        assertEq(midnight.collateral(id, lender, tokenIndex), 2 * PARKED_ASSETS, "pulled collateral");
        assertEq(lender.balance, 0, "lender native residual");
        assertEq(collateralToken.balanceOf(lender), 0, "lender collateral residual");
        assertEq(weth.balanceOf(address(midnightBundles)), 0, "bundler wrapped residual");
        assertEq(collateralToken.balanceOf(address(midnightBundles)), 0, "bundler collateral residual");
    }

    function testMakeRevertsWhenNativeIsNotConsumed() public {
        deal(lender, 1 ether);

        // There is no first transfer to wrap into, so the native tokens would otherwise be stranded in the bundle.
        vm.prank(lender);
        vm.expectRevert(IMidnightBundlesV2.UnusedNative.selector);
        midnightBundles.midnightBundlesV2CancelAndMake{value: 1 ether}(
            blueMarket,
            0,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(0),
            bytes32(0),
            "",
            new GroupCancellation[](0),
            "",
            block.timestamp
        );

        assertEq(address(midnightBundles).balance, 0, "no native left in the bundle");
        assertEq(lender.balance, 1 ether, "native returned to the lender");
    }

    function testMakeIgnoresNativeAlreadyHeldByTheBundle() public {
        // A prior donation must not let a later call strand its own msg.value, nor block a legitimate one.
        deal(address(midnightBundles), 5 ether);

        WETHMock weth = new WETHMock();
        MarketParams memory wethBlueMarket = MarketParams({
            loanToken: address(weth),
            collateralToken: address(collateralToken),
            oracle: address(blueOracle),
            irm: address(0),
            lltv: LLTV
        });
        morpho.createMarket(wethBlueMarket);

        deal(lender, PARKED_ASSETS);
        vm.prank(lender);
        midnightBundles.midnightBundlesV2CancelAndMake{value: PARKED_ASSETS}(
            wethBlueMarket,
            PARKED_ASSETS,
            CALLBACK_SALT,
            midnightMarket,
            noCollateralSupplies(),
            address(0),
            bytes32(0),
            "",
            new GroupCancellation[](0),
            "",
            block.timestamp
        );

        assertEq(morpho.expectedSupplyAssets(wethBlueMarket, callbackOf(lender)), PARKED_ASSETS, "parked assets");
        assertEq(address(midnightBundles).balance, 5 ether, "donation untouched");
    }
}

contract RevertingLog {
    error Reverted();

    fallback() external {
        revert Reverted();
    }
}

contract InvalidResponseRatifier {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(bytes32(0));
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
