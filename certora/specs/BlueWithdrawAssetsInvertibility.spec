// SPDX-License-Identifier: GPL-2.0-or-later

// Check that the Blue entrypoints transfer the target net amount.

methods {
    function _.transfer(address to, uint256 amount) external with(env e) => summaryTransfer(calledContract, e.msg.sender, to, amount) expect(bool);
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => NONDET;
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(token, assets, data) expect void;
    function _.deposit() external => NONDET;

    // Exclude PA donations from proceeds.
    function SafeERC20Lib.safeTransferFrom(address token, address from, address to, uint256 value) internal => NONDET;

    // Ignore Blue authorization state.
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => NONDET;
    function _.nonce(address authorizer) external => NONDET;

    // Assume that requireMaxLtv does not revert.
    function BlueBundlesV1.requireMaxLtv(BlueBundlesV1.MarketParams memory marketParams, address sender, uint256 maxLtv) internal => NONDET;
    function TokenLib.pullToken(address token, address from, uint256 amount, TokenLib.TokenPermit memory permit) internal => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // UtilsLib.mulDivUp and MathLib.mulDivUp are summarised with same ghost as the functions are identical.
    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpGhost(x, y, d);
    function MathLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpGhost(x, y, d);
    function UtilsLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256) => summaryMulDivDown(x, y, d);
}

persistent ghost mulDivUpGhost(uint256, uint256, uint256) returns uint256;

// Track direct ERC20 transfers from the bundler.
persistent ghost mapping(address => mapping(address => mathint)) transferredFromBundler;

definition WAD() returns uint256 = 10 ^ 18;

function summaryMulDivDown(uint256 a, uint256 b, uint256 d) returns uint256 {
    if (d == 0 || a * b > max_uint256) {
        revert();
    }

    return assert_uint256(a * b / d);
}

function referralFeeInversionHolds(uint256 assets, uint256 penaltyAssets, uint256 referralFeePct, uint256 targetAssets) returns bool {
    if (assets < penaltyAssets) {
        return false;
    }
    uint256 receivedAssets = assert_uint256(assets - penaltyAssets);
    return receivedAssets - summaryMulDivDown(receivedAssets, referralFeePct, WAD()) == targetAssets;
}

function summaryTransfer(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) {
        transferredFromBundler[token][to] = transferredFromBundler[token][to] + amount;
    }
    return true;
}

function summaryBorrow(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    assert shares == 0;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryWithdraw(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    assert shares == 0;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryFlashLoan(address token, uint256 assets, bytes data) {
    env callbackEnv;
    onMorphoFlashLoan(callbackEnv, assets, data);
}

function sumPenaltyAssets(BlueBundlesV1.PublicAllocations[] reallocations) returns uint256 {
    if (reallocations.length > 1) {
        return require_uint256(mulDivUpGhost(reallocations[0].assets, reallocations[0].penalty, WAD()) + mulDivUpGhost(reallocations[1].assets, reallocations[1].penalty, WAD()));
    } else if (reallocations.length > 0) {
        return mulDivUpGhost(reallocations[0].assets, reallocations[0].penalty, WAD());
    } else {
        return 0;
    }
}

// Gross withdrawal needed for the target net assets.
rule withdrawReferralFeeInversion(uint256 targetAssets, uint256 referralFeePct, uint256 penaltyAssets) {
    require referralFeePct < WAD(), "valid fee";

    uint256 receivedAssets = summaryMulDivDown(targetAssets, WAD(), assert_uint256(WAD() - referralFeePct));
    require penaltyAssets + receivedAssets <= max_uint256, "valid uint256 input";
    uint256 withdrawAssets = assert_uint256(penaltyAssets + receivedAssets);

    assert referralFeeInversionHolds(withdrawAssets, penaltyAssets, referralFeePct, targetAssets);
}

// Gross borrow needed for the target net assets.
rule borrowReferralFeeInversion(uint256 targetAssets, uint256 referralFeePct, uint256 penaltyAssets) {
    require referralFeePct < WAD(), "valid fee";

    uint256 receivedAssets = summaryMulDivDown(targetAssets, WAD(), assert_uint256(WAD() - referralFeePct));
    require penaltyAssets + receivedAssets <= max_uint256, "valid uint256 input";
    uint256 borrowAssets = assert_uint256(penaltyAssets + receivedAssets);

    assert referralFeeInversionHolds(borrowAssets, penaltyAssets, referralFeePct, targetAssets);
}

// Check that withdrawing transfers the target amount.
rule blueBundlesV1WithdrawReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetAssets) {
    require referralFeeRecipient != e.msg.sender, "fee recipient is distinct";
    require reallocations.length <= 2, "assume two allocations";

    uint256 penaltyAssets = sumPenaltyAssets(reallocations);
    uint256 withdrawAssets;
    require referralFeeInversionHolds(withdrawAssets, penaltyAssets, referralFeePct, targetAssets), "see withdrawReferralFeeInversion";
    mathint receivedBefore = transferredFromBundler[marketParams.loanToken][e.msg.sender];

    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, 0, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert transferredFromBundler[marketParams.loanToken][e.msg.sender] == receivedBefore + targetAssets;
}

// Check that borrowing transfers the target amount.
rule blueBundlesV1SupplyCollateralAndBorrowReturnsTargetNet(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAssets, uint256 maxLtv, TokenLib.TokenPermit collateralPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, uint256 targetAssets) {
    require referralFeeRecipient != e.msg.sender, "fee recipient is distinct";
    require reallocations.length <= 2, "assume two allocations";

    uint256 penaltyAssets = sumPenaltyAssets(reallocations);
    uint256 borrowAssets;
    require referralFeeInversionHolds(borrowAssets, penaltyAssets, referralFeePct, targetAssets), "see borrowReferralFeeInversion";
    mathint receivedBefore = transferredFromBundler[marketParams.loanToken][e.msg.sender];

    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, borrowAssets, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    assert transferredFromBundler[marketParams.loanToken][e.msg.sender] == receivedBefore + targetAssets;
}
