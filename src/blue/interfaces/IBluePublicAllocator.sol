// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @dev Minimal interface restricted to what the bundler calls. Declared here rather than imported from vault-v2 so that its MarketParams is this repo's, not vault-v2's nested morpho-blue copy.
interface IBluePublicAllocator {
    function reallocate(
        address vault,
        address deallocateAdapter,
        MarketParams calldata deallocateMarketParams,
        address allocateAdapter,
        MarketParams calldata allocateMarketParams,
        uint128 assets,
        uint64 penalty
    ) external;
    function allocateFromIdle(
        address vault,
        address adapter,
        MarketParams calldata marketParams,
        uint128 assets,
        uint64 penalty
    ) external;
}
