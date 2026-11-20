// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);

    // Blue modeling, where only callbacks and amounts are modeled, since Blue's transfers are not in the body of the bundle functions.
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(calledContract, assets, data) expect void;
    function _.supply(VaultExitBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(calledContract, assets, data) expect(uint256, uint256);

    // Sound since the asset of a vault is immutable.
    function _.asset() external => assetOf[calledContract] expect(address);

    // Vault modeling, where only amounts are modeled, since the vault's transfers are not in the body of the bundle functions.
    function _.withdraw(uint256 assets, address, address) external => summaryWithdraw(assets) expect(uint256);
}

/// HELPERS ///

// Net amount transferred to each account during the interaction, per token, which is not the token balance.
persistent ghost mapping(address => mapping(address => mathint)) transferBalanceChange;

persistent ghost mapping(address => address) assetOf;

persistent ghost mathint suppliedAssets;

persistent ghost mathint withdrawnAssets;

function summarySafeTransfer(address token, address to, uint256 amount) {
    transferBalanceChange[token][currentContract] = transferBalanceChange[token][currentContract] - amount;
    transferBalanceChange[token][to] = transferBalanceChange[token][to] + amount;
}

function summaryFlashLoan(address blue, uint256 assets, bytes data) {
    env callbackEnv;
    require callbackEnv.msg.sender == blue, "Blue calls back";
    onMorphoFlashLoan(callbackEnv, assets, data);
}

function summarySupply(address blue, uint256 assets, bytes data) returns (uint256, uint256) {
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == blue, "Blue calls back";
        onMorphoSupply(callbackEnv, assets, data);
    }
    suppliedAssets = suppliedAssets + assets;
    uint256 shares;
    return (assets, shares);
}

function summaryWithdraw(uint256 assets) returns uint256 {
    withdrawnAssets = withdrawnAssets + assets;
    uint256 shares;
    return shares;
}

/// RULES ///

rule inKindRedemptionVaultV1DoesntLoseTokens(env e, address vault, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline) {
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require currentContract == 13, "ack";

    // Markets of a vault have the vault asset as loan token, as verified by enabledHasConsistentAsset in https://github.com/morpho-org/metamorpho/blob/ae732258e55be466b959705ad2e6bc6c66e1819d/certora/specs/ConsistentState.spec.
    require forall uint256 i. i < marketParamsList.length => marketParamsList[i].loanToken == asset, "vault market";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    suppliedAssets = 0;
    withdrawnAssets = 0;
    vaultExitBundlesV1InKindRedemptionVaultV1(e, vault, marketParamsList, exitAssets, sharesPermit, deadline);

    assert transferBalanceChange[token][e.msg.sender] == 0;
    assert suppliedAssets == exitAssets && withdrawnAssets == exitAssets;
}

rule inKindRedemptionVaultV2DoesntLoseTokens(env e, address vault, address adapter, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline) {
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require currentContract == 13, "ack";

    // Markets of the adapter have the vault asset as loan token.
    require forall uint256 i. i < marketParamsList.length => marketParamsList[i].loanToken == asset, "adapter market";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    suppliedAssets = 0;
    withdrawnAssets = 0;
    vaultExitBundlesV1InKindRedemptionVaultV2(e, vault, adapter, marketParamsList, exitAssets, sharesPermit, deadline);

    mathint received = transferBalanceChange[token][e.msg.sender];

    assert token == asset => withdrawnAssets == received + suppliedAssets;
    assert token != asset => received == 0;
}

rule forceWithdrawVaultV2DoesntLoseTokens(env e, address vault, address adapter, uint256 exitAssets, uint256 minSharePriceE27, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    withdrawnAssets = 0;
    vaultExitBundlesV1ForceWithdrawVaultV2(e, vault, adapter, exitAssets, minSharePriceE27, sharesPermit, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[token][e.msg.sender];
    mathint fees = transferBalanceChange[token][referralFeeRecipient];

    assert token == asset => withdrawnAssets == received + fees;
    assert token != asset => received == 0 && fees == 0;
}
