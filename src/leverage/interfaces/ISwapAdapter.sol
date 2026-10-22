// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

interface ISwapAdapter {
    /// @notice Swaps up to `maxIn` of `tokenIn`, already transferred to the adapter, for at least `amountOut` of `tokenOut`.
    /// @dev Must send all `tokenOut` it holds and all unspent `tokenIn` to the caller before returning.
    function swapExactOut(address tokenIn, address tokenOut, uint256 maxIn, uint256 amountOut, bytes calldata data)
        external;
}
