// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.0;

import {Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";

contract Utils {
    function hashMarket(Market memory market) external pure returns (bytes32) {
        return keccak256(abi.encode(market));
    }
}
