// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {IAllowanceHolder} from "./helpers/IAllowanceHolder.sol";
import {ISettlerTakerSubmitted} from "./helpers/ISettlerTakerSubmitted.sol";
import {IZeroExLeverageBundlesV1} from "../src/leverage/interfaces/IZeroExLeverageBundlesV1.sol";
import {ZeroExLeverageBundlesV1} from "../src/leverage/ZeroExLeverageBundlesV1.sol";
import {AllowanceHolderMock, SettlerMock} from "./helpers/ZeroExMocks.sol";

contract ZeroExLeverageBundlesV1Test is LeverageTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct Permit {
        TokenAmount permitted;
        uint256 nonce;
        uint256 deadline;
    }

    bytes4 internal constant TRANSFER_FROM_SELECTOR =
        bytes4(keccak256("TRANSFER_FROM(address,((address,uint256),uint256,uint256),bytes)"));

    AllowanceHolderMock internal allowanceHolder;
    SettlerMock internal settler;
    ZeroExLeverageBundlesV1 internal bundle;

    function setUp() public {
        setUpLeverageMarket();
        allowanceHolder = new AllowanceHolderMock();
        settler = new SettlerMock(allowanceHolder);
        bundle = new ZeroExLeverageBundlesV1(address(morpho), address(allowanceHolder));
    }

    function testOpenExactOutput() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        uint256 maxBorrowAssets = 12e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams,
            collateralAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, collateralAssets + collateralToBuy);
        assertEq(_debt(position, morpho.market(marketParams.id())), collateralToBuy);
        assertNoResiduals();
    }

    function testOutputSentElsewhereReverts() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        uint256 maxBorrowAssets = 12e18;
        fundUser(address(bundle), collateralAssets);
        settler.setExactOutput(true);
        bytes memory swapData = _buildSwapDataTo(
            address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy, address(0xbeef)
        );

        vm.expectRevert(IZeroExLeverageBundlesV1.IncompleteFill.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams,
            collateralAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            block.timestamp
        );
        assertNoResiduals();
    }

    function testOpenRejectsZeroCollateralToBuy() public {
        vm.expectRevert(IZeroExLeverageBundlesV1.ZeroCollateralToBuy.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 0, 1e18, "", type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testOpenEnforcesMaxLtv() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, collateralToBuy);

        vm.expectRevert(IZeroExLeverageBundlesV1.LtvExceeded.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams, collateralAssets, collateralToBuy, 12e18, swapData, 0.49e18, block.timestamp
        );
        assertNoResiduals();

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams, collateralAssets, collateralToBuy, 12e18, swapData, 0.51e18, block.timestamp
        );
        assertNoResiduals();
    }

    function testDeleverSellsCollateral() public {
        uint256 debtBefore = openPosition();
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        uint256 collateralToSell = 6e18;
        uint256 minRepayAssets = debtBefore / 2;
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), collateralToSell, minRepayAssets);
        uint256 loanBalanceBefore = loanToken.balanceOf(user);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, collateralToSell, minRepayAssets, swapData, type(uint256).max, block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        uint256 debtAfter = _debt(afterPosition, morpho.market(marketParams.id()));
        assertGe(debtBefore - debtAfter, minRepayAssets);
        assertEq(beforePosition.collateral - afterPosition.collateral, collateralToSell);
        assertEq(loanToken.balanceOf(user), loanBalanceBefore);
        assertNoResiduals();
    }

    function testDeleverSurplusRepaysDebtThenReturnsWalletRemainder() public {
        uint256 debtBefore = openPosition();
        uint256 minRepayAssets = debtBefore / 2;
        uint256 remainingDebt = debtBefore - minRepayAssets;
        uint256 surplus = remainingDebt + 2e18;
        uint256 collateralToSell = minRepayAssets + surplus;
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), collateralToSell, minRepayAssets);
        uint256 loanBalanceBefore = loanToken.balanceOf(user);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, collateralToSell, minRepayAssets, swapData, type(uint256).max, block.timestamp
        );

        assertEq(morpho.position(marketParams.id(), user).borrowShares, 0);
        assertApproxEqAbs(loanToken.balanceOf(user) - loanBalanceBefore, surplus - remainingDebt, 2);
        assertGt(collateralToSell, debtBefore);
        assertNoResiduals();
    }

    function testDeleverEnforcesMaxLtv() public {
        uint256 debt = openPosition();
        uint256 collateralToSell = debt / 2;
        uint256 minRepayAssets = debt / 2;
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), collateralToSell, minRepayAssets);

        vm.expectRevert(IZeroExLeverageBundlesV1.LtvExceeded.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, collateralToSell, minRepayAssets, swapData, 0.1e18, block.timestamp
        );
        assertNoResiduals();
    }

    function testCloseExactOutputReturnsBufferAsLoanTokens() public {
        openPosition();
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        uint256 debt = _debt(beforePosition, morpho.market(marketParams.id()));
        uint256 buffer = 1e18;
        uint256 buyAmount = debt + buffer;
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), beforePosition.collateral, buyAmount);
        uint256 loanBalanceBefore = loanToken.balanceOf(user);
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, beforePosition.collateral, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertEq(loanToken.balanceOf(user) - loanBalanceBefore, buffer);
        assertEq(collateralToken.balanceOf(user) - collateralBalanceBefore, beforePosition.collateral - buyAmount);
        assertNoResiduals();
    }

    function testCloseExactInReturnsEquity() public {
        openPosition();
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        uint256 debt = _debt(beforePosition, morpho.market(marketParams.id()));
        uint256 equity = 5e18;
        uint256 minLoanOut = debt + equity;
        settler.setRate(minLoanOut, beforePosition.collateral);
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), beforePosition.collateral, minLoanOut);
        uint256 loanBalanceBefore = loanToken.balanceOf(user);
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1CloseExactIn(marketParams, minLoanOut, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertEq(loanToken.balanceOf(user) - loanBalanceBefore, equity);
        assertEq(collateralToken.balanceOf(user), collateralBalanceBefore);
        assertNoResiduals();
    }

    function testCloseExactInRequiresOutputToCoverDebt() public {
        openPosition();
        Position memory position = morpho.position(marketParams.id(), user);
        uint256 debt = _debt(position, morpho.market(marketParams.id()));
        settler.setRate(debt - 1, position.collateral);
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), position.collateral, 1);

        vm.expectRevert(IZeroExLeverageBundlesV1.IncompleteFill.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1CloseExactIn(marketParams, 1, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testCloseWithoutDebtReturnsCollateral() public {
        uint256 collateral = 5e18;
        deal(address(collateralToken), user, collateral);
        vm.startPrank(user);
        safeApprove(collateralToken, address(morpho), collateral);
        morpho.setAuthorization(address(bundle), true);
        morpho.supplyCollateral(marketParams, collateral, user, "");
        vm.stopPrank();

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 0, "", block.timestamp);
        assertEq(collateralToken.balanceOf(user), collateral);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);

        vm.startPrank(user);
        safeApprove(collateralToken, address(morpho), collateral);
        morpho.supplyCollateral(marketParams, collateral, user, "");
        vm.stopPrank();

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1CloseExactIn(marketParams, 1e18, "", block.timestamp);
        assertEq(collateralToken.balanceOf(user), collateral);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        assertNoResiduals();
    }

    function testSwapRevertBubbles() public {
        openPosition();
        Position memory position = morpho.position(marketParams.id(), user);
        uint256 minLoanOut = _debt(position, morpho.market(marketParams.id())) + 1e18;
        settler.setRate(1, 2);
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), position.collateral, minLoanOut);

        vm.expectRevert(SettlerMock.MinimumOutputNotMet.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1CloseExactIn(marketParams, minLoanOut, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testAllowanceHolderCapsInput() public {
        uint256 maxBorrowAssets = 2e18;
        uint256 collateralAssets = 2e18;
        fundUser(address(bundle), collateralAssets);
        deal(address(loanToken), address(bundle), 1);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets + 1, 1e18);

        // The bundle approves only maxBorrowAssets, so the pull of maxBorrowAssets + 1 reverts in the token.
        vm.expectRevert();
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams, collateralAssets, 1e18, maxBorrowAssets, swapData, type(uint256).max, block.timestamp
        );
        deal(address(loanToken), address(bundle), 0);
        assertNoResiduals();
    }

    function testSettlerReentryIsBlocked() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        uint256 maxBorrowAssets = 12e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory reentryData = abi.encodeCall(
            bundle.zeroExLeverageBundlesV1Open,
            (marketParams, 0, collateralToBuy, maxBorrowAssets, bytes(""), type(uint256).max, block.timestamp)
        );
        settler.setReentry(address(bundle), reentryData);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams,
            collateralAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            block.timestamp
        );

        assertTrue(settler.reentryAttempted());
        assertFalse(settler.reentrySucceeded());
        assertEq(_revertSelector(settler.reentryReturnData()), IZeroExLeverageBundlesV1.Reentrancy.selector);
        assertNoResiduals();
    }

    function testAllEntrypointsRejectExpiredDeadline() public {
        uint256 futureTimestamp = vm.getBlockTimestamp() + 1 days;
        vm.warp(futureTimestamp);
        uint256 expired = futureTimestamp - 1;
        bytes memory emptySwapData = "";

        vm.expectRevert(IZeroExLeverageBundlesV1.DeadlinePassed.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 1, 1, emptySwapData, type(uint256).max, expired);

        vm.expectRevert(IZeroExLeverageBundlesV1.DeadlinePassed.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(marketParams, 1, 1, emptySwapData, type(uint256).max, expired);

        vm.expectRevert(IZeroExLeverageBundlesV1.DeadlinePassed.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 1, emptySwapData, expired);

        vm.expectRevert(IZeroExLeverageBundlesV1.DeadlinePassed.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1CloseExactIn(marketParams, 1, emptySwapData, expired);
        assertNoResiduals();
    }

    function testCallbacksOnlyAcceptMorpho() public {
        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoSupplyCollateral(0, "");

        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoRepay(0, "");
        assertNoResiduals();
    }

    function testCallbacksRejectUnknownSelector() public {
        bytes memory callbackData = abi.encode(bytes4(0xdeadbeef), user, bytes(""));

        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        vm.prank(address(morpho));
        bundle.onMorphoSupplyCollateral(0, callbackData);

        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        vm.prank(address(morpho));
        bundle.onMorphoRepay(0, callbackData);
        assertNoResiduals();
    }

    function buildSwapData(address tokenIn, address tokenOut, uint256 quoteAmount, uint256 quotedMinOut)
        internal
        returns (bytes memory)
    {
        settler.setExactOutput(true);
        return _buildSwapData(tokenIn, tokenOut, quoteAmount, quotedMinOut);
    }

    function buildExactInSwapData(address tokenIn, address tokenOut, uint256 sellAmount, uint256 quotedMinOut)
        internal
        returns (bytes memory)
    {
        settler.setExactOutput(false);
        return _buildSwapData(tokenIn, tokenOut, sellAmount, quotedMinOut);
    }

    function _buildSwapData(address tokenIn, address tokenOut, uint256 quoteAmount, uint256 quotedMinOut)
        internal
        returns (bytes memory)
    {
        return _buildSwapDataTo(tokenIn, tokenOut, quoteAmount, quotedMinOut, address(bundle));
    }

    function _buildSwapDataTo(
        address tokenIn,
        address tokenOut,
        uint256 quoteAmount,
        uint256 quotedMinOut,
        address recipient
    ) internal returns (bytes memory) {
        bytes[] memory actions = new bytes[](1);
        actions[0] = _transferFromAction(address(bundle), tokenIn, quoteAmount);
        deal(tokenOut, address(settler), 1e30);
        bytes memory settlerData = _settlerData(tokenOut, quotedMinOut, actions, recipient);
        return _encodeExec(address(settler), tokenIn, quoteAmount, address(settler), settlerData);
    }

    function _settlerData(address tokenOut, uint256 quotedMinOut, bytes[] memory actions, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        ISettlerTakerSubmitted.AllowedSlippage memory slippage =
            ISettlerTakerSubmitted.AllowedSlippage(recipient, tokenOut, quotedMinOut);
        return abi.encodeWithSelector(ISettlerTakerSubmitted.execute.selector, slippage, actions, bytes32(0));
    }

    function _transferFromAction(address recipient, address token, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        Permit memory permit = Permit(TokenAmount(token, amount), 0, 0);
        return abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, recipient, permit, bytes(""));
    }

    function _encodeExec(address operator, address token, uint256 amount, address target, bytes memory settlerData)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(
                IAllowanceHolder.exec.selector, operator, token, amount, payable(target), settlerData
            );
    }

    function openPosition() internal returns (uint256 debt) {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams, collateralAssets, collateralToBuy, 12e18, swapData, type(uint256).max, block.timestamp
        );
        Position memory position = morpho.position(marketParams.id(), user);
        debt = _debt(position, morpho.market(marketParams.id()));
    }

    function _debt(Position memory position, Market memory market) internal pure returns (uint256) {
        return uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
    }

    function _revertSelector(bytes memory returnData) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }

    function assertNoResiduals() internal view {
        closeAllTokenBalances(address(bundle));
        assertEq(loanToken.allowance(address(bundle), address(allowanceHolder)), 0);
        assertEq(collateralToken.allowance(address(bundle), address(allowanceHolder)), 0);
        assertEq(allowanceHolder.transientAllowance(address(settler), address(bundle), address(loanToken)), 0);
        assertEq(allowanceHolder.transientAllowance(address(settler), address(bundle), address(collateralToken)), 0);
    }
}
