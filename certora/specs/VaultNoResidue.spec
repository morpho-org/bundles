// SPDX-License-Identifier: GPL-2.0-or-later

// No token residue: every entry point preserves the bundler's balance of every token, and its native balance (delta 0).
// Scope: all entry points.
// Three assumptions shared with the BlueBundles suite:
//   - no bundler donations: the referral fee recipient and the caller are different from the bundler.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing): matching the token restriction in VaultBundles' header.
//   - the bundler is not the wrapped-native token.
// Two assumptions specific to the vault bundles, since the vault is caller-supplied rather than an immutable:
//   - well-behaved ERC4626: deposit pulls exactly its assets argument, withdraw and redeem send exactly the assets they report, and asset() is constant per vault. Migrate's asset consistency check relies on that last part.
//   - non-reentrant vault and token: the permit and approve calls are summarized without state changes, so reentering an entry point is out of model.
// Share amounts are also out of model: the vault's mints and burns don't move bundlerBalance, so token == vault is not a claim about share residue. Instead the summaries assert that the bundler is never a share receiver or owner, which is why no share can be left behind.

// The bundler's balance of every token, updated on every transfer that touches it.
persistent ghost mapping(address => mathint) bundlerBalance;

// Each vault's underlying asset, fixed per vault so that migrate's asset consistency check is exercised rather than assumed.
persistent ghost mapping(address => address) vaultAsset;

methods {
    // ERC20: the bundler's own transfers move bundlerBalance.

    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amt) expect(bool);

    // ERC4626: pull on deposit, send on withdraw/redeem.

    function _.asset() external => summaryAsset(calledContract) expect(address);
    function _.deposit(uint256 assets, address receiver) external => summaryDeposit(calledContract, assets, receiver) expect(uint256);
    function _.withdraw(uint256 assets, address receiver, address owner) external => summaryWithdraw(calledContract, assets, receiver, owner) expect(uint256);
    function _.redeem(uint256 shares, address receiver, address owner) external => summaryRedeem(calledContract, receiver, owner) expect(uint256);

    // Model the WNative contract's deposit behavior: mints on deposit. Deposit wraps msg.value into the vault asset instead of pulling it.
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;

    // Summarized without state changes, as the HAVOC_ECF allows the callee to credit native tokens to the caller.
    function _.permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // Since calls are not summarized as havoc all by default, it is assumed that other calls don't change the bundler's balance of any token.
}

// well-behaved ERC20: transfers move balances by the amount.
function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    return true;
}

function summaryAsset(address vault) returns address {
    return vaultAsset[vault];
}

// The native sent along is deducted by the call itself, so only the minted wrapped token is credited here.
function summaryWrapNative(address token, uint256 value) {
    bundlerBalance[token] = bundlerBalance[token] + value;
}

// The receiver and owner assertions stand in for tracking share amounts: the bundler is never minted shares and never has its own burned, so it can hold no share residue.
function summaryDeposit(address vault, uint256 assets, address receiver) returns uint256 {
    assert receiver != currentContract, "the bundler is never minted shares";
    bundlerBalance[vaultAsset[vault]] = bundlerBalance[vaultAsset[vault]] - assets;
    uint256 returnedShares;
    return returnedShares;
}

function summaryWithdraw(address vault, uint256 assets, address receiver, address owner) returns uint256 {
    assert owner != currentContract, "the bundler's own shares are never burned";
    if (receiver == currentContract) bundlerBalance[vaultAsset[vault]] = bundlerBalance[vaultAsset[vault]] + assets;
    uint256 returnedShares;
    return returnedShares;
}

function summaryRedeem(address vault, address receiver, address owner) returns uint256 {
    assert owner != currentContract, "the bundler's own shares are never burned";
    uint256 assets;
    if (receiver == currentContract) bundlerBalance[vaultAsset[vault]] = bundlerBalance[vaultAsset[vault]] + assets;
    return assets;
}

rule depositPreservesBalance(env e, address vault, uint256 assets, uint256 maxSharePriceE27, TokenLib.TokenPermit permit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require permit.kind != TokenLib.PermitKind.Permit2, "simplification for prover performance";
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";
    require vaultAsset[vault] != currentContract, "the bundler is not the wrapped-native token";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = nativeBalances[currentContract];
    vaultBundlesV1Deposit(e, vault, assets, maxSharePriceE27, permit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeBalances[currentContract] == nativeBefore;
}

rule withdrawPreservesBalance(env e, address vault, uint256 assets, uint256 shares, TokenLib.Permit sharesPermit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = nativeBalances[currentContract];
    vaultBundlesV1Withdraw(e, vault, assets, shares, sharesPermit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeBalances[currentContract] == nativeBefore;
}

rule migratePreservesBalance(env e, address sourceVault, address destVault, uint256 assetsWithdrawn, uint256 sharesRedeemed, uint256 destMaxSharePriceE27, TokenLib.Permit sharesPermit, uint256 feePct, address recipient, address token, uint256 deadline) {
    require e.msg.sender != currentContract, "bundler is never its own caller";
    require recipient != currentContract, "no bundler donations of the fee";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = nativeBalances[currentContract];
    vaultBundlesV1Migrate(e, sourceVault, destVault, assetsWithdrawn, sharesRedeemed, destMaxSharePriceE27, sharesPermit, feePct, recipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeBalances[currentContract] == nativeBefore;
}
