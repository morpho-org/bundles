// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Offer, Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

struct GroupCancellation {
    bytes32 group;
    uint128 maxConsumed;
}

struct CollateralTransfer {
    uint256 collateralIndex;
    uint256 assets;
}

struct OfferFill {
    Offer offer;
    bytes ratifierData;
    uint256 units;
}

interface IMidnightBundlesV2 {
    /// ERRORS ///
    error ConsumedAboveMax();
    error ContinuousFeeAboveMax();
    error DeadlinePassed();
    error InconsistentBlue();
    error InconsistentMarket();
    error InconsistentMidnight();
    error InconsistentSide();
    error InvalidRatifierResponse();
    error NotReduceOnly();
    error OutOfOffers();
    error PctExceeded();
    error SellerAssetsTooLow();
    error UnitsTooHigh();
    error UnitsTooLow();

    /// STORAGE GETTERS ///
    function MIDNIGHT() external view returns (address);
    function BLUE() external view returns (address);
    function BLUE_BUY_CALLBACK_FACTORY() external view returns (address);
    function LOG() external view returns (address);

    /// FUNCTIONS ///
    function midnightBundlesV2CancelAndMake(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        Market memory market,
        CollateralTransfer[] memory collateralSupplies,
        address ratifier,
        bytes32 newRoot,
        uint256 signatureHeight,
        uint128 signatureNonce,
        uint256 signatureDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        GroupCancellation[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline,
        address wrappedNative
    ) external payable;

    function midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        bool reduceOnly,
        bool repayEnabled,
        OfferFill[] memory offerFills,
        CollateralTransfer[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline,
        address wrappedNative
    ) external payable;

    function midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        bool reduceOnly,
        address receiver,
        CollateralTransfer[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline,
        address wrappedNative
    ) external payable;

    function midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        bool reduceOnly,
        bool repayEnabled,
        OfferFill[] memory offerFills,
        CollateralTransfer[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline,
        address wrappedNative
    ) external payable;

    function midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        bool reduceOnly,
        address receiver,
        CollateralTransfer[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline,
        address wrappedNative
    ) external payable;
}
