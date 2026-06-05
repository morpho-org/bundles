// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.34;

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IBlueBundles} from "./IBlueBundles.sol";
import {IERC20} from "midnight/interfaces/IERC20.sol";
import {SafeTransferLib} from "midnight/libraries/SafeTransferLib.sol";
import {UtilsLib} from "midnight/libraries/UtilsLib.sol";
import {WAD} from "midnight/libraries/ConstantsLib.sol";
import {BlueBundlesUtils, TokenPermit} from "./BlueBundlesUtils.sol";

/// @dev Inherits the token safety requirements of Morpho Blue (see Morpho.sol).
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract BlueBundles is IBlueBundles {
    using UtilsLib for uint256;

    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public immutable BLUE;

    constructor(address _blue) {
        BLUE = _blue;
    }

    /// EXTERNAL ///

    /// @dev The onBehalf must have authorized this contract and the msg.sender (if different from onBehalf) on Blue.
    /// @dev Pulls `collateralAmount` of `marketParams.collateralToken` from msg.sender (optionally via ERC-2612 or
    /// Permit2), supplies it as collateral on Blue for onBehalf, then borrows `borrowAssets` of the loan token on
    /// behalf of onBehalf, routed via this contract.
    /// @dev Total loan assets routed: borrowedAssets - referralFeeAssets to receiver, referralFeeAssets to
    /// referralFeeRecipient.
    /// @dev Fee = borrowedAssets * referralFeePct / WAD; net = borrowedAssets - fee.
    function supplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 borrowAssets,
        address onBehalf,
        address receiver,
        TokenPermit memory collateralPermit,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external {
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());

        BlueBundlesUtils.pullToken(marketParams.collateralToken, msg.sender, collateralAmount, collateralPermit);
        BlueBundlesUtils.forceApproveMax(marketParams.collateralToken, BLUE);

        IMorpho(BLUE).supplyCollateral(marketParams, collateralAmount, onBehalf, "");
        (uint256 borrowed,) = IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, onBehalf, address(this));

        uint256 referralFeeAssets = borrowed.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, receiver, borrowed - referralFeeAssets);
    }

    /// @dev The onBehalf must have authorized this contract and the msg.sender (if different from onBehalf) on Blue.
    /// @dev Pulls `repayAssets` of `marketParams.loanToken` from msg.sender (optionally via ERC-2612 or Permit2).
    /// @dev The referral fee is deducted from repayAssets; the remainder is repaid against onBehalf's debt.
    /// @dev If `withdrawCollateralAssets > 0`, also withdraws that amount of collateral from onBehalf's position to
    /// receiver.
    /// @dev Any leftover loan tokens (e.g. due to share-rounding overshoot on repay) are refunded to msg.sender.
    /// @dev Fee = repayAssets * referralFeePct / WAD; units repaid = repayAssets - fee.
    function repayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 withdrawCollateralAssets,
        address onBehalf,
        address receiver,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external {
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());

        uint256 referralFeeAssets = repayAssets.mulDivDown(referralFeePct, WAD);
        uint256 toRepay = repayAssets - referralFeeAssets;

        BlueBundlesUtils.pullToken(marketParams.loanToken, msg.sender, repayAssets, loanTokenPermit);
        BlueBundlesUtils.forceApproveMax(marketParams.loanToken, BLUE);

        IMorpho(BLUE).repay(marketParams, toRepay, 0, onBehalf, "");

        if (withdrawCollateralAssets > 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, withdrawCollateralAssets, onBehalf, receiver);
        }

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }

        // Refund any leftover loan tokens (Blue may have used slightly less than toRepay due to share rounding).
        uint256 leftover = IERC20(marketParams.loanToken).balanceOf(address(this));
        if (leftover > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, leftover);
        }
    }

    /// @dev Supply is permissionless on Blue, so no authorization of msg.sender over onBehalf is required.
    /// @dev Pulls `assets` of `marketParams.loanToken` from msg.sender (optionally via ERC-2612 or Permit2).
    /// @dev The referral fee is deducted from `assets`; the remainder is supplied to the market for onBehalf.
    /// @dev Fee = assets * referralFeePct / WAD; supplied = assets - fee.
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        TokenPermit memory loanTokenPermit,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external {
        require(referralFeePct < WAD, PctExceeded());

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD);
        uint256 toSupply = assets - referralFeeAssets;

        BlueBundlesUtils.pullToken(marketParams.loanToken, msg.sender, assets, loanTokenPermit);
        BlueBundlesUtils.forceApproveMax(marketParams.loanToken, BLUE);

        // assets specified => Blue pulls exactly `toSupply`, so no leftover refund is needed.
        IMorpho(BLUE).supply(marketParams, toSupply, 0, onBehalf, "");

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
    }

    /// @dev The onBehalf must have authorized this contract and the msg.sender (if different from onBehalf) on Blue.
    /// @dev Withdraws `withdrawAssets` of `marketParams.loanToken` from onBehalf's supply position, routed via this
    /// contract.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to receiver.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
    function withdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        address onBehalf,
        address receiver,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external {
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());

        (uint256 withdrawn,) = IMorpho(BLUE).withdraw(marketParams, withdrawAssets, 0, onBehalf, address(this));

        uint256 referralFeeAssets = withdrawn.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, receiver, withdrawn - referralFeeAssets);
    }
}
