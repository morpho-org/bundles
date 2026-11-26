// SPDX-License-Identifier: MIT

methods {
    // Allowances and authorizations are not modeled, so ignore these side-effects.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization, BlueBundlesV1.Signature) external => NONDET;

    // Over-approximation of checks and arithmetic, since we don't check for reverts in this file.
    function BlueBundlesV1.requireMaxLtv(BlueBundlesV1.MarketParams memory, address, uint256) internal => NONDET;
    function UtilsLib.mulDivDown(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpGhost(x, y, d);

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransferFrom(token, currentContract, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => summarySafeTransferFrom(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(e.msg.value) expect void;
    function _.withdraw(uint256 amount) external => summaryUnwrapNative(amount) expect void;

    // Calls accounting for transfers.
    function _.allocateFromIdle(address, address, BlueBundlesV1.MarketParams, uint128 assets, uint64 penalty) external => summaryPayPenalty(assets, penalty) expect void;
    function _.reallocate(address, address, BlueBundlesV1.MarketParams, address, BlueBundlesV1.MarketParams, uint128 assets, uint64 penalty) external => summaryPayPenalty(assets, penalty) expect void;
    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(assets, shares) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address) external => summaryWithdraw(assets) expect(uint256, uint256);
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address) external => summaryBorrow(assets, shares) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(calledContract, assets, data) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(assets) expect void;
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address) external => summaryWithdrawCollateral(assets) expect void;
    function _.flashLoan(address, uint256 assets, bytes data) external => summaryFlashLoan(calledContract, assets, data) expect void;
}

/// HELPERS ///

// Net amount transferred to each account during the interaction, per token, which is not the token balance.
persistent ghost mapping(address => mapping(address => mathint)) transferBalanceChange;

// Native value sent by the bundler to each account during the interaction.
persistent ghost mapping(address => mathint) nativeTransfers;

persistent ghost mathint wrappedAssets;

persistent ghost mathint unwrappedAssets;

persistent ghost mathint suppliedAssets;

persistent ghost mathint withdrawnAssets;

persistent ghost mathint borrowedAssets;

persistent ghost mathint repaidAssets;

persistent ghost mathint suppliedCollateral;

persistent ghost mathint withdrawnCollateral;

persistent ghost mathint penaltyAssets;

persistent ghost mulDivUpGhost(uint256, uint256, uint256) returns uint256;

definition WAD() returns uint256 = 10 ^ 18;

function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    transferBalanceChange[token][from] = transferBalanceChange[token][from] - amount;
    transferBalanceChange[token][to] = transferBalanceChange[token][to] + amount;
}

function summaryWrapNative(uint256 value) {
    wrappedAssets = wrappedAssets + value;
}

function summaryUnwrapNative(uint256 amount) {
    unwrappedAssets = unwrappedAssets + amount;
}

hook CALL(uint256 g, address addr, uint256 value, uint256 argsOffset, uint256 argsLength, uint256 retOffset, uint256 retLength) uint256 rc {
    // The return code rc is 0 when the call reverts, so only successful native transfers are counted.
    if (executingContract == currentContract && rc != 0) {
        nativeTransfers[addr] = nativeTransfers[addr] + value;
    }
}

function summarySupply(uint256 assets, uint256 shares) returns (uint256, uint256) {
    assert shares == 0;
    suppliedAssets = suppliedAssets + assets;
    uint256 suppliedShares;
    return (assets, suppliedShares);
}

function summaryWithdraw(uint256 assets) returns (uint256, uint256) {
    uint256 withdrawn;
    require assets > 0 => withdrawn == assets, "withdraw exact assets";
    withdrawnAssets = withdrawnAssets + withdrawn;
    uint256 shares;
    return (withdrawn, shares);
}

function summaryBorrow(uint256 assets, uint256 shares) returns (uint256, uint256) {
    assert shares == 0;
    borrowedAssets = borrowedAssets + assets;
    uint256 borrowedShares;
    return (assets, borrowedShares);
}

function summaryRepay(address blue, uint256 assets, bytes data) returns (uint256, uint256) {
    uint256 repaid;
    require assets > 0 => repaid == assets, "repay exact assets";
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == blue, "Blue calls back";
        onMorphoRepay(callbackEnv, repaid, data);
    }
    repaidAssets = repaidAssets + repaid;
    uint256 shares;
    return (repaid, shares);
}

function summarySupplyCollateral(uint256 assets) {
    suppliedCollateral = suppliedCollateral + assets;
}

function summaryWithdrawCollateral(uint256 assets) {
    withdrawnCollateral = withdrawnCollateral + assets;
}

function summaryFlashLoan(address blue, uint256 assets, bytes data) {
    env callbackEnv;
    require callbackEnv.msg.sender == blue, "Blue calls back";
    onMorphoFlashLoan(callbackEnv, assets, data);
}

function summaryPayPenalty(uint128 assets, uint64 penalty) {
    penaltyAssets = penaltyAssets + mulDivUpGhost(assets, penalty, WAD());
}

/// RULES ///

rule supplyCollateralAndBorrowDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAssets, uint256 borrowAssets, uint256 maxLtv, TokenLib.TokenPermit collateralPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require marketParams.loanToken != marketParams.collateralToken, "assume different loan and collateral tokens for simpler accounting";
    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets == 0 && borrowedAssets == 0 && suppliedCollateral == 0 && penaltyAssets == 0, "only count operations of the interaction";
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, borrowAssets, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    // Conservatively count both the native transfer and balance change from transfers, even if at most one is non-zero.
    mathint sent = e.msg.value - transferBalanceChange[marketParams.collateralToken][e.msg.sender];
    mathint received = transferBalanceChange[marketParams.loanToken][e.msg.sender];
    mathint fees = transferBalanceChange[marketParams.loanToken][referralFeeRecipient];

    // Also check that every native token sent is wrapped.
    assert e.msg.value == wrappedAssets;
    assert borrowedAssets == received + penaltyAssets + fees;
    assert sent == suppliedCollateral;
}

rule repayAndWithdrawCollateralDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 repayAssets, uint256 repayShares, uint256 maxRepayAssets, uint256 collateralAssets, uint256 maxLtv, TokenLib.TokenPermit loanTokenPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require forall address a. nativeTransfers[a] == 0, "only count native transfers of the interaction";
    require wrappedAssets == 0 && unwrappedAssets == 0 && repaidAssets == 0, "only count operations of the interaction";
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, repayAssets, repayShares, maxRepayAssets, collateralAssets, maxLtv, loanTokenPermit, signedAuthorization, referralFeePct, referralFeeRecipient, deadline);

    // Conservatively count both the native transfer and balance change from transfers, even if at most one is non-zero.
    mathint spent = e.msg.value - transferBalanceChange[marketParams.loanToken][e.msg.sender];
    mathint fees = transferBalanceChange[marketParams.loanToken][referralFeeRecipient];
    mathint refunded = nativeTransfers[e.msg.sender];

    // Also check that every native token sent is wrapped, and that every unwrapped token is sent back.
    assert e.msg.value == wrappedAssets;
    assert unwrappedAssets == refunded;
    assert spent == repaidAssets + refunded + fees;
}

rule supplyDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, TokenLib.TokenPermit loanTokenPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets == 0 && suppliedAssets == 0, "only count operations of the interaction";
    blueBundlesV1Supply(e, marketParams, assets, loanTokenPermit, referralFeePct, referralFeeRecipient, deadline);

    // Conservatively count both the native transfer and balance change from transfers, even if at most one is non-zero.
    mathint spent = e.msg.value - transferBalanceChange[marketParams.loanToken][e.msg.sender];
    mathint fees = transferBalanceChange[marketParams.loanToken][referralFeeRecipient];

    // Also check that every native token sent is wrapped.
    assert e.msg.value == wrappedAssets;
    assert spent == suppliedAssets + fees;
}

rule withdrawDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 withdrawAssets, uint256 withdrawShares, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require withdrawnAssets == 0 && penaltyAssets == 0, "only count operations of the interaction";
    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, withdrawShares, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[marketParams.loanToken][e.msg.sender];
    mathint fees = transferBalanceChange[marketParams.loanToken][referralFeeRecipient];

    assert withdrawnAssets == received + penaltyAssets + fees;
}

rule migrateBorrowPositionDoesntLoseTokens(env e, BlueBundlesV1.MarketParams sourceMarketParams, BlueBundlesV1.MarketParams destMarketParams, uint256 maxLtv, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require borrowedAssets == 0 && repaidAssets == 0 && suppliedCollateral == 0 && withdrawnCollateral == 0 && penaltyAssets == 0, "only count operations of the interaction";
    blueBundlesV1MigrateBorrowPosition(e, sourceMarketParams, destMarketParams, maxLtv, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint fees = transferBalanceChange[destMarketParams.loanToken][referralFeeRecipient];

    assert transferBalanceChange[destMarketParams.loanToken][e.msg.sender] == 0 && transferBalanceChange[destMarketParams.collateralToken][e.msg.sender] == 0;
    assert borrowedAssets == repaidAssets + penaltyAssets + fees;
    assert suppliedCollateral == withdrawnCollateral;
}
