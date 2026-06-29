// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

interface IAaveV3 {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
