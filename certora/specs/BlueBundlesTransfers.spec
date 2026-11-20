// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Over-approximate checks and arithmetic, since amounts are tracked through their effects.
    function BlueBundlesV1.requireMaxLtv(BlueBundlesV1.MarketParams memory, address, uint256) internal => NONDET;
    function UtilsLib.mulDivDown(uint256, uint256, uint256) internal returns (uint256) => NONDET;

    // Functional summary, so that the penalties computed by the bundler are the ones paid to the public allocator.
    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpGhost(x, y, d);

    // Public allocator modeling, where only the penalty amount is modeled.
    function _.allocateFromIdle(address, address, BlueBundlesV1.MarketParams, uint128 assets, uint64 penalty) external => summaryPayPenalty(assets, penalty) expect void;
    function _.reallocate(address, address, BlueBundlesV1.MarketParams, address, BlueBundlesV1.MarketParams, uint128 assets, uint64 penalty) external => summaryPayPenalty(assets, penalty) expect void;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransferFrom(token, currentContract, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => summarySafeTransferFrom(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(e.msg.value) expect void;
    function _.withdraw(uint256 amount) external => summaryUnwrapNative(amount) expect void;

    // Blue modeling, where only callbacks and amounts are modeled, since Blue's transfers are not in the body of the bundle functions.
    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(assets) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address) external => summaryWithdraw(assets) expect(uint256, uint256);
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address) external => summaryBorrow(assets) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(calledContract, assets, data) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(assets) expect void;
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address) external => summaryWithdrawCollateral(assets) expect void;
    function _.flashLoan(address, uint256 assets, bytes data) external => summaryFlashLoan(calledContract, assets, data) expect void;
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization, BlueBundlesV1.Signature) external => NONDET;
}

/// HELPERS ///

// Net amount transferred to each account during the interaction, per token, which is not the token balance.
persistent ghost mapping(address => mapping(address => mathint)) transferBalanceChange;

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

function summarySupply(uint256 assets) returns (uint256, uint256) {
    suppliedAssets = suppliedAssets + assets;
    uint256 shares;
    return (assets, shares);
}

function summaryWithdraw(uint256 assets) returns (uint256, uint256) {
    uint256 withdrawn;
    require assets > 0 => withdrawn == assets, "withdraw exact assets";
    withdrawnAssets = withdrawnAssets + withdrawn;
    uint256 shares;
    return (withdrawn, shares);
}

function summaryBorrow(uint256 assets) returns (uint256, uint256) {
    borrowedAssets = borrowedAssets + assets;
    uint256 shares;
    return (assets, shares);
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
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require marketParams.loanToken != marketParams.collateralToken, "assume different loan and collateral tokens for simpler accounting";
    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets == 0 && borrowedAssets == 0 && suppliedCollateral == 0 && penaltyAssets == 0, "only count operations of the interaction";
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, borrowAssets, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    // The native value sent is spent in the collateral token, which it is wrapped into.
    mathint wrapped = token == marketParams.collateralToken ? e.msg.value : 0;
    mathint received = transferBalanceChange[token][e.msg.sender];
    mathint sent = wrapped - received;
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint borrowed = borrowedAssets;
    mathint supplied = suppliedCollateral;
    mathint penalties = penaltyAssets;

    assert wrappedAssets == e.msg.value;
    assert token == marketParams.loanToken => borrowed == received + penalties + fees;
    assert token == marketParams.collateralToken => sent == supplied;
    assert token != marketParams.loanToken && token != marketParams.collateralToken => received == 0;
    assert token != marketParams.loanToken => fees == 0;
}

rule repayAndWithdrawCollateralDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 repayAssets, uint256 repayShares, uint256 maxRepayAssets, uint256 collateralAssets, uint256 maxLtv, TokenLib.TokenPermit loanTokenPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets == 0 && unwrappedAssets == 0 && repaidAssets == 0, "only count operations of the interaction";
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, repayAssets, repayShares, maxRepayAssets, collateralAssets, maxLtv, loanTokenPermit, signedAuthorization, referralFeePct, referralFeeRecipient, deadline);

    // The native value sent is spent in the loan token, which it is wrapped into.
    mathint sent = token == marketParams.loanToken ? e.msg.value : 0;
    mathint spent = sent - transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint unwrapped = unwrappedAssets;
    mathint repaid = repaidAssets;

    assert wrappedAssets == e.msg.value;
    assert token == marketParams.loanToken => spent == repaid + unwrapped + fees;
    assert token != marketParams.loanToken => spent == 0 && fees == 0;
}

rule supplyDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, TokenLib.TokenPermit loanTokenPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets == 0 && suppliedAssets == 0, "only count operations of the interaction";
    blueBundlesV1Supply(e, marketParams, assets, loanTokenPermit, referralFeePct, referralFeeRecipient, deadline);

    // The native value sent is spent in the loan token, which it is wrapped into.
    mathint spent = (token == marketParams.loanToken ? e.msg.value : 0) - transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint supplied = suppliedAssets;

    assert wrappedAssets == e.msg.value;
    assert token == marketParams.loanToken => spent == supplied + fees;
    assert token != marketParams.loanToken => spent == 0 && fees == 0;
}

rule withdrawDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 withdrawAssets, uint256 withdrawShares, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require withdrawnAssets == 0 && penaltyAssets == 0, "only count operations of the interaction";
    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, withdrawShares, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint withdrawn = withdrawnAssets;
    mathint penalties = penaltyAssets;

    assert token == marketParams.loanToken => withdrawn == received + penalties + fees;
    assert token != marketParams.loanToken => received == 0 && fees == 0;
}

rule migrateBorrowPositionDoesntLoseTokens(env e, BlueBundlesV1.MarketParams sourceMarketParams, BlueBundlesV1.MarketParams destMarketParams, uint256 maxLtv, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require borrowedAssets == 0 && repaidAssets == 0 && suppliedCollateral == 0 && withdrawnCollateral == 0 && penaltyAssets == 0, "only count operations of the interaction";
    blueBundlesV1MigrateBorrowPosition(e, sourceMarketParams, destMarketParams, maxLtv, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint borrowed = borrowedAssets;
    mathint repaid = repaidAssets;
    mathint penalties = penaltyAssets;

    assert transferBalanceChange[token][e.msg.sender] == 0;
    assert token == destMarketParams.loanToken => borrowed == repaid + penalties + fees;
    assert suppliedCollateral == withdrawnCollateral;
    assert token != destMarketParams.loanToken => fees == 0;
}
