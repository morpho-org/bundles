// SPDX-License-Identifier: GPL-2.0-or-later

// Check that the Blue entrypoints transfer the target net amount.

methods {
    function _.transferFrom(address from, address to, uint256 amount) external => cvlTransferFrom(calledContract, from, to, amount) expect(bool);
    function _.transfer(address to, uint256 amount) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amount) expect(bool);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails details, address owner, bytes signature) external => summaryPermit2Transfer(permit.permitted.token, owner, details.to, details.requestedAmount) expect void;
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(marketParams.collateralToken, assets) expect void;
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(token, assets, data) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;

    // Assume public allocations only charge their penalty.
    function _.reallocate(address vault, address deallocateAdapter, BlueBundlesV1.MarketParams deallocateMarketParams, address allocateAdapter, BlueBundlesV1.MarketParams allocateMarketParams, uint128 assets, uint64 penalty) external => summaryPublicAllocation(allocateMarketParams.loanToken, vault, assets, penalty) expect void;
    function _.allocateFromIdle(address vault, address adapter, BlueBundlesV1.MarketParams marketParams, uint128 assets, uint64 penalty) external => summaryPublicAllocation(marketParams.loanToken, vault, assets, penalty) expect void;

    // Ignore Blue authorization state.
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => NONDET;
    function _.nonce(address authorizer) external => NONDET;

    // Assume that requireMaxLtv does not revert.
    function BlueBundlesV1.requireMaxLtv(BlueBundlesV1.MarketParams memory marketParams, address sender, uint256 maxLtv) internal => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpG(x, y, d);
    function UtilsLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256) => summaryMulDivDown(x, y, d);
}

// Assume the bundler and public allocator use the same penalty calculation.
persistent ghost mulDivUpG(uint256, uint256, uint256) returns uint256;

// Balance mutations that do not fit uint256 model reverting token transfers and prune those paths.
persistent ghost mapping(address => uint256) bundlerBalance;

persistent ghost mapping(address => mapping(address => uint256)) recipientBalance;

definition WAD() returns uint256 = 10 ^ 18;

function summaryMulDivDown(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0 || a * b > max_uint256) {
        revert();
    }

    return assert_uint256(a * b / d);
}

function referralFeeInversionHolds(uint256 receivedAssets, uint256 referralFeePct, uint256 targetAssets) returns bool {
    return receivedAssets - summaryMulDivDown(receivedAssets, referralFeePct, WAD()) == targetAssets;
}

function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = require_uint256(bundlerBalance[token] - amount);
    if (to == currentContract) bundlerBalance[token] = require_uint256(bundlerBalance[token] + amount);
    else if (from == currentContract) {
        recipientBalance[token][to] = require_uint256(recipientBalance[token][to] + amount);
    }
    return true;
}

function summaryPublicAllocation(address token, address vault, uint128 assets, uint64 penalty) {
    cvlTransferFrom(token, currentContract, vault, mulDivUpG(assets, penalty, WAD()));
}

function summaryPermit2Transfer(address token, address from, address to, uint256 amount) {
    cvlTransferFrom(token, from, to, amount);
}

function summarySupplyCollateral(address token, uint256 amount) {
    bundlerBalance[token] = require_uint256(bundlerBalance[token] - amount);
}

function summaryWrapNative(address token, uint256 value) {
    bundlerBalance[token] = require_uint256(bundlerBalance[token] + value);
}

function summaryBorrow(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    assert shares == 0;
    if (receiver == currentContract) {
        bundlerBalance[token] = require_uint256(bundlerBalance[token] + assets);
    }
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryWithdraw(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    assert shares == 0;
    if (receiver == currentContract) {
        bundlerBalance[token] = require_uint256(bundlerBalance[token] + assets);
    }
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryFlashLoan(address token, uint256 assets, bytes data) {
    bundlerBalance[token] = require_uint256(bundlerBalance[token] + assets);
    env callbackEnv;
    onMorphoFlashLoan(callbackEnv, assets, data);
    bundlerBalance[token] = require_uint256(bundlerBalance[token] - assets);
}

function reallocationsAssumptions(BlueBundlesV1.PublicAllocations[] reallocations, address caller) {
    require reallocations.length <= 2, "loop bound";
    require reallocations.length > 0 => reallocations[0].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 1 => reallocations[1].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 0 => reallocations[0].vault != caller, "no penalty to caller";
    require reallocations.length > 1 => reallocations[1].vault != caller, "no penalty to caller";
}

function sumPenaltyAssets(BlueBundlesV1.PublicAllocations[] reallocations) returns uint256 {
    if (reallocations.length > 1) {
        return require_uint256(
            mulDivUpG(reallocations[0].assets, reallocations[0].penalty, WAD())
                + mulDivUpG(reallocations[1].assets, reallocations[1].penalty, WAD())
        );
    } else if (reallocations.length > 0) {
        return mulDivUpG(reallocations[0].assets, reallocations[0].penalty, WAD());
    } else {
        return 0;
    }
}

// Check that grossing up the target amount offsets the referral fee.
rule referralFeeInversion(uint256 targetAssets, uint256 referralFeePct) {
    require referralFeePct < WAD(), "valid fee";

    uint256 receivedAssets = summaryMulDivDown(targetAssets, WAD(), assert_uint256(WAD() - referralFeePct));

    assert referralFeeInversionHolds(receivedAssets, referralFeePct, targetAssets);
}

// Check that withdrawing transfers the target amount and leaves no residue.
rule blueBundlesV1WithdrawReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetAssets) {
    require e.msg.sender != currentContract, "external caller";
    require referralFeeRecipient != currentContract, "no fee residue";
    require referralFeeRecipient != e.msg.sender, "separate fee recipient";
    reallocationsAssumptions(reallocations, e.msg.sender);

    uint256 penaltyAssets = sumPenaltyAssets(reallocations);
    uint256 receivedAssets;
    require referralFeeInversionHolds(receivedAssets, referralFeePct, targetAssets), "see referralFeeInversion";
    require penaltyAssets + receivedAssets <= max_uint256, "valid uint256 input";
    uint256 withdrawAssets = assert_uint256(penaltyAssets + receivedAssets);
    uint256 before = bundlerBalance[marketParams.loanToken];
    uint256 userBefore = recipientBalance[marketParams.loanToken][e.msg.sender];

    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, 0, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert bundlerBalance[marketParams.loanToken] == before;
    assert recipientBalance[marketParams.loanToken][e.msg.sender] == userBefore + targetAssets;
}

// Check that borrowing transfers the target amount and leaves no residue.
rule blueBundlesV1SupplyCollateralAndBorrowReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAssets, uint256 maxLtv, TokenLib.TokenPermit collateralPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetAssets) {
    require e.msg.sender != currentContract, "external caller";
    require referralFeeRecipient != currentContract, "no fee residue";
    require referralFeeRecipient != e.msg.sender, "separate fee recipient";
    reallocationsAssumptions(reallocations, e.msg.sender);

    uint256 penaltyAssets = sumPenaltyAssets(reallocations);
    uint256 receivedAssets;
    require referralFeeInversionHolds(receivedAssets, referralFeePct, targetAssets), "see referralFeeInversion";
    require penaltyAssets + receivedAssets <= max_uint256, "valid uint256 input";
    uint256 borrowAssets = assert_uint256(penaltyAssets + receivedAssets);
    uint256 before = bundlerBalance[marketParams.loanToken];
    uint256 userBefore = recipientBalance[marketParams.loanToken][e.msg.sender];

    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, borrowAssets, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert bundlerBalance[marketParams.loanToken] == before;
    assert recipientBalance[marketParams.loanToken][e.msg.sender] == userBefore + targetAssets;
}
