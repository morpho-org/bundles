// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IAugustusV6} from "./interfaces/IAugustusV6.sol";
import {IVeloraLeverageBundlesV1} from "./interfaces/IVeloraLeverageBundlesV1.sol";
import {IMorpho, MarketParams, Position, Market} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoRepayCallback,
    IMorphoSupplyCollateralCallback
} from "../../lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {Math} from "../../lib/vault-v2/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BytesLib} from "../libraries/BytesLib.sol";
import {TokenLib} from "../libraries/TokenLib.sol";

/// @notice Executes exact-input and exact-output swaps using the Augustus v6.2 contract fixed at deployment.
contract VeloraLeverageBundlesV1 is IVeloraLeverageBundlesV1, IMorphoSupplyCollateralCallback, IMorphoRepayCallback {
    using MarketParamsLib for MarketParams;
    using BytesLib for bytes;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;

    address public immutable override BLUE;
    address public immutable override AUGUSTUS;

    /// @dev Blocks re-entry from the swap executor into the entrypoints.
    bool internal transient locked;

    constructor(address blue, address augustus) {
        BLUE = blue;
        AUGUSTUS = augustus;
    }

    modifier nonReentrant() {
        _lock();
        _;
        _unlock();
    }

    function _lock() internal {
        require(!locked, Reentrancy());
        locked = true;
    }

    function _unlock() internal {
        locked = false;
    }

    /// @notice Adds caller collateral and purchased collateral to the caller's position using borrowed assets.
    /// @param collateralAssets Collateral-token amount to pull from the caller, in token base units.
    /// @param collateralToBuy Nonzero additional collateral-token amount to acquire and supply, in token base units.
    /// @param maxBorrowAssets Maximum loan-token amount to borrow for the swap; unused assets are repaid.
    /// @param swapData Augustus v6.2 exact-output calldata with `beneficiary` set to this bundle and a nonzero output amount.
    /// @param maxLtv Maximum resulting LTV of the caller's position, in WAD; type(uint256).max disables the check.
    /// @dev Resizes output to `collateralToBuy + 1` for Augustus's payout rounding.
    function veloraLeverageBundlesV1Open(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 collateralToBuy,
        uint256 maxBorrowAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(collateralToBuy != 0, ZeroCollateralToBuy());

        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + collateralToBuy,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Open.selector,
                    msg.sender,
                    abi.encode(marketParams, collateralToBuy, maxBorrowAssets, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Opens a leveraged position by borrowing and selling an exact amount of loan tokens.
    /// @param collateralAssets Collateral-token amount to pull from the caller.
    /// @param borrowAssets Loan-token amount to borrow and sell.
    /// @param minCollateralOut Minimum collateral-token amount the swap must return.
    /// @param swapData Augustus v6.2 exact-input calldata with `beneficiary` set to this bundle.
    /// @param maxLtv Maximum resulting LTV of the caller's position, in WAD; type(uint256).max disables the check.
    /// @dev Sets Augustus's minimum output to `minCollateralOut + 1` for its one-wei payout retention.
    function veloraLeverageBundlesV1OpenExactIn(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 borrowAssets,
        uint256 minCollateralOut,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + minCollateralOut,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1OpenExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, borrowAssets, minCollateralOut, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays part of the caller's debt by withdrawing and swapping collateral.
    /// @param swapData Augustus v6.2 exact-output calldata with `beneficiary` set to this bundle and a nonzero output amount.
    /// @param maxLtv Maximum resulting LTV of the caller's position, in WAD; type(uint256).max disables the check.
    /// @dev Resizes output to Morpho's callback repayment amount plus one wei and repays any excess against remaining debt.
    function veloraLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                repayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Delever.selector,
                    msg.sender,
                    abi.encode(marketParams, maxCollateralIn, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays part of the caller's debt by selling an exact amount of collateral.
    /// @param collateralToSell Collateral-token amount to sell.
    /// @param minRepayAssets Minimum loan-token amount the swap must return for repayment.
    /// @param swapData Augustus v6.2 exact-input calldata with `beneficiary` set to this bundle.
    /// @param maxLtv Maximum resulting LTV of the caller's position, in WAD; type(uint256).max disables the check.
    /// @dev Excess loan tokens repay remaining debt up to its balance; any rest is returned to the caller.
    /// Augustus's minimum output is set to `minRepayAssets + 1` for its payout retention.
    function veloraLeverageBundlesV1DeleverExactIn(
        MarketParams memory marketParams,
        uint256 collateralToSell,
        uint256 minRepayAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                minRepayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1DeleverExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, collateralToSell, minRepayAssets, swapData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays all borrow shares and returns the remaining collateral.
    /// @param maxCollateralIn Absolute collateral spending cap, including after resizing the swap.
    /// @param swapData Augustus v6.2 exact-output calldata with `beneficiary` set to this bundle; amount offsets are derived from its selector.
    /// @dev Resizes output to Morpho's callback debt plus one base unit for Augustus's payout rounding.
    /// Maximum and quoted input amounts are scaled proportionally, rounding down; maximum input is capped at `maxCollateralIn`.
    function veloraLeverageBundlesV1Close(
        MarketParams memory marketParams,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
            return;
        }

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1Close.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, maxCollateralIn, swapData)
                )
            );
    }

    /// @notice Closes a position by selling all collateral and returning remaining loan tokens as equity.
    /// @param minLoanOut Minimum total loan-token output, including the amount used to repay debt.
    /// @param swapData Augustus v6.2 exact-input calldata with `beneficiary` set to this bundle.
    /// @dev Sets Augustus's minimum output to `max(minLoanOut, callback debt) + 1` and returns output above the debt to the caller.
    function veloraLeverageBundlesV1CloseExactIn(
        MarketParams memory marketParams,
        uint256 minLoanOut,
        bytes calldata swapData,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        if (position.borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, position.collateral, msg.sender, msg.sender);
            return;
        }

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint guard is active throughout this callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.veloraLeverageBundlesV1CloseExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, minLoanOut, swapData)
                )
            );
    }

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external override {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.veloraLeverageBundlesV1Open.selector) {
            _openCallback(user, operationData);
        } else if (selector == this.veloraLeverageBundlesV1OpenExactIn.selector) {
            _openExactInCallback(user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function _openCallback(address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateralToBuy, uint256 maxBorrowAssets, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).borrow(marketParams, maxBorrowAssets, 0, user, address(this));
        _resizeSwapData(swapData, collateralToBuy + 1, maxBorrowAssets);
        (uint256 spent, uint256 received) =
            _swap(marketParams.loanToken, marketParams.collateralToken, maxBorrowAssets, collateralToBuy, swapData);

        if (maxBorrowAssets > spent) {
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            IMorpho(BLUE).repay(marketParams, maxBorrowAssets - spent, 0, user, "");
        }
        if (received > collateralToBuy) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, received - collateralToBuy, user, "");
        }
    }

    function _openExactInCallback(address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 borrowAssets, uint256 minCollateralOut, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, user, address(this));
        _resizeSwapDataExactIn(swapData, borrowAssets, minCollateralOut);
        (uint256 spent, uint256 received) =
            _swap(marketParams.loanToken, marketParams.collateralToken, borrowAssets, minCollateralOut, swapData);

        if (borrowAssets > spent) {
            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            IMorpho(BLUE).repay(marketParams, borrowAssets - spent, 0, user, "");
        }
        if (received > minCollateralOut) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, received - minCollateralOut, user, "");
        }
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external override {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.veloraLeverageBundlesV1Delever.selector) {
            _deleverCallback(assets, user, operationData);
        } else if (selector == this.veloraLeverageBundlesV1DeleverExactIn.selector) {
            _deleverExactInCallback(assets, user, operationData);
        } else if (selector == this.veloraLeverageBundlesV1Close.selector) {
            _closeCallback(assets, user, operationData);
        } else if (selector == this.veloraLeverageBundlesV1CloseExactIn.selector) {
            _closeExactInCallback(assets, user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function _deleverCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 maxCollateralIn, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, bytes));

        _resizeSwapData(swapData, assets + 1, maxCollateralIn);

        IMorpho(BLUE).withdrawCollateral(marketParams, maxCollateralIn, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, swapData);

        if (maxCollateralIn > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, maxCollateralIn - spent, user, "");
        }
        _repayDeleverSurplus(marketParams, user, assets, received);
    }

    function _deleverExactInCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateralToSell, uint256 minRepayAssets, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        _resizeSwapDataExactIn(swapData, collateralToSell, minRepayAssets);

        IMorpho(BLUE).withdrawCollateral(marketParams, collateralToSell, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, collateralToSell, minRepayAssets, swapData);

        if (collateralToSell > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, collateralToSell - spent, user, "");
        }
        _repayDeleverSurplus(marketParams, user, assets, received);
    }

    function _repayDeleverSurplus(MarketParams memory marketParams, address user, uint256 assets, uint256 received)
        internal
    {
        if (received > assets) {
            uint256 excess = received - assets;
            uint256 borrowShares = IMorpho(BLUE).position(marketParams.id(), user).borrowShares;
            Market memory market = IMorpho(BLUE).market(marketParams.id());
            uint256 debt = borrowShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

            TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
            if (excess >= debt) {
                if (borrowShares > 0) IMorpho(BLUE).repay(marketParams, 0, borrowShares, user, "");
                excess -= debt;
            } else {
                IMorpho(BLUE).repay(marketParams, excess, 0, user, "");
                excess = 0;
            }

            if (excess > 0) SafeTransferLib.safeTransfer(marketParams.loanToken, user, excess);
        }
    }

    function _closeCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateral, uint256 maxCollateralIn, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        _resizeSwapData(swapData, assets + 1, maxCollateralIn);

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, swapData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function _closeExactInCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 collateral, uint256 minLoanOut, bytes memory swapData) =
            abi.decode(operationData, (MarketParams, uint256, uint256, bytes));

        uint256 minOut = Math.max(minLoanOut, assets);
        _resizeSwapDataExactIn(swapData, collateral, minOut);

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, collateral, minOut, swapData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    /// @dev Updates only the selector-defined amount words; route data must support resizing these amounts.
    function _resizeSwapData(bytes memory data, uint256 amountOut, uint256 maxIn) internal pure {
        (uint256 exactAmount, uint256 limitAmount, uint256 quotedAmount, bool exactIn) = _amountOffsets(data);
        require(!exactIn, InvalidSelector());

        uint256 oldAmountOut = data.get(exactAmount);
        require(oldAmountOut != 0, ZeroSwapAmount());

        uint256 newLimitAmount = Math.min(Math.mulDiv(data.get(limitAmount), amountOut, oldAmountOut), maxIn);
        uint256 newQuotedAmount = Math.mulDiv(data.get(quotedAmount), amountOut, oldAmountOut);
        data.set(quotedAmount, newQuotedAmount);
        data.set(limitAmount, newLimitAmount);
        data.set(exactAmount, amountOut);
    }

    /// @dev Sets exact input, scales quoted output proportionally and adds Augustus's one-wei payout retention to the minimum output.
    function _resizeSwapDataExactIn(bytes memory data, uint256 amountIn, uint256 minOut) internal pure {
        (uint256 exactAmount, uint256 minAmount, uint256 quotedAmount, bool exactIn) = _amountOffsets(data);
        require(exactIn, InvalidSelector());

        uint256 oldAmountIn = data.get(exactAmount);
        require(oldAmountIn != 0, ZeroSwapAmount());

        uint256 newQuotedAmount = Math.mulDiv(data.get(quotedAmount), amountIn, oldAmountIn);
        data.set(quotedAmount, newQuotedAmount);
        data.set(minAmount, minOut + 1);
        data.set(exactAmount, amountIn);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        require(data.length >= 4, InvalidSelector());
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }

    function _amountOffsets(bytes memory data)
        internal
        pure
        returns (uint256 exactAmount, uint256 limitAmount, uint256 quotedAmount, bool exactIn)
    {
        bytes4 selector = _selector(data);

        if (selector == IAugustusV6.swapExactAmountOut.selector) return (132, 100, 164, false);
        if (selector == IAugustusV6.swapExactAmountIn.selector) return (100, 132, 164, true);
        if (
            selector == IAugustusV6.swapExactAmountOutOnUniswapV2.selector
                || selector == IAugustusV6.swapExactAmountOutOnUniswapV3.selector
        ) return (196, 164, 228, false);
        if (
            selector == IAugustusV6.swapExactAmountInOnUniswapV2.selector
                || selector == IAugustusV6.swapExactAmountInOnUniswapV3.selector
        ) return (164, 196, 228, true);
        revert InvalidSelector();
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; type(uint256).max disables the check (and notably skips the oracle call).
    /// @dev Accrues market interest when needed, then mirrors Blue's own health check against maxLtv.
    function requireMaxLtv(MarketParams memory marketParams, address sender, uint256 maxLtv) internal {
        if (maxLtv != type(uint256).max) {
            Position memory position = IMorpho(BLUE).position(marketParams.id(), sender);
            if (position.borrowShares != 0) {
                Market memory market = IMorpho(BLUE).market(marketParams.id());
                if (market.lastUpdate != block.timestamp) {
                    // forge-lint: disable-next-line(reentrancy-no-eth) The helper is only called from locked entrypoints.
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

    /// @dev Only generic, Uniswap V2 and Uniswap V3 exact-input or exact-output methods are accepted.
    function _swap(address tokenIn, address tokenOut, uint256 maxIn, uint256 minOut, bytes memory data)
        internal
        returns (uint256 spent, uint256 received)
    {
        _amountOffsets(data);
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TokenLib.safeApprove(tokenIn, AUGUSTUS, maxIn);
        (bool success, bytes memory returnData) = AUGUSTUS.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        TokenLib.safeApprove(tokenIn, AUGUSTUS, 0);

        uint256 inAfter = IERC20(tokenIn).balanceOf(address(this));
        require(inAfter <= inBefore, IncompleteFill());
        spent = inBefore - inAfter;
        require(spent <= maxIn, IncompleteFill());

        uint256 outAfter = IERC20(tokenOut).balanceOf(address(this));
        require(outAfter >= outBefore, IncompleteFill());
        received = outAfter - outBefore;
        require(received >= minOut, IncompleteFill());
    }
}
