// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);

    // Blue modeling, where the bundler pays the supplied assets and repays the flash loan.
    function _.flashLoan(address token, uint256 assets, bytes data) external => summaryFlashLoan(calledContract, token, assets, data) expect void;
    function _.supply(VaultExitBundlesV1.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summarySupply(calledContract, marketParams.loanToken, assets, data) expect(uint256, uint256);

    // Vault modeling, where withdrawn assets are sent to the receiver.
    function _.asset() external => assetOf[calledContract] expect(address);
    function _.withdraw(uint256 assets, address receiver, address owner) external => summaryWithdraw(assetOf[calledContract], assets, receiver) expect(uint256);
}

/// HELPERS ///

persistent ghost mapping(address => mapping(address => uint256)) tokenBalance;

persistent ghost mapping(address => address) assetOf;

persistent ghost mathint suppliedAssets;

persistent ghost mathint withdrawnAssets;

function summarySafeTransfer(address token, address to, uint256 amount) {
    decreaseBalance(token, currentContract, amount);
    increaseBalance(token, to, amount);
}

function increaseBalance(address token, address account, uint256 amount) {
    if (amount + tokenBalance[token][account] > max_uint256) {
        revert();
    }
    tokenBalance[token][account] = assert_uint256(tokenBalance[token][account] + amount);
}

function decreaseBalance(address token, address account, uint256 amount) {
    if (amount > tokenBalance[token][account]) {
        revert();
    }
    tokenBalance[token][account] = assert_uint256(tokenBalance[token][account] - amount);
}

function summaryFlashLoan(address blue, address token, uint256 assets, bytes data) {
    increaseBalance(token, currentContract, assets);
    env callbackEnv;
    require callbackEnv.msg.sender == blue, "Blue calls back";
    onMorphoFlashLoan(callbackEnv, assets, data);
    decreaseBalance(token, currentContract, assets);
}

function summarySupply(address blue, address loanToken, uint256 assets, bytes data) returns (uint256, uint256) {
    if (data.length > 0) {
        env callbackEnv;
        require callbackEnv.msg.sender == blue, "Blue calls back";
        onMorphoSupply(callbackEnv, assets, data);
    }
    decreaseBalance(loanToken, currentContract, assets);
    suppliedAssets = suppliedAssets + assets;
    uint256 shares;
    return (assets, shares);
}

function summaryWithdraw(address asset, uint256 assets, address receiver) returns uint256 {
    increaseBalance(asset, receiver, assets);
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

    // Markets of a vault have the vault asset as loan token.
    require marketParamsList.length > 0 => marketParamsList[0].loanToken == asset, "vault market";
    require marketParamsList.length > 1 => marketParamsList[1].loanToken == asset, "vault market";

    suppliedAssets = 0;
    withdrawnAssets = 0;
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    uint256 bundlerBalanceBefore = tokenBalance[token][currentContract];
    vaultExitBundlesV1InKindRedemptionVaultV1(e, vault, marketParamsList, exitAssets, sharesPermit, deadline);

    assert tokenBalance[token][e.msg.sender] == senderBalanceBefore;
    assert tokenBalance[token][currentContract] == bundlerBalanceBefore;
    assert suppliedAssets == exitAssets && withdrawnAssets == exitAssets;
}

rule inKindRedemptionVaultV2DoesntLoseTokens(env e, address vault, address adapter, VaultExitBundlesV1.MarketParams[] marketParamsList, uint256 exitAssets, TokenLib.Permit sharesPermit, uint256 deadline) {
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require currentContract == 13, "ack";

    // Markets of the adapter have the vault asset as loan token.
    require marketParamsList.length > 0 => marketParamsList[0].loanToken == asset, "adapter market";
    require marketParamsList.length > 1 => marketParamsList[1].loanToken == asset, "adapter market";

    suppliedAssets = 0;
    withdrawnAssets = 0;
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    uint256 bundlerBalanceBefore = tokenBalance[token][currentContract];
    vaultExitBundlesV1InKindRedemptionVaultV2(e, vault, adapter, marketParamsList, exitAssets, sharesPermit, deadline);

    mathint received = tokenBalance[token][e.msg.sender] - senderBalanceBefore;

    assert tokenBalance[token][currentContract] == bundlerBalanceBefore;
    assert token == asset => received == withdrawnAssets - suppliedAssets;
    assert token != asset => received == 0;
}

rule forceWithdrawVaultV2DoesntLoseTokens(env e, address vault, address adapter, uint256 exitAssets, uint256 minSharePriceE27, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultExitBundlesV1 only compares addresses to BLUE, whose balance is not tracked.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    withdrawnAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    uint256 bundlerBalanceBefore = tokenBalance[token][currentContract];
    vaultExitBundlesV1ForceWithdrawVaultV2(e, vault, adapter, exitAssets, minSharePriceE27, sharesPermit, referralFeePct, referralFeeRecipient, deadline);

    mathint received = tokenBalance[token][e.msg.sender] - senderBalanceBefore;
    mathint fees = tokenBalance[token][referralFeeRecipient] - feeBalanceBefore;

    assert tokenBalance[token][currentContract] == bundlerBalanceBefore;
    assert token == asset => received == withdrawnAssets - fees;
    assert token != asset => received == 0 && fees == 0;
}
