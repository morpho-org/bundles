// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

interface ISettlerTakerSubmitted {
    struct AllowedSlippage {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
    }

    function execute(AllowedSlippage calldata slippage, bytes[] calldata actions, bytes32 zidAndAffiliate) external;
}
