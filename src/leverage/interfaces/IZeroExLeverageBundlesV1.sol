// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IZeroExLeverageBundlesV1 {
    error DeadlinePassed();
    error IncompleteFill();
    error InvalidSettler();
    error InvalidSwapData();
    error LtvExceeded();
    error Reentrancy();
    error UnauthorizedCallback();
    error ZeroCollateralToBuy();

    function BLUE() external view returns (address);
    function ALLOWANCE_HOLDER() external view returns (address);
    function ZERO_EX_DEPLOYER() external view returns (address);

    /// @notice Adds caller collateral and 0x-purchased collateral to the caller's position.
    /// @param marketParams Morpho Blue market parameters.
    /// @param collateralAssets Collateral-token amount to pull from the caller.
    /// @param collateralToBuy Exact collateral-token output requested from the 0x API BUY quote.
    /// @param maxBorrowAssets Maximum loan-token amount to borrow and spend.
    /// @param swapData The 0x Swap API AllowanceHolder `transaction.data`, quoted with this bundle as taker.
    /// @param maxLtv Maximum resulting LTV; type(uint256).max disables the check.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `buyAmount` equal to `collateralToBuy`.
    function zeroExLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    /// @notice Repays part of the caller's debt using a 0x API BUY quote for loan tokens.
    /// @param marketParams Morpho Blue market parameters.
    /// @param repayAssets Exact loan-token output requested from the quote.
    /// @param maxCollateralIn Maximum collateral-token amount to withdraw and spend.
    /// @param swapData The 0x Swap API AllowanceHolder `transaction.data`, quoted with this bundle as taker.
    /// @param maxLtv Maximum resulting LTV; type(uint256).max disables the check.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `buyAmount` equal to `repayAssets`.
    function zeroExLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    /// @notice Repays all borrow shares and swaps collateral for the loan-token debt, returning unspent collateral and excess loan tokens.
    /// @param marketParams Morpho Blue market parameters.
    /// @param maxCollateralIn Maximum collateral-token amount that may be spent.
    /// @param swapData The 0x API BUY quote's AllowanceHolder `transaction.data`, with `buyAmount` set to debt plus a small buffer.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `buyAmount` equal to debt plus a small buffer; the buffer returns as loan tokens.
    function zeroExLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    /// @notice Sells the caller's entire collateral balance and returns remaining loan tokens as equity.
    /// @param marketParams Morpho Blue market parameters.
    /// @param minLoanOut Minimum total loan-token output, including the amount used to repay debt.
    /// @param swapData The 0x API SELL quote's AllowanceHolder `transaction.data`, with `sellAmount` equal to the position's full collateral.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `sellAmount` equal to the position's full collateral.
    function zeroExLeverageBundlesV1CloseExactIn(
        MarketParams memory marketParams,
        uint256 minLoanOut,
        bytes calldata swapData,
        uint256 deadline
    ) external;
}
