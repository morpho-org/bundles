// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho-blue/libraries/ConstantsLib.sol";
import {OracleMock} from "morpho-blue/mocks/OracleMock.sol";
import {WAD} from "midnight/libraries/ConstantsLib.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Permit2 as VendorPermit2} from "../lib/midnight/test/vendor/Permit2.sol";
import {BlueBundles} from "../src/blue/BlueBundles.sol";
import {IBlueBundles} from "../src/blue/IBlueBundles.sol";
import {TokenPermit, PermitKind} from "../src/libraries/TokenLib.sol";

contract BlueBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LIQUIDITY = 1e32;

    IMorpho internal morpho;
    BlueBundles internal blueBundles;
    ERC20Permit internal loanToken;
    ERC20Permit internal collateralToken;
    OracleMock internal oracle;

    MarketParams internal marketParams;
    Id internal id;

    address internal owner;
    address internal supplier;
    address internal user;
    address internal referrer;
    address internal receiver;
    mapping(address => uint256) internal privateKey;

    function setUp() public {
        owner = makeAddr("owner");
        supplier = makeAddr("supplier");
        referrer = makeAddr("referrer");
        receiver = makeAddr("receiver");
        uint256 userPk;
        (user, userPk) = makeAddrAndKey("user");
        privateKey[user] = userPk;

        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        loanToken = new ERC20Permit("loan", "loan");
        collateralToken = new ERC20Permit("collateral", "collateral");
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        blueBundles = new BlueBundles(address(morpho));
        assertEq(blueBundles.BLUE(), address(morpho));
        deployCodeTo("Permit2", PERMIT2);

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

        // Seed the market with loan-side liquidity so borrows can be served.
        deal(address(loanToken), supplier, LIQUIDITY);
        vm.startPrank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, LIQUIDITY, 0, supplier, "");
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

    function _permit2(address token, address holder, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (TokenPermit memory)
    {
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                tokenPermissionsHash,
                address(blueBundles),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", VendorPermit2(PERMIT2).DOMAIN_SEPARATOR(), permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey[holder], digest);
        return TokenPermit({kind: PermitKind.Permit2, data: abi.encode(nonce, deadline, abi.encodePacked(r, s, v))});
    }

    function _permit(address token, address holder, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (TokenPermit memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(ERC20Permit(token).PERMIT_TYPEHASH(), holder, address(blueBundles), amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey[holder], digest);
        return TokenPermit({kind: PermitKind.ERC2612, data: abi.encode(deadline, v, r, s)});
    }

    /// AUTHORIZATION ///

    function testSupplyCollateralAndBorrowUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundles.Unauthorized.selector);
        blueBundles.supplyCollateralAndBorrow(marketParams, 1, 1, user, receiver, _noPermit(), 0, address(0));
    }

    function testRepayAndWithdrawCollateralUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundles.Unauthorized.selector);
        blueBundles.repayAndWithdrawCollateral(marketParams, 1, 0, user, receiver, _noPermit(), 0, address(0));
    }

    function testWithdrawUnauthorized() public {
        vm.prank(address(0xdead));
        vm.expectRevert(IBlueBundles.Unauthorized.selector);
        blueBundles.withdraw(marketParams, 1, user, receiver, 0, address(0));
    }

    /// @dev Blue-specific inverse of the auth tests: supply is permissionless, so it must succeed even when the
    /// caller is neither the onBehalf nor authorized by them.
    function testSupplyIsPermissionless(uint256 assets) public {
        assets = bound(assets, 1, 1e30);
        address caller = makeAddr("randomSupplier");
        deal(address(loanToken), caller, assets);

        vm.startPrank(caller);
        loanToken.approve(address(blueBundles), assets);
        blueBundles.supply(marketParams, assets, user, _noPermit(), 0, address(0));
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

        vm.expectRevert(IBlueBundles.PctExceeded.selector);
        blueBundles.supplyCollateralAndBorrow(marketParams, 1, 1, user, receiver, _noPermit(), WAD, address(0));
        vm.expectRevert(IBlueBundles.PctExceeded.selector);
        blueBundles.repayAndWithdrawCollateral(marketParams, 1, 0, user, receiver, _noPermit(), WAD, address(0));
        vm.expectRevert(IBlueBundles.PctExceeded.selector);
        blueBundles.supply(marketParams, 1, user, _noPermit(), WAD, address(0));
        vm.expectRevert(IBlueBundles.PctExceeded.selector);
        blueBundles.withdraw(marketParams, 1, user, receiver, WAD, address(0));
        vm.stopPrank();
    }

    /// SUPPLY COLLATERAL AND BORROW ///

    function testSupplyCollateralAndBorrow(uint256 borrowAssets) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), user, collateral);

        vm.startPrank(user);
        collateralToken.approve(address(blueBundles), collateral);
        blueBundles.supplyCollateralAndBorrow(
            marketParams, collateral, borrowAssets, user, receiver, _noPermit(), 0, address(0)
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
        blueBundles.supplyCollateralAndBorrow(
            marketParams, collateral, borrowAssets, user, receiver, _noPermit(), referralFeePct, referrer
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(loanToken.balanceOf(receiver), borrowAssets - expectedFee, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testSupplyCollateralAndBorrowPermit2() public {
        uint256 borrowAssets = 100e18;
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), user, collateral);

        vm.startPrank(user);
        collateralToken.approve(PERMIT2, collateral);
        vm.stopPrank();

        TokenPermit memory permit =
            _permit2(address(collateralToken), user, collateral, 0, vm.getBlockTimestamp() + 1);
        vm.prank(user);
        blueBundles.supplyCollateralAndBorrow(
            marketParams, collateral, borrowAssets, user, receiver, permit, 0, address(0)
        );

        assertEq(collateralToken.allowance(user, address(blueBundles)), 0);
        assertEq(collateralToken.allowance(user, PERMIT2), 0);
        assertEq(morpho.collateral(id, user), collateral);
        assertEq(loanToken.balanceOf(receiver), borrowAssets);
    }

    function testSupplyCollateralAndBorrowPermit() public {
        uint256 borrowAssets = 100e18;
        uint256 collateral = _collateralFor(borrowAssets);
        deal(address(collateralToken), user, collateral);

        TokenPermit memory permit =
            _permit(address(collateralToken), user, collateral, 0, vm.getBlockTimestamp() + 1);
        vm.prank(user);
        blueBundles.supplyCollateralAndBorrow(
            marketParams, collateral, borrowAssets, user, receiver, permit, 0, address(0)
        );

        assertEq(collateralToken.allowance(user, address(blueBundles)), 0);
        assertEq(morpho.collateral(id, user), collateral);
        assertEq(loanToken.balanceOf(receiver), borrowAssets);
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
        blueBundles.repayAndWithdrawCollateral(
            marketParams, repayAssets, withdrawCollateral, user, receiver, _noPermit(), 0, address(0)
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets - repayAssets, "debt");
        assertEq(morpho.collateral(id, user), collateral - withdrawCollateral, "remaining collateral");
        assertEq(collateralToken.balanceOf(receiver), withdrawCollateral, "collateral receiver");
        assertEq(loanToken.balanceOf(user), 0, "user spent repay assets");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testRepayWithReferralFee(uint256 borrowAssets, uint256 repayAssets, uint256 referralFeePct) public {
        borrowAssets = bound(borrowAssets, 1, 1e30);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        _openBorrow(user, borrowAssets);

        // Bound repayAssets so the post-fee amount repaid never exceeds outstanding debt.
        uint256 maxRepay = borrowAssets * WAD / (WAD - referralFeePct);
        repayAssets = bound(repayAssets, 1, maxRepay);
        uint256 expectedFee = repayAssets * referralFeePct / WAD;
        uint256 repaid = repayAssets - expectedFee;

        deal(address(loanToken), user, repayAssets);
        vm.startPrank(user);
        loanToken.approve(address(blueBundles), repayAssets);
        blueBundles.repayAndWithdrawCollateral(
            marketParams, repayAssets, 0, user, receiver, _noPermit(), referralFeePct, referrer
        );
        vm.stopPrank();

        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets - repaid, "debt");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(user), 0, "user spent repay assets");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testRepayPermit2() public {
        uint256 borrowAssets = 100e18;
        _openBorrow(user, borrowAssets);

        uint256 repayAssets = 40e18;
        deal(address(loanToken), user, repayAssets);
        vm.startPrank(user);
        loanToken.approve(PERMIT2, repayAssets);
        vm.stopPrank();

        TokenPermit memory permit = _permit2(address(loanToken), user, repayAssets, 0, vm.getBlockTimestamp() + 1);
        vm.prank(user);
        blueBundles.repayAndWithdrawCollateral(
            marketParams, repayAssets, 0, user, receiver, permit, 0, address(0)
        );

        assertEq(loanToken.allowance(user, address(blueBundles)), 0);
        assertEq(loanToken.allowance(user, PERMIT2), 0);
        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets - repayAssets);
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// SUPPLY ///

    function testSupply(uint256 assets) public {
        assets = bound(assets, 1, 1e30);
        deal(address(loanToken), user, assets);

        vm.startPrank(user);
        loanToken.approve(address(blueBundles), assets);
        blueBundles.supply(marketParams, assets, user, _noPermit(), 0, address(0));
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
        blueBundles.supply(marketParams, assets, user, _noPermit(), referralFeePct, referrer);
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(marketParams, user), supplied, "supply net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testSupplyPermit2() public {
        uint256 assets = 100e18;
        deal(address(loanToken), user, assets);

        vm.startPrank(user);
        loanToken.approve(PERMIT2, assets);
        vm.stopPrank();

        TokenPermit memory permit = _permit2(address(loanToken), user, assets, 0, vm.getBlockTimestamp() + 1);
        vm.prank(user);
        blueBundles.supply(marketParams, assets, user, permit, 0, address(0));

        assertEq(loanToken.allowance(user, address(blueBundles)), 0);
        assertEq(loanToken.allowance(user, PERMIT2), 0);
        assertEq(morpho.expectedSupplyAssets(marketParams, user), assets);
    }

    /// WITHDRAW ///

    function testWithdraw(uint256 supplyAssets, uint256 withdrawAssets) public {
        supplyAssets = bound(supplyAssets, 1, 1e30);
        withdrawAssets = bound(withdrawAssets, 1, supplyAssets);
        deal(address(loanToken), user, supplyAssets);

        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAssets, 0, user, "");
        blueBundles.withdraw(marketParams, withdrawAssets, user, receiver, 0, address(0));
        vm.stopPrank();

        assertEq(morpho.expectedSupplyAssets(marketParams, user), supplyAssets - withdrawAssets, "remaining supply");
        assertEq(loanToken.balanceOf(receiver), withdrawAssets, "receiver");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    function testWithdrawWithReferralFee(uint256 supplyAssets, uint256 withdrawAssets, uint256 referralFeePct)
        public
    {
        supplyAssets = bound(supplyAssets, 1, 1e30);
        withdrawAssets = bound(withdrawAssets, 1, supplyAssets);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        deal(address(loanToken), user, supplyAssets);

        uint256 expectedFee = withdrawAssets * referralFeePct / WAD;

        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAssets, 0, user, "");
        blueBundles.withdraw(marketParams, withdrawAssets, user, receiver, referralFeePct, referrer);
        vm.stopPrank();

        assertEq(loanToken.balanceOf(receiver), withdrawAssets - expectedFee, "receiver net");
        assertEq(loanToken.balanceOf(referrer), expectedFee, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }
}
