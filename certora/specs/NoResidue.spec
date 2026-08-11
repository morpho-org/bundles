// SPDX-License-Identifier: GPL-2.0-or-later

// No token residue: every entry point preserves the bundler's balance of every token (delta 0).
// Scope: all entry points.
// Assumptions shared with that suite:
//   - no bundler donations: the receiver and the recipient are different from the bundler.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing): matching the token restriction in BlueBundles' header.
//   - the bundler is not the wrapped-native token.
//   - the public allocator and its configured vault/adapters do not call back into or donate to the bundler.

methods {
    // ERC20: the bundler's own transfers move bundlerBalance.
    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amt) expect(bool);

    // Morpho: pull on supply/repay/supplyCollateral, send on borrow/withdraw/withdrawCollateral.
    // Also assumes that the Morpho Blue address is different from the bundler's.
    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(marketParams.loanToken, assets, shares) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(calledContract, marketParams.loanToken, data) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(marketParams.collateralToken, assets) expect void;
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, receiver) expect(uint256, uint256);
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => summaryWithdrawCollateral(marketParams.collateralToken, assets, receiver) expect void;

    // Public allocator: the penalty getter is nondeterministic, while allocation calls only spend the attached native value from the bundler.
    // Their state changes are irrelevant to the residue property; NONDET encodes the no-callback/no-donation assumption above.
    function _.vaultData(address vault) external => NONDET;
    function _.reallocate(address vault, address deallocateAdapter, BlueBundlesV1.MarketParams deallocateMarketParams, address allocateAdapter, BlueBundlesV1.MarketParams allocateMarketParams, uint128 assets) external => NONDET;
    function _.allocateFromIdle(address vault, address adapter, BlueBundlesV1.MarketParams marketParams, uint128 assets) external => NONDET;

    // Model the WNative contract's deposit and withdraw behavior: mints on deposit and burns on withdraw.
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;
    function _.withdraw(uint256 amount) external => summaryUnwrapNative(calledContract, amount) expect void;

    // Summarized without state changes, as the HAVOC_ECF allows the callee to credit native tokens to the caller.
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // Since calls are not summarized as havoc all by default, it is assumed that other calls don't change the bundler's balance of any token.
}

definition WAD() returns mathint = 10 ^ 18;

// The bundler's balance of every token, updated on every transfer that touches it.
persistent ghost mapping(address => mathint) bundlerBalance;

// Native sent to the bundler by the wrapped-native contract on withdraw: summaries cannot write nativeBalances, so it is tracked separately and added to the bundler's native balance in the rules.
persistent ghost mathint unwrappedNative;

definition bundlerNativeBalance() returns mathint = nativeBalances[currentContract] + unwrappedNative;

// well-behaved ERC20: transfers move balances by the amount.
function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    return true;
}

function summarySupply(address token, uint256 assets, uint256 shares) returns (uint256, uint256) {
    assert shares == 0;
    bundlerBalance[token] = bundlerBalance[token] - assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryRepay(address blue, address token, bytes data) returns (uint256, uint256) {
    uint256 assets;
    uint256 shares;
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == blue;
        onMorphoRepay(callbackEnv, assets, data);
    }
    bundlerBalance[token] = bundlerBalance[token] - assets;
    return (assets, shares);
}

function summarySupplyCollateral(address token, uint256 assets) {
    bundlerBalance[token] = bundlerBalance[token] - assets;
}

function summaryBorrow(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    assert shares == 0;
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryWithdraw(address token, address receiver) returns (uint256, uint256) {
    uint256 assets;
    uint256 shares;
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
    return (assets, shares);
}

function summaryWithdrawCollateral(address token, uint256 assets, address receiver) {
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
}

function summaryWrapNative(address token, uint256 value) {
    bundlerBalance[token] = bundlerBalance[token] + value;
}

function summaryUnwrapNative(address token, uint256 amount) {
    bundlerBalance[token] = bundlerBalance[token] - amount;
    unwrappedNative = unwrappedNative + amount;
}

rule supplyPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 maxSharePriceE27, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";
    require marketParams.loanToken != currentContract, "the bundler is not the wrapped-native token";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = bundlerNativeBalance();
    blueBundlesV1Supply(e, marketParams, assets, maxSharePriceE27, permit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert bundlerNativeBalance() == nativeBefore;
}

rule withdrawPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicReallocation[] reallocations, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";
    require PUBLIC_ALLOCATOR(e) != currentContract, "the public allocator is not the bundler";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = bundlerNativeBalance();
    blueBundlesV1Withdraw(e, marketParams, assets, shares, signedAuthorization, reallocations, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert bundlerNativeBalance() == nativeBefore;
}

rule supplyCollateralAndBorrowPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAmount, uint256 borrowAssets, uint256 minSharePriceE27, uint256 maxLtv, TokenLib.TokenPermit permit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicReallocation[] reallocations, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";
    require marketParams.collateralToken != currentContract, "the bundler is not the collateral token";
    require PUBLIC_ALLOCATOR(e) != currentContract, "the public allocator is not the bundler";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = bundlerNativeBalance();
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAmount, borrowAssets, minSharePriceE27, maxLtv, permit, signedAuthorization, reallocations, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert bundlerNativeBalance() == nativeBefore;
}

rule repayAndWithdrawCollateralPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, uint256 maxRepayAssets, uint256 maxSharePriceE27, uint256 withdrawCollateralAssets, uint256 maxLtv, TokenLib.TokenPermit permit, BlueBundlesV1.SignedAuthorization signedAuthorization, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";
    require marketParams.loanToken != currentContract, "the bundler is not the wrapped-native token";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = bundlerNativeBalance();
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, assets, shares, maxRepayAssets, maxSharePriceE27, withdrawCollateralAssets, maxLtv, permit, signedAuthorization, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert bundlerNativeBalance() == nativeBefore;
}

rule migrateBorrowPositionPreservesBalance(env e, BlueBundlesV1.MarketParams sourceMarketParams, BlueBundlesV1.MarketParams destMarketParams, uint256 sourceMaxSharePriceE27, uint256 destMinSharePriceE27, uint256 maxLtv, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicReallocation[] reallocations, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";
    require sourceMarketParams.loanToken != currentContract, "the bundler is not the loan token";
    require sourceMarketParams.collateralToken != currentContract, "the bundler is not the collateral token";
    require BLUE(e) != currentContract, "Blue is not the bundler";
    require PUBLIC_ALLOCATOR(e) != currentContract, "the public allocator is not the bundler";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = bundlerNativeBalance();
    blueBundlesV1MigrateBorrowPosition(e, sourceMarketParams, destMarketParams, sourceMaxSharePriceE27, destMinSharePriceE27, maxLtv, signedAuthorization, reallocations, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert bundlerNativeBalance() == nativeBefore;
}
