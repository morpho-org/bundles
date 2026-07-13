// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IBlueBundlesV1, SignedAuthorization} from "./interfaces/IBlueBundlesV1.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {
    IMorpho,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
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
contract BlueBundlesV1 is IBlueBundlesV1, IMorphoRepayCallback {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;

    constructor(address _blue) {
        BLUE = _blue;
    }

    /// EXTERNAL ///

    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev Pulls collateralAmount of marketParams.collateralToken from msg.sender (optionally via ERC-2612 or Permit2), supplies it as collateral on Blue for msg.sender, then borrows assets of the loan token on behalf of msg.sender, routed via this contract.
    /// @dev Total loan assets routed: assets - referralFeeAssets to msg.sender, referralFeeAssets to referralFeeRecipient.
    /// @dev Fee = assets * referralFeePct / WAD; net = assets - fee.
    /// @dev maxLtv caps msg.sender's resulting LTV; at or above the market LLTV it is a no-op (WAD disables it).
    /// @dev minSharePriceE27 lower-bounds the realized borrow share price (borrowed assets per share, scaled by 1e27).
    function blueBundlesV1SupplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 assets,
        uint256 minSharePriceE27,
        uint256 maxLtv,
        TokenPermit memory collateralPermit,
        SignedAuthorization memory signedAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);

        TokenLib.pullToken(marketParams.collateralToken, msg.sender, collateralAmount, collateralPermit);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        IMorpho(BLUE).supplyCollateral(marketParams, collateralAmount, msg.sender, "");
        (, uint256 shares) = IMorpho(BLUE).borrow(marketParams, assets, 0, msg.sender, address(this));
        require(assets.mulDivDown(1e27, shares) >= minSharePriceE27, SlippageExceeded());

        requireMaxLtv(marketParams, msg.sender, maxLtv);

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, assets - referralFeeAssets);
    }

    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization, if some collateral is withdrawn.
    /// @dev Pulls maxRepayAssets from msg.sender, and reimburse the unused remainder at the end of the call, and withdraws collateral if withdrawCollateralAssets > 0.
    /// @dev Exactly one of assets and shares should be non-zero: the debt is repaid by assets, or by shares. To close the full debt, pass msg.sender's full borrow shares as shares.
    /// @dev The fee is repaidAmount * referralFeePct / (WAD - referralFeePct).
    /// @dev maxLtv caps msg.sender's resulting LTV after a withdrawal; skipped on a pure repay.
    /// @dev maxSharePriceE27 upper-bounds the realized repay share price (repaid assets per share, scaled by 1e27).
    function blueBundlesV1RepayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxRepayAssets,
        uint256 maxSharePriceE27,
        uint256 withdrawCollateralAssets,
        uint256 maxLtv,
        TokenPermit memory loanTokenPermit,
        SignedAuthorization memory signedAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);

        TokenLib.pullToken(marketParams.loanToken, msg.sender, maxRepayAssets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        (assets, shares) = IMorpho(BLUE).repay(marketParams, assets, shares, msg.sender, "");
        require(assets.mulDivUp(1e27, shares) <= maxSharePriceE27, SlippageExceeded());

        if (withdrawCollateralAssets > 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, withdrawCollateralAssets, msg.sender, msg.sender);
            requireMaxLtv(marketParams, msg.sender, maxLtv);
        }

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, maxRepayAssets - assets - referralFeeAssets);
    }

    /// @dev Pulls assets of marketParams.loanToken from msg.sender (optionally via ERC-2612 or Permit2).
    /// @dev The referral fee is deducted from assets; the remainder is supplied to the market for msg.sender.
    /// @dev Fee = assets * referralFeePct / WAD; supplied = assets - fee.
    /// @dev maxSharePriceE27 upper-bounds the realized supply share price (supplied assets per share, scaled by 1e27).
    function blueBundlesV1Supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 maxSharePriceE27,
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

        (, uint256 suppliedShares) = IMorpho(BLUE).supply(marketParams, toSupply, 0, msg.sender, "");
        require(toSupply.mulDivUp(1e27, suppliedShares) <= maxSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
    }

    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev Withdraws from msg.sender's supply position, routed via this contract.
    /// @dev Exactly one of assets and shares should be non-zero: the position is withdrawn by assets, or by shares. To close the full supply position so no supply shares remain, pass msg.sender's full supply shares as shares.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to msg.sender.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
    /// @dev minSharePriceE27 lower-bounds the realized withdraw share price (withdrawn assets per share, scaled by 1e27).
    function blueBundlesV1Withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        SignedAuthorization memory signedAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);

        (uint256 withdrawn, uint256 withdrawnShares) =
            IMorpho(BLUE).withdraw(marketParams, assets, shares, msg.sender, address(this));
        require(withdrawn.mulDivDown(1e27, withdrawnShares) >= minSharePriceE27, SlippageExceeded());

        uint256 referralFeeAssets = withdrawn.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, withdrawn - referralFeeAssets);
    }

    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev Moves the full position of msg.sender (collateral and borrow shares, read from Blue) from the source market to the destination market via Blue's repay callback, pulling no tokens from msg.sender.
    /// @dev The markets must have the same loan token and the same collateral token.
    /// @dev The referral fee is borrowed on the destination on top of the repaid assets, adding to the debt.
    /// @dev Fee = repaidAssets * referralFeePct / (WAD - referralFeePct); total borrowed = repaidAssets + fee.
    /// @dev maxLtv caps the resulting LTV of the destination position, which includes fees, and any previous position. Use destination LLTV to disable.
    /// @dev maxSharePriceE27 upper-bounds the realized source repay share price; minSharePriceE27 lower-bounds the realized destination borrow share price (both assets per share, scaled by 1e27).
    /// @dev Migrating a position without debt reverts on Blue.
    function blueBundlesV1MigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
        uint256 maxSharePriceE27,
        uint256 minSharePriceE27,
        uint256 maxLtv,
        SignedAuthorization memory signedAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);

        require(
            sourceMarketParams.loanToken == destMarketParams.loanToken
                && sourceMarketParams.collateralToken == destMarketParams.collateralToken,
            InconsistentTokens()
        );

        Position memory position = IMorpho(BLUE).position(sourceMarketParams.id(), msg.sender);

        bytes memory data = abi.encode(
            sourceMarketParams,
            destMarketParams,
            position.collateral,
            msg.sender,
            referralFeePct,
            referralFeeRecipient,
            minSharePriceE27
        );
        (uint256 assets,) = IMorpho(BLUE).repay(sourceMarketParams, 0, position.borrowShares, msg.sender, data);
        require(assets.mulDivUp(1e27, position.borrowShares) <= maxSharePriceE27, SlippageExceeded());

        requireMaxLtv(destMarketParams, msg.sender, maxLtv);
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (
            MarketParams memory sourceMarketParams,
            MarketParams memory destMarketParams,
            uint256 collateral,
            address sender,
            uint256 referralFeePct,
            address referralFeeRecipient,
            uint256 minSharePriceE27
        ) = abi.decode(data, (MarketParams, MarketParams, uint256, address, uint256, address, uint256));

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 borrowAssets = assets + referralFeeAssets;

        IMorpho(BLUE).withdrawCollateral(sourceMarketParams, collateral, sender, address(this));

        TokenLib.forceApproveMax(destMarketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(destMarketParams, collateral, sender, "");
        (, uint256 borrowedShares) = IMorpho(BLUE).borrow(destMarketParams, borrowAssets, 0, sender, address(this));
        require(borrowAssets.mulDivDown(1e27, borrowedShares) >= minSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(destMarketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(sourceMarketParams.loanToken, BLUE);
    }

    /// @dev Skipped when the signature is empty (v, r and s all zero; no valid signature has any of them zero), useful to be able to pass an empty signedAuthorization.
    /// @dev On a consumed nonce, skips the submission if the authorization is already set (e.g. a front-run submission), and reverts with InvalidAuthorizationSignature otherwise; an invalid or expired signature, or a future nonce, reverts on Blue.
    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until signedAuthorization.deadline, as revoking on Blue does not consume the nonce.
    function setAuthorizationWithSig(SignedAuthorization memory signedAuthorization) internal {
        Signature memory signature = signedAuthorization.signature;
        if (signature.v == 0 && signature.r == 0 && signature.s == 0) return;
        if (IMorpho(BLUE).nonce(msg.sender) > signedAuthorization.nonce) {
            require(IMorpho(BLUE).isAuthorized(msg.sender, address(this)), InvalidAuthorizationSignature());
            return;
        }
        IMorpho(BLUE)
            .setAuthorizationWithSig(
                Authorization({
                authorizer: msg.sender,
                authorized: address(this),
                isAuthorized: true,
                nonce: signedAuthorization.nonce,
                deadline: signedAuthorization.deadline
            }),
                signature
            );
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; at or above the market LLTV it is a no-op.
    /// @dev Must be called only after the market's interest has been accrued, so the stored totals are current; mirrors Blue's own health check but against maxLtv.
    function requireMaxLtv(MarketParams memory marketParams, address sender, uint256 maxLtv) internal view {
        if (maxLtv >= marketParams.lltv) return;
        Market memory market = IMorpho(BLUE).market(marketParams.id());
        Position memory position = IMorpho(BLUE).position(marketParams.id(), sender);
        uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
        require(borrowed <= maxBorrow, LtvExceeded());
    }
}
