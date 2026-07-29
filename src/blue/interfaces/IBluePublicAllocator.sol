// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @dev Minimal handle on Vault V2's Blue public allocator, restricted to what the bundler calls.
interface IBluePublicAllocator {
    function vaultData(address vault)
        external
        view
        returns (bool canAllocateFromIdle, uint120 nativePenalty, uint120 accruedNativePenalty);

    function reallocate(
        address vault,
        address deallocateAdapter,
        MarketParams calldata deallocateMarketParams,
        address allocateAdapter,
        MarketParams calldata allocateMarketParams,
        uint128 assets
    ) external payable;

    function allocateFromIdle(address vault, address adapter, MarketParams calldata marketParams, uint128 assets)
        external
        payable;
}
