// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {IBlueLeverageBase} from "../src/leverage/interfaces/IBlueLeverageBase.sol";
import {LeverageBundlesV1} from "../src/leverage/LeverageBundlesV1.sol";
import {UniversalRouterSwapAdapter} from "../src/leverage/adapters/UniversalRouterSwapAdapter.sol";
import {RouterParameters} from "../lib/universal-router/contracts/types/RouterParameters.sol";
import {Commands} from "../lib/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "../lib/universal-router/lib/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "../lib/universal-router/lib/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "../lib/universal-router/lib/v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "../lib/universal-router/lib/v4-periphery/src/libraries/PathKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";

contract LeverageBundlesV1Test is LeverageTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    LeverageBundlesV1 internal bundle;
    UniversalRouterSwapAdapter internal adapter;
    address internal universalRouter;

    function setUp() public {
        if (tokenType() == 2 || tokenType() == 4) {
            // v4-core's PoolModifyLiquidityTest requires bool-returning transferFrom.
            vm.skip(true);
        }
        setUpLeverageMarketOnly(false);
        setUpLeveragePool();
        universalRouter = _deployUniversalRouter();
        adapter = new UniversalRouterSwapAdapter(universalRouter);
        bundle = new LeverageBundlesV1(address(morpho));
    }

    function testFuzzOpen(uint256 equity, uint256 leverage) public {
        equity = bound(equity, 1e6, 1e24);
        leverage = bound(leverage, 1.1e18, 4e18);
        uint256 collateralToBuy = equity.mulDivDown(leverage - 1e18, 1e18);
        uint256 maxBorrowAssets = collateralToBuy.mulDivUp(101, 100) + 1;
        fundUser(address(bundle), equity);
        (bytes memory commands, bytes[] memory inputs) =
            buildSingleHopRoute(address(loanToken), address(collateralToken), collateralToBuy, maxBorrowAssets, poolKey);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams,
            equity,
            leverage,
            maxBorrowAssets,
            address(adapter),
            abi.encode(commands, inputs),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debt = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        assertEq(position.collateral, equity + collateralToBuy);
        assertLe(debt, maxBorrowAssets);
        assertNoResiduals();
    }

    function testMultiHopOpen() public {
        uint256 equity = 10e18;
        uint256 amountOut = equity;
        uint256 maxBorrowAssets = amountOut.mulDivUp(101, 100) + 1;
        fundUser(address(bundle), equity);
        (bytes memory commands, bytes[] memory inputs) = buildMultiHopRoute(amountOut, maxBorrowAssets);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams, equity, 2e18, maxBorrowAssets, address(adapter), abi.encode(commands, inputs), block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, 2 * equity);
        assertGt(position.borrowShares, 0);
        assertNoResiduals();
    }

    function testDelever() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(101, 100) + 1;
        fundUser(address(bundle), equity);
        (bytes memory openCommands, bytes[] memory openInputs) =
            buildSingleHopRoute(address(loanToken), address(collateralToken), equity, maxBorrowAssets, poolKey);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams,
            equity,
            2e18,
            maxBorrowAssets,
            address(adapter),
            abi.encode(openCommands, openInputs),
            block.timestamp
        );

        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtBefore =
            uint256(beforePosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 repayAssets = debtBefore / 2;
        uint256 maxCollateralIn = 2 * repayAssets;
        (bytes memory commands, bytes[] memory inputs) =
            buildSingleHopRoute(address(collateralToken), address(loanToken), repayAssets, maxCollateralIn, poolKey);

        vm.prank(user);
        bundle.leverageBundlesV1Delever(
            marketParams, repayAssets, maxCollateralIn, address(adapter), abi.encode(commands, inputs), block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        Market memory marketAfter = morpho.market(marketParams.id());
        assertEq(market.totalBorrowAssets - marketAfter.totalBorrowAssets, repayAssets);
        assertLe(beforePosition.collateral - afterPosition.collateral, maxCollateralIn);
        assertLt(afterPosition.borrowShares, beforePosition.borrowShares);
        assertLt(afterPosition.collateral, beforePosition.collateral);
        assertNoResiduals();
    }

    function testCloseAccruesInterest() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(101, 100) + 1;
        uint256 timestamp = vm.getBlockTimestamp();
        fundUser(address(bundle), equity);
        (bytes memory openCommands, bytes[] memory openInputs) =
            buildSingleHopRoute(address(loanToken), address(collateralToken), equity, maxBorrowAssets, poolKey);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams,
            equity,
            2e18,
            maxBorrowAssets,
            address(adapter),
            abi.encode(openCommands, openInputs),
            timestamp
        );

        vm.warp(timestamp + 365 days);
        morpho.accrueInterest(marketParams);
        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtAssets =
            uint256(beforePosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        (bytes memory commands, bytes[] memory inputs) = buildSingleHopRoute(
            address(collateralToken), address(loanToken), debtAssets, beforePosition.collateral, poolKey
        );

        vm.prank(user);
        bundle.leverageBundlesV1Close(
            marketParams, beforePosition.collateral, address(adapter), abi.encode(commands, inputs), block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertGt(collateralToken.balanceOf(user), 0);
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
        bundle.leverageBundlesV1Close(marketParams, 0, address(adapter), "", block.timestamp);

        assertEq(collateralToken.balanceOf(user), collateral);
        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        assertNoResiduals();
    }

    function testCloseNeedsOnlyMarketLiquidity() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(101, 100) + 1;
        fundUser(address(bundle), equity);
        (bytes memory openCommands, bytes[] memory openInputs) =
            buildSingleHopRoute(address(loanToken), address(collateralToken), equity, maxBorrowAssets, poolKey);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams,
            equity,
            2e18,
            maxBorrowAssets,
            address(adapter),
            abi.encode(openCommands, openInputs),
            block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        deal(address(collateralToken), address(morpho), position.collateral);
        morpho.accrueInterest(marketParams);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtAssets =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        (bytes memory commands, bytes[] memory inputs) =
            buildSingleHopRoute(address(collateralToken), address(loanToken), debtAssets, position.collateral, poolKey);

        vm.prank(user);
        bundle.leverageBundlesV1Close(
            marketParams, position.collateral, address(adapter), abi.encode(commands, inputs), block.timestamp
        );

        assertEq(morpho.position(marketParams.id(), user).collateral, 0);
        assertEq(morpho.position(marketParams.id(), user).borrowShares, 0);
        assertNoResiduals();
    }

    function testRejectsExpiredDeadline() public {
        vm.expectRevert(IBlueLeverageBase.DeadlinePassed.selector);
        bundle.leverageBundlesV1Open(marketParams, 1e18, 2e18, 2e18, address(adapter), "", 0);

        vm.expectRevert(IBlueLeverageBase.DeadlinePassed.selector);
        bundle.leverageBundlesV1Delever(marketParams, 1e18, 1e18, address(adapter), "", 0);

        vm.expectRevert(IBlueLeverageBase.DeadlinePassed.selector);
        bundle.leverageBundlesV1Close(marketParams, 1e18, address(adapter), "", 0);
        assertNoResiduals();
    }

    function testRejectsUnauthorizedSupplyCollateralCallback() public {
        vm.expectRevert(IBlueLeverageBase.UnauthorizedCallback.selector);
        bundle.onMorphoSupplyCollateral(0, "");
        assertNoResiduals();
    }

    function testRejectsUnauthorizedRepayCallback() public {
        vm.expectRevert(IBlueLeverageBase.UnauthorizedCallback.selector);
        bundle.onMorphoRepay(0, "");
        assertNoResiduals();
    }

    function testOpenRejectsIncompleteFill() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(101, 100) + 1;
        fundUser(address(bundle), equity);
        (bytes memory commands, bytes[] memory inputs) =
            buildSingleHopRoute(address(loanToken), address(collateralToken), equity - 1, maxBorrowAssets, poolKey);

        vm.expectRevert(IBlueLeverageBase.IncompleteFill.selector);
        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams, equity, 2e18, maxBorrowAssets, address(adapter), abi.encode(commands, inputs), block.timestamp
        );
        assertNoResiduals();
    }

    function _deployUniversalRouter() internal returns (address router) {
        RouterParameters memory params = RouterParameters({
            permit2: address(1),
            weth9: address(1),
            v2Factory: address(0),
            v3Factory: address(0),
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: bytes32(0),
            v4PoolManager: address(poolManager),
            permissionsAdapterFactory: address(0),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0),
            spokePool: address(0)
        });
        bytes memory initcode = abi.encodePacked(vm.getCode("UniversalRouter.sol:UniversalRouter"), abi.encode(params));
        assembly {
            router := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(router != address(0), "UR deploy failed");
    }

    function buildSingleHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn,
        PoolKey memory key
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: tokenIn == Currency.unwrap(key.currency0),
                amountOut: amountOut.toUint128(),
                amountInMaximum: maxIn.toUint128(),
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(Currency.wrap(tokenIn), uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(Currency.wrap(tokenOut), ActionConstants.MSG_SENDER, uint256(ActionConstants.OPEN_DELTA));

        commands = abi.encodePacked(uint8(Commands.V4_SWAP), uint8(Commands.SWEEP));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(tokenIn, ActionConstants.MSG_SENDER, uint256(0));
    }

    function buildMultiHopRoute(uint256 amountOut, uint256 maxIn)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(loanToken)),
            fee: loanIntermediatePoolKey.fee,
            tickSpacing: loanIntermediatePoolKey.tickSpacing,
            hooks: IHooks(address(0)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(intermediateToken)),
            fee: intermediateCollateralPoolKey.fee,
            tickSpacing: intermediateCollateralPoolKey.tickSpacing,
            hooks: IHooks(address(0)),
            hookData: ""
        });

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT), uint8(Actions.SETTLE), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputParams({
                currencyOut: Currency.wrap(address(collateralToken)),
                path: path,
                minHopPriceX36: new uint256[](0),
                amountOut: amountOut.toUint128(),
                amountInMaximum: maxIn.toUint128()
            })
        );
        params[1] = abi.encode(Currency.wrap(address(loanToken)), uint256(ActionConstants.OPEN_DELTA), false);
        params[2] = abi.encode(
            Currency.wrap(address(collateralToken)), ActionConstants.MSG_SENDER, uint256(ActionConstants.OPEN_DELTA)
        );

        commands = abi.encodePacked(uint8(Commands.V4_SWAP), uint8(Commands.SWEEP));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(loanToken), ActionConstants.MSG_SENDER, uint256(0));
    }

    function assertNoResiduals() internal view {
        closeAllTokenBalances(address(bundle));
        closeAllTokenBalances(address(adapter));
        assertNoRouterBalances();
        _assertNoExternalAllowances(address(bundle));
        _assertNoExternalAllowances(address(adapter));
    }

    function _assertNoExternalAllowances(address owner_) internal view {
        assertEq(loanToken.allowance(owner_, universalRouter), 0);
        assertEq(collateralToken.allowance(owner_, universalRouter), 0);
        assertEq(intermediateToken.allowance(owner_, universalRouter), 0);
        assertEq(loanToken.allowance(owner_, address(adapter)), 0);
        assertEq(collateralToken.allowance(owner_, address(adapter)), 0);
        assertEq(intermediateToken.allowance(owner_, address(adapter)), 0);
    }

    function assertNoRouterBalances() internal view {
        assertEq(loanToken.balanceOf(universalRouter), 0);
        assertEq(collateralToken.balanceOf(universalRouter), 0);
        assertEq(intermediateToken.balanceOf(universalRouter), 0);
    }
}
