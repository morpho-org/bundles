// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens and vault shares from msg.sender.
// Assumes no reentrancy into the bundler.

methods {
    // Token pulls.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => onlyCaller(TRANSFER_FROM(), from);
    function _.transferFrom(address from, address to, uint256 value) external => onlyCallerReturnsBool(TRANSFER_FROM(), from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => onlyCaller(PERMIT2(), owner) expect void;

    // Vault share pulls.
    function _.withdraw(uint256 assets, address receiver, address onBehalf) external => onlyCallerReturns(WITHDRAW(), onBehalf) expect(uint256);
    function _.redeem(uint256 shares, address receiver, address onBehalf) external => onlyCallerReturns(REDEEM(), onBehalf) expect(uint256);
}

definition TRANSFER_FROM() returns uint8 = 0;

definition PERMIT2() returns uint8 = 1;

definition WITHDRAW() returns uint8 = 2;

definition REDEEM() returns uint8 = 3;

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens or shares from an account other than the initiator.
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

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !actedForOther, "initial state";

    f(e, args);

    assert !actedForOther;
}

// Reachability of each summary, so that noThirdPartyPull cannot pass because a pull escapes the summaries.

rule transferFromIsReached(env e, calldataarg args) {
    require !reached[TRANSFER_FROM()], "initial state";
    vaultBundlesV1Deposit(e, args);
    satisfy reached[TRANSFER_FROM()];
}

rule permit2IsReached(env e, calldataarg args) {
    require !reached[PERMIT2()], "initial state";
    vaultBundlesV1Deposit(e, args);
    satisfy reached[PERMIT2()];
}

rule withdrawIsReached(env e, calldataarg args) {
    require !reached[WITHDRAW()], "initial state";
    vaultBundlesV1Withdraw(e, args);
    satisfy reached[WITHDRAW()];
}

rule redeemIsReached(env e, calldataarg args) {
    require !reached[REDEEM()], "initial state";
    vaultBundlesV1Withdraw(e, args);
    satisfy reached[REDEEM()];
}
