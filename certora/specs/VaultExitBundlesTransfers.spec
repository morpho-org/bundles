// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);

    // Sound since the asset of a vault is immutable.
    function _.asset() external => assetOf[calledContract] expect(address);

    // Calls accounting for transfers.
    function _.supply(VaultExitBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(calledContract, assets, data) expect(uint256, uint256);
    function _.withdraw(uint256 assets, address, address) external => summaryWithdraw(assets) expect(uint256);

    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(calledContract, assets, data) expect void;
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

function summaryFlashLoan(address blue, uint256 assets, bytes data) {
    env callbackEnv;
    require callbackEnv.msg.sender == blue, "Blue calls back";
    onMorphoFlashLoan(callbackEnv, assets, data);
}

/// RULES ///

rule inKindRedemptionVaultV1DoesntLoseTokens(env e, address vault, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline) {
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require currentContract == 12, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    suppliedAssets = 0;
    withdrawnAssets = 0;
    vaultExitBundlesV1InKindRedemptionVaultV1(e, vault, marketParamsList, exitAssets, sharesPermit, deadline);

    assert transferBalanceChange[asset][e.msg.sender] == 0;
    assert suppliedAssets == exitAssets && withdrawnAssets == exitAssets;
}

rule inKindRedemptionVaultV2DoesntLoseTokens(env e, address vault, address adapter, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline) {
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require currentContract == 12, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    suppliedAssets = 0;
    withdrawnAssets = 0;
    vaultExitBundlesV1InKindRedemptionVaultV2(e, vault, adapter, marketParamsList, exitAssets, sharesPermit, deadline);

    mathint received = transferBalanceChange[asset][e.msg.sender];

    assert withdrawnAssets == received + suppliedAssets;
}

rule forceWithdrawVaultV2DoesntLoseTokens(env e, address vault, address adapter, uint256 exitAssets, uint256 minSharePriceE27, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    withdrawnAssets = 0;
    vaultExitBundlesV1ForceWithdrawVaultV2(e, vault, adapter, exitAssets, minSharePriceE27, sharesPermit, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[asset][e.msg.sender];
    mathint fees = transferBalanceChange[asset][referralFeeRecipient];

    assert withdrawnAssets == received + fees;
}
