// SPDX-License-Identifier: GPL-2.0-or-later

// No token residue: every entry point preserves the bundler's balance of every token (delta 0).
// Stated as preservation, not "== 0", because donations could increase the balance of the bundler.
// Two assumptions shared with that suite:
//   - no self-transfer: the receiver and the recipient are different from the bundler.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing): matching the token restriction in BlueBundles' header.

definition WAD() returns mathint = 10 ^ 18;

// The bundler's balance of every token, updated on every transfer that touches it.
persistent ghost mapping(address => mathint) bundlerBalance;

methods {
    // ERC20: the bundler's own transfers move bundlerBalance.

    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amt) expect(bool);

    // Morpho: pull on supply/repay/supplyCollateral, send on borrow/withdraw/withdrawCollateral.

    function _.supply(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(marketParams.loanToken, assets) expect(uint256, uint256);
    function _.repay(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryRepay(marketParams.loanToken, assets, shares) expect(uint256, uint256);
    function _.supplyCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) external => summarySupplyCollateral(marketParams.collateralToken, assets) expect void;
    function _.borrow(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryBorrow(marketParams.loanToken, assets, receiver) expect(uint256, uint256);
    function _.withdraw(BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external => summaryWithdraw(marketParams.loanToken, assets, shares, receiver) expect(uint256, uint256);
    function _.withdrawCollateral(BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) external => summaryWithdrawCollateral(marketParams.collateralToken, assets, receiver) expect void;

    // Since calls are not summarized as havoc all by default, it is assumed that other calls don't change the bundler's balance of any token.
}

// ERC20 transfers move balances by the amount.
function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = require_uint256(bundlerBalance[token] - amount);
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    return true;
}

function summarySupply(address token, uint256 assets) returns (uint256, uint256) {
    bundlerBalance[token] = require_uint256(bundlerBalance[token] - assets);
    return (assets, 0);
}

function summarySupplyCollateral(address token, uint256 assets) {
    bundlerBalance[token] = require_uint256(bundlerBalance[token] - assets);
}

function summaryRepay(address token, uint256 assets, uint256 shares) returns (uint256, uint256) {
    uint256 pulled;
    bundlerBalance[token] = require_uint256(bundlerBalance[token] - pulled);
    return (pulled, 0);
}

function summaryBorrow(address token, uint256 assets, address receiver) returns (uint256, uint256) {
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
    return (assets, 0);
}

function summaryWithdraw(address token, uint256 assets, uint256 shares, address receiver) returns (uint256, uint256) {
    uint256 sent;
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + sent;
    return (sent, 0);
}

function summaryWithdrawCollateral(address token, uint256 assets, address receiver) {
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
}

rule supplyPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, address onBehalf, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBalance[token];
    blueBundlesV1Supply(e, marketParams, assets, onBehalf, permit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
}

rule withdrawPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 withdrawAssets, address onBehalf, address receiver, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBalance[token];
    blueBundlesV1Withdraw(e, marketParams, withdrawAssets, onBehalf, receiver, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
}

rule supplyCollateralAndBorrowPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 collateralAmount, uint256 borrowAssets, uint256 maxLtv, address onBehalf, address receiver, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBalance[token];
    blueBundlesV1SupplyCollateralAndBorrow(e, marketParams, collateralAmount, borrowAssets, maxLtv, onBehalf, receiver, permit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
}

rule repayAndWithdrawCollateralPreservesBalance(env e, BlueBundlesV1.MarketParams marketParams, uint256 assets, uint256 maxRepayAssets, uint256 withdrawCollateralAssets, uint256 maxLtv, address onBehalf, address receiver, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind == TokenLib.PermitKind.None, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require receiver != currentContract, "no self-transfer of proceeds";
    require recipient != currentContract, "no self-transfer of the fee";

    mathint before = bundlerBalance[token];
    blueBundlesV1RepayAndWithdrawCollateral(e, marketParams, assets, maxRepayAssets, withdrawCollateralAssets, maxLtv, onBehalf, receiver, permit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
}
