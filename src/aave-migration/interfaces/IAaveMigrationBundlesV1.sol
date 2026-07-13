// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {TokenPermit} from "../../libraries/TokenLib.sol";

interface IAaveMigrationBundlesV1 {
    /// ERRORS ///
    error InconsistentTokens();
    error SlippageExceeded();
    error DeadlinePassed();

    /// FUNCTIONS ///
    function aaveMigrationBundlesV1WithdrawAndDepositInVaultV2(
        address aaveV3Pool,
        address aToken,
        uint256 aTokenAmount,
        address vaultV2,
        uint256 maxSharePriceE27,
        address onBehalf,
        TokenPermit memory aTokenPermit,
        uint256 deadline
    ) external;
}
