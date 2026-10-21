// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender, and only acts on Midnight and on ratifiers on behalf of msg.sender.
// Also proves that the bundler never makes Midnight pull tokens from a callback, which could hold someone else's funds.
// Assumes no reentrancy into the bundler.

methods {
    // Token pulls.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => onlyCaller(TRANSFER_FROM(), from);
    function _.transferFrom(address from, address to, uint256 value) external => onlyCallerReturnsBool(TRANSFER_FROM(), from) expect(bool);

    // Midnight operations on behalf of a user.
    function _.take(Midnight.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => summaryTake(taker, takerCallback) expect(uint256, uint256);
    function _.withdraw(Midnight.Market market, uint256 units, address onBehalf, address receiver) external => onlyCaller(WITHDRAW(), onBehalf) expect void;
    function _.withdrawCollateral(Midnight.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver) external => onlyCaller(WITHDRAW_COLLATERAL(), onBehalf) expect void;
    function _.repay(Midnight.Market market, uint256 units, address onBehalf, address callback, bytes data) external => noCallback(REPAY(), callback) expect void;
    function _.setConsumed(bytes32 group, uint128 amount, address onBehalf) external => onlyCaller(SET_CONSUMED(), onBehalf) expect void;
    function _.setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external => onlyCaller(SET_IS_AUTHORIZED(), onBehalf) expect void;

    // Ratifier operations on behalf of a maker.
    function _.setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external => onlyCallerReturns(SET_IS_ROOT_RATIFIED(), maker) expect(bytes32);
    function _.setIsRootRatifiedWithSig(address maker, bytes32 root, uint256 height, bool newIsRootRatified, uint128 nonce, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external => onlyCallerReturns(SET_IS_ROOT_RATIFIED_WITH_SIG(), maker) expect(bytes32);
}

definition TRANSFER_FROM() returns uint8 = 0;

definition TAKE() returns uint8 = 1;

definition WITHDRAW() returns uint8 = 2;

definition WITHDRAW_COLLATERAL() returns uint8 = 3;

definition REPAY() returns uint8 = 4;

definition SET_CONSUMED() returns uint8 = 5;

definition SET_IS_AUTHORIZED() returns uint8 = 6;

definition SET_IS_ROOT_RATIFIED() returns uint8 = 7;

definition SET_IS_ROOT_RATIFIED_WITH_SIG() returns uint8 = 8;

// The initiator of the bundle.
persistent ghost address caller;

// Whether the bundler pulled tokens from, or acted on behalf of, an account other than the initiator.
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

function onlyCallerReturns(uint8 summary, address account) returns (bytes32) {
    onlyCaller(summary, account);
    bytes32 res;
    return res;
}

// When a callback is passed, Midnight pulls the tokens owed from it instead of from the bundler.
function noCallback(uint8 summary, address callback) {
    reached[summary] = true;
    if (callback != 0) actedForOther = true;
}

function summaryTake(address taker, address takerCallback) returns (uint256, uint256) {
    onlyCaller(TAKE(), taker);
    noCallback(TAKE(), takerCallback);
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

rule withdrawIsReached(env e, calldataarg args) {
    require !reached[WITHDRAW()], "initial state";
    midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(e, args);
    satisfy reached[WITHDRAW()];
}

rule withdrawCollateralIsReached(env e, calldataarg args) {
    require !reached[WITHDRAW_COLLATERAL()], "initial state";
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, args);
    satisfy reached[WITHDRAW_COLLATERAL()];
}

rule repayIsReached(env e, calldataarg args) {
    require !reached[REPAY()], "initial state";
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, args);
    satisfy reached[REPAY()];
}

rule setConsumedIsReached(env e, calldataarg args) {
    require !reached[SET_CONSUMED()], "initial state";
    midnightBundlesV2CancelAndMake(e, args);
    satisfy reached[SET_CONSUMED()];
}

rule setIsAuthorizedIsReached(env e, calldataarg args) {
    require !reached[SET_IS_AUTHORIZED()], "initial state";
    midnightBundlesV2CancelAndMake(e, args);
    satisfy reached[SET_IS_AUTHORIZED()];
}

rule setIsRootRatifiedIsReached(env e, calldataarg args) {
    require !reached[SET_IS_ROOT_RATIFIED()], "initial state";
    midnightBundlesV2CancelAndMake(e, args);
    satisfy reached[SET_IS_ROOT_RATIFIED()];
}

rule setIsRootRatifiedWithSigIsReached(env e, calldataarg args) {
    require !reached[SET_IS_ROOT_RATIFIED_WITH_SIG()], "initial state";
    midnightBundlesV2CancelAndMake(e, args);
    satisfy reached[SET_IS_ROOT_RATIFIED_WITH_SIG()];
}
