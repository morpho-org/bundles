// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {ISettlerTakerSubmitted} from "./ISettlerTakerSubmitted.sol";

contract AllowanceHolderMock {
    error InsufficientTransientAllowance();

    mapping(address operator => mapping(address owner => mapping(address token => uint256))) public transientAllowance;

    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
    {
        transientAllowance[operator][msg.sender][token] = amount;
        (bool success, bytes memory returnData) = target.call(bytes.concat(data, bytes20(msg.sender)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        delete transientAllowance[operator][msg.sender][token];
    }

    function transferFrom(address token, address owner, address recipient, uint256 amount) external {
        uint256 allowance = transientAllowance[msg.sender][owner][token];
        if (allowance < amount) revert InsufficientTransientAllowance();
        transientAllowance[msg.sender][owner][token] = allowance - amount;
        SafeTransferLib.safeTransferFrom(token, owner, recipient, amount);
    }
}

contract SettlerMock is ISettlerTakerSubmitted {
    using UtilsLib for uint256;

    error MinimumOutputNotMet();
    error OnlyAllowanceHolder();
    error InvalidAction();

    AllowanceHolderMock public immutable allowanceHolder;
    uint256 public rateNumerator = 1;
    uint256 public rateDenominator = 1;
    bool public exactOutput;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    address internal reentryTarget;
    bytes internal reentryData;

    constructor(AllowanceHolderMock allowanceHolder_) {
        allowanceHolder = allowanceHolder_;
    }

    function setRate(uint256 numerator, uint256 denominator) external {
        require(denominator != 0);
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    function setExactOutput(bool exactOutput_) external {
        exactOutput = exactOutput_;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function execute(ISettlerTakerSubmitted.AllowedSlippage calldata slippage, bytes[] calldata actions, bytes32)
        external
        override
    {
        if (msg.sender != address(allowanceHolder)) revert OnlyAllowanceHolder();
        if (actions.length == 0 || actions[0].length < 0xa4) revert InvalidAction();

        address taker = _taker();
        bytes calldata action = actions[0];
        uint256 tokenWord;
        uint256 amountIn;
        assembly ("memory-safe") {
            tokenWord := calldataload(add(action.offset, 0x24))
            amountIn := calldataload(add(action.offset, 0x44))
        }
        address sellToken = address(uint160(tokenWord));
        uint256 amountOut = amountIn.mulDivDown(rateNumerator, rateDenominator);
        uint256 amountSpent = amountIn;
        if (exactOutput) {
            amountOut = slippage.minAmountOut;
            amountSpent = amountOut.mulDivUp(rateDenominator, rateNumerator);
            if (amountSpent > amountIn) revert MinimumOutputNotMet();
        }
        uint256 refund = amountIn - amountSpent;

        _attemptReentry();
        allowanceHolder.transferFrom(sellToken, taker, address(this), amountIn);

        if (amountOut < slippage.minAmountOut) revert MinimumOutputNotMet();
        if (refund != 0) SafeTransferLib.safeTransfer(sellToken, taker, refund);
        SafeTransferLib.safeTransfer(slippage.buyToken, slippage.recipient, amountOut);
    }

    function _attemptReentry() internal {
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded, reentryReturnData) = reentryTarget.call(reentryData);
        }
    }

    function _taker() internal pure returns (address taker) {
        assembly ("memory-safe") {
            taker := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}
