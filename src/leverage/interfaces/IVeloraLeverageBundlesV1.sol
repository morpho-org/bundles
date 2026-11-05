// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IVeloraLeverageBundlesV1 {
    error DeadlinePassed();
    error IncompleteFill();
    error InvalidAugustus();
    error InvalidSelector();
    error LtvExceeded();
    error Reentrancy();
    error UnauthorizedCallback();
    error ZeroCollateralToBuy();
    error ZeroSwapAmount();

    function BLUE() external view returns (address);
    function AUGUSTUS_REGISTRY() external view returns (address);

    function veloraLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        address augustus,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    function veloraLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        address augustus,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    function veloraLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        address augustus,
        bytes calldata swapData,
        uint256 deadline
    ) external;
}
