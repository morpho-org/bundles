// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {IBlueLeverageBase} from "./IBlueLeverageBase.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface ILeverageBundlesV1 is IBlueLeverageBase {
    function leverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        address adapter,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    function leverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        address adapter,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    function leverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        address adapter,
        bytes calldata swapData,
        uint256 deadline
    ) external;
}
