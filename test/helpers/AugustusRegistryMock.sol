// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IAugustusRegistry} from "../../src/leverage/interfaces/IAugustusRegistry.sol";

contract AugustusRegistryMock is IAugustusRegistry {
    mapping(address => bool) public override isValidAugustus;

    function setValid(address augustus, bool valid) external {
        isValidAugustus[augustus] = valid;
    }
}
