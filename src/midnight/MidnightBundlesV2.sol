// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import {ISetterRatifier} from "../../lib/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IMidnightBundlesV2, CollateralSupply} from "./interfaces/IMidnightBundlesV2.sol";

/// @dev Maker-side Midnight offer creation and reposting, including callback-funded lend offers and collateralized
/// borrow offers.
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

        executeCancelAndMake(newRoot, rootsToCancel, groupsToCancel, payload);
    }

    /// @dev Pulls each collateral supply from msg.sender and supplies it to market on behalf of msg.sender. msg.sender
    /// must approve this contract for each collateral token beforehand.
    /// @dev The new root is expected to contain sell offers made by msg.sender. The collateral is supplied only to
    /// market, while the opaque root may include offers for other markets and is not validated onchain.
    /// @dev This contract must be authorized by msg.sender on Midnight.
    function midnightBundlesV2BorrowLimit(
        Market memory market,
        CollateralSupply[] memory collateralSupplies,
        bytes32 newRoot,
        bytes32[] memory rootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        IMidnight midnight = IMidnight(MIDNIGHT);
        for (uint256 i; i < collateralSupplies.length; i++) {
            uint256 assets = collateralSupplies[i].assets;
            if (assets > 0) {
                uint256 collateralIndex = collateralSupplies[i].collateralIndex;
                address collateralToken = market.collateralParams[collateralIndex].token;
                SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), assets);
                TokenLib.forceApproveMax(collateralToken, MIDNIGHT);
                midnight.supplyCollateral(market, collateralIndex, assets, msg.sender);
            }
        }

        executeCancelAndMake(newRoot, rootsToCancel, groupsToCancel, payload);
    }

    /// @dev Activates a new maker offer root, deactivates selected roots, cancels selected offer groups, and publishes
    /// payload through LOG. The opaque root and payload are not validated onchain in order to support multi-market
    /// offers.
    /// @dev This contract must be authorized by msg.sender on Midnight.
    function midnightBundlesV2CancelAndMake(
        bytes32 newRoot,
        bytes32[] memory rootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        executeCancelAndMake(newRoot, rootsToCancel, groupsToCancel, payload);
    }

    /// INTERNAL ///

    function executeCancelAndMake(
        bytes32 newRoot,
        bytes32[] memory rootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload
    ) internal {
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
