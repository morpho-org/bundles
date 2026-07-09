// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVaultBundlesV1} from "./interfaces/IVaultBundlesV1.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {IERC4626} from "../../lib/vault-v2/src/interfaces/IERC4626.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

/// @dev Designed for Morpho Vault V1 (MetaMorpho) and Morpho Vault V2.
/// @dev Inherits the token safety requirements of the vaults and their dependencies.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev Gated vaults (Vault V2) require this contract to be permitted by the relevant gates.
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract VaultBundlesV1 is IVaultBundlesV1 {
    using UtilsLib for uint256;

    /// EXTERNAL ///

    /// @dev Pulls `assets` of the vault asset from msg.sender (optionally via ERC-2612 or Permit2) and deposits them into `vault` for onBehalf.
    /// @dev maxSharePriceE27 upper-bounds the realized deposit share price (deposited assets per share, scaled by 1e27).
    function vaultBundlesV1Deposit(
        address vault,
        uint256 assets,
        uint256 maxSharePriceE27,
        address onBehalf,
        TokenPermit memory assetPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        address asset = IERC4626(vault).asset();
        TokenLib.pullToken(asset, msg.sender, assets, assetPermit);
        TokenLib.forceApproveMax(asset, vault);

        uint256 shares = IERC4626(vault).deposit(assets, onBehalf);
        require(assets.mulDivUp(1e27, shares) <= maxSharePriceE27, SlippageExceeded());
    }

    /// @dev Withdraws from msg.sender's position in the vault and sends the withdrawn assets to receiver.
    /// @dev Requires the sender to have given enough allowance over its vault shares to this contract. Using max allowance makes sure that this condition is met.
    /// @dev If assets is type(uint256).max, the sender's entire position in the vault is withdrawn.
    /// @dev minSharePriceE27 lower-bounds the realized withdraw share price (withdrawn assets per share, scaled by 1e27).
    function vaultBundlesV1Withdraw(
        address vault,
        uint256 assets,
        uint256 minSharePriceE27,
        address receiver,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        uint256 assetsWithdrawn;
        uint256 sharesRedeemed;
        if (assets == type(uint256).max) {
            sharesRedeemed = IERC4626(vault).balanceOf(msg.sender);
            assetsWithdrawn = IERC4626(vault).redeem(sharesRedeemed, receiver, msg.sender);
        } else {
            sharesRedeemed = IERC4626(vault).withdraw(assets, receiver, msg.sender);
            assetsWithdrawn = assets;
        }
        require(assetsWithdrawn.mulDivDown(1e27, sharesRedeemed) >= minSharePriceE27, SlippageExceeded());
    }

    /// @dev Migrates msg.sender's position in sourceVault to a position in destVault for onBehalf, by withdrawing them from sourceVault (routed via this contract) then depositing them into destVault.
    /// @dev sourceVault and destVault can each be a Vault V1 or a Vault V2. Migrating from a Vault V2 to a Vault V1 is not prevented, even though it is not expected to be useful.
    /// @dev Requires the sender to have given enough allowance over its sourceVault shares to this contract. Using max allowance makes sure that this condition is met.
    /// @dev The two vaults must share the same asset.
    /// @dev If assets is type(uint256).max, the sender's entire position in sourceVault is withdrawn.
    /// @dev minSharePriceE27 lower-bounds the realized sourceVault withdraw share price; maxSharePriceE27 upper-bounds the realized destVault deposit share price (both assets per share, scaled by 1e27).
    function vaultBundlesV1Migrate(
        address sourceVault,
        address destVault,
        uint256 assets,
        uint256 minSharePriceE27,
        uint256 maxSharePriceE27,
        address onBehalf,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        address asset = IERC4626(sourceVault).asset();
        require(asset == IERC4626(destVault).asset(), InconsistentAssets());

        uint256 assetsWithdrawn;
        uint256 sharesRedeemed;
        if (assets == type(uint256).max) {
            sharesRedeemed = IERC4626(sourceVault).balanceOf(msg.sender);
            assetsWithdrawn = IERC4626(sourceVault).redeem(sharesRedeemed, address(this), msg.sender);
        } else {
            sharesRedeemed = IERC4626(sourceVault).withdraw(assets, address(this), msg.sender);
            assetsWithdrawn = assets;
        }
        require(assetsWithdrawn.mulDivDown(1e27, sharesRedeemed) >= minSharePriceE27, SlippageExceeded());

        TokenLib.forceApproveMax(asset, destVault);
        uint256 sharesMinted = IERC4626(destVault).deposit(assetsWithdrawn, onBehalf);
        require(assetsWithdrawn.mulDivUp(1e27, sharesMinted) <= maxSharePriceE27, SlippageExceeded());
    }
}
