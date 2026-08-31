// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IBlueBundlesV1, SignedAuthorization, PublicAllocations} from "./interfaces/IBlueBundlesV1.sol";
import {IBluePublicAllocator} from "./interfaces/IBluePublicAllocator.sol";
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
/// @dev Share-price slippage is not checked. Users must instead ensure that they use only markets that are protected against supply share price inflation attacks.
contract BlueBundlesV1 is IBlueBundlesV1, IMorphoRepayCallback, IMorphoFlashLoanCallback {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;
    address public immutable PUBLIC_ALLOCATOR;

    uint256 internal transient withdrawnAssetsTransient;

    constructor(address _blue, address _publicAllocator) {
        BLUE = _blue;
        PUBLIC_ALLOCATOR = _publicAllocator;
    }

    /// @dev Receives the native tokens unwrapped from the wrapped-native token when reimbursing a native repay.
    receive() external payable {}

    /// ENTRYPOINT ///

    /// @dev Pulls collateralAssets from msg.sender (optionally via ERC-2612 or Permit2), supplies it on Blue, then borrows borrowAssets (if non-zero) on behalf of msg.sender.
    /// @dev When native tokens are sent, collateralPermit.kind must be PermitKind.None and collateralAssets must equal msg.value; the native tokens are wrapped into marketParams.collateralToken (which must be the wrapped-native token) instead of being pulled.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev The aggregate public allocator penalties P are deducted from borrowAssets before the referral fee is charged. The resulting net borrow proceeds are sent to msg.sender. Fee = floor((borrowAssets - P) * referralFeePct / WAD).
    /// @dev To receive an amount W, pass borrowAssets = P + floor(W * WAD / (WAD - referralFeePct)).
    /// @dev maxLtv caps msg.sender's resulting LTV; type(uint256).max disables it.
    /// @dev reallocations must be empty when borrowAssets is zero.
    /// @dev The aggregate penalty of the reallocations is flash loaned to pay the public allocator upfront.
    /// @dev All public reallocations execute unconditionally.
    function blueBundlesV1SupplyCollateralAndBorrow(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 borrowAssets,
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
        require(borrowAssets > 0 || reallocations.length == 0, InconsistentBorrowInput());

        setAuthorizationWithSig(signedAuthorization);
        TokenLib.pullOrWrapNative(marketParams.collateralToken, msg.sender, collateralAssets, collateralPermit);
        if (collateralAssets > 0) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, collateralAssets, msg.sender, "");
        }
        uint256 penaltyAssets = totalPenaltyAssets(reallocations);
        if (penaltyAssets > 0) {
            bytes memory operationData = abi.encode(marketParams, borrowAssets, reallocations);
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            IMorpho(BLUE)
                .flashLoan(
                    marketParams.loanToken,
                    penaltyAssets,
                    abi.encode(msg.sender, this.blueBundlesV1SupplyCollateralAndBorrow.selector, operationData)
                );
        } else {
            executeBorrow(marketParams, borrowAssets, reallocations, msg.sender);
        }

        uint256 receivedAssets = borrowAssets - penaltyAssets;
        uint256 referralFeeAssets = receivedAssets.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        SafeTransferLib.safeTransfer(marketParams.loanToken, msg.sender, receivedAssets - referralFeeAssets);
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    function executeBorrow(
        MarketParams memory marketParams,
        uint256 borrowAssets,
        PublicAllocations[] memory reallocations,
        address sender
    ) internal {
        executePublicAllocations(marketParams.loanToken, reallocations);
        if (borrowAssets > 0) {
            IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, sender, address(this));
        }
    }

    /// @dev Pulls maxRepayAssets from msg.sender, repays msg.sender's debt (if repayAssets or repayShares are non-zero), reimburses the unused remainder (if any) at the end of the call, and withdraws collateral if collateralAssets > 0.
    /// @dev When native tokens are sent, loanTokenPermit.kind must be PermitKind.None and maxRepayAssets must equal msg.value; the native tokens are wrapped into marketParams.loanToken (which must be the wrapped-native token) instead of being pulled, and the reimbursed remainder is unwrapped back to native.
    /// @dev Reimbursing native tokens requires msg.sender to be able to receive native tokens, or else it will revert.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization, if some collateral is withdrawn.
    /// @dev At least one of repayAssets and repayShares must be zero to repay; set both to zero for a pure collateral withdrawal.
    /// @dev When repayShares is type(uint256).max, it is replaced with msg.sender's borrow shares at execution to close any remaining debt.
    /// @dev The fee is repaidAssets * referralFeePct / (WAD - referralFeePct), where repaidAssets is the actual assets repaid.
    /// @dev maxLtv caps msg.sender's resulting LTV; type(uint256).max disables it.
    function blueBundlesV1RepayAndWithdrawCollateral(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 repayShares,
        uint256 maxRepayAssets,
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

        if (repayShares == type(uint256).max) {
            repayShares = IMorpho(BLUE).position(marketParams.id(), msg.sender).borrowShares;
        }

        if (repayAssets > 0 || repayShares > 0) {
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            (repayAssets,) = IMorpho(BLUE).repay(marketParams, repayAssets, repayShares, msg.sender, "");
        }

        if (collateralAssets > 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, collateralAssets, msg.sender, msg.sender);
        }

        uint256 referralFeeAssets = repayAssets.mulDivDown(referralFeePct, WAD - referralFeePct);
        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
        requireMaxLtv(marketParams, msg.sender, maxLtv);

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
    function blueBundlesV1Supply(
        MarketParams memory marketParams,
        uint256 assets,
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

        IMorpho(BLUE).supply(marketParams, toSupply, 0, msg.sender, "");

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }
    }

    /// @dev Withdraws from msg.sender's supply position.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev Exactly one of withdrawAssets and withdrawShares should be non-zero: the position is withdrawn by assets, or by shares. To close the full supply position so no supply shares remain, pass msg.sender's full supply shares as withdrawShares.
    /// @dev The aggregate public allocator penalties P are deducted from withdrawnAssets before the referral fee is charged. The resulting net withdrawal proceeds are sent to msg.sender. Fee = floor((withdrawnAssets - P) * referralFeePct / WAD).
    /// @dev To receive an amount W when withdrawing by assets, pass withdrawAssets = P + floor(W * WAD / (WAD - referralFeePct)) and withdrawShares = 0.
    /// @dev The supply share price is not checked: any drop due to bad debt realisation is not quickly reversed, so a reverted exit retried later would be on similar or worse terms.
    /// @dev All public reallocations execute unconditionally; their aggregate penalty is not bounded relative to withdrawAssets.
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
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
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
        // forge-lint: disable-next-item(missing-events-arithmetic) transient plumbing.
        (withdrawnAssetsTransient,) =
            IMorpho(BLUE).withdraw(marketParams, withdrawAssets, withdrawShares, sender, address(this));
    }

    /// @dev Moves the full position of msg.sender (collateral and borrow shares, read from Blue) from the source market to the destination market.
    /// @dev The msg.sender must have authorized this contract on Blue, beforehand or via signedAuthorization.
    /// @dev The referral fee and public allocator penalties are borrowed on the destination on top of the repaid assets, adding to the debt. Fee = repaidAssets * referralFeePct / (WAD - referralFeePct); total borrowed = repaidAssets + fee + penalties.
    /// @dev maxLtv caps the resulting LTV of the destination position, which includes fees, and any previous position. Pass type(uint256).max to disable.
    /// @dev Migrating a position without debt reverts on Blue.
    /// @dev The aggregate penalty of the reallocations is flash loaned to pay the public allocator upfront.
    /// @dev All public reallocations execute unconditionally.
    function blueBundlesV1MigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        MarketParams memory destMarketParams,
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
            referralFeeRecipient
        );
        uint256 penaltyAssets = totalPenaltyAssets(reallocations);
        if (penaltyAssets == 0) {
            executeMigrateBorrowPosition(
                sourceMarketParams, position.borrowShares, reallocations, migrationData, 0, msg.sender
            );
        } else {
            bytes memory operationData =
                abi.encode(sourceMarketParams, uint256(position.borrowShares), reallocations, migrationData);
            TokenLib.forceApproveMax(destMarketParams.loanToken, BLUE);
            IMorpho(BLUE)
                .flashLoan(
                    destMarketParams.loanToken,
                    penaltyAssets,
                    abi.encode(msg.sender, this.blueBundlesV1MigrateBorrowPosition.selector, operationData)
                );
        }
        requireMaxLtv(destMarketParams, msg.sender, maxLtv);
    }

    /// @dev migrationData is the onMorphoRepay callback data, passed through opaquely; the flash-loaned penaltyAssets is appended to it.
    function executeMigrateBorrowPosition(
        MarketParams memory sourceMarketParams,
        uint256 borrowShares,
        PublicAllocations[] memory reallocations,
        bytes memory migrationData,
        uint256 penaltyAssets,
        address sender
    ) internal {
        executePublicAllocations(sourceMarketParams.loanToken, reallocations);

        bytes memory data = abi.encode(migrationData, penaltyAssets);
        IMorpho(BLUE).repay(sourceMarketParams, 0, borrowShares, sender, data);
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
            address referralFeeRecipient
        ) = abi.decode(migrationData, (MarketParams, MarketParams, uint256, address, uint256, address));

        uint256 referralFeeAssets = assets.mulDivDown(referralFeePct, WAD - referralFeePct);
        uint256 borrowAssets = assets + referralFeeAssets + penaltyAssets;

        IMorpho(BLUE).withdrawCollateral(sourceMarketParams, collateral, sender, address(this));

        TokenLib.forceApproveMax(destMarketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(destMarketParams, collateral, sender, "");
        IMorpho(BLUE).borrow(destMarketParams, borrowAssets, 0, sender, address(this));

        if (referralFeeAssets > 0) {
            SafeTransferLib.safeTransfer(destMarketParams.loanToken, referralFeeRecipient, referralFeeAssets);
        }

        TokenLib.forceApproveMax(sourceMarketParams.loanToken, BLUE);
    }

    function onMorphoFlashLoan(uint256 penaltyAssets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (address sender, bytes4 selector, bytes memory operationData) = abi.decode(data, (address, bytes4, bytes));

        if (selector == this.blueBundlesV1SupplyCollateralAndBorrow.selector) {
            (MarketParams memory marketParams, uint256 borrowAssets, PublicAllocations[] memory reallocations) =
                abi.decode(operationData, (MarketParams, uint256, PublicAllocations[]));
            executeBorrow(marketParams, borrowAssets, reallocations, sender);
        } else if (selector == this.blueBundlesV1Withdraw.selector) {
            (
                MarketParams memory marketParams,
                uint256 withdrawAssets,
                uint256 withdrawShares,
                PublicAllocations[] memory reallocations
            ) = abi.decode(operationData, (MarketParams, uint256, uint256, PublicAllocations[]));
            executeWithdraw(marketParams, withdrawAssets, withdrawShares, reallocations, sender);
        } else if (selector == this.blueBundlesV1MigrateBorrowPosition.selector) {
            (
                MarketParams memory sourceMarketParams,
                uint256 borrowShares,
                PublicAllocations[] memory reallocations,
                bytes memory migrationData
            ) = abi.decode(operationData, (MarketParams, uint256, PublicAllocations[], bytes));
            executeMigrateBorrowPosition(
                sourceMarketParams, borrowShares, reallocations, migrationData, penaltyAssets, sender
            );
        } else {
            revert UnauthorizedCallback();
        }
    }

    /// INTERNAL ///

    /// @dev All touched markets' loan token must be the flash-loaned loanToken, such that all penalties are paid in that same token.
    function executePublicAllocations(address loanToken, PublicAllocations[] memory reallocations) internal {
        if (reallocations.length == 0) return;

        TokenLib.forceApproveMax(loanToken, PUBLIC_ALLOCATOR);

        for (uint256 i; i < reallocations.length; i++) {
            PublicAllocations memory reallocation = reallocations[i];
            require(reallocation.marketParams.loanToken == loanToken, InconsistentTokens());

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
            // forge-lint: disable-next-item(named-struct-fields) named fields would change the compiled bytecode.
            IMorpho(BLUE)
                .setAuthorizationWithSig(
                    Authorization(
                        msg.sender, address(this), true, signedAuthorization.nonce, signedAuthorization.deadline
                    ),
                    signature
                );
        }
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; type(uint256).max disables the check (and notably skips the oracle call).
    /// @dev Accrues market interest when needed, then mirrors Blue's own health check against maxLtv.
    function requireMaxLtv(MarketParams memory marketParams, address sender, uint256 maxLtv) internal {
        if (maxLtv != type(uint256).max) {
            Position memory position = IMorpho(BLUE).position(marketParams.id(), sender);
            if (position.borrowShares != 0) {
                Market memory market = IMorpho(BLUE).market(marketParams.id());
                if (market.lastUpdate != block.timestamp) {
                    IMorpho(BLUE).accrueInterest(marketParams);
                    market = IMorpho(BLUE).market(marketParams.id());
                }
                uint256 borrowed =
                    uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
                uint256 price = IOracle(marketParams.oracle).price();
                uint256 maxBorrow =
                    uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
                require(borrowed <= maxBorrow, LtvExceeded());
            }
        }
    }
}
