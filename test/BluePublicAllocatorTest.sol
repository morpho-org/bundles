// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IMorpho, MarketParams} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";
import {ErrorsLib as BlueErrorsLib} from "../lib/morpho-blue/src/libraries/ErrorsLib.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {WAD} from "../lib/midnight/src/libraries/ConstantsLib.sol";

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {MAX_MAX_RATE, WAD as VAULT_WAD} from "../lib/vault-v2/src/libraries/ConstantsLib.sol";
import {IMorphoMarketV1AdapterV2} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {
    IMorphoMarketV1AdapterV2Factory
} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";

import {BlueBundlesV1} from "../src/blue/BlueBundlesV1.sol";
import {IBlueBundlesV1, SignedAuthorization, PublicAllocations} from "../src/blue/interfaces/IBlueBundlesV1.sol";
import {TokenPermit} from "../src/libraries/TokenLib.sol";
import {WETHMock} from "./BlueBundlesTest.sol";
import {
    IBluePublicAllocator
} from "../lib/vault-v2/src/periphery/blue-public-allocator/interfaces/IBluePublicAllocator.sol";

/// @dev Covers the public-allocator paths of the three Blue entrypoints that consume market liquidity: borrowing
/// against fresh collateral, exiting a supply position, and migrating a borrow position.
contract BluePublicAllocatorTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LLTV_DEST = 0.9e18;
    uint256 internal constant LLTV_LIQUID = 0.95e18;

    uint64 internal constant PENALTY = 0.01e18;
    uint256 internal constant VAULT_ASSETS = 100e18;

    IMorpho internal morpho;
    IVaultV2 internal vault;
    IMorphoMarketV1AdapterV2 internal adapter;
    IBluePublicAllocator internal publicAllocator;
    BlueBundlesV1 internal blueBundles;

    ERC20Mock internal loanToken;
    WETHMock internal weth; // ERC20 collateral of every market.
    OracleMock internal oracle;

    /// @dev The market the bundle acts on, kept illiquid by the tests.
    MarketParams internal marketParams;
    /// @dev Migration destination, also kept illiquid.
    MarketParams internal destMarketParams;
    /// @dev Where the vault's allocation sits, used as the deallocation source of the reallocations.
    MarketParams internal liquidMarketParams;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal depositor = makeAddr("depositor");
    address internal borrower = makeAddr("borrower");
    address internal user = makeAddr("user");
    address internal referrer = makeAddr("referrer");

    function setUp() public {
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        loanToken = new ERC20Mock(18);
        weth = new WETHMock();
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        // IRM address(0) ⇒ zero borrow rate ⇒ exact, interest-free accounting.
        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(LLTV);
        morpho.enableLltv(LLTV_DEST);
        morpho.enableLltv(LLTV_LIQUID);
        vm.stopPrank();

        marketParams = MarketParams(address(loanToken), address(weth), address(oracle), address(0), LLTV);
        destMarketParams = MarketParams(address(loanToken), address(weth), address(oracle), address(0), LLTV_DEST);
        liquidMarketParams = MarketParams(address(loanToken), address(weth), address(oracle), address(0), LLTV_LIQUID);
        morpho.createMarket(marketParams);
        morpho.createMarket(destMarketParams);
        morpho.createMarket(liquidMarketParams);

        // Vault V2 + Morpho-Market-V1 adapter (deployed via factories compiled through test/imports/VaultImport.sol).
        IVaultV2Factory vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
        vault = IVaultV2(vaultFactory.createVaultV2(owner, address(loanToken), bytes32(0)));

        vm.prank(owner);
        vault.setCurator(curator);
        _submitAndExec(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));

        IMorphoMarketV1AdapterV2Factory adapterFactory = IMorphoMarketV1AdapterV2Factory(
            deployCode(
                "MorphoMarketV1AdapterV2Factory.sol:MorphoMarketV1AdapterV2Factory", abi.encode(morpho, address(0))
            )
        );
        adapter = IMorphoMarketV1AdapterV2(adapterFactory.createMorphoMarketV1AdapterV2(address(vault)));
        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));

        vm.prank(allocator);
        vault.setMaxRate(MAX_MAX_RATE);

        _increaseCaps(abi.encode("this", address(adapter)));
        _increaseCaps(abi.encode("collateralToken", address(weth)));
        _increaseCaps(abi.encode("this/marketParams", address(adapter), marketParams));
        _increaseCaps(abi.encode("this/marketParams", address(adapter), destMarketParams));
        _increaseCaps(abi.encode("this/marketParams", address(adapter), liquidMarketParams));

        // Deployed through deployCode so that its own compiler settings do not leak into this file's compilation unit.
        publicAllocator = IBluePublicAllocator(
            deployCode("BluePublicAllocator.sol:BluePublicAllocator", abi.encode(address(vaultFactory)))
        );
        _submitAndExec(abi.encodeCall(IVaultV2.setIsAllocator, (address(publicAllocator), true)));

        vm.startPrank(allocator);
        publicAllocator.setIsActiveAdapter(address(vault), address(adapter), true);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), marketParams, type(uint128).max);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), destMarketParams, type(uint128).max);
        publicAllocator.setCanPullFromMarket(address(vault), address(adapter), liquidMarketParams, true);
        publicAllocator.setCanPullFromIdle(address(vault), true);
        publicAllocator.setPenalty(address(vault), PENALTY);
        vm.stopPrank();

        blueBundles = new BlueBundlesV1(address(morpho), address(publicAllocator));
        assertEq(blueBundles.BLUE(), address(morpho));
        assertEq(blueBundles.PUBLIC_ALLOCATOR(), address(publicAllocator));

        vm.prank(user);
        morpho.setAuthorization(address(blueBundles), true);
    }

    /// HELPERS ///

    function _noPermit() internal pure returns (TokenPermit memory) {}

    function _noAuthSig() internal pure returns (SignedAuthorization memory) {}

    function _submitAndExec(bytes memory data) internal {
        vm.prank(curator);
        vault.submit(data);
        (bool success,) = address(vault).call(data);
        require(success, "exec failed");
    }

    function _increaseCaps(bytes memory idData) internal {
        _submitAndExec(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _submitAndExec(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, VAULT_WAD)));
    }

    /// @dev The id the vault (and the public allocator) keys the adapter's per-market allocation under.
    function _vaultBlueId(address adapter_, MarketParams memory mp) internal pure returns (bytes32) {
        return keccak256(abi.encode("this/marketParams", adapter_, mp));
    }

    function _allocation(MarketParams memory mp) internal view returns (uint256) {
        return vault.allocation(_vaultBlueId(address(adapter), mp));
    }

    function _penaltyAssets(uint256 assets) internal pure returns (uint256) {
        return (assets * PENALTY + WAD - 1) / WAD;
    }

    function _grossUpForPenalty(uint256 netAssets) internal pure returns (uint256) {
        return (netAssets * WAD + (WAD - PENALTY) - 1) / (WAD - PENALTY);
    }

    /// @dev Adds a second Morpho-Market-V1 adapter to the vault, able to source deallocations from the liquid market.
    /// @dev A fresh factory is needed because each factory deploys one adapter per vault at a deterministic address.
    function _addSecondAdapter() internal returns (address secondAdapter) {
        IMorphoMarketV1AdapterV2Factory secondFactory = IMorphoMarketV1AdapterV2Factory(
            deployCode(
                "MorphoMarketV1AdapterV2Factory.sol:MorphoMarketV1AdapterV2Factory", abi.encode(morpho, address(0))
            )
        );
        secondAdapter = secondFactory.createMorphoMarketV1AdapterV2(address(vault));

        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (secondAdapter)));
        _increaseCaps(abi.encode("this", secondAdapter));
        _increaseCaps(abi.encode("this/marketParams", secondAdapter, liquidMarketParams));

        vm.startPrank(allocator);
        publicAllocator.setIsActiveAdapter(address(vault), secondAdapter, true);
        publicAllocator.setCanPullFromMarket(address(vault), secondAdapter, liquidMarketParams, true);
        vm.stopPrank();
    }

    /// @dev Deposits VAULT_ASSETS into the vault and pushes `toAllocate` of them into the liquid market, so they can be
    /// deallocated from there; the rest stays idle in the vault.
    function _fundVault(uint256 toAllocate) internal {
        deal(address(loanToken), depositor, VAULT_ASSETS);
        vm.startPrank(depositor);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(VAULT_ASSETS, depositor);
        vm.stopPrank();

        if (toAllocate > 0) {
            vm.prank(allocator);
            vault.allocate(address(adapter), abi.encode(liquidMarketParams), toAllocate);
            assertEq(_allocation(liquidMarketParams), toAllocate, "liquid market allocation");
        }
    }

    function _fundWeth(address account, uint256 amount) internal {
        vm.deal(account, amount);
        vm.prank(account);
        weth.deposit{value: amount}();
    }

    /// @dev Gives `account` collateral on `mp` with ample headroom above the LLTV, then borrows `borrowAssets`.
    function _openBorrow(MarketParams memory mp, address account, uint256 borrowAssets) internal {
        uint256 collateral = 2 * borrowAssets;
        _fundWeth(account, collateral);
        vm.startPrank(account);
        weth.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(mp, collateral, account, "");
        morpho.borrow(mp, borrowAssets, 0, account, account);
        vm.stopPrank();
    }

    /// @dev Supplies `assets` to `mp` for `user` then borrows all of it out, leaving the market fully utilized.
    function _supplyThenDrain(MarketParams memory mp, uint256 assets) internal {
        deal(address(loanToken), user, assets);
        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(mp, assets, 0, user, "");
        vm.stopPrank();

        _openBorrow(mp, borrower, assets);
        assertEq(morpho.market(mp.id()).totalSupplyAssets, morpho.market(mp.id()).totalBorrowAssets, "fully utilized");
    }

    /// forge-lint: disable-start(unsafe-typecast) the tests' amounts are all far below type(uint128).max.
    function _reallocation(MarketParams memory source, uint256 assets)
        internal
        view
        returns (PublicAllocations[] memory list)
    {
        list = new PublicAllocations[](1);
        list[0] = PublicAllocations({
            vault: address(vault),
            adapter: address(adapter),
            marketParams: marketParams,
            fromIdle: false,
            sourceAdapter: address(adapter),
            sourceMarketParams: source,
            assets: uint128(assets),
            penalty: PENALTY
        });
    }

    function _idleReallocation(uint256 assets) internal view returns (PublicAllocations[] memory list) {
        list = new PublicAllocations[](1);
        list[0] = PublicAllocations({
            vault: address(vault),
            adapter: address(adapter),
            marketParams: marketParams,
            fromIdle: true,
            sourceAdapter: address(0),
            sourceMarketParams: MarketParams(address(0), address(0), address(0), address(0), 0),
            assets: uint128(assets),
            penalty: PENALTY
        });
    }

    /// forge-lint: disable-end(unsafe-typecast)

    /// WITHDRAW ///

    function testFlashLoanCallbackNotBlue() public {
        vm.expectRevert(IBlueBundlesV1.UnauthorizedCallback.selector);
        blueBundles.onMorphoFlashLoan(1, "");
    }

    /// @dev A fully utilized market cannot be exited without moving liquidity into it first.
    function testWithdrawIlliquidRevertsWithoutReallocation() public {
        uint256 assets = 10e18;
        _supplyThenDrain(marketParams, assets);

        vm.prank(user);
        vm.expectRevert(bytes(BlueErrorsLib.INSUFFICIENT_LIQUIDITY));
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), new PublicAllocations[](0), 0, address(0), block.timestamp
        );
    }

    /// @dev The reallocation moves the vault's allocation from the liquid market into the exited one, so the vault
    /// takes over the supply the user leaves behind.
    function testWithdrawIlliquidWithReallocation() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        uint256 penaltyAssets = _penaltyAssets(assets);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets - penaltyAssets, "user received assets net of penalty");
        assertEq(morpho.supplyShares(marketParams.id(), user), 0, "user supply position closed");
        assertEq(_allocation(marketParams), assets, "vault took over the market");
        assertEq(_allocation(liquidMarketParams), VAULT_ASSETS - assets, "liquid market allocation reduced");
        assertEq(loanToken.balanceOf(address(vault)), penaltyAssets, "penalty donated to vault");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler token residual");
    }

    /// @dev Only the penalty is flash loaned, so a source holding the full reallocation amount needs just the penalty
    /// in additional global Blue liquidity. Flash loaning the reallocation amount itself would make this call fail.
    function testReallocationOnlyFlashLoansPenalty() public {
        uint256 assets = 10e18;
        uint256 penaltyAssets = _penaltyAssets(assets);
        _fundVault(assets);
        _supplyThenDrain(marketParams, assets);
        deal(address(loanToken), address(morpho), assets + penaltyAssets);
        assertEq(loanToken.balanceOf(address(morpho)), assets + penaltyAssets, "source plus penalty is liquid");

        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets - penaltyAssets, "user received assets net of penalty");
    }

    /// @dev The vault's idle assets are an equally valid liquidity source.
    function testWithdrawIlliquidWithAllocateFromIdle() public {
        uint256 assets = 10e18;
        _fundVault(0);
        _supplyThenDrain(marketParams, assets);

        // Idle vault assets are not on Blue, so seed only the penalty required by the flash loan.
        uint256 penaltyAssets = _penaltyAssets(assets);
        deal(address(loanToken), depositor, penaltyAssets);
        vm.startPrank(depositor);
        loanToken.approve(address(morpho), penaltyAssets);
        morpho.supply(destMarketParams, penaltyAssets, 0, depositor, "");
        vm.stopPrank();

        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), _idleReallocation(assets), 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets - _penaltyAssets(assets), "user received assets net of penalty");
        assertEq(_allocation(marketParams), assets, "vault took over the market");
    }

    /// @dev The deallocation source and the allocation destination can live on two different adapters of the vault.
    function testWithdrawIlliquidWithCrossAdapterReallocation() public {
        uint256 assets = 10e18;
        address sourceAdapter = _addSecondAdapter();

        // The whole deposit sits in the liquid market through the second adapter, so only that adapter can source it.
        _fundVault(0);
        vm.prank(allocator);
        vault.allocate(sourceAdapter, abi.encode(liquidMarketParams), VAULT_ASSETS);

        _supplyThenDrain(marketParams, assets);

        PublicAllocations[] memory reallocations = _reallocation(liquidMarketParams, assets);
        reallocations[0].sourceAdapter = sourceAdapter;

        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets - _penaltyAssets(assets), "user received assets net of penalty");
        assertEq(_allocation(marketParams), assets, "first adapter took over the market");
        assertEq(
            vault.allocation(_vaultBlueId(sourceAdapter, liquidMarketParams)),
            VAULT_ASSETS - assets,
            "second adapter's allocation reduced"
        );
    }

    /// @dev Liquidity can be sourced from several markets in one bundle, each charging its own penalty.
    function testWithdrawIlliquidWithTwoReallocations() public {
        uint256 assets = 10e18;
        // Half allocated to the liquid market, half left idle, so both sources can serve part of the withdrawal.
        _fundVault(VAULT_ASSETS / 2);
        _supplyThenDrain(marketParams, assets);

        PublicAllocations[] memory reallocations = new PublicAllocations[](2);
        reallocations[0] = _reallocation(liquidMarketParams, assets / 2)[0];
        reallocations[1] = _idleReallocation(assets - assets / 2)[0];

        uint256 penaltyAssets = 2 * _penaltyAssets(assets / 2);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );
        assertEq(loanToken.balanceOf(user), assets - penaltyAssets, "user received assets net of penalties");
        assertEq(_allocation(marketParams), assets, "vault took over the market");
        assertEq(
            loanToken.balanceOf(address(vault)),
            VAULT_ASSETS / 2 - (assets - assets / 2) + penaltyAssets,
            "idle assets plus both donated penalties"
        );
    }

    /// @dev Checks the doc formula: to receive targetNet when withdrawing by assets, pass
    /// withdrawAssets = P + floor(targetNet * WAD / (WAD - referralFeePct)), where P is the aggregate penalty of the
    /// reallocations. The penalty is deducted before the fee, so it cancels out of the net exactly.
    function testWithdrawTargetNetWithPenalty(uint256 targetNet, uint256 referralFeePct) public {
        referralFeePct = bound(referralFeePct, 1, WAD - 1);
        // Caps the gross-up so that the reallocation, sized at twice the gross-up, stays well within the vault's
        // deposit: it is deallocated from the liquid market while the penalty is flash loaned out of Blue.
        uint256 maxGrossAssets = VAULT_ASSETS / 4;
        targetNet = bound(targetNet, 1, maxGrossAssets * (WAD - referralFeePct) / WAD);

        uint256 grossAssets = targetNet * WAD / (WAD - referralFeePct);
        // The reallocation amount is chosen independently of the withdrawal. PENALTY is far below WAD / 2, so the
        // penalty is at most the gross-up and the reallocated liquidity always covers penalty plus gross-up.
        uint256 reallocationAssets = 2 * grossAssets;
        uint256 penaltyAssets = _penaltyAssets(reallocationAssets);
        uint256 withdrawAssets = penaltyAssets + grossAssets;

        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, withdrawAssets);

        deal(address(loanToken), user, 0);

        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            withdrawAssets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, reallocationAssets),
            referralFeePct,
            referrer,
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), targetNet, "net equals target");
        assertEq(loanToken.balanceOf(referrer), grossAssets - targetNet, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// SUPPLY COLLATERAL AND BORROW ///

    /// @dev An empty market can be borrowed from once the vault has been pushed into it.
    function testSupplyCollateralAndBorrowIlliquidWithReallocation() public {
        uint256 borrowAssets = 10e18;
        uint256 collateral = 2 * borrowAssets;
        _fundVault(VAULT_ASSETS);

        _fundWeth(user, collateral);
        vm.startPrank(user);
        weth.approve(address(blueBundles), type(uint256).max);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams,
            collateral,
            borrowAssets,
            0,
            WAD,
            _noPermit(),
            _noAuthSig(),
            _reallocation(liquidMarketParams, borrowAssets),
            0,
            address(0),
            block.timestamp
        );
        vm.stopPrank();

        assertEq(loanToken.balanceOf(user), borrowAssets - _penaltyAssets(borrowAssets), "user borrowed net of penalty");
        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(_allocation(marketParams), borrowAssets, "vault funded the borrow");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler token residual");
    }

    /// @dev Native collateral is wrapped before being supplied, even when a reallocation also flash loans a penalty.
    function testSupplyCollateralAndBorrowWrapNativeWithReallocation() public {
        uint256 borrowAssets = 10e18;
        uint256 collateral = 2 * borrowAssets;
        _fundVault(VAULT_ASSETS);

        vm.deal(user, collateral);
        vm.prank(user);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow{value: collateral}(
            marketParams,
            collateral,
            borrowAssets,
            0,
            WAD,
            _noPermit(),
            _noAuthSig(),
            _reallocation(liquidMarketParams, borrowAssets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), borrowAssets - _penaltyAssets(borrowAssets), "user borrowed net of penalty");
        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(_allocation(marketParams), borrowAssets, "vault funded the borrow");
        assertEq(user.balance, 0, "user native residual");
        assertEq(address(blueBundles).balance, 0, "bundler native residual");
        assertEq(weth.balanceOf(address(blueBundles)), 0, "bundler wrapped residual");
    }

    /// @dev Checks the doc formula: to receive targetNet, pass
    /// borrowAssets = P + floor(targetNet * WAD / (WAD - referralFeePct)), where P is the aggregate penalty of the
    /// reallocations. The penalty is deducted before the fee, so it cancels out of the net exactly.
    function testSupplyCollateralAndBorrowTargetNetWithPenalty(uint256 targetNet, uint256 referralFeePct) public {
        referralFeePct = bound(referralFeePct, 1, WAD - 1);
        // Caps the gross-up so that the reallocation, sized at twice the gross-up, stays well within the vault's
        // deposit: it is deallocated from the liquid market while the penalty is flash loaned out of Blue.
        uint256 maxGrossAssets = VAULT_ASSETS / 4;
        targetNet = bound(targetNet, 1, maxGrossAssets * (WAD - referralFeePct) / WAD);

        uint256 grossAssets = targetNet * WAD / (WAD - referralFeePct);
        // The reallocation amount is chosen independently of the borrow. PENALTY is far below WAD / 2, so the penalty
        // is at most the gross-up and the reallocated liquidity always covers penalty plus gross-up.
        uint256 reallocationAssets = 2 * grossAssets;
        uint256 penaltyAssets = _penaltyAssets(reallocationAssets);
        uint256 borrowAssets = penaltyAssets + grossAssets;
        uint256 collateral = 2 * borrowAssets;

        _fundVault(VAULT_ASSETS);
        _fundWeth(user, collateral);

        assertEq(loanToken.balanceOf(user), 0, "user starts with no loan token");

        vm.startPrank(user);
        weth.approve(address(blueBundles), type(uint256).max);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams,
            collateral,
            borrowAssets,
            0,
            WAD,
            _noPermit(),
            _noAuthSig(),
            _reallocation(liquidMarketParams, reallocationAssets),
            referralFeePct,
            referrer,
            block.timestamp
        );
        vm.stopPrank();

        assertEq(loanToken.balanceOf(user), targetNet, "net equals target");
        assertEq(loanToken.balanceOf(referrer), grossAssets - targetNet, "referrer fee");
        assertEq(loanToken.balanceOf(address(blueBundles)), 0, "bundler residual");
    }

    /// MIGRATE BORROW POSITION ///

    /// @dev An illiquid destination market can still be migrated into.
    function testMigrateBorrowPositionIlliquidDestWithReallocation() public {
        uint256 borrowAssets = 10e18;
        uint256 reallocationAssets = _grossUpForPenalty(borrowAssets);
        _fundVault(VAULT_ASSETS);

        // The source market is liquid so the user could borrow from it; the destination is empty.
        deal(address(loanToken), depositor, borrowAssets);
        vm.startPrank(depositor);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, borrowAssets, 0, depositor, "");
        vm.stopPrank();

        _openBorrow(marketParams, user, borrowAssets);
        uint256 collateral = morpho.position(marketParams.id(), user).collateral;

        PublicAllocations[] memory reallocations = _reallocation(liquidMarketParams, reallocationAssets);
        reallocations[0].marketParams = destMarketParams;

        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition(
            marketParams,
            destMarketParams,
            type(uint256).max,
            0,
            LLTV_DEST,
            _noAuthSig(),
            reallocations,
            0,
            address(0),
            block.timestamp
        );

        assertEq(morpho.position(marketParams.id(), user).borrowShares, 0, "source debt closed");
        assertEq(morpho.position(marketParams.id(), user).collateral, 0, "source collateral moved");
        assertEq(morpho.position(destMarketParams.id(), user).collateral, collateral, "destination collateral");
        assertEq(
            morpho.expectedBorrowAssets(destMarketParams, user),
            borrowAssets + _penaltyAssets(reallocationAssets),
            "destination debt includes penalty"
        );
        assertEq(_allocation(destMarketParams), reallocationAssets, "vault funded debt and penalty");
    }

    /// PENALTY SLIPPAGE ///

    /// @dev An allocator raising the penalty rate above the one passed makes the public allocator revert the bundle.
    function testWithdrawPenaltyRaisedReverts() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setPenalty(address(vault), 2 * PENALTY);

        vm.prank(user);
        vm.expectRevert(IBluePublicAllocator.IncorrectPenalty.selector);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );
    }

    /// @dev The public allocator's penalty check is an exact match: even a favorable rate change reverts the bundle.
    function testWithdrawPenaltyLoweredReverts() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setPenalty(address(vault), PENALTY / 2);

        vm.prank(user);
        vm.expectRevert(IBluePublicAllocator.IncorrectPenalty.selector);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );
    }

    /// @dev With no penalty set, the entrypoints stay usable and skip the flash loan entirely.
    function testWithdrawZeroPenalty() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setPenalty(address(vault), 0);

        PublicAllocations[] memory reallocations = _reallocation(liquidMarketParams, assets);
        reallocations[0].penalty = 0;

        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
    }

    /// REALLOCATION FAILURES ///

    /// @dev A reallocation the public allocator refuses fails the whole bundle.
    function testWithdrawCannotDeallocateBubbles() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setCanPullFromMarket(address(vault), address(adapter), liquidMarketParams, false);

        vm.prank(user);
        vm.expectRevert(IBluePublicAllocator.CannotPullFromMarket.selector);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );
    }

    /// @dev The public allocator only serves adapters the vault's allocators activated on it.
    function testWithdrawInactiveAdapterBubbles() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setIsActiveAdapter(address(vault), address(adapter), false);

        vm.prank(user);
        vm.expectRevert(IBluePublicAllocator.InactiveAdapter.selector);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );
    }

    /// @dev An allocator cutting the destination's absolute cap to zero blocks the public inflow.
    function testWithdrawZeroAbsoluteCapBubbles() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), marketParams, 0);

        vm.prank(user);
        vm.expectRevert(IBluePublicAllocator.ZeroAbsoluteCap.selector);
        blueBundles.blueBundlesV1Withdraw(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );
    }

    /// @dev Each reallocation independently selects its destination: market-sourced and idle-sourced entries can target
    /// different markets sharing the bundle's loan token, neither of which is the market the bundle acts on.
    function testReallocationDestinationsOtherMarkets() public {
        uint256 borrowAssets = 10e18;
        uint256 collateral = 2 * borrowAssets;
        uint256 marketSourcedAssets = 4e18;
        uint256 idleSourcedAssets = 6e18;
        uint256 penaltyAssets = _penaltyAssets(marketSourcedAssets) + _penaltyAssets(idleSourcedAssets);
        _fundVault(VAULT_ASSETS / 2);

        // The bundle's market is already liquid, so neither reallocation needs to target it.
        deal(address(loanToken), depositor, borrowAssets);
        vm.startPrank(depositor);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, borrowAssets, 0, depositor, "");
        vm.stopPrank();

        vm.prank(allocator);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), liquidMarketParams, type(uint128).max);

        PublicAllocations[] memory reallocations = new PublicAllocations[](2);
        reallocations[0] = _reallocation(liquidMarketParams, marketSourcedAssets)[0];
        reallocations[0].marketParams = destMarketParams;
        reallocations[1] = _idleReallocation(idleSourcedAssets)[0];
        reallocations[1].marketParams = liquidMarketParams;

        _fundWeth(user, collateral);
        vm.startPrank(user);
        weth.approve(address(blueBundles), type(uint256).max);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow(
            marketParams,
            collateral,
            borrowAssets,
            0,
            WAD,
            _noPermit(),
            _noAuthSig(),
            reallocations,
            0,
            address(0),
            block.timestamp
        );
        vm.stopPrank();

        assertEq(loanToken.balanceOf(user), borrowAssets - penaltyAssets, "user borrowed net of penalties");
        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(_allocation(destMarketParams), marketSourcedAssets, "market-sourced destination");
        assertEq(
            _allocation(liquidMarketParams),
            VAULT_ASSETS / 2 - marketSourcedAssets + idleSourcedAssets,
            "idle-sourced destination"
        );
        assertEq(_allocation(marketParams), 0, "bundle market not funded by the vault");
    }

    /// @dev A reallocation destination whose loan token differs from the bundle's is rejected: penalties are paid in the bundle's loan token.
    function testReallocationDestinationLoanTokenMismatchReverts() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        PublicAllocations[] memory reallocations = _reallocation(liquidMarketParams, assets);
        reallocations[0].marketParams.loanToken = address(weth);

        vm.prank(user);
        vm.expectRevert(IBlueBundlesV1.InconsistentTokens.selector);
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );
    }
}
