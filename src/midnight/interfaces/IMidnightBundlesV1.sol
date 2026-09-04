// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Offer, Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {TokenPermit} from "../../libraries/TokenLib.sol";

struct OfferFill {
    Offer offer;
    bytes ratifierData;
    uint256 units;
}

struct CollateralWithdrawal {
    uint256 collateralIndex;
    uint256 assets;
}

struct CollateralSupply {
    uint256 collateralIndex;
    uint256 assets;
    TokenPermit permit;
}

interface IMidnightBundlesV1 {
    /// ERRORS ///
    error ContinuousFeeAboveMax();
    error DeadlinePassed();
    error InconsistentMarket();
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

    // forgefmt: disable-start
    /// FUNCTIONS ///
    function midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(Market memory market, uint256 targetUnits, uint256 maxBuyerAssets, uint256 repayUnits, address taker, bool reduceOnly, TokenPermit memory loanTokenPermit, OfferFill[] memory offerFills, CollateralWithdrawal[] memory collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) external;
    function midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(Market memory market, uint256 targetUnits, uint256 minSellerAssets, uint256 withdrawUnits, address taker, bool reduceOnly, address receiver, CollateralSupply[] memory collateralSupplies, OfferFill[] memory offerFills, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) external;
    function midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(Market memory market, uint256 targetBuyerAssets, uint256 minUnits, uint256 repayUnits, address taker, bool reduceOnly, TokenPermit memory loanTokenPermit, OfferFill[] memory offerFills, CollateralWithdrawal[] memory collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) external;
    function midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(Market memory market, uint256 targetSellerAssets, uint256 maxUnits, uint256 withdrawUnits, address taker, bool reduceOnly, address receiver, CollateralSupply[] memory collateralSupplies, OfferFill[] memory offerFills, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) external;
    // forgefmt: disable-end
}
