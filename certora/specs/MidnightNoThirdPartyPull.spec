// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender.
// Also proves that the bundler never makes Midnight pull tokens from a callback, which could hold someone else's tokens.
// Assumes no reentrancy into the bundler.

methods {
    function _.transferFrom(address from, address to, uint256 value) external => pullFromReturnsBool(TRANSFER_FROM(), from) expect(bool);
    function _.take(Midnight.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => noCallbackReturns(TAKE(), takerCallback) expect(uint256, uint256);
    function _.repay(Midnight.Market market, uint256 units, address onBehalf, address callback, bytes data) external => noCallback(REPAY(), callback) expect void;
}

definition TRANSFER_FROM() returns uint8 = 0;

definition TAKE() returns uint8 = 1;

definition REPAY() returns uint8 = 2;

// The initiator of the bundle.
persistent ghost address caller;

// Whether tokens were pulled from an account other than the initiator.
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

// When a callback is passed, Midnight pulls the tokens owed from it instead of from the bundler.
function noCallback(uint8 summary, address callback) {
    reached[summary] = true;
    if (callback != 0) pulledFromOther = true;
}

function noCallbackReturns(uint8 summary, address callback) returns (uint256, uint256) {
    noCallback(summary, callback);
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

// Reachability of each summary, so that noThirdPartyPull cannot pass because a pull escapes the summaries.

rule transferFromIsReached(env e, calldataarg args) {
    require !reached[TRANSFER_FROM()], "initial state";
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, args);
    satisfy reached[TRANSFER_FROM()];
}

rule takeIsReached(env e, calldataarg args) {
    require !reached[TAKE()], "initial state";
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, args);
    satisfy reached[TAKE()];
}

rule repayIsReached(env e, calldataarg args) {
    require !reached[REPAY()], "initial state";
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, args);
    satisfy reached[REPAY()];
}
