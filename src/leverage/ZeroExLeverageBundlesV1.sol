// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IAllowanceHolder} from "./interfaces/IAllowanceHolder.sol";
import {IZeroExDeployer} from "./interfaces/IZeroExDeployer.sol";
import {IZeroExLeverageBundlesV1} from "./interfaces/IZeroExLeverageBundlesV1.sol";
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
import {TokenLib} from "../libraries/TokenLib.sol";

/// @notice Executes exact-input and exact-output swaps through 0x AllowanceHolder and Settler.
contract ZeroExLeverageBundlesV1 is IZeroExLeverageBundlesV1, IMorphoSupplyCollateralCallback, IMorphoRepayCallback {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    uint128 internal constant SETTLER_FEATURE = 2;

    address public immutable override BLUE;
    address public immutable override ALLOWANCE_HOLDER;
    address public immutable override ZERO_EX_DEPLOYER;

    /// @dev Settler can make arbitrary calls; Morpho only acts for the authorized caller, and the lock spans callbacks.
    bool internal transient locked;

    /// @param blue Morpho Blue contract.
    /// @param allowanceHolder 0x AllowanceHolder contract.
    /// @param zeroExDeployer 0x Settler registry/deployer.
    constructor(address blue, address allowanceHolder, address zeroExDeployer) {
        BLUE = blue;
        ALLOWANCE_HOLDER = allowanceHolder;
        ZERO_EX_DEPLOYER = zeroExDeployer;
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

    /// @notice Adds caller collateral and exact-output purchased collateral to the caller's position.
    /// @param marketParams Morpho Blue market parameters.
    /// @param collateralAssets Collateral-token amount to pull from the caller.
    /// @param collateralToBuy Exact collateral-token output requested by the 0x API BUY quote.
    /// @param maxBorrowAssets Maximum loan-token amount to borrow and spend; unused assets are repaid.
    /// @param swapData The 0x AllowanceHolder quote's `transaction.data`, with this bundle as taker.
    /// @param maxLtv Maximum resulting LTV; type(uint256).max disables the check.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `buyAmount` equal to `collateralToBuy`.
    function zeroExLeverageBundlesV1Open(
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

        (address settler, bytes memory settlerData) = _decodeSwapData(swapData, marketParams.loanToken);
        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + collateralToBuy,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1Open.selector,
                    msg.sender,
                    abi.encode(marketParams, collateralToBuy, maxBorrowAssets, settler, settlerData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Opens a leveraged position by borrowing and selling loan tokens.
    /// @param marketParams Morpho Blue market parameters.
    /// @param collateralAssets Collateral-token amount to pull from the caller.
    /// @param borrowAssets Loan-token amount to borrow and sell; unspent assets are repaid.
    /// @param minCollateralOut Minimum collateral-token output required from the quote.
    /// @param swapData The 0x AllowanceHolder quote's `transaction.data`, with this bundle as taker.
    /// @param maxLtv Maximum resulting LTV; type(uint256).max disables the check.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `sellAmount` equal to `borrowAssets`.
    function zeroExLeverageBundlesV1OpenExactIn(
        MarketParams memory marketParams,
        uint256 collateralAssets,
        uint256 borrowAssets,
        uint256 minCollateralOut,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());

        (address settler, bytes memory settlerData) = _decodeSwapData(swapData, marketParams.loanToken);
        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);
        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .supplyCollateral(
                marketParams,
                collateralAssets + minCollateralOut,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1OpenExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, borrowAssets, minCollateralOut, settler, settlerData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays part of the caller's debt using a 0x API BUY quote for loan tokens.
    /// @param marketParams Morpho Blue market parameters.
    /// @param repayAssets Exact loan-token output requested from the quote.
    /// @param maxCollateralIn Maximum collateral-token amount to withdraw and spend.
    /// @param swapData The 0x AllowanceHolder quote's `transaction.data`, with this bundle as taker.
    /// @param maxLtv Maximum resulting LTV; type(uint256).max disables the check.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `buyAmount` equal to `repayAssets`.
    function zeroExLeverageBundlesV1Delever(
        MarketParams memory marketParams,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        (address settler, bytes memory settlerData) = _decodeSwapData(swapData, marketParams.collateralToken);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                repayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1Delever.selector,
                    msg.sender,
                    abi.encode(marketParams, maxCollateralIn, settler, settlerData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays part of the caller's debt by selling collateral using a 0x API SELL quote.
    /// @param marketParams Morpho Blue market parameters.
    /// @param collateralToSell Collateral-token amount to sell.
    /// @param minRepayAssets Minimum loan-token output required from the quote.
    /// @param swapData The 0x AllowanceHolder quote's `transaction.data`, with this bundle as taker.
    /// @param maxLtv Maximum resulting LTV; type(uint256).max disables the check.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `sellAmount` equal to `collateralToSell`.
    function zeroExLeverageBundlesV1DeleverExactIn(
        MarketParams memory marketParams,
        uint256 collateralToSell,
        uint256 minRepayAssets,
        bytes calldata swapData,
        uint256 maxLtv,
        uint256 deadline
    ) external override nonReentrant {
        require(block.timestamp <= deadline, DeadlinePassed());
        (address settler, bytes memory settlerData) = _decodeSwapData(swapData, marketParams.collateralToken);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                minRepayAssets,
                0,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1DeleverExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, collateralToSell, minRepayAssets, settler, settlerData)
                )
            );
        requireMaxLtv(marketParams, msg.sender, maxLtv);
    }

    /// @notice Repays all borrow shares and swaps collateral for the debt, returning unspent collateral and excess loan tokens.
    /// @param marketParams Morpho Blue market parameters.
    /// @param maxCollateralIn Maximum collateral-token amount that may be spent.
    /// @param swapData The 0x API BUY quote's `transaction.data`, with this bundle as taker and `buyAmount` set to debt plus a small buffer.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `buyAmount` equal to debt plus a small buffer; the buffer returns as loan tokens.
    function zeroExLeverageBundlesV1Close(
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

        (address settler, bytes memory settlerData) = _decodeSwapData(swapData, marketParams.collateralToken);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1Close.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, maxCollateralIn, settler, settlerData)
                )
            );
    }

    /// @notice Sells all collateral using a 0x API SELL quote, repays the debt and returns loan-token equity.
    /// @param marketParams Morpho Blue market parameters.
    /// @param minLoanOut Minimum total loan-token output, including the amount used to repay debt.
    /// @param swapData The 0x API SELL quote's `transaction.data`, with `sellAmount` equal to the position's full collateral.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @dev Quote with `sellAmount` equal to the position's full collateral.
    function zeroExLeverageBundlesV1CloseExactIn(
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

        (address settler, bytes memory settlerData) = _decodeSwapData(swapData, marketParams.collateralToken);
        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        // forge-lint: disable-next-item(reentrancy-no-eth) The entrypoint lock remains active through the callback.
        IMorpho(BLUE)
            .repay(
                marketParams,
                0,
                position.borrowShares,
                msg.sender,
                abi.encode(
                    this.zeroExLeverageBundlesV1CloseExactIn.selector,
                    msg.sender,
                    abi.encode(marketParams, position.collateral, minLoanOut, settler, settlerData)
                )
            );
    }

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external override {
        require(msg.sender == BLUE, UnauthorizedCallback());

        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));
        if (selector == this.zeroExLeverageBundlesV1Open.selector) {
            _openCallback(user, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1OpenExactIn.selector) {
            _openExactInCallback(user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function _openCallback(address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 collateralToBuy,
            uint256 maxBorrowAssets,
            address settler,
            bytes memory settlerData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, address, bytes));

        IMorpho(BLUE).borrow(marketParams, maxBorrowAssets, 0, user, address(this));
        (uint256 spent, uint256 received) = _swap(
            marketParams.loanToken, marketParams.collateralToken, maxBorrowAssets, collateralToBuy, settler, settlerData
        );

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
        (
            MarketParams memory marketParams,
            uint256 borrowAssets,
            uint256 minCollateralOut,
            address settler,
            bytes memory settlerData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, address, bytes));

        IMorpho(BLUE).borrow(marketParams, borrowAssets, 0, user, address(this));
        (uint256 spent, uint256 received) = _swap(
            marketParams.loanToken, marketParams.collateralToken, borrowAssets, minCollateralOut, settler, settlerData
        );

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
        if (selector == this.zeroExLeverageBundlesV1Delever.selector) {
            _deleverCallback(assets, user, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1DeleverExactIn.selector) {
            _deleverExactInCallback(assets, user, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1Close.selector) {
            _closeCallback(assets, user, operationData);
        } else if (selector == this.zeroExLeverageBundlesV1CloseExactIn.selector) {
            _closeExactInCallback(assets, user, operationData);
        } else {
            revert UnauthorizedCallback();
        }
    }

    function _deleverCallback(uint256 assets, address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, uint256 maxCollateralIn, address settler, bytes memory settlerData) =
            abi.decode(operationData, (MarketParams, uint256, address, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, maxCollateralIn, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, settler, settlerData);

        if (maxCollateralIn > spent) {
            TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
            IMorpho(BLUE).supplyCollateral(marketParams, maxCollateralIn - spent, user, "");
        }
        _repayDeleverSurplus(marketParams, user, assets, received);
    }

    function _deleverExactInCallback(uint256 assets, address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 collateralToSell,
            uint256 minRepayAssets,
            address settler,
            bytes memory settlerData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, address, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateralToSell, user, address(this));
        (uint256 spent, uint256 received) = _swap(
            marketParams.collateralToken, marketParams.loanToken, collateralToSell, minRepayAssets, settler, settlerData
        );

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
        (
            MarketParams memory marketParams,
            uint256 collateral,
            uint256 maxCollateralIn,
            address settler,
            bytes memory settlerData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, address, bytes));

        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, maxCollateralIn, assets, settler, settlerData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function _closeExactInCallback(uint256 assets, address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            uint256 collateral,
            uint256 minLoanOut,
            address settler,
            bytes memory settlerData
        ) = abi.decode(operationData, (MarketParams, uint256, uint256, address, bytes));

        uint256 minOut = Math.max(minLoanOut, assets);
        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        (uint256 spent, uint256 received) =
            _swap(marketParams.collateralToken, marketParams.loanToken, collateral, minOut, settler, settlerData);

        if (collateral > spent) {
            SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - spent);
        }
        if (received > assets) {
            SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - assets);
        }
    }

    function _decodeSwapData(bytes calldata swapData, address tokenIn)
        internal
        view
        returns (address settler, bytes memory settlerData)
    {
        require(swapData.length >= 4 && bytes4(swapData[:4]) == IAllowanceHolder.exec.selector, InvalidSwapData());
        require(swapData.length >= 196, InvalidSwapData());

        address operator;
        address token;
        address target;
        (operator, token,, target, settlerData) = abi.decode(swapData[4:], (address, address, uint256, address, bytes));
        require(operator == target && token == tokenIn, InvalidSwapData());
        settler = operator;
        if (IZeroExDeployer(ZERO_EX_DEPLOYER).ownerOf(SETTLER_FEATURE) != settler) {
            require(IZeroExDeployer(ZERO_EX_DEPLOYER).prev(SETTLER_FEATURE) == settler, InvalidSettler());
        }
    }

    /// @dev Reverts unless sender's LTV is at or below maxLtv; type(uint256).max disables the check.
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

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 maxIn,
        uint256 minOut,
        address settler,
        bytes memory settlerData
    ) internal returns (uint256 spent, uint256 received) {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        TokenLib.safeApprove(tokenIn, ALLOWANCE_HOLDER, maxIn);
        IAllowanceHolder(ALLOWANCE_HOLDER).exec(settler, tokenIn, maxIn, payable(settler), settlerData);
        TokenLib.safeApprove(tokenIn, ALLOWANCE_HOLDER, 0);

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
