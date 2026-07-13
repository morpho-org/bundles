// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AaveMigrationBundlesV1} from "../src/aave-migration/AaveMigrationBundlesV1.sol";
import {IAaveMigrationBundlesV1} from "../src/aave-migration/interfaces/IAaveMigrationBundlesV1.sol";
import {TokenPermit} from "../src/libraries/TokenLib.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract AaveMigrationBundlesForkTest is Test {
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant FORK_BLOCK = 25_400_000;

    AaveMigrationBundlesV1 internal bundles;
    IVaultV2Factory internal vaultFactory;
    IVaultV2 internal vault;

    address internal owner;
    address internal user;

    function setUp() public {
        // Create a fork of Ethereum at the given block, requiring to use Alchemy RPC.
        vm.createSelectFork(vm.toString(uint256(1)), FORK_BLOCK);

        owner = makeAddr("owner");
        user = makeAddr("user");

        vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
        vault = IVaultV2(vaultFactory.createVaultV2(owner, USDC, bytes32(0)));

        bundles = new AaveMigrationBundlesV1();
    }

    /// HELPERS ///

    function _noPermit() internal pure returns (TokenPermit memory) {}

    function testWithdrawAndDepositInVaultV2(uint256 usdcAmount, uint256 aTokenAmount) public {
        usdcAmount = bound(usdcAmount, 1e6, 1_000_000e6);
        deal(USDC, user, usdcAmount);
        vm.startPrank(user);
        IERC20(USDC).approve(AAVE_V3_POOL, usdcAmount);
        IAavePool(AAVE_V3_POOL).supply(USDC, usdcAmount, user, 0);
        vm.stopPrank();

        uint256 aTokenBalance = IERC20(A_USDC).balanceOf(user);
        // Kept above dust so Aave's rebasing rounding (a few wei) stays negligible relative to the amount.
        aTokenAmount = bound(aTokenAmount, 1e5, aTokenBalance);

        // The underlying withdrawn from Aave matches aTokenAmount up to rebasing rounding.
        uint256 expectedShares = vault.previewDeposit(aTokenAmount);

        vm.startPrank(user);
        IERC20(A_USDC).approve(address(bundles), aTokenAmount);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            AAVE_V3_POOL, A_USDC, aTokenAmount, address(vault), type(uint256).max, user, _noPermit(), block.timestamp
        );
        vm.stopPrank();

        assertApproxEqAbs(IERC20(A_USDC).balanceOf(user), aTokenBalance - aTokenAmount, 2, "user aToken balance");
        assertApproxEqRel(vault.balanceOf(user), expectedShares, 0.0001e18, "user vault shares");
        assertApproxEqRel(IERC20(USDC).balanceOf(address(vault)), aTokenAmount, 0.0001e18, "vault assets");
        assertEq(IERC20(USDC).balanceOf(address(bundles)), 0, "bundler asset residual");
        assertEq(IERC20(A_USDC).balanceOf(address(bundles)), 0, "bundler aToken residual");
    }
}
