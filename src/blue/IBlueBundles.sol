// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity >=0.5.0;

import {MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenPermit} from "../libraries/TokenLib.sol";

interface IBlueBundles {
    /// ERRORS ///
    error PctExceeded();
    error Unauthorized();
    error UnauthorizedCallback();
    error InconsistentTokens();
    error LtvExceeded();

    /// STORAGE GETTERS ///
    function PERMIT2() external view returns (address);
    function BLUE() external view returns (address);

    /// FUNCTIONS ///
    function supplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 borrowAssets,
        uint256 maxLtv,
        address onBehalf,
        address receiver,
        TokenPermit memory collateralPermit,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external;

    function repayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 withdrawCollateralAssets,
        uint256 maxLtv,
        address onBehalf,
        address receiver,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external;

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external;

    function withdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        address onBehalf,
        address receiver,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external;

    function migrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 maxLtv,
        address onBehalf,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external;
}
