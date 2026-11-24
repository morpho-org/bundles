// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightVaultExitBundlesV1} from "../../src/vault-exit/MidnightVaultExitBundlesV1.sol";
import {Permit} from "../../src/libraries/TokenLib.sol";

contract MidnightVaultExitBundlesHarness is MidnightVaultExitBundlesV1 {
    constructor() MidnightVaultExitBundlesV1(address(1), address(2)) {}

    function redeemFullyIdle(address vault, address adapter, uint256 exitAssets, uint256 deadline) external {
        Permit memory permit;
        _redeem(vault, adapter, exitAssets, 0, permit, deadline, false);
    }

    function distributeThree(uint256 first, uint256 second, uint256 third, uint256 assets)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = first;
        amounts[1] = second;
        amounts[2] = third;
        uint256 total = first + second + third;
        amounts = _distributeProRata(amounts, assets, total);
        return (amounts[0], amounts[1], amounts[2]);
    }

    function chunk(uint256 seed, uint256 feeRate, uint256 assets) external pure returns (uint256, uint256, uint256) {
        return _chunk(seed, feeRate, assets);
    }
}
