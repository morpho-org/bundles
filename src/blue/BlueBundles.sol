// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.34;

import {IBlueBundles} from "./IBlueBundles.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {IMorpho, MarketParams, Position} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoRepayCallback} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {IERC20} from "../../lib/midnight/src/interfaces/IERC20.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";

/// @dev Inherits the token safety requirements of Morpho Blue (see Morpho.sol).
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract BlueBundles is IBlueBundles, IMorphoRepayCallback {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;

    struct RefinanceData {
        MarketParams sourceMarketParams;
        MarketParams destMarketParams;
        uint256 collateral;
        uint256 maxLtvPct;
        address onBehalf;
        uint256 referralFeePct;
        address referralFeeRecipient;
    }

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

        TokenLib.pullToken(marketParams.collateralToken, msg.sender, collateralAmount, collateralPermit);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

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

        TokenLib.pullToken(marketParams.loanToken, msg.sender, repayAssets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

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

        TokenLib.pullToken(marketParams.loanToken, msg.sender, assets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

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

    /// @dev The onBehalf must have authorized this contract and the msg.sender (if different from onBehalf) on Blue.
    /// @dev Moves the full position of onBehalf (collateral and borrow shares, read from Blue) from the source market
    /// to the destination market via Blue's repay callback, pulling no tokens from msg.sender.
    /// @dev The markets must have the same loan token and the same collateral token.
    /// @dev The referral fee is borrowed on the destination on top of the assets repaid on the source, so it adds to
    /// the destination debt and lowers the resulting health factor.
    /// @dev Fee = repaidAssets * referralFeePct / WAD; total borrowed on the destination = repaidAssets + fee.
    /// @dev maxLtvPct bounds the resulting destination LTV relative to the destination LLTV (fee included): total
    /// borrowed <= collateral value * destLltv * maxLtvPct / WAD. maxLtvPct = WAD adds no bound beyond Blue's own
    /// health check.
    /// @dev Refinancing a position without debt reverts on Blue.
    function refinance(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 maxLtvPct,
        address onBehalf,
        uint256 referralFeePct,
        address referralFeeRecipient
    ) external {
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD && maxLtvPct <= WAD, PctExceeded());
        require(
            sourceMarketParams.loanToken == destMarketParams.loanToken
                && sourceMarketParams.collateralToken == destMarketParams.collateralToken,
            InconsistentTokens()
        );

        Position memory position = IMorpho(BLUE).position(sourceMarketParams.id(), onBehalf);

        bytes memory data = abi.encode(
            RefinanceData({
                sourceMarketParams: sourceMarketParams,
                destMarketParams: destMarketParams,
                collateral: position.collateral,
                maxLtvPct: maxLtvPct,
                onBehalf: onBehalf,
                referralFeePct: referralFeePct,
                referralFeeRecipient: referralFeeRecipient
            })
        );
        IMorpho(BLUE).repay(sourceMarketParams, 0, position.borrowShares, onBehalf, data);
    }

    /// @dev Blue's repay callback. Only reachable during refinance: no other function passes non-empty data to repay.
    /// @dev Blue pulls exactly `assets` of the loan token from this contract after this callback returns.
    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        RefinanceData memory d = abi.decode(data, (RefinanceData));

        uint256 referralFeeAssets = assets.mulDivDown(d.referralFeePct, WAD);
        uint256 borrowAssets = assets + referralFeeAssets;

        // Mirrors Blue's health check rounding (allowance rounded down); at maxLtvPct == WAD it is Blue's maxBorrow.
        uint256 price = IOracle(d.destMarketParams.oracle).price();
        uint256 maxBorrow = d.collateral.mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(d.destMarketParams.lltv, WAD)
            .mulDivDown(d.maxLtvPct, WAD);
        require(borrowAssets <= maxBorrow, LtvExceeded());

        IMorpho(BLUE).withdrawCollateral(d.sourceMarketParams, d.collateral, d.onBehalf, address(this));

        TokenLib.forceApproveMax(d.destMarketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(d.destMarketParams, d.collateral, d.onBehalf, "");
        IMorpho(BLUE).borrow(d.destMarketParams, borrowAssets, 0, d.onBehalf, address(this));

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(d.destMarketParams.loanToken, d.referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(d.destMarketParams.loanToken, BLUE);
    }
}
