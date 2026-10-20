// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {SafeTransferLib} from "../../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IERC20} from "../../../lib/vault-v2/src/interfaces/IERC20.sol";
import {TokenLib} from "../../libraries/TokenLib.sol";

interface IAugustusV6 {
    struct GenericData {
        IERC20 srcToken;
        IERC20 destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address payable beneficiary;
    }

    function swapExactAmountOut(
        address executor,
        GenericData calldata swapData,
        uint256 partnerAndFee,
        bytes calldata permit,
        bytes calldata executorData
    ) external returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}

contract ParaswapSwapAdapter is ISwapAdapter {
    address public immutable AUGUSTUS;

    constructor(address augustus) {
        AUGUSTUS = augustus;
    }

    function swapExactOut(address tokenIn, address tokenOut, uint256 maxIn, uint256, bytes calldata data) external {
        TokenLib.safeApprove(tokenIn, AUGUSTUS, maxIn);
        (bool success, bytes memory returnData) = AUGUSTUS.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        TokenLib.safeApprove(tokenIn, AUGUSTUS, 0);

        uint256 tokenOutBalance = IERC20(tokenOut).balanceOf(address(this));
        if (tokenOutBalance > 0) SafeTransferLib.safeTransfer(tokenOut, msg.sender, tokenOutBalance);

        uint256 tokenInBalance = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInBalance > 0) SafeTransferLib.safeTransfer(tokenIn, msg.sender, tokenInBalance);
    }
}
