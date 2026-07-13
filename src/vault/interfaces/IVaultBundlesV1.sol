// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {TokenPermit} from "../../libraries/TokenLib.sol";

interface IVaultBundlesV1 {
    /// ERRORS ///
    error SlippageExceeded();
    error InconsistentAssets();
    error NotExactlyOneZero();
    error PctExceeded();
    error DeadlinePassed();

    /// FUNCTIONS ///
    function vaultBundlesV1Deposit(
        address vault,
        uint256 assets,
        uint256 maxSharePriceE27,
        TokenPermit memory assetPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function vaultBundlesV1Withdraw(
        address vault,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function vaultBundlesV1Migrate(
        address sourceVault,
        address destVault,
        uint256 assetsWithdrawn,
        uint256 sharesRedeemed,
        uint256 minSharePriceE27,
        uint256 maxSharePriceE27,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
