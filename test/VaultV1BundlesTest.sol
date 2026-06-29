// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultBundlesV1} from "../src/vault/VaultBundlesV1.sol";
import {IVaultBundlesV1} from "../src/vault/IVaultBundlesV1.sol";

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

contract VaultV1BundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV_1 = 0.8e18;
    uint256 internal constant LLTV_2 = 0.9e18;

    uint256 internal constant MIN_ASSETS = 2;
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    IMetaMorpho internal vault;
    VaultBundlesV1 internal vaultBundles;

    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;

    MarketParams internal marketParams; // vault market (made illiquid)
    MarketParams internal otherMarket; // same loan token, supplies Morpho's global liquidity

    MarketParams[] internal markets; // 15-market setup for the gas benchmarks
    uint256 internal withdrawAmount; // withdraw size, loaded from storage in the gas benchmarks

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

        vaultBundles = new VaultBundlesV1(address(morpho));
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
        vm.expectRevert(IVaultBundlesV1.Unauthorized.selector);
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

        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(address(vault), _singleton(marketParams), assets, block.timestamp);

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
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(address(vault), list, forceWithdrawAssets, block.timestamp);

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
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(address(vault), list, forceWithdrawAssets, block.timestamp);

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertApproxEqAbs(morpho.expectedSupplyAssets(marketParams, address(this)), available1, 3, "first market");
        assertApproxEqAbs(morpho.expectedSupplyAssets(otherMarket, address(this)), 20e18, 3, "second market");
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawIlliquidDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultBundlesV1.DeadlinePassed.selector);
        vaultBundles.vaultBundlesV1ForceWithdrawIlliquidVaultV1(address(vault), _singleton(marketParams), assets, block.timestamp - 1);
    }

    /// GAS: WITHDRAW LOOP LENGTH ///

    /// @dev Deploys a MetaMorpho with `markets.length` markets, all in the supply and withdraw queues in order. The
    /// vault gets a position in every market; markets [0, n-2] are then fully borrowed out (illiquid), only the last
    /// one keeps liquidity. So every `withdraw` walks the whole withdraw queue: it reads each illiquid market (finding
    /// nothing withdrawable) before pulling everything from the last market.
    function _setUp15MarketsLastLiquid() internal {
        uint256 n = 15;
        uint256 perMarket = 10e18; // allocated to and borrowed out of each illiquid market
        uint256 lastLiquidity = 100e18; // liquidity left in the last market to serve the withdraws

        // 15 distinct markets sharing the loan/collateral/oracle, told apart by their LLTV.
        for (uint256 i; i < n; ++i) {
            uint256 lltv = (i + 1) * 0.05e18; // 0.05e18 .. 0.75e18, all distinct and < WAD
            vm.prank(owner);
            morpho.enableLltv(lltv);
            MarketParams memory mp =
                MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), lltv);
            morpho.createMarket(mp);
            markets.push(mp);
        }

        vault = IMetaMorpho(
            deployCode(
                "MetaMorpho.sol:MetaMorpho", abi.encode(owner, address(morpho), 1 days, address(loanToken), "V1", "V1")
            )
        );

        Id[] memory queue = new Id[](n);
        vm.startPrank(owner);
        for (uint256 i; i < n; ++i) {
            // Last market uncapped (holds the remaining liquidity); the others capped at exactly `perMarket`.
            uint184 cap = i == n - 1 ? type(uint184).max : uint184(perMarket);
            vault.submitCap(markets[i], cap);
            queue[i] = markets[i].id();
        }
        vm.warp(block.timestamp + 1 days);
        for (uint256 i; i < n; ++i) {
            vault.acceptCap(markets[i]); // acceptance order [0..n-1] => withdraw queue [0..n-1].
        }
        vault.setSupplyQueue(queue); // same order: deposit fills [0..n-2] to cap, the rest into the last market.
        vm.stopPrank();

        uint256 total = perMarket * (n - 1) + lastLiquidity;
        deal(address(loanToken), address(this), total);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(total, address(this));

        // Borrow everything out of the first n-1 markets so only the last one keeps liquidity. Collateral is sized at
        // 100x the borrow so even the lowest-LLTV (0.05) market is over-collateralized.
        for (uint256 i; i < n - 1; ++i) {
            deal(address(collateralToken), borrower, 100 * perMarket);
            vm.startPrank(borrower);
            collateralToken.approve(address(morpho), type(uint256).max);
            morpho.supplyCollateral(markets[i], 100 * perMarket, borrower, "");
            morpho.borrow(markets[i], perMarket, 0, borrower, borrower);
            vm.stopPrank();
        }

        withdrawAmount = 1e18; // 15 * 1e18 < lastLiquidity, so the last market serves them all.
    }

    /// @dev 15 sequential withdraws, each walking the full 15-market withdraw queue.
    function testGasVaultV1Withdraw15Times() public {
        _setUp15MarketsLastLiquid();

        uint256 assets = withdrawAmount;
        address self = address(this);
        uint256 shares;

        uint256 g = gasleft();
        for (uint256 i; i < 15; ++i) {
            shares += vault.withdraw(assets, self, self);
        }
        g = g - gasleft();

        require(shares > 0, "no withdraw");
        emit log_named_uint("gas: 15 withdraws (full 15-market loop each)", g);
        emit log_named_uint("gas: per withdraw (avg)", g / 15);
    }

    /// @dev Two withdraws behind distinct external selectors so the flamechart keeps them as separate frames
    /// (identical call paths are otherwise folded into a single summed block). Also logs each call's gas.
    function firstWithdraw() external returns (uint256) {
        return vault.withdraw(withdrawAmount, address(this), address(this));
    }

    function secondWithdraw() external returns (uint256) {
        return vault.withdraw(withdrawAmount, address(this), address(this));
    }

    /// @dev Single parent frame wrapping both withdraws, so the flamechart has one block to zoom into.
    function bothWithdraws() external returns (uint256, uint256) {
        return (this.firstWithdraw(), this.secondWithdraw());
    }

    function testGasVaultV1Withdraw2Times() public {
        _setUp15MarketsLastLiquid();

        (uint256 s1, uint256 s2) = this.bothWithdraws();

        require(s1 > 0 && s2 > 0, "no withdraw");
    }

    /// @dev Number of distinct entries in `a` (O(n^2), fine for the small access lists here).
    function _distinct(bytes32[] memory a) internal pure returns (uint256 n) {
        for (uint256 i; i < a.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (a[j] == a[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) ++n;
        }
    }

    /// @dev Counts total vs distinct storage slots read (SLOAD) and written (SSTORE) during one withdraw, across
    /// every contract the call touches. total = #opcodes executed; distinct = #unique slots (the cold candidates).
    /// cold->warm gain ~= distinct_slots * (2100 - 100); warm floor ~= total_slots * 100.
    function testCountSlotsVaultV1Withdraw() public {
        _setUp15MarketsLastLiquid();

        address[6] memory addrs =
            [address(vault), address(morpho), address(loanToken), address(collateralToken), address(oracle), address(this)];

        vm.record();
        vault.withdraw(withdrawAmount, address(this), address(this));

        uint256 totalReads;
        uint256 distinctReads;
        uint256 totalWrites;
        uint256 distinctWrites;
        for (uint256 k; k < addrs.length; ++k) {
            (bytes32[] memory r, bytes32[] memory w) = vm.accesses(addrs[k]);
            totalReads += r.length;
            distinctReads += _distinct(r);
            totalWrites += w.length;
            distinctWrites += _distinct(w);
        }
        emit log_named_uint("SLOAD total (with repeats)", totalReads);
        emit log_named_uint("SLOAD distinct slots       ", distinctReads);
        emit log_named_uint("SSTORE total (with repeats)", totalWrites);
        emit log_named_uint("SSTORE distinct slots      ", distinctWrites);
    }

    /// @dev Directly measures the cold->warm gain: forcibly cool every touched account, do an all-cold withdraw,
    /// then a fully-warm one. The gap is the real EIP-2929 saving and should track distinct_slots * 2000.
    function testColdWarmGainVaultV1Withdraw() public {
        _setUp15MarketsLastLiquid();
        address self = address(this);

        vm.cool(address(vault));
        vm.cool(address(morpho));
        vm.cool(address(loanToken));
        vm.cool(self);

        uint256 g1 = gasleft();
        uint256 s1 = vault.withdraw(withdrawAmount, self, self);
        g1 = g1 - gasleft();

        uint256 g2 = gasleft();
        uint256 s2 = vault.withdraw(withdrawAmount, self, self);
        g2 = g2 - gasleft();

        require(s1 > 0 && s2 > 0, "no withdraw");
        emit log_named_uint("withdraw all-cold", g1);
        emit log_named_uint("withdraw all-warm", g2);
        emit log_named_uint("cold->warm gain  ", g1 - g2);
    }

    /// @dev A single withdraw over the same 15-market setup, for comparison.
    function testGasVaultV1WithdrawOnce() public {
        _setUp15MarketsLastLiquid();

        uint256 assets = withdrawAmount;
        address self = address(this);

        uint256 g = gasleft();
        uint256 shares = vault.withdraw(assets, self, self);
        g = g - gasleft();

        require(shares > 0, "no withdraw");
        emit log_named_uint("gas: 1 withdraw (full 15-market loop)", g);
    }
}
