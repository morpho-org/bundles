// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.5.0;

import {MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IVaultBundles {
    /// ERRORS ///
    error AdapterNotPartOfVault();
    error MarketNotPartOfAdapter();
    error MarketNotPartOfVault();
    error NoMarketParams();
    error Unauthorized();
    error DeadlinePassed();

    /// STORAGE GETTERS ///
    function PERMIT2() external view returns (address);
    function BLUE() external view returns (address);

    /// FUNCTIONS ///

    function forceWithdrawIlliquidVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParams,
        uint256 assets,
        uint256 deadline
    ) external;

    function forceWithdrawLiquidVaultV2(
        address vault,
        address adapter,
        MarketParams memory marketParams,
        uint256 assets,
        uint256 deadline
    ) external;

    function forceWithdrawIlliquidVaultV1(
        address vault,
        MarketParams memory marketParams,
        uint256 assets,
        uint256 deadline
    ) external;
}
