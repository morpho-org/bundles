// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IERC20} from "../../../lib/vault-v2/src/interfaces/IERC20.sol";

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

    struct UniswapData {
        IERC20 srcToken;
        IERC20 destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address payable beneficiary;
        bytes pools;
    }

    function swapExactAmountOut(
        address executor,
        GenericData calldata swapData,
        uint256 partnerAndFee,
        bytes calldata permit,
        bytes calldata executorData
    ) external returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);

    function swapExactAmountOutOnUniswapV2(UniswapData calldata uniData, uint256 partnerAndFee, bytes calldata permit)
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);

    function swapExactAmountOutOnUniswapV3(UniswapData calldata uniData, uint256 partnerAndFee, bytes calldata permit)
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);

    function swapExactAmountIn(
        address executor,
        GenericData calldata swapData,
        uint256 partnerAndFee,
        bytes calldata permit,
        bytes calldata executorData
    ) external returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);

    function swapExactAmountInOnUniswapV2(UniswapData calldata uniData, uint256 partnerAndFee, bytes calldata permit)
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);

    function swapExactAmountInOnUniswapV3(UniswapData calldata uniData, uint256 partnerAndFee, bytes calldata permit)
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
