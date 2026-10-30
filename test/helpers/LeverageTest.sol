// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OracleMock} from "../../lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "../../lib/morpho-blue/src/mocks/IrmMock.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {TokenTest, ITestToken} from "./TestToken.sol";

abstract contract LeverageTest is TokenTest {
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LIQUIDITY = 1e32;

    IMorpho internal morpho;
    ITestToken internal loanToken;
    ITestToken internal collateralToken;
    OracleMock internal oracle;
    IrmMock internal irm;
    MarketParams internal marketParams;

    address internal owner;
    address internal supplier;
    address internal user;

    function setUpLeverageMarketOnly(bool loanTokenIsCurrency1) internal {
        owner = makeAddr("owner");
        supplier = makeAddr("supplier");
        user = makeAddr("user");

        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
        ITestToken tokenA = deployToken("token A");
        ITestToken tokenB = deployToken("token B");
        if ((address(tokenA) > address(tokenB)) == loanTokenIsCurrency1) {
            loanToken = tokenA;
            collateralToken = tokenB;
        } else {
            loanToken = tokenB;
            collateralToken = tokenA;
        }
        oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        irm = new IrmMock();
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });

        vm.startPrank(owner);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(LLTV);
        vm.stopPrank();
        morpho.createMarket(marketParams);

        deal(address(loanToken), supplier, LIQUIDITY);
        vm.startPrank(supplier);
        safeApprove(loanToken, address(morpho), type(uint256).max);
        morpho.supply(marketParams, LIQUIDITY, 0, supplier, "");
        vm.stopPrank();
    }

    function closeAllTokenBalances(address bundle) internal view {
        assertEq(loanToken.balanceOf(bundle), 0);
        assertEq(collateralToken.balanceOf(bundle), 0);
    }

    function fundUser(address bundle, uint256 equity) internal {
        deal(address(collateralToken), user, equity);
        vm.startPrank(user);
        safeApprove(collateralToken, bundle, equity);
        morpho.setAuthorization(bundle, true);
        vm.stopPrank();
    }
}
