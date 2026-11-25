// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Offer} from "../../../lib/midnight/src/interfaces/IMidnight.sol";

/// @dev Minimal interface restricted to what the bundler calls. Declared here rather than imported from vault-v2 so that its Offer is this repo's, not vault-v2's nested midnight copy (a distinct type to the compiler).
interface IMidnightAdapter {
    function parentVault() external view returns (address);
    function take(Offer memory offer, bytes calldata ratifierData, uint256 units, bytes calldata takerCallbackData)
        external;
}
