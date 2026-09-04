// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IMidnightBundlesV2 {
    /// ERRORS ///
    error DeadlinePassed();
    error InconsistentMidnight();
    error NewRootCannotBeCancelled();

    /// STORAGE GETTERS ///
    function MIDNIGHT() external view returns (address);
    function BLUE() external view returns (address);
    function BLUE_BUY_CALLBACK_FACTORY() external view returns (address);
    function LOG() external view returns (address);
    function SETTER_RATIFIER() external view returns (address);

    /// FUNCTIONS ///
    function midnightBundlesV2LendLimitWithBlueBuyCallback(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        bytes32 newRoot,
        bytes32[] memory rootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external;
}
