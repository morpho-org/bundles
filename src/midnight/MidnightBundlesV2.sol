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

/// @dev Maker-side Midnight offer creation and reposting, including callback-funded lend offers and collateralized borrow offers.
/// @dev The maker must authorize this contract on Midnight beforehand.
/// @dev Inherits the token safety requirements of Midnight and Morpho Blue.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
contract MidnightBundlesV2 is IMidnightBundlesV2 {
    address public immutable MIDNIGHT;
    address public immutable BLUE;
    address public immutable BLUE_BUY_CALLBACK_FACTORY;
    address public immutable LOG;
    address public immutable SETTER_RATIFIER;

    constructor(
        address _midnight,
        address _blue,
        address _blueBuyCallbackFactory,
        address _log,
        address _setterRatifier
    ) {
        require(
            IBlueBuyCallbackFactory(_blueBuyCallbackFactory).MIDNIGHT() == _midnight
                && ISetterRatifier(_setterRatifier).MIDNIGHT() == _midnight,
            InconsistentMidnight()
        );
        require(IBlueBuyCallbackFactory(_blueBuyCallbackFactory).BLUE() == _blue, InconsistentBlue());

        MIDNIGHT = _midnight;
        BLUE = _blue;
        BLUE_BUY_CALLBACK_FACTORY = _blueBuyCallbackFactory;
        LOG = _log;
        SETTER_RATIFIER = _setterRatifier;
    }

    /// EXTERNAL ///

    /// @dev Optionally parks loan assets on Blue for msg.sender's derived callback.
    /// @dev Buy offers intended to be funded by the assets supplied to Blue must set Offer.callback to the derived BlueBuyCallback address and Offer.callbackData to abi.encode(blueMarket).
    /// @dev Optionally supplies collateral to msg.sender on Midnight.
    /// @dev If newRoot is non-zero, authorizes SETTER_RATIFIER, activates newRoot, and publishes payload. Otherwise payload is ignored and SETTER_RATIFIER authorization is unchanged.
    /// @dev Set assetsToPark to zero and pass an empty collateralSupplies array to repost or cancel without moving assets. blueMarket and callbackSalt are unused when assetsToPark is zero; market is unused when all collateral supplies are zero.
    /// @dev msg.sender must approve this contract for all supplied loan and collateral assets beforehand.
    /// @dev The new root may contain offers for multiple markets.
    /// @dev Share-price slippage when parking assets on Blue is not checked. Users must only use markets protected against supply-share-price inflation attacks.
    /// @dev This bundle does not check that:
    /// - Offers in newRoot or payload match the intended use case (lend limit or borrow limit) and the supplied funding or collateral inputs.
    /// - newRoot corresponds to the offers described by payload. The payload posted to LOG is not validated against any on-chain state or bundle inputs.
    /// @dev Cancel prior offers before reposting to avoid leaving both old and new offers takeable. Include their group IDs in groupsToCancel and use fresh group IDs for the new offers.
    function midnightBundlesV2Make(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        Market memory market,
        CollateralSupply[] memory collateralSupplies,
        bytes32 newRoot,
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

        for (uint256 i; i < collateralSupplies.length; i++) {
            CollateralSupply memory collateralSupply = collateralSupplies[i];
            if (collateralSupply.assets > 0) {
                address collateralToken = market.collateralParams[collateralSupply.collateralIndex].token;
                SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), collateralSupply.assets);
                TokenLib.forceApproveMax(collateralToken, MIDNIGHT);
                IMidnight(MIDNIGHT)
                    .supplyCollateral(market, collateralSupply.collateralIndex, collateralSupply.assets, msg.sender);
            }
        }

        for (uint256 i; i < groupsToCancel.length; i++) {
            IMidnight(MIDNIGHT).setConsumed(groupsToCancel[i], type(uint128).max, msg.sender);
        }

        if (newRoot != bytes32(0)) {
            IMidnight(MIDNIGHT).setIsAuthorized(SETTER_RATIFIER, true, msg.sender);
            ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(msg.sender, newRoot, true);

            (bool success, bytes memory returndata) = LOG.call(payload);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
    }

    /// @dev Cancels each group for msg.sender by setting its consumed assets to type(uint128).max on Midnight.
    function midnightBundlesV2Cancel(bytes32[] memory groupsToCancel) external {
        for (uint256 i; i < groupsToCancel.length; i++) {
            IMidnight(MIDNIGHT).setConsumed(groupsToCancel[i], type(uint128).max, msg.sender);
        }
    }
}
