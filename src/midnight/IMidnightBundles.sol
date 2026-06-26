// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity >=0.5.0;

import {Offer, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {TokenPermit} from "../libraries/TokenLib.sol";

struct Take {
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

interface IMidnightBundles {
    /// ERRORS ///
    error DeadlinePassed();
    error InconsistentMarket();
    error InconsistentSide();
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
    function midnightBundlesBuyWithUnitsTargetAndWithdrawCollateral(uint256 targetUnits, uint256 maxBuyerAssets, address taker, TokenPermit memory loanTokenPermit, Take[] memory takes, CollateralWithdrawal[] memory collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) external;
    function midnightBundlesSupplyCollateralAndSellWithUnitsTarget(uint256 targetUnits, uint256 minSellerAssets, address taker, address receiver, CollateralSupply[] memory collateralSupplies, Take[] memory takes, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) external;
    function midnightBundlesBuyWithAssetsTargetAndWithdrawCollateral(uint256 targetBuyerAssets, uint256 minUnits, address taker, TokenPermit memory loanTokenPermit, Take[] memory takes, CollateralWithdrawal[] memory collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) external;
    function midnightBundlesSupplyCollateralAndSellWithAssetsTarget(uint256 targetSellerAssets, uint256 maxUnits, address taker, address receiver, CollateralSupply[] memory collateralSupplies, Take[] memory takes, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) external;
    function midnightBundlesRepayAndWithdrawCollateral(Market memory market, uint256 assets, address onBehalf, TokenPermit memory loanTokenPermit, CollateralWithdrawal[] memory collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) external;
    // forgefmt: disable-end
}
