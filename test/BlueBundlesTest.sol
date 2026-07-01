// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IMorpho, MarketParams, Id} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";
import {WAD} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {BlueBundlesV1} from "../src/blue/BlueBundlesV1.sol";
import {IBlueBundlesV1} from "../src/blue/IBlueBundlesV1.sol";
import {TokenPermit} from "../src/libraries/TokenLib.sol";

contract BlueBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LLTV_DEST = 0.9e18;
    uint256 internal constant LIQUIDITY = 1e32;

    IMorpho internal morpho;
    BlueBundlesV1 internal blueBundles;
    ERC20Permit internal loanToken;
    ERC20Permit internal collateralToken;
    OracleMock internal oracle;
    OracleMock internal destOracle;

    MarketParams internal marketParams;
    Id internal id;
    MarketParams internal destMarketParams;
    Id internal destId;

    address internal owner;
    address internal supplier;
    address internal user;
    address internal referrer;
    address internal receiver;

    function setUp() public {
        owner = makeAddr("owner");
        supplier = makeAddr("supplier");
        referrer = makeAddr("referrer");
        receiver = makeAddr("receiver");
        user = makeAddr("user");

        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        loanToken = new ERC20Permit("loan", "loan");
        collateralToken = new ERC20Permit("collateral", "collateral");
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        blueBundles = new BlueBundlesV1(address(morpho));
        assertEq(blueBundles.BLUE(), address(morpho));

        // IRM address(0) ⇒ zero borrow rate ⇒ exact, interest-free accounting.
        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(LLTV);
        vm.stopPrank();

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: LLTV
        });
        morpho.createMarket(marketParams);
        id = marketParams.id();

        // Destination market for migrateBorrowPosition tests: same token pair, own oracle, higher LLTV.
        vm.prank(owner);
        morpho.enableLltv(LLTV_DEST);
        destOracle = new OracleMock();
        destOracle.setPrice(ORACLE_PRICE_SCALE);
        destMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(destOracle),
            irm: address(0),
            lltv: LLTV_DEST
        });
        morpho.createMarket(destMarketParams);
        destId = destMarketParams.id();

        // Seed both markets with loan-side liquidity so borrows can be served.
        deal(address(loanToken), supplier, 2 * LIQUIDITY);
        vm.startPrank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, LIQUIDITY, 0, supplier, "");
        morpho.supply(destMarketParams, LIQUIDITY, 0, supplier, "");
        vm.stopPrank();

        // The user authorizes the bundler so it can borrow / withdraw on their behalf.
        vm.prank(user);
        morpho.setAuthorization(address(blueBundles), true);
    }

    /// HELPERS ///

    function _noPermit() internal pure returns (TokenPermit memory) {}

    function _collateralFor(uint256 borrowAssets) internal pure returns (uint256) {
        // price == ORACLE_PRICE_SCALE (1:1); 2x gives ample health headroom above the LLTV requirement.
        return borrowAssets * 2;
    }

    /// @dev Opens a borrow position for `onBehalf` directly on Morpho (used to set up repay/withdraw tests).
    function _openBorrow(address onBehalf, uint256 borrowAssets) internal {
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), onBehalf, collateral);
        vm.startPrank(onBehalf);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, collateral, onBehalf, "");
        morpho.borrow(marketParams, borrowAssets, 0, onBehalf, onBehalf);
        vm.stopPrank();
    }

    /// AUTHORIZATION ///

    function testSupplyCollateralAndBorrowUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundlesV1.Unauthorized.selector);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams, 1, 1, WAD, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );
    }

    function testRepayAndWithdrawCollateralUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundlesV1.Unauthorized.selector);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams, 1, 0, 0, WAD, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );
    }

    function testWithdrawUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundlesV1.Unauthorized.selector);
        blueBundles.blueBundlesV1Withdraw(marketParams, 1, user, receiver, 0, address(0), block.timestamp);
    }

    /// @dev Blue-specific inverse of the auth tests: supply is permissionless, so it must succeed even when the
    /// caller is neither the onBehalf nor authorized by them.
    function testSupplyIsPermissionless(uint256 assets) public {
        assets = bound(assets, 1, 1e30);
        address caller = makeAddr("randomSupplier");
        deal(address(loanToken), caller, assets);

        vm.startPrank(caller);
        loanToken.approve(address(blueBundles), assets);
        blueBundles.blueBundlesV1Supply(marketParams, assets, user, _noPermit(), 0, address(0), block.timestamp);
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(marketParams, user), assets, "user supply position");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testPctExceeded() public {
        deal(address(loanToken), user, 1);
        deal(address(collateralToken), user, 1);

        vm.startPrank(user);
        loanToken.approve(address(blueBundles), type(uint256).max);
        collateralToken.approve(address(blueBundles), type(uint256).max);

        vm.expectRevert(IBlueBundlesV1.PctExceeded.selector);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams, 1, 1, WAD, user, receiver, _noPermit(), WAD, address(0), block.timestamp
        );
        vm.expectRevert(IBlueBundlesV1.PctExceeded.selector);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams, 1, 0, 0, WAD, user, receiver, _noPermit(), WAD, address(0), block.timestamp
        );
        vm.expectRevert(IBlueBundlesV1.PctExceeded.selector);
        blueBundles.blueBundlesV1Supply(marketParams, 1, user, _noPermit(), WAD, address(0), block.timestamp);
        vm.expectRevert(IBlueBundlesV1.PctExceeded.selector);
        blueBundles.blueBundlesV1Withdraw(marketParams, 1, user, receiver, WAD, address(0), block.timestamp);
        vm.expectRevert(IBlueBundlesV1.PctExceeded.selector);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, WAD, user, WAD, address(0), block.timestamp
        );
        vm.stopPrank();
    }

    /// @dev Every entrypoint reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testDeadlinePassed() public {
        uint256 past = block.timestamp - 1;

        vm.startPrank(user);
        vm.expectRevert(IBlueBundlesV1.DeadlinePassed.selector);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams, 1, 1, WAD, user, receiver, _noPermit(), 0, address(0), past
        );
        vm.expectRevert(IBlueBundlesV1.DeadlinePassed.selector);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams, 1, 0, 0, WAD, user, receiver, _noPermit(), 0, address(0), past
        );
        vm.expectRevert(IBlueBundlesV1.DeadlinePassed.selector);
        blueBundles.blueBundlesV1Supply(marketParams, 1, user, _noPermit(), 0, address(0), past);
        vm.expectRevert(IBlueBundlesV1.DeadlinePassed.selector);
        blueBundles.blueBundlesV1Withdraw(marketParams, 1, user, receiver, 0, address(0), past);
        vm.expectRevert(IBlueBundlesV1.DeadlinePassed.selector);
        blueBundles.blueBundlesV1MigrateBorrowPosition(marketParams, destMarketParams, WAD, user, 0, address(0), past);
        vm.stopPrank();
    }

    /// SUPPLY COLLATERAL AND BORROW ///

    function testSupplyCollateralAndBorrow(uint256 borrowAssets) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), user, collateral);

        vm.startPrank(user);
        collateralToken.approve(address(blueBundles), collateral);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams, collateral, borrowAssets, WAD, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.collateral(id, user), collateral, "collateral");
        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(loanToken.balanceOf(receiver), borrowAssets, "receiver");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testSupplyCollateralAndBorrowWithReferralFee(uint256 borrowAssets, uint256 referralFeePct) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), user, collateral);

        uint256 expectedFee = borrowAssets * referralFeePct / WAD;

        vm.startPrank(user);
        collateralToken.approve(address(blueBundles), collateral);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams,
            collateral,
            borrowAssets,
            WAD,
            user,
            receiver,
            _noPermit(),
            referralFeePct,
            referrer,
            block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(loanToken.balanceOf(receiver), borrowAssets - expectedFee, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// @dev maxLtv caps the resulting LTV (1:1 price): at the exact-fit ltv the borrow lands on the cap, one wei
    /// less reverts. fitLtv is below the LLTV, so the bundler cap binds before Blue's health check.
    function testSupplyCollateralAndBorrowLtvExceeded() public {
        uint256 borrowAssets = 100e18;
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), user, collateral);

        uint256 fitLtv = borrowAssets * WAD / collateral;

        vm.startPrank(user);
        collateralToken.approve(address(blueBundles), collateral);

        vm.expectRevert(IBlueBundlesV1.LtvExceeded.selector);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams,
            collateral,
            borrowAssets,
            fitLtv - 1,
            user,
            receiver,
            _noPermit(),
            0,
            address(0),
            block.timestamp
        );

        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams, collateral, borrowAssets, fitLtv, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
    }

    /// REPAY AND WITHDRAW COLLATERAL ///

    function testRepayAndWithdrawCollateral() public {
        uint256 borrowAssets = 100e18;
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        uint256 repayAssets = 40e18;
        // After repaying repayAssets, remaining debt is 60e18, needing 75e18 collateral (60/0.8) at 1:1 price.
        uint256 withdrawCollateral = collateral - 75e18;

        deal(address(loanToken), user, repayAssets);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), repayAssets);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams,
            repayAssets,
            repayAssets,
            withdrawCollateral,
            WAD,
            user,
            receiver,
            _noPermit(),
            0,
            address(0),
            block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets - repayAssets, "debt");
        assertEq(morpho.collateral(id, user), collateral - withdrawCollateral, "remaining collateral");
        assertEq(collateralToken.balanceOf(receiver), withdrawCollateral, "collateral receiver");
        assertEq(loanToken.balanceOf(user), 0, "user spent repay assets");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// @dev maxLtv caps the resulting LTV after a withdrawal: repaying 30e18 and withdrawing 100e18 leaves 70e18
    /// debt against 100e18 collateral (LTV 0.7) — within the 0.8 LLTV Blue allows, but above a 0.6 maxLtv.
    function testRepayAndWithdrawCollateralLtvExceeded() public {
        _openBorrow(user, 100e18);

        deal(address(loanToken), user, 30e18);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), 30e18);

        vm.expectRevert(IBlueBundlesV1.LtvExceeded.selector);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams, 30e18, 30e18, 100e18, 0.6e18, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );

        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams, 30e18, 30e18, 100e18, 0.7e18, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), 70e18, "remaining debt");
        assertEq(morpho.collateral(id, user), 100e18, "remaining collateral");
    }

    /// @dev On a pure repay (no withdrawal) the maxLtv cap is skipped: a tight maxLtv below the resulting LTV does
    /// not revert, since a repay can only lower the LTV.
    function testRepayWithoutWithdrawIgnoresMaxLtv() public {
        _openBorrow(user, 100e18);

        // Resulting LTV after repaying 30e18 is 70e18 / 200e18 = 0.35, above the 0.3 maxLtv — but no withdrawal,
        // so the check never runs.
        deal(address(loanToken), user, 30e18);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), 30e18);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams, 30e18, 30e18, 0, 0.3e18, user, receiver, _noPermit(), 0, address(0), block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), 70e18, "remaining debt");
        assertEq(morpho.collateral(id, user), 200e18, "collateral unchanged");
    }

    function testRepayWithReferralFee(uint256 borrowAssets, uint256 repayAssets, uint256 referralFeePct) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        _openBorrow(user, borrowAssets);

        // repayAssets is repaid on Blue; the fee is charged on top, so maxRepayAssets must cover repaid + fee.
        repayAssets = bound(repayAssets, 1, borrowAssets);
        uint256 expectedFee = repayAssets * referralFeePct / (WAD - referralFeePct);
        uint256 maxRepayAssets = repayAssets + expectedFee;

        deal(address(loanToken), user, maxRepayAssets);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), maxRepayAssets);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams,
            repayAssets,
            maxRepayAssets,
            0,
            WAD,
            user,
            receiver,
            _noPermit(),
            referralFeePct,
            referrer,
            block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets - repayAssets, "debt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(user), 0, "user spent repay assets");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// @dev assets == type(uint256).max closes the debt by shares: maxRepayAssets is pulled, debt + fee is spent
    /// (fee on top, as in migrateBorrowPosition), and the unused remainder is refunded to receiver.
    function testRepayMaxClosesDebt(uint256 borrowAssets, uint256 referralFeePct) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        // Zero IRM and sole borrower: the accrued debt is exactly borrowAssets. The fee is borrowed on top, so it is a
        // percentage of the total spent (debt + fee), matching referralFeePct's meaning elsewhere.
        uint256 expectedFee = borrowAssets * referralFeePct / (WAD - referralFeePct);
        uint256 cost = borrowAssets + expectedFee;
        uint256 maxRepayAssets = cost + 1e18; // generous ceiling; the 1e18 excess must be refunded

        deal(address(loanToken), user, maxRepayAssets);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), maxRepayAssets);
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams,
            type(uint256).max,
            maxRepayAssets,
            collateral,
            WAD,
            user,
            receiver,
            _noPermit(),
            referralFeePct,
            referrer,
            block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.borrowShares(id, user), 0, "borrow shares");
        assertEq(morpho.collateral(id, user), 0, "collateral");
        assertEq(collateralToken.balanceOf(receiver), collateral, "collateral receiver");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(user), 0, "user spent maxRepayAssets");
        assertEq(loanToken.balanceOf(receiver), maxRepayAssets - cost, "receiver refunded the unused remainder");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// @dev maxRepayAssets is the user's spend cap on a full close: if it can't cover debt + fee, the repaid debt
    /// drains the pulled amount and the fee transfer runs out of balance, reverting the call.
    function testRepayMaxCapTooLow() public {
        uint256 borrowAssets = 100e18;
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        // Fee = 100e18 * 0.1 / 0.9 ≈ 11.1e18, so cost ≈ 111.1e18; a cap of just the debt can't cover the fee.
        uint256 referralFeePct = 0.1e18;
        uint256 maxRepayAssets = borrowAssets;

        deal(address(loanToken), user, maxRepayAssets);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), maxRepayAssets);
        vm.expectRevert("Insufficient balance");
        blueBundles.blueBundlesV1RepayAndWithdrawCollateral(
            marketParams,
            type(uint256).max,
            maxRepayAssets,
            collateral,
            WAD,
            user,
            receiver,
            _noPermit(),
            referralFeePct,
            referrer,
            block.timestamp
        );
        vm.stopPrank();
    }

    /// SUPPLY ///

    function testSupply(uint256 assets) public {
        assets = bound(assets, 1, 1e30);
        deal(address(loanToken), user, assets);

        vm.startPrank(user);
        loanToken.approve(address(blueBundles), assets);
        blueBundles.blueBundlesV1Supply(marketParams, assets, user, _noPermit(), 0, address(0), block.timestamp);
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(marketParams, user), assets, "supply position");
        assertEq(loanToken.balanceOf(user), 0, "user spent assets");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testSupplyWithReferralFee(uint256 assets, uint256 referralFeePct) public {
        assets = bound(assets, 1, 1e30);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        deal(address(loanToken), user, assets);

        uint256 expectedFee = assets * referralFeePct / WAD;
        uint256 supplied = assets - expectedFee;

        vm.startPrank(user);
        loanToken.approve(address(blueBundles), assets);
        blueBundles.blueBundlesV1Supply(
            marketParams, assets, user, _noPermit(), referralFeePct, referrer, block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(marketParams, user), supplied, "supply net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// WITHDRAW ///

    function testWithdraw(uint256 supplyAssets, uint256 withdrawAssets) public {
        supplyAssets = bound(supplyAssets, 1, 1e30);
        withdrawAssets = bound(withdrawAssets, 1, supplyAssets);
        deal(address(loanToken), user, supplyAssets);

        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAssets, 0, user, "");
        blueBundles.blueBundlesV1Withdraw(marketParams, withdrawAssets, user, receiver, 0, address(0), block.timestamp);
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(marketParams, user), supplyAssets - withdrawAssets, "remaining supply");
        assertEq(loanToken.balanceOf(receiver), withdrawAssets, "receiver");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testWithdrawWithReferralFee(uint256 supplyAssets, uint256 withdrawAssets, uint256 referralFeePct) public {
        supplyAssets = bound(supplyAssets, 1, 1e30);
        withdrawAssets = bound(withdrawAssets, 1, supplyAssets);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        deal(address(loanToken), user, supplyAssets);

        uint256 expectedFee = withdrawAssets * referralFeePct / WAD;

        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAssets, 0, user, "");
        blueBundles.blueBundlesV1Withdraw(
            marketParams, withdrawAssets, user, receiver, referralFeePct, referrer, block.timestamp
        );
        vm.stopPrank();

        assertEq(loanToken.balanceOf(receiver), withdrawAssets - expectedFee, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// @dev withdrawAssets == type(uint256).max closes the supply position by shares: no supply shares remain.
    function testWithdrawMaxClosesPosition(uint256 supplyAssets, uint256 referralFeePct) public {
        supplyAssets = bound(supplyAssets, 1, 1e30);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        deal(address(loanToken), user, supplyAssets);

        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAssets, 0, user, "");
        blueBundles.blueBundlesV1Withdraw(
            marketParams, type(uint256).max, user, receiver, referralFeePct, referrer, block.timestamp
        );
        vm.stopPrank();

        // Withdrawing by shares rounds assets down, so up to 1 wei can stay behind in the market.
        uint256 withdrawn = loanToken.balanceOf(receiver) + loanToken.balanceOf(referrer);
        uint256 expectedFee = withdrawn * referralFeePct / WAD;

        assertEq(morpho.supplyShares(id, user), 0, "supply shares");
        assertApproxEqAbs(withdrawn, supplyAssets, 1, "withdrawn");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(receiver), withdrawn - expectedFee, "receiver net");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// MIGRATE BORROW POSITION ///

    function testMigrateBorrowPositionUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundlesV1.Unauthorized.selector);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, WAD, user, 0, address(0), block.timestamp
        );
    }

    function testMigrateBorrowPositionCallbackNotBlue() public {
        vm.expectRevert(IBlueBundlesV1.UnauthorizedCallback.selector);
        blueBundles.onMorphoRepay(0, "");
    }

    function testMigrateBorrowPositionInconsistentTokens() public {
        MarketParams memory wrongDest = destMarketParams;
        wrongDest.loanToken = address(collateralToken);

        vm.prank(user);
        vm.expectRevert(IBlueBundlesV1.InconsistentTokens.selector);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, wrongDest, WAD, user, 0, address(0), block.timestamp
        );
    }

    function testMigrateBorrowPositionLtvExceeded() public {
        uint256 borrowAssets = 100e18;
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        // Allowed borrow = collateral value * maxLtv (1:1 price). At the exact-fit ltv the allowance equals the
        // debt; one wei less drops it just below.
        uint256 fitLtv = borrowAssets * WAD / collateral;

        vm.prank(user);
        vm.expectRevert(IBlueBundlesV1.LtvExceeded.selector);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, fitLtv - 1, user, 0, address(0), block.timestamp
        );

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, fitLtv, user, 0, address(0), block.timestamp
        );
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets, "dest debt");
    }

    /// @dev The LTV bound applies to the total destination borrow, fee included: a threshold that fits the debt
    /// alone reverts once the fee is added on top.
    function testMigrateBorrowPositionLtvExceededWithReferralFee() public {
        uint256 borrowAssets = 100e18;
        uint256 referralFeePct = 0.1e18;
        _openBorrow(user, borrowAssets);

        // Collateral 200e18 (1:1 price) at maxLtv 0.54 allows 108e18: fits the 100e18 debt, not debt + 10e18 fee.
        uint256 maxLtv = 0.54e18;

        vm.prank(user);
        vm.expectRevert(IBlueBundlesV1.LtvExceeded.selector);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, maxLtv, user, referralFeePct, referrer, block.timestamp
        );

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, maxLtv, user, 0, address(0), block.timestamp
        );
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets, "dest debt");
    }

    /// @dev With maxLtv == destLltv the bundler cap is a no-op (it short-circuits at/above the LLTV), so Blue's own
    /// health check bounds the borrow: a position landing precisely at the destination LLTV limit passes.
    function testMigrateBorrowPositionLtvBoundAtDestLltvExactLimit() public {
        // Dest collateral value is half the source's: 200e18 collateral => 100e18 value => 90e18 limit at 0.9 LLTV.
        destOracle.setPrice(ORACLE_PRICE_SCALE / 2);
        uint256 collateral = 200e18;
        deal(address(collateralToken), user, collateral);

        vm.startPrank(user);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, collateral, user, "");
        morpho.borrow(marketParams, 90e18, 0, user, user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, LLTV_DEST, user, 0, address(0), block.timestamp
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), 90e18, "dest debt at the LLTV limit");
    }

    function testMigrateBorrowPositionLtvBoundAtDestLltvOverLimit() public {
        destOracle.setPrice(ORACLE_PRICE_SCALE / 2);
        uint256 collateral = 200e18;
        deal(address(collateralToken), user, collateral);

        vm.startPrank(user);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, collateral, user, "");
        morpho.borrow(marketParams, 90e18 + 1, 0, user, user);
        // maxLtv == destLltv makes the bundler cap a no-op, so the over-limit borrow reverts on Blue's own check.
        vm.expectRevert(bytes("insufficient collateral"));
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, LLTV_DEST, user, 0, address(0), block.timestamp
        );
        vm.stopPrank();
    }

    function testMigrateBorrowPosition(uint256 borrowAssets) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, WAD, user, 0, address(0), block.timestamp
        );

        assertEq(morpho.collateral(id, user), 0, "source collateral");
        assertEq(morpho.borrowShares(id, user), 0, "source debt");
        assertEq(morpho.collateral(destId, user), collateral, "dest collateral");
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets, "dest debt");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler loan residual");
        assertEq(collateralToken.balanceOf(address(blueBundles)), 0, "bundler collateral residual");
        // Capital-free: the user's loan token balance (the original borrow proceeds) is untouched.
        assertEq(loanToken.balanceOf(user), borrowAssets, "user loan tokens untouched");
    }

    /// @dev The fee is borrowed on the destination on top of the repaid assets, so the move stays capital-free for
    /// the user and the fee shows up as extra destination debt.
    function testMigrateBorrowPositionWithReferralFee(uint256 borrowAssets, uint256 referralFeePct) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        // Collateral is 2x the debt and dest LLTV is 0.9, so total borrow must stay under 1.8x. The fee is borrowed on
        // top (pct / (WAD - pct)), so cap pct at 0.4e18 => fee <= 0.667x => total <= 1.667x.
        referralFeePct = bound(referralFeePct, 0, 0.4e18);
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        uint256 expectedFee = borrowAssets * referralFeePct / (WAD - referralFeePct);

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, WAD, user, referralFeePct, referrer, block.timestamp
        );

        assertEq(morpho.collateral(id, user), 0, "source collateral");
        assertEq(morpho.borrowShares(id, user), 0, "source debt");
        assertEq(morpho.collateral(destId, user), collateral, "dest collateral");
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets + expectedFee, "dest debt incl fee");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler loan residual");
        assertEq(collateralToken.balanceOf(address(blueBundles)), 0, "bundler collateral residual");
        // Still capital-free for the user: the fee is financed by the extra destination borrow.
        assertEq(loanToken.balanceOf(user), borrowAssets, "user loan tokens untouched");
    }

    /// @dev The source oracle is never read during a full-position migrateBorrowPosition: the debt is zero by the
    /// time the collateral withdrawal health check runs, which short-circuits before the oracle call. Positions can
    /// therefore migrate out of a market whose oracle is broken.
    function testMigrateBorrowPositionWithBrokenSourceOracle() public {
        uint256 borrowAssets = 100e18;
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IOracle.price.selector), "oracle down");

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, WAD, user, 0, address(0), block.timestamp
        );

        assertEq(morpho.borrowShares(id, user), 0, "source debt");
        assertEq(morpho.collateral(destId, user), collateral, "dest collateral");
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets, "dest debt");
    }

    /// @dev Reading the position from Blue makes migrateBorrowPosition immune to drift: a third party repaying part
    /// of the debt between quoting and execution no longer reverts the call — the remaining position is moved.
    function testMigrateBorrowPositionAfterThirdPartyRepay() public {
        uint256 borrowAssets = 100e18;
        _openBorrow(user, borrowAssets);
        uint256 collateral = morpho.collateral(id, user);

        address thirdParty = makeAddr("thirdParty");
        deal(address(loanToken), thirdParty, 1);
        vm.startPrank(thirdParty);
        loanToken.approve(address(morpho), 1);
        morpho.repay(marketParams, 1, 0, user, "");
        vm.stopPrank();

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams, destMarketParams, WAD, user, 0, address(0), block.timestamp
        );

        assertEq(morpho.borrowShares(id, user), 0, "source debt");
        assertEq(morpho.collateral(id, user), 0, "source collateral");
        assertEq(morpho.collateral(destId, user), collateral, "dest collateral");
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets - 1, "dest debt");
    }
}
