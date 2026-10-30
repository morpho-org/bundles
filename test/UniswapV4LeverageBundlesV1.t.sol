// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {SafeCast} from "../lib/v4-core/src/libraries/SafeCast.sol";
import {IBlueLeverageBase} from "../src/leverage/interfaces/IBlueLeverageBase.sol";
import {IUniswapV4LeverageBundlesV1} from "../src/leverage/interfaces/IUniswapV4LeverageBundlesV1.sol";
import {UniswapV4LeverageBundlesV1} from "../src/leverage/UniswapV4LeverageBundlesV1.sol";

contract UniswapV4LeverageBundlesV1Test is LeverageTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    UniswapV4LeverageBundlesV1 internal bundle;

    function setUp() public {
        if (tokenType() == 2 || tokenType() == 4) {
            // v4-core's PoolModifyLiquidityTest requires bool-returning transferFrom.
            vm.skip(true);
        }
        setUpLeverage(false);
        bundle = new UniswapV4LeverageBundlesV1(address(morpho), address(poolManager));
    }

    function testFuzzOpen(uint256 equity, uint256 leverage) public {
        equity = bound(equity, 1e6, 1e24);
        leverage = bound(leverage, 1.1e18, 4e18);
        fundUser(address(bundle), equity);

        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(
            marketParams, poolKey, equity, leverage, type(uint256).max, block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertGt(position.borrowShares, 0);
        assertEq(position.collateral, equity + equity * (leverage - 1e18) / 1e18);
        closeAllTokenBalances(address(bundle));
    }

    function testOpenWhenLoanTokenIsCurrency1() public {
        setUpLeverage(true);
        bundle = new UniswapV4LeverageBundlesV1(address(morpho), address(poolManager));
        uint256 equity = 10e18;
        fundUser(address(bundle), equity);

        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, type(uint256).max, block.timestamp);

        assertGt(morpho.position(marketParams.id(), user).borrowShares, 0);
        closeAllTokenBalances(address(bundle));
    }

    function testDelever() public {
        uint256 equity = 10e18;
        fundUser(address(bundle), equity);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, type(uint256).max, block.timestamp);

        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtBefore =
            uint256(beforePosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 maxCollateralIn = debtBefore;

        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Delever(
            marketParams, poolKey, debtBefore / 2, maxCollateralIn, block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        Market memory marketAfter = morpho.market(marketParams.id());
        assertLt(afterPosition.borrowShares, beforePosition.borrowShares);
        assertLt(afterPosition.collateral, beforePosition.collateral);
        assertEq(market.totalBorrowAssets - marketAfter.totalBorrowAssets, debtBefore / 2);
        assertLe(beforePosition.collateral - afterPosition.collateral, maxCollateralIn);
        closeAllTokenBalances(address(bundle));
    }

    function testCloseAccruesInterest() public {
        uint256 equity = 10e18;
        uint256 timestamp = vm.getBlockTimestamp();
        fundUser(address(bundle), equity);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, type(uint256).max, timestamp);

        uint256 collateralBefore = morpho.position(marketParams.id(), user).collateral;
        vm.warp(timestamp + 365 days);

        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Close(marketParams, poolKey, collateralBefore, block.timestamp);

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.borrowShares, 0);
        assertEq(position.collateral, 0);
        assertGt(collateralToken.balanceOf(user), 0);
        closeAllTokenBalances(address(bundle));
    }

    function testCloseWithoutDebtReturnsAllCollateral() public {
        uint256 collateral = 5e18;
        deal(address(collateralToken), user, collateral);
        vm.startPrank(user);
        safeApprove(collateralToken, address(morpho), collateral);
        morpho.supplyCollateral(marketParams, collateral, user, "");
        morpho.setAuthorization(address(bundle), true);
        vm.stopPrank();

        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Close(marketParams, poolKey, 0, block.timestamp);

        assertEq(collateralToken.balanceOf(user), collateral);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        closeAllTokenBalances(address(bundle));
    }

    function testRejectsInvalidLeverage() public {
        vm.expectRevert(IBlueLeverageBase.InvalidLeverage.selector);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, 1e18, 1e18, type(uint256).max, block.timestamp);
    }

    function testOpenRequiresBlueAuthorization() public {
        uint256 equity = 10e18;
        deal(address(collateralToken), user, equity);
        vm.prank(user);
        safeApprove(collateralToken, address(bundle), equity);

        vm.expectRevert();
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, type(uint256).max, block.timestamp);
    }

    function testRejectsInconsistentPoolTokens() public {
        vm.expectRevert(IUniswapV4LeverageBundlesV1.InconsistentTokens.selector);
        bundle.uniswapV4LeverageBundlesV1Delever(
            marketParams, loanIntermediatePoolKey, 1e18, type(uint256).max, block.timestamp
        );
    }

    function testRejectsExpiredDeadline() public {
        vm.expectRevert(IBlueLeverageBase.DeadlinePassed.selector);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, 1e18, 2e18, 1e18, 0);
    }

    function testRejectsUnauthorizedCallback() public {
        vm.expectRevert(IBlueLeverageBase.UnauthorizedCallback.selector);
        bundle.unlockCallback("");
    }

    function testOpenRejectsOutputBeyondPoolCapacity() public {
        uint256 collateralAssets = 1e29;
        fundUser(address(bundle), collateralAssets);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(
            marketParams, poolKey, collateralAssets, 2e18, type(uint256).max, block.timestamp
        );
    }

    function testOpenRejectsInsufficientInputLimit() public {
        uint256 equity = 10e18;
        fundUser(address(bundle), equity);

        vm.expectRevert(IUniswapV4LeverageBundlesV1.SlippageExceeded.selector);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, 1, block.timestamp);
    }

    function testDeleverRejectsInsufficientInputLimit() public {
        uint256 equity = 10e18;
        fundUser(address(bundle), equity);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, type(uint256).max, block.timestamp);

        vm.expectRevert(IUniswapV4LeverageBundlesV1.SlippageExceeded.selector);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Delever(marketParams, poolKey, 1e18, 1, block.timestamp);
    }

    function testCloseRejectsInsufficientInputLimit() public {
        uint256 equity = 10e18;
        fundUser(address(bundle), equity);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Open(marketParams, poolKey, equity, 2e18, type(uint256).max, block.timestamp);

        vm.expectRevert(IUniswapV4LeverageBundlesV1.SlippageExceeded.selector);
        vm.prank(user);
        bundle.uniswapV4LeverageBundlesV1Close(marketParams, poolKey, 1, block.timestamp);
    }
}
