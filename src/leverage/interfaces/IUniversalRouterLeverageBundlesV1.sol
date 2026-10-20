// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {IBlueLeverageBase} from "./IBlueLeverageBase.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IUniversalRouterLeverageBundlesV1 is IBlueLeverageBase {
    /// STORAGE GETTERS ///
    function UNIVERSAL_ROUTER() external view returns (address);

    /// FUNCTIONS ///

    function universalRouterLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        uint256 maxLtv,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external;

    function universalRouterLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        uint256 maxLtv,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external;

    function universalRouterLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external;
}
