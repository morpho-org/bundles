// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IMidnightToBlueBundlesV1, MAX_REFERRAL_FEE_PCT} from "./interfaces/IMidnightToBlueBundlesV1.sol";
import {SignedAuthorization} from "../blue/interfaces/IBlueBundlesV1.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IRepayCallback} from "../../lib/midnight/src/interfaces/ICallbacks.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {CALLBACK_SUCCESS, WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {
    IMorpho,
    MarketParams,
    Position,
    Market as BlueMarket,
    Authorization,
    Signature
} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";

/// @dev Inherits the token safety requirements of Morpho Blue and Midnight (see Morpho.sol and Midnight.sol).
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
contract MidnightToBlueBundlesV1 is IMidnightToBlueBundlesV1, IRepayCallback {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable MIDNIGHT;
    address public immutable BLUE;

    /// @dev keccak256 of the callback data committed by an in-flight entry-point call. Cleared inside onRepay.
    /// @dev Required because Midnight's repay accepts an arbitrary callback address, so `msg.sender == MIDNIGHT`
    /// alone would let any caller invoke onRepay with forged data and abuse the user's Midnight+Blue authorizations.
    /// Blue's repay callbacks are safe from this because they only invoke the callback on msg.sender.
    bytes32 transient _pendingCallbackHash;

    constructor(address _midnight, address _blue) {
        MIDNIGHT = _midnight;
        BLUE = _blue;
    }

    /// EXTERNAL ///

    /// @dev Migrates msg.sender's full borrow position (debt + one collateral) from a Midnight market to a Blue market, without a flash loan.
    /// @dev The destination Blue borrow, taken inside Midnight's onRepay callback, funds the Midnight repay: no external capital is required.
    /// @dev msg.sender must have authorized this contract on Midnight beforehand (Midnight has no signed-authorization path).
    /// @dev msg.sender must have authorized this contract on Blue beforehand, or via destAuthorization.
    /// @dev Assumes sourceMidnightMarket.loanToken == destBlueParams.loanToken and sourceMidnightMarket.collateralParams[collateralIndex].token == destBlueParams.collateralToken; reverts otherwise.
    /// @dev Only the borrower side of the Midnight position is migrated: any lender-side credit position on the same Midnight market is untouched.
    /// @dev sourceMaxRepayAssets upper-bounds the Midnight units repaid (equal to the loan-token amount pulled to Midnight, since Midnight repays 1:1).
    /// @dev The referral fee is borrowed on the destination on top of the repaid units, adding to the debt.
    /// @dev Fee = repaidUnits * referralFeePct / (WAD - referralFeePct); total borrowed on Blue = repaidUnits + fee.
    /// @dev referralFeePct is hard-capped at MAX_REFERRAL_FEE_PCT (5%) to bound the worst-case fee a distributor can charge.
    /// @dev maxLtv caps the resulting LTV of the destination Blue position, which includes fees, and any previous position. Use destination LLTV to disable.
    /// @dev destMinSharePriceE27 lower-bounds the realized destination borrow share price (borrowed assets per share, scaled by 1e27).
    /// @dev Migrating a position without debt is a no-op on Midnight (repay of 0 units); no destination borrow is taken.
    function midnightToBlueBundlesV1MigrateBorrowPosition(
        Market memory sourceMidnightMarket,
        MarketParams memory destBlueParams,
        uint256 collateralIndex,
        uint256 sourceMaxRepayAssets,
        uint256 destMinSharePriceE27,
        uint256 maxLtv,
        SignedAuthorization memory destAuthorization,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct <= MAX_REFERRAL_FEE_PCT, PctExceeded());

        setAuthorizationWithSig(destAuthorization);
        require(
            sourceMidnightMarket.loanToken == destBlueParams.loanToken
                && sourceMidnightMarket.collateralParams[collateralIndex].token == destBlueParams.collateralToken,
            InconsistentTokens()
        );

        // Borrower debt on Midnight is denominated in units (loan-token 1:1) and is not affected by continuous fee
        // accrual: pendingFee only impacts lender credit positions (see Midnight.sol). Reading debt() gives the exact
        // amount required to fully close the borrower's position; touchMarket is called by Midnight during repay.
        bytes32 id = IdLib.toId(sourceMidnightMarket);
        uint256 units = IMidnight(MIDNIGHT).debt(id, msg.sender);
        require(units <= sourceMaxRepayAssets, SlippageExceeded());
        uint256 collateralAmount = IMidnight(MIDNIGHT).collateral(id, msg.sender, collateralIndex);

        bytes memory data = abi.encode(
            sourceMidnightMarket,
            destBlueParams,
            collateralIndex,
            collateralAmount,
            msg.sender,
            referralFeePct,
            referralFeeRecipient,
            destMinSharePriceE27
        );
        _pendingCallbackHash = keccak256(data);
        IMidnight(MIDNIGHT).repay(sourceMidnightMarket, units, msg.sender, address(this), data);

        requireMaxLtv(destBlueParams, msg.sender, maxLtv);
    }

    /// @dev Called by Midnight during repay, with debt already decremented but before Midnight pulls loan tokens from this contract.
    /// @dev The `_pendingCallbackHash` guard binds this callback to a top-level entry call: without it, any address could invoke Midnight.repay with this contract as the callback and forge `data`, since Midnight's repay accepts an arbitrary callback address.
    function onRepay(bytes32, Market memory, uint256 units, address, bytes memory data) external returns (bytes32) {
        require(msg.sender == MIDNIGHT, UnauthorizedCallback());
        require(_pendingCallbackHash == keccak256(data), UnauthorizedCallback());
        _pendingCallbackHash = bytes32(0);
        (
            Market memory sourceMidnightMarket,
            MarketParams memory destBlueParams,
            uint256 collateralIndex,
            uint256 collateralAmount,
            address sender,
            uint256 referralFeePct,
            address referralFeeRecipient,
            uint256 destMinSharePriceE27
        ) = abi.decode(data, (Market, MarketParams, uint256, uint256, address, uint256, address, uint256));

        uint256 referralFeeAssets = units.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 borrowAssets = units + referralFeeAssets;

        // Debt is 0 in this window, so Midnight's health check skips oracle reads and this succeeds.
        IMidnight(MIDNIGHT)
            .withdrawCollateral(sourceMidnightMarket, collateralIndex, collateralAmount, sender, address(this));

        TokenLib.forceApproveMax(destBlueParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(destBlueParams, collateralAmount, sender, "");
        (, uint256 borrowedShares) = IMorpho(BLUE).borrow(destBlueParams, borrowAssets, 0, sender, address(this));
        require(borrowAssets.mulDivDown(1e27, borrowedShares) >= destMinSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(destBlueParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(sourceMidnightMarket.loanToken, MIDNIGHT);
        return CALLBACK_SUCCESS;
    }

    /// INTERNAL ///

    /// @dev The parameters signed by the user should be the same as the inputs of this function.
    /// @dev Skipped when the signature is empty (v, r and s all zero; which doesn't correspond to a valid signature), for when the authorization is already done.
    /// @dev Skipped on an already consumed nonce (e.g. a front-run submission): the signature is not checked in that case, and Blue checks authorization at the point of use.
    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until destAuthorization.deadline, as revoking on Blue does not consume the nonce.
    function setAuthorizationWithSig(SignedAuthorization memory destAuthorization) internal {
        Signature memory signature = destAuthorization.signature;
        bool emptySignature = signature.v == 0 && signature.r == 0 && signature.s == 0;

        if (!emptySignature && IMorpho(BLUE).nonce(msg.sender) <= destAuthorization.nonce) {
            IMorpho(BLUE)
                .setAuthorizationWithSig(
                    Authorization({
                        authorizer: msg.sender,
                        authorized: address(this),
                        isAuthorized: true,
                        nonce: destAuthorization.nonce,
                        deadline: destAuthorization.deadline
                    }),
                    signature
                );
        }
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; at or above the market LLTV it is a no-op.
    /// @dev Must be called only after the market's interest has been accrued, so the stored totals are current; mirrors Blue's own health check but against maxLtv.
    function requireMaxLtv(MarketParams memory marketParams, address sender, uint256 maxLtv) internal view {
        if (maxLtv >= marketParams.lltv) return;
        Position memory position = IMorpho(BLUE).position(marketParams.id(), sender);
        if (position.borrowShares == 0) return;
        BlueMarket memory market = IMorpho(BLUE).market(marketParams.id());
        uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
        require(borrowed <= maxBorrow, LtvExceeded());
    }
}
