// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";

import {IMidnight, Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {WAD, maxSettlementFee} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";

import {IMorpho, MarketParams, Id, Authorization, Signature} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE, AUTHORIZATION_TYPEHASH} from "../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";

import {MidnightToBlueBundlesV1} from "../src/midnight-to-blue/MidnightToBlueBundlesV1.sol";
import {
    IMidnightToBlueBundlesV1,
    MAX_REFERRAL_FEE_PCT
} from "../src/midnight-to-blue/interfaces/IMidnightToBlueBundlesV1.sol";
import {SignedAuthorization} from "../src/blue/interfaces/IBlueBundlesV1.sol";

contract MidnightToBlueBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using UtilsLib for uint256;

    uint256 internal constant MIDNIGHT_LLTV = 0.77e18;
    uint256 internal constant BLUE_LLTV = 0.9e18;
    uint256 internal constant LIQUIDITY = 1e32;
    uint256 internal constant LIQUIDATION_CURSOR = 0.25e18;

    IMidnight internal midnight;
    IMorpho internal morpho;
    MidnightToBlueBundlesV1 internal bundle;

    ERC20 internal loanToken;
    ERC20 internal collateralToken;
    Oracle internal midnightOracle;
    OracleMock internal blueOracle;
    DummyRatifier internal ratifier;

    Market internal midnightMarket;
    bytes32 internal midnightId;
    Offer internal lenderOffer;

    MarketParams internal blueParams;
    Id internal blueId;

    address internal owner;
    address internal supplier;
    address internal lender;
    address internal referrer;
    address internal user;
    uint256 internal userKey;

    function setUp() public {
        owner = makeAddr("owner");
        supplier = makeAddr("supplier");
        lender = makeAddr("lender");
        referrer = makeAddr("referrer");
        (user, userKey) = makeAddrAndKey("user");

        midnight = IMidnight(deployCode("Midnight"));
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        ratifier = new DummyRatifier();

        loanToken = new ERC20Permit("loan", "loan");
        collateralToken = new ERC20Permit("collateral", "collateral");
        midnightOracle = new Oracle();
        blueOracle = new OracleMock();
        blueOracle.setPrice(ORACLE_PRICE_SCALE);

        bundle = new MidnightToBlueBundlesV1(address(midnight), address(morpho));
        assertEq(bundle.MIDNIGHT(), address(midnight));
        assertEq(bundle.BLUE(), address(morpho));

        // Configure Midnight: enable LLTV/liquidation cursor, set fees to their max.
        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));
        midnight.setFeeClaimer(makeAddr("feeClaimer"));
        midnight.enableLltv(MIDNIGHT_LLTV);
        midnight.enableLiquidationCursor(LIQUIDATION_CURSOR);
        for (uint256 i; i <= 6; i++) {
            midnight.setDefaultSettlementFee(address(loanToken), i, maxSettlementFee(i));
        }

        // Configure Blue: zero-rate IRM, enable destination LLTV.
        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(BLUE_LLTV);
        vm.stopPrank();

        // Midnight source market (single collateral, matches Blue's).
        midnightMarket.chainId = block.chainid;
        midnightMarket.midnight = address(midnight);
        midnightMarket.loanToken = address(loanToken);
        midnightMarket.maturity = block.timestamp + 100;
        midnightMarket.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken),
                    lltv: MIDNIGHT_LLTV,
                    liquidationCursor: LIQUIDATION_CURSOR,
                    oracle: address(midnightOracle)
                })
            );
        midnightId = midnight.touchMarket(midnightMarket);

        // Blue destination market with the SAME loan and collateral tokens.
        blueParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(blueOracle),
            irm: address(0),
            lltv: BLUE_LLTV
        });
        morpho.createMarket(blueParams);
        blueId = blueParams.id();

        // Lender offer: buys units on Midnight (provides loan-token liquidity to the borrower).
        lenderOffer.buy = true;
        lenderOffer.maker = lender;
        lenderOffer.market = midnightMarket;
        lenderOffer.expiry = block.timestamp + 200;
        lenderOffer.tick = MAX_TICK;
        lenderOffer.maxUnits = type(uint128).max;
        lenderOffer.ratifier = address(ratifier);
        lenderOffer.continuousFeeCap = type(uint256).max;

        // Blue liquidity so the destination borrow can be served.
        deal(address(loanToken), supplier, LIQUIDITY);
        vm.startPrank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(blueParams, LIQUIDITY, 0, supplier, "");
        vm.stopPrank();

        // Fund lender and let Midnight pull loan tokens during take.
        deal(address(loanToken), lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        // The maker must have authorized their ratifier on Midnight.
        vm.prank(lender);
        midnight.setIsAuthorized(address(ratifier), true, lender);

        // User authorizations: test contract to originate the debt via midnight.take, bundle to run the roll.
        vm.prank(user);
        midnight.setIsAuthorized(address(this), true, user);
        vm.prank(user);
        midnight.setIsAuthorized(address(bundle), true, user);
        vm.prank(user);
        morpho.setAuthorization(address(bundle), true);
    }

    /// HELPERS ///

    function _noAuthSig() internal pure returns (SignedAuthorization memory) {}

    /// @dev Signs a Blue authorization for the bundle over msg.sender's current nonce and the given deadline.
    function _signBlueAuth(uint256 privateKey, address authorizer, uint256 sigDeadline)
        internal
        view
        returns (SignedAuthorization memory)
    {
        Authorization memory authorization = Authorization({
            authorizer: authorizer,
            authorized: address(bundle),
            isAuthorized: true,
            nonce: morpho.nonce(authorizer),
            deadline: sigDeadline
        });
        bytes32 digest = keccak256(
            bytes.concat(
                "\x19\x01", morpho.DOMAIN_SEPARATOR(), keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return SignedAuthorization({
            signature: Signature({v: v, r: r, s: s}), nonce: authorization.nonce, deadline: authorization.deadline
        });
    }

    /// @dev Opens a Midnight borrow for `user`: supplies 2x-of-min collateral, then takes `units` against the lender's
    /// buy offer via the test contract (authorized by user). Returns the collateral supplied.
    function _openMidnightBorrow(uint256 units) internal returns (uint256 collateralAmount) {
        // 2x margin on top of the Midnight LLTV minimum so the destination Blue borrow (with a small referral fee)
        // still fits under BLUE_LLTV.
        collateralAmount = units.mulDivUp(WAD, MIDNIGHT_LLTV) * 2;
        deal(address(collateralToken), user, collateralAmount);
        vm.startPrank(user);
        collateralToken.approve(address(midnight), collateralAmount);
        midnight.supplyCollateral(midnightMarket, 0, collateralAmount, user);
        vm.stopPrank();

        Offer memory offer = lenderOffer;
        offer.maxUnits = uint128(units);
        midnight.take(offer, hex"", units, user, user, address(0), "");
    }

    /// HAPPY PATH ///

    /// @dev The bundle migrates the borrower's full Midnight debt+collateral to Blue in one transaction, without a
    /// flash loan: the destination Blue borrow, taken inside Midnight's onRepay callback, funds the Midnight repay.
    function testMigrateBorrowPosition(uint256 units) public {
        units = bound(units, 1e6, 1e24);
        uint256 collateralAmount = _openMidnightBorrow(units);

        // Pre-state.
        assertEq(midnight.debt(midnightId, user), units, "midnight debt before");
        assertEq(midnight.collateral(midnightId, user, 0), collateralAmount, "midnight collateral before");
        assertEq(morpho.expectedBorrowAssets(blueParams, user), 0, "blue debt before");
        assertEq(morpho.collateral(blueId, user), 0, "blue collateral before");
        assertEq(loanToken.balanceOf(address(bundle)), 0, "bundle loan before");
        assertEq(collateralToken.balanceOf(address(bundle)), 0, "bundle collateral before");

        vm.prank(user);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units, 0, WAD, _noAuthSig(), 0, address(0), block.timestamp
        );

        // Post-state: Midnight closed, Blue mirrors it (no referral fee).
        assertEq(midnight.debt(midnightId, user), 0, "midnight debt after");
        assertEq(midnight.collateral(midnightId, user, 0), 0, "midnight collateral after");
        assertEq(morpho.expectedBorrowAssets(blueParams, user), units, "blue debt after");
        assertEq(morpho.collateral(blueId, user), collateralAmount, "blue collateral after");

        // No flash loan / no leftover capital.
        assertEq(loanToken.balanceOf(address(bundle)), 0, "bundle loan after");
        assertEq(collateralToken.balanceOf(address(bundle)), 0, "bundle collateral after");
    }

    /// @dev A user with no prior Blue authorization can run the roll in a single tx via destAuthorization.
    function testMigrateBorrowPositionWithBlueAuthSig(uint256 units) public {
        units = bound(units, 1e6, 1e24);
        _openMidnightBorrow(units);

        // Revoke any pre-existing Blue authorization; use only the signed one.
        vm.prank(user);
        morpho.setAuthorization(address(bundle), false);
        assertFalse(morpho.isAuthorized(user, address(bundle)));

        SignedAuthorization memory authSig = _signBlueAuth(userKey, user, block.timestamp);
        vm.prank(user);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units, 0, WAD, authSig, 0, address(0), block.timestamp
        );

        assertTrue(morpho.isAuthorized(user, address(bundle)));
        assertEq(midnight.debt(midnightId, user), 0);
        assertEq(morpho.expectedBorrowAssets(blueParams, user), units);
    }

    /// @dev The referral fee is borrowed on Blue on top of the Midnight repaid units.
    function testMigrateBorrowPositionReferralFee(uint256 units, uint256 referralFeePct) public {
        units = bound(units, 1e6, 1e24);
        referralFeePct = bound(referralFeePct, 1, MAX_REFERRAL_FEE_PCT);
        _openMidnightBorrow(units);

        uint256 expectedFee = units * referralFeePct / (WAD - referralFeePct);
        assertEq(loanToken.balanceOf(referrer), 0);

        vm.prank(user);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units, 0, WAD, _noAuthSig(), referralFeePct, referrer, block.timestamp
        );

        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer got fee");
        assertEq(morpho.expectedBorrowAssets(blueParams, user), units + expectedFee, "blue debt includes fee");
        assertEq(loanToken.balanceOf(address(bundle)), 0);
        assertEq(collateralToken.balanceOf(address(bundle)), 0);
    }

    /// @dev Exactly MAX_REFERRAL_FEE_PCT is allowed (boundary test); one wei above reverts.
    function testMigrateBorrowPositionAtReferralFeeCap() public {
        uint256 units = 1e18;
        _openMidnightBorrow(units);
        uint256 expectedFee = units * MAX_REFERRAL_FEE_PCT / (WAD - MAX_REFERRAL_FEE_PCT);
        vm.prank(user);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units, 0, WAD, _noAuthSig(), MAX_REFERRAL_FEE_PCT, referrer, block.timestamp
        );
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer got capped fee");
    }

    /// REVERTS ///

    function testMigrateBorrowPositionRevertsOnPastDeadline() public {
        _openMidnightBorrow(1e18);
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.DeadlinePassed.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, 1e18, 0, WAD, _noAuthSig(), 0, address(0), block.timestamp - 1
        );
    }

    function testMigrateBorrowPositionRevertsAboveReferralFeeCap() public {
        _openMidnightBorrow(1e18);
        // One wei above the hardcap reverts.
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.PctExceeded.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket,
            blueParams,
            0,
            1e18,
            0,
            WAD,
            _noAuthSig(),
            MAX_REFERRAL_FEE_PCT + 1,
            referrer,
            block.timestamp
        );
    }

    function testOnRepayRevertsFromNonMidnightCaller() public {
        vm.expectRevert(IMidnightToBlueBundlesV1.UnauthorizedCallback.selector);
        bundle.onRepay(bytes32(0), midnightMarket, 0, user, hex"");
    }

    /// @dev Midnight's repay accepts an arbitrary callback address. Without the transient-storage commitment,
    /// an attacker with only their own Midnight/Blue positions could invoke Midnight.repay with the bundle as the
    /// callback and forged data referencing the victim, then abuse the victim's standing Midnight+Blue authorizations
    /// to yank the victim's collateral and open a Blue borrow on their behalf. Ensure that path reverts.
    function testOnRepayRevertsWhenInvokedViaMidnightWithForgedData() public {
        // Victim has a legitimate Midnight position and standing authorizations for the bundle on both protocols
        // (these are set up in setUp for `user`).
        _openMidnightBorrow(1e18);

        // Attacker has their own tiny Midnight market with the same loan token; they authorize the bundle themselves
        // (any user can, unilaterally) and open a small debt so `debt >= units`.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        midnight.setIsAuthorized(address(bundle), true, attacker);

        // Attacker's own Midnight market (different maturity so it's a fresh market).
        CollateralParams[] memory attackerCollateralParams = new CollateralParams[](1);
        attackerCollateralParams[0] = CollateralParams({
            token: address(collateralToken),
            lltv: MIDNIGHT_LLTV,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(midnightOracle)
        });
        Market memory attackerMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: attackerCollateralParams,
            maturity: block.timestamp + 300,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        midnight.touchMarket(attackerMarket);

        // Give attacker collateral and a small debt on their own market.
        uint256 units = 1e15;
        uint256 attackerCollateral = units.mulDivUp(WAD, MIDNIGHT_LLTV) * 2;
        deal(address(collateralToken), attacker, attackerCollateral);
        vm.startPrank(attacker);
        collateralToken.approve(address(midnight), attackerCollateral);
        midnight.supplyCollateral(attackerMarket, 0, attackerCollateral, attacker);
        vm.stopPrank();
        // Attacker takes a small position against the lender's offer on the attacker's own market.
        // Use a distinct `group` so the lender's per-group consumed counter isn't shared with the victim's take.
        Offer memory attackerOffer = lenderOffer;
        attackerOffer.market = attackerMarket;
        attackerOffer.group = bytes32(uint256(0xdeadbeef));
        vm.prank(attacker);
        midnight.setIsAuthorized(address(this), true, attacker);
        midnight.take(attackerOffer, hex"", units, attacker, attacker, address(0), "");

        // Attacker forges callback data pointing at the victim, so the bundle would move the victim's assets.
        bytes memory forgedData = abi.encode(
            midnightMarket, // source: victim's Midnight market
            blueParams,
            uint256(0), // collateralIndex
            midnight.collateral(midnightId, user, 0), // collateralAmount to yank
            user, // sender: forged as victim
            uint256(0), // referralFeePct
            address(0), // referralFeeRecipient
            uint256(0) // destMinSharePriceE27
        );
        vm.prank(attacker);
        vm.expectRevert(IMidnightToBlueBundlesV1.UnauthorizedCallback.selector);
        midnight.repay(attackerMarket, units, attacker, address(bundle), forgedData);

        // Victim's position must still be intact.
        assertEq(midnight.debt(midnightId, user), 1e18, "victim's debt untouched");
        assertGt(midnight.collateral(midnightId, user, 0), 0, "victim's collateral untouched");
        assertEq(morpho.collateral(blueId, user), 0, "no Blue position opened on victim");
    }

    function testMigrateBorrowPositionRevertsOnLoanTokenMismatch() public {
        _openMidnightBorrow(1e18);
        MarketParams memory bad = blueParams;
        bad.loanToken = address(new ERC20Permit("other", "other"));
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.InconsistentTokens.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, bad, 0, 1e18, 0, WAD, _noAuthSig(), 0, address(0), block.timestamp
        );
    }

    function testMigrateBorrowPositionRevertsOnCollateralTokenMismatch() public {
        _openMidnightBorrow(1e18);
        MarketParams memory bad = blueParams;
        bad.collateralToken = address(new ERC20Permit("other", "other"));
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.InconsistentTokens.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, bad, 0, 1e18, 0, WAD, _noAuthSig(), 0, address(0), block.timestamp
        );
    }

    function testMigrateBorrowPositionRevertsOnSourceSlippage() public {
        uint256 units = 1e18;
        _openMidnightBorrow(units);
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.SlippageExceeded.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units - 1, 0, WAD, _noAuthSig(), 0, address(0), block.timestamp
        );
    }

    function testMigrateBorrowPositionRevertsOnDestSlippage() public {
        uint256 units = 1e18;
        _openMidnightBorrow(units);
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.SlippageExceeded.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units, type(uint256).max, WAD, _noAuthSig(), 0, address(0), block.timestamp
        );
    }

    function testMigrateBorrowPositionRevertsOnLtvExceeded() public {
        uint256 units = 1e18;
        _openMidnightBorrow(units);
        // 2x collateral margin ⇒ resulting LTV ~= 0.5 * MIDNIGHT_LLTV = 0.385. Any maxLtv below that reverts.
        vm.prank(user);
        vm.expectRevert(IMidnightToBlueBundlesV1.LtvExceeded.selector);
        bundle.midnightToBlueBundlesV1MigrateBorrowPosition(
            midnightMarket, blueParams, 0, units, 0, 0.1e18, _noAuthSig(), 0, address(0), block.timestamp
        );
    }
}
