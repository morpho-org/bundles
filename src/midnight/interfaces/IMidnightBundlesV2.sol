// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Offer, Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenPermit} from "../../libraries/TokenLib.sol";

struct CollateralSupply {
    uint256 collateralIndex;
    uint256 assets;
}

struct CollateralSupplyWithPermit {
    uint256 collateralIndex;
    uint256 assets;
    TokenPermit permit;
}

struct CollateralWithdrawal {
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
    error ContinuousFeeAboveMax();
    error DeadlinePassed();
    error InconsistentBlue();
    error InconsistentMarket();
    error InconsistentMidnight();
    error InconsistentSide();
    error NotReduceOnly();
    error OutOfOffers();
    error PctExceeded();
    error SellerAssetsTooLow();
    error Unauthorized();
    error UnitsTooHigh();
    error UnitsTooLow();

    /// STORAGE GETTERS ///
    function MIDNIGHT() external view returns (address);
    function BLUE() external view returns (address);
    function BLUE_BUY_CALLBACK_FACTORY() external view returns (address);
    function LOG() external view returns (address);
    function SETTER_RATIFIER() external view returns (address);

    /// FUNCTIONS ///
    function midnightBundlesV2CancelAndMake(
        MarketParams memory blueMarket,
        uint256 assetsToPark,
        bytes32 callbackSalt,
        Market memory market,
        CollateralSupply[] memory collateralSupplies,
        bytes32 newRoot,
        bytes32[] memory groupsToCancel,
        bytes memory payload,
        uint256 deadline
    ) external;

    function midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        address taker,
        bool reduceOnly,
        bool repayEnabled,
        TokenPermit memory loanTokenPermit,
        OfferFill[] memory offerFills,
        CollateralWithdrawal[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external;

    function midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        address taker,
        bool reduceOnly,
        address receiver,
        CollateralSupplyWithPermit[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external;

    function midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        address taker,
        bool reduceOnly,
        bool repayEnabled,
        TokenPermit memory loanTokenPermit,
        OfferFill[] memory offerFills,
        CollateralWithdrawal[] memory collateralWithdrawals,
        address collateralReceiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external;

    function midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        address taker,
        bool reduceOnly,
        address receiver,
        CollateralSupplyWithPermit[] memory collateralSupplies,
        OfferFill[] memory offerFills,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external;
}
