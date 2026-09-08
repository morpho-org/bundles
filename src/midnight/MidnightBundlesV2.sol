// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "../../lib/midnight/src/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import {IEcrecoverRatifier} from "../../lib/midnight/src/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {ISetterRatifier} from "../../lib/midnight/src/ratifiers/interfaces/ISetterRatifier.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IMidnightBundlesV2, CollateralSupply} from "./interfaces/IMidnightBundlesV2.sol";

/// @dev Maker-side Midnight offer creation and reposting, including callback-funded lend offers and collateralized
/// borrow offers.
/// @dev The maker must authorize this contract on Midnight beforehand.
/// @dev Reposting deactivates selected Setter roots, permanently cancels selected Ecrecover roots, cancels selected
/// groups, authorizes SETTER_RATIFIER, activates the new Setter root, then publishes the payload through LOG.
/// @dev SETTER_RATIFIER is authorized on behalf of the maker when a new root is activated.
/// @dev Replacement offers must not use a group passed in groupsToCancel.
/// @dev Inherits the token safety requirements of Midnight and Morpho Blue.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
contract MidnightBundlesV2 is IMidnightBundlesV2 {
    address public immutable MIDNIGHT;
    address public immutable BLUE;
    address public immutable BLUE_BUY_CALLBACK_FACTORY;
    address public immutable LOG;
    address public immutable SETTER_RATIFIER;
    address public immutable ECRECOVER_RATIFIER;

    constructor(
        address _midnight,
        address _blueBuyCallbackFactory,
        address _log,
        address _setterRatifier,
        address _ecrecoverRatifier
    ) {
        require(
            IBlueBuyCallbackFactory(_blueBuyCallbackFactory).MIDNIGHT() == _midnight
                && ISetterRatifier(_setterRatifier).MIDNIGHT() == _midnight
                && IEcrecoverRatifier(_ecrecoverRatifier).MIDNIGHT() == _midnight,
            InconsistentMidnight()
        );

        MIDNIGHT = _midnight;
        BLUE = IBlueBuyCallbackFactory(_blueBuyCallbackFactory).BLUE();
        BLUE_BUY_CALLBACK_FACTORY = _blueBuyCallbackFactory;
        LOG = _log;
        SETTER_RATIFIER = _setterRatifier;
        ECRECOVER_RATIFIER = _ecrecoverRatifier;
    }

    /// EXTERNAL ///

    /// @dev If assetsToPark is non-zero, pulls the assets from msg.sender and supplies them on Blue on behalf of
    /// msg.sender's callback derived from callbackSalt, creating the callback if necessary. Then reposts the maker's
    /// offers.
    /// @dev msg.sender must approve this contract for at least assetsToPark beforehand.
    /// @dev Offers intended to use the parked assets must be buy offers whose callback is the derived callback and whose
    /// callbackData is abi.encode(blueMarket).
    /// @dev Share-price slippage when parking assets on Blue is not checked. Users must only use markets protected
    /// against supply-share-price inflation attacks.
    function midnightBundlesV2LendLimitWithBlueBuyCallback(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        bytes32 newRoot,
        bytes32[] memory setterRootsToDeactivate,
        bytes32[] memory ecrecoverRootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        if (assetsToPark > 0) {
            address blueBuyCallback =
                IBlueBuyCallbackFactory(BLUE_BUY_CALLBACK_FACTORY).createBlueBuyCallback(msg.sender, callbackSalt);
            SafeTransferLib.safeTransferFrom(blueMarket.loanToken, msg.sender, address(this), assetsToPark);
            TokenLib.forceApproveMax(blueMarket.loanToken, BLUE);
            IMorpho(BLUE).supply(blueMarket, assetsToPark, 0, blueBuyCallback, "");
        }

        repost(newRoot, setterRootsToDeactivate, ecrecoverRootsToCancel, groupsToCancel, payload);
    }

    /// @dev Pulls each non-zero collateral supply from msg.sender, supplies it to msg.sender's position on market, then
    /// reposts the maker's offers.
    /// @dev msg.sender must approve this contract for each collateral token beforehand.
    /// @dev newRoot is expected to contain sell offers made by msg.sender, but may also contain offers for other markets.
    function midnightBundlesV2BorrowLimit(
        Market memory market,
        CollateralSupply[] memory collateralSupplies,
        bytes32 newRoot,
        bytes32[] memory setterRootsToDeactivate,
        bytes32[] memory ecrecoverRootsToCancel,
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

        repost(newRoot, setterRootsToDeactivate, ecrecoverRootsToCancel, groupsToCancel, payload);
    }

    /// @dev Invalidates selected roots and groups, authorizes SETTER_RATIFIER, activates the new Setter root, then
    /// publishes payload.
    function midnightBundlesV2Repost(
        bytes32 newRoot,
        bytes32[] memory setterRootsToDeactivate,
        bytes32[] memory ecrecoverRootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        repost(newRoot, setterRootsToDeactivate, ecrecoverRootsToCancel, groupsToCancel, payload);
    }

    /// @dev Deactivates selected Setter roots, permanently cancels selected Ecrecover roots, and cancels selected
    /// groups. Does not activate or publish a new root.
    function midnightBundlesV2Cancel(
        bytes32[] memory setterRootsToDeactivate,
        bytes32[] memory ecrecoverRootsToCancel,
        bytes32[] memory groupsToCancel,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());

        for (uint256 i; i < setterRootsToDeactivate.length; i++) {
            ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, setterRootsToDeactivate[i], false);
        }
        for (uint256 i; i < ecrecoverRootsToCancel.length; i++) {
            IEcrecoverRatifier(ECRECOVER_RATIFIER).cancelRoot(msg.sender, ecrecoverRootsToCancel[i]);
        }
        for (uint256 i; i < groupsToCancel.length; i++) {
            IMidnight(MIDNIGHT).setConsumed(groupsToCancel[i], type(uint128).max, msg.sender);
        }
    }

    /// INTERNAL ///

    function repost(
        bytes32 newRoot,
        bytes32[] memory setterRootsToDeactivate,
        bytes32[] memory ecrecoverRootsToCancel,
        bytes32[] memory groupsToCancel,
        bytes memory payload
    ) internal {
        IMidnight midnight = IMidnight(MIDNIGHT);

        for (uint256 i; i < setterRootsToDeactivate.length; i++) {
            require(setterRootsToDeactivate[i] != newRoot, NewRootCannotBeDeactivated());
            ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, setterRootsToDeactivate[i], false);
        }
        for (uint256 i; i < ecrecoverRootsToCancel.length; i++) {
            IEcrecoverRatifier(ECRECOVER_RATIFIER).cancelRoot(msg.sender, ecrecoverRootsToCancel[i]);
        }
        for (uint256 i; i < groupsToCancel.length; i++) {
            midnight.setConsumed(groupsToCancel[i], type(uint128).max, msg.sender);
        }

        midnight.setIsAuthorized(SETTER_RATIFIER, true, msg.sender);

        ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, newRoot, true);

        (bool success, bytes memory returndata) = LOG.call(payload);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}
