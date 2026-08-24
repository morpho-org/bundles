// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVaultBundlesV1, Permit} from "./interfaces/IVaultBundlesV1.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {IERC4626} from "../../lib/vault-v2/src/interfaces/IERC4626.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";

/// @dev Designed and audited for Vault V1 (MetaMorpho V1 or V1.1) and Vault V2.
/// @dev Adapters of Vault V2 that are used with this contract must be either MorphoMarketV1AdapterV2 or MorphoVaultV1Adapter.
/// @dev Inherits the token safety requirements of the vaults and their dependencies.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev The sendAssetsGate of vaults (V2) that are used with this contract must go through when this contract deposits the assets. The gate can query the bundle's initiator thanks to the exposed transient variable.
/// @dev The receiveAssetsGate of vaults (V2) that are used with this contract must go through when this contract receives the withdrawn assets. The gate can query the bundle's initiator thanks to the exposed transient variable.
/// @dev This contract can approve tokens to arbitrary addresses. This is safe because a token amount pulled is always fully spent in the same transaction, and because the only tokens pulled to this contract are owned by msg.sender.
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
contract VaultBundlesV1 is IVaultBundlesV1 {
    using UtilsLib for uint256;

    address public transient initiator;

    /// EXTERNAL ///

    /// @dev Pulls assets of the vault asset from msg.sender (optionally via ERC-2612 or Permit2) and deposits them into vault.
    /// @dev When native tokens are sent, assetPermit.kind must be PermitKind.None and assets must equal msg.value; the native tokens are wrapped into the vault asset (which must be the wrapped-native token) instead of being pulled.
    /// @dev The referral fee is deducted from assets; the remainder is deposited into vault for msg.sender.
    /// @dev Fee = assets * referralFeePct / WAD; deposited = assets - fee.
    /// @dev maxSharePriceE27 upper-bounds the realized deposit share price (deposited assets per share, scaled by 1e27).
    function vaultBundlesV1Deposit(
        address vault,
        uint256 assets,
        uint256 maxSharePriceE27,
        TokenPermit memory assetPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external payable {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD);
        uint256 toDeposit = assets - referralFeeAssets;

        address asset = IERC4626(vault).asset();
        TokenLib.pullOrWrapNative(asset, msg.sender, assets, assetPermit);
        TokenLib.forceApproveMax(asset, vault);

        uint256 shares = IERC4626(vault).deposit(toDeposit, msg.sender);
        require(toDeposit.mulDivUp(1e27, shares) <= maxSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(asset, referralFeeRecipient, referralFeeAssets);
    }

    /// @dev Withdraws msg.sender's position in the vault.
    /// @dev Requires the sender to have given enough allowance over its vault shares to this contract, beforehand or via sharesPermit.
    /// @dev Exactly one of assets and shares should be non-zero: the vault is withdrawn by assets, or redeemed by shares. To withdraw the sender's entire position, pass its full share balance as shares.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to msg.sender.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
    /// @dev To receive an amount W, pass assets = floor(W * WAD / (WAD - referralFeePct)).
    /// @dev The vault share price is not checked: any drop (e.g. a bad debt realisation) is not quickly reversed, so a reverted exit retried later would be on similar or worse terms.
    function vaultBundlesV1Withdraw(
        address vault,
        uint256 assets,
        uint256 shares,
        Permit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require((assets == 0) != (shares == 0), NotExactlyOneZero());
        require(referralFeePct < WAD, PctExceeded());

        TokenLib.submitPermit(vault, sharesPermit);

        if (assets > 0) IERC4626(vault).withdraw(assets, address(this), msg.sender);
        else assets = IERC4626(vault).redeem(shares, address(this), msg.sender);

        address asset = IERC4626(vault).asset();
        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(asset, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(asset, msg.sender, assets - referralFeeAssets);
    }

    /// @dev Migrates msg.sender's position in sourceVault to a position in destVault, by withdrawing them from sourceVault then depositing them into destVault.
    /// @dev sourceVault and destVault can each be a Vault V1 or a Vault V2. Migrating from a Vault V2 to a Vault V1 is not prevented, even though it is not expected to be useful.
    /// @dev Requires the sender to have given enough allowance over its sourceVault shares to this contract, beforehand or via sharesPermit.
    /// @dev Exactly one of assetsWithdrawn and sharesRedeemed should be non-zero: sourceVault is withdrawn by assets, or redeemed by shares. To migrate the sender's entire position, pass its full sourceVault share balance as shares.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is deposited into destVault.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; deposited = withdrawnAssets - fee.
    /// @dev The source vault share price is not checked: any drop (e.g. a bad debt realisation) is not quickly reversed, so a reverted exit retried later would be on similar or worse terms.
    /// @dev destMaxSharePriceE27 upper-bounds the realized destVault deposit share price (deposited assets per share, scaled by 1e27).
    function vaultBundlesV1Migrate(
        address sourceVault,
        address destVault,
        uint256 assetsWithdrawn,
        uint256 sharesRedeemed,
        uint256 destMaxSharePriceE27,
        Permit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require((assetsWithdrawn == 0) != (sharesRedeemed == 0), NotExactlyOneZero());
        require(referralFeePct < WAD, PctExceeded());

        TokenLib.submitPermit(sourceVault, sharesPermit);

        address asset = IERC4626(sourceVault).asset();
        require(asset == IERC4626(destVault).asset(), InconsistentAssets());

        if (assetsWithdrawn > 0) IERC4626(sourceVault).withdraw(assetsWithdrawn, address(this), msg.sender);
        else assetsWithdrawn = IERC4626(sourceVault).redeem(sharesRedeemed, address(this), msg.sender);

        uint256 referralFeeAssets = assetsWithdrawn.mulDivDown(referralFeePct, WAD);
        uint256 toDeposit = assetsWithdrawn - referralFeeAssets;

        TokenLib.forceApproveMax(asset, destVault);
        uint256 sharesMinted = IERC4626(destVault).deposit(toDeposit, msg.sender);
        require(toDeposit.mulDivUp(1e27, sharesMinted) <= destMaxSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(asset, referralFeeRecipient, referralFeeAssets);
    }
}
