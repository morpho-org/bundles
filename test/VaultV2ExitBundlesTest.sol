// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultExitBundlesV1} from "../src/vault-exit/VaultExitBundlesV1.sol";
import {IVaultExitBundlesV1, SharesPermit} from "../src/vault-exit/interfaces/IVaultExitBundlesV1.sol";

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

// Minimal ERC-2612 handle exposed by the vault shares, used to sign shares permits.
interface IERC20PermitVault {
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract VaultV2ExitBundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV_1 = 0.8e18;
    uint256 internal constant LLTV_2 = 0.9e18;
    uint256 internal constant PENALTY = 0.01e18;

    uint256 internal constant MIN_ASSETS = 2; // assets == 1 ⇒ deallocatedAssets == 0 (see testInKindRedemptionTooSmallNoOp).
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    IVaultV2 internal vault;
    IMorphoMarketV1AdapterV2 internal adapter;
    VaultExitBundlesV1 internal vaultBundles;

    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    OracleMock internal oracle;

    MarketParams internal marketParams; // vault market (made illiquid)
    MarketParams internal otherMarket; // same loan token, supplies Morpho's global liquidity
    MarketParams internal thirdMarket; // created in _setUpLiquidThreeMarkets

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal borrower = makeAddr("borrower");
    address internal liquidityProvider = makeAddr("liquidityProvider");
    address internal referralFeeRecipient = makeAddr("referralFeeRecipient");

    // The empty shares permit (v, r and s all zero) is skipped by the bundler.
    SharesPermit internal noSharesPermit;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

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

        vaultBundles = new VaultExitBundlesV1(address(morpho));
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

    /// @dev Wraps a single market into the singleton list expected by vaultExitBundlesV1InKindRedemptionVaultV2.
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

    /// @dev Signs an ERC-2612 permit of the bundler over owner's vault shares, for the given value and deadline.
    function _signSharesPermit(uint256 privateKey, address owner_, uint256 value, uint256 sigDeadline)
        internal
        view
        returns (SharesPermit memory)
    {
        uint256 nonce = IERC20PermitVault(address(vault)).nonces(owner_);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, address(vaultBundles), value, nonce, sigDeadline));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IERC20PermitVault(address(vault)).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return SharesPermit({value: value, nonce: nonce, deadline: sigDeadline, v: v, r: r, s: s});
    }

    function _setUpIlliquid(uint256 assets) internal {
        _setUpIlliquid(assets, address(this), true);
    }

    /// @dev Deposits `assets` into the vault for `depositor`, allocates them to the Morpho market, then borrows all
    /// of them out so the market is fully illiquid. A second market is used so the Morpho contract still holds
    /// enough global loan token liquidity.
    /// @dev When approveBundler is false, the depositor grants no allowance, leaving it to a shares permit.
    function _setUpIlliquid(uint256 assets, address depositor, bool approveBundler) internal {
        deal(address(loanToken), depositor, assets);
        vm.startPrank(depositor);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets, depositor);
        vm.stopPrank();

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

        // The sender authorizes the bundler to move its vault shares (unless left to a shares permit).
        if (approveBundler) {
            vm.prank(depositor);
            vault.approve(address(vaultBundles), type(uint256).max);
        }

        // Sanity: the depositor cannot redeem normally, yet still "owns" ~assets worth of shares.
        deal(address(loanToken), depositor, 0);
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

    /// @dev Like _setUpLiquid but allocates across two adapter markets (`marketParams` and `otherMarket`). Nothing is
    /// borrowed out, so both markets stay liquid.
    function _setUpLiquidTwoMarkets(uint256 assets1, uint256 assets2) internal {
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

        // The sender (this contract) authorizes the bundler to move its vault shares.
        vault.approve(address(vaultBundles), type(uint256).max);

        // Reset so the final balance measures exactly what is withdrawn from the vault.
        deal(address(loanToken), address(this), 0);
    }

    /// @dev Like _setUpLiquidTwoMarkets but with a third market (`thirdMarket`, created here).
    function _setUpLiquidThreeMarkets(uint256 assets1, uint256 assets2, uint256 assets3) internal {
        vm.prank(owner);
        morpho.enableLltv(0.7e18);
        thirdMarket = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), 0.7e18);
        morpho.createMarket(thirdMarket);
        _increaseCaps(abi.encode("this/marketParams", address(adapter), thirdMarket));

        _setUpLiquidTwoMarkets(assets1, assets2);

        deal(address(loanToken), address(this), assets3);
        vault.deposit(assets3, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(thirdMarket), assets3);
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

    function testInKindRedemptionAdapterNotPartOfVault() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultExitBundlesV1.AdapterNotPartOfVault.selector);
        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), makeAddr("notAdapter"), _singleton(marketParams), assets, noSharesPermit, block.timestamp
        );
    }

    /// @dev A market not allocated through the adapter (supplyShares == 0) is skipped; with no further market in the
    /// list to cover the requested assets, the loop runs past the list and reverts.
    function testInKindRedemptionMarketWithoutAdapterShares() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        // otherMarket was never allocated through the adapter ⇒ supplyShares == 0.
        vm.expectRevert();
        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(otherMarket), assets, noSharesPermit, block.timestamp
        );
    }

    /// @dev The single market is allocated through the adapter but holds less than the requested amount; with no
    /// further market in the list to cover the remainder, the loop runs past the list and reverts.
    function testInKindRedemptionNotEnoughAvailable() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        // Requesting 2x the deposited assets ⇒ assetsToDeallocate ≈ 1.98x what the single market holds.
        uint256 tooMuch = 2 * assets;
        assertGt(optimalDeallocateAssets(tooMuch), assets, "precondition");

        vm.expectRevert();
        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(marketParams), tooMuch, noSharesPermit, block.timestamp
        );
    }

    function testOnMorphoSupplyOnlyBlue() public {
        vm.expectRevert(IVaultExitBundlesV1.UnauthorizedCallback.selector);
        vaultBundles.onMorphoSupply(1, "");
    }

    /// @dev assets so small that deallocatedAssets rounds to 0 ⇒ the deallocation loop never runs (no-op).
    function testInKindRedemptionTooSmallNoOp() public {
        uint256 assets = 1;
        _setUpIlliquid(assets);
        assertEq(optimalDeallocateAssets(assets), 0, "precondition");

        uint256 sharesBefore = vault.balanceOf(address(this));
        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, noSharesPermit, block.timestamp
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

    function testInKindRedemption(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpIlliquid(assets);

        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, noSharesPermit, block.timestamp
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

    /// @dev A sender that never approved the bundler can exit in a single transaction via sharesPermit.
    function testInKindRedemptionWithSharesPermit(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        (address sigUser, uint256 sigUserKey) = makeAddrAndKey("sigUser");
        _setUpIlliquid(assets, sigUser, false);

        assertEq(vault.allowance(sigUser, address(vaultBundles)), 0, "no prior allowance");

        SharesPermit memory sharesPermit = _signSharesPermit(sigUserKey, sigUser, type(uint256).max, block.timestamp);
        vm.prank(sigUser);
        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, sharesPermit, block.timestamp
        );

        assertEq(morpho.expectedSupplyAssets(marketParams, sigUser), optimalDeallocateAssets(assets), "supply position");
        assertApproxEqAbs(vault.balanceOf(sigUser), 0, 1, "vault balance");
    }

    /// @dev When the first market does not hold enough, the loop drains it and pulls the remainder from the next
    /// market in the list, leaving the sender an in-kind position in both.
    function testInKindRedemptionMultipleMarkets() public {
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
        uint256 exitAssets = 90e18;
        uint256 deallocate = optimalDeallocateAssets(exitAssets);
        assertGt(deallocate, available1, "precondition: one market is not enough");

        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), list, exitAssets, noSharesPermit, block.timestamp
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

    function testInKindRedemptionSkipsEmptyAdapterMarket() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);
        assertEq(adapter.supplyShares(Id.unwrap(otherMarket.id())), 0, "otherMarket empty in adapter");

        MarketParams[] memory list = new MarketParams[](2);
        list[0] = otherMarket;
        list[1] = marketParams;

        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), list, assets, noSharesPermit, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertEq(
            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
        );
    }

    /// @dev The first list entry can be a market over a different loan token (the adapter holds no position in it):
    /// the Blue approval token is derived from the vault, so the foreign entry is skipped like any empty adapter
    /// market. Deriving the token from marketParamsList[0] would approve the wrong token and revert when Blue pulls
    /// the supplied assets.
    function testInKindRedemptionForeignFirstMarket(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpIlliquid(assets);

        ERC20Mock foreignToken = new ERC20Mock(18);
        MarketParams memory foreignMarket =
            MarketParams(address(foreignToken), address(collateralToken), address(oracle), address(0), LLTV_1);
        morpho.createMarket(foreignMarket);
        assertEq(adapter.supplyShares(Id.unwrap(foreignMarket.id())), 0, "foreignMarket empty in adapter");

        MarketParams[] memory list = new MarketParams[](2);
        list[0] = foreignMarket;
        list[1] = marketParams;

        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), list, assets, noSharesPermit, block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        assertEq(
            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
        );
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testInKindRedemptionDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultExitBundlesV1.DeadlinePassed.selector);
        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(marketParams), assets, noSharesPermit, block.timestamp - 1
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
    function testInKindRedemptionSafeExit(uint256 assets, uint256 priceWad) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        priceWad = bound(priceWad, WAD / 10, 10 * WAD);
        _setUpIlliquid(assets);
        _setSharePrice(priceWad);

        uint256 sharesBefore = vault.balanceOf(address(this));
        vm.assume(sharesBefore > 2);
        uint256 amount = vault.previewRedeem(sharesBefore - 2);
        vm.assume(optimalDeallocateAssets(amount) > 0);

        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), _singleton(marketParams), amount, noSharesPermit, block.timestamp
        );

        assertLe(
            vault.previewRedeem(vault.balanceOf(address(this))), 2 * priceWad / WAD + 2, "more than 2 shares worth left"
        );
    }

    /// FORCE WITHDRAWAL ///

    function testForceWithdrawAdapterNotPartOfVault() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert(IVaultExitBundlesV1.AdapterNotPartOfVault.selector);
        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), makeAddr("notAdapter"), assets, noSharesPermit, 0, address(0), block.timestamp
        );
    }

    /// @dev The adapter's markets hold less than the requested amount; the loop runs past the market list and reverts.
    function testForceWithdrawNotEnoughAvailable() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert();
        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), 2 * assets, noSharesPermit, 0, address(0), block.timestamp
        );
    }

    function testForceWithdraw(uint256 assets) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _setUpLiquid(assets);

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), assets, noSharesPermit, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
        assertEq(loanToken.balanceOf(address(adapter)), 0, "adapter loan token balance");
        // The user leaves the vault with the deallocated assets.
        assertEq(loanToken.balanceOf(address(this)), optimalDeallocateAssets(assets), "user loan token balance");
        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
    }

    function testExitWithReferralFee(uint256 assets, uint256 referralFeePct) public {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        referralFeePct = bound(referralFeePct, 0, WAD - 1);
        _setUpLiquid(assets);

        uint256 withdrawn = optimalDeallocateAssets(assets);
        uint256 expectedFee = withdrawn * referralFeePct / WAD;

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault),
            address(adapter),
            assets,
            noSharesPermit,
            referralFeePct,
            referralFeeRecipient,
            block.timestamp
        );

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(this)), withdrawn - expectedFee, "user net");
        assertEq(loanToken.balanceOf(referralFeeRecipient), expectedFee, "referralFeeRecipient fee");
        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
    }

    function testForceWithdrawPctExceeded() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert(IVaultExitBundlesV1.PctExceeded.selector);
        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), assets, noSharesPermit, WAD, referralFeeRecipient, block.timestamp
        );
    }

    function testForceWithdrawThreeMarkets() public {
        _setUpLiquidThreeMarkets(50e18, 30e18, 20e18);

        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 amount = vault.previewRedeem(sharesBefore - 4);
        uint256 deallocate = optimalDeallocateAssets(amount);
        assertGt(deallocate, 80e18, "precondition: all three markets are needed");

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), amount, noSharesPermit, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(address(this)), deallocate, "user loan token balance");
        // The first two markets are drained, the remainder is pulled from the third.
        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 0, "first market position");
        assertEq(morpho.expectedSupplyAssets(otherMarket, address(adapter)), 0, "second market position");
        assertEq(
            morpho.expectedSupplyAssets(thirdMarket, address(adapter)), 100e18 - deallocate, "third market position"
        );
        assertEq(vault.balanceOf(address(this)), 4, "exactly the margin is left in the vault");
    }

    /// @dev The first market's liquidity is partially borrowed out, so only its available liquidity is taken from it
    /// and the rest comes from the second market.
    function testForceWithdrawMarketLiquidityLimited() public {
        _setUpLiquidTwoMarkets(100e18, 100e18);

        // Borrow 40 out of the first market ⇒ only 60 of the adapter's 100 position is withdrawable there.
        deal(address(collateralToken), borrower, 100e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, 100e18, borrower, "");
        morpho.borrow(marketParams, 40e18, 0, borrower, borrower);
        vm.stopPrank();

        uint256 exitAssets = 101e18;
        assertEq(optimalDeallocateAssets(exitAssets), 100e18, "precondition");

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), exitAssets, noSharesPermit, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(address(this)), 100e18, "user loan token balance");
        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 40e18, "first market position");
        assertEq(morpho.expectedSupplyAssets(otherMarket, address(adapter)), 60e18, "second market position");
    }

    /// @dev The liquidity available through the liquidity adapter is withdrawn first, without penalty; only the
    /// remainder is force deallocated.
    function testForceWithdrawLiquidityAdapterFirst() public {
        _setUpLiquidTwoMarkets(60e18, 40e18);

        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(adapter), abi.encode(marketParams));

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), 80e18, noSharesPermit, 0, address(0), block.timestamp
        );

        // 60 comes penalty-free through the liquidity adapter, the remaining 20 pays the penalty.
        assertEq(loanToken.balanceOf(address(this)), 60e18 + optimalDeallocateAssets(20e18), "user loan token balance");
        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 0, "first market position");
        assertApproxEqAbs(
            morpho.expectedSupplyAssets(otherMarket, address(adapter)),
            40e18 - optimalDeallocateAssets(20e18),
            2,
            "second market position"
        );
    }

    /// @dev A request fully covered by the liquidity adapter pays no penalty and never force deallocates.
    function testForceWithdrawOnlyLiquidityAdapter() public {
        _setUpLiquidTwoMarkets(60e18, 40e18);

        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(adapter), abi.encode(marketParams));

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), 50e18, noSharesPermit, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(address(this)), 50e18, "user loan token balance");
        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 10e18, "first market position");
        assertEq(morpho.expectedSupplyAssets(otherMarket, address(adapter)), 40e18, "second market position");
    }

    /// @dev The vault's idle assets are withdrawn first, without penalty; only the remainder is force deallocated.
    function testForceWithdrawIdleAssetsFirst() public {
        deal(address(loanToken), address(this), 100e18);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, address(this));

        // Allocate only 70 ⇒ 30 stay idle in the vault.
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(marketParams), 70e18);

        vault.approve(address(vaultBundles), type(uint256).max);
        deal(address(loanToken), address(this), 0);

        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), 40e18, noSharesPermit, 0, address(0), block.timestamp
        );

        // 30 comes penalty-free from the idle assets, the remaining 10 pays the penalty.
        assertEq(loanToken.balanceOf(address(this)), 30e18 + optimalDeallocateAssets(10e18), "user loan token balance");
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpLiquid(assets);

        vm.expectRevert(IVaultExitBundlesV1.DeadlinePassed.selector);
        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
            address(vault), address(adapter), assets, noSharesPermit, 0, address(0), block.timestamp - 1
        );
    }
}
