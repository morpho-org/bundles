// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultIkrBundlesV1} from "../src/vault-ikr/VaultIkrBundlesV1.sol";
import {IVaultIkrBundlesV1} from "../src/vault-ikr/interfaces/IVaultIkrBundlesV1.sol";

// Import from metamorpho/lib/morpho-blue to avoid duplicate types.
import {IMorpho, MarketParams, Id} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/metamorpho/lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/metamorpho/lib/morpho-blue/src/mocks/OracleMock.sol";

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {MAX_MAX_RATE, WAD} from "../lib/vault-v2/src/libraries/ConstantsLib.sol";
import {IMorphoMarketV1AdapterV2} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {
    IMorphoMarketV1AdapterV2Factory
} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";

contract VaultV2IkrBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV_1 = 0.8e18;
    uint256 internal constant LLTV_2 = 0.9e18;
    uint256 internal constant PENALTY = 0.01e18;

    uint256 internal constant MIN_ASSETS = 2;
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    IVaultV2 internal vault;
    IMorphoMarketV1AdapterV2 internal adapter;
    VaultIkrBundlesV1 internal vaultBundles;

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

        vaultBundles = new VaultIkrBundlesV1(address(morpho));
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

    /// @dev Wraps a single market into the singleton list expected by vaultBundlesV1ForceWithdrawIlliquidVaultV2.
    function _singleton(MarketParams memory marketParams_) internal pure returns (MarketParams[] memory list) {
        list = new MarketParams[](1);
        list[0] = marketParams_;
    }

    /// @dev Simulates accrued yield on a market via a storage cheat so its (and its suppliers') assets/shares ratio
    /// is non-round, exercising real rounding. Funds Morpho with the extra assets so they remain withdrawable.
    function _accrueYield(MarketParams memory mp, uint256 yield) internal {
        if (yield == 0) return;
        bytes32 slot = MorphoStorageLib.marketTotalSupplyAssetsAndSharesSlot(mp.id());
        uint256 packed = uint256(vm.load(address(morpho), slot));
        // forge-lint:disable-next-line(unsafe-typecast) truncating on purpose.
        uint256 totalSupplyAssets = uint128(packed);
        uint256 totalSupplyShares = packed >> 128;
        vm.store(address(morpho), slot, bytes32((totalSupplyShares << 128) | (totalSupplyAssets + yield)));
        deal(address(loanToken), address(morpho), loanToken.balanceOf(address(morpho)) + yield);
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

        // The sender (this contract) authorizes the bundler to move its vault shares.
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

        // The sender (this contract) authorizes the bundler to move its vault shares.
        vault.approve(address(vaultBundles), type(uint256).max);

        // Reset so the final balance measures exactly what is withdrawn from the vault.
        deal(address(loanToken), address(this), 0);
    }

    /// @dev Like _setUpIlliquid but allocates across two adapter markets (`marketParams` and `otherMarket`), both
    /// borrowed out and given non-round share/asset ratios. A third market supplies Morpho's global loan liquidity.
    function _setUpIlliquidTwoMarkets(uint256 assets1, uint256 assets2) internal {
        // Allow the adapter to allocate into otherMarket too (the `this` and collateral caps are already shared).
        _increaseCaps(abi.encode("this/marketParams", address(adapter), otherMarket));

        uint256 total = assets1 + assets2;
        deal(address(loanToken), address(this), total);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(total, address(this));

        vm.startPrank(allocator);
        vault.allocate(address(adapter), abi.encode(marketParams), assets1);
        vault.allocate(address(adapter), abi.encode(otherMarket), assets2);
        vm.stopPrank();

        // Borrow everything out of both markets ⇒ both illiquid.
        deal(address(collateralToken), borrower, 4 * total);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, 2 * assets1, borrower, "");
        morpho.borrow(marketParams, assets1, 0, borrower, borrower);
        morpho.supplyCollateral(otherMarket, 2 * assets2, borrower, "");
        morpho.borrow(otherMarket, assets2, 0, borrower, borrower);
        vm.stopPrank();

        // Non-round share/asset ratios on both markets so the redemption math exercises real rounding.
        _accrueYield(marketParams, assets1 / 3);
        _accrueYield(otherMarket, assets2 / 7);

        // Morpho global liquidity from a third market sharing the loan token (never borrowed).
        vm.prank(owner);
        morpho.enableLltv(0.5e18);
        MarketParams memory liquidityMarket =
            MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), 0.5e18);
        morpho.createMarket(liquidityMarket);
        deal(address(loanToken), liquidityProvider, 2 * total);
        vm.startPrank(liquidityProvider);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(liquidityMarket, 2 * total, 0, liquidityProvider, "");
        vm.stopPrank();

        vault.approve(address(vaultBundles), type(uint256).max);
        deal(address(loanToken), address(this), 0);
    }

    /// AUTHORIZATION & VALIDATION ///

    function testForceWithdrawAdapterNotPartOfVault() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultIkrBundlesV1.AdapterNotPartOfVault.selector);
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), makeAddr("notAdapter"), _singleton(marketParams), assets, block.timestamp
        );
    }

    /// @dev A market not allocated through the adapter (supplyShares == 0) is skipped; with no further market in the
    /// list to cover the requested assets, the loop runs past the list and reverts.
    function testForceWithdrawMarketWithoutAdapterShares() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        // otherMarket was never allocated through the adapter ⇒ supplyShares == 0.
        vm.expectRevert();
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), _singleton(otherMarket), assets, block.timestamp
        );
    }

    /// @dev The single market is allocated through the adapter but holds less than the requested amount; with no
    /// further market in the list to cover the remainder, the loop runs past the list and reverts.
    function testForceWithdrawNotEnoughAvailable() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        // Requesting 2x the deposited assets ⇒ assetsToDeallocate ≈ 1.98x what the single market holds.
        uint256 tooMuch = 2 * assets;
        assertGt(optimalDeallocateAssets(tooMuch), assets, "precondition");

        vm.expectRevert();
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), _singleton(marketParams), tooMuch, block.timestamp
        );
    }

    function testOnMorphoSupplyOnlyBlue() public {
        vm.expectRevert(IVaultIkrBundlesV1.Unauthorized.selector);
        vaultBundles.onMorphoSupply(1, "");
    }

    /// @dev assets so small that deallocatedAssets rounds to 0 ⇒ the deallocation loop never runs (no-op).
    function testForceWithdrawIlliquidTooSmallNoOp() public {
        uint256 assets = 1;
        _setUpIlliquid(assets);
        assertEq(optimalDeallocateAssets(assets), 0, "precondition");

        uint256 sharesBefore = vault.balanceOf(address(this));
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, block.timestamp
        );

        assertEq(vault.balanceOf(address(this)), sharesBefore, "vault balance unchanged");
        assertEq(morpho.expectedSupplyAssets(marketParams, address(this)), 0, "no supply position");
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

        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, block.timestamp
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

    /// @dev When the first market does not hold enough, the loop drains it and pulls the remainder from the next
    /// market in the list, leaving the sender an in-kind position in both.
    function testForceWithdrawIlliquidMultipleMarkets() public {
        uint256 assets1 = 60e18;
        uint256 assets2 = 60e18;
        _setUpIlliquidTwoMarkets(assets1, assets2);
        _setSharePrice(1.07e18); // non-round vault share/asset ratio

        MarketParams[] memory list = new MarketParams[](2);
        list[0] = marketParams;
        list[1] = otherMarket;

        // The adapter's (yield-inflated) position in the first market.
        uint256 available1 = morpho.expectedSupplyAssets(marketParams, address(adapter));

        // Deallocate more than the first market holds, so the remainder must come from the second.
        uint256 forceWithdrawAssets = 90e18;
        uint256 deallocate = optimalDeallocateAssets(forceWithdrawAssets);
        assertGt(deallocate, available1, "precondition: one market is not enough");

        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), list, forceWithdrawAssets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        // First market drained, remainder pulled from the second.
        assertApproxEqAbs(
            morpho.expectedSupplyAssets(marketParams, address(this)), available1, 3, "first market position"
        );
        assertApproxEqAbs(
            morpho.expectedSupplyAssets(otherMarket, address(this)),
            deallocate - available1,
            3,
            "second market position"
        );
    }

    function testForceWithdrawSkipsEmptyAdapterMarket() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);
        assertEq(adapter.supplyShares(Id.unwrap(otherMarket.id())), 0, "otherMarket empty in adapter");

        MarketParams[] memory list = new MarketParams[](2);
        list[0] = otherMarket;
        list[1] = marketParams;

        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), list, assets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertEq(
            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
        );
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawIlliquidDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultIkrBundlesV1.DeadlinePassed.selector);
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, block.timestamp - 1
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

    /// @dev Passing assets = previewRedeem(balanceOf(sender) - 2) never reverts and
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

        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV2(
            address(vault), address(adapter), _singleton(marketParams), amount, block.timestamp
        );

        assertLe(
            vault.previewRedeem(vault.balanceOf(address(this))), 2 * priceWad / WAD + 2, "more than 2 shares worth left"
        );
    }

    /// LIQUID WITHDRAWAL ///

    function testForceWithdrawLiquidAdapterNotPartOfVault() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert(IVaultIkrBundlesV1.AdapterNotPartOfVault.selector);
        vaultBundles.vaultBundlesV1ForceWithdrawLiquidVaultV2(
            address(vault), makeAddr("notAdapter"), marketParams, assets, block.timestamp
        );
    }

    function testForceWithdrawLiquidMarketWithoutAdapterShares() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        // otherMarket was never allocated through the adapter ⇒ supplyShares == 0.
        vm.expectRevert("panic: arithmetic underflow or overflow (0x11)");
        vaultBundles.vaultBundlesV1ForceWithdrawLiquidVaultV2(
            address(vault), address(adapter), otherMarket, assets, block.timestamp
        );
    }

    function testForceWithdrawLiquid(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpLiquid(assets);

        vaultBundles.vaultBundlesV1ForceWithdrawLiquidVaultV2(
            address(vault), address(adapter), marketParams, assets, block.timestamp
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

        vm.expectRevert(IVaultIkrBundlesV1.DeadlinePassed.selector);
        vaultBundles.vaultBundlesV1ForceWithdrawLiquidVaultV2(
            address(vault), address(adapter), marketParams, assets, block.timestamp - 1
        );
    }
}
