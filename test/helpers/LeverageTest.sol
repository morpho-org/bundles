// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {OracleMock} from "../../lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "../../lib/morpho-blue/src/mocks/IrmMock.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {TokenTest, ITestToken} from "./TestToken.sol";
import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "../../lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "../../lib/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "../../lib/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "../../lib/v4-core/src/libraries/TickMath.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta);
}

abstract contract LeverageTest is TokenTest {
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LIQUIDITY = 1e32;
    uint128 internal constant POOL_LIQUIDITY = 1e28;
    uint256 internal constant POOL_TOKENS = 1e29;

    IMorpho internal morpho;
    ITestToken internal loanToken;
    ITestToken internal collateralToken;
    ITestToken internal intermediateToken;
    OracleMock internal oracle;
    IrmMock internal irm;
    IPoolManager internal poolManager;
    IPoolModifyLiquidityTest internal liquidityRouter;
    MarketParams internal marketParams;
    PoolKey internal poolKey;
    PoolKey internal loanIntermediatePoolKey;
    PoolKey internal intermediateCollateralPoolKey;

    address internal owner;
    address internal supplier;
    address internal user;

    function setUpLeverage(bool loanTokenIsCurrency1) internal {
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
        intermediateToken = deployToken("intermediate");

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
        deal(address(collateralToken), address(morpho), LIQUIDITY);

        poolManager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(owner)));
        liquidityRouter = IPoolModifyLiquidityTest(
            deployCode("PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest", abi.encode(address(poolManager)))
        );

        poolKey = createPool(address(loanToken), address(collateralToken));
        loanIntermediatePoolKey = createPool(address(loanToken), address(intermediateToken));
        intermediateCollateralPoolKey = createPool(address(intermediateToken), address(collateralToken));
    }

    function createPool(address tokenA, address tokenB) internal returns (PoolKey memory key) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(key, uint160(1 << 96));

        deal(token0, address(this), POOL_TOKENS);
        deal(token1, address(this), POOL_TOKENS);
        safeApprove(ITestToken(token0), address(liquidityRouter), type(uint256).max);
        safeApprove(ITestToken(token1), address(liquidityRouter), type(uint256).max);

        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(POOL_LIQUIDITY)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function closeAllTokenBalances(address bundle) internal view {
        assertEq(loanToken.balanceOf(bundle), 0);
        assertEq(collateralToken.balanceOf(bundle), 0);
        assertEq(intermediateToken.balanceOf(bundle), 0);
    }

    function fundUser(address bundle, uint256 equity) internal {
        deal(address(collateralToken), user, equity);
        vm.startPrank(user);
        safeApprove(collateralToken, bundle, equity);
        morpho.setAuthorization(bundle, true);
        vm.stopPrank();
    }
}
