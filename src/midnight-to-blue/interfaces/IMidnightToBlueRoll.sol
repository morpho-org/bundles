// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IMidnightToBlueRoll {
    function MIDNIGHT() external view returns (address);
    function BLUE() external view returns (address);

    function roll(Market memory sourceMidnightMarket, MarketParams memory destBlueParams, uint256 collateralIndex)
        external;
}
