// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender.
// Assumes no reentrancy into the bundler.

methods {
    function _.transferFrom(address from, address to, uint256 value) external => pullFromReturnsBool(TRANSFER_FROM(), from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => pullFrom(PERMIT2(), owner) expect void;
}

definition TRANSFER_FROM() returns uint8 = 0;

definition PERMIT2() returns uint8 = 1;

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens from an account other than the initiator.
persistent ghost bool pulledFromOther;

// Which summaries were reached, to check that each of them is matched.
persistent ghost mapping(uint8 => bool) reached;

function pullFrom(uint8 summary, address from) {
    reached[summary] = true;
    if (from != caller) pulledFromOther = true;
}

function pullFromReturnsBool(uint8 summary, address from) returns (bool) {
    pullFrom(summary, from);
    return true;
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !pulledFromOther, "initial state";

    f(e, args);

    assert !pulledFromOther;
}

// Reachability of each summary, so that noThirdPartyPull cannot pass because a pull escapes the summaries.

rule transferFromIsReached(env e, calldataarg args) {
    require !reached[TRANSFER_FROM()], "initial state";
    blueBundlesV1Supply(e, args);
    satisfy reached[TRANSFER_FROM()];
}

rule permit2IsReached(env e, calldataarg args) {
    require !reached[PERMIT2()], "initial state";
    blueBundlesV1Supply(e, args);
    satisfy reached[PERMIT2()];
}
