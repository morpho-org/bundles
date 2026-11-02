// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

library BytesLib {
    error InvalidOffset();

    /// @notice Reads a 32-byte word at a byte offset from the start of data.
    function get(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        require(data.length >= 32 && offset <= data.length - 32, InvalidOffset());
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), offset))
        }
    }

    /// @notice Writes a 32-byte word at a byte offset from the start of data.
    function set(bytes memory data, uint256 offset, uint256 value) internal pure {
        require(data.length >= 32 && offset <= data.length - 32, InvalidOffset());
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), value)
        }
    }
}
