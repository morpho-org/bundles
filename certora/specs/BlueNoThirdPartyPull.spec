// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender, and only acts on Blue on behalf of msg.sender.
// Assumes that Blue only calls back the caller of flashLoan and repay, so the callbacks are only reached through the bundler's entrypoints.
// Assumes no other reentrancy into the bundler.

methods {
    function BLUE() external returns (address) envfree;

    // Token pulls.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => onlyCaller(TRANSFER_FROM(), from);
    function _.transferFrom(address from, address to, uint256 value) external => onlyCallerReturnsBool(TRANSFER_FROM(), from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => onlyCaller(PERMIT2(), owner) expect void;

    // Blue operations on behalf of a user.
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => onlyCallerReturns(WITHDRAW(), onBehalf) expect(uint256, uint256);
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => onlyCallerReturns(BORROW(), onBehalf) expect(uint256, uint256);
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => onlyCaller(WITHDRAW_COLLATERAL(), onBehalf) expect void;
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => onlyCaller(SET_AUTHORIZATION_WITH_SIG(), authorization.authorizer) expect void;

    // Blue callbacks.
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(assets, data) expect void;
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(data) expect(uint256, uint256);
}

definition TRANSFER_FROM() returns uint8 = 0;

definition PERMIT2() returns uint8 = 1;

definition WITHDRAW() returns uint8 = 2;

definition BORROW() returns uint8 = 3;

definition WITHDRAW_COLLATERAL() returns uint8 = 4;

definition SET_AUTHORIZATION_WITH_SIG() returns uint8 = 5;

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

function onlyCallerReturns(uint8 summary, address account) returns (uint256, uint256) {
    onlyCaller(summary, account);
    uint256 x;
    uint256 y;
    return (x, y);
}

function summaryFlashLoan(uint256 assets, bytes data) {
    env callbackEnv;
    require callbackEnv.msg.sender == BLUE(), "Blue calls back the caller of flashLoan";
    onMorphoFlashLoan(callbackEnv, assets, data);
}

function summaryRepay(bytes data) returns (uint256, uint256) {
    uint256 assets;
    uint256 shares;
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == BLUE(), "Blue calls back the caller of repay";
        onMorphoRepay(callbackEnv, assets, data);
    }
    return (assets, shares);
}

rule noThirdPartyPull(env e, method f, calldataarg args) filtered { f -> f.selector != sig:onMorphoFlashLoan(uint256, bytes).selector && f.selector != sig:onMorphoRepay(uint256, bytes).selector } {
    require caller == e.msg.sender, "initiator";
    require !actedForOther, "initial state";

    f(e, args);

    assert !actedForOther;
}

rule onMorphoFlashLoanOnlyFromBlue(env e, uint256 assets, bytes data) {
    address blue = BLUE();
    onMorphoFlashLoan@withrevert(e, assets, data);
    assert e.msg.sender != blue => lastReverted;
}

rule onMorphoRepayOnlyFromBlue(env e, uint256 assets, bytes data) {
    address blue = BLUE();
    onMorphoRepay@withrevert(e, assets, data);
    assert e.msg.sender != blue => lastReverted;
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

rule withdrawIsReached(env e, calldataarg args) {
    require !reached[WITHDRAW()], "initial state";
    blueBundlesV1Withdraw(e, args);
    satisfy reached[WITHDRAW()];
}

// Also reaches the flashLoan and repay callbacks.
rule borrowIsReached(env e, calldataarg args) {
    require !reached[BORROW()], "initial state";
    blueBundlesV1MigrateBorrowPosition(e, args);
    satisfy reached[BORROW()];
}

rule withdrawCollateralIsReached(env e, calldataarg args) {
    require !reached[WITHDRAW_COLLATERAL()], "initial state";
    blueBundlesV1RepayAndWithdrawCollateral(e, args);
    satisfy reached[WITHDRAW_COLLATERAL()];
}

rule setAuthorizationWithSigIsReached(env e, calldataarg args) {
    require !reached[SET_AUTHORIZATION_WITH_SIG()], "initial state";
    blueBundlesV1Withdraw(e, args);
    satisfy reached[SET_AUTHORIZATION_WITH_SIG()];
}
