// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IAugustusV6} from "../../src/leverage/interfaces/IAugustusV6.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

contract AugustusMock is IAugustusV6 {
    using UtilsLib for uint256;

    uint256 public lastFromAmount;
    uint256 public lastToAmount;
    uint256 public lastQuotedAmount;
    uint256 public outputReduction;
    address internal reentryTarget;
    bytes internal reentryData;

    function setOutputReduction(uint256 amount) external {
        outputReduction = amount;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function swapExactAmountOut(address, GenericData calldata swapData, uint256, bytes calldata, bytes calldata)
        external
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        (spentAmount, receivedAmount) = _swap(
            address(swapData.srcToken),
            address(swapData.destToken),
            swapData.fromAmount,
            swapData.toAmount,
            swapData.quotedAmount,
            swapData.beneficiary
        );
        paraswapShare = 0;
        partnerShare = 0;
    }

    function swapExactAmountOutOnUniswapV2(IAugustusV6.UniswapData calldata data, uint256, bytes calldata)
        external
        payable
        override
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        (spentAmount, receivedAmount) = _swap(
            address(data.srcToken),
            address(data.destToken),
            data.fromAmount,
            data.toAmount,
            data.quotedAmount,
            data.beneficiary
        );
        paraswapShare = 0;
        partnerShare = 0;
    }

    function swapExactAmountOutOnUniswapV3(IAugustusV6.UniswapData calldata data, uint256, bytes calldata)
        external
        payable
        override
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        (spentAmount, receivedAmount) = _swap(
            address(data.srcToken),
            address(data.destToken),
            data.fromAmount,
            data.toAmount,
            data.quotedAmount,
            data.beneficiary
        );
        paraswapShare = 0;
        partnerShare = 0;
    }

    function _swap(
        address srcToken,
        address destToken,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 quotedAmount,
        address beneficiary
    ) internal returns (uint256 spentAmount, uint256 receivedAmount) {
        lastFromAmount = fromAmount;
        lastToAmount = toAmount;
        lastQuotedAmount = quotedAmount;
        spentAmount = toAmount.mulDivUp(1003, 1000);
        require(spentAmount <= fromAmount, "maximum input exceeded");
        if (reentryTarget != address(0)) {
            (bool success, bytes memory returnData) = reentryTarget.call(reentryData);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
        receivedAmount = toAmount - outputReduction;
        SafeTransferLib.safeTransferFrom(srcToken, msg.sender, address(this), spentAmount);
        SafeTransferLib.safeTransfer(destToken, beneficiary, receivedAmount);
    }
}
