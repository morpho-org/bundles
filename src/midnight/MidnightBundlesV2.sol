// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import {ISetterRatifier} from "../../lib/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IMidnightBundlesV2} from "./interfaces/IMidnightBundlesV2.sol";

/// @dev Asset-capped Midnight buy offers funded through Midnight's BlueBuyCallback periphery.
/// @dev The maker should authorize this contract on Midnight before calling make.
/// @dev Offers are constructed offchain and activated as Merkle roots through SETTER_RATIFIER.
/// @dev Reposting activates a new root, then deactivates selected roots and cancels selected offer groups atomically.
/// @dev assetsToPark is optional so a repost can reuse assets already supplied to the callback on Blue.
/// @dev The signed offer must be a buy offer whose callback is the callback derived from callbackSalt and whose
/// callbackData is abi.encode(blueMarket).
/// @dev Replacement offers must not reuse a group passed in groupsToCancel.
contract MidnightBundlesV2 is IMidnightBundlesV2 {
    address public immutable MIDNIGHT;
    address public immutable BLUE;
    address public immutable BLUE_BUY_CALLBACK_FACTORY;
    address public immutable LOG;
    address public immutable SETTER_RATIFIER;

    constructor(address _midnight, address _blueBuyCallbackFactory, address _log, address _setterRatifier) {
        require(
            IBlueBuyCallbackFactory(_blueBuyCallbackFactory).MIDNIGHT() == _midnight
                && ISetterRatifier(_setterRatifier).MIDNIGHT() == _midnight,
            InconsistentMidnight()
        );

        MIDNIGHT = _midnight;
        BLUE = IBlueBuyCallbackFactory(_blueBuyCallbackFactory).BLUE();
        BLUE_BUY_CALLBACK_FACTORY = _blueBuyCallbackFactory;
        LOG = _log;
        SETTER_RATIFIER = _setterRatifier;
    }

    /// EXTERNAL ///

    /// @dev Creates or reuses msg.sender's BlueBuyCallback for callbackSalt.
    /// @dev Pulls assetsToPark from msg.sender and supplies them to blueMarket on behalf of the callback. msg.sender
    /// must approve this contract for at least assetsToPark beforehand.
    /// @dev This contract must be authorized by msg.sender on Midnight so it can authorize SETTER_RATIFIER and update roots.
    /// @dev SETTER_RATIFIER is authorized on Midnight if it is not already authorized.
    /// @dev The new root is enabled before selected roots and groups are cancelled, then payload is published through LOG.
    /// @dev payload is forwarded verbatim and is not checked against newRoot.
    /// All changes revert atomically on failure.
    function midnightBundlesV2LendLimitWithBlueBuyCallback(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        bytes32 newRoot,
        bytes32[] memory rootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        address blueBuyCallback =
            IBlueBuyCallbackFactory(BLUE_BUY_CALLBACK_FACTORY).createBlueBuyCallback(msg.sender, callbackSalt);

        if (assetsToPark > 0) {
            SafeTransferLib.safeTransferFrom(blueMarket.loanToken, msg.sender, address(this), assetsToPark);
            TokenLib.forceApproveMax(blueMarket.loanToken, BLUE);
            IMorpho(BLUE).supply(blueMarket, assetsToPark, 0, blueBuyCallback, "");
        }

        IMidnight midnight = IMidnight(MIDNIGHT);
        if (!midnight.isAuthorized(msg.sender, SETTER_RATIFIER)) {
            midnight.setIsAuthorized(SETTER_RATIFIER, true, msg.sender);
        }

        ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, newRoot, true);

        for (uint256 i; i < rootsToCancel.length; i++) {
            require(rootsToCancel[i] != newRoot, NewRootCannotBeCancelled());
            ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, rootsToCancel[i], false);
        }
        for (uint256 i; i < groupsToCancel.length; i++) {
            midnight.setConsumed(groupsToCancel[i], type(uint128).max, msg.sender);
        }

        (bool success, bytes memory returndata) = LOG.call(payload);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}
