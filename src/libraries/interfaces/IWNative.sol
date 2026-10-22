// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

interface IWNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
