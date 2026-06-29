// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IAaveMigrationBundlesV1} from "./IAaveMigrationBundlesV1.sol";
import {IAaveV3} from "./IAaveV3.sol";
import {IAToken} from "./IAToken.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";

/// @dev Inherits the token safety requirements of Aave V3 and Vault V2.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract AaveMigrationBundlesV1 is IAaveMigrationBundlesV1 {
    /// EXTERNAL ///

    /// @dev Migration is permissionless on Vault V2, so no authorization of msg.sender over onBehalf is required.
    /// @dev Pulls `amount` of `aToken` from msg.sender (optionally via ERC-2612 or Permit2), withdraws the whole
    /// pulled balance from `aaveV3Pool` into this contract, then deposits the underlying into `vaultV2` for onBehalf.
    /// @dev The underlying withdrawn from Aave is `vaultV2`'s asset.
    function aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
        address aaveV3Pool,
        address aToken,
        uint256 amount,
        address vaultV2,
        address onBehalf,
        TokenPermit memory aTokenPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        address asset = IVaultV2(vaultV2).asset();
        require(asset == IAToken(aToken).UNDERLYING_ASSET_ADDRESS(), InconsistentTokens());

        TokenLib.pullToken(aToken, msg.sender, amount, aTokenPermit);
        uint256 withdrawn = IAaveV3(aaveV3Pool).withdraw(asset, type(uint256).max, address(this));

        TokenLib.forceApproveMax(asset, vaultV2);
        IVaultV2(vaultV2).deposit(withdrawn, onBehalf);
    }
}
