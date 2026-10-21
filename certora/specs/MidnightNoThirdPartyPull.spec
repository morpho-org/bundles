// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender, and only acts on Midnight and on ratifiers on behalf of msg.sender.
// Also proves that the bundler never makes Midnight pull tokens from a callback, which could hold someone else's funds.
// Assumes no reentrancy into the bundler.

methods {
    // Token pulls.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => pull(from);
    function _.transferFrom(address from, address to, uint256 value) external => pullReturns(from) expect(bool);

    // Midnight operations on behalf of a user.
    function _.take(Midnight.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => summaryTake(taker, takerCallback) expect(uint256, uint256);
    function _.withdraw(Midnight.Market market, uint256 units, address onBehalf, address receiver) external => onlyCaller(onBehalf) expect void;
    function _.withdrawCollateral(Midnight.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver) external => onlyCaller(onBehalf) expect void;
    function _.repay(Midnight.Market market, uint256 units, address onBehalf, address callback, bytes data) external => noCallback(callback) expect void;
    function _.setConsumed(bytes32 group, uint128 amount, address onBehalf) external => onlyCaller(onBehalf) expect void;
    function _.setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external => onlyCaller(onBehalf) expect void;

    // Ratifier operations on behalf of a maker.
    function _.setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external => onlyCallerReturns(maker) expect(bytes32);
    function _.setIsRootRatifiedWithSig(address maker, bytes32 root, uint256 height, bool newIsRootRatified, uint128 nonce, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external => onlyCallerReturns(maker) expect(bytes32);
}

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens from, or acted on behalf of, an account other than the initiator.
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

function onlyCallerReturns(address account) returns (bytes32) {
    onlyCaller(account);
    bytes32 res;
    return res;
}

// When a callback is passed, Midnight pulls the tokens owed from it instead of from the bundler.
function noCallback(address callback) {
    if (callback != 0) actedForOther = true;
}

function summaryTake(address taker, address takerCallback) returns (uint256, uint256) {
    onlyCaller(taker);
    noCallback(takerCallback);
    uint256 buyerAssets;
    uint256 sellerAssets;
    return (buyerAssets, sellerAssets);
}

rule noThirdPartyPull(env e, method f, calldataarg args) {
    require caller == e.msg.sender, "initiator";
    require !actedForOther, "initial state";

    f(e, args);

    assert !actedForOther;
}

rule pullIsReachable(env e, calldataarg args) {
    require !pulled, "initial state";

    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, args);

    satisfy pulled;
}
