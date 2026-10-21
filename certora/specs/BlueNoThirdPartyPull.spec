// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender.
// Assumes no reentrancy into the bundler.

methods {
    function _.transferFrom(address from, address to, uint256 value) external => pullFromReturnsBool(from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => pullFrom(owner) expect void;
}

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens from an account other than the initiator.
persistent ghost bool pulledFromOther;

// Whether a pull was reached, to check that the summaries are matched.
persistent ghost bool reached;

function pullFrom(address from) {
    reached = true;
    if (from != caller) pulledFromOther = true;
}

function pullFromReturnsBool(address from) returns (bool) {
    pullFrom(from);
    return true;
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !pulledFromOther, "initial state";

    f(e, args);

    assert !pulledFromOther;
}

// Reachability of the summaries, so that noThirdPartyPull cannot pass because a pull escapes them.
rule pullIsReached(env e, calldataarg args) {
    require !reached, "initial state";
    blueBundlesV1Supply(e, args);
    satisfy reached;
}
