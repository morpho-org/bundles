// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

interface IZeroExDeployer {
    function ownerOf(uint256 tokenId) external view returns (address);

    function prev(uint128 tokenId) external view returns (address);
}
