// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultIkrBundlesV1} from "../src/vault/VaultIkrBundlesV1.sol";
import {IVaultIkrBundlesV1} from "../src/vault/interfaces/IVaultIkrBundlesV1.sol";

// Use the vault's own (nested) morpho-blue everywhere, so Morpho, MetaMorpho and this test share a single market type.
import {IMetaMorpho} from "../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IMorpho, MarketParams, Id} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/metamorpho/lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/metamorpho/lib/morpho-blue/src/mocks/OracleMock.sol";

// The bundler is compiled against the top-level morpho-blue (a different commit), so its MarketParams is a distinct
// type: alias it just for the vaultBundlesV1ForceWithdrawIlliquidVaultV1 argument and convert at that single boundary.
import {MarketParams as BundlerMarketParams} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";

contract VaultV1IkrBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV_1 = 0.8e18;
    uint256 internal constant LLTV_2 = 0.9e18;

    uint256 internal constant MIN_ASSETS = 2;
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    IMetaMorpho internal vault;
    VaultIkrBundlesV1 internal vaultBundles;

    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;

    MarketParams internal marketParams; // vault market (made illiquid)
    MarketParams internal otherMarket; // same loan token, supplies Morpho's global liquidity

    address internal owner = makeAddr("owner");
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

        vaultBundles = new VaultIkrBundlesV1(address(morpho));
        assertEq(vaultBundles.BLUE(), address(morpho));
    }

    /// HELPERS ///

    /// @dev Converts a market to the bundler's (top-level morpho-blue) MarketParams type.
    function _toBundler(MarketParams memory mp) internal pure returns (BundlerMarketParams memory) {
        return BundlerMarketParams(mp.loanToken, mp.collateralToken, mp.oracle, mp.irm, mp.lltv);
    }

    /// @dev Wraps a single market into the singleton list expected by vaultBundlesV1ForceWithdrawIlliquidVaultV1.
    function _singleton(MarketParams memory marketParams_) internal pure returns (BundlerMarketParams[] memory list) {
        list = new BundlerMarketParams[](1);
        list[0] = _toBundler(marketParams_);
    }

    /// @dev Deploys a MetaMorpho (Vault V1) over the loan token, deposits `assets` for address(this) which get
    /// allocated to the Morpho market, then borrows all of them out so the market is fully illiquid. A second market
    /// is used so the Morpho contract still holds enough global loan token liquidity to fund the flash loan.
    function _setUpIlliquid(uint256 assets) internal {
        vault = IMetaMorpho(
            deployCode(
                "MetaMorpho.sol:MetaMorpho", abi.encode(owner, address(morpho), 1 days, address(loanToken), "V1", "V1")
            )
        );

        // Enable marketParams with an infinite cap and make it the only entry of the supply/withdraw queues.
        Id[] memory queue = new Id[](1);
        queue[0] = marketParams.id();
        vm.startPrank(owner);
        vault.submitCap(marketParams, type(uint184).max);
        vm.warp(block.timestamp + 1 days);
        vault.acceptCap(marketParams);
        vault.setSupplyQueue(queue);
        vm.stopPrank();

        // Depositing allocates to the market through the supply queue.
        deal(address(loanToken), address(this), assets);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets, address(this));
        assertGt(morpho.supplyShares(marketParams.id(), address(vault)), 0, "allocation");

        // Borrow everything out of the vault's market ⇒ illiquid.
        deal(address(collateralToken), borrower, 2 * assets);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, 2 * assets, borrower, "");
        morpho.borrow(marketParams, assets, 0, borrower, borrower);
        vm.stopPrank();

        // Morpho global liquidity (funds the flash loan) from another market sharing the loan token.
        deal(address(loanToken), liquidityProvider, 2 * assets);
        vm.startPrank(liquidityProvider);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(otherMarket, 2 * assets, 0, liquidityProvider, "");
        vm.stopPrank();

        // The sender (this contract) authorizes the bundler to move its vault shares.
        vault.approve(address(vaultBundles), type(uint256).max);

        // Sanity: the depositor still "owns" ~assets worth of shares but holds no loan token.
        deal(address(loanToken), address(this), 0);
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

    /// @dev Borrows `amount` out of `mp` (over-collateralized) to remove that much liquidity from the market.
    function _borrowOut(MarketParams memory mp, uint256 amount) internal {
        deal(address(collateralToken), borrower, 2 * amount);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(mp, 2 * amount, borrower, "");
        morpho.borrow(mp, amount, 0, borrower, borrower);
        vm.stopPrank();
    }

    /// @dev Deploys a MetaMorpho over `marketParams` (cap `assets1`) and `otherMarket` (uncapped), both in the supply
    /// and withdraw queues, then deposits `assets1 + assets2` for address(this) (filling marketParams to its cap, the
    /// rest into otherMarket). Accrues non-round yield on both markets — so the vault and the markets all end up with
    /// non-round share/asset ratios — and funds Morpho's global liquidity for the flash loan. Markets are left fully
    /// liquid; callers borrow out whatever they need.
    function _deployVaultTwoMarkets(uint256 assets1, uint256 assets2) internal {
        assets1 = bound(assets1, 0, type(uint184).max);
        vault = IMetaMorpho(
            deployCode(
                "MetaMorpho.sol:MetaMorpho", abi.encode(owner, address(morpho), 1 days, address(loanToken), "V1", "V1")
            )
        );

        Id[] memory queue = new Id[](2);
        queue[0] = marketParams.id();
        queue[1] = otherMarket.id();
        vm.startPrank(owner);
        // forge-lint:disable-next-line(unsafe-typecast) safe because assets1 <= type(uint184).max.
        vault.submitCap(marketParams, uint184(assets1));
        vault.submitCap(otherMarket, type(uint184).max);
        vm.warp(block.timestamp + 1 days);
        vault.acceptCap(marketParams);
        vault.acceptCap(otherMarket);
        vault.setSupplyQueue(queue); // withdraw queue defaults to acceptance order [marketParams, otherMarket].
        vm.stopPrank();

        // Depositing allocates marketParams up to its cap, then the rest to otherMarket.
        deal(address(loanToken), address(this), assets1 + assets2);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets1 + assets2, address(this));
        assertApproxEqAbs(morpho.expectedSupplyAssets(marketParams, address(vault)), assets1, 1, "market1 allocation");
        assertApproxEqAbs(morpho.expectedSupplyAssets(otherMarket, address(vault)), assets2, 1, "market2 allocation");

        // Non-round share/asset ratios on both markets (and hence on the vault, the sole supplier).
        _accrueYield(marketParams, assets1 / 3);
        _accrueYield(otherMarket, assets2 / 7);

        // Morpho global liquidity to fund the flash loan, from a third market sharing the loan token (never borrowed).
        vm.prank(owner);
        morpho.enableLltv(0.5e18);
        MarketParams memory liquidityMarket =
            MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), 0.5e18);
        morpho.createMarket(liquidityMarket);
        uint256 liquidity = 4 * (assets1 + assets2);
        deal(address(loanToken), liquidityProvider, liquidity);
        vm.startPrank(liquidityProvider);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(liquidityMarket, liquidity, 0, liquidityProvider, "");
        vm.stopPrank();

        vault.approve(address(vaultBundles), type(uint256).max);
        deal(address(loanToken), address(this), 0);
    }

    /// AUTHORIZATION & VALIDATION ///

    function testOnMorphoFlashLoanOnlyBlue() public {
        vm.expectRevert(IVaultIkrBundlesV1.Unauthorized.selector);
        vaultBundles.onMorphoFlashLoan(1, "");
    }

    /// IN-KIND REDEMPTION ///

    /// @dev A normal withdraw from a fully illiquid vault reverts.
    function testCantWithdrawWhenIlliquid(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpIlliquid(assets);

        vm.expectRevert();
        vault.withdraw(assets, address(this), address(this));
    }

    function testForceWithdrawIlliquid(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpIlliquid(assets);

        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(
            address(vault), _singleton(marketParams), assets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        // Vault V1 has no force deallocate: the user leaves with an in-kind supply position on the market.
        assertApproxEqAbs(morpho.expectedSupplyAssets(marketParams, address(this)), assets, 1, "supply position");
        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
    }

    /// @dev The markets of the withdraw queue keep some liquidity (only half borrowed out). The force withdraw still
    /// in-kind redeems the sender across the whole list.
    function testForceWithdrawNotCompletelyIlliquid() public {
        uint256 assets1 = 60e18;
        uint256 assets2 = 60e18;
        _deployVaultTwoMarkets(assets1, assets2);

        uint256 available1 = morpho.expectedSupplyAssets(marketParams, address(vault));
        uint256 available2 = morpho.expectedSupplyAssets(otherMarket, address(vault));
        // Only half of each market is borrowed out ⇒ neither is completely illiquid.
        _borrowOut(marketParams, available1 / 2);
        _borrowOut(otherMarket, available2 / 2);

        BundlerMarketParams[] memory list = new BundlerMarketParams[](2);
        list[0] = _toBundler(marketParams);
        list[1] = _toBundler(otherMarket);

        // Withdraw more than the first market holds so the remainder spills into the second.
        uint256 forceWithdrawAssets = available1 + 20e18;
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(
            address(vault), list, forceWithdrawAssets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertApproxEqAbs(morpho.expectedSupplyAssets(marketParams, address(this)), available1, 3, "first market");
        assertApproxEqAbs(morpho.expectedSupplyAssets(otherMarket, address(this)), 20e18, 3, "second market");
    }

    /// @dev The vault's position in the first market is not enough to cover the requested assets, so the redemption
    /// drains it and pulls the remainder from the next market: the sender ends with an in-kind position in both.
    function testForceWithdrawMultipleMarkets() public {
        uint256 assets1 = 60e18;
        uint256 assets2 = 60e18;
        _deployVaultTwoMarkets(assets1, assets2);

        uint256 available1 = morpho.expectedSupplyAssets(marketParams, address(vault));
        uint256 available2 = morpho.expectedSupplyAssets(otherMarket, address(vault));
        // Borrow everything out of both markets ⇒ both fully illiquid.
        _borrowOut(marketParams, available1);
        _borrowOut(otherMarket, available2);

        BundlerMarketParams[] memory list = new BundlerMarketParams[](2);
        list[0] = _toBundler(marketParams);
        list[1] = _toBundler(otherMarket);

        // More than the first market holds ⇒ in-kind redeemed across both.
        uint256 forceWithdrawAssets = available1 + 20e18;
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(
            address(vault), list, forceWithdrawAssets, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertApproxEqAbs(morpho.expectedSupplyAssets(marketParams, address(this)), available1, 3, "first market");
        assertApproxEqAbs(morpho.expectedSupplyAssets(otherMarket, address(this)), 20e18, 3, "second market");
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawIlliquidDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultIkrBundlesV1.DeadlinePassed.selector);
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(
            address(vault), _singleton(marketParams), assets, block.timestamp - 1
        );
    }
}
