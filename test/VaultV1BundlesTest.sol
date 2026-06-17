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
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultBundles} from "../src/vault/VaultBundles.sol";
import {IVaultBundles} from "../src/vault/IVaultBundles.sol";

// MetaMorpho (Vault V1) ships its own nested morpho-blue, so its market types are distinct from the ones above.
import {IMetaMorpho} from "../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {MarketParams as MMMarketParams, Id as MMId} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    MarketParamsLib as MMMarketParamsLib
} from "../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";

contract VaultV1BundlesTest is Test {
    using MarketParamsLib for MarketParams;
    using MMMarketParamsLib for MMMarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant LLTV_1 = 0.8e18;
    uint256 internal constant LLTV_2 = 0.9e18;

    uint256 internal constant MIN_ASSETS = 2;
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    IMetaMorpho internal vault;
    VaultBundles internal vaultBundles;

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

        vaultBundles = new VaultBundles(address(morpho));
        assertEq(vaultBundles.BLUE(), address(morpho));
    }

    /// HELPERS ///

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
        MMMarketParams memory mmMarketParams =
            MMMarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), LLTV_1);
        MMId[] memory queue = new MMId[](1);
        queue[0] = mmMarketParams.id();
        vm.startPrank(owner);
        vault.submitCap(mmMarketParams, type(uint184).max);
        vm.warp(block.timestamp + 1 days);
        vault.acceptCap(mmMarketParams);
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

        // onBehalf (this contract) authorizes the bundler to move its vault shares.
        vault.approve(address(vaultBundles), type(uint256).max);

        // Sanity: the depositor still "owns" ~assets worth of shares but holds no loan token.
        deal(address(loanToken), address(this), 0);
    }

    /// AUTHORIZATION & VALIDATION ///

    function testForceWithdrawUnauthorized() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IVaultBundles.Unauthorized.selector);
        vaultBundles.forceWithdrawIlliquidVaultV1(address(vault), marketParams, address(this), assets, block.timestamp);
    }

    function testOnMorphoFlashLoanOnlyBlue() public {
        vm.expectRevert(IVaultBundles.Unauthorized.selector);
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

        vaultBundles.forceWithdrawIlliquidVaultV1(address(vault), marketParams, address(this), assets, block.timestamp);

        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
        // Vault V1 has no force deallocate: the user leaves with an in-kind supply position on the market.
        assertApproxEqAbs(morpho.expectedSupplyAssets(marketParams, address(this)), assets, 1, "supply position");
        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
    }

    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
    function testForceWithdrawIlliquidDeadlinePassed() public {
        uint256 assets = 100e18;
        _setUpIlliquid(assets);

        vm.expectRevert(IVaultBundles.DeadlinePassed.selector);
        vaultBundles.forceWithdrawIlliquidVaultV1(
            address(vault), marketParams, address(this), assets, block.timestamp - 1
        );
    }
}
