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
import {IBlueBundlesV1, SignedAuthorization, PublicReallocation} from "../src/blue/interfaces/IBlueBundlesV1.sol";
import {TokenLib, TokenPermit} from "../src/libraries/TokenLib.sol";
import {WETHMock} from "./BlueBundlesTest.sol";

/// @dev Handle on the vendored public allocator (see test/vendor), which is deployed through deployCode so that its
/// own compiler settings do not leak into this file's compilation unit.
interface IPublicAllocator {
    error AbsoluteCapExceeded();
    error CannotDeallocate();

    function accruedNativePenalty(address vault) external view returns (uint256);
    function setAbsoluteCap(address vault, address adapter, MarketParams calldata marketParams, uint256 newAbsoluteCap)
        external;
    function setCanDeallocate(address vault, address adapter, MarketParams calldata marketParams, bool newCanDeallocate)
        external;
    function setCanDeallocateFromIdle(address vault, bool newCanDeallocate) external;
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

        publicAllocator = IPublicAllocator(
            deployCode(
                "BlueAdapterV2PublicAllocator.sol:BlueAdapterV2PublicAllocator", abi.encode(address(adapterFactory))
            )
        );
        _submitAndExec(abi.encodeCall(IVaultV2.setIsAllocator, (address(publicAllocator), true)));

        vm.startPrank(allocator);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), marketParams, type(uint128).max);
        publicAllocator.setAbsoluteCap(address(vault), address(adapter), destMarketParams, type(uint128).max);
        publicAllocator.setCanDeallocate(address(vault), address(adapter), liquidMarketParams, true);
        publicAllocator.setCanDeallocateFromIdle(address(vault), true);
        vm.stopPrank();

        vm.prank(curator);
        publicAllocator.setNativePenalty(address(vault), NATIVE_PENALTY);

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
    function _vaultBlueId(MarketParams memory mp) internal view returns (bytes32) {
        return keccak256(abi.encode("this/marketParams", address(adapter), mp));
    }

    function _allocation(MarketParams memory mp) internal view returns (uint256) {
        return vault.allocation(_vaultBlueId(mp));
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
        assertEq(publicAllocator.accruedNativePenalty(address(vault)), NATIVE_PENALTY, "penalty accrued");
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
        assertEq(publicAllocator.accruedNativePenalty(address(vault)), 2 * NATIVE_PENALTY, "both penalties accrued");
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

    /// @dev Native left unspent by the penalties would be stuck in the bundler, so it reverts instead.
    function testWithdrawUnspentNativeAssets() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.deal(user, 2 * NATIVE_PENALTY);
        vm.prank(user);
        vm.expectRevert(IBlueBundlesV1.UnspentNativeAssets.selector);
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
    }

    /// @dev A curator raising the penalty after the bundle was built makes it revert rather than overpay.
    function testWithdrawPenaltyRaisedReverts() public {
        uint256 assets = 10e18;
        _fundVault(VAULT_ASSETS);
        _supplyThenDrain(marketParams, assets);

        vm.prank(curator);
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

        vm.prank(curator);
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

    /// @dev A sentinel cutting the destination's absolute cap to zero blocks the public inflow.
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
