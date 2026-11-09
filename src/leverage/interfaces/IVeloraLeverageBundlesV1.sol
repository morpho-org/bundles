// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

interface IVeloraLeverageBundlesV1 {
    error DeadlinePassed();
    error IncompleteFill();
    error InvalidSelector();
    error LtvExceeded();
    error Reentrancy();
    error UnauthorizedCallback();
    error ZeroCollateralToBuy();
    error ZeroSwapAmount();

    function BLUE() external view returns (address);
    function AUGUSTUS() external view returns (address);

    function veloraLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    function veloraLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    function veloraLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external;

    /// @notice Opens a leveraged position with an exact-input SELL swap.
    /// @param collateralAssets Collateral-token amount to pull from the caller.
    /// @param borrowAssets Loan-token amount to borrow and sell.
    /// @param minCollateralOut Minimum collateral-token amount the swap must return.
    /// @param swapData Augustus v6.2 exact-input calldata with `beneficiary` set to this bundle.
    /// @param maxLtv Maximum resulting LTV of the caller's position; type(uint256).max disables the check.
    /// @dev Augustus's minimum output is set to `minCollateralOut + 1` for its payout retention.
    function veloraLeverageBundlesV1OpenExactIn(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 borrowAssets,
        uint256 minCollateralOut,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    /// @notice Repays part of the caller's debt by selling an exact amount of collateral.
    /// @param collateralToSell Collateral-token amount to sell.
    /// @param minRepayAssets Minimum loan-token amount the swap must return for repayment.
    /// @param swapData Augustus v6.2 exact-input calldata with `beneficiary` set to this bundle.
    /// @param maxLtv Maximum resulting LTV of the caller's position; type(uint256).max disables the check.
    /// @dev Augustus's minimum output is set to `minRepayAssets + 1` for its payout retention.
    function veloraLeverageBundlesV1DeleverExactIn(
        MarketParams memory marketParams,
        uint256 collateralToSell,
        uint256 minRepayAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external;

    /// @notice Closes a position by selling all collateral and returning remaining loan tokens as equity.
    /// @param minLoanOut Minimum total loan-token output, including the amount used to repay debt.
    /// @param swapData Augustus v6.2 exact-input calldata with `beneficiary` set to this bundle.
    /// @dev Augustus's minimum output is set to `max(minLoanOut, debt) + 1` for its payout retention.
    function veloraLeverageBundlesV1CloseExactIn(
        MarketParams memory marketParams,
        uint256 minLoanOut,
        bytes calldata swapData,
        uint256 deadline
    ) external;
}
