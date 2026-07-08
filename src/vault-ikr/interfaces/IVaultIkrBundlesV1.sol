// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IVaultIkrBundlesV1 {
    /// ERRORS ///
    error AdapterNotPartOfVault();
    error DeadlinePassed();
    error LiquidityAdapterMismatch();
    error MorphoMismatch();
    error Unauthorized();

    /// STORAGE GETTERS ///
    function BLUE() external view returns (address);

    /// FUNCTIONS ///
    function vaultBundlesV1ForceWithdrawIlliquidVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParams,
        uint256 forceWithdrawAssets,
        uint256 deadline
    ) external;

    function vaultBundlesV1ForceWithdrawLiquidVaultV2(
        address vault,
        address adapter,
        uint256 forceWithdrawAssets,
        uint256 deadline
    ) external;

    function vaultBundlesV1ForceWithdrawIlliquidVaultV1(
        address vault,
        MarketParams[] memory marketParams,
        uint256 forceWithdrawAssets,
        uint256 deadline
    ) external;
}
