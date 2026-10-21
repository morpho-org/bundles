// SPDX-License-Identifier: MIT

// Proves that the bundler only pulls tokens from msg.sender, and only acts on Blue on behalf of msg.sender.
// Assumes that Blue only calls back the caller of flashLoan and repay, so the callbacks are only reached through the bundler's entrypoints.
// Assumes no other reentrancy into the bundler.

methods {
    function BLUE() external returns (address) envfree;

    // Token pulls.
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => pull(from);
    function _.transferFrom(address from, address to, uint256 value) external => pullReturns(from) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => pull(owner) expect void;

    // Blue operations on behalf of a user.
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => onlyCallerReturns(onBehalf) expect(uint256, uint256);
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => onlyCallerReturns(onBehalf) expect(uint256, uint256);
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => onlyCaller(onBehalf) expect void;
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => onlyCaller(authorization.authorizer) expect void;

    // Blue callbacks.
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(assets, data) expect void;
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(data) expect(uint256, uint256);
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

function onlyCallerReturns(address account) returns (uint256, uint256) {
    onlyCaller(account);
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

rule pullIsReachable(env e, calldataarg args) {
    require !pulled, "initial state";

    blueBundlesV1Supply(e, args);

    satisfy pulled;
}
