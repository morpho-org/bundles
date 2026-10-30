// SPDX-License-Identifier: MIT

// No token residue: every entry point preserves the bundler's balance of every token, and its native balance (delta 0).
// Scope: all entry points.
// Assumptions shared with the BlueBundles and VaultBundles suites:
//   - no bundler donations: the caller and the referral fee recipient are different from the bundler.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing).
//   - well-behaved vault: withdraw sends exactly its assets argument, and asset() is constant per vault.
//   - calls not summarized below (vault, adapter and Morpho views, forceDeallocate, permit and approve) don't change the bundler's balance of any token.
// Assumption specific to the vault exit bundles:
//   - the markets the bundler supplies to have the vault's asset as loan token. Vault V1 only enables such markets, and the Vault V2 adapter only holds and force deallocates such markets.
// Share amounts are out of model: the summaries assert that the bundler is never the owner of the withdrawn shares, which is why no share can be left behind.

methods {
    // ERC20 transfers.
    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amt) expect(bool);

    // Morpho transfers.
    function _.supply(VaultExitBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(marketParams.loanToken, assets, shares, data) expect(uint256, uint256);
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(token, assets, data) expect void;

    // Vault transfers.
    function _.asset() external => summaryAsset(calledContract) expect(address);
    function _.withdraw(uint256 assets, address receiver, address owner) external => summaryWithdraw(calledContract, assets, receiver, owner) expect(uint256);

    // Balance-neutral calls, summarized without state changes, as the HAVOC_ECF allows the callee to credit native tokens to the caller.
    function _.forceDeallocate(address adapter, bytes data, uint256 assets, address onBehalf) external => NONDET;
    function _.permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external => NONDET;
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // Avoid non-linear arithmetic by using non-determinism (reverts are not checked by the specification).
    function SharesMathLib.toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal returns (uint256) => NONDET;
    function MorphoBalancesLib.expectedSupplyAssets(address morpho, VaultExitBundlesV1.MarketParams memory marketParams, address user) internal returns (uint256) => NONDET;
    function MorphoBalancesLib.expectedMarketBalances(address morpho, VaultExitBundlesV1.MarketParams memory marketParams) internal returns (uint256, uint256, uint256, uint256) => NONDET;
}

// Bundler ERC20 balances.
persistent ghost mapping(address => mathint) bundlerBalance;

// Each vault's underlying asset, fixed per vault.
persistent ghost mapping(address => address) vaultAsset;

function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    return true;
}

// Morpho calls the supply callback before pulling the assets.
function summarySupply(address token, uint256 assets, uint256 shares, bytes data) returns (uint256, uint256) {
    assert shares == 0;
    if (data.length > 0) {
        env callbackEnv;
        onMorphoSupply(callbackEnv, assets, data);
    }
    bundlerBalance[token] = bundlerBalance[token] - assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryFlashLoan(address token, uint256 assets, bytes data) {
    bundlerBalance[token] = bundlerBalance[token] + assets;
    env callbackEnv;
    onMorphoFlashLoan(callbackEnv, assets, data);
    bundlerBalance[token] = bundlerBalance[token] - assets;
}

function summaryAsset(address vault) returns address {
    return vaultAsset[vault];
}

// The owner assertion stands in for tracking share amounts: the bundler never has its own shares burned, so it can hold no share residue.
function summaryWithdraw(address vault, uint256 assets, address receiver, address owner) returns uint256 {
    assert owner != currentContract, "the bundler's own shares are never burned";
    if (receiver == currentContract) bundlerBalance[vaultAsset[vault]] = bundlerBalance[vaultAsset[vault]] + assets;
    uint256 returnedShares;
    return returnedShares;
}

// Up to loop_iter elements.
function marketsAssumptions(VaultExitBundlesV1.MarketParams[] marketParamsList, address vault) {
    require marketParamsList.length > 0 => marketParamsList[0].loanToken == vaultAsset[vault], "the vault's markets have the vault's asset as loan token";
    require marketParamsList.length > 1 => marketParamsList[1].loanToken == vaultAsset[vault], "the vault's markets have the vault's asset as loan token";
    require marketParamsList.length > 2 => marketParamsList[2].loanToken == vaultAsset[vault], "the vault's markets have the vault's asset as loan token";
}

rule inKindRedemptionVaultV1PreservesBalance(env e, address vault, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline, address token) {
    require e.msg.sender != currentContract, "external caller";
    marketsAssumptions(marketParamsList, vault);

    mathint before = bundlerBalance[token];
    mathint nativeBefore = nativeBalances[currentContract];
    vaultExitBundlesV1InKindRedemptionVaultV1(e, vault, marketParamsList, exitAssets, sharesPermit, deadline);
    assert bundlerBalance[token] == before;
    assert nativeBalances[currentContract] == nativeBefore;
}

rule inKindRedemptionVaultV2PreservesBalance(env e, address vault, address adapter, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline, address token) {
    require e.msg.sender != currentContract, "external caller";
    marketsAssumptions(marketParamsList, vault);

    mathint before = bundlerBalance[token];
    mathint nativeBefore = nativeBalances[currentContract];
    vaultExitBundlesV1InKindRedemptionVaultV2(e, vault, adapter, marketParamsList, exitAssets, sharesPermit, deadline);
    assert bundlerBalance[token] == before;
    assert nativeBalances[currentContract] == nativeBefore;
}

rule forceWithdrawVaultV2PreservesBalance(env e, address vault, address adapter, uint256 exitAssets, uint256 minSharePriceE27, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, address token) {
    require e.msg.sender != currentContract, "external caller";
    require referralFeeRecipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeBefore = nativeBalances[currentContract];
    vaultExitBundlesV1ForceWithdrawVaultV2(e, vault, adapter, exitAssets, minSharePriceE27, sharesPermit, referralFeePct, referralFeeRecipient, deadline);
    assert bundlerBalance[token] == before;
    assert nativeBalances[currentContract] == nativeBefore;
}
