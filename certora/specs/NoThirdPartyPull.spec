// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender.

methods {
    function _.transferFrom(address from, address to, uint256 value) external => pullFromReturnsBool(from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => pullFrom(owner) expect void;
}

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens from an account other than the initiator.
persistent ghost bool pulledFromOther;

function pullFrom(address from) {
    if (from != caller) pulledFromOther = true;
}

function pullFromReturnsBool(address from) returns (bool) {
    if (from != caller) pulledFromOther = true;
    return true;
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !pulledFromOther, "initial state";

    f(e, args);

    assert !pulledFromOther;
}
