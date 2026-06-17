// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IMorpho, MarketParams, Id} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/morpho-blue/src/mocks/OracleMock.sol";
import {WAD} from "../lib/midnight/src/libraries/ConstantsLib.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultBundles} from "../src/vault/VaultBundles.sol";
import {IVaultBundles} from "../src/vault/IVaultBundles.sol";

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {
    IMorphoMarketV1AdapterV2Factory
} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";

contract VaultBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV_1 = 0.8e18;
    uint256 internal constant LLTV_2 = 0.9e18;
    uint256 internal constant PENALTY = 0.01e18;
    uint256 internal constant MAX_MAX_RATE = 200e16 / uint256(365 days);

    uint256 internal constant MIN_ASSETS = 2; // assets == 1 ⇒ deallocatedAssets == 0 (see testTooSmallReverts).
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    IVaultV2 internal vault;
    IMorphoMarketV1AdapterV2 internal adapter;
    VaultBundles internal vaultBundles;

    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;

    MarketParams internal marketParams; // vault market (made illiquid)
    MarketParams internal otherMarket; // same loan token, supplies Morpho's global liquidity

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal borrower = makeAddr("borrower");
    address internal liquidityProvider = makeAddr("liquidityProvider");

    function setUp() public {
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        loanToken = new ERC20Mock(18);
        collateralToken = new ERC20Mock(18);
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        // IRM as address(0) to have zero borrow rate.
        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(LLTV_1);
        morpho.enableLltv(LLTV_2);
        vm.stopPrank();

        marketParams = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), LLTV_1);
        otherMarket = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), LLTV_2);
        morpho.createMarket(marketParams);
        morpho.createMarket(otherMarket);

        // VaultV2 + Morpho-Market-V1 adapter (deployed via factories compiled through test/imports/VaultImport.sol).
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

        // Caps for the adapter's three ids (adapter, collateral token, adapter+marketParams).
        _increaseCaps(abi.encode("this", address(adapter)));
        _increaseCaps(abi.encode("collateralToken", marketParams.collateralToken));
        _increaseCaps(abi.encode("this/marketParams", address(adapter), marketParams));

        _submitAndExec(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), PENALTY)));

        vaultBundles = new VaultBundles(address(morpho));
        assertEq(vaultBundles.BLUE(), address(morpho));
    }

    /// HELPERS ///

    function _submitAndExec(bytes memory data) internal {
        vm.prank(curator);
        vault.submit(data);
        (bool success,) = address(vault).call(data);
        require(success, "exec failed");
    }

    function _increaseCaps(bytes memory idData) internal {
        _submitAndExec(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _submitAndExec(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, WAD)));
    }

    function optimalDeallocateAssets(uint256 assets) internal pure returns (uint256) {
        return assets * WAD / (WAD + PENALTY);
    }

    /// @dev Deposits `assets` into the vault for address(this), allocates them to the Morpho market, then borrows all
    /// of them out so the market is fully illiquid. A second market is used so the Morpho contract still holds
    /// enough global loan token liquidity.
    function _setUpIlliquid(uint256 assets) internal {
        deal(address(loanToken), address(this), assets);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(marketParams), assets);
        assertGt(adapter.supplyShares(Id.unwrap(marketParams.id())), 0, "allocation");

        // Borrow everything out of the vault's market ⇒ illiquid.
        deal(address(collateralToken), borrower, 2 * assets);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, 2 * assets, borrower, "");
        morpho.borrow(marketParams, assets, 0, borrower, borrower);
        vm.stopPrank();

        // Morpho global liquidity (from another market sharing the loan token).
        deal(address(loanToken), liquidityProvider, 2 * assets);
        vm.startPrank(liquidityProvider);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(otherMarket, 2 * assets, 0, liquidityProvider, "");
        vm.stopPrank();

        // onBehalf (this contract) authorizes the bundler to move its vault shares.
        vault.approve(address(vaultBundles), type(uint256).max);

        // Sanity: the depositor cannot redeem normally, yet still "owns" ~assets worth of shares.
        deal(address(loanToken), address(this), 0);
    }

    /// @dev Deposits `assets` into the vault for address(this) and allocates them to the Morpho market. Nothing is
    /// borrowed out, so the market stays liquid and the assets can be deallocated directly from it.
    function _setUpLiquid(uint256 assets) internal {
        deal(address(loanToken), address(this), assets);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(marketParams), assets);
        assertGt(adapter.supplyShares(Id.unwrap(marketParams.id())), 0, "allocation");

        // onBehalf (this contract) authorizes the bundler to move its vault shares.
        vault.approve(address(vaultBundles), type(uint256).max);

        // Reset so the final balance measures exactly what is withdrawn from the vault.
        deal(address(loanToken), address(this), 0);
    }

    /// AUTHORIZATION & VALIDATION ///

    function testForceWithdrawUnauthorized() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IVaultBundles.Unauthorized.selector);
        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp
        );
    }

    function testForceWithdrawAdapterNotPartOfVault() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultBundles.AdapterNotPartOfVault.selector);
        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), makeAddr("notAdapter"), marketParams, address(this), assets, block.timestamp
        );
    }

    function testForceWithdrawMarketNotPartOfAdapter() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        // otherMarket was never allocated through the adapter ⇒ supplyShares == 0.
        vm.expectRevert(IVaultBundles.MarketNotPartOfAdapter.selector);
        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), otherMarket, address(this), assets, block.timestamp
        );
    }

    function testOnMorphoSupplyOnlyBlue() public {
        vm.expectRevert(IVaultBundles.Unauthorized.selector);
        vaultBundles.onMorphoSupply(1, "");
    }

    /// @dev assets so small that deallocatedAssets rounds to 0 ⇒ Morpho's supply(0) reverts.
    function testForceWithdrawIlliquidTooSmallReverts() public {
        uint256 assets = 1;
        _setUpIlliquid(assets);
        assertEq(optimalDeallocateAssets(assets), 0, "precondition");

        vm.expectRevert();
        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp
        );
    }

    /// IN-KIND REDEMPTION ///

    /// @dev Mirrors the reference IkrTest: a normal withdraw from a fully illiquid vault reverts.
    function testCantWithdrawWhenIlliquid(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpIlliquid(assets);

        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(adapter), abi.encode(marketParams));

        vm.expectRevert();
        vault.withdraw(assets, address(this), address(this));
    }

    function testForceWithdrawIlliquid(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpIlliquid(assets);
        vm.assume(optimalDeallocateAssets(assets) > 0);

        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
        assertEq(loanToken.balanceOf(address(adapter)), 0, "adapter loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertEq(
            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
        );
        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawIlliquidDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultBundles.DeadlinePassed.selector);
        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp - 1
        );
    }

    /// @dev Set a share price != 1 while keeping the vault balance consistent with the total supply.
    function _setSharePrice(uint256 priceWad) internal {
        uint256 newShares = vault.totalAssets() * WAD / priceWad;
        vm.store(address(vault), bytes32(uint256(11)), bytes32(newShares));
        vm.store(address(vault), keccak256(abi.encode(address(this), uint256(12))), bytes32(newShares));
        assertEq(vault.totalSupply(), newShares, "totalSupply slot");
        assertEq(vault.balanceOf(address(this)), newShares, "balanceOf slot");
    }

    /// @dev Passing assets = previewRedeem(balanceOf(onBehalf) - 2) never reverts and
    /// sweeps all but a few assets' worth of the position (on top of the 2 shares). The
    /// 2 shares margin keeps the two ceil-rounded withdrawals from over-burning.
    function testForceWithdrawSafeExit(uint256 assets, uint256 priceWad) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        priceWad = bound(priceWad, WAD / 10, 10 * WAD);
        _setUpIlliquid(assets);
        _setSharePrice(priceWad);

        uint256 sharesBefore = vault.balanceOf(address(this));
        vm.assume(sharesBefore > 2);
        uint256 amount = vault.previewRedeem(sharesBefore - 2);
        vm.assume(optimalDeallocateAssets(amount) > 0);

        vaultBundles.forceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), amount, block.timestamp
        );

        assertLe(
            vault.previewRedeem(vault.balanceOf(address(this))), 2 * priceWad / WAD + 2, "more than 2 shares worth left"
        );
    }

    /// LIQUID WITHDRAWAL ///

    function testForceWithdrawLiquidUnauthorized() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IVaultBundles.Unauthorized.selector);
        vaultBundles.forceWithdrawLiquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp
        );
    }

    function testForceWithdrawLiquidAdapterNotPartOfVault() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert(IVaultBundles.AdapterNotPartOfVault.selector);
        vaultBundles.forceWithdrawLiquidVaultV2(
            address(vault), makeAddr("notAdapter"), marketParams, address(this), assets, block.timestamp
        );
    }

    function testForceWithdrawLiquidMarketNotPartOfAdapter() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        // otherMarket was never allocated through the adapter ⇒ supplyShares == 0.
        vm.expectRevert(IVaultBundles.MarketNotPartOfAdapter.selector);
        vaultBundles.forceWithdrawLiquidVaultV2(
            address(vault), address(adapter), otherMarket, address(this), assets, block.timestamp
        );
    }

    function testForceWithdrawLiquid(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpLiquid(assets);
        vm.assume(optimalDeallocateAssets(assets) > 0);

        vaultBundles.forceWithdrawLiquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
        assertEq(loanToken.balanceOf(address(adapter)), 0, "adapter loan token balance");
        // The user leaves the vault with the deallocated assets.
        assertEq(loanToken.balanceOf(address(this)), optimalDeallocateAssets(assets), "user loan token balance");
        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawLiquidDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert(IVaultBundles.DeadlinePassed.selector);
        vaultBundles.forceWithdrawLiquidVaultV2(
            address(vault), address(adapter), marketParams, address(this), assets, block.timestamp - 1
        );
    }
}
