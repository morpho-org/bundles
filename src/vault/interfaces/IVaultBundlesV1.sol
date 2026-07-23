// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {TokenPermit} from "../../libraries/TokenLib.sol";

/// @dev An empty permit (v, r and s all zero) means no permit is submitted.
/// @dev A permit with an already consumed nonce is not submitted either.
struct SharesPermit {
    uint256 value;
    uint256 nonce;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

interface IVaultBundlesV1 {
    /// ERRORS ///
    error DeadlinePassed();
    error InconsistentAssets();
    error NotExactlyOneZero();
    error PctExceeded();
    error SlippageExceeded();

    /// FUNCTIONS ///
    function vaultBundlesV1Deposit(
        address vault,
        uint256 assets,
        uint256 maxSharePriceE27,
        TokenPermit memory assetPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external payable;

    function vaultBundlesV1Withdraw(
        address vault,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        SharesPermit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function vaultBundlesV1Migrate(
        address sourceVault,
        address destVault,
        uint256 assetsWithdrawn,
        uint256 sharesRedeemed,
        uint256 sourceMinSharePriceE27,
        uint256 destMaxSharePriceE27,
        SharesPermit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
