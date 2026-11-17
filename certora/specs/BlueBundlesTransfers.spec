// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Over-approximate checks and arithmetic, since amounts are tracked through their effects.
    function BlueBundlesV1.requireMaxLtv(BlueBundlesV1.MarketParams memory, address, uint256) internal => NONDET;
    function UtilsLib.mulDivDown(uint256, uint256, uint256) internal returns (uint256) => NONDET;
    function UtilsLib.mulDivUp(uint256, uint256, uint256) internal returns (uint256) => NONDET;

    // Public allocator penalties are pulled from the bundler, whose balance is checked in NoResidue, so ignore them.
    function _.allocateFromIdle(address, address, BlueBundlesV1.MarketParams, uint256, uint256) external => NONDET;
    function _.reallocate(address, address, BlueBundlesV1.MarketParams, address, BlueBundlesV1.MarketParams, uint256, uint256) external => NONDET;
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization, BlueBundlesV1.Signature) external => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => summarySafeTransferFrom(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;
    function _.withdraw(uint256 amount) external => summaryUnwrapNative(calledContract, amount) expect void;

    // Blue modeling.
    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(marketParams.loanToken, assets) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, assets, receiver) expect(uint256, uint256);
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, receiver) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(calledContract, marketParams.loanToken, assets, data) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(marketParams.collateralToken, assets) expect void;
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => summaryWithdrawCollateral(marketParams.collateralToken, assets, receiver) expect void;
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(calledContract, token, assets, data) expect void;
}

/// HELPERS ///

// Net amount transferred to each account during the interaction, per token, which is not the token balance.
persistent ghost mapping(address => mapping(address => mathint)) transferBalanceChange;

persistent ghost mapping(address => mathint) wrappedAssets;

persistent ghost mapping(address => mathint) unwrappedAssets;

persistent ghost mapping(address => mathint) suppliedAssets;

persistent ghost mapping(address => mathint) withdrawnAssets;

persistent ghost mapping(address => mathint) borrowedAssets;

persistent ghost mapping(address => mathint) repaidAssets;

persistent ghost mapping(address => mathint) suppliedCollateral;

persistent ghost mapping(address => mathint) withdrawnCollateral;

persistent ghost mapping(address => mathint) flashLoanedAssets;

function increaseBalance(address token, address account, uint256 amount) {
    transferBalanceChange[token][account] = transferBalanceChange[token][account] + amount;
}

function decreaseBalance(address token, address account, uint256 amount) {
    transferBalanceChange[token][account] = transferBalanceChange[token][account] - amount;
}

function summarySafeTransfer(address token, address to, uint256 amount) {
    summarySafeTransferFrom(token, currentContract, to, amount);
}

function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    decreaseBalance(token, from, amount);
    increaseBalance(token, to, amount);
}

function summaryWrapNative(address token, uint256 value) {
    increaseBalance(token, currentContract, value);
    wrappedAssets[token] = wrappedAssets[token] + value;
}

function summaryUnwrapNative(address token, uint256 amount) {
    decreaseBalance(token, currentContract, amount);
    unwrappedAssets[token] = unwrappedAssets[token] + amount;
}

function summarySupply(address loanToken, uint256 assets) returns (uint256, uint256) {
    decreaseBalance(loanToken, currentContract, assets);
    suppliedAssets[loanToken] = suppliedAssets[loanToken] + assets;
    uint256 shares;
    return (assets, shares);
}

function summaryWithdraw(address loanToken, uint256 assets, address receiver) returns (uint256, uint256) {
    uint256 withdrawn;
    require assets > 0 => withdrawn == assets, "withdraw exact assets";
    increaseBalance(loanToken, receiver, withdrawn);
    withdrawnAssets[loanToken] = withdrawnAssets[loanToken] + withdrawn;
    uint256 shares;
    return (withdrawn, shares);
}

function summaryBorrow(address loanToken, uint256 assets, address receiver) returns (uint256, uint256) {
    increaseBalance(loanToken, receiver, assets);
    borrowedAssets[loanToken] = borrowedAssets[loanToken] + assets;
    uint256 shares;
    return (assets, shares);
}

function summaryRepay(address blue, address loanToken, uint256 assets, bytes data) returns (uint256, uint256) {
    uint256 repaid;
    require assets > 0 => repaid == assets, "repay exact assets";
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == blue, "Blue calls back";
        onMorphoRepay(callbackEnv, repaid, data);
    }
    decreaseBalance(loanToken, currentContract, repaid);
    repaidAssets[loanToken] = repaidAssets[loanToken] + repaid;
    uint256 shares;
    return (repaid, shares);
}

function summarySupplyCollateral(address collateralToken, uint256 assets) {
    decreaseBalance(collateralToken, currentContract, assets);
    suppliedCollateral[collateralToken] = suppliedCollateral[collateralToken] + assets;
}

function summaryWithdrawCollateral(address collateralToken, uint256 assets, address receiver) {
    increaseBalance(collateralToken, receiver, assets);
    withdrawnCollateral[collateralToken] = withdrawnCollateral[collateralToken] + assets;
}

function summaryFlashLoan(address blue, address token, uint256 assets, bytes data) {
    increaseBalance(token, currentContract, assets);
    env callbackEnv;
    require callbackEnv.msg.sender == blue, "Blue calls back";
    onMorphoFlashLoan(callbackEnv, assets, data);
    decreaseBalance(token, currentContract, assets);
    flashLoanedAssets[token] = flashLoanedAssets[token] + assets;
}

/// RULES ///

rule supplyCollateralAndBorrowDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAssets, uint256 borrowAssets, uint256 maxLtv, TokenLib.TokenPermit collateralPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets[token] == 0 && borrowedAssets[token] == 0 && suppliedCollateral[token] == 0 && flashLoanedAssets[token] == 0, "only count operations of the interaction";
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAssets, borrowAssets, maxLtv, collateralPermit, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint wrapped = wrappedAssets[token];
    mathint borrowed = borrowedAssets[token];
    mathint supplied = suppliedCollateral[token];
    mathint flashLoaned = flashLoanedAssets[token];

    assert received == borrowed - flashLoaned - fees + wrapped - supplied;
    assert token != marketParams.loanToken => fees == 0;
}

rule repayAndWithdrawCollateralDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 repayAssets, uint256 repayShares, uint256 maxRepayAssets, uint256 collateralAssets, uint256 maxLtv, TokenLib.TokenPermit loanTokenPermit, BlueBundlesV1.SignedAuthorization signedAuthorization, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets[token] == 0 && unwrappedAssets[token] == 0 && repaidAssets[token] == 0 && withdrawnCollateral[token] == 0, "only count operations of the interaction";
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, repayAssets, repayShares, maxRepayAssets, collateralAssets, maxLtv, loanTokenPermit, signedAuthorization, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint wrapped = wrappedAssets[token];
    mathint unwrapped = unwrappedAssets[token];
    mathint repaid = repaidAssets[token];
    mathint withdrawn = withdrawnCollateral[token];

    assert received == withdrawn - repaid - fees + wrapped - unwrapped;
    assert token != marketParams.loanToken => fees == 0;
}

rule supplyDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, TokenLib.TokenPermit loanTokenPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require wrappedAssets[token] == 0 && suppliedAssets[token] == 0, "only count operations of the interaction";
    blueBundlesV1Supply(e, marketParams, assets, loanTokenPermit, referralFeePct, referralFeeRecipient, deadline);

    mathint spent = -transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint wrapped = wrappedAssets[token];
    mathint supplied = suppliedAssets[token];

    assert spent + wrapped == supplied + fees;
    assert token != marketParams.loanToken => spent == 0 && fees == 0;
}

rule withdrawDoesntLoseTokens(env e, BlueBundlesV1.MarketParams marketParams, uint256 withdrawAssets, uint256 withdrawShares, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require withdrawnAssets[token] == 0 && flashLoanedAssets[token] == 0, "only count operations of the interaction";
    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, withdrawShares, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint withdrawn = withdrawnAssets[token];
    mathint flashLoaned = flashLoanedAssets[token];

    assert received == withdrawn - flashLoaned - fees;
    assert token != marketParams.loanToken => received == 0 && fees == 0;
}

rule migrateBorrowPositionDoesntLoseTokens(env e, BlueBundlesV1.MarketParams sourceMarketParams, BlueBundlesV1.MarketParams destMarketParams, uint256 maxLtv, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since BlueBundlesV1 never compares these addresses, except to BLUE whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    require borrowedAssets[token] == 0 && repaidAssets[token] == 0 && suppliedCollateral[token] == 0 && withdrawnCollateral[token] == 0 && flashLoanedAssets[token] == 0, "only count operations of the interaction";
    blueBundlesV1MigrateBorrowPosition(e, sourceMarketParams, destMarketParams, maxLtv, signedAuthorization, reallocations, referralFeePct, referralFeeRecipient, deadline);

    mathint fees = transferBalanceChange[token][referralFeeRecipient];
    mathint borrowed = borrowedAssets[token];
    mathint repaid = repaidAssets[token];
    mathint flashLoaned = flashLoanedAssets[token];

    assert transferBalanceChange[token][e.msg.sender] == 0;
    assert fees == borrowed - repaid - flashLoaned;
    assert suppliedCollateral[token] == withdrawnCollateral[token];
    assert token != destMarketParams.loanToken => fees == 0;
}
