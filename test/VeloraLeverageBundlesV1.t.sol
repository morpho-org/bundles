// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {IVeloraLeverageBundlesV1} from "../src/leverage/interfaces/IVeloraLeverageBundlesV1.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {BytesLib} from "../src/libraries/BytesLib.sol";
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

    function testAugustusExactOutputSelectors() public pure {
        assertTrue(IAugustusV6.swapExactAmountOut.selector == bytes4(0x7f457675));
        assertTrue(IAugustusV6.swapExactAmountOutOnUniswapV2.selector == bytes4(0xa76f4eb6));
        assertTrue(IAugustusV6.swapExactAmountOutOnUniswapV3.selector == bytes4(0x5e94e28d));
    }

    function testFuzzOpen(uint256 equity, uint256 collateralToBuy, uint256 borrowBuffer) public {
        equity = bound(equity, 1e6, 1e24);
        collateralToBuy = bound(collateralToBuy, 1, 3 * equity);
        borrowBuffer = bound(borrowBuffer, 0, equity / 10);
        uint256 spentAmount = collateralToBuy.mulDivUp(1003, 1000);
        uint256 maxBorrowAssets = spentAmount + borrowBuffer;
        fundUser(address(bundle), equity);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, collateralToBuy, maxBorrowAssets, swapData, type(uint256).max, block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debt = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        assertEq(position.collateral, equity + collateralToBuy);
        assertEq(debt, spentAmount);
        assertNoResiduals();
    }

    function testOpenEnforcesMaxLtv() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.expectRevert(IVeloraLeverageBundlesV1.LtvExceeded.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, swapData, 0.5e18, block.timestamp
        );
        assertNoResiduals();

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, swapData, 0.51e18, block.timestamp
        );
        assertEq(morpho.position(marketParams.id(), user).collateral, 2 * equity);
        assertNoResiduals();
    }

    function testOpenRejectsZeroCollateralToBuy() public {
        vm.expectRevert(IVeloraLeverageBundlesV1.ZeroCollateralToBuy.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(marketParams, 1e18, 0, 1e18, "", type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testRejectsDisallowedSelectorOnOpen() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);

        vm.expectRevert(IVeloraLeverageBundlesV1.InvalidSelector.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, hex"e3ead59e", type(uint256).max, block.timestamp
        );
        assertNoResiduals();
    }

    function testRejectsDisallowedSelectorOnDeleverAndClose() public {
        uint256 debt = openPosition();
        Position memory position = morpho.position(marketParams.id(), user);
        uint256 repayAssets = debt / 2;
        bytes memory invalidSwapData = hex"e3ead59e";

        vm.expectRevert(IVeloraLeverageBundlesV1.InvalidSelector.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Delever(
            marketParams, repayAssets, position.collateral / 2, invalidSwapData, type(uint256).max, block.timestamp
        );
        assertNoResiduals();

        bytes memory closeSwapData = buildCloseSwapData(0, position.collateral, debt, debt);
        assembly ("memory-safe") {
            mstore(add(closeSwapData, 0x20), 0xe3ead59e00000000000000000000000000000000000000000000000000000000)
        }
        vm.expectRevert(IVeloraLeverageBundlesV1.InvalidSelector.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, position.collateral, closeSwapData, block.timestamp);
        assertNoResiduals();
    }

    function testRejectsShortSwapData() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);

        vm.expectRevert(IVeloraLeverageBundlesV1.InvalidSelector.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, "", type(uint256).max, block.timestamp
        );
        assertNoResiduals();
    }

    function testRejectsReentrantOpenFromAugustus() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);
        bytes memory reentryData = abi.encodeCall(
            IVeloraLeverageBundlesV1.veloraLeverageBundlesV1Open,
            (marketParams, equity, equity, maxBorrowAssets, bytes(""), type(uint256).max, vm.getBlockTimestamp())
        );
        augustus.setReentry(address(bundle), reentryData);

        vm.expectRevert(IVeloraLeverageBundlesV1.Reentrancy.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, swapData, type(uint256).max, vm.getBlockTimestamp()
        );
        assertNoResiduals();
    }

    function testDelever() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, openSwapData, type(uint256).max, block.timestamp
        );

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
        bundle.veloraLeverageBundlesV1Delever(
            marketParams, repayAssets, maxCollateralIn, swapData, type(uint256).max, block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        Market memory marketAfter = morpho.market(marketParams.id());
        assertEq(market.totalBorrowAssets - marketAfter.totalBorrowAssets, repayAssets);
        assertEq(beforePosition.collateral - afterPosition.collateral, spentAmount);
        assertLt(spentAmount, maxCollateralIn);
        assertNoResiduals();
    }

    function testDeleverEnforcesMaxLtv() public {
        uint256 debt = openPosition();
        uint256 repayAssets = debt / 2;
        uint256 maxCollateralIn = repayAssets.mulDivUp(1003, 1000) + 1e18;
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), maxCollateralIn, repayAssets);

        vm.expectRevert(IVeloraLeverageBundlesV1.LtvExceeded.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Delever(
            marketParams, repayAssets, maxCollateralIn, swapData, 0.1e18, block.timestamp
        );
        assertNoResiduals();
    }

    function testCloseAfterOneYearOfInterest() public {
        uint256 quotedDebt = openPosition();
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        bytes memory swapData = buildCloseSwapData(0, beforePosition.collateral, quotedDebt + 1, quotedDebt);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 debtAssets = MorphoBalancesLib.expectedBorrowAssets(morpho, marketParams, user);
        assertGt(debtAssets, quotedDebt);
        augustus.setOutputReduction(1);
        uint256 loanBalanceBeforeClose = loanToken.balanceOf(user);
        uint256 collateralBalanceBeforeClose = collateralToken.balanceOf(user);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, beforePosition.collateral, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        uint256 expectedSpent = (debtAssets + 1).mulDivUp(1003, 1000);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertEq(loanToken.balanceOf(user), loanBalanceBeforeClose);
        assertEq(augustus.lastToAmount(), debtAssets + 1);
        assertEq(augustus.lastFromAmount(), beforePosition.collateral);
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

    function testFuzzCloseResizesDifferentLayouts(
        uint256 quotedOutput,
        uint256 elapsed,
        uint8 layout,
        bool payoutRounding
    ) public {
        uint256 initialDebt = openPosition();
        quotedOutput = bound(quotedOutput, initialDebt / 2, initialDebt * 2);
        elapsed = bound(elapsed, 0, 365 days);
        layout = uint8(bound(layout, 0, 2));
        uint256 quotedInput = quotedOutput.mulDivUp(1003, 1000);
        uint256 quotedLimit = quotedInput + quotedInput / 10;
        bytes memory swapData = buildCloseSwapData(layout, quotedLimit, quotedOutput, quotedInput);

        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 debt = MorphoBalancesLib.expectedBorrowAssets(morpho, marketParams, user);
        uint256 collateral = morpho.position(marketParams.id(), user).collateral;
        uint256 newOutput = debt + 1;
        uint256 newLimit = quotedLimit.mulDivDown(newOutput, quotedOutput).min(collateral);
        uint256 newQuote = quotedInput.mulDivDown(newOutput, quotedOutput);
        bytes memory expectedData = buildCloseSwapData(layout, newLimit, newOutput, newQuote);
        uint256 loanBalanceBefore = loanToken.balanceOf(user);
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user);
        augustus.setOutputReduction(payoutRounding ? 1 : 0);

        // Checks that the selector, tokens, recipient and route bytes survive resizing unchanged.
        vm.expectCall(address(augustus), expectedData);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, collateral, swapData, block.timestamp);

        assertEq(augustus.lastFromAmount(), newLimit);
        assertEq(augustus.lastToAmount(), newOutput);
        assertEq(augustus.lastQuotedAmount(), newQuote);
        assertEq(morpho.position(marketParams.id(), user).borrowShares, 0);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        assertEq(loanToken.balanceOf(user) - loanBalanceBefore, payoutRounding ? 0 : 1);
        assertEq(collateralToken.balanceOf(user) - collateralBalanceBefore, collateral - newOutput.mulDivUp(1003, 1000));
        assertNoResiduals();
    }

    function testCloseRejectsAccruedDebtAboveCollateralCap() public {
        uint256 initialDebt = openPosition();
        uint256 collateral = morpho.position(marketParams.id(), user).collateral;
        bytes memory swapData = buildCloseSwapData(0, collateral, initialDebt + 1, initialDebt);
        uint256 maxCollateralIn = (initialDebt + 1).mulDivUp(1003, 1000);
        uint256 borrowShares = morpho.position(marketParams.id(), user).borrowShares;
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.expectRevert(bytes("maximum input exceeded"));
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, maxCollateralIn, swapData, block.timestamp);

        assertEq(morpho.position(marketParams.id(), user).borrowShares, borrowShares);
        assertEq(morpho.position(marketParams.id(), user).collateral, collateral);
        assertNoResiduals();
    }

    function testCloseRejectsZeroQuotedOutput() public {
        openPosition();
        bytes memory swapData = buildCloseSwapData(0, 20e18, 0, 0);
        vm.expectRevert(IVeloraLeverageBundlesV1.ZeroSwapAmount.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, 20e18, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testFuzzCloseRejectsShortCalldata(uint8 length) public {
        openPosition();
        bytes memory swapData = new bytes(bound(length, 0, 31));
        vm.expectRevert(IVeloraLeverageBundlesV1.InvalidSelector.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, 20e18, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testCloseRejectsTruncatedAllowedSelector() public {
        openPosition();
        bytes memory swapData = abi.encodePacked(IAugustusV6.swapExactAmountOut.selector, new bytes(159));
        vm.expectRevert(BytesLib.InvalidOffset.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, 20e18, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testCloseRejectsIncompleteFill() public {
        uint256 debt = openPosition();
        bytes memory swapData = buildCloseSwapData(0, 20e18, debt, debt);
        augustus.setOutputReduction(2);
        vm.expectRevert(IVeloraLeverageBundlesV1.IncompleteFill.selector);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, 20e18, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testCloseUsesFullPrecisionScaling() public {
        uint256 debt = openPosition();
        bytes memory swapData = buildCloseSwapData(0, type(uint256).max, 2 * (debt + 1), type(uint256).max);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, 20e18, swapData, block.timestamp);
        assertEq(augustus.lastFromAmount(), 20e18);
        assertEq(augustus.lastQuotedAmount(), type(uint256).max / 2);
        assertNoResiduals();
    }

    function testCloseNeedsOnlyMarketLiquidity() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, openSwapData, type(uint256).max, block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        deal(address(collateralToken), address(morpho), position.collateral);
        morpho.accrueInterest(marketParams);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtAssets =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), position.collateral, debtAssets + 1);

        vm.prank(user);
        bundle.veloraLeverageBundlesV1Close(marketParams, position.collateral, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.collateral, 0);
        assertEq(afterPosition.borrowShares, 0);
        assertNoResiduals();
    }

    function testRejectsExpiredDeadlineOnEachEntrypoint() public {
        vm.expectRevert(IVeloraLeverageBundlesV1.DeadlinePassed.selector);
        bundle.veloraLeverageBundlesV1Open(marketParams, 1e18, 1e18, 2e18, "", type(uint256).max, 0);

        vm.expectRevert(IVeloraLeverageBundlesV1.DeadlinePassed.selector);
        bundle.veloraLeverageBundlesV1Delever(marketParams, 1e18, 1e18, "", type(uint256).max, 0);

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
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, maxBorrowAssets, swapData, type(uint256).max, block.timestamp
        );
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
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, amountOut, maxBorrowAssets, swapData, type(uint256).max, block.timestamp
        );
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

    function openPosition() internal returns (uint256 debt) {
        uint256 equity = 10e18;
        debt = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), debt, equity);
        vm.prank(user);
        bundle.veloraLeverageBundlesV1Open(
            marketParams, equity, equity, debt, swapData, type(uint256).max, vm.getBlockTimestamp()
        );

        // Use 50% utilization so the IRM accrues meaningful interest between quoting and closing.
        vm.prank(supplier);
        morpho.withdraw(marketParams, LIQUIDITY - 2 * debt, 0, supplier, supplier);
        deal(address(loanToken), address(augustus), LIQUIDITY);
    }

    function buildCloseSwapData(uint8 layout, uint256 maxIn, uint256 amountOut, uint256 quotedAmount)
        internal
        view
        returns (bytes memory data)
    {
        if (layout == 0) {
            data = abi.encodeCall(
                IAugustusV6.swapExactAmountOut,
                (
                    address(123),
                    IAugustusV6.GenericData({
                        srcToken: IERC20(address(collateralToken)),
                        destToken: IERC20(address(loanToken)),
                        fromAmount: maxIn,
                        toAmount: amountOut,
                        quotedAmount: quotedAmount,
                        metadata: bytes32(uint256(456)),
                        beneficiary: payable(address(bundle))
                    }),
                    789,
                    hex"aabbcc",
                    hex"ddeeff"
                )
            );
        } else {
            IAugustusV6.UniswapData memory uniData = IAugustusV6.UniswapData({
                srcToken: IERC20(address(collateralToken)),
                destToken: IERC20(address(loanToken)),
                fromAmount: maxIn,
                toAmount: amountOut,
                quotedAmount: quotedAmount,
                metadata: bytes32(uint256(456)),
                beneficiary: payable(address(bundle)),
                pools: hex"aabbccddeeff"
            });
            if (layout == 1) {
                data = abi.encodeCall(AugustusMock.swapExactAmountOutOnUniswapV2, (uniData, 789, hex"aabbcc"));
            } else {
                data = abi.encodeCall(AugustusMock.swapExactAmountOutOnUniswapV3, (uniData, 789, hex"aabbcc"));
            }
        }
    }

    function assertNoResiduals() internal view {
        closeAllTokenBalances(address(bundle));
        assertEq(loanToken.allowance(address(bundle), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(bundle), address(augustus)), 0);
    }
}
