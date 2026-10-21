// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens and vault shares from msg.sender.
// Assumes no reentrancy into the bundler.

methods {
    // Token pulls.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => pull(from);
    function _.transferFrom(address from, address to, uint256 value) external => pullReturns(from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => pull(owner) expect void;

    // Vault share pulls.
    function _.withdraw(uint256 assets, address receiver, address onBehalf) external => onlyCallerReturns(onBehalf) expect(uint256);
    function _.redeem(uint256 shares, address receiver, address onBehalf) external => onlyCallerReturns(onBehalf) expect(uint256);
}

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens or shares from an account other than the initiator.
persistent ghost bool actedForOther;

function onlyCaller(address account) {
    if (account != caller) actedForOther = true;
}

// Whether the bundler pulled tokens, to check that pulls are summarized.
persistent ghost bool pulled;

function pull(address from) {
    pulled = true;
    onlyCaller(from);
}

function pullReturns(address from) returns (bool) {
    pull(from);
    return true;
}

function onlyCallerReturns(address account) returns (uint256) {
    onlyCaller(account);
    uint256 res;
    return res;
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !actedForOther, "initial state";

    f(e, args);

    assert !actedForOther;
}

rule pullIsReachable(env e, calldataarg args) {
    require !pulled, "initial state";

    vaultBundlesV1Deposit(e, args);

    satisfy pulled;
}
