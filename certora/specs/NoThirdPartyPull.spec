// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from, and only withdraws or redeems vault shares of, msg.sender.

methods {
    function _.transferFrom(address from, address to, uint256 value) external => pullFromReturnsBool(from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => pullFrom(owner) expect void;
    function _.withdraw(uint256 assets, address receiver, address owner) external => pullFromReturnsUint(owner) expect(uint256);
    function _.redeem(uint256 shares, address receiver, address owner) external => pullFromReturnsUint(owner) expect(uint256);
}

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens or vault shares from an account other than the initiator.
persistent ghost bool pulledFromOther;

function pullFrom(address from) {
    if (from != caller) pulledFromOther = true;
}

function pullFromReturnsBool(address from) returns (bool) {
    if (from != caller) pulledFromOther = true;
    return true;
}

function pullFromReturnsUint(address from) returns (uint256) {
    if (from != caller) pulledFromOther = true;
    uint256 value;
    return value;
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !pulledFromOther, "initial state";

    f(e, args);

    assert !pulledFromOther;
}
