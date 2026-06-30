// SPDX-License-Identifier: GPL-2.0-or-later

// No token residue: every entry point preserves the bundler's balance of every token (delta 0).
// Stated as preservation, not "== 0", so a donation is irrelevant.
// Scope: the four direct entry points including their type(uint256).max full close; migrateBorrowPosition/onMorphoRepay excluded (callback).
// Morpho is abstract, modeled by its token moves below; its own correctness is verified upstream.
//
// Each Morpho summary is a property already proven in morpho-blue's certora suite (named inline).
// Two assumptions shared with that suite:
//   - no in-block accrual: morpho-blue's AssetsAccounting rules require lastUpdate == block.timestamp.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing): Transfer.spec's dispatch set, matching the
//     token restriction in BlueBundles' header.

definition WAD() returns mathint = 10 ^ 18;

// The bundler's balance of every token, updated on every transfer that touches it.
persistent ghost mapping(address => mathint) bundlesBalance;

methods {
    // ERC20: the bundler's own transfers move bundlesBalance.

    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransfer(calledContract, e.msg.sender, to, amt) expect(bool);
    function _.approve(address, uint256) external => cvlTrue() expect(bool); // well-behaved ERC20: approve returns true
    function _.permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external => NONDET; // sets allowance only

    // Morpho: pull on supply/repay/supplyCollateral, send on borrow/withdraw/withdrawCollateral.

    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => cvlMorphoPull(marketParams.loanToken, assets) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => cvlMorphoRepay(marketParams.loanToken, assets, shares) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => cvlMorphoPullVoid(marketParams.collateralToken, assets) expect void;
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => cvlMorphoSend(marketParams.loanToken, assets, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => cvlMorphoWithdraw(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => cvlMorphoSendVoid(marketParams.collateralToken, assets, receiver) expect void;
}

function cvlTrue() returns bool {
    return true;
}

// ERC20 transferFrom moves balances by ±amt, reverting iff insufficient.
// Justified by morpho-blue Transfer.spec: checkTransferFromSummary, transferFromRevertCondition.
function cvlTransferFrom(address token, address from, address to, uint256 amt) returns bool {
    if (from == currentContract) bundlesBalance[token] = require_uint256(bundlesBalance[token] - amt);
    if (to == currentContract) bundlesBalance[token] = bundlesBalance[token] + amt;
    return true;
}

// ERC20 transfer counterpart. Justified by morpho-blue Transfer.spec: checkTransferSummary,
// transferRevertCondition.
function cvlTransfer(address token, address from, address to, uint256 amt) returns bool {
    if (from == currentContract) bundlesBalance[token] = require_uint256(bundlesBalance[token] - amt);
    if (to == currentContract) bundlesBalance[token] = bundlesBalance[token] + amt;
    return true;
}

// Justified by morpho-blue supplyAssetsAccounting.
function cvlMorphoPull(address token, uint256 assets) returns (uint256, uint256) {
    bundlesBalance[token] = require_uint256(bundlesBalance[token] - assets);
    return (assets, 0);
}

// supplyCollateral pulls exactly `assets`. Justified by morpho-blue supplyCollateralAssetsAccounting
// (proven as an equality: collateralBefore + assets == collateralAfter).
function cvlMorphoPullVoid(address token, uint256 assets) {
    bundlesBalance[token] = require_uint256(bundlesBalance[token] - assets);
}

// Justified by morpho-blue repayAssetsAccounting.
function cvlMorphoRepay(address token, uint256 assets, uint256 shares) returns (uint256, uint256) {
    uint256 pulled;
    bundlesBalance[token] = require_uint256(bundlesBalance[token] - pulled);
    return (pulled, 0);
}

// borrow sends `assets` to `receiver`. Justified by morpho-blue borrowAssetsAccounting.
function cvlMorphoSend(address token, uint256 assets, address receiver) returns (uint256, uint256) {
    if (receiver == currentContract) bundlesBalance[token] = bundlesBalance[token] + assets;
    return (assets, 0);
}

// withdraw sends the returned amount to `receiver` (the bundler forwards that same value, so any
// amount cancels); nondet on a full close by shares. Justified by morpho-blue withdrawAssetsAccounting.
function cvlMorphoWithdraw(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    uint256 sent;
    if (receiver == currentContract) bundlesBalance[token] = bundlesBalance[token] + sent;
    return (sent, 0);
}

// withdrawCollateral sends `assets` to `receiver`. Justified by morpho-blue withdrawCollateralAssetsAccounting.
function cvlMorphoSendVoid(address token, uint256 assets, address receiver) {
    if (receiver == currentContract) bundlesBalance[token] = bundlesBalance[token] + assets;
}

rule supplyPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlesBalance[token];
    blueBundlesV1Supply(e, marketParams, assets, onBehalf, permit, feePct, recipient, deadline);
    assert bundlesBalance[token] == before;
}

rule withdrawPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 withdrawAssets, address onBehalf, address receiver, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlesBalance[token];
    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, onBehalf, receiver, feePct, recipient, deadline);
    assert bundlesBalance[token] == before;
}

rule supplyCollateralAndBorrowPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAmount, uint256 borrowAssets, uint256 maxLtv, address onBehalf, address receiver, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlesBalance[token];
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAmount, borrowAssets, maxLtv, onBehalf, receiver, permit, feePct, recipient, deadline);
    assert bundlesBalance[token] == before;
}

// Covers both the finite-repay and the type(uint256).max full-close branches.
rule repayAndWithdrawCollateralPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 maxRepayAssets, uint256 withdrawCollateralAssets, uint256 maxLtv, address onBehalf, address receiver, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlesBalance[token];
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, assets, maxRepayAssets, withdrawCollateralAssets, maxLtv, onBehalf, receiver, permit, feePct, recipient, deadline);
    assert bundlesBalance[token] == before;
}
