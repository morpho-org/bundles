// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IAaveMigrationBundlesV1} from "./interfaces/IAaveMigrationBundlesV1.sol";
import {IAaveV3} from "./interfaces/IAaveV3.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

/// @dev Inherits the token safety requirements of Aave V3 and Vault V2.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract AaveMigrationBundlesV1 is IAaveMigrationBundlesV1 {
    using UtilsLib for uint256;

    /// EXTERNAL ///
    /// @dev Pulls aTokenAmount of aToken from msg.sender (optionally via ERC-2612 or Permit2), withdraws the whole pulled balance from aaveV3Pool into this contract, then deposits the underlying into vaultV2 for onBehalf.
    /// @dev maxSharePriceE27 upper-bounds the realized deposit share price (deposited assets per share, scaled by 1e27).
    function aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
        address aaveV3Pool,
        address aToken,
        uint256 aTokenAmount,
        address vaultV2,
        uint256 maxSharePriceE27,
        address onBehalf,
        TokenPermit memory aTokenPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        address asset = IVaultV2(vaultV2).asset();
        require(asset == IAToken(aToken).UNDERLYING_ASSET_ADDRESS(), InconsistentTokens());

        TokenLib.pullToken(aToken, msg.sender, aTokenAmount, aTokenPermit);
        uint256 withdrawn = IAaveV3(aaveV3Pool).withdraw(asset, type(uint256).max, address(this));

        TokenLib.forceApproveMax(asset, vaultV2);
        uint256 shares = IVaultV2(vaultV2).deposit(withdrawn, onBehalf);
        require(withdrawn.mulDivUp(1e27, shares) <= maxSharePriceE27, SlippageExceeded());
    }
}
