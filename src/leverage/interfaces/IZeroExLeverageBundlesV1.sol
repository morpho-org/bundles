// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @dev When fromIdle is true, the vault's idle assets are allocated and sourceAdapter and sourceMarketParams are ignored; otherwise assets are first deallocated from sourceAdapter's sourceMarketParams.
/// @dev penalty is the exact WAD-scaled penalty rate and must equal the vault's configured penalty when the allocation executes.
struct PublicAllocations {
    address vault;
    address adapter;
    MarketParams marketParams;
    bool fromIdle;
    address sourceAdapter;
    MarketParams sourceMarketParams;
    uint128 assets;
    uint64 penalty;
}

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

interface IZeroExLeverageBundlesV1 {
    /// ERRORS ///
    error DeadlinePassed();
    error ExcessiveInput();
    error InconsistentPenaltyAssets();
    error InconsistentTokens();
    error InsufficientOutput();
    error LtvExceeded();
    error Reentrancy();
    error UnauthorizedCallback();
    error ZeroCollateralToBuy();

    /// STORAGE GETTERS ///
    function BLUE() external view returns (address);
    function ALLOWANCE_HOLDER() external view returns (address);
    function PUBLIC_ALLOCATOR() external view returns (address);

    /// FUNCTIONS ///
    function zeroExLeverageBundlesV1SwapAndSupply(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 loanAssets,
        uint256 collateralToBuy,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    function zeroExLeverageBundlesV1Lever(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 loanAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        PublicAllocations[] calldata reallocations,
        uint256 penaltyAssets,
        uint256 deadline
    ) external;

    function zeroExLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 collateralToSell,
        uint256 minRepayAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    function zeroExLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        uint256 minLoanOut,
        bytes calldata swapData,
        uint256 deadline
    ) external;
}
