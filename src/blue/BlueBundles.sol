// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.34;

import {IBlueBundles} from "./IBlueBundles.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {IMorpho, MarketParams, Position, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoRepayCallback} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
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
    using SharesMathLib for uint256;

    struct MigrateBorrowPositionData {
        MarketParams sourceMarketParams;
        MarketParams destMarketParams;
        uint256 collateral;
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
    /// @dev maxLtv caps onBehalf's resulting LTV; at or above the market LLTV it is a no-op (WAD disables it).
    function supplyCollateralAndBorrow(
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
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());

        TokenLib.pullToken(marketParams.collateralToken, msg.sender, collateralAmount, collateralPermit);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        IMorpho(BLUE).supplyCollateral(marketParams, collateralAmount, onBehalf, "");
        IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, onBehalf, address(this));

        requireMaxLtv(marketParams, onBehalf, maxLtv);

        uint256 referralFeeAssets = borrowAssets.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, receiver, borrowAssets - referralFeeAssets);
    }

    /// @dev The onBehalf must have authorized this contract and the msg.sender (if different from onBehalf) on Blue.
    /// @dev Pulls maxRepayAssets from msg.sender, and reimburse the unused remainder at the end of the call.
    /// @dev If assets == type(uint256).max, the full debt is closed by shares.
    /// @dev The fee is repaidAmount * referralFeePct / (WAD - referralFeePct).
    /// @dev If withdrawCollateralAssets > 0, also withdraws that amount of collateral from onBehalf's position to receiver.
    /// @dev maxLtv caps onBehalf's resulting LTV after a withdrawal; skipped on a pure repay.
    function repayAndWithdrawCollateral(
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
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());

        TokenLib.pullToken(marketParams.loanToken, msg.sender, maxRepayAssets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        uint256 repayAssets = assets == type(uint256).max ? 0 : assets;
        uint256 repayShares =
            assets == type(uint256).max ? IMorpho(BLUE).position(marketParams.id(), onBehalf).borrowShares : 0;
        (uint256 repaidAmount,) = IMorpho(BLUE).repay(marketParams, repayAssets, repayShares, onBehalf, "");

        if (withdrawCollateralAssets > 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, withdrawCollateralAssets, onBehalf, receiver);
            requireMaxLtv(marketParams, onBehalf, maxLtv);
        }

        uint256 referralFeeAssets = repaidAmount.mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(
            marketParams.loanToken, receiver, maxRepayAssets - repaidAmount - referralFeeAssets
        );
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
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD);
        uint256 toSupply = assets - referralFeeAssets;

        TokenLib.pullToken(marketParams.loanToken, msg.sender, assets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        IMorpho(BLUE).supply(marketParams, toSupply, 0, onBehalf, "");

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
    }

    /// @dev The onBehalf must have authorized this contract and the msg.sender (if different from onBehalf) on Blue.
    /// @dev Withdraws `withdrawAssets` of `marketParams.loanToken` from onBehalf's supply position, routed via this
    /// contract.
    /// @dev If `withdrawAssets == type(uint256).max`, the full supply position is closed by shares so no supply
    /// shares remain.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to receiver.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
    function withdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        address onBehalf,
        address receiver,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());

        uint256 withdrawn;
        if (withdrawAssets == type(uint256).max) {
            uint256 supplyShares = IMorpho(BLUE).position(marketParams.id(), onBehalf).supplyShares;
            (withdrawn,) = IMorpho(BLUE).withdraw(marketParams, 0, supplyShares, onBehalf, address(this));
        } else {
            (withdrawn,) = IMorpho(BLUE).withdraw(marketParams, withdrawAssets, 0, onBehalf, address(this));
        }

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
    /// @dev The referral fee is borrowed on the destination on top of the repaid assets, adding to the debt.
    /// @dev Fee = repaidAssets * referralFeePct / (WAD - referralFeePct); total borrowed = repaidAssets + fee.
    /// @dev @dev maxLtv caps the resulting LTV of the destination position, which includes fees, and any previous position. Use destination LLTV to disable.
    /// @dev Migrating a position without debt reverts on Blue.
    function migrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 maxLtv,
        address onBehalf,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(onBehalf == msg.sender || IMorpho(BLUE).isAuthorized(onBehalf, msg.sender), Unauthorized());
        require(referralFeePct < WAD, PctExceeded());
        require(
            sourceMarketParams.loanToken == destMarketParams.loanToken
                && sourceMarketParams.collateralToken == destMarketParams.collateralToken,
            InconsistentTokens()
        );

        Position memory position = IMorpho(BLUE).position(sourceMarketParams.id(), onBehalf);

        bytes memory data = abi.encode(
            MigrateBorrowPositionData({
                sourceMarketParams: sourceMarketParams,
                destMarketParams: destMarketParams,
                collateral: position.collateral,
                onBehalf: onBehalf,
                referralFeePct: referralFeePct,
                referralFeeRecipient: referralFeeRecipient
            })
        );
        IMorpho(BLUE).repay(sourceMarketParams, 0, position.borrowShares, onBehalf, data);

        requireMaxLtv(destMarketParams, onBehalf, maxLtv);
    }

    /// @dev Blue's repay callback. Only reachable during migrateBorrowPosition: no other function passes non-empty
    /// data to repay.
    /// @dev Blue pulls exactly `assets` of the loan token from this contract after this callback returns.
    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        MigrateBorrowPositionData memory d = abi.decode(data, (MigrateBorrowPositionData));

        uint256 referralFeeAssets = assets.mulDivDown(d.referralFeePct, WAD - d.referralFeePct);
        uint256 borrowAssets = assets + referralFeeAssets;

        IMorpho(BLUE).withdrawCollateral(d.sourceMarketParams, d.collateral, d.onBehalf, address(this));

        TokenLib.forceApproveMax(d.destMarketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(d.destMarketParams, d.collateral, d.onBehalf, "");
        IMorpho(BLUE).borrow(d.destMarketParams, borrowAssets, 0, d.onBehalf, address(this));

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(d.destMarketParams.loanToken, d.referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(d.sourceMarketParams.loanToken, BLUE);
    }

    /// @dev Reverts unless onBehalf's LTV is at or below maxLtv; at or above the market LLTV it is a no-op.
    /// @dev Must be called only after the market's interest has been accrued, so the stored totals are
    /// current; mirrors Blue's own health check but against maxLtv.
    function requireMaxLtv(MarketParams memory marketParams, address onBehalf, uint256 maxLtv) internal view {
        if (maxLtv >= marketParams.lltv) return;
        Market memory market = IMorpho(BLUE).market(marketParams.id());
        Position memory position = IMorpho(BLUE).position(marketParams.id(), onBehalf);
        uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
        require(borrowed <= maxBorrow, LtvExceeded());
    }
}
