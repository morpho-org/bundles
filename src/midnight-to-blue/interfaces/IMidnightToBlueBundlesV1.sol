// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {SignedAuthorization} from "../../blue/interfaces/IBlueBundlesV1.sol";

/// @dev Hardcap on the referral fee applied by this bundle: 5% of the migrated debt.
/// @dev Fee = repaidUnits * referralFeePct / (WAD - referralFeePct); at pct = 5% this is ~5.26% of the migrated principal.
uint256 constant MAX_REFERRAL_FEE_PCT = 0.05e18;

interface IMidnightToBlueBundlesV1 {
    /// ERRORS ///
    error DeadlinePassed();
    error InconsistentTokens();
    error LtvExceeded();
    error PctExceeded();
    error SlippageExceeded();
    error UnauthorizedCallback();

    /// STORAGE GETTERS ///
    function MIDNIGHT() external view returns (address);
    function BLUE() external view returns (address);

    // forgefmt: disable-start
    /// FUNCTIONS ///
    function midnightToBlueBundlesV1MigrateBorrowPosition(
        Market memory sourceMidnightMarket,
        MarketParams memory destBlueParams,
        uint256 collateralIndex,
        uint256 sourceMaxRepayAssets,
        uint256 destMinSharePriceE27,
        uint256 maxLtv,
        SignedAuthorization memory destAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
    // forgefmt: disable-end
}
