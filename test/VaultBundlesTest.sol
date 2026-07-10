// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";

import {VaultBundlesV1} from "../src/vault/VaultBundlesV1.sol";
import {IVaultBundlesV1} from "../src/vault/interfaces/IVaultBundlesV1.sol";
import {TokenPermit, PermitKind} from "../src/libraries/TokenLib.sol";

// The generic ERC-4626 handle, satisfied by both Vault V1 (MetaMorpho) and Vault V2.
import {IERC4626} from "../lib/vault-v2/src/interfaces/IERC4626.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";

// Vault V1 (MetaMorpho) is set up over its own (nested) morpho-blue, so Morpho, MetaMorpho and this test share a
// single market type.
import {IMetaMorpho} from "../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IMorpho, MarketParams, Id} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {ORACLE_PRICE_SCALE} from "../lib/metamorpho/lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {OracleMock} from "../lib/metamorpho/lib/morpho-blue/src/mocks/OracleMock.sol";

contract VaultBundlesTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant TIMELOCK = 1 days;
    uint256 internal constant RAY = 1e27;

    uint256 internal constant MIN_ASSETS = 1;
    uint256 internal constant MAX_ASSETS = 1e24;

    IMorpho internal morpho;
    VaultBundlesV1 internal bundles;
    IVaultV2Factory internal vaultV2Factory;

    ERC20Mock internal loanToken;
    ERC20Mock internal collateralToken;
    ERC20Mock internal otherToken;
    OracleMock internal oracle;

    MarketParams internal marketParams;

    // Two vaults per version share the loan token, so any (source, destination) migration pair can be built.
    IERC4626 internal vaultV1;
    IERC4626 internal vaultV1b;
    IERC4626 internal vaultV2;
    IERC4626 internal vaultV2b;
    IERC4626 internal vaultOther; // Vault V2 over a different asset, for the asset-consistency check.

    address internal owner = makeAddr("owner");

    // This contract is the user: it owns positions and grants the bundler its allowances.
    address internal user = address(this);

    TokenPermit internal noPermit = TokenPermit(PermitKind.None, "");

    function setUp() public {
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        loanToken = new ERC20Mock(18);
        collateralToken = new ERC20Mock(18);
        otherToken = new ERC20Mock(18);
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        vm.startPrank(owner);
        morpho.enableIrm(address(0));
        morpho.enableLltv(LLTV);
        vm.stopPrank();

        marketParams = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), LLTV);
        morpho.createMarket(marketParams);

        bundles = new VaultBundlesV1();
        vaultV2Factory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));

        vaultV1 = _deployMetaMorpho();
        vaultV1b = _deployMetaMorpho();
        vaultV2 = _deployVaultV2(loanToken, bytes32(uint256(1)));
        vaultV2b = _deployVaultV2(loanToken, bytes32(uint256(2)));
        vaultOther = _deployVaultV2(otherToken, bytes32(uint256(3)));

        // The user lets the bundler pull its loan token for deposits.
        loanToken.approve(address(bundles), type(uint256).max);
    }

    /// HELPERS ///

    function _deployMetaMorpho() internal returns (IERC4626) {
        address vault = deployCode(
            "MetaMorpho.sol:MetaMorpho", abi.encode(owner, address(morpho), TIMELOCK, address(loanToken), "V1", "V1")
        );

        Id[] memory queue = new Id[](1);
        queue[0] = marketParams.id();

        vm.startPrank(owner);
        IMetaMorpho(vault).submitCap(marketParams, type(uint184).max);
        vm.warp(block.timestamp + TIMELOCK);
        IMetaMorpho(vault).acceptCap(marketParams);
        IMetaMorpho(vault).setSupplyQueue(queue);
        vm.stopPrank();

        return IERC4626(vault);
    }

    function _deployVaultV2(ERC20Mock asset, bytes32 salt) internal returns (IERC4626) {
        return IERC4626(vaultV2Factory.createVaultV2(owner, address(asset), salt));
    }

    /// @dev The user deposits `assets` into `vault` directly and approves the bundler over the resulting shares, as
    /// required by withdraw and migrate.
    function _deposited(IERC4626 vault, uint256 assets) internal {
        deal(address(loanToken), user, assets);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets, user);
        vault.approve(address(bundles), type(uint256).max);
        deal(address(loanToken), user, 0);
    }

    /// DEPOSIT ///

    function testDepositV1(uint256 assets) public {
        _testDeposit(vaultV1, assets);
    }

    function testDepositV2(uint256 assets) public {
        _testDeposit(vaultV2, assets);
    }

    function _testDeposit(IERC4626 vault, uint256 assets) internal {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        deal(address(loanToken), user, assets);

        bundles.vaultBundlesV1Deposit(address(vault), assets, RAY, noPermit, block.timestamp);

        assertEq(loanToken.balanceOf(user), 0, "user loan token");
        assertEq(loanToken.balanceOf(address(bundles)), 0, "bundler loan token");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(user)), assets, 1, "user position");
    }

    function testDepositSlippageV1() public {
        _testDepositSlippage(vaultV1);
    }

    function testDepositSlippageV2() public {
        _testDepositSlippage(vaultV2);
    }

    function _testDepositSlippage(IERC4626 vault) internal {
        uint256 assets = 100e18;
        deal(address(loanToken), user, assets);

        // Realized share price is ~1e27, so a 1 wei-per-share cap is always exceeded.
        vm.expectRevert(IVaultBundlesV1.SlippageExceeded.selector);
        bundles.vaultBundlesV1Deposit(address(vault), assets, 1, noPermit, block.timestamp);
    }

    function testDepositDeadline() public {
        deal(address(loanToken), user, 1e18);
        vm.expectRevert(IVaultBundlesV1.DeadlinePassed.selector);
        bundles.vaultBundlesV1Deposit(address(vaultV1), 1e18, RAY, noPermit, block.timestamp - 1);
    }

    /// WITHDRAW ///

    function testWithdrawV1(uint256 assets) public {
        _testWithdraw(vaultV1, assets);
    }

    function testWithdrawV2(uint256 assets) public {
        _testWithdraw(vaultV2, assets);
    }

    function _testWithdraw(IERC4626 vault, uint256 assets) internal {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _deposited(vault, assets);

        bundles.vaultBundlesV1Withdraw(address(vault), assets, 0, 0, block.timestamp);

        assertEq(loanToken.balanceOf(user), assets, "user loan token");
        assertEq(loanToken.balanceOf(address(bundles)), 0, "bundler loan token");
        assertApproxEqAbs(vault.balanceOf(user), 0, 1, "user shares");
    }

    function testWithdrawAllV1(uint256 assets) public {
        _testWithdrawAll(vaultV1, assets);
    }

    function testWithdrawAllV2(uint256 assets) public {
        _testWithdrawAll(vaultV2, assets);
    }

    // Passing the sender's full share balance redeems its entire position.
    function _testWithdrawAll(IERC4626 vault, uint256 assets) internal {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _deposited(vault, assets);

        bundles.vaultBundlesV1Withdraw(address(vault), 0, vault.balanceOf(user), 0, block.timestamp);

        assertApproxEqAbs(loanToken.balanceOf(user), assets, 1, "user loan token");
        assertEq(loanToken.balanceOf(address(bundles)), 0, "bundler loan token");
        assertEq(vault.balanceOf(user), 0, "user shares");
    }

    function testWithdrawRequiresApprovalV1() public {
        _testWithdrawRequiresApproval(vaultV1);
    }

    function testWithdrawRequiresApprovalV2() public {
        _testWithdrawRequiresApproval(vaultV2);
    }

    function _testWithdrawRequiresApproval(IERC4626 vault) internal {
        uint256 assets = 100e18;
        deal(address(loanToken), user, assets);
        loanToken.approve(address(vault), type(uint256).max);
        vault.deposit(assets, user);
        // No approval of the bundler over the vault shares.

        vm.expectRevert();
        bundles.vaultBundlesV1Withdraw(address(vault), assets, 0, 0, block.timestamp);
    }

    function testWithdrawSlippageV1() public {
        _testWithdrawSlippage(vaultV1);
    }

    function testWithdrawSlippageV2() public {
        _testWithdrawSlippage(vaultV2);
    }

    function _testWithdrawSlippage(IERC4626 vault) internal {
        uint256 assets = 100e18;
        _deposited(vault, assets);

        // Realized share price is ~1e27, always below a max-uint floor.
        vm.expectRevert(IVaultBundlesV1.SlippageExceeded.selector);
        bundles.vaultBundlesV1Withdraw(address(vault), assets, 0, type(uint256).max, block.timestamp);
    }

    function testWithdrawNotExactlyOneZero() public {
        _deposited(vaultV1, 100e18);

        // Both assets and shares non-zero.
        vm.expectRevert(IVaultBundlesV1.NotExactlyOneZero.selector);
        bundles.vaultBundlesV1Withdraw(address(vaultV1), 100e18, 1, 0, block.timestamp);

        // Both assets and shares zero.
        vm.expectRevert(IVaultBundlesV1.NotExactlyOneZero.selector);
        bundles.vaultBundlesV1Withdraw(address(vaultV1), 0, 0, 0, block.timestamp);
    }

    function testWithdrawDeadline() public {
        _deposited(vaultV1, 100e18);
        vm.expectRevert(IVaultBundlesV1.DeadlinePassed.selector);
        bundles.vaultBundlesV1Withdraw(address(vaultV1), 100e18, 0, 0, block.timestamp - 1);
    }

    /// MIGRATE ///

    function testMigrateV1toV2(uint256 assets) public {
        _testMigrate(vaultV1, vaultV2, assets);
    }

    function testMigrateV2toV1(uint256 assets) public {
        _testMigrate(vaultV2, vaultV1, assets);
    }

    function testMigrateV1toV1(uint256 assets) public {
        _testMigrate(vaultV1, vaultV1b, assets);
    }

    function testMigrateV2toV2(uint256 assets) public {
        _testMigrate(vaultV2, vaultV2b, assets);
    }

    function _testMigrate(IERC4626 source, IERC4626 dest, uint256 assets) internal {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _deposited(source, assets);

        bundles.vaultBundlesV1Migrate(address(source), address(dest), assets, 0, 0, RAY, block.timestamp);

        assertApproxEqAbs(source.balanceOf(user), 0, 1, "source shares");
        assertApproxEqAbs(dest.convertToAssets(dest.balanceOf(user)), assets, 1, "dest position");
        assertEq(loanToken.balanceOf(address(bundles)), 0, "bundler loan token");
        assertEq(loanToken.balanceOf(user), 0, "user loan token");
    }

    function testMigrateAllV1toV2(uint256 assets) public {
        _testMigrateAll(vaultV1, vaultV2, assets);
    }

    function testMigrateAllV2toV1(uint256 assets) public {
        _testMigrateAll(vaultV2, vaultV1, assets);
    }

    function testMigrateAllV1toV1(uint256 assets) public {
        _testMigrateAll(vaultV1, vaultV1b, assets);
    }

    function testMigrateAllV2toV2(uint256 assets) public {
        _testMigrateAll(vaultV2, vaultV2b, assets);
    }

    // Passing the sender's full sourceVault share balance redeems its entire position before depositing into destVault.
    function _testMigrateAll(IERC4626 source, IERC4626 dest, uint256 assets) internal {
        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
        _deposited(source, assets);

        bundles.vaultBundlesV1Migrate(
            address(source), address(dest), 0, source.balanceOf(user), 0, RAY, block.timestamp
        );

        assertEq(source.balanceOf(user), 0, "source shares");
        assertApproxEqAbs(dest.convertToAssets(dest.balanceOf(user)), assets, 2, "dest position");
        assertEq(loanToken.balanceOf(address(bundles)), 0, "bundler loan token");
        assertEq(loanToken.balanceOf(user), 0, "user loan token");
    }

    function testMigrateInconsistentAssets() public {
        _deposited(vaultV1, 100e18);
        vm.expectRevert(IVaultBundlesV1.InconsistentAssets.selector);
        bundles.vaultBundlesV1Migrate(address(vaultV1), address(vaultOther), 100e18, 0, 0, RAY, block.timestamp);
    }

    function testMigrateNotExactlyOneZero() public {
        _deposited(vaultV1, 100e18);

        // Both assets and shares non-zero.
        vm.expectRevert(IVaultBundlesV1.NotExactlyOneZero.selector);
        bundles.vaultBundlesV1Migrate(address(vaultV1), address(vaultV2), 100e18, 1, 0, RAY, block.timestamp);

        // Both assets and shares zero.
        vm.expectRevert(IVaultBundlesV1.NotExactlyOneZero.selector);
        bundles.vaultBundlesV1Migrate(address(vaultV1), address(vaultV2), 0, 0, 0, RAY, block.timestamp);
    }

    function testMigrateSlippageSource() public {
        _deposited(vaultV1, 100e18);
        vm.expectRevert(IVaultBundlesV1.SlippageExceeded.selector);
        bundles.vaultBundlesV1Migrate(
            address(vaultV1), address(vaultV2), 100e18, 0, type(uint256).max, RAY, block.timestamp
        );
    }

    function testMigrateSlippageDest() public {
        _deposited(vaultV1, 100e18);
        vm.expectRevert(IVaultBundlesV1.SlippageExceeded.selector);
        bundles.vaultBundlesV1Migrate(address(vaultV1), address(vaultV2), 100e18, 0, 0, 1, block.timestamp);
    }

    function testMigrateDeadline() public {
        _deposited(vaultV1, 100e18);
        vm.expectRevert(IVaultBundlesV1.DeadlinePassed.selector);
        bundles.vaultBundlesV1Migrate(
            address(vaultV1), address(vaultV2), 100e18, 0, 0, RAY, block.timestamp - 1
        );
    }
}
