// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";

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

interface IVaultExitBundlesV1 {
    /// ERRORS ///
    error AdapterNotPartOfVault();
    error DeadlinePassed();
    error InvalidAdaptersLength();
    error MorphoMismatch();
    error PctExceeded();
    error SlippageExceeded();
    error UnauthorizedCallback();

    /// STORAGE GETTERS ///
    function BLUE() external view returns (address);

    /// FUNCTIONS ///
    function vaultExitBundlesV1InKindRedemptionVaultV1(
        address vault,
        MarketParams[] memory marketParamsList,
        uint256 exitAssets,
        SharesPermit memory sharesPermit,
        uint256 deadline
    ) external;

    function vaultExitBundlesV1InKindRedemptionVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParamsList,
        uint256 exitAssets,
        SharesPermit memory sharesPermit,
        uint256 deadline
    ) external;

    function vaultExitBundlesV1ForceWithdrawVaultV2(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 minSharePriceE27,
        SharesPermit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
