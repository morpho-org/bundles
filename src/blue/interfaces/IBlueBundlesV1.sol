// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams, Signature} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {TokenPermit} from "../../libraries/TokenLib.sol";

/// @dev An empty signature (v, r and s all zero) means no authorization is submitted.
/// @dev The signature deadline is independent of the call deadline: an unsubmitted signature stays submittable until deadline, as revoking on Blue does not consume the nonce.
struct SignedAuthorization {
    Signature signature;
    uint256 nonce;
    uint256 deadline;
}

/// @dev When fromIdle is true, the vault's idle assets are allocated and sourceAdapter and sourceMarketParams are ignored; otherwise assets are first deallocated from sourceAdapter's sourceMarketParams.
/// @dev penalty is the exact WAD-scaled penalty rate and must equal the vault's configured penalty when the allocation executes.
struct PublicAllocations {
    address vault;
    address adapter;
    MarketParams marketParams;
    bool fromIdle;
    address sourceAdapter;
    MarketParams sourceMarketParams;
    uint128 assets;
    uint64 penalty;
}

interface IBlueBundlesV1 {
    /// ERRORS ///
    error DeadlinePassed();
    error InconsistentTokens();
    error LtvExceeded();
    error NativeTransferFailed();
    error PctExceeded();
    error SlippageExceeded();
    error UnauthorizedCallback();

    /// STORAGE GETTERS ///
    function BLUE() external view returns (address);
    function PUBLIC_ALLOCATOR() external view returns (address);

    /// FUNCTIONS ///
    function blueBundlesV1SupplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 borrowAssets,
        uint256 minSharePriceE27,
        uint256 maxLtv,
        TokenPermit memory collateralPermit,
        SignedAuthorization memory signedAuthorization,
        PublicAllocations[] memory reallocations,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external payable;

    function blueBundlesV1RepayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 repayShares,
        uint256 maxRepayAssets,
        uint256 maxSharePriceE27,
        uint256 collateralAssets,
        uint256 maxLtv,
        TokenPermit memory loanTokenPermit,
        SignedAuthorization memory signedAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external payable;

    function blueBundlesV1Supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 maxSharePriceE27,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external payable;

    function blueBundlesV1Withdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        uint256 withdrawShares,
        SignedAuthorization memory signedAuthorization,
        PublicAllocations[] memory reallocations,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;

    function blueBundlesV1MigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 sourceMaxSharePriceE27,
        uint256 destMinSharePriceE27,
        uint256 maxLtv,
        SignedAuthorization memory signedAuthorization,
        PublicAllocations[] memory reallocations,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external;
}
