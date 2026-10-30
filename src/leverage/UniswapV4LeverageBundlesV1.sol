// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IUniswapV4LeverageBundlesV1} from "./interfaces/IUniswapV4LeverageBundlesV1.sol";
import {BlueLeverageBase} from "./BlueLeverageBase.sol";
import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../lib/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "../../lib/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "../../lib/v4-core/src/libraries/TickMath.sol";

contract UniswapV4LeverageBundlesV1 is IUniswapV4LeverageBundlesV1, BlueLeverageBase, IUnlockCallback {
    using UtilsLib for uint256;
    using BalanceDeltaLibrary for BalanceDelta;

    address public immutable POOL_MANAGER;

    constructor(address blue, address poolManager) BlueLeverageBase(blue) {
        POOL_MANAGER = poolManager;
    }

    /// ENTRYPOINTS ///

    /// @dev Supplies caller collateral plus an exact-output swap, then borrows enough loan tokens to settle it.
    function uniswapV4LeverageBundlesV1Open(
        MarketParams memory marketParams,
        PoolKey memory poolKey,
        uint256 collateralAssets,
        uint256 leverage,
        uint256 maxBorrowAssets,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(leverage > 1e18, InvalidLeverage());
        validatePoolTokens(poolKey, marketParams.loanToken, marketParams.collateralToken);

        uint256 collateralToBuy = collateralAssets.mulDivDown(leverage - 1e18, 1e18);
        SafeTransferLib.safeTransferFrom(marketParams.collateralToken, msg.sender, address(this), collateralAssets);

        bytes memory operationData =
            abi.encode(marketParams, poolKey, collateralAssets, collateralToBuy, maxBorrowAssets);
        IPoolManager(POOL_MANAGER)
            .unlock(abi.encode(this.uniswapV4LeverageBundlesV1Open.selector, msg.sender, operationData));
    }

    /// @dev Swaps collateral for loan tokens and repays the requested debt amount.
    function uniswapV4LeverageBundlesV1Delever(
        MarketParams memory marketParams,
        PoolKey memory poolKey,
        uint256 repayAssets,
        uint256 maxCollateralIn,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        validatePoolTokens(poolKey, marketParams.collateralToken, marketParams.loanToken);

        bytes memory operationData = abi.encode(marketParams, poolKey, repayAssets, maxCollateralIn);
        IPoolManager(POOL_MANAGER)
            .unlock(abi.encode(this.uniswapV4LeverageBundlesV1Delever.selector, msg.sender, operationData));
    }

    /// @dev Swaps enough collateral to repay all borrow shares, then returns remaining collateral and loan tokens.
    function uniswapV4LeverageBundlesV1Close(
        MarketParams memory marketParams,
        PoolKey memory poolKey,
        uint256 maxCollateralIn,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        validatePoolTokens(poolKey, marketParams.collateralToken, marketParams.loanToken);

        (uint256 borrowShares, uint256 debtAssets, uint256 collateral) = readFullCloseTarget(marketParams);
        if (borrowShares == 0) {
            IMorpho(BLUE).withdrawCollateral(marketParams, collateral, msg.sender, msg.sender);
            return;
        }

        bytes memory operationData =
            abi.encode(marketParams, poolKey, borrowShares, debtAssets, collateral, maxCollateralIn);
        IPoolManager(POOL_MANAGER)
            .unlock(abi.encode(this.uniswapV4LeverageBundlesV1Close.selector, msg.sender, operationData));
    }

    /// CALLBACKS ///

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, UnauthorizedCallback());
        (bytes4 selector, address user, bytes memory operationData) = abi.decode(data, (bytes4, address, bytes));

        if (selector == this.uniswapV4LeverageBundlesV1Open.selector) {
            _openCallback(user, operationData);
        } else if (selector == this.uniswapV4LeverageBundlesV1Delever.selector) {
            _deleverCallback(user, operationData);
        } else if (selector == this.uniswapV4LeverageBundlesV1Close.selector) {
            _closeCallback(user, operationData);
        } else {
            revert UnauthorizedCallback();
        }

        return "";
    }

    /// INTERNALS ///

    function _openCallback(address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            PoolKey memory poolKey,
            uint256 collateralAssets,
            uint256 collateralToBuy,
            uint256 maxBorrowAssets
        ) = abi.decode(operationData, (MarketParams, PoolKey, uint256, uint256, uint256));

        (uint256 owed, uint256 received) = swapExactOutput(
            poolKey, marketParams.loanToken, marketParams.collateralToken, collateralToBuy, maxBorrowAssets
        );

        TokenLib.forceApproveMax(marketParams.collateralToken, BLUE);
        IMorpho(BLUE).supplyCollateral(marketParams, collateralAssets + received, user, "");
        IMorpho(BLUE).borrow(marketParams, owed, 0, user, address(this));
        settle(Currency.wrap(marketParams.loanToken), owed);
    }

    function _deleverCallback(address user, bytes memory operationData) internal {
        (MarketParams memory marketParams, PoolKey memory poolKey, uint256 repayAssets, uint256 maxCollateralIn) =
            abi.decode(operationData, (MarketParams, PoolKey, uint256, uint256));

        (uint256 owed, uint256 received) =
            swapExactOutput(poolKey, marketParams.collateralToken, marketParams.loanToken, repayAssets, maxCollateralIn);

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        IMorpho(BLUE).repay(marketParams, received, 0, user, "");
        IMorpho(BLUE).withdrawCollateral(marketParams, owed, user, address(this));
        settle(Currency.wrap(marketParams.collateralToken), owed);
    }

    function _closeCallback(address user, bytes memory operationData) internal {
        (
            MarketParams memory marketParams,
            PoolKey memory poolKey,
            uint256 borrowShares,
            uint256 debtAssets,
            uint256 collateral,
            uint256 maxCollateralIn
        ) = abi.decode(operationData, (MarketParams, PoolKey, uint256, uint256, uint256, uint256));

        (uint256 owed, uint256 received) =
            swapExactOutput(poolKey, marketParams.collateralToken, marketParams.loanToken, debtAssets, maxCollateralIn);

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);
        IMorpho(BLUE).repay(marketParams, 0, borrowShares, user, "");
        IMorpho(BLUE).withdrawCollateral(marketParams, collateral, user, address(this));
        settle(Currency.wrap(marketParams.collateralToken), owed);

        SafeTransferLib.safeTransfer(marketParams.collateralToken, user, collateral - owed);
        SafeTransferLib.safeTransfer(marketParams.loanToken, user, received - debtAssets);
    }

    function swapExactOutput(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn
    ) internal returns (uint256 owed, uint256 received) {
        validatePoolTokens(poolKey, tokenIn, tokenOut);

        bool zeroForOne = Currency.unwrap(poolKey.currency0) == tokenIn;
        Currency output = zeroForOne ? poolKey.currency1 : poolKey.currency0;
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        require(amountOut <= (type(uint256).max >> 1), IncompleteFill());
        // forge-lint: disable-next-line(unsafe-typecast) safe because of the bound above.
        int256 amountSpecified = int256(amountOut);
        BalanceDelta delta = IPoolManager(POOL_MANAGER)
            .swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                ""
            );

        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        require(outputDelta >= 0, IncompleteFill());
        // forge-lint: disable-next-line(unsafe-typecast) safe because outputDelta is nonnegative and int128-sized.
        received = uint256(uint128(outputDelta));
        require(received >= amountOut, IncompleteFill());
        require(inputDelta <= 0, SlippageExceeded());
        // forge-lint: disable-next-line(unsafe-typecast) safe because inputDelta is nonpositive and int128-sized.
        owed = uint256(-int256(inputDelta));
        require(owed <= maxIn, SlippageExceeded());

        IPoolManager(POOL_MANAGER).take(output, address(this), received);
    }

    function settle(Currency currency, uint256 amount) internal {
        IPoolManager(POOL_MANAGER).sync(currency);
        SafeTransferLib.safeTransfer(Currency.unwrap(currency), POOL_MANAGER, amount);
        IPoolManager(POOL_MANAGER).settle();
    }

    function validatePoolTokens(PoolKey memory poolKey, address tokenIn, address tokenOut) internal pure {
        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);
        require(
            (currency0 == tokenIn && currency1 == tokenOut) || (currency0 == tokenOut && currency1 == tokenIn),
            InconsistentTokens()
        );
        require(currency0 != address(0) && currency1 != address(0), InconsistentTokens());
    }
}
