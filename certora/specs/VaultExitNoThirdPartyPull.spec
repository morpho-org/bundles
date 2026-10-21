// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls vault shares from msg.sender, and only force deallocates on behalf of msg.sender.
// Assumes that Blue only calls back the caller of flashLoan and supply, so the callbacks are only reached through the bundler's entrypoints.
// Assumes no other reentrancy into the bundler.

methods {
    function BLUE() external returns (address) envfree;

    // Token pulls, which the bundler does not do.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => onlyCaller(TRANSFER_FROM(), from);
    function _.transferFrom(address from, address to, uint256 value) external => onlyCallerReturnsBool(TRANSFER_FROM(), from) expect(bool);

    // Vault share pulls.
    function _.withdraw(uint256 assets, address receiver, address onBehalf) external => onlyCallerReturns(WITHDRAW(), onBehalf) expect(uint256);
    function _.redeem(uint256 shares, address receiver, address onBehalf) external => onlyCallerReturns(REDEEM(), onBehalf) expect(uint256);
    function _.forceDeallocate(address adapter, bytes data, uint256 assets, address onBehalf) external => onlyCallerReturns(FORCE_DEALLOCATE(), onBehalf) expect(uint256);

    // Blue callbacks.
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(assets, data) expect void;
    function _.supply(VaultExitBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(assets, data) expect(uint256, uint256);
}

definition TRANSFER_FROM() returns uint8 = 0;

definition WITHDRAW() returns uint8 = 1;

definition REDEEM() returns uint8 = 2;

definition FORCE_DEALLOCATE() returns uint8 = 3;

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens or shares from, or acted on behalf of, an account other than the initiator.
persistent ghost bool actedForOther;

// Which summaries were reached, to check that each of them is matched.
persistent ghost mapping(uint8 => bool) reached;

function onlyCaller(uint8 summary, address account) {
    reached[summary] = true;
    if (account != caller) actedForOther = true;
}

function onlyCallerReturnsBool(uint8 summary, address account) returns (bool) {
    onlyCaller(summary, account);
    return true;
}

function onlyCallerReturns(uint8 summary, address account) returns (uint256) {
    onlyCaller(summary, account);
    uint256 res;
    return res;
}

function summaryFlashLoan(uint256 assets, bytes data) {
    env callbackEnv;
    require callbackEnv.msg.sender == BLUE(), "Blue calls back the caller of flashLoan";
    onMorphoFlashLoan(callbackEnv, assets, data);
}

function summarySupply(uint256 assets, bytes data) returns (uint256, uint256) {
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == BLUE(), "Blue calls back the caller of supply";
        onMorphoSupply(callbackEnv, assets, data);
    }
    uint256 shares;
    return (assets, shares);
}

rule noThirdPartyPull(env e, method f, calldataarg args) filtered { f -> f.selector != sig:onMorphoFlashLoan(uint256, bytes).selector && f.selector != sig:onMorphoSupply(uint256, bytes).selector } {
    require caller == e.msg.sender, "initiator";
    require !actedForOther, "initial state";

    f(e, args);

    assert !actedForOther;
}

rule onMorphoFlashLoanOnlyFromBlue(env e, uint256 assets, bytes data) {
    address blue = BLUE();
    onMorphoFlashLoan@withrevert(e, assets, data);
    assert e.msg.sender != blue => lastReverted;
}

rule onMorphoSupplyOnlyFromBlue(env e, uint256 assets, bytes data) {
    address blue = BLUE();
    onMorphoSupply@withrevert(e, assets, data);
    assert e.msg.sender != blue => lastReverted;
}

// Reachability of each summary used by the bundler, so that noThirdPartyPull cannot pass because a pull escapes the summaries.

// Also reaches the flashLoan callback.
rule withdrawIsReached(env e, calldataarg args) {
    require !reached[WITHDRAW()], "initial state";
    vaultExitBundlesV1InKindRedemptionVaultV1(e, args);
    satisfy reached[WITHDRAW()];
}

// Also reaches the supply callback.
rule forceDeallocateIsReached(env e, calldataarg args) {
    require !reached[FORCE_DEALLOCATE()], "initial state";
    vaultExitBundlesV1InKindRedemptionVaultV2(e, args);
    satisfy reached[FORCE_DEALLOCATE()];
}
