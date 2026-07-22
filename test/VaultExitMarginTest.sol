// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test, StdStorage, stdStorage} from "../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultExitBundlesV1} from "../src/vault-exit/VaultExitBundlesV1.sol";
import {SharesPermit} from "../src/vault-exit/interfaces/IVaultExitBundlesV1.sol";

import {IMetaMorpho} from "../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IMorpho, MarketParams, Id} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
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

/// @dev Harness verifying the theoretical safety margin `shares` for which exitAssets = previewRedeem(balanceOf(sender) - shares) does not revert, for the three exit functions and a varying number of markets.
contract VaultExitMarginTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using stdStorage for StdStorage;

    uint256 internal constant V1_ILLIQUID = 0;
    uint256 internal constant V2_ILLIQUID = 1;
    uint256 internal constant V2_LIQUID = 2;
    uint256 internal constant MAX_NUMBER_OF_MARKETS = 20;

    uint256 internal constant PENALTY = 0.01e18;
    uint256 internal constant PER_MARKET = 100e18;
    uint256 internal constant SHARE_PRICE = 1.07e18; // non-round vault share/asset ratio
    // Huge amount to allow for flash-loan and supply callback global liquidity needs.
    uint256 internal constant GLOBAL_LIQUIDITY = 1_000_000e18;
    SharesPermit internal noSharesPermit =
        SharesPermit({value: 0, nonce: 0, deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

    IMorpho internal morpho;
    VaultExitBundlesV1 internal exitBundles;
    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal borrower = makeAddr("borrower");

    address internal vault;
    address internal adapter;
    MarketParams[] internal marketList;

    function setUp() public {
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        loanToken = new ERC20Mock(18);
        collateralToken = new ERC20Mock(18);
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        for (uint256 i = 0; i < 32; i++) {
            morpho.enableLltv(_lltv(i));
        }
        morpho.enableLltv(0.95e18); // dedicated to the global-liquidity market
        vm.stopPrank();

        exitBundles = new VaultExitBundlesV1(address(morpho));

        MarketParams memory m =
            MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), 0.95e18);
        morpho.createMarket(m);
        address supplier = makeAddr("supplier");
        deal(address(loanToken), supplier, GLOBAL_LIQUIDITY);
        vm.startPrank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(m, GLOBAL_LIQUIDITY, 0, supplier, "");
        vm.stopPrank();
    }

    /// HELPERS ///

    function _lltv(uint256 i) internal pure returns (uint256) {
        return 0.1e18 + i * 0.01e18; // distinct; _borrowOut sizes collateral to the lltv, so any value is fine.
    }

    function _market(uint256 i) internal view returns (MarketParams memory) {
        return MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), _lltv(i));
    }

    // Per-market allocation, distinct per market to stress rounding.
    function _amt(uint256 i) internal pure returns (uint256) {
        return 1e18 + uint256(keccak256(abi.encode(i))) % PER_MARKET;
    }

    function _total(uint256 numberOfMarkets) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < numberOfMarkets; i++) {
            s += _amt(i);
        }
    }

    /// @dev Simulates accrued yield on a market via a storage cheat so its share/asset ratio is non-round.
    /// @dev The yield is a pseudo-random fraction of the market's assets, distinct per market to stress rounding.
    function _accrueYield(MarketParams memory marketParams) internal {
        bytes32 slot = MorphoStorageLib.marketTotalSupplyAssetsAndSharesSlot(marketParams.id());
        uint256 packed = uint256(vm.load(address(morpho), slot));
        // forge-lint:disable-next-line(unsafe-typecast) truncating on purpose.
        uint256 totalSupplyAssets = uint128(packed);
        uint256 totalSupplyShares = packed >> 128;
        uint256 yield = uint256(keccak256(abi.encode(Id.unwrap(marketParams.id())))) % totalSupplyAssets;
        if (yield == 0) return;
        vm.store(address(morpho), slot, bytes32((totalSupplyShares << 128) | (totalSupplyAssets + yield)));
        deal(address(loanToken), address(morpho), loanToken.balanceOf(address(morpho)) + yield);
    }

    /// @dev Borrows `amount` out of `marketParams` (over-collateralized) to remove that much liquidity.
    function _borrowOut(MarketParams memory marketParams, uint256 amount) internal {
        if (amount == 0) return;
        uint256 collateral = amount * WAD / marketParams.lltv * 2;
        deal(address(collateralToken), borrower, collateralToken.balanceOf(borrower) + collateral);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, collateral, borrower, "");
        morpho.borrow(marketParams, amount, 0, borrower, borrower);
        vm.stopPrank();
    }

    /// SETUPS ///

    function _setupV1(uint256 numberOfMarkets) internal {
        vault = address(
            IMetaMorpho(
                deployCode(
                    "MetaMorpho.sol:MetaMorpho",
                    abi.encode(owner, address(morpho), 1 days, address(loanToken), "V1", "V1")
                )
            )
        );

        Id[] memory queue = new Id[](numberOfMarkets);
        vm.startPrank(owner);
        for (uint256 i = 0; i < numberOfMarkets; i++) {
            MarketParams memory m = _market(i);
            morpho.createMarket(m);
            marketList.push(m);
            // forge-lint:disable-next-line(unsafe-typecast)
            IMetaMorpho(vault).submitCap(m, uint184(_amt(i)));
            queue[i] = m.id();
        }
        vm.warp(block.timestamp + 1 days);
        for (uint256 i = 0; i < numberOfMarkets; i++) {
            IMetaMorpho(vault).acceptCap(marketList[i]);
        }
        IMetaMorpho(vault).setSupplyQueue(queue);
        vm.stopPrank();

        deal(address(loanToken), address(this), _total(numberOfMarkets));
        loanToken.approve(vault, type(uint256).max);
        IMetaMorpho(vault).deposit(_total(numberOfMarkets), address(this));

        for (uint256 i = 0; i < numberOfMarkets; i++) {
            _accrueYield(marketList[i]);
            _borrowOut(marketList[i], morpho.expectedSupplyAssets(marketList[i], address(vault)));
        }

        // Set the vault share price to SHARE_PRICE, keeping the sole holder's balance equal to the total supply.
        uint256 newShares = IMetaMorpho(vault).totalAssets() * WAD / SHARE_PRICE;
        stdstore.target(vault).sig("totalSupply()").checked_write(newShares);
        stdstore.target(vault).sig("balanceOf(address)").with_key(address(this)).checked_write(newShares);
        assertApproxEqAbs(
            IMetaMorpho(vault).totalAssets() * WAD / IMetaMorpho(vault).totalSupply(), SHARE_PRICE, 1, "share price"
        );

        IMetaMorpho(vault).approve(address(exitBundles), type(uint256).max);
        deal(address(loanToken), address(this), 0);
    }

    function _setupV2(uint256 numberOfMarkets, bool illiquid) internal {
        IVaultV2Factory vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
        vault = address(IVaultV2(vaultFactory.createVaultV2(owner, address(loanToken), bytes32(0))));

        vm.prank(owner);
        IVaultV2(vault).setCurator(curator);
        _submitAndExec(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));

        IMorphoMarketV1AdapterV2Factory adapterFactory = IMorphoMarketV1AdapterV2Factory(
            deployCode(
                "MorphoMarketV1AdapterV2Factory.sol:MorphoMarketV1AdapterV2Factory", abi.encode(morpho, address(0))
            )
        );
        adapter = address(IMorphoMarketV1AdapterV2(adapterFactory.createMorphoMarketV1AdapterV2(address(vault))));
        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (adapter)));

        vm.prank(allocator);
        IVaultV2(vault).setMaxRate(MAX_MAX_RATE);

        _setMaxCaps(abi.encode("this", adapter));
        _setMaxCaps(abi.encode("collateralToken", address(collateralToken)));
        for (uint256 i = 0; i < numberOfMarkets; i++) {
            MarketParams memory m = _market(i);
            morpho.createMarket(m);
            marketList.push(m);
            _setMaxCaps(abi.encode("this/marketParams", adapter, m));
        }

        _submitAndExec(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (adapter, PENALTY)));

        deal(address(loanToken), address(this), _total(numberOfMarkets));
        loanToken.approve(address(vault), type(uint256).max);
        IVaultV2(vault).deposit(_total(numberOfMarkets), address(this));

        for (uint256 i = 0; i < numberOfMarkets; i++) {
            vm.prank(allocator);
            IVaultV2(vault).allocate(adapter, abi.encode(marketList[i]), _amt(i));
            _accrueYield(marketList[i]);
            if (illiquid) _borrowOut(marketList[i], morpho.expectedSupplyAssets(marketList[i], address(adapter)));
        }

        // Set the vault share price to SHARE_PRICE, keeping the sole holder's balance equal to the total supply.
        uint256 newShares = IVaultV2(vault).totalAssets() * WAD / SHARE_PRICE;
        stdstore.target(vault).sig("totalSupply()").checked_write(newShares);
        stdstore.target(vault).sig("balanceOf(address)").with_key(address(this)).checked_write(newShares);
        assertApproxEqAbs(
            IVaultV2(vault).totalAssets() * WAD / IVaultV2(vault).totalSupply(), SHARE_PRICE, 1, "share price"
        );

        IVaultV2(vault).approve(address(exitBundles), type(uint256).max);
        deal(address(loanToken), address(this), 0);
    }

    function _submitAndExec(bytes memory data) internal {
        vm.prank(curator);
        IVaultV2(vault).submit(data);
        (bool success,) = vault.call(data);
        require(success, "exec failed");
    }

    function _setMaxCaps(bytes memory idData) internal {
        _submitAndExec(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _submitAndExec(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, WAD)));
    }

    /// THEORETICAL BOUND ///

    // Theoretical safe margin (in shares): the exit is split into independent vault withdrawals.
    // Each withdrawal burns previewWithdraw(assets) shares (mulDivUp), so it rounds up by at most one share.
    // The V1 path withdraws exitAssets = previewRedeem(balance - margin), so it needs no margin (0).
    // The illiquid V2 path makes two withdrawals per market (penalty and deallocated assets), hence 2 * numberOfMarkets.
    // The liquid V2 path makes one upfront withdrawal, one penalty withdrawal per market, and one final withdrawal, hence numberOfMarkets + 2.
    function _margin(uint256 scenario, uint256 numberOfMarkets) internal pure returns (uint256) {
        if (scenario == V1_ILLIQUID) return 0;
        if (scenario == V2_ILLIQUID) return 2 * numberOfMarkets;
        return numberOfMarkets + 2;
    }

    function testMarginV1(uint256 numberOfMarkets) public {
        numberOfMarkets = bound(numberOfMarkets, 1, MAX_NUMBER_OF_MARKETS);
        _setupV1(numberOfMarkets);

        uint256 margin = _margin(V1_ILLIQUID, numberOfMarkets);
        uint256 balance = IMetaMorpho(vault).balanceOf(address(this));
        if (margin >= balance) return;
        uint256 exitAssets = IMetaMorpho(vault).previewRedeem(balance - margin);
        if (exitAssets == 0) return;

        exitBundles.vaultExitBundlesV1InKindRedemptionVaultV1(
            vault, marketList, exitAssets, noSharesPermit, block.timestamp
        );
    }

    function testMarginV2Illiquid(uint256 numberOfMarkets) public {
        numberOfMarkets = bound(numberOfMarkets, 1, MAX_NUMBER_OF_MARKETS);
        _setupV2(numberOfMarkets, true);

        uint256 margin = _margin(V2_ILLIQUID, numberOfMarkets);
        uint256 balance = IVaultV2(vault).balanceOf(address(this));
        if (margin >= balance) return;
        uint256 exitAssets = IVaultV2(vault).previewRedeem(balance - margin);
        if (exitAssets == 0) return;

        exitBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            vault, adapter, marketList, exitAssets, noSharesPermit, block.timestamp
        );
    }

    function testMarginV2Liquid(uint256 numberOfMarkets) public {
        numberOfMarkets = bound(numberOfMarkets, 1, MAX_NUMBER_OF_MARKETS);
        _setupV2(numberOfMarkets, false);

        uint256 margin = _margin(V2_LIQUID, numberOfMarkets);
        uint256 balance = IVaultV2(vault).balanceOf(address(this));
        if (margin >= balance) return;
        uint256 exitAssets = IVaultV2(vault).previewRedeem(balance - margin);
        if (exitAssets == 0) return;

        exitBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            vault, adapter, exitAssets, noSharesPermit, 0, address(0), block.timestamp
        );
    }
}
