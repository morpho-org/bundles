// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UniversalRouterSwapAdapter} from "../src/leverage/adapters/UniversalRouterSwapAdapter.sol";
import {Commands} from "../lib/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "../lib/universal-router/lib/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "../lib/universal-router/lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";

contract UniversalRouterSwapAdapterHarness is UniversalRouterSwapAdapter {
    constructor(address universalRouter) UniversalRouterSwapAdapter(universalRouter) {}

    function withExactAmounts(bytes memory commands, bytes[] memory inputs, uint256 amountOut, uint256 maxIn)
        external
        pure
        returns (bytes[] memory)
    {
        return _withExactAmounts(commands, inputs, amountOut, maxIn);
    }
}

contract UniversalRouterSwapAdapterTest is Test {
    UniversalRouterSwapAdapterHarness internal adapter;

    function setUp() public {
        adapter = new UniversalRouterSwapAdapterHarness(address(1));
    }

    function testV3ExactOutputAmountsAreRewritten() public view {
        address recipient = address(0x1234);
        bytes memory path = hex"123456";
        uint256[] memory minHopPriceX36 = new uint256[](2);
        minHopPriceX36[0] = 11;
        minHopPriceX36[1] = 22;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(recipient, 1, 2, path, true, minHopPriceX36);

        bytes[] memory rewritten =
            adapter.withExactAmounts(abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_OUT)), inputs, 100, 200);
        (
            address actualRecipient,
            uint256 amountOut,
            uint256 maxIn,
            bytes memory actualPath,
            bool payerIsUser,
            uint256[] memory actualMinHopPriceX36
        ) = abi.decode(rewritten[0], (address, uint256, uint256, bytes, bool, uint256[]));

        assertEq(actualRecipient, recipient);
        assertEq(amountOut, 100);
        assertEq(maxIn, 200);
        assertEq(keccak256(actualPath), keccak256(path));
        assertTrue(payerIsUser);
        assertEq(keccak256(abi.encode(actualMinHopPriceX36)), keccak256(abi.encode(minHopPriceX36)));
    }

    function testV2ExactOutputAllowsRevertFlag() public view {
        address recipient = address(0x1234);
        address[] memory path = new address[](2);
        path[0] = address(0x1111);
        path[1] = address(0x2222);
        uint256[] memory minHopPriceX36 = new uint256[](1);
        minHopPriceX36[0] = 33;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(recipient, 1, 2, path, false, minHopPriceX36);

        bytes[] memory rewritten = adapter.withExactAmounts(hex"89", inputs, 100, 200);
        (
            address actualRecipient,
            uint256 amountOut,
            uint256 maxIn,
            address[] memory actualPath,
            bool payerIsUser,
            uint256[] memory actualMinHopPriceX36
        ) = abi.decode(rewritten[0], (address, uint256, uint256, address[], bool, uint256[]));

        assertEq(actualRecipient, recipient);
        assertEq(amountOut, 100);
        assertEq(maxIn, 200);
        assertEq(actualPath[0], path[0]);
        assertEq(actualPath[1], path[1]);
        assertFalse(payerIsUser);
        assertEq(keccak256(abi.encode(actualMinHopPriceX36)), keccak256(abi.encode(minHopPriceX36)));
    }

    function testV4ExactOutputSingleAmountsAreRewritten() public view {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        IV4Router.ExactOutputSingleParams memory swapParams = IV4Router.ExactOutputSingleParams({
            poolKey: poolKey,
            zeroForOne: true,
            amountOut: 1,
            amountInMaximum: 2,
            minHopPriceX36: 33,
            hookData: hex"1234"
        });
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(swapParams);
        params[1] = hex"010203";
        params[2] = hex"040506";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        bytes[] memory rewritten = adapter.withExactAmounts(abi.encodePacked(uint8(Commands.V4_SWAP)), inputs, 100, 200);
        (bytes memory actualActions, bytes[] memory actualParams) = abi.decode(rewritten[0], (bytes, bytes[]));
        IV4Router.ExactOutputSingleParams memory actualSwapParams =
            abi.decode(actualParams[0], (IV4Router.ExactOutputSingleParams));

        assertEq(keccak256(actualActions), keccak256(actions));
        assertEq(actualSwapParams.amountOut, 100);
        assertEq(actualSwapParams.amountInMaximum, 200);
        assertEq(keccak256(abi.encode(actualSwapParams.poolKey)), keccak256(abi.encode(poolKey)));
        assertTrue(actualSwapParams.zeroForOne);
        assertEq(actualSwapParams.minHopPriceX36, 33);
        assertEq(keccak256(actualSwapParams.hookData), keccak256(hex"1234"));
        assertEq(keccak256(actualParams[1]), keccak256(params[1]));
        assertEq(keccak256(actualParams[2]), keccak256(params[2]));
    }

    function testMultipleExactOutputSwapsRemainUnchanged() public view {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = hex"1234";
        inputs[1] = hex"5678";
        bytes32 originalHash = keccak256(abi.encode(inputs));

        bytes[] memory rewritten = adapter.withExactAmounts(hex"0109", inputs, 100, 200);

        assertEq(keccak256(abi.encode(rewritten)), originalHash);
    }

    function testExactInputRouteRemainsUnchanged() public view {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"123456";
        bytes32 originalHash = keccak256(abi.encode(inputs));

        bytes[] memory rewritten = adapter.withExactAmounts(hex"00", inputs, 100, 200);

        assertEq(keccak256(abi.encode(rewritten)), originalHash);
    }

    function testV4AmountOutOverflowReverts() public {
        IV4Router.ExactOutputSingleParams memory swapParams = IV4Router.ExactOutputSingleParams({
            poolKey: PoolKey({
                currency0: Currency.wrap(address(0x1111)),
                currency1: Currency.wrap(address(0x2222)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            zeroForOne: true,
            amountOut: 1,
            amountInMaximum: 2,
            minHopPriceX36: 0,
            hookData: ""
        });
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(swapParams);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE)), params);

        vm.expectRevert();
        adapter.withExactAmounts(abi.encodePacked(uint8(Commands.V4_SWAP)), inputs, uint256(type(uint128).max) + 1, 200);
    }
}
