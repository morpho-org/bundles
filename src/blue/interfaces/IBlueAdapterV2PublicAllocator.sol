// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @dev Minimal handle on Vault V2's Blue public allocator, restricted to what the bundler calls.
interface IBlueAdapterV2PublicAllocator {
    function nativePenalty(address vault) external view returns (uint256);

    function reallocate(
        address vault,
        address adapter,
        MarketParams calldata deallocateMarketParams,
        MarketParams calldata allocateMarketParams,
        uint128 assets
    ) external payable;

    function allocateFromIdle(address vault, address adapter, MarketParams calldata marketParams, uint128 assets)
        external
        payable;
}
