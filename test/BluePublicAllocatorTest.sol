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
import {IrmMock} from "../lib/morpho-blue/src/mocks/IrmMock.sol";
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
import {IBlueBundlesV1, SignedAuthorization, PublicReallocation} from "../src/blue/interfaces/IBlueBundlesV1.sol";
import {TokenLib, TokenPermit} from "../src/libraries/TokenLib.sol";
import {WETHMock} from "./BlueBundlesTest.sol";

/// @dev Handle on Vault V2's BluePublicAllocator, which is deployed through deployCode so that its own compiler
/// settings do not leak into this file's compilation unit.
interface IPublicAllocator {
    error AbsoluteCapExceeded();
    error CannotDeallocate();
    error InactiveAdapter();

    function vaultData(address vault)
        external
        view
        returns (bool canAllocateFromIdle, uint120 nativePenalty, uint120 accruedNativePenalty);
    function setIsActiveAdapter(address vault, address adapter, bool newIsActiveAdapter) external;
    function setAbsoluteCap(address vault, address adapter, MarketParams calldata marketParams, uint256 newAbsoluteCap)
        external;
    function setCanDeallocate(address vault, address adapter, MarketParams calldata marketParams, bool newCanDeallocate)
        external;
    function setCanAllocateFromIdle(address vault, bool newCanDeallocate) external;
    function setNativePenalty(address vault, uint256 newNativePenalty) external;
}

/// @dev Covers the public-allocator paths of the three Blue entrypoints that consume market liquidity: borrowing
/// against fresh collateral, exiting a supply position, and migrating a borrow position.
contract BluePublicAllocatorTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LLTV_DEST = 0.9e18;
    uint256 internal constant LLTV_LIQUID = 0.95e18;

    uint256 internal constant NATIVE_PENALTY = 0.01 ether;
    uint256 internal constant VAULT_ASSETS = 100e18;

    IMorpho internal morpho;
    IVaultV2 internal vault;
    IMorphoMarketV1AdapterV2 internal adapter;
    IPublicAllocator internal publicAllocator;
    BlueBundlesV1 internal blueBundles;

    ERC20Mock internal loanToken;
    WETHMock internal weth; // collateral of every market, so native collateral can be wrapped.
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

        publicAllocator = IPublicAllocator(deployCode("BluePublicAllocator.sol:BluePublicAllocator"));
        _submitAndExec(abi.encodeCall(IVaultV2.setIsAllocator, (address(publicAllocator), true)));

        vm.startPrank(allocator);
        publicAllocator.setIsActiveAdapter(address(vault), address(adapter), true);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), marketParams, type(uint128).max);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), destMarketParams, type(uint128).max);
        publicAllocator.setCanDeallocate(address(vault), address(adapter), liquidMarketParams, true);
        publicAllocator.setCanAllocateFromIdle(address(vault), true);
        publicAllocator.setNativePenalty(address(vault), NATIVE_PENALTY);
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

    function _accruedNativePenalty() internal view returns (uint256) {
        (,, uint120 accrued) = publicAllocator.vaultData(address(vault));
        return accrued;
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
        publicAllocator.setCanDeallocate(address(vault), secondAdapter, liquidMarketParams, true);
        vm.stopPrank();
    }

    /// @dev Creates a market accruing interest, and a second adapter bound to its IRM the vault can allocate through.
    function _createInterestMarket() internal returns (MarketParams memory mp, address interestAdapter) {
        address irm = address(new IrmMock());
        vm.prank(owner);
        morpho.enableIrm(irm);
        mp = MarketParams(address(loanToken), address(weth), address(oracle), irm, LLTV);
        morpho.createMarket(mp);

        IMorphoMarketV1AdapterV2Factory factory = IMorphoMarketV1AdapterV2Factory(
            deployCode("MorphoMarketV1AdapterV2Factory.sol:MorphoMarketV1AdapterV2Factory", abi.encode(morpho, irm))
        );
        interestAdapter = factory.createMorphoMarketV1AdapterV2(address(vault));

        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (interestAdapter)));
        _increaseCaps(abi.encode("this", interestAdapter));
        _increaseCaps(abi.encode("this/marketParams", interestAdapter, mp));

        vm.startPrank(allocator);
        publicAllocator.setIsActiveAdapter(address(vault), interestAdapter, true);
        publicAllocator.setAbsoluteCap(address(vault), interestAdapter, mp, type(uint128).max);
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
        returns (PublicReallocation[] memory list)
    {
        list = new PublicReallocation[](1);
        list[0] = PublicReallocation({
            vault: address(vault),
            adapter: address(adapter),
            fromIdle: false,
            sourceAdapter: address(adapter),
            sourceMarketParams: source,
            assets: uint128(assets)
        });
    }

    function _idleReallocation(uint256 assets) internal view returns (PublicReallocation[] memory list) {
        list = new PublicReallocation[](1);
        list[0] = PublicReallocation({
            vault: address(vault),
            adapter: address(adapter),
            fromIdle: true,
            sourceAdapter: address(0),
            sourceMarketParams: MarketParams(address(0), address(0), address(0), address(0), 0),
            assets: uint128(assets)
        });
    }

    /// forge-lint: disable-end(unsafe-typecast)

    /// WITHDRAW ///

    /// @dev A fully utilized market cannot be exited without infusing liquidity first.
    function testWithdrawIlliquidRevertsWithoutReallocation() public {
        uint256 assets = 10e18;
        _supplyThenDrain(marketParams, assets);

        vm.prank(user);
        vm.expectRevert(bytes(BlueErrorsLib.INSUFFICIENT_LIQUIDITY));
        blueBundles.blueBundlesV1Withdraw(
            marketParams, assets, 0, _noAuthSig(), new PublicReallocation[](0), 0, address(0), block.timestamp
        );
    }

    /// @dev The reallocation moves the vault's allocation from the liquid market into the exited one, so the vault
    /// takes over the supply the user leaves behind.
    function testWithdrawIlliquidWithReallocation() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
        assertEq(morpho.supplyShares(marketParams.id(), user), 0, "user supply position closed");
        assertEq(_allocation(marketParams), assets, "vault took over the market");
        assertEq(_allocation(liquidMarketParams), VAULT_ASSETS - assets, "liquid market allocation reduced");
        assertEq(_accruedNativePenalty(), NATIVE_PENALTY, "penalty accrued");
        assertEq(address(blueBundles).balance, 0, "bundler native residual");
    }

    /// @dev The vault's idle assets are an equally valid liquidity source.
    function testWithdrawIlliquidWithAllocateFromIdle() public {
        uint256 assets = 10e18;
        _fundVault(0);
        _supplyThenDrain(marketParams, assets);

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
            marketParams, assets, 0, _noAuthSig(), _idleReallocation(assets), 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
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

        PublicReallocation[] memory reallocations = _reallocation(liquidMarketParams, assets);
        reallocations[0].sourceAdapter = sourceAdapter;

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
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

        PublicReallocation[] memory reallocations = new PublicReallocation[](2);
        reallocations[0] = _reallocation(liquidMarketParams, assets / 2)[0];
        reallocations[1] = _idleReallocation(assets - assets / 2)[0];

        vm.deal(user, 2 * NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: 2 * NATIVE_PENALTY}(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
        assertEq(_allocation(marketParams), assets, "vault took over the market");
        assertEq(_accruedNativePenalty(), 2 * NATIVE_PENALTY, "both penalties accrued");
    }

    /// @dev A full exit by shares needs no buffer: the withdrawal is sized on-chain, and only the market's missing
    /// liquidity is reallocated, the reallocation's assets acting as a cap.
    function testWithdrawMaxByShares() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        uint256 shares = morpho.supplyShares(marketParams.id(), user);

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
            marketParams,
            0,
            shares,
            _noAuthSig(),
            _reallocation(liquidMarketParams, VAULT_ASSETS),
            0,
            address(0),
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
        assertEq(morpho.supplyShares(marketParams.id(), user), 0, "user supply position closed");
        assertEq(_allocation(marketParams), assets, "only the missing liquidity was reallocated");
        assertEq(_allocation(liquidMarketParams), VAULT_ASSETS - assets, "liquid market allocation reduced");
    }

    /// @dev The by-shares conversion accrues interest, so a max exit stays exact when the position has grown.
    function testWithdrawMaxBySharesWithInterest() public {
        uint256 assets = 10e18;
        (MarketParams memory mp, address interestAdapter) = _createInterestMarket();
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(mp, assets);

        skip(30 days);

        uint256 shares = morpho.supplyShares(mp.id(), user);
        uint256 expectedAssets = morpho.expectedSupplyAssets(mp, user);
        assertGt(expectedAssets, assets, "interest accrued");

        PublicReallocation[] memory reallocations = _reallocation(liquidMarketParams, VAULT_ASSETS);
        reallocations[0].adapter = interestAdapter;

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
            mp, 0, shares, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), expectedAssets, "user received the accrued position");
        assertEq(morpho.supplyShares(mp.id(), user), 0, "user supply position closed, no dust");
        // The reallocation moves exactly expectedAssets; the vault's ledger can trail it by the wei the adapter loses
        // to share rounding on the supply.
        assertApproxEqAbs(
            vault.allocation(_vaultBlueId(interestAdapter, mp)),
            expectedAssets,
            1,
            "exactly the missing liquidity was reallocated"
        );
    }

    /// @dev Sizing on the down-rounded share price keeps a route capped at the exact requirement from spilling a wei
    /// into the next reallocation, whose flat penalty would dwarf the wei it moves.
    function testWithdrawMaxBySharesTightCapChargesOnePenalty() public {
        uint256 assets = 10e18;
        (MarketParams memory mp, address interestAdapter) = _createInterestMarket();
        _fundVault(VAULT_ASSETS / 2);
        _supplyThenDrain(mp, assets);

        skip(30 days);

        uint256 shares = morpho.supplyShares(mp.id(), user);
        uint256 expectedAssets = morpho.expectedSupplyAssets(mp, user);

        // The first route's cap is the exact requirement, as a frontend quoting the position would set it.
        PublicReallocation[] memory reallocations = new PublicReallocation[](2);
        reallocations[0] = _reallocation(liquidMarketParams, expectedAssets)[0];
        reallocations[0].adapter = interestAdapter;
        reallocations[1] = _idleReallocation(VAULT_ASSETS / 2)[0];
        reallocations[1].adapter = interestAdapter;

        vm.deal(user, 2 * NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: 2 * NATIVE_PENALTY}(
            mp, 0, shares, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), expectedAssets, "user received the accrued position");
        assertEq(morpho.supplyShares(mp.id(), user), 0, "user supply position closed, no dust");
        assertEq(_accruedNativePenalty(), NATIVE_PENALTY, "the second reallocation was skipped");
        assertEq(user.balance, NATIVE_PENALTY, "its penalty refunded");
    }

    /// @dev A reallocation is skipped once the previous ones cover the withdrawal, sparing its penalty.
    function testWithdrawReallocationSkippedOnceCovered() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS / 2);
        _supplyThenDrain(marketParams, assets);

        PublicReallocation[] memory reallocations = new PublicReallocation[](2);
        reallocations[0] = _reallocation(liquidMarketParams, VAULT_ASSETS / 2)[0];
        reallocations[1] = _idleReallocation(VAULT_ASSETS / 2)[0];

        vm.deal(user, 2 * NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: 2 * NATIVE_PENALTY}(
            marketParams, assets, 0, _noAuthSig(), reallocations, 0, address(0), block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
        assertEq(_allocation(marketParams), assets, "first reallocation trimmed to the missing liquidity");
        assertEq(_allocation(liquidMarketParams), VAULT_ASSETS / 2 - assets, "liquid market allocation reduced");
        assertEq(_accruedNativePenalty(), NATIVE_PENALTY, "second penalty not spent");
        assertEq(user.balance, NATIVE_PENALTY, "second penalty refunded");
    }

    /// SUPPLY COLLATERAL AND BORROW ///

    /// @dev An empty market can be borrowed from once the vault has been pushed into it.
    function testSupplyCollateralAndBorrowIlliquidWithReallocation() public {
        uint256 borrowAssets = 10e18;
        uint256 collateral = 2 * borrowAssets;
        _fundVault(VAULT_ASSETS);

        _fundWeth(user, collateral);
        vm.deal(user, NATIVE_PENALTY);
        vm.startPrank(user);
        weth.approve(address(blueBundles), type(uint256).max);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow{value: NATIVE_PENALTY}(
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

        assertEq(loanToken.balanceOf(user), borrowAssets, "user borrowed");
        assertEq(morpho.expectedBorrowAssets(marketParams, user), borrowAssets, "debt");
        assertEq(_allocation(marketParams), borrowAssets, "vault funded the borrow");
    }

    /// @dev msg.value covers the penalties first, and only the remainder is wrapped as collateral.
    function testSupplyCollateralAndBorrowWrapNativeWithPenalty() public {
        uint256 borrowAssets = 10e18;
        uint256 collateral = 2 * borrowAssets;
        _fundVault(VAULT_ASSETS);

        vm.deal(user, collateral + NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow{value: collateral + NATIVE_PENALTY}(
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

        assertEq(morpho.position(marketParams.id(), user).collateral, collateral, "collateral wrapped and supplied");
        assertEq(loanToken.balanceOf(user), borrowAssets, "user borrowed");
        assertEq(user.balance, 0, "user native residual");
        assertEq(address(blueBundles).balance, 0, "bundler native residual");
        assertEq(weth.balanceOf(address(blueBundles)), 0, "bundler wrapped residual");
    }

    /// @dev The native left after the penalties must match collateralAssets exactly.
    function testSupplyCollateralAndBorrowWrapNativeInconsistentAmount() public {
        uint256 borrowAssets = 10e18;
        uint256 collateral = 2 * borrowAssets;
        _fundVault(VAULT_ASSETS);

        vm.deal(user, collateral + NATIVE_PENALTY);
        vm.prank(user);
        vm.expectRevert(TokenLib.InconsistentAmountAndNative.selector);
        blueBundles.blueBundlesV1SupplyCollateralAndBorrow{value: collateral + NATIVE_PENALTY}(
            marketParams,
            collateral + NATIVE_PENALTY,
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
    }

    /// MIGRATE BORROW POSITION ///

    /// @dev An illiquid destination market can still be migrated into.
    function testMigrateBorrowPositionIlliquidDestWithReallocation() public {
        uint256 borrowAssets = 10e18;
        _fundVault(VAULT_ASSETS);

        // The source market is liquid so the user could borrow from it; the destination is empty.
        deal(address(loanToken), depositor, borrowAssets);
        vm.startPrank(depositor);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, borrowAssets, 0, depositor, "");
        vm.stopPrank();

        _openBorrow(marketParams, user, borrowAssets);
        uint256 collateral = morpho.position(marketParams.id(), user).collateral;

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1MigrateBorrowPosition{value: NATIVE_PENALTY}(
            marketParams,
            destMarketParams,
            type(uint256).max,
            0,
            LLTV_DEST,
            _noAuthSig(),
            _reallocation(liquidMarketParams, borrowAssets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(morpho.position(marketParams.id(), user).borrowShares, 0, "source debt closed");
        assertEq(morpho.position(marketParams.id(), user).collateral, 0, "source collateral moved");
        assertEq(morpho.position(destMarketParams.id(), user).collateral, collateral, "destination collateral");
        assertEq(morpho.expectedBorrowAssets(destMarketParams, user), borrowAssets, "destination debt");
        assertEq(_allocation(destMarketParams), borrowAssets, "vault funded the destination");
    }

    /// NATIVE ACCOUNTING ///

    /// @dev Native left unspent by the penalties is refunded, since skipped reallocations make the spend unpredictable.
    function testWithdrawUnspentNativeRefunded() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.deal(user, 2 * NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: 2 * NATIVE_PENALTY}(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
        assertEq(user.balance, NATIVE_PENALTY, "unspent native refunded");
        assertEq(_accruedNativePenalty(), NATIVE_PENALTY, "penalty accrued");
        assertEq(address(blueBundles).balance, 0, "bundler native residual");
    }

    /// @dev An allocator raising the penalty after the bundle was built makes it revert rather than overpay.
    function testWithdrawPenaltyRaisedReverts() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setNativePenalty(address(vault), 2 * NATIVE_PENALTY);

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        vm.expectRevert(IBlueBundlesV1.InsufficientNativeAssets.selector);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
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

    /// @dev With no penalty set, the entrypoints stay usable without sending any native token.
    function testWithdrawZeroPenalty() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setNativePenalty(address(vault), 0);

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

        assertEq(loanToken.balanceOf(user), assets, "user received the loan token");
    }

    /// REALLOCATION FAILURES ///

    /// @dev A reallocation the public allocator refuses fails the whole bundle.
    function testWithdrawCannotDeallocateBubbles() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setCanDeallocate(address(vault), address(adapter), liquidMarketParams, false);

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        vm.expectRevert(IPublicAllocator.CannotDeallocate.selector);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
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

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        vm.expectRevert(IPublicAllocator.InactiveAdapter.selector);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
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
    function testWithdrawAbsoluteCapExceededBubbles() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(allocator);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), marketParams, 0);

        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        vm.expectRevert(IPublicAllocator.AbsoluteCapExceeded.selector);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
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

    /// @dev The bundle can only push liquidity into the market it acts on: the destination is never caller-supplied.
    function testReallocationDestinationIsBundleMarket() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        // sourceMarketParams names the liquid market; destMarketParams is left untouched by the withdraw bundle.
        vm.deal(user, NATIVE_PENALTY);
        vm.prank(user);
        blueBundles.blueBundlesV1Withdraw{value: NATIVE_PENALTY}(
            marketParams,
            assets,
            0,
            _noAuthSig(),
            _reallocation(liquidMarketParams, assets),
            0,
            address(0),
            block.timestamp
        );

        assertEq(_allocation(marketParams), assets, "liquidity landed in the bundle's market");
        assertEq(_allocation(destMarketParams), 0, "no other market was funded");
    }
}
