// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

interface IAllowanceHolder {
    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable;
}
