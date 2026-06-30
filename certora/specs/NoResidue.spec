// SPDX-License-Identifier: GPL-2.0-or-later
// No token residue: every entry point preserves the bundler's balance of every token (delta 0).
// Stated as preservation, not "== 0", so a donation is irrelevant. Scope: the four direct entry
// points incl. their type(uint256).max full close; refinance/onMorphoRepay excluded (callback).
// Morpho is abstract, modeled by its token moves below; its own correctness is verified upstream.
//
// Each Morpho summary is a property already proven in morpho-blue's certora suite (named inline).
// Two assumptions shared with that suite:
//   - no in-block accrual: morpho-blue's AssetsAccounting rules require lastUpdate == block.timestamp.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing): Transfer.spec's dispatch set, matching the
//     token restriction in BlueBundles' header.

definition WAD() returns mathint = 1000000000000000000;

// The bundler's balance of every token, updated on every transfer that touches it.
persistent ghost mapping(address => mathint) bundlerBal;
// repay-by-shares pulls == expectedBorrowAssets in the same block (accrual invariance).
persistent ghost mathint gRepayShareAssets;
// withdraw-by-shares returns a nondet amount on a full supply close.
persistent ghost mathint gWithdrawShareAssets;

methods {
    // ERC20: the bundler's own transfers move bundlerBal.
    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect bool;
    function _.transfer(address to, uint256 amt) external with (env e) => cvlTransfer(calledContract, e.msg.sender, to, amt) expect bool;
    function _.approve(address, uint256) external => cvlTrue() expect bool; // well-behaved ERC20: approve returns true
    function _.allowance(address, address) external => NONDET;              // conservative: arbitrary, moves no tokens
    function _.permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external => NONDET; // sets allowance only

    // Morpho: pull on supply/repay/supplyCollateral, send on borrow/withdraw/withdrawCollateral.
    function _.isAuthorized(address, address) external => NONDET; // conservative: arbitrary, moves no tokens
    function _.position(BlueBundles.Id, address) external => NONDET; // conservative: arbitrary shares/collateral
    function _.price() external => NONDET;                          // conservative: refinance-only, unreached here
    function _.supply(BlueBundles.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data) external => cvlMorphoPull(mp.loanToken, assets) expect (uint256, uint256);
    function _.supplyCollateral(BlueBundles.MarketParams mp, uint256 assets, address onBehalf, bytes data) external => cvlMorphoPullVoid(mp.collateralToken, assets) expect void;
    function _.repay(BlueBundles.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data) external => cvlMorphoRepay(mp.loanToken, assets, shares) expect (uint256, uint256);
    function _.borrow(BlueBundles.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver) external => cvlMorphoSend(mp.loanToken, assets, receiver) expect (uint256, uint256);
    function _.withdraw(BlueBundles.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver) external => cvlMorphoWithdraw(mp.loanToken, assets, shares, receiver) expect (uint256, uint256);
    function _.withdrawCollateral(BlueBundles.MarketParams mp, uint256 assets, address onBehalf, address receiver) external => cvlMorphoSendVoid(mp.collateralToken, assets, receiver) expect void;

    // Tie the full-close pull to the quote (accrual invariance).
    function MorphoBalancesLib.expectedBorrowAssets(address, BlueBundles.MarketParams memory, address) internal returns (uint256) => cvlExpectedBorrow();
}

function cvlTrue() returns bool { return true; }

// expectedBorrowAssets == the repay-by-shares pull: both are toAssetsUp(borrowShares, accruedTotals)
// over the same in-block totals; morpho-blue repayAssetsAccounting backs the >= direction.
function cvlExpectedBorrow() returns uint256 { return require_uint256(gRepayShareAssets); }

// ERC20 transferFrom moves balances by ±amt, reverting iff insufficient.
// Justified by morpho-blue Transfer.spec: checkTransferFromSummary, transferFromRevertCondition.
function cvlTransferFrom(address token, address from, address to, uint256 amt) returns bool {
    if (from == currentContract) bundlerBal[token] = require_uint256(bundlerBal[token] - amt);
    if (to == currentContract)   bundlerBal[token] = bundlerBal[token] + amt;
    return true;
}

// ERC20 transfer counterpart. Justified by morpho-blue Transfer.spec: checkTransferSummary,
// transferRevertCondition.
function cvlTransfer(address token, address from, address to, uint256 amt) returns bool {
    if (from == currentContract) bundlerBal[token] = require_uint256(bundlerBal[token] - amt);
    if (to == currentContract)   bundlerBal[token] = bundlerBal[token] + amt;
    return true;
}

// supply / repay-by-assets pull exactly `assets` from the bundler.
// Justified by morpho-blue supplyAssetsAccounting / repayAssetsAccounting.
function cvlMorphoPull(address token, uint256 assets) returns (uint256, uint256) {
    bundlerBal[token] = require_uint256(bundlerBal[token] - assets);
    return (assets, 0);
}

// supplyCollateral pulls exactly `assets`. Justified by morpho-blue supplyCollateralAssetsAccounting
// (proven as an equality: collateralBefore + assets == collateralAfter).
function cvlMorphoPullVoid(address token, uint256 assets) {
    bundlerBal[token] = require_uint256(bundlerBal[token] - assets);
}

// repay pulls `assets`, or `gRepayShareAssets` on a full close by shares (see cvlExpectedBorrow).
// Justified by morpho-blue repayAssetsAccounting.
function cvlMorphoRepay(address token, uint256 assets, uint256 shares) returns (uint256, uint256) {
    uint256 pulled;
    if (shares == 0) { pulled = assets; } else { pulled = require_uint256(gRepayShareAssets); }
    bundlerBal[token] = require_uint256(bundlerBal[token] - pulled);
    return (pulled, 0);
}

// borrow sends `assets` to `receiver`. Justified by morpho-blue borrowAssetsAccounting.
function cvlMorphoSend(address token, uint256 assets, address receiver) returns (uint256, uint256) {
    if (receiver == currentContract) bundlerBal[token] = bundlerBal[token] + assets;
    return (assets, 0);
}

// withdraw sends the returned amount to `receiver` (the bundler forwards that same value, so any
// amount cancels); nondet on a full close by shares. Justified by morpho-blue withdrawAssetsAccounting.
function cvlMorphoWithdraw(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    uint256 sent;
    if (shares == 0) { sent = assets; } else { sent = require_uint256(gWithdrawShareAssets); }
    if (receiver == currentContract) bundlerBal[token] = bundlerBal[token] + sent;
    return (sent, 0);
}

// withdrawCollateral sends `assets` to `receiver`. Justified by morpho-blue withdrawCollateralAssetsAccounting.
function cvlMorphoSendVoid(address token, uint256 assets, address receiver) {
    if (receiver == currentContract) bundlerBal[token] = bundlerBal[token] + assets;
}

// feePct < WAD and onBehalf == msg.sender are omitted: the contract's own guards revert otherwise.

// supply is permissionless: no authorization precondition.
rule supplyPreservesBalance(env e, BlueBundles.MarketParams mp, uint256 assets, address onBehalf, TokenLib.TokenPermit permit, uint256 feePct, address recip, address t) {
    require permit.kind == TokenLib.PermitKind.None, "plain transferFrom pull path";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recip != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBal[t];
    supply(e, mp, assets, onBehalf, permit, feePct, recip);
    assert bundlerBal[t] == before;
}

rule withdrawPreservesBalance(env e, BlueBundles.MarketParams mp, uint256 withdrawAssets, address onBehalf, address receiver, uint256 feePct, address recip, address t) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recip != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBal[t];
    withdraw(e, mp, withdrawAssets, onBehalf, receiver, feePct, recip);
    assert bundlerBal[t] == before;
}

rule supplyCollateralAndBorrowPreservesBalance(env e, BlueBundles.MarketParams mp, uint256 collateralAmount, uint256 borrowAssets, address onBehalf, address receiver, TokenLib.TokenPermit permit, uint256 feePct, address recip, address t) {
    require permit.kind == TokenLib.PermitKind.None, "plain transferFrom pull path";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recip != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBal[t];
    supplyCollateralAndBorrow(e, mp, collateralAmount, borrowAssets, onBehalf, receiver, permit, feePct, recip);
    assert bundlerBal[t] == before;
}

// Covers both the finite-repay and the type(uint256).max full-close branches.
rule repayAndWithdrawCollateralPreservesBalance(env e, BlueBundles.MarketParams mp, uint256 repayAssets, uint256 withdrawCollateralAssets, address onBehalf, address receiver, TokenLib.TokenPermit permit, uint256 feePct, address recip, address t) {
    require permit.kind == TokenLib.PermitKind.None, "plain transferFrom pull path";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recip != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBal[t];
    repayAndWithdrawCollateral(e, mp, repayAssets, withdrawCollateralAssets, onBehalf, receiver, permit, feePct, recip);
    assert bundlerBal[t] == before;
}
