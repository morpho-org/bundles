// SPDX-License-Identifier: MIT

// Checks the Blue callbacks through the entrypoints, since Blue only calls back the caller of flashLoan or supply with the data it was given.

import "NoThirdPartyPull.spec";

methods {
    function _.flashLoan(address token, uint256 assets, bytes data) external => flashLoanCallback(calledContract, assets, data) expect void;
    function _.supply(VaultExitBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => supplyCallback(calledContract, assets, data) expect(uint256, uint256);
}

function flashLoanCallback(address blue, uint256 assets, bytes data) {
    env callbackEnv;
    require callbackEnv.msg.sender == blue, "Blue calls back";
    onMorphoFlashLoan(callbackEnv, assets, data);
}

function supplyCallback(address blue, uint256 assets, bytes data) returns (uint256, uint256) {
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == blue, "Blue calls back";
        onMorphoSupply(callbackEnv, assets, data);
    }
    uint256 shares;
    return (assets, shares);
}

use rule noThirdPartyPull filtered { f -> f.selector != sig:onMorphoFlashLoan(uint256, bytes).selector && f.selector != sig:onMorphoSupply(uint256, bytes).selector }
