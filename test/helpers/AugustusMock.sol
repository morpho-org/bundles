// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IAugustusV6} from "../../src/leverage/interfaces/IAugustusV6.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

contract AugustusMock is IAugustusV6 {
    using UtilsLib for uint256;

    // Same tuple layouts as Augustus v6.2's direct Uniswap and Balancer methods.
    struct UniswapData {
        address srcToken;
        address destToken;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        address payable beneficiary;
        bytes pools;
    }

    struct BalancerData {
        uint256 fromAmount;
        uint256 toAmount;
        uint256 quotedAmount;
        bytes32 metadata;
        uint256 beneficiaryAndApproveFlag;
    }

    uint256 public lastFromAmount;
    uint256 public lastToAmount;
    uint256 public lastQuotedAmount;
    uint256 public outputReduction;

    function setOutputReduction(uint256 amount) external {
        outputReduction = amount;
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

    function swapExactAmountOutOnUniswapV2(UniswapData calldata data, uint256, bytes calldata) external {
        _swap(data.srcToken, data.destToken, data.fromAmount, data.toAmount, data.quotedAmount, data.beneficiary);
    }

    function swapExactAmountOutOnUniswapV3(UniswapData calldata data, uint256, bytes calldata) external {
        _swap(data.srcToken, data.destToken, data.fromAmount, data.toAmount, data.quotedAmount, data.beneficiary);
    }

    function swapExactAmountOutOnBalancerV2(BalancerData calldata data, uint256, bytes calldata, bytes calldata route)
        external
    {
        (address srcToken, address destToken) = abi.decode(route, (address, address));
        // The low 160 bits hold the beneficiary; approval flags are unused in this mock.
        // forge-lint: disable-next-line(unsafe-typecast)
        address beneficiary = address(uint160(data.beneficiaryAndApproveFlag));
        _swap(srcToken, destToken, data.fromAmount, data.toAmount, data.quotedAmount, beneficiary);
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
        receivedAmount = toAmount - outputReduction;
        SafeTransferLib.safeTransferFrom(srcToken, msg.sender, address(this), spentAmount);
        SafeTransferLib.safeTransfer(destToken, beneficiary, receivedAmount);
    }
}
