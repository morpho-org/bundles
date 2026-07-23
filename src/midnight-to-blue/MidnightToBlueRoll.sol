// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

// EDUCATIONAL PROOF OF CONCEPT — DO NOT USE IN PRODUCTION.
// Demonstrates chaining Midnight's onRepay callback with a Morpho Blue borrow to migrate a
// borrow position across the two protocols in a single transaction, without a flash loan.
// Slippage bounds, LTV caps, deadlines, referral fees, callback authentication, token
// consistency checks and every other production concern are deliberately omitted.

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IRepayCallback} from "../../lib/midnight/src/interfaces/ICallbacks.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {CALLBACK_SUCCESS} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMidnightToBlueRoll} from "./interfaces/IMidnightToBlueRoll.sol";

interface IERC20Approve {
    function approve(address spender, uint256 value) external returns (bool);
}

contract MidnightToBlueRoll is IMidnightToBlueRoll, IRepayCallback {
    address public immutable MIDNIGHT;
    address public immutable BLUE;

    constructor(address _midnight, address _blue) {
        MIDNIGHT = _midnight;
        BLUE = _blue;
    }

    function roll(Market memory sourceMidnightMarket, MarketParams memory destBlueParams, uint256 collateralIndex)
        external
    {
        bytes32 id = IdLib.toId(sourceMidnightMarket);
        uint256 units = IMidnight(MIDNIGHT).debt(id, msg.sender);
        uint256 collateralAmount = IMidnight(MIDNIGHT).collateral(id, msg.sender, collateralIndex);

        IMidnight(MIDNIGHT)
            .repay(
                sourceMidnightMarket,
                units,
                msg.sender,
                address(this),
                abi.encode(sourceMidnightMarket, destBlueParams, collateralIndex, collateralAmount, msg.sender)
            );
    }

    function onRepay(bytes32, Market memory, uint256 units, address, bytes memory data) external returns (bytes32) {
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
