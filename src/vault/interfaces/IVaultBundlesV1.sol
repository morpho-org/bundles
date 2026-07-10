// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {TokenPermit} from "../../libraries/TokenLib.sol";

interface IVaultBundlesV1 {
    /// ERRORS ///
    error SlippageExceeded();
    error InconsistentAssets();
    error NotExactlyOneZero();
    error DeadlinePassed();

    /// FUNCTIONS ///
    function vaultBundlesV1Deposit(
        address vault,
        uint256 assets,
        uint256 maxSharePriceE27,
        address onBehalf,
        TokenPermit memory assetPermit,
        uint256 deadline
    ) external;

    function vaultBundlesV1Withdraw(
        address vault,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address receiver,
        uint256 deadline
    ) external;

    function vaultBundlesV1Migrate(
        address sourceVault,
        address destVault,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        uint256 maxSharePriceE27,
        address onBehalf,
        uint256 deadline
    ) external;
}
