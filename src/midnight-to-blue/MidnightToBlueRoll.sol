// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

// EDUCATIONAL PROOF OF CONCEPT — DO NOT USE IN PRODUCTION.
// Callback-only. In the intended architecture the caller (typically a smart wallet)
// invokes Midnight.repay itself with this contract as the callback; the callback then
// chains Midnight.withdrawCollateral, Blue.supplyCollateral and Blue.borrow to migrate
// the position without a flash loan.

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IRepayCallback} from "../../lib/midnight/src/interfaces/ICallbacks.sol";
import {CALLBACK_SUCCESS} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IERC20Approve {
    function approve(address spender, uint256 value) external returns (bool);
}

contract MidnightToBlueRoll is IRepayCallback {
    address public immutable MIDNIGHT;
    address public immutable BLUE;

    constructor(address _midnight, address _blue) {
        MIDNIGHT = _midnight;
        BLUE = _blue;
    }

    function onRepay(bytes32, Market memory, uint256 units, address, bytes memory data) external returns (bytes32) {
        require(msg.sender == MIDNIGHT);
        (
            Market memory sourceMidnightMarket,
            MarketParams memory destBlueParams,
            uint256 collateralIndex,
            uint256 collateralAmount,
            address sender
        ) = abi.decode(data, (Market, MarketParams, uint256, uint256, address));

        IMidnight(MIDNIGHT)
            .withdrawCollateral(sourceMidnightMarket, collateralIndex, collateralAmount, sender, address(this));

        IERC20Approve(destBlueParams.collateralToken).approve(BLUE, type(uint256).max);
        IMorpho(BLUE).supplyCollateral(destBlueParams, collateralAmount, sender, "");
        IMorpho(BLUE).borrow(destBlueParams, units, 0, sender, address(this));

        IERC20Approve(sourceMidnightMarket.loanToken).approve(MIDNIGHT, type(uint256).max);
        return CALLBACK_SUCCESS;
    }
}
