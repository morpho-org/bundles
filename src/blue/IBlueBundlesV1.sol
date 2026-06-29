// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenPermit} from "../libraries/TokenLib.sol";

interface IBlueBundlesV1 {
    /// ERRORS ///
    error PctExceeded();
    error Unauthorized();
    error UnauthorizedCallback();
    error InconsistentTokens();
    error LtvExceeded();
    error DeadlinePassed();

    /// STORAGE GETTERS ///
    function BLUE() external view returns (address);

    /// FUNCTIONS ///
    function blueBundlesV1SupplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 borrowAssets,
        uint256 maxLtv,
        address onBehalf,
        address receiver,
        TokenPermit memory collateralPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1RepayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 maxRepayAssets,
        uint256 withdrawCollateralAssets,
        uint256 maxLtv,
        address onBehalf,
        address receiver,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1Supply(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1Withdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        address onBehalf,
        address receiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1MigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 maxLtv,
        address onBehalf,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
