// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";

import {IMidnight, Market, Offer, CollateralParams} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {WAD, maxSettlementFee} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";

import {IMorpho, MarketParams, Id} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";

import {MidnightToBlueRoll} from "../src/midnight-to-blue/MidnightToBlueRoll.sol";

/// @dev End-to-end demonstration of the callback-based Midnight → Blue roll.
contract MidnightToBlueRollTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using UtilsLib for uint256;

    uint256 internal constant MIDNIGHT_LLTV = 0.77e18;
    uint256 internal constant BLUE_LLTV = 0.9e18;

    IMidnight internal midnight;
    IMorpho internal morpho;
    MidnightToBlueRoll internal roll;

    ERC20Permit internal loanToken;
    ERC20Permit internal collateralToken;
    Oracle internal midnightOracle;
    OracleMock internal blueOracle;
    DummyRatifier internal ratifier;

    Market internal midnightMarket;
    bytes32 internal midnightId;
    Offer internal lenderOffer;

    MarketParams internal blueParams;
    Id internal blueId;

    address internal user = makeAddr("user");
    address internal lender = makeAddr("lender");
    address internal supplier = makeAddr("supplier");
    address internal owner = makeAddr("owner");

    function setUp() public {
        midnight = IMidnight(deployCode("Midnight"));
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        ratifier = new DummyRatifier();

        loanToken = new ERC20Permit("loan", "loan");
        collateralToken = new ERC20Permit("collateral", "collateral");
        midnightOracle = new Oracle();
        blueOracle = new OracleMock();
        blueOracle.setPrice(ORACLE_PRICE_SCALE);

        roll = new MidnightToBlueRoll(address(midnight), address(morpho));

        midnight.setFeeSetter(address(this));
        midnight.setTickSpacingSetter(address(this));
        midnight.setFeeClaimer(makeAddr("feeClaimer"));
        midnight.enableLltv(MIDNIGHT_LLTV);
        midnight.enableLiquidationCursor(0.25e18);
        for (uint256 i; i <= 6; i++) {
            midnight.setDefaultSettlementFee(address(loanToken), i, maxSettlementFee(i));
        }

        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(BLUE_LLTV);
        vm.stopPrank();

        midnightMarket.chainId = block.chainid;
        midnightMarket.midnight = address(midnight);
        midnightMarket.loanToken = address(loanToken);
        midnightMarket.maturity = block.timestamp + 100;
        midnightMarket.collateralParams
            .push(
                CollateralParams({
                    token: address(collateralToken),
                    lltv: MIDNIGHT_LLTV,
                    liquidationCursor: 0.25e18,
                    oracle: address(midnightOracle)
                })
            );
        midnightId = midnight.touchMarket(midnightMarket);

        blueParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(blueOracle),
            irm: address(0),
            lltv: BLUE_LLTV
        });
        morpho.createMarket(blueParams);
        blueId = blueParams.id();

        lenderOffer.buy = true;
        lenderOffer.maker = lender;
        lenderOffer.market = midnightMarket;
        lenderOffer.expiry = block.timestamp + 200;
        lenderOffer.tick = MAX_TICK;
        lenderOffer.maxUnits = type(uint128).max;
        lenderOffer.ratifier = address(ratifier);
        lenderOffer.continuousFeeCap = type(uint256).max;

        deal(address(loanToken), supplier, 1e32);
        vm.startPrank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(blueParams, 1e32, 0, supplier, "");
        vm.stopPrank();

        deal(address(loanToken), lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.prank(lender);
        midnight.setIsAuthorized(address(ratifier), true, lender);

        vm.prank(user);
        midnight.setIsAuthorized(address(this), true, user);
        vm.prank(user);
        midnight.setIsAuthorized(address(roll), true, user);
        vm.prank(user);
        morpho.setAuthorization(address(roll), true);
    }

    function testRoll() public {
        uint256 units = 1e18;
        uint256 collateralAmount = units.mulDivUp(WAD, MIDNIGHT_LLTV) * 2;
        deal(address(collateralToken), user, collateralAmount);
        vm.startPrank(user);
        collateralToken.approve(address(midnight), collateralAmount);
        midnight.supplyCollateral(midnightMarket, 0, collateralAmount, user);
        vm.stopPrank();

        Offer memory offer = lenderOffer;
        offer.maxUnits = uint128(units);
        midnight.take(offer, hex"", units, user, user, address(0), "");

        // Before: debt & collateral on Midnight, nothing on Blue, roll contract empty.
        assertEq(midnight.debt(midnightId, user), units);
        assertEq(midnight.collateral(midnightId, user, 0), collateralAmount);
        assertEq(morpho.collateral(blueId, user), 0);
        assertEq(loanToken.balanceOf(address(roll)), 0);
        assertEq(collateralToken.balanceOf(address(roll)), 0);

        vm.prank(user);
        roll.roll(midnightMarket, blueParams, 0);

        // After: Midnight closed, Blue mirrors the position, roll contract empty
        // (no flash loan, no leftover capital).
        assertEq(midnight.debt(midnightId, user), 0);
        assertEq(midnight.collateral(midnightId, user, 0), 0);
        assertEq(morpho.collateral(blueId, user), collateralAmount);
        assertEq(morpho.expectedBorrowAssets(blueParams, user), units);
        assertEq(loanToken.balanceOf(address(roll)), 0);
        assertEq(collateralToken.balanceOf(address(roll)), 0);
    }
}
