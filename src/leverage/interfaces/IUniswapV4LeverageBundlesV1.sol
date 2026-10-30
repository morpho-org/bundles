// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {IBlueLeverageBase} from "./IBlueLeverageBase.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {PoolKey} from "../../../lib/v4-core/src/types/PoolKey.sol";

interface IUniswapV4LeverageBundlesV1 is IBlueLeverageBase {
    /// ERRORS ///
    error InconsistentTokens();
    error SlippageExceeded();

    /// STORAGE GETTERS ///

    function POOL_MANAGER() external view returns (address);

    /// FUNCTIONS ///

    function uniswapV4LeverageBundlesV1Open(
        MarketParams memory marketParams,
        PoolKey memory poolKey,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        uint256 deadline
    ) external;

    function uniswapV4LeverageBundlesV1Delever(
        MarketParams memory marketParams,
        PoolKey memory poolKey,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        uint256 deadline
    ) external;

    function uniswapV4LeverageBundlesV1Close(
        MarketParams memory marketParams,
        PoolKey memory poolKey,
        uint256 maxCollateralIn,
        uint256 deadline
    ) external;
}
