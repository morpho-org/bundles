// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IBlueBundlesV1, SignedAuthorization, PublicAllocations} from "./interfaces/IBlueBundlesV1.sol";
import {
    IBluePublicAllocator
} from "../../lib/vault-v2/src/periphery/blue-public-allocator/interfaces/IBluePublicAllocator.sol";
import {TokenLib, TokenPermit} from "../libraries/TokenLib.sol";
import {IWNative} from "../libraries/interfaces/IWNative.sol";
import {
    IMorpho,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoRepayCallback,
    IMorphoFlashLoanCallback
} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";

/// @dev Inherits the token safety requirements of Morpho Blue (see Morpho.sol).
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
contract BlueBundlesV1 is IBlueBundlesV1, IMorphoRepayCallback, IMorphoFlashLoanCallback {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;
    address public immutable PUBLIC_ALLOCATOR;

    /// @dev Carries the withdrawn assets from the flash-loan callback back to the entrypoint, where the payout happens.
    uint256 internal transient withdrawnAssetsTransient;

    constructor(address _blue, address _publicAllocator) {
        BLUE = _blue;
        PUBLIC_ALLOCATOR = _publicAllocator;
    }

    /// @dev Receives the native tokens unwrapped from the wrapped-native token when reimbursing a native repay.
    receive() external payable {}

    /// EXTERNAL ///

    /// @dev Pulls collateralAssets as an ERC20 (optionally via ERC-2612 or Permit2), supplies it on Blue, then borrows borrowAssets on behalf of msg.sender.
    /// @dev When native tokens are sent, collateralPermit.kind must be PermitKind.None and collateralAssets must equal msg.value; the native tokens are wrapped into marketParams.collateralToken (which must be the wrapped-native token) instead of being pulled.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev The public allocator penalties are deducted from the borrowed assets (the flash-loan repayment enforces penalties <= borrowAssets) and the referral fee is charged on the remainder; the rest is sent to msg.sender. Fee = (borrowAssets - penalties) * referralFeePct / WAD; net = borrowAssets - penalties - fee.
    /// @dev maxLtv caps msg.sender's resulting LTV; at or above the market LLTV it is a no-op (WAD disables it).
    /// @dev minSharePriceE27 lower-bounds the realized borrow share price (borrowed assets per share, scaled by 1e27).
    /// @dev The aggregate penalty of the reallocations is flash loaned to pay the public allocator upfront.
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
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);
        TokenLib.pullOrWrapNative(marketParams.collateralToken, msg.sender, collateralAssets, collateralPermit);
        if (collateralAssets > 0) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, collateralAssets, msg.sender, "");
        }

        uint256 penaltyAssets = totalPenaltyAssets(reallocations);
        if (penaltyAssets == 0) {
            executeBorrow(marketParams, borrowAssets, minSharePriceE27, reallocations, msg.sender);
        } else {
            bytes memory operationData = abi.encode(marketParams, borrowAssets, minSharePriceE27, reallocations);
            IMorpho(BLUE)
                .flashLoan(
                    marketParams.loanToken,
                    penaltyAssets,
                    abi.encode(msg.sender, this.blueBundlesV1SupplyCollateralAndBorrow.selector, operationData)
                );
        }
        requireMaxLtv(marketParams, msg.sender, maxLtv);

        uint256 receivedAssets = borrowAssets - penaltyAssets;
        uint256 referralFeeAssets = receivedAssets.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, receivedAssets - referralFeeAssets);
    }

    function executeBorrow(
        MarketParams memory marketParams,
        uint256 borrowAssets,
        uint256 minSharePriceE27,
        PublicAllocations[] memory reallocations,
        address sender
    ) internal {
        executePublicAllocations(marketParams.loanToken, reallocations);
        (, uint256 borrowShares) = IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, sender, address(this));
        require(borrowAssets.mulDivDown(1e27, borrowShares) >= minSharePriceE27, SlippageExceeded());
    }

    /// @dev Pulls maxRepayAssets from msg.sender, repays msg.sender's debt, reimburses the unused remainder (if any) at the end of the call, and withdraws collateral if collateralAssets > 0.
    /// @dev When native tokens are sent, loanTokenPermit.kind must be PermitKind.None and maxRepayAssets must equal msg.value; the native tokens are wrapped into marketParams.loanToken (which must be the wrapped-native token) instead of being pulled, and the reimbursed remainder is unwrapped back to native.
    /// @dev Reimbursing native tokens requires msg.sender to be able to receive native tokens, or else it will revert.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization, if some collateral is withdrawn.
    /// @dev Exactly one of repayAssets and repayShares should be non-zero: the debt is repaid by assets, or by shares. To close the full debt, pass msg.sender's full borrow shares as repayShares.
    /// @dev The fee is repaidAmount * referralFeePct / (WAD - referralFeePct).
    /// @dev maxLtv caps msg.sender's resulting LTV after a withdrawal; skipped on a pure repay.
    /// @dev maxSharePriceE27 upper-bounds the realized repay share price (repaid assets per share, scaled by 1e27).
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
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);
        TokenLib.pullOrWrapNative(marketParams.loanToken, msg.sender, maxRepayAssets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        (repayAssets, repayShares) = IMorpho(BLUE).repay(marketParams, repayAssets, repayShares, msg.sender, "");
        require(repayAssets.mulDivUp(1e27, repayShares) <= maxSharePriceE27, SlippageExceeded());

        if (collateralAssets > 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, collateralAssets, msg.sender, msg.sender);
            requireMaxLtv(marketParams, msg.sender, maxLtv);
        }

        uint256 referralFeeAssets = repayAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        uint256 remainder = maxRepayAssets - repayAssets - referralFeeAssets;
        if (remainder > 0) {
            if (msg.value > 0) {
                IWNative(marketParams.loanToken).withdraw(remainder);
                (bool success,) = msg.sender.call{value: remainder}("");
                require(success, NativeTransferFailed());
            } else {
                SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, remainder);
            }
        }
    }

    /// @dev Pulls assets from msg.sender (optionally via ERC-2612 or Permit2) and supplies them to the market for msg.sender.
    /// @dev When native tokens are sent, loanTokenPermit.kind must be PermitKind.None and assets must equal msg.value; the native tokens are wrapped into marketParams.loanToken (which must be the wrapped-native token) instead of being pulled.
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
    ) external payable {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD);
        uint256 toSupply = assets - referralFeeAssets;

        TokenLib.pullOrWrapNative(marketParams.loanToken, msg.sender, assets, loanTokenPermit);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        (, uint256 suppliedShares) = IMorpho(BLUE).supply(marketParams, toSupply, 0, msg.sender, "");
        require(toSupply.mulDivUp(1e27, suppliedShares) <= maxSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
    }

    /// @dev Withdraws from msg.sender's supply position.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev Exactly one of withdrawAssets and withdrawShares should be non-zero: the position is withdrawn by assets, or by shares. To close the full supply position so no supply shares remain, pass msg.sender's full supply shares as withdrawShares.
    /// @dev The public allocator penalties are deducted from the withdrawn assets (the flash-loan repayment enforces penalties <= withdrawnAssets) and the referral fee is charged on the remainder; the rest is sent to msg.sender. Fee = (withdrawnAssets - penalties) * referralFeePct / WAD; net = withdrawnAssets - penalties - fee.
    /// @dev The supply share price is not checked: any drop due to bad debt realisation is not quickly reversed, so a reverted exit retried later would be on similar or worse terms.
    /// @dev The aggregate penalty of the reallocations is flash loaned to pay the public allocator upfront.
    function blueBundlesV1Withdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        uint256 withdrawShares,
        SignedAuthorization memory signedAuthorization,
        PublicAllocations[] memory reallocations,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);

        uint256 penaltyAssets = totalPenaltyAssets(reallocations);
        if (penaltyAssets == 0) {
            executeWithdraw(marketParams, withdrawAssets, withdrawShares, reallocations, msg.sender);
        } else {
            bytes memory operationData = abi.encode(marketParams, withdrawAssets, withdrawShares, reallocations);
            IMorpho(BLUE)
                .flashLoan(
                    marketParams.loanToken,
                    penaltyAssets,
                    abi.encode(msg.sender, this.blueBundlesV1Withdraw.selector, operationData)
                );
        }

        uint256 receivedAssets = withdrawnAssetsTransient - penaltyAssets;
        uint256 referralFeeAssets = receivedAssets.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, receivedAssets - referralFeeAssets);
    }

    function executeWithdraw(
        MarketParams memory marketParams,
        uint256 withdrawAssets,
        uint256 withdrawShares,
        PublicAllocations[] memory reallocations,
        address sender
    ) internal {
        executePublicAllocations(marketParams.loanToken, reallocations);
        (withdrawnAssetsTransient,) =
            IMorpho(BLUE).withdraw(marketParams, withdrawAssets, withdrawShares, sender, address(this));
    }

    /// @dev Moves the full position of msg.sender (collateral and borrow shares, read from Blue) from the source market to the destination market.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev The referral fee and public allocator penalties are borrowed on the destination on top of the repaid assets, adding to the debt. Fee = repaidAssets * referralFeePct / (WAD - referralFeePct); total borrowed = repaidAssets + fee + penalties.
    /// @dev maxLtv caps the resulting LTV of the destination position, which includes fees, and any previous position. Use destination LLTV to disable.
    /// @dev sourceMaxSharePriceE27 upper-bounds the realized source repay share price; destMinSharePriceE27 lower-bounds the realized destination borrow share price (both assets per share, scaled by 1e27).
    /// @dev Migrating a position without debt reverts on Blue.
    /// @dev The aggregate penalty of the reallocations is flash loaned to pay the public allocator upfront.
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
        bytes memory migrationData = abi.encode(
            sourceMarketParams,
            destMarketParams,
            uint256(position.collateral),
            msg.sender,
            referralFeePct,
            referralFeeRecipient,
            destMinSharePriceE27
        );
        uint256 penaltyAssets = totalPenaltyAssets(reallocations);
        if (penaltyAssets == 0) {
            executeMigrateBorrowPosition(
                sourceMarketParams,
                position.borrowShares,
                sourceMaxSharePriceE27,
                reallocations,
                migrationData,
                msg.sender
            );
        } else {
            bytes memory operationData = abi.encode(
                sourceMarketParams, uint256(position.borrowShares), sourceMaxSharePriceE27, reallocations, migrationData
            );
            IMorpho(BLUE)
                .flashLoan(
                    destMarketParams.loanToken,
                    penaltyAssets,
                    abi.encode(msg.sender, this.blueBundlesV1MigrateBorrowPosition.selector, operationData)
                );
        }
        requireMaxLtv(destMarketParams, msg.sender, maxLtv);
    }

    /// @dev migrationData is the onMorphoRepay callback data, passed through opaquely; the charged penaltyAssets is appended to it once known.
    function executeMigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        uint256 borrowShares,
        uint256 sourceMaxSharePriceE27,
        PublicAllocations[] memory reallocations,
        bytes memory migrationData,
        address sender
    ) internal {
        uint256 penaltyAssets = executePublicAllocations(sourceMarketParams.loanToken, reallocations);

        bytes memory data = abi.encode(migrationData, penaltyAssets);
        (uint256 assets,) = IMorpho(BLUE).repay(sourceMarketParams, 0, borrowShares, sender, data);
        require(assets.mulDivUp(1e27, borrowShares) <= sourceMaxSharePriceE27, SlippageExceeded());
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (bytes memory migrationData, uint256 penaltyAssets) = abi.decode(data, (bytes, uint256));
        (
            MarketParams memory sourceMarketParams,
            MarketParams memory destMarketParams,
            uint256 collateral,
            address sender,
            uint256 referralFeePct,
            address referralFeeRecipient,
            uint256 destMinSharePriceE27
        ) = abi.decode(migrationData, (MarketParams, MarketParams, uint256, address, uint256, address, uint256));

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 borrowAssets = assets + referralFeeAssets + penaltyAssets;

        IMorpho(BLUE).withdrawCollateral(sourceMarketParams, collateral, sender, address(this));

        TokenLib.forceApproveMax(destMarketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(destMarketParams, collateral, sender, "");
        (, uint256 borrowedShares) = IMorpho(BLUE).borrow(destMarketParams, borrowAssets, 0, sender, address(this));
        require(borrowAssets.mulDivDown(1e27, borrowedShares) >= destMinSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(destMarketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(sourceMarketParams.loanToken, BLUE);
    }

    function onMorphoFlashLoan(uint256, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (address sender, bytes4 selector, bytes memory operationData) = abi.decode(data, (address, bytes4, bytes));

        if (selector == this.blueBundlesV1SupplyCollateralAndBorrow.selector) {
            (
                MarketParams memory marketParams,
                uint256 borrowAssets,
                uint256 minSharePriceE27,
                PublicAllocations[] memory reallocations
            ) = abi.decode(operationData, (MarketParams, uint256, uint256, PublicAllocations[]));
            executeBorrow(marketParams, borrowAssets, minSharePriceE27, reallocations, sender);
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        } else if (selector == this.blueBundlesV1Withdraw.selector) {
            (
                MarketParams memory marketParams,
                uint256 withdrawAssets,
                uint256 withdrawShares,
                PublicAllocations[] memory reallocations
            ) = abi.decode(operationData, (MarketParams, uint256, uint256, PublicAllocations[]));
            executeWithdraw(marketParams, withdrawAssets, withdrawShares, reallocations, sender);
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        } else if (selector == this.blueBundlesV1MigrateBorrowPosition.selector) {
            (
                MarketParams memory sourceMarketParams,
                uint256 borrowShares,
                uint256 sourceMaxSharePriceE27,
                PublicAllocations[] memory reallocations,
                bytes memory migrationData
            ) = abi.decode(operationData, (MarketParams, uint256, uint256, PublicAllocations[], bytes));
            executeMigrateBorrowPosition(
                sourceMarketParams, borrowShares, sourceMaxSharePriceE27, reallocations, migrationData, sender
            );
            TokenLib.forceApproveMax(sourceMarketParams.loanToken, BLUE);
        } else {
            revert UnauthorizedCallback();
        }
    }

    /// INTERNAL ///

    /// @dev Each reallocation either allocates the vault's idle assets, or first deallocates assets from its source market.
    /// @dev Each allocation's destination is its own marketParams, whose loan token must be the flash-loaned loanToken, so all penalties are paid in that single token.
    /// @dev Returns the aggregate charged penalty, computed with the same per-call upward rounding as the public allocator.
    function executePublicAllocations(address loanToken, PublicAllocations[] memory reallocations)
        internal
        returns (uint256)
    {
        if (reallocations.length == 0) return 0;

        TokenLib.forceApproveMax(loanToken, PUBLIC_ALLOCATOR);

        uint256 penaltyAssets;
        for (uint256 i; i < reallocations.length; i++) {
            PublicAllocations memory reallocation = reallocations[i];
            require(reallocation.marketParams.loanToken == loanToken, InconsistentTokens());
            penaltyAssets += uint256(reallocation.assets).mulDivUp(reallocation.penalty, WAD);

            if (reallocation.fromIdle) {
                IBluePublicAllocator(PUBLIC_ALLOCATOR)
                    .allocateFromIdle(
                        reallocation.vault,
                        reallocation.adapter,
                        reallocation.marketParams,
                        reallocation.assets,
                        reallocation.penalty
                    );
            } else {
                IBluePublicAllocator(PUBLIC_ALLOCATOR)
                    .reallocate(
                        reallocation.vault,
                        reallocation.sourceAdapter,
                        reallocation.sourceMarketParams,
                        reallocation.adapter,
                        reallocation.marketParams,
                        reallocation.assets,
                        reallocation.penalty
                    );
            }
        }

        return penaltyAssets;
    }

    function totalPenaltyAssets(PublicAllocations[] memory reallocations) internal pure returns (uint256) {
        uint256 penaltyAssets;
        for (uint256 i; i < reallocations.length; i++) {
            penaltyAssets += uint256(reallocations[i].assets).mulDivUp(reallocations[i].penalty, WAD);
        }
        return penaltyAssets;
    }

    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until signedAuthorization.deadline, as revoking on Blue does not consume the nonce.
    function setAuthorizationWithSig(SignedAuthorization memory signedAuthorization) internal {
        Signature memory signature = signedAuthorization.signature;
        bool emptySignature = signature.v == 0 && signature.r == 0 && signature.s == 0;

        if (!emptySignature && IMorpho(BLUE).nonce(msg.sender) <= signedAuthorization.nonce) {
            IMorpho(BLUE)
                .setAuthorizationWithSig(
                    Authorization(
                        msg.sender, address(this), true, signedAuthorization.nonce, signedAuthorization.deadline
                    ),
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
        Market memory market = IMorpho(BLUE).market(marketParams.id());
        uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
        require(borrowed <= maxBorrow, LtvExceeded());
    }
}
