// SPDX-License-Identifier: GPL-2.0-or-later

// Proves no ERC20 residue and no spending of pre-existing native tokens.
// Assumes standard ERC20 accounting and no external callbacks or donations to the bundler.

methods {
    // ERC20 transfers.
    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amt) expect(bool);

    // Permit2 transfers.
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => summaryPermit2Transfer(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount) expect void;

    // Morpho transfers.
    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(marketParams.loanToken, assets, shares) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(marketParams.loanToken, data) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(marketParams.collateralToken, assets) expect void;
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, receiver) expect(uint256, uint256);
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => summaryWithdrawCollateral(marketParams.collateralToken, assets, receiver) expect void;
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(token, assets, data) expect void;

    // The public allocator is linked; unresolved downstream calls use AUTO.

    // Wrapped native transfers.
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;
    function _.withdraw(uint256 amount) external => summaryUnwrapNative(calledContract, amount) expect void;

    // Balance-neutral calls.
    function _.setAuthorizationWithSig(BlueBundlesV1.Authorization authorization, BlueBundlesV1.Signature signature) external => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // The bundler's penalty total (UtilsLib) and the public allocator's pulls (MathLib) share one uninterpreted
    // function, so their equality follows by congruence instead of nonlinear arithmetic.
    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpG(x, y, d);
    function MathLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => mulDivUpG(x, y, d);

    // The public allocator's penalty pull is a low-level token.call whose sighash the prover cannot resolve
    // statically, so the _.transferFrom wildcard misses it; summarize the library function instead.
    function SafeERC20Lib.safeTransferFrom(address token, address from, address to, uint256 value) internal => cvlSafeTransferFrom(token, from, to, value);
}

// Uninterpreted rounding-up mulDiv shared by both implementations.
persistent ghost mulDivUpG(uint256, uint256, uint256) returns uint256;

// The public allocator can never register the bundler as a vault (its setters require isVaultV2), so a reallocation
// whose vault is the bundler always reverts on InactiveAdapter; the linked allocator's symbolic storage cannot know
// this, so exclude it (up to loop_iter elements).
function reallocationsAssumptions(BlueBundlesV1.PublicAllocations[] reallocations) {
    require reallocations.length <= 3, "loop bound";
    require reallocations.length > 0 => reallocations[0].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 1 => reallocations[1].vault != currentContract, "bundler is not a vault";
    require reallocations.length > 2 => reallocations[2].vault != currentContract, "bundler is not a vault";
}

// Bundler ERC20 balances.
persistent ghost mapping(address => mathint) bundlerBalance;

// Native received from wrapped-native withdrawals.
persistent ghost mathint unwrappedNative;

// Successful native outflow from the bundler.
persistent ghost mathint nativeSentByBundler;

hook CALL(uint g, address target, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint success {
    if (executingContract == currentContract && success != 0) {
        nativeSentByBundler = nativeSentByBundler + value;
    }
}

function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    return true;
}

function cvlSafeTransferFrom(address token, address from, address to, uint256 value) {
    cvlTransferFrom(token, from, to, value);
}

function summaryPermit2Transfer(address token, address from, address to, uint256 amount) {
    cvlTransferFrom(token, from, to, amount);
}

function summarySupply(address token, uint256 assets, uint256 shares) returns (uint256, uint256) {
    assert shares == 0;
    bundlerBalance[token] = bundlerBalance[token] - assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryRepay(address token, bytes data) returns (uint256, uint256) {
    uint256 assets;
    uint256 shares;
    if (data.length > 0) {
        env callbackEnv;
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

function summaryFlashLoan(address token, uint256 assets, bytes data) {
    bundlerBalance[token] = bundlerBalance[token] + assets;
    env callbackEnv;
    onMorphoFlashLoan(callbackEnv, assets, data);
    bundlerBalance[token] = bundlerBalance[token] - assets;
}

function summaryWrapNative(address token, uint256 value) {
    bundlerBalance[token] = bundlerBalance[token] + value;
}

function summaryUnwrapNative(address token, uint256 amount) {
    bundlerBalance[token] = bundlerBalance[token] - amount;
    unwrappedNative = unwrappedNative + amount;
}

rule supplyPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 maxSharePriceE27, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "external caller";
    require recipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    mathint nativeReceivedBefore = unwrappedNative;
    blueBundlesV1Supply(e, marketParams, assets, maxSharePriceE27, permit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore - (unwrappedNative - nativeReceivedBefore) == e.msg.value;
}

rule withdrawPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 withdrawAssets, uint256 withdrawShares, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "external caller";
    require recipient != currentContract, "no fee residue";
    reallocationsAssumptions(reallocations);

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    mathint nativeReceivedBefore = unwrappedNative;
    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, withdrawShares, signedAuthorization, reallocations, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore - (unwrappedNative - nativeReceivedBefore) == e.msg.value;
}

rule supplyCollateralAndBorrowPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAmount, uint256 borrowAssets, uint256 minSharePriceE27, uint256 maxLtv, TokenLib.TokenPermit permit, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "external caller";
    require recipient != currentContract, "no fee residue";
    reallocationsAssumptions(reallocations);

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    mathint nativeReceivedBefore = unwrappedNative;
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAmount, borrowAssets, minSharePriceE27, maxLtv, permit, signedAuthorization, reallocations, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore - (unwrappedNative - nativeReceivedBefore) == e.msg.value;
}

rule repayAndWithdrawCollateralPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, uint256 maxRepayAssets, uint256 maxSharePriceE27, uint256 withdrawCollateralAssets, uint256 maxLtv, TokenLib.TokenPermit permit, BlueBundlesV1.SignedAuthorization signedAuthorization, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "external caller";
    require recipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    mathint nativeReceivedBefore = unwrappedNative;
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, assets, shares, maxRepayAssets, maxSharePriceE27, withdrawCollateralAssets, maxLtv, permit, signedAuthorization, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore - (unwrappedNative - nativeReceivedBefore) == e.msg.value;
}

rule migrateBorrowPositionPreservesBalance(env e, BlueBundlesV1.MarketParams sourceMarketParams, BlueBundlesV1.MarketParams destMarketParams, uint256 sourceMaxSharePriceE27, uint256 destMinSharePriceE27, uint256 maxLtv, BlueBundlesV1.SignedAuthorization signedAuthorization, BlueBundlesV1.PublicAllocations[] reallocations, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "external caller";
    require recipient != currentContract, "no fee residue";
    reallocationsAssumptions(reallocations);

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    mathint nativeReceivedBefore = unwrappedNative;
    blueBundlesV1MigrateBorrowPosition(e, sourceMarketParams, destMarketParams, sourceMaxSharePriceE27, destMinSharePriceE27, maxLtv, signedAuthorization, reallocations, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore - (unwrappedNative - nativeReceivedBefore) == e.msg.value;
}
