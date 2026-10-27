// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {IVeloraLeverageBundlesV1} from "../src/leverage/interfaces/IVeloraLeverageBundlesV1.sol";
import {IAugustusV6} from "../src/leverage/interfaces/IAugustusV6.sol";
import {VeloraLeverageBundlesV1} from "../src/leverage/VeloraLeverageBundlesV1.sol";
import {AugustusMock} from "./helpers/AugustusMock.sol";
import {IERC20} from "../lib/vault-v2/src/interfaces/IERC20.sol";

contract VeloraLeverageBundlesV1Test is LeverageTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    VeloraLeverageBundlesV1 internal bundle;
    AugustusMock internal augustus;

    function setUp() public {
        setUpLeverageMarketOnly(false);
        augustus = new AugustusMock();
        bundle = new VeloraLeverageBundlesV1(address(morpho), address(augustus));
    }

    function testFuzzOpen(uint256 equity, uint256 leverage) public {
        equity = bound(equity, 1e6, 1e24);
        leverage = bound(leverage, 1.1e18, 4e18);
        uint256 collateralToBuy = equity.mulDivDown(leverage - 1e18, 1e18);
        uint256 spentAmount = collateralToBuy.mulDivUp(1003, 1000);
        uint256 maxBorrowAssets = spentAmount;
        fundUser(address(bundle), equity);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, equity, leverage, maxBorrowAssets, swapData, block.timestamp);

        Position memory position = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debt = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        assertEq(position.collateral, equity.mulDivDown(leverage, 1e18));
        assertEq(debt, spentAmount);
        assertNoResiduals();
    }

    function testDelever() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, equity, 2e18, maxBorrowAssets, openSwapData, block.timestamp);

        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtBefore =
            uint256(beforePosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 repayAssets = debtBefore / 2;
        uint256 spentAmount = repayAssets.mulDivUp(1003, 1000);
        uint256 maxCollateralIn = spentAmount + 1e18;
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), maxCollateralIn, repayAssets);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Delever(marketParams, repayAssets, maxCollateralIn, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        Market memory marketAfter = morpho.market(marketParams.id());
        assertEq(market.totalBorrowAssets - marketAfter.totalBorrowAssets, repayAssets);
        assertEq(beforePosition.collateral - afterPosition.collateral, spentAmount);
        assertLt(spentAmount, maxCollateralIn);
        assertNoResiduals();
    }

    function testCloseAfterOneYearOfInterest() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        uint256 timestamp = vm.getBlockTimestamp();
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, equity, 2e18, maxBorrowAssets, openSwapData, timestamp);

        vm.warp(timestamp + 365 days);
        morpho.accrueInterest(marketParams);
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtAssets =
            uint256(beforePosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 loanBalanceBeforeClose = loanToken.balanceOf(user);
        uint256 collateralBalanceBeforeClose = collateralToken.balanceOf(user);
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), beforePosition.collateral, debtAssets);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, beforePosition.collateral, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        uint256 expectedSpent = debtAssets.mulDivUp(1003, 1000);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertEq(loanToken.balanceOf(user), loanBalanceBeforeClose);
        assertEq(
            collateralToken.balanceOf(user) - collateralBalanceBeforeClose, beforePosition.collateral - expectedSpent
        );
        assertNoResiduals();
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
        bundle.veloraLeverageBundlesV1Close(marketParams, 0, "", block.timestamp);

        assertEq(collateralToken.balanceOf(user), collateral);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        assertNoResiduals();
    }

    function testCloseNeedsOnlyMarketLiquidity() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, equity, 2e18, maxBorrowAssets, openSwapData, block.timestamp);

        Position memory position = morpho.position(marketParams.id(), user);
        deal(address(collateralToken), address(morpho), position.collateral);
        morpho.accrueInterest(marketParams);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtAssets =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), position.collateral, debtAssets);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, position.collateral, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.collateral, 0);
        assertEq(afterPosition.borrowShares, 0);
        assertNoResiduals();
    }

    function testRejectsExpiredDeadlineOnEachEntrypoint() public {
        vm.expectRevert(IVeloraLeverageBundlesV1.DeadlinePassed.selector);
        bundle.veloraLeverageBundlesV1Open(marketParams, 1e18, 2e18, 2e18, "", 0);

        vm.expectRevert(IVeloraLeverageBundlesV1.DeadlinePassed.selector);
        bundle.veloraLeverageBundlesV1Delever(marketParams, 1e18, 1e18, "", 0);

        vm.expectRevert(IVeloraLeverageBundlesV1.DeadlinePassed.selector);
        bundle.veloraLeverageBundlesV1Close(marketParams, 1e18, "", 0);
        assertNoResiduals();
    }

    function testRejectsUnauthorizedSupplyCollateralCallback() public {
        vm.expectRevert(IVeloraLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoSupplyCollateral(0, "");
        assertNoResiduals();
    }

    function testRejectsUnauthorizedRepayCallback() public {
        vm.expectRevert(IVeloraLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoRepay(0, "");
        assertNoResiduals();
    }

    function testOpenRejectsIncompleteFill() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, 1);

        vm.expectRevert(IVeloraLeverageBundlesV1.IncompleteFill.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, equity, 2e18, maxBorrowAssets, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testBubblesAugustusRevert() public {
        uint256 equity = 10e18;
        uint256 amountOut = equity;
        uint256 maxBorrowAssets = amountOut.mulDivUp(1003, 1000) - 1;
        fundUser(address(bundle), equity);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, amountOut);

        vm.expectRevert();
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, equity, 2e18, maxBorrowAssets, swapData, block.timestamp);
        assertNoResiduals();
    }

    function buildSwapData(address tokenIn, address tokenOut, uint256 maxIn, uint256 amountOut)
        internal
        returns (bytes memory)
    {
        deal(tokenOut, address(augustus), amountOut);
        return abi.encodeCall(
            IAugustusV6.swapExactAmountOut,
            (
                address(0),
                IAugustusV6.GenericData({
                    srcToken: IERC20(tokenIn),
                    destToken: IERC20(tokenOut),
                    fromAmount: maxIn,
                    toAmount: amountOut,
                    quotedAmount: amountOut,
                    metadata: bytes32(0),
                    beneficiary: payable(address(bundle))
                }),
                0,
                bytes(""),
                bytes("")
            )
        );
    }

    function assertNoResiduals() internal view {
        closeAllTokenBalances(address(bundle));
        assertEq(loanToken.allowance(address(bundle), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(bundle), address(augustus)), 0);
    }
}
