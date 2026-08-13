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

struct SupplyCollateralAndBorrowParams {
    MarketParams marketParams;
    uint256 collateralAssets;
    uint256 borrowAssets;
    uint256 minSharePriceE27;
    uint256 maxLtv;
    TokenPermit collateralPermit;
    PublicAllocations[] reallocations;
    uint256 referralFeePct;
    address referralFeeRecipient;
}

struct WithdrawParams {
    MarketParams marketParams;
    uint256 assets;
    uint256 shares;
    PublicAllocations[] reallocations;
    uint256 referralFeePct;
    address referralFeeRecipient;
}

struct MigrateBorrowPositionParams {
    MarketParams sourceMarketParams;
    MarketParams destMarketParams;
    uint256 sourceMaxSharePriceE27;
    uint256 destMinSharePriceE27;
    uint256 maxLtv;
    PublicAllocations[] reallocations;
    uint256 referralFeePct;
    address referralFeeRecipient;
}

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

    address public transient initiator;

    constructor(address _blue, address _publicAllocator) {
        BLUE = _blue;
        PUBLIC_ALLOCATOR = _publicAllocator;
    }

    /// @dev Receives the native tokens unwrapped from the wrapped-native token when reimbursing a native repay.
    receive() external payable {}

    /// EXTERNAL ///

    /// @dev Pulls collateralAssets as an ERC20 (optionally via ERC-2612 or Permit2), supplies it on Blue, then borrows borrowAssets on behalf of msg.sender; native collateral is not supported.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev referralFeeAssets = borrowAssets * referralFeePct / WAD; public allocator penalties are deducted from the
    /// borrowed assets; net = borrowAssets - referralFeeAssets - public allocator penalties.
    /// @dev maxLtv caps msg.sender's resulting LTV; at or above the market LLTV it is a no-op (WAD disables it).
    /// @dev minSharePriceE27 lower-bounds the realized borrow share price (borrowed assets per share, scaled by 1e27).
    /// @dev Each reallocation's maxPenalty bounds its WAD-scaled penalty rate.
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
    ) external {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);
        SupplyCollateralAndBorrowParams memory params = SupplyCollateralAndBorrowParams({
            marketParams: marketParams,
            collateralAssets: collateralAssets,
            borrowAssets: borrowAssets,
            minSharePriceE27: minSharePriceE27,
            maxLtv: maxLtv,
            collateralPermit: collateralPermit,
            reallocations: reallocations,
            referralFeePct: referralFeePct,
            referralFeeRecipient: referralFeeRecipient
        });
        executeWithFlashLoan(
            marketParams.loanToken,
            reallocations,
            this.blueBundlesV1SupplyCollateralAndBorrow.selector,
            abi.encode(params)
        );
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
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
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
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
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
    /// @dev Exactly one of assets and shares should be non-zero: the position is withdrawn by assets, or by shares. To close the full supply position so no supply shares remain, pass msg.sender's full supply shares as shares.
    /// @dev The referral fee and public allocator penalties are deducted from the withdrawn assets; the remainder is
    /// sent to msg.sender. Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee - penalties.
    /// @dev The supply share price is not checked: any drop due to bad debt realisation is not quickly reversed, so a reverted exit retried later would be on similar or worse terms.
    /// @dev Each reallocation's maxPenalty bounds its WAD-scaled penalty rate.
    function blueBundlesV1Withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        SignedAuthorization memory signedAuthorization,
        PublicAllocations[] memory reallocations,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);
        WithdrawParams memory params = WithdrawParams({
            marketParams: marketParams,
            assets: assets,
            shares: shares,
            reallocations: reallocations,
            referralFeePct: referralFeePct,
            referralFeeRecipient: referralFeeRecipient
        });
        executeWithFlashLoan(
            marketParams.loanToken, reallocations, this.blueBundlesV1Withdraw.selector, abi.encode(params)
        );
    }

    /// @dev Moves the full position of msg.sender (collateral and borrow shares, read from Blue) from the source market to the destination market.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev The referral fee and public allocator penalties are borrowed on the destination on top of the repaid assets,
    /// adding to the debt. Fee = repaidAssets * referralFeePct / (WAD - referralFeePct); total borrowed = repaidAssets +
    /// fee + penalties.
    /// @dev maxLtv caps the resulting LTV of the destination position, which includes fees, and any previous position. Use destination LLTV to disable.
    /// @dev sourceMaxSharePriceE27 upper-bounds the realized source repay share price; destMinSharePriceE27 lower-bounds the realized destination borrow share price (both assets per share, scaled by 1e27).
    /// @dev Migrating a position without debt reverts on Blue.
    /// @dev Each reallocation's maxPenalty bounds its WAD-scaled penalty rate.
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
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(referralFeePct < WAD, PctExceeded());

        setAuthorizationWithSig(signedAuthorization);
        require(
            sourceMarketParams.loanToken == destMarketParams.loanToken
                && sourceMarketParams.collateralToken == destMarketParams.collateralToken,
            InconsistentTokens()
        );
        MigrateBorrowPositionParams memory params = MigrateBorrowPositionParams({
            sourceMarketParams: sourceMarketParams,
            destMarketParams: destMarketParams,
            sourceMaxSharePriceE27: sourceMaxSharePriceE27,
            destMinSharePriceE27: destMinSharePriceE27,
            maxLtv: maxLtv,
            reallocations: reallocations,
            referralFeePct: referralFeePct,
            referralFeeRecipient: referralFeeRecipient
        });
        executeWithFlashLoan(
            destMarketParams.loanToken,
            reallocations,
            this.blueBundlesV1MigrateBorrowPosition.selector,
            abi.encode(params)
        );
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (
            MarketParams memory sourceMarketParams,
            MarketParams memory destMarketParams,
            uint256 collateral,
            uint256 referralFeePct,
            address referralFeeRecipient,
            uint256 destMinSharePriceE27,
            uint256 penaltyAssets
        ) = abi.decode(data, (MarketParams, MarketParams, uint256, uint256, address, uint256, uint256));

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 borrowAssets = assets + referralFeeAssets + penaltyAssets;

        IMorpho(BLUE).withdrawCollateral(sourceMarketParams, collateral, initiator, address(this));

        TokenLib.forceApproveMax(destMarketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(destMarketParams, collateral, initiator, "");
        (, uint256 borrowedShares) = IMorpho(BLUE).borrow(destMarketParams, borrowAssets, 0, initiator, address(this));
        require(borrowAssets.mulDivDown(1e27, borrowedShares) >= destMinSharePriceE27, SlippageExceeded());

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(destMarketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(sourceMarketParams.loanToken, BLUE);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (bytes4 selector, bytes memory operationData, uint64[] memory penalties) =
            abi.decode(data, (bytes4, bytes, uint64[]));
        executeFlashOperation(selector, operationData, penalties, assets);
    }

    /// INTERNAL ///

    /// @dev Previews each public allocation's exact penalty with the same upward rounding as the public allocator,
    /// then flash loans only their aggregate loan-token penalty.
    function executeWithFlashLoan(
        address loanToken,
        PublicAllocations[] memory reallocations,
        bytes4 selector,
        bytes memory operationData
    ) internal {
        (uint256 flashLoanAssets, uint64[] memory penalties) = previewPublicAllocationPenalties(reallocations);
        if (flashLoanAssets == 0) {
            executeFlashOperation(selector, operationData, penalties, 0);
            return;
        }

        bytes memory data = abi.encode(selector, operationData, penalties);
        TokenLib.forceApproveMax(loanToken, BLUE);
        IMorpho(BLUE).flashLoan(loanToken, flashLoanAssets, data);
    }

    function executeFlashOperation(
        bytes4 selector,
        bytes memory operationData,
        uint64[] memory penalties,
        uint256 penaltyAssets
    ) internal {
        if (selector == this.blueBundlesV1SupplyCollateralAndBorrow.selector) {
            supplyCollateralAndBorrow(
                abi.decode(operationData, (SupplyCollateralAndBorrowParams)), penalties, penaltyAssets
            );
        } else if (selector == this.blueBundlesV1Withdraw.selector) {
            withdraw(abi.decode(operationData, (WithdrawParams)), penalties, penaltyAssets);
        } else if (selector == this.blueBundlesV1MigrateBorrowPosition.selector) {
            migrateBorrowPosition(abi.decode(operationData, (MigrateBorrowPositionParams)), penalties, penaltyAssets);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function supplyCollateralAndBorrow(
        SupplyCollateralAndBorrowParams memory params,
        uint64[] memory penalties,
        uint256 penaltyAssets
    ) internal {
        executePublicAllocations(params.marketParams, params.reallocations, penalties, penaltyAssets);
        TokenLib.pullToken(
            params.marketParams.collateralToken, initiator, params.collateralAssets, params.collateralPermit
        );
        if (params.collateralAssets > 0) {
            TokenLib.forceApproveMax(params.marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(params.marketParams, params.collateralAssets, initiator, "");
        }

        (, uint256 borrowShares) =
            IMorpho(BLUE).borrow(params.marketParams, params.borrowAssets, 0, initiator, address(this));
        require(params.borrowAssets.mulDivDown(1e27, borrowShares) >= params.minSharePriceE27, SlippageExceeded());

        requireMaxLtv(params.marketParams, initiator, params.maxLtv);

        uint256 referralFeeAssets = params.borrowAssets.mulDivDown(params.referralFeePct, WAD);
        require(penaltyAssets <= params.borrowAssets - referralFeeAssets, SlippageExceeded());
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(params.marketParams.loanToken, params.referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(
            params.marketParams.loanToken, initiator, params.borrowAssets - referralFeeAssets - penaltyAssets
        );
    }

    function withdraw(WithdrawParams memory params, uint64[] memory penalties, uint256 penaltyAssets) internal {
        executePublicAllocations(params.marketParams, params.reallocations, penalties, penaltyAssets);
        (uint256 assets,) =
            IMorpho(BLUE).withdraw(params.marketParams, params.assets, params.shares, initiator, address(this));

        uint256 referralFeeAssets = assets.mulDivDown(params.referralFeePct, WAD);
        require(penaltyAssets <= assets - referralFeeAssets, SlippageExceeded());
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(params.marketParams.loanToken, params.referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(
            params.marketParams.loanToken, initiator, assets - referralFeeAssets - penaltyAssets
        );
    }

    function migrateBorrowPosition(
        MigrateBorrowPositionParams memory params,
        uint64[] memory penalties,
        uint256 penaltyAssets
    ) internal {
        Position memory position = IMorpho(BLUE).position(params.sourceMarketParams.id(), initiator);
        executePublicAllocations(params.destMarketParams, params.reallocations, penalties, penaltyAssets);

        bytes memory data = abi.encode(
            params.sourceMarketParams,
            params.destMarketParams,
            position.collateral,
            params.referralFeePct,
            params.referralFeeRecipient,
            params.destMinSharePriceE27,
            penaltyAssets
        );
        (uint256 assets,) = IMorpho(BLUE).repay(params.sourceMarketParams, 0, position.borrowShares, initiator, data);
        require(assets.mulDivUp(1e27, position.borrowShares) <= params.sourceMaxSharePriceE27, SlippageExceeded());

        requireMaxLtv(params.destMarketParams, initiator, params.maxLtv);
    }

    /// @dev Each reallocation either allocates the vault's idle assets, or first deallocates assets from its source market.
    /// @dev The allocation destination is always marketParams, so the bundler cannot move a vault's liquidity anywhere else than the market it is about to act on.
    /// @dev Uses the penalty rates read before the flash loan. The public allocator rejects a rate change and charges
    /// the aggregate penaltyAssets calculated with the same per-call upward rounding.
    function executePublicAllocations(
        MarketParams memory marketParams,
        PublicAllocations[] memory reallocations,
        uint64[] memory penalties,
        uint256 penaltyAssets
    ) internal {
        TokenLib.safeApprove(marketParams.loanToken, PUBLIC_ALLOCATOR, 0);
        TokenLib.safeApprove(marketParams.loanToken, PUBLIC_ALLOCATOR, penaltyAssets);

        for (uint256 i; i < reallocations.length; i++) {
            PublicAllocations memory reallocation = reallocations[i];
            uint64 penalty = penalties[i];

            if (reallocation.fromIdle) {
                IBluePublicAllocator(PUBLIC_ALLOCATOR)
                    .allocateFromIdle(
                        reallocation.vault, reallocation.adapter, marketParams, reallocation.assets, penalty
                    );
            } else {
                IBluePublicAllocator(PUBLIC_ALLOCATOR)
                    .reallocate(
                        reallocation.vault,
                        reallocation.sourceAdapter,
                        reallocation.sourceMarketParams,
                        reallocation.adapter,
                        marketParams,
                        reallocation.assets,
                        penalty
                    );
            }
        }

        TokenLib.safeApprove(marketParams.loanToken, PUBLIC_ALLOCATOR, 0);
    }

    function previewPublicAllocationPenalties(PublicAllocations[] memory reallocations)
        internal
        view
        returns (uint256 penaltyAssets, uint64[] memory penalties)
    {
        penalties = new uint64[](reallocations.length);
        for (uint256 i; i < reallocations.length; i++) {
            PublicAllocations memory reallocation = reallocations[i];
            (, uint64 penalty) = IBluePublicAllocator(PUBLIC_ALLOCATOR).vaultData(reallocation.vault);
            require(penalty <= reallocation.maxPenalty, SlippageExceeded());
            penalties[i] = penalty;
            penaltyAssets += uint256(reallocation.assets).mulDivUp(penalty, WAD);
        }
    }

    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until signedAuthorization.deadline, as revoking on Blue does not consume the nonce.
    function setAuthorizationWithSig(SignedAuthorization memory signedAuthorization) internal {
        Signature memory signature = signedAuthorization.signature;
        bool emptySignature = signature.v == 0 && signature.r == 0 && signature.s == 0;

        if (!emptySignature && IMorpho(BLUE).nonce(msg.sender) <= signedAuthorization.nonce) {
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
