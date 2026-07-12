// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams, Signature} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenPermit} from "../../libraries/TokenLib.sol";

interface IBlueBundlesV1 {
    /// ERRORS ///
    error PctExceeded();
    error UnauthorizedCallback();
    error InconsistentTokens();
    error LtvExceeded();
    error SlippageExceeded();
    error DeadlinePassed();
    error InvalidAuthorizationSignature();

    /// STORAGE GETTERS ///
    function BLUE() external view returns (address);

    /// FUNCTIONS ///
    function blueBundlesV1SupplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 assets,
        uint256 minSharePriceE27,
        uint256 maxLtv,
        TokenPermit memory collateralPermit,
        Signature memory authorizationSignature,
        uint256 authorizationNonce,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1RepayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxRepayAssets,
        uint256 maxSharePriceE27,
        uint256 withdrawCollateralAssets,
        uint256 maxLtv,
        TokenPermit memory loanTokenPermit,
        Signature memory authorizationSignature,
        uint256 authorizationNonce,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1Supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 maxSharePriceE27,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1Withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        Signature memory authorizationSignature,
        uint256 authorizationNonce,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1MigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 maxSharePriceE27,
        uint256 minSharePriceE27,
        uint256 maxLtv,
        Signature memory authorizationSignature,
        uint256 authorizationNonce,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
