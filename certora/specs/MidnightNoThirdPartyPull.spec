// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender.
// Also proves that the bundler never makes Midnight pull tokens from a callback, which could hold someone else's tokens.

methods {
    function _.transferFrom(address from, address to, uint256 value) external => pullFromReturnsBool(from) expect(bool);
    function _.take(Midnight.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => noCallbackReturns(takerCallback) expect(uint256, uint256);
    function _.repay(Midnight.Market market, uint256 units, address onBehalf, address callback, bytes data) external => noCallback(callback) expect void;
}

// The initiator of the bundle.
persistent ghost address caller;

// Whether tokens were pulled from an account other than the initiator.
persistent ghost bool pulledFromOther;

function pullFromReturnsBool(address from) returns (bool) {
    if (from != caller) pulledFromOther = true;
    return true;
}

// When a callback is passed, Midnight pulls the tokens owed from it instead of from the bundler.
function noCallback(address callback) {
    if (callback != 0) pulledFromOther = true;
}

function noCallbackReturns(address callback) returns (uint256, uint256) {
    noCallback(callback);
    uint256 buyerAssets;
    uint256 sellerAssets;
    return (buyerAssets, sellerAssets);
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !pulledFromOther, "initial state";

    f(e, args);

    assert !pulledFromOther;
}
