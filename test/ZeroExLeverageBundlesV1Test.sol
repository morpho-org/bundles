// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {IAllowanceHolder} from "../src/leverage/interfaces/IAllowanceHolder.sol";
import {ISettlerTakerSubmitted} from "../src/leverage/interfaces/ISettlerTakerSubmitted.sol";
import {IZeroExLeverageBundlesV1} from "../src/leverage/interfaces/IZeroExLeverageBundlesV1.sol";
import {ZeroExLeverageBundlesV1} from "../src/leverage/ZeroExLeverageBundlesV1.sol";
import {AllowanceHolderMock, SettlerMock, ZeroExDeployerMock} from "./helpers/ZeroExMocks.sol";

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
    bytes4 internal constant POSITIVE_SLIPPAGE_SELECTOR = 0x5f80abae;
    address internal constant ZERO_EX_FEE_RECIPIENT = address(0xfee);

    AllowanceHolderMock internal allowanceHolder;
    SettlerMock internal settler;
    ZeroExDeployerMock internal deployer;
    ZeroExLeverageBundlesV1 internal bundle;

    function setUp() public {
        setUpLeverageMarketOnly(false);
        allowanceHolder = new AllowanceHolderMock();
        settler = new SettlerMock(allowanceHolder);
        deployer = new ZeroExDeployerMock();
        deployer.setOwnerOf(2, address(settler));
        bundle = new ZeroExLeverageBundlesV1(address(morpho), address(allowanceHolder), address(deployer));
    }

    function testAllowanceHolderSelector() public pure {
        assertEq(IAllowanceHolder.exec.selector, bytes4(0x2213bc0b));
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
        assertEq(settler.lastSellAmount(), maxBorrowAssets);
        assertEq(settler.lastMinAmountOut(), collateralToBuy);
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

    function testDeleverExactOutputResuppliesUnusedCollateral() public {
        uint256 debtBefore = openPosition();
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory marketBefore = morpho.market(marketParams.id());
        uint256 repayAssets = debtBefore / 2;
        uint256 collateralToSpend = repayAssets;
        bytes memory swapData = buildSwapData(address(collateralToken), address(loanToken), 10e18, repayAssets);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, repayAssets, 10e18, swapData, type(uint256).max, block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        Market memory marketAfter = morpho.market(marketParams.id());
        assertApproxEqAbs(_debt(beforePosition, marketBefore) - _debt(afterPosition, marketAfter), repayAssets, 2);
        assertEq(beforePosition.collateral - afterPosition.collateral, collateralToSpend);
        assertEq(settler.lastMinAmountOut(), repayAssets);
        assertNoResiduals();
    }

    function testDeleverSurplusRepaysDebtThenReturnsWalletRemainder() public {
        uint256 debtBefore = openPosition();
        uint256 repayAssets = debtBefore / 2;
        uint256 remainingDebt = debtBefore - repayAssets;
        uint256 surplus = remainingDebt + 2e18;
        uint256 swapOutput = repayAssets + surplus;
        bytes memory swapData = buildSwapData(address(collateralToken), address(loanToken), 13e18, swapOutput);
        uint256 loanBalanceBefore = loanToken.balanceOf(user);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, repayAssets, 13e18, swapData, type(uint256).max, block.timestamp
        );

        assertEq(morpho.position(marketParams.id(), user).borrowShares, 0);
        assertApproxEqAbs(loanToken.balanceOf(user) - loanBalanceBefore, surplus - remainingDebt, 2);
        assertEq(settler.lastMinAmountOut(), swapOutput);
        assertNoResiduals();
    }

    function testDeleverEnforcesMaxLtv() public {
        uint256 debt = openPosition();
        uint256 repayAssets = debt / 2;
        bytes memory swapData = buildSwapData(address(collateralToken), address(loanToken), 10e18, repayAssets);

        vm.expectRevert(IZeroExLeverageBundlesV1.LtvExceeded.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(marketParams, repayAssets, 10e18, swapData, 0.1e18, block.timestamp);
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
        assertEq(settler.lastSellAmount(), beforePosition.collateral);
        assertEq(collateralToken.balanceOf(user) - collateralBalanceBefore, beforePosition.collateral - buyAmount);
        assertEq(collateralToken.balanceOf(ZERO_EX_FEE_RECIPIENT), 0);
        assertEq(settler.lastMinAmountOut(), buyAmount);
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
        assertEq(settler.lastSellAmount(), beforePosition.collateral);
        assertEq(settler.lastMinAmountOut(), minLoanOut);
        assertEq(loanToken.balanceOf(user) - loanBalanceBefore, equity);
        assertEq(collateralToken.balanceOf(user), collateralBalanceBefore);
        assertEq(loanToken.balanceOf(ZERO_EX_FEE_RECIPIENT), 0);
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

    function testPreviousSettlerIsAccepted() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        fundUser(address(bundle), collateralAssets);
        deployer.setOwnerOf(2, address(0x1234));
        deployer.setPrev(2, address(settler));
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams, collateralAssets, collateralToBuy, 12e18, swapData, type(uint256).max, block.timestamp
        );
        assertEq(morpho.position(marketParams.id(), user).collateral, collateralAssets + collateralToBuy);
        assertNoResiduals();
    }

    function testUnknownSettlerIsRejected() public {
        bytes[] memory actions = new bytes[](1);
        actions[0] = _transferFromAction(address(bundle), address(loanToken), 1e18);
        bytes memory settlerData =
            _settlerData(ISettlerTakerSubmitted.execute.selector, address(collateralToken), 1e18, actions);
        bytes memory swapData = _encodeExec(address(0x1234), address(loanToken), 1e18, address(0x1234), settlerData);

        vm.expectRevert(IZeroExLeverageBundlesV1.InvalidSettler.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 1e18, 1e18, swapData, type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testPausedDeployerRevertBubbles() public {
        deployer.setPaused(true);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 1e18, 1e18);

        vm.expectRevert(ZeroExDeployerMock.Paused.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 1e18, 1e18, swapData, type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testWrongAllowanceHolderExecSelectorIsRejected() public {
        bytes[] memory actions = new bytes[](1);
        actions[0] = _transferFromAction(address(bundle), address(loanToken), 1e18);
        bytes memory settlerData =
            _settlerData(ISettlerTakerSubmitted.execute.selector, address(collateralToken), 1, actions);
        bytes memory swapData = _encodeExecWithSelector(
            bytes4(0xdeadbeef), address(settler), address(loanToken), 1e18, address(settler), settlerData
        );

        vm.expectRevert(IZeroExLeverageBundlesV1.InvalidSwapData.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 1e18, 1e18, swapData, type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testOperatorMustEqualTarget() public {
        bytes[] memory actions = new bytes[](1);
        actions[0] = _transferFromAction(address(bundle), address(loanToken), 1e18);
        bytes memory settlerData =
            _settlerData(ISettlerTakerSubmitted.execute.selector, address(collateralToken), 1, actions);
        bytes memory swapData = _encodeExec(address(settler), address(loanToken), 1e18, address(0x1234), settlerData);

        vm.expectRevert(IZeroExLeverageBundlesV1.InvalidSwapData.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 1e18, 1e18, swapData, type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testExecTokenMustMatchSwapDirection() public {
        bytes memory swapData = buildSwapData(address(collateralToken), address(loanToken), 1e18, 1e18);

        vm.expectRevert(IZeroExLeverageBundlesV1.InvalidSwapData.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(marketParams, 0, 1e18, 1e18, swapData, type(uint256).max, block.timestamp);
        assertNoResiduals();
    }

    function testMinimumOutputViolationReverts() public {
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
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets + 1, 1e18);

        vm.expectRevert(AllowanceHolderMock.InsufficientTransientAllowance.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Open(
            marketParams, collateralAssets, 1e18, maxBorrowAssets, swapData, type(uint256).max, block.timestamp
        );
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
        bytes[] memory actions = new bytes[](2);
        actions[0] = _transferFromAction(address(bundle), tokenIn, quoteAmount);
        bool exactOutput = settler.exactOutput();
        address feeToken = exactOutput ? tokenIn : tokenOut;
        uint256 expectedAmount;
        if (exactOutput && settler.rateNumerator() != 0) {
            uint256 numerator = quotedMinOut * settler.rateDenominator();
            uint256 quotedSpend = numerator / settler.rateNumerator();
            if (numerator % settler.rateNumerator() != 0) ++quotedSpend;
            if (quotedSpend < quoteAmount) expectedAmount = quoteAmount - quotedSpend;
        } else if (!exactOutput) {
            expectedAmount = quoteAmount * settler.rateNumerator() / settler.rateDenominator();
        }
        actions[1] = _positiveSlippageAction(ZERO_EX_FEE_RECIPIENT, feeToken, expectedAmount, 1e6, 1e6);
        return _buildSwapDataWithActions(
            tokenIn, tokenOut, quoteAmount, quotedMinOut, actions, ISettlerTakerSubmitted.execute.selector
        );
    }

    function _buildSwapDataWithActions(
        address tokenIn,
        address tokenOut,
        uint256 apiAmount,
        uint256 quotedMinOut,
        bytes[] memory actions,
        bytes4 executeSelector
    ) internal returns (bytes memory) {
        deal(tokenOut, address(settler), 1e30);
        bytes memory settlerData = _settlerData(executeSelector, tokenOut, quotedMinOut, actions);
        return _encodeExec(address(settler), tokenIn, apiAmount, address(settler), settlerData);
    }

    function _settlerData(bytes4 selector, address tokenOut, uint256 quotedMinOut, bytes[] memory actions)
        internal
        view
        returns (bytes memory)
    {
        ISettlerTakerSubmitted.AllowedSlippage memory slippage =
            ISettlerTakerSubmitted.AllowedSlippage(address(bundle), tokenOut, quotedMinOut);
        return abi.encodeWithSelector(selector, slippage, actions, bytes32(0));
    }

    function _transferFromAction(address recipient, address token, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        Permit memory permit = Permit(TokenAmount(token, amount), 0, 0);
        return abi.encodeWithSelector(TRANSFER_FROM_SELECTOR, recipient, permit, bytes(""));
    }

    function _positiveSlippageAction(
        address recipient,
        address token,
        uint256 expectedAmount,
        uint256 surplusPpm,
        uint256 maxPpm
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(POSITIVE_SLIPPAGE_SELECTOR, recipient, token, expectedAmount, surplusPpm, maxPpm);
    }

    function _encodeExec(address operator, address token, uint256 amount, address target, bytes memory settlerData)
        internal
        pure
        returns (bytes memory)
    {
        return _encodeExecWithSelector(IAllowanceHolder.exec.selector, operator, token, amount, target, settlerData);
    }

    function _encodeExecWithSelector(
        bytes4 selector,
        address operator,
        address token,
        uint256 amount,
        address target,
        bytes memory settlerData
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, operator, token, amount, payable(target), settlerData);
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
