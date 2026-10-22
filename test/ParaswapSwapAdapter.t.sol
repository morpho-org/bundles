// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {LeverageTest} from "./helpers/LeverageTest.sol";
import {MarketParams, Market, Position} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "../lib/midnight/src/libraries/UtilsLib.sol";
import {LeverageBundlesV1} from "../src/leverage/LeverageBundlesV1.sol";
import {ParaswapSwapAdapter, IAugustusV6} from "../src/leverage/adapters/ParaswapSwapAdapter.sol";
import {AugustusMock} from "./helpers/AugustusMock.sol";
import {IERC20} from "../lib/vault-v2/src/interfaces/IERC20.sol";

contract ParaswapSwapAdapterTest is LeverageTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    LeverageBundlesV1 internal bundle;
    ParaswapSwapAdapter internal adapter;
    AugustusMock internal augustus;

    function setUp() public {
        setUpLeverageMarketOnly(false);
        augustus = new AugustusMock();
        adapter = new ParaswapSwapAdapter(address(augustus));
        bundle = new LeverageBundlesV1(address(morpho));
    }

    function testOpen() public {
        uint256 equity = 10e18;
        uint256 amountOut = equity;
        uint256 maxBorrowAssets = amountOut.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory swapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, amountOut);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams, equity, 2e18, maxBorrowAssets, address(adapter), swapData, block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        assertEq(position.collateral, 2 * equity);
        assertGt(position.borrowShares, 0);
        assertNoResiduals();
    }

    function testDelever() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams, equity, 2e18, maxBorrowAssets, address(adapter), openSwapData, block.timestamp
        );

        Position memory beforePosition = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtBefore =
            uint256(beforePosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 repayAssets = debtBefore / 2;
        uint256 maxCollateralIn = repayAssets.mulDivUp(1003, 1000);
        bytes memory swapData =
            buildSwapData(address(collateralToken), address(loanToken), maxCollateralIn, repayAssets);

        vm.prank(user);
        bundle.leverageBundlesV1Delever(
            marketParams, repayAssets, maxCollateralIn, address(adapter), swapData, block.timestamp
        );

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        Market memory marketAfter = morpho.market(marketParams.id());
        assertEq(market.totalBorrowAssets - marketAfter.totalBorrowAssets, repayAssets);
        assertLe(beforePosition.collateral - afterPosition.collateral, maxCollateralIn);
        assertNoResiduals();
    }

    function testClose() public {
        uint256 equity = 10e18;
        uint256 maxBorrowAssets = equity.mulDivUp(1003, 1000);
        fundUser(address(bundle), equity);
        bytes memory openSwapData = buildSwapData(address(loanToken), address(collateralToken), maxBorrowAssets, equity);

        vm.prank(user);
        bundle.leverageBundlesV1Open(
            marketParams, equity, 2e18, maxBorrowAssets, address(adapter), openSwapData, block.timestamp
        );

        Position memory position = morpho.position(marketParams.id(), user);
        Market memory market = morpho.market(marketParams.id());
        uint256 debtAssets =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 maxCollateralIn = debtAssets.mulDivUp(1003, 1000);
        bytes memory swapData = buildSwapData(address(collateralToken), address(loanToken), maxCollateralIn, debtAssets);

        vm.prank(user);
        bundle.leverageBundlesV1Close(marketParams, position.collateral, address(adapter), swapData, block.timestamp);

        Position memory afterPosition = morpho.position(marketParams.id(), user);
        assertEq(afterPosition.borrowShares, 0);
        assertEq(afterPosition.collateral, 0);
        assertGt(collateralToken.balanceOf(user), 0);
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
                    beneficiary: payable(address(adapter))
                }),
                0,
                bytes(""),
                bytes("")
            )
        );
    }

    function assertNoResiduals() internal view {
        closeAllTokenBalances(address(bundle));
        closeAllTokenBalances(address(adapter));
        assertEq(loanToken.allowance(address(adapter), address(augustus)), 0);
        assertEq(collateralToken.allowance(address(adapter), address(augustus)), 0);
    }
}
