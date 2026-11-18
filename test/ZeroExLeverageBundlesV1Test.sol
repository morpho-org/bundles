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
import {PublicAllocatorMock} from "./helpers/PublicAllocatorMock.sol";
import {PublicAllocations} from "../src/blue/interfaces/IBlueBundlesV1.sol";
import {IMorphoBase} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {ErrorsLib as BlueErrorsLib} from "../lib/morpho-blue/src/libraries/ErrorsLib.sol";

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

    uint256 internal constant LLTV_LIQUID = 0.9e18;
    uint64 internal constant PENALTY = 0.01e18;

    PublicAllocatorMock internal publicAllocator;
    address internal vault;
    /// @dev Another market of the same loan token, used as the deallocation source of the reallocations.
    MarketParams internal liquidMarketParams;

    function setUp() public {
        setUpLeverageMarket();
        allowanceHolder = new AllowanceHolderMock();
        settler = new SettlerMock(allowanceHolder);
        publicAllocator = new PublicAllocatorMock(morpho);
        vault = makeAddr("vault");
        bundle = new ZeroExLeverageBundlesV1(address(morpho), address(allowanceHolder), address(publicAllocator));
        assertEq(bundle.PUBLIC_ALLOCATOR(), address(publicAllocator));
    }

    function testLeverExactOutput() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        uint256 maxBorrowAssets = 12e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
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

        vm.expectRevert(IZeroExLeverageBundlesV1.InsufficientOutput.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
            block.timestamp
        );
        assertNoResiduals();
    }

    function testLeverRejectsZeroCollateralToBuy() public {
        vm.expectRevert(IZeroExLeverageBundlesV1.ZeroCollateralToBuy.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams, 0, 0, 0, 1e18, "", type(uint256).max, noReallocations(), block.timestamp
        );
        assertNoResiduals();
    }

    function testLeverEnforcesMaxLtv() public {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, collateralToBuy);

        vm.expectRevert(IZeroExLeverageBundlesV1.LtvExceeded.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            12e18,
            swapData,
            0.49e18,
            noReallocations(),
            block.timestamp
        );
        assertNoResiduals();

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            12e18,
            swapData,
            0.51e18,
            noReallocations(),
            block.timestamp
        );
        assertNoResiduals();
    }

    function testLeverFromLoanAssetsExactOutput() public {
        uint256 loanAssets = 10e18;
        uint256 collateralToBuy = 20e18;
        uint256 maxBorrowAssets = 12e18;
        fundUserWithLoanAssets(loanAssets);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), loanAssets + maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            0,
            loanAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, collateralToBuy);
        assertEq(_debt(position, morpho.market(marketParams.id())), collateralToBuy - loanAssets);
        assertEq(loanToken.balanceOf(user), 0);
        assertNoResiduals();
    }

    function testLeverFromBothAssets() public {
        uint256 collateralAssets = 5e18;
        uint256 loanAssets = 5e18;
        uint256 collateralToBuy = 15e18;
        uint256 maxBorrowAssets = 12e18;
        fundUser(address(bundle), collateralAssets);
        fundUserWithLoanAssets(loanAssets);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), loanAssets + maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            loanAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, collateralAssets + collateralToBuy);
        assertEq(_debt(position, morpho.market(marketParams.id())), collateralToBuy - loanAssets);
        assertNoResiduals();
    }

    function testLeverSurplusAboveDebtIsSentToUser() public {
        uint256 loanAssets = 10e18;
        uint256 collateralToBuy = 5e18;
        uint256 maxBorrowAssets = 1e18;
        fundUserWithLoanAssets(loanAssets);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), loanAssets + maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            0,
            loanAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, collateralToBuy);
        assertEq(position.borrowShares, 0);
        assertEq(loanToken.balanceOf(user), loanAssets - collateralToBuy);
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

    function testDeleverRequiresMinRepayAssets() public {
        uint256 debt = openPosition();
        uint256 collateralToSell = 6e18;
        uint256 minRepayAssets = debt / 2;
        settler.setRate(minRepayAssets - 1, collateralToSell);
        bytes memory swapData = buildExactInSwapData(address(collateralToken), address(loanToken), collateralToSell, 1);

        vm.expectRevert(IZeroExLeverageBundlesV1.InsufficientOutput.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, collateralToSell, minRepayAssets, swapData, type(uint256).max, block.timestamp
        );
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

    function testCloseExactOutputReturnsBufferAsLoanAssets() public {
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
        bundle.zeroExLeverageBundlesV1Close(marketParams, beforePosition.collateral, 0, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertEq(loanToken.balanceOf(user) - loanBalanceBefore, buffer);
        assertEq(collateralToken.balanceOf(user) - collateralBalanceBefore, beforePosition.collateral - buyAmount);
        assertNoResiduals();
    }

    function testCloseExactInReturnsEquityAsLoanAssets() public {
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
        bundle.zeroExLeverageBundlesV1Close(marketParams, 0, minLoanOut, swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertEq(loanToken.balanceOf(user) - loanBalanceBefore, equity);
        assertEq(collateralToken.balanceOf(user), collateralBalanceBefore);
        assertNoResiduals();
    }

    function testCloseExactInRequiresMinLoanOut() public {
        openPosition();
        Position memory position = morpho.position(marketParams.id(), user);
        uint256 debt = _debt(position, morpho.market(marketParams.id()));
        uint256 minLoanOut = debt + 5e18;
        settler.setRate(minLoanOut - 1, position.collateral);
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), position.collateral, 1);

        vm.expectRevert(IZeroExLeverageBundlesV1.InsufficientOutput.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 0, minLoanOut, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testCloseExactInRequiresOutputToCoverDebt() public {
        openPosition();
        Position memory position = morpho.position(marketParams.id(), user);
        uint256 debt = _debt(position, morpho.market(marketParams.id()));
        settler.setRate(debt - 1, position.collateral);
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), position.collateral, 1);

        vm.expectRevert(IZeroExLeverageBundlesV1.InsufficientOutput.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 0, 1, swapData, block.timestamp);
        assertNoResiduals();
    }

    function testCloseRequiresExactlyOneBound() public {
        openPosition();

        vm.expectRevert(IZeroExLeverageBundlesV1.InconsistentCloseInput.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 0, 0, "", block.timestamp);

        vm.expectRevert(IZeroExLeverageBundlesV1.InconsistentCloseInput.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 1, 1, "", block.timestamp);
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
        bundle.zeroExLeverageBundlesV1Close(marketParams, 0, 1, "", block.timestamp);
        assertEq(collateralToken.balanceOf(user), collateral);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        assertNoResiduals();
    }

    function testSwapRevertBubbles() public {
        uint256 debt = openPosition();
        uint256 collateralToSell = 6e18;
        uint256 minRepayAssets = debt / 2;
        settler.setRate(1, 2);
        bytes memory swapData =
            buildExactInSwapData(address(collateralToken), address(loanToken), collateralToSell, minRepayAssets);

        vm.expectRevert(SettlerMock.MinimumOutputNotMet.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(
            marketParams, collateralToSell, minRepayAssets, swapData, type(uint256).max, block.timestamp
        );
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
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            1e18,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
            block.timestamp
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
            bundle.zeroExLeverageBundlesV1Lever,
            (
                marketParams,
                0,
                0,
                collateralToBuy,
                maxBorrowAssets,
                bytes(""),
                type(uint256).max,
                noReallocations(),
                block.timestamp
            )
        );
        settler.setReentry(address(bundle), reentryData);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            noReallocations(),
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
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams, 0, 0, 1, 1, emptySwapData, type(uint256).max, noReallocations(), expired
        );

        vm.expectRevert(IZeroExLeverageBundlesV1.DeadlinePassed.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Delever(marketParams, 1, 1, emptySwapData, type(uint256).max, expired);

        vm.expectRevert(IZeroExLeverageBundlesV1.DeadlinePassed.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Close(marketParams, 1, 0, emptySwapData, expired);

        assertNoResiduals();
    }

    function testCallbacksOnlyAcceptMorpho() public {
        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoSupplyCollateral(0, "");

        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoRepay(0, "");

        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoFlashLoan(0, "");
        assertNoResiduals();
    }

    function testRepayCallbackRejectsUnknownSelector() public {
        bytes memory callbackData = abi.encode(bytes4(0xdeadbeef), user, bytes(""));

        vm.expectRevert(IZeroExLeverageBundlesV1.UnauthorizedCallback.selector);
        vm.prank(address(morpho));
        bundle.onMorphoRepay(0, callbackData);
        assertNoResiduals();
    }

    /// PUBLIC ALLOCATOR ///

    function testLeverWithoutLiquidityReverts() public {
        setUpIlliquidMarket();
        fundUser(address(bundle), 10e18);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, 10e18);

        vm.expectRevert(bytes(BlueErrorsLib.INSUFFICIENT_LIQUIDITY));
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams, 10e18, 0, 10e18, 12e18, swapData, type(uint256).max, noReallocations(), block.timestamp
        );
    }

    function testLeverAllocatesFromIdleAndPaysPenaltyFromBorrow() public {
        setUpIlliquidMarket();
        _testLeverWithPenalty(idleReallocation(12e18, PENALTY));
    }

    function testLeverReallocatesFromMarketAndPaysPenaltyFromBorrow() public {
        setUpIlliquidMarket();
        _testLeverWithPenalty(marketReallocation(12e18, PENALTY));
    }

    function _testLeverWithPenalty(PublicAllocations[] memory reallocations) internal {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        uint256 maxBorrowAssets = 12e18;
        uint256 penaltyAssets = 0.12e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData = buildSwapData(
            address(loanToken), address(collateralToken), maxBorrowAssets - penaltyAssets, collateralToBuy
        );

        vm.expectCall(
            address(morpho),
            abi.encodeWithSelector(IMorphoBase.flashLoan.selector, address(loanToken), penaltyAssets),
            1
        );
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            reallocations,
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, collateralAssets + collateralToBuy);
        assertEq(_debt(position, morpho.market(marketParams.id())), collateralToBuy + penaltyAssets);
        assertEq(loanToken.balanceOf(vault), penaltyAssets);
        assertNoResiduals();
    }

    function testLeverFromLoanAssetsPaysPenaltyFromBorrow() public {
        setUpIlliquidMarket();
        uint256 loanAssets = 10e18;
        uint256 collateralToBuy = 20e18;
        uint256 maxBorrowAssets = 12e18;
        uint256 penaltyAssets = 0.12e18;
        fundUserWithLoanAssets(loanAssets);
        bytes memory swapData = buildSwapData(
            address(loanToken), address(collateralToken), loanAssets + maxBorrowAssets - penaltyAssets, collateralToBuy
        );

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            0,
            loanAssets,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            idleReallocation(12e18, PENALTY),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, collateralToBuy);
        assertEq(_debt(position, morpho.market(marketParams.id())), collateralToBuy - loanAssets + penaltyAssets);
        assertEq(loanToken.balanceOf(user), 0);
        assertEq(loanToken.balanceOf(vault), penaltyAssets);
        assertNoResiduals();
    }

    function testLeverWithZeroPenaltySkipsFlashLoan() public {
        setUpIlliquidMarket();
        publicAllocator.setPenalty(vault, 0);
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        uint256 maxBorrowAssets = 12e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData =
            buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, collateralToBuy);

        vm.expectCall(address(morpho), abi.encodeWithSelector(IMorphoBase.flashLoan.selector), 0);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            maxBorrowAssets,
            swapData,
            type(uint256).max,
            idleReallocation(12e18, 0),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(_debt(position, morpho.market(marketParams.id())), collateralToBuy);
        assertEq(loanToken.balanceOf(vault), 0);
        assertNoResiduals();
    }

    function testLeverSwapInputIsCappedNetOfPenalty() public {
        setUpIlliquidMarket();
        fundUser(address(bundle), 10e18);
        // The quote pulls the full maxBorrowAssets, which exceeds what is left after the penalty.
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, 10e18);

        vm.expectRevert();
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            10e18,
            0,
            10e18,
            12e18,
            swapData,
            type(uint256).max,
            idleReallocation(12e18, PENALTY),
            block.timestamp
        );
    }

    function testLeverRejectsReallocationOfAnotherLoanToken() public {
        setUpIlliquidMarket();
        fundUser(address(bundle), 10e18);
        PublicAllocations[] memory reallocations = idleReallocation(12e18, PENALTY);
        reallocations[0].marketParams.loanToken = address(collateralToken);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 11.88e18, 10e18);

        vm.expectRevert(IZeroExLeverageBundlesV1.InconsistentTokens.selector);
        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams, 10e18, 0, 10e18, 12e18, swapData, type(uint256).max, reallocations, block.timestamp
        );
    }

    /// HELPERS ///

    function noReallocations() internal pure returns (PublicAllocations[] memory) {
        return new PublicAllocations[](0);
    }

    /// @dev Empties the lever market, and gives the public allocator idle assets and a supply position in another
    /// market of the same loan token (which also keeps Blue able to flash loan the penalty).
    function setUpIlliquidMarket() internal {
        vm.prank(supplier);
        morpho.withdraw(marketParams, LIQUIDITY, 0, supplier, supplier);

        liquidMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV_LIQUID
        });
        vm.prank(owner);
        morpho.enableLltv(LLTV_LIQUID);
        morpho.createMarket(liquidMarketParams);

        deal(address(loanToken), address(publicAllocator), 200e18);
        vm.startPrank(address(publicAllocator));
        safeApprove(loanToken, address(morpho), type(uint256).max);
        morpho.supply(liquidMarketParams, 100e18, 0, address(publicAllocator), "");
        vm.stopPrank();
        publicAllocator.setPenalty(vault, PENALTY);
    }

    function idleReallocation(uint128 assets, uint64 penalty) internal view returns (PublicAllocations[] memory) {
        PublicAllocations[] memory reallocations = new PublicAllocations[](1);
        reallocations[0].vault = vault;
        reallocations[0].marketParams = marketParams;
        reallocations[0].fromIdle = true;
        reallocations[0].assets = assets;
        reallocations[0].penalty = penalty;
        return reallocations;
    }

    function marketReallocation(uint128 assets, uint64 penalty) internal view returns (PublicAllocations[] memory) {
        PublicAllocations[] memory reallocations = idleReallocation(assets, penalty);
        reallocations[0].fromIdle = false;
        reallocations[0].sourceMarketParams = liquidMarketParams;
        return reallocations;
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

    function fundUserWithLoanAssets(uint256 loanAssets) internal {
        deal(address(loanToken), user, loanAssets);
        vm.startPrank(user);
        safeApprove(loanToken, address(bundle), loanAssets);
        if (!morpho.isAuthorized(user, address(bundle))) morpho.setAuthorization(address(bundle), true);
        vm.stopPrank();
    }

    function openPosition() internal returns (uint256 debt) {
        uint256 collateralAssets = 10e18;
        uint256 collateralToBuy = 10e18;
        fundUser(address(bundle), collateralAssets);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), 12e18, collateralToBuy);

        vm.prank(user);
        bundle.zeroExLeverageBundlesV1Lever(
            marketParams,
            collateralAssets,
            0,
            collateralToBuy,
            12e18,
            swapData,
            type(uint256).max,
            noReallocations(),
            block.timestamp
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
