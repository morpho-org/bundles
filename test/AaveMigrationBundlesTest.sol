// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AaveMigrationBundlesV1} from "../src/aave-migration/AaveMigrationBundlesV1.sol";
import {IAaveMigrationBundlesV1} from "../src/aave-migration/IAaveMigrationBundlesV1.sol";
import {TokenPermit} from "../src/libraries/TokenLib.sol";

contract AaveMigrationBundlesTest is Test {
    AaveMigrationBundlesV1 internal bundles;
    AaveV3PoolMock internal pool;
    TokenMock internal asset;
    ATokenMock internal aToken;
    IVaultV2Factory internal vaultFactory;
    IVaultV2 internal vault;

    address internal owner;
    address internal user;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        asset = new TokenMock("asset", "asset");
        aToken = new ATokenMock("aToken", "aToken", address(asset));
        pool = new AaveV3PoolMock();
        pool.setAToken(address(asset), aToken);

        vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
        vault = IVaultV2(vaultFactory.createVaultV2(owner, address(asset), bytes32(0)));

        bundles = new AaveMigrationBundlesV1();
    }

    /// HELPERS ///

    function _noPermit() internal pure returns (TokenPermit memory) {}

    /// @dev Mints `amount` of aTokens to `onBehalf` and funds the pool with the matching underlying liquidity.
    function _openAavePosition(address onBehalf, uint256 amount) internal {
        aToken.mint(onBehalf, amount);
        asset.mint(address(pool), amount);
    }

    /// @dev Asserts the full pulled position landed in the vault for `onBehalf` and that nothing is left behind.
    function _assertMigrated(address payer, address onBehalf, uint256 expectedShares, uint256 amount) internal view {
        assertEq(aToken.balanceOf(payer), 0, "payer aToken balance");
        assertEq(vault.balanceOf(onBehalf), expectedShares, "onBehalf vault shares");
        assertEq(asset.balanceOf(address(vault)), amount, "vault assets");
        assertEq(asset.balanceOf(address(bundles)), 0, "bundler asset residual");
        assertEq(aToken.balanceOf(address(bundles)), 0, "bundler aToken residual");
    }

    /// WITHDRAW AND DEPOSIT IN VAULT V2 ///

    function testWithdrawAndDepositInVaultV2(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _openAavePosition(user, amount);
        uint256 expectedShares = vault.previewDeposit(amount);

        vm.startPrank(user);
        aToken.approve(address(bundles), amount);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            address(pool), address(aToken), amount, address(vault), user, _noPermit(), block.timestamp
        );
        vm.stopPrank();

        _assertMigrated(user, user, expectedShares, amount);
    }

    /// @dev The vault's asset must match the aToken's underlying, otherwise the wrong token would be withdrawn.
    function testInconsistentTokens() public {
        TokenMock otherAsset = new TokenMock("other", "other");
        ATokenMock otherAToken = new ATokenMock("otherA", "otherA", address(otherAsset));

        vm.prank(user);
        vm.expectRevert(IAaveMigrationBundlesV1.InconsistentTokens.selector);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            address(pool), address(otherAToken), 1, address(vault), user, _noPermit(), block.timestamp
        );
    }

    function testDeadlinePassed() public {
        uint256 past = block.timestamp - 1;

        vm.prank(user);
        vm.expectRevert(IAaveMigrationBundlesV1.DeadlinePassed.selector);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            address(pool), address(aToken), 1, address(vault), user, _noPermit(), past
        );
    }
}

/// @dev Minimal mintable/burnable token used for both the underlying and the aToken.
contract TokenMock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/// @dev Aave V3 aToken: tracks its underlying so the bundler can cross-check it against the vault's asset.
contract ATokenMock is TokenMock {
    address public immutable UNDERLYING;

    constructor(string memory name_, string memory symbol_, address underlying) TokenMock(name_, symbol_) {
        UNDERLYING = underlying;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return UNDERLYING;
    }
}

/// @dev Aave V3 pool: burns the caller's aTokens 1:1 and pays out the underlying it holds.
contract AaveV3PoolMock {
    mapping(address => ATokenMock) public aToken;

    function setAToken(address underlying, ATokenMock _aToken) external {
        aToken[underlying] = _aToken;
    }

    function withdraw(address underlying, uint256 amount, address to) external returns (uint256) {
        ATokenMock _aToken = aToken[underlying];
        if (amount == type(uint256).max) amount = _aToken.balanceOf(msg.sender);
        _aToken.burn(msg.sender, amount);
        bool success = ERC20(underlying).transfer(to, amount);
        require(success, "transfer failed");
        return amount;
    }
}
