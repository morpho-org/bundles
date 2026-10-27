// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IVeloraLeverageBundlesV1 {
    error DeadlinePassed();
    error IncompleteFill();
    error InvalidLeverage();
    error UnauthorizedCallback();

    function BLUE() external view returns (address);
    function AUGUSTUS() external view returns (address);

    function veloraLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    function veloraLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    function veloraLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external;
}
