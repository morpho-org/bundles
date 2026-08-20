// SPDX-License-Identifier: GPL-2.0-or-later

// Net amount inversion for the two Blue entrypoints. P is the aggregate
// public-allocator penalty, deducted before the referral fee.

methods {
    function _.transferFrom(address from, address to, uint256 amount) external => cvlTransferFrom(calledContract, from, to, amount) expect(bool);
    function _.transfer(address to, uint256 amount) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amount) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails details, address owner, bytes signature) external => summaryPermit2Transfer(permit.permitted.token, owner, details.to, details.requestedAmount) expect void;
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(marketParams.collateralToken, assets) expect void;
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(token, assets, data) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;
    function SafeERC20Lib.safeTransferFrom(address token, address from, address to, uint256 value) internal => cvlSafeTransferFrom(token, from, to, value);
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // Both implementations use this same rounding-up penalty calculation.
    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpG(x, y, d);
    function MathLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpG(x, y, d);
    function UtilsLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256) => summaryMulDivDown(x, y, d);
}

persistent ghost mulDivUpG(uint256, uint256, uint256) returns uint256;

persistent ghost mapping(address => mathint) bundlerBalance;

persistent ghost mapping(address => mapping(address => mathint)) recipientBalance;

definition WAD() returns uint256 = 10 ^ 18;

function summaryMulDivDown(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0) revert();
    mathint numerator = a * b;
    mathint result = numerator / d;
    assert result >= 0 && result <= max_uint256;
    return require_uint256(result);
}

function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    else if (from == currentContract) recipientBalance[token][to] = recipientBalance[token][to] + amount;
    return true;
}

function cvlSafeTransferFrom(address token, address from, address to, uint256 value) {
    cvlTransferFrom(token, from, to, value);
}

function summaryPermit2Transfer(address token, address from, address to, uint256 amount) {
    cvlTransferFrom(token, from, to, amount);
}

function summarySupplyCollateral(address token, uint256 amount) {
    bundlerBalance[token] = bundlerBalance[token] - amount;
}

function summaryWrapNative(address token, uint256 value) {
    bundlerBalance[token] = bundlerBalance[token] + value;
}

function summaryBorrow(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    assert shares == 0;
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryWithdraw(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    require shares == 0;
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryFlashLoan(address token, uint256 assets, bytes data) {
    bundlerBalance[token] = bundlerBalance[token] + assets;
    env callbackEnv;
    onMorphoFlashLoan(callbackEnv, assets, data);
    bundlerBalance[token] = bundlerBalance[token] - assets;
}

function reallocationsAssumptions(BlueBundlesV1.PublicAllocations[] reallocations) {
    require reallocations.length <= 3, "loop bound";
    require reallocations.length > 0 => reallocations[0].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 1 => reallocations[1].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 2 => reallocations[2].vault != currentContract, "bundler is not a vault";
}

rule blueBundlesV1WithdrawReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetNet) {
    require e.msg.sender != currentContract;
    require referralFeeRecipient != currentContract;
    require referralFeeRecipient != e.msg.sender;
    require referralFeePct < WAD();
    reallocationsAssumptions(reallocations);

    uint256 penaltyAssets;
    if (reallocations.length > 0) penaltyAssets = penaltyAssets + uint256(reallocations[0].assets).mulDivUp(uint256(reallocations[0].penalty), WAD());
    if (reallocations.length > 1) penaltyAssets = penaltyAssets + uint256(reallocations[1].assets).mulDivUp(uint256(reallocations[1].penalty), WAD());
    if (reallocations.length > 2) penaltyAssets = penaltyAssets + uint256(reallocations[2].assets).mulDivUp(uint256(reallocations[2].penalty), WAD());
    uint256 grossAssets = summaryMulDivDown(targetNet, WAD(), assert_uint256(WAD() - referralFeePct));
    mathint before = bundlerBalance[marketParams.loanToken];
    mathint userBefore = recipientBalance[marketParams.loanToken][e.msg.sender];

    blueBundlesV1Withdraw(e, marketParams, penaltyAssets + grossAssets, 0, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert bundlerBalance[marketParams.loanToken] == before;
    assert recipientBalance[marketParams.loanToken][e.msg.sender] - userBefore == targetNet;
}

rule blueBundlesV1SupplyCollateralAndBorrowReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAssets, uint256 minSharePriceE27, uint256 maxLtv, TokenLib.TokenPermit collateralPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetNet) {
    require e.msg.sender != currentContract;
    require referralFeeRecipient != currentContract;
    require referralFeeRecipient != e.msg.sender;
    require referralFeePct < WAD();
    reallocationsAssumptions(reallocations);

    uint256 penaltyAssets;
    if (reallocations.length > 0) penaltyAssets = penaltyAssets + uint256(reallocations[0].assets).mulDivUp(uint256(reallocations[0].penalty), WAD());
    if (reallocations.length > 1) penaltyAssets = penaltyAssets + uint256(reallocations[1].assets).mulDivUp(uint256(reallocations[1].penalty), WAD());
    if (reallocations.length > 2) penaltyAssets = penaltyAssets + uint256(reallocations[2].assets).mulDivUp(uint256(reallocations[2].penalty), WAD());
    uint256 grossAssets = summaryMulDivDown(targetNet, WAD(), assert_uint256(WAD() - referralFeePct));
    mathint before = bundlerBalance[marketParams.loanToken];
    mathint userBefore = recipientBalance[marketParams.loanToken][e.msg.sender];

    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, penaltyAssets + grossAssets, minSharePriceE27, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert bundlerBalance[marketParams.loanToken] == before;
    assert recipientBalance[marketParams.loanToken][e.msg.sender] - userBefore == targetNet;
}
