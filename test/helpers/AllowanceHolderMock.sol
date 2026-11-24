// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";

contract AllowanceHolderMock {
    error InsufficientTransientAllowance();

    mapping(address operator => mapping(address owner => mapping(address token => uint256))) public transientAllowance;

    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        transientAllowance[operator][msg.sender][token] = amount;
        bool success;
        (success, result) = target.call(bytes.concat(data, bytes20(msg.sender)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        delete transientAllowance[operator][msg.sender][token];
    }

    function transferFrom(address token, address owner, address recipient, uint256 amount) external {
        uint256 allowance = transientAllowance[msg.sender][owner][token];
        if (allowance < amount) revert InsufficientTransientAllowance();
        transientAllowance[msg.sender][owner][token] = allowance - amount;
        SafeTransferLib.safeTransferFrom(token, owner, recipient, amount);
    }
}
