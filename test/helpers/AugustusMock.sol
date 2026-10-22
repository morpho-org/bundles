// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IAugustusV6} from "../../src/leverage/adapters/ParaswapSwapAdapter.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

contract AugustusMock is IAugustusV6 {
    using UtilsLib for uint256;

    function swapExactAmountOut(address, GenericData calldata swapData, uint256, bytes calldata, bytes calldata)
        external
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        spentAmount = swapData.toAmount.mulDivUp(1003, 1000);
        require(spentAmount <= swapData.fromAmount);
        SafeTransferLib.safeTransferFrom(address(swapData.srcToken), msg.sender, address(this), spentAmount);
        SafeTransferLib.safeTransfer(address(swapData.destToken), swapData.beneficiary, swapData.toAmount);
        receivedAmount = swapData.toAmount;
        paraswapShare = 0;
        partnerShare = 0;
    }
}
