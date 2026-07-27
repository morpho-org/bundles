// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {Permit} from "../../libraries/TokenLib.sol";

interface IVaultExitBundlesV1 {
    /// ERRORS ///
    error AlreadyInitiated();
    error AdapterNotPartOfVault();
    error DeadlinePassed();
    error InvalidAdaptersLength();
    error MorphoMismatch();
    error PctExceeded();
    error SlippageExceeded();
    error UnauthorizedCallback();

    /// STORAGE GETTERS ///
    function initiator() external view returns (address);
    function BLUE() external view returns (address);

    /// FUNCTIONS ///
    function vaultExitBundlesV1InKindRedemptionVaultV1(
        address vault,
        MarketParams[] memory marketParamsList,
        uint256 exitAssets,
        Permit memory sharesPermit,
        uint256 deadline
    ) external;

    function vaultExitBundlesV1InKindRedemptionVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParamsList,
        uint256 exitAssets,
        Permit memory sharesPermit,
        uint256 deadline
    ) external;

    function vaultExitBundlesV1ForceWithdrawVaultV2(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 minSharePriceE27,
        Permit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
