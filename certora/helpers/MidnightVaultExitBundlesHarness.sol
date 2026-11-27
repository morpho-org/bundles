// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightVaultExitBundlesV1} from "../../src/vault-exit/MidnightVaultExitBundlesV1.sol";
import {Permit} from "../../src/libraries/TokenLib.sol";

contract MidnightVaultExitBundlesHarness is MidnightVaultExitBundlesV1 {
    constructor() MidnightVaultExitBundlesV1(address(1), address(2)) {}

    function redeemFullyIdle(address vault, address adapter, uint256 exitAssets, uint256 deadline) external {
        Permit memory permit;
        _redeemByLiquidity(vault, adapter, exitAssets, type(uint256).max, new bytes32[](0), 0, permit, deadline);
    }

    function chunk(uint256 seed, uint256 feeRate, uint256 assets) external pure returns (uint256, uint256, uint256) {
        return _chunk(seed, feeRate, assets);
    }
}
