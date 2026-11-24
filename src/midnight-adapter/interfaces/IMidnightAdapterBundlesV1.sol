// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Market} from "../../../lib/midnight/src/interfaces/IMidnight.sol";
import {OfferFill} from "../../midnight/interfaces/IMidnightBundlesV2.sol";

/// @dev Lets an allocator of a Vault V2 take several Midnight offers through the vault's MidnightAdapter in one
/// transaction, with slippage protection.
/// @dev This contract must be an allocator of the vault: MidnightAdapter.take only accepts vault allocators.
/// @dev The only state-changing calls this contract makes are Midnight.touchMarket and MidnightAdapter.take.
/// @dev It holds no tokens and gives no approvals. The vault pays and receives through the adapter's callbacks.
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

    /// @dev Buys credit for `adapter`'s parent vault by taking sell offers, in the order given.
    /// @dev msg.sender must be an allocator of the adapter's parent vault.
    /// @dev The vault spends exactly targetBuyerAssets (settlement fee included), or the call reverts with OutOfOffers.
    /// @dev The adapter gains at least minUnits, or the call reverts with UnitsTooLow.
    /// @dev An offer whose take reverts is skipped, including reverts from the adapter's and the vault's checks.
    /// @dev takerCallbackData is forwarded to the adapter and selects the funding source:
    /// abi.encode(address(0), "") for the vault's idle assets.
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

    /// @dev Buys exactly targetUnits of credit for `adapter`'s parent vault by taking sell offers.
    /// @dev The vault spends at most maxBuyerAssets, or the call reverts with BuyerAssetsTooHigh.
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

    /// @dev Sells credit of `adapter`'s parent vault by taking buy offers until the vault has received exactly
    /// targetSellerAssets.
    /// @dev The adapter sells at most maxUnits, or the call reverts with UnitsTooHigh.
    /// @dev Does not withdraw already-repaid credit first.
    function midnightAdapterBundlesV1SellWithAssetsTarget(
        address adapter,
        Market memory market,
        uint256 targetSellerAssets,
        uint256 maxUnits,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external;

    /// @dev Sells exactly targetUnits of credit of `adapter`'s parent vault by taking buy offers.
    /// @dev targetUnits = type(uint256).max targets the adapter's credit in the market at execution.
    /// @dev The vault receives at least minSellerAssets, or the call reverts with SellerAssetsTooLow.
    /// @dev Does not withdraw already-repaid credit first.
    function midnightAdapterBundlesV1SellWithUnitsTarget(
        address adapter,
        Market memory market,
        uint256 targetUnits,
        uint256 minSellerAssets,
        OfferFill[] memory offerFills,
        uint256 deadline
    ) external;
}
