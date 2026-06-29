// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {Permit2 as VendorPermit2} from "../lib/midnight/test/vendor/Permit2.sol";
import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AaveMigrationBundlesV1} from "../src/aave-migration/AaveMigrationBundlesV1.sol";
import {IAaveMigrationBundlesV1} from "../src/aave-migration/IAaveMigrationBundlesV1.sol";
import {TokenPermit, PermitKind} from "../src/libraries/TokenLib.sol";

contract AaveMigrationBundlesTest is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    AaveMigrationBundlesV1 internal bundles;
    AaveV3PoolMock internal pool;
    TokenMock internal asset;
    ATokenMock internal aToken;
    IVaultV2Factory internal vaultFactory;
    IVaultV2 internal vault;

    address internal owner;
    address internal user;
    address internal receiver;
    mapping(address => uint256) internal privateKey;

    function setUp() public {
        owner = makeAddr("owner");
        receiver = makeAddr("receiver");
        uint256 userPk;
        (user, userPk) = makeAddrAndKey("user");
        privateKey[user] = userPk;

        asset = new TokenMock("asset", "asset");
        aToken = new ATokenMock("aToken", "aToken", address(asset));
        pool = new AaveV3PoolMock();
        pool.setAToken(address(asset), aToken);

        vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
        vault = IVaultV2(vaultFactory.createVaultV2(owner, address(asset), bytes32(0)));

        bundles = new AaveMigrationBundlesV1();
        deployCodeTo("Permit2", PERMIT2);
    }

    /// HELPERS ///

    function _noPermit() internal pure returns (TokenPermit memory) {}

    /// @dev Mints `amount` of aTokens to `onBehalf` and funds the pool with the matching underlying liquidity.
    function _openAavePosition(address onBehalf, uint256 amount) internal {
        aToken.mint(onBehalf, amount);
        asset.mint(address(pool), amount);
    }

    function _permit(address token, address holder, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (TokenPermit memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(ERC20Permit(token).PERMIT_TYPEHASH(), holder, address(bundles), amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey[holder], digest);
        return TokenPermit({kind: PermitKind.ERC2612, data: abi.encode(deadline, v, r, s)});
    }

    function _permit2(address token, address holder, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (TokenPermit memory)
    {
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                tokenPermissionsHash,
                address(bundles),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", VendorPermit2(PERMIT2).DOMAIN_SEPARATOR(), permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey[holder], digest);
        return TokenPermit({kind: PermitKind.Permit2, data: abi.encode(nonce, deadline, abi.encodePacked(r, s, v))});
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

    /// @dev Vault V2 deposit is permissionless: a third-party payer can migrate their Aave position into onBehalf's
    /// vault account. The aTokens are pulled from the caller, the vault shares accrue to onBehalf.
    function testWithdrawAndDepositIsPermissionless(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        address payer = makeAddr("payer");
        _openAavePosition(payer, amount);
        uint256 expectedShares = vault.previewDeposit(amount);

        vm.startPrank(payer);
        aToken.approve(address(bundles), amount);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            address(pool), address(aToken), amount, address(vault), user, _noPermit(), block.timestamp
        );
        vm.stopPrank();

        _assertMigrated(payer, user, expectedShares, amount);
    }

    function testWithdrawAndDepositInVaultV2Permit() public {
        uint256 amount = 100e18;
        _openAavePosition(user, amount);
        uint256 expectedShares = vault.previewDeposit(amount);

        TokenPermit memory permit = _permit(address(aToken), user, amount, 0, vm.getBlockTimestamp() + 1);
        vm.prank(user);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            address(pool), address(aToken), amount, address(vault), user, permit, block.timestamp
        );

        assertEq(aToken.allowance(user, address(bundles)), 0, "permit allowance consumed");
        _assertMigrated(user, user, expectedShares, amount);
    }

    function testWithdrawAndDepositInVaultV2Permit2() public {
        uint256 amount = 100e18;
        _openAavePosition(user, amount);
        uint256 expectedShares = vault.previewDeposit(amount);

        vm.prank(user);
        aToken.approve(PERMIT2, amount);

        TokenPermit memory permit = _permit2(address(aToken), user, amount, 0, vm.getBlockTimestamp() + 1);
        vm.prank(user);
        bundles.aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
            address(pool), address(aToken), amount, address(vault), user, permit, block.timestamp
        );

        assertEq(aToken.allowance(user, PERMIT2), 0, "permit2 allowance consumed");
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

/// @dev Minimal mintable/burnable ERC-2612 token used for both the underlying and the aToken.
contract TokenMock is ERC20Permit {
    constructor(string memory name_, string memory symbol_) ERC20Permit(name_, symbol_) {}

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
        ERC20(underlying).transfer(to, amount);
        return amount;
    }
}
