// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {OfferFill} from "../../midnight/interfaces/IMidnightBundlesV2.sol";

interface IMidnightAdapterBundlesV1 {
    /// ERRORS ///
    error BuyerAssetsTooHigh();
    error ContinuousFeeAboveMax();
    error DeadlinePassed();
    error InconsistentMarket();
    error InconsistentSide();
    error OutOfOffers();
    error Reentrancy();
    error SellerAssetsTooLow();
    error Unauthorized();
    error UnitsTooHigh();
    error UnitsTooLow();

    /// STORAGE GETTERS ///
    function MIDNIGHT() external view returns (address);

    /// FUNCTIONS ///
    function midnightAdapterBundlesV1BuyWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetBuyerAssets,
        uint256 minUnits,
        OfferFill[] memory offerFills,
        bytes memory takerCallbackData,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external;

    function midnightAdapterBundlesV1BuyWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 maxBuyerAssets,
        OfferFill[] memory offerFills,
        bytes memory takerCallbackData,
        uint256 maxContinuousFee,
        uint256 deadline
    ) external;

    function midnightAdapterBundlesV1SellWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external;

    function midnightAdapterBundlesV1SellWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external;
}
