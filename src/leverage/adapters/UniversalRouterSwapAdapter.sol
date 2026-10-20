// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {IV4Router} from "../../../lib/universal-router/lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "../../../lib/universal-router/lib/v4-periphery/src/libraries/Actions.sol";
import {Commands} from "../../../lib/universal-router/contracts/libraries/Commands.sol";
import {SafeCast} from "../../../lib/v4-core/src/libraries/SafeCast.sol";
import {SafeTransferLib} from "../../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IERC20} from "../../../lib/vault-v2/src/interfaces/IERC20.sol";

contract UniversalRouterSwapAdapter is ISwapAdapter {
    address public immutable UNIVERSAL_ROUTER;

    constructor(address universalRouter) {
        UNIVERSAL_ROUTER = universalRouter;
    }

    /// @notice Rewrites a sole exact-output swap to the supplied amounts; routes with zero or multiple exact-output swaps are unchanged.
    function swapExactOut(address tokenIn, address tokenOut, uint256 maxIn, uint256 amountOut, bytes calldata data)
        external
    {
        (bytes memory commands, bytes[] memory inputs) = abi.decode(data, (bytes, bytes[]));
        inputs = _withExactAmounts(commands, inputs, amountOut, maxIn);

        SafeTransferLib.safeTransfer(tokenIn, UNIVERSAL_ROUTER, maxIn);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp);

        uint256 tokenOutBalance = IERC20(tokenOut).balanceOf(address(this));
        if (tokenOutBalance > 0) SafeTransferLib.safeTransfer(tokenOut, msg.sender, tokenOutBalance);

        uint256 tokenInBalance = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInBalance > 0) SafeTransferLib.safeTransfer(tokenIn, msg.sender, tokenInBalance);
    }

    function _withExactAmounts(bytes memory commands, bytes[] memory inputs, uint256 amountOut, uint256 maxIn)
        internal
        pure
        returns (bytes[] memory)
    {
        uint256 exactOutCount;
        uint256 swapCommandIndex;
        uint256 swapActionIndex;

        for (uint256 i; i < commands.length; i++) {
            uint256 command = uint8(commands[i]) & uint8(Commands.COMMAND_TYPE_MASK);
            if (command == Commands.V3_SWAP_EXACT_OUT || command == Commands.V2_SWAP_EXACT_OUT) {
                exactOutCount++;
                swapCommandIndex = i;
            } else if (command == Commands.V4_SWAP) {
                (bytes memory actions,) = abi.decode(inputs[i], (bytes, bytes[]));
                for (uint256 j; j < actions.length; j++) {
                    uint8 action = uint8(actions[j]);
                    if (action == Actions.SWAP_EXACT_OUT_SINGLE || action == Actions.SWAP_EXACT_OUT) {
                        exactOutCount++;
                        swapCommandIndex = i;
                        swapActionIndex = j;
                    }
                }
            }
        }

        if (exactOutCount != 1) return inputs;

        uint256 swapCommand = uint8(commands[swapCommandIndex]) & uint8(Commands.COMMAND_TYPE_MASK);
        if (swapCommand == Commands.V3_SWAP_EXACT_OUT) {
            (address recipient,,, bytes memory path, bool payerIsUser, uint256[] memory minHopPriceX36) =
                abi.decode(inputs[swapCommandIndex], (address, uint256, uint256, bytes, bool, uint256[]));
            inputs[swapCommandIndex] = abi.encode(recipient, amountOut, maxIn, path, payerIsUser, minHopPriceX36);
        } else if (swapCommand == Commands.V2_SWAP_EXACT_OUT) {
            (address recipient,,, address[] memory path, bool payerIsUser, uint256[] memory minHopPriceX36) =
                abi.decode(inputs[swapCommandIndex], (address, uint256, uint256, address[], bool, uint256[]));
            inputs[swapCommandIndex] = abi.encode(recipient, amountOut, maxIn, path, payerIsUser, minHopPriceX36);
        } else {
            (bytes memory actions, bytes[] memory params) = abi.decode(inputs[swapCommandIndex], (bytes, bytes[]));
            if (uint8(actions[swapActionIndex]) == Actions.SWAP_EXACT_OUT_SINGLE) {
                IV4Router.ExactOutputSingleParams memory swapParams =
                    abi.decode(params[swapActionIndex], (IV4Router.ExactOutputSingleParams));
                swapParams.amountOut = SafeCast.toUint128(amountOut);
                swapParams.amountInMaximum = SafeCast.toUint128(maxIn);
                params[swapActionIndex] = abi.encode(swapParams);
            } else {
                IV4Router.ExactOutputParams memory swapParams =
                    abi.decode(params[swapActionIndex], (IV4Router.ExactOutputParams));
                swapParams.amountOut = SafeCast.toUint128(amountOut);
                swapParams.amountInMaximum = SafeCast.toUint128(maxIn);
                params[swapActionIndex] = abi.encode(swapParams);
            }
            inputs[swapCommandIndex] = abi.encode(actions, params);
        }

        return inputs;
    }
}
