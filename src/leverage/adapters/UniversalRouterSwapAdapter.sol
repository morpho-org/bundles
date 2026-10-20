// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {SafeTransferLib} from "../../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IERC20} from "../../../lib/vault-v2/src/interfaces/IERC20.sol";

contract UniversalRouterSwapAdapter is ISwapAdapter {
    address public immutable UNIVERSAL_ROUTER;

    constructor(address universalRouter) {
        UNIVERSAL_ROUTER = universalRouter;
    }

    function swapExactOut(address tokenIn, address tokenOut, uint256 maxIn, uint256, bytes calldata data) external {
        (bytes memory commands, bytes[] memory inputs) = abi.decode(data, (bytes, bytes[]));

        SafeTransferLib.safeTransfer(tokenIn, UNIVERSAL_ROUTER, maxIn);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp);

        uint256 tokenOutBalance = IERC20(tokenOut).balanceOf(address(this));
        if (tokenOutBalance > 0) SafeTransferLib.safeTransfer(tokenOut, msg.sender, tokenOutBalance);

        uint256 tokenInBalance = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInBalance > 0) SafeTransferLib.safeTransfer(tokenIn, msg.sender, tokenInBalance);
    }
}
