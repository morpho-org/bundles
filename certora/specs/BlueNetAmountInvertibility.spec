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
    // The public allocator charges the caller mulDivUp(assets, penalty, WAD) of the destination
    // loan token and sends it to the vault, and moves no other token of the caller. Proven of the
    // implementation by BluePublicAllocatorPenalty.spec. Its revert conditions are dropped, which
    // only widens the set of verified executions.
    function _.reallocate(address vault, address deallocateAdapter, BlueBundlesV1.MarketParams deallocateMarketParams, address allocateAdapter, BlueBundlesV1.MarketParams allocateMarketParams, uint128 assets, uint64 penalty) external => summaryPublicAllocation(allocateMarketParams.loanToken, vault, assets, penalty) expect void;
    function _.allocateFromIdle(address vault, address adapter, BlueBundlesV1.MarketParams marketParams, uint128 assets, uint64 penalty) external => summaryPublicAllocation(marketParams.loanToken, vault, assets, penalty) expect void;
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => NONDET;
    function _.nonce(address authorizer) external => NONDET;

    // Only reverts, and reads no state that the property depends on: skipping it verifies a
    // superset of the executions (over-approximation), and drops the market id hashing, the
    // oracle price call and two symbolic-divisor divisions.
    function BlueBundlesV1.requireMaxLtv(BlueBundlesV1.MarketParams memory marketParams, address sender, uint256 maxLtv) internal => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpG(x, y, d);
    function UtilsLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256) => summaryMulDivDown(x, y, d);
}

// The bundler and the public allocator compute the penalty with the same rounding-up division, so
// both sides of the summary above use this one uninterpreted function.
persistent ghost mulDivUpG(uint256, uint256, uint256) returns uint256;

persistent ghost mapping(address => mathint) bundlerBalance;

persistent ghost mapping(address => mapping(address => mathint)) recipientBalance;

definition WAD() returns uint256 = 10 ^ 18;

function summaryMulDivDown(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0 || a * b > max_uint256) {
        revert();
    }
    // a * b <= max_uint256 and d >= 1 above, so the result fits.
    return require_uint256(a * b / d);
}

function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    else if (from == currentContract) recipientBalance[token][to] = recipientBalance[token][to] + amount;
    return true;
}

function summaryPublicAllocation(address token, address vault, uint128 assets, uint64 penalty) {
    cvlTransferFrom(token, currentContract, vault, mulDivUpG(assets, penalty, WAD()));
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

function reallocationsAssumptions(BlueBundlesV1.PublicAllocations[] reallocations, address recipient) {
    require reallocations.length <= 3, "loop bound";
    require reallocations.length > 0 => reallocations[0].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 1 => reallocations[1].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 2 => reallocations[2].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 0 => reallocations[0].vault != recipient, "recipient is not a vault";
    require reallocations.length > 1 => reallocations[1].vault != recipient, "recipient is not a vault";
    require reallocations.length > 2 => reallocations[2].vault != recipient, "recipient is not a vault";
}

function sumPenaltyAssets(BlueBundlesV1.PublicAllocations[] reallocations) returns mathint {
    if (reallocations.length > 2) {
        return mulDivUpG(reallocations[0].assets, reallocations[0].penalty, WAD())
            + mulDivUpG(reallocations[1].assets, reallocations[1].penalty, WAD())
            + mulDivUpG(reallocations[2].assets, reallocations[2].penalty, WAD());
    } else if (reallocations.length > 1) {
        return mulDivUpG(reallocations[0].assets, reallocations[0].penalty, WAD())
            + mulDivUpG(reallocations[1].assets, reallocations[1].penalty, WAD());
    } else if (reallocations.length > 0) {
        return mulDivUpG(reallocations[0].assets, reallocations[0].penalty, WAD());
    } else {
        return 0;
    }
}

rule blueBundlesV1WithdrawReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetNet) {
    require e.msg.sender != currentContract;
    require referralFeeRecipient != currentContract;
    require referralFeeRecipient != e.msg.sender;
    require referralFeePct < WAD();
    reallocationsAssumptions(reallocations, e.msg.sender);

    mathint penaltyAssets = sumPenaltyAssets(reallocations);
    uint256 grossAssets = summaryMulDivDown(targetNet, WAD(), assert_uint256(WAD() - referralFeePct));
    mathint before = bundlerBalance[marketParams.loanToken];
    mathint userBefore = recipientBalance[marketParams.loanToken][e.msg.sender];

    blueBundlesV1Withdraw(e, marketParams, require_uint256(penaltyAssets + grossAssets), 0, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert bundlerBalance[marketParams.loanToken] == before;
    assert recipientBalance[marketParams.loanToken][e.msg.sender] - userBefore == targetNet;
}

rule blueBundlesV1SupplyCollateralAndBorrowReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAssets, uint256 minSharePriceE27, uint256 maxLtv, TokenLib.TokenPermit collateralPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetNet) {
    require e.msg.sender != currentContract;
    require referralFeeRecipient != currentContract;
    require referralFeeRecipient != e.msg.sender;
    require referralFeePct < WAD();
    reallocationsAssumptions(reallocations, e.msg.sender);

    mathint penaltyAssets = sumPenaltyAssets(reallocations);
    uint256 grossAssets = summaryMulDivDown(targetNet, WAD(), assert_uint256(WAD() - referralFeePct));
    mathint before = bundlerBalance[marketParams.loanToken];
    mathint userBefore = recipientBalance[marketParams.loanToken][e.msg.sender];

    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, require_uint256(penaltyAssets + grossAssets), minSharePriceE27, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert bundlerBalance[marketParams.loanToken] == before;
    assert recipientBalance[marketParams.loanToken][e.msg.sender] - userBefore == targetNet;
}
