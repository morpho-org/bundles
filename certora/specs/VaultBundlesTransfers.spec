// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransferFrom(token, currentContract, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => summarySafeTransferFrom(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(e.msg.value) expect void;

    // Sound since the asset of a vault is immutable.
    function _.asset() external => assetOf[calledContract] expect(address);

    // Calls accounting for transfers.
    function _.withdraw(uint256 assets, address, address) external => summaryWithdraw(assets) expect(uint256);
    function _.redeem(uint256, address, address) external => summaryRedeem() expect(uint256);
    function _.deposit(uint256 assets, address) external => summaryDeposit(assets) expect(uint256);
}

/// HELPERS ///

// Net amount transferred to each account during the interaction, per token, which is not the token balance.
persistent ghost mapping(address => mapping(address => mathint)) transferBalanceChange;

function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    transferBalanceChange[token][from] = transferBalanceChange[token][from] - amount;
    transferBalanceChange[token][to] = transferBalanceChange[token][to] + amount;
}

persistent ghost mathint wrappedAssets;

function summaryWrapNative(uint256 value) {
    wrappedAssets = wrappedAssets + value;
}

persistent ghost mapping(address => address) assetOf;

persistent ghost mathint depositedAssets;

persistent ghost mathint withdrawnAssets;

function summaryDeposit(uint256 assets) returns uint256 {
    depositedAssets = depositedAssets + assets;
    uint256 shares;
    return shares;
}

function summaryWithdraw(uint256 assets) returns uint256 {
    withdrawnAssets = withdrawnAssets + assets;
    uint256 shares;
    return shares;
}

function summaryRedeem() returns uint256 {
    uint256 assets;
    withdrawnAssets = withdrawnAssets + assets;
    return assets;
}

/// RULES ///

rule depositDoesntLoseTokens(env e, address vault, uint256 assets, uint256 maxSharePriceE27, TokenLib.TokenPermit assetPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultBundlesV1 never compares these addresses.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    wrappedAssets = 0;
    depositedAssets = 0;
    vaultBundlesV1Deposit(e, vault, assets, maxSharePriceE27, assetPermit, referralFeePct, referralFeeRecipient, deadline);

    // The native value sent is spent in the vault asset, which it is wrapped into.
    mathint spent = e.msg.value - transferBalanceChange[asset][e.msg.sender];
    mathint fees = transferBalanceChange[asset][referralFeeRecipient];

    assert wrappedAssets == e.msg.value;
    assert spent == depositedAssets + fees;
}

rule withdrawDoesntLoseTokens(env e, address vault, uint256 assets, uint256 shares, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultBundlesV1 never compares these addresses.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    withdrawnAssets = 0;
    vaultBundlesV1Withdraw(e, vault, assets, shares, sharesPermit, referralFeePct, referralFeeRecipient, deadline);

    mathint received = transferBalanceChange[asset][e.msg.sender];
    mathint fees = transferBalanceChange[asset][referralFeeRecipient];

    assert withdrawnAssets == received + fees;
}

rule migrateDoesntLoseTokens(env e, address sourceVault, address destVault, uint256 assetsWithdrawn, uint256 sharesRedeemed, uint256 destMaxSharePriceE27, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address asset = assetOf[sourceVault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultBundlesV1 never compares these addresses.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    require forall address t. forall address a. transferBalanceChange[t][a] == 0, "only count transfers of the interaction";
    withdrawnAssets = 0;
    depositedAssets = 0;
    vaultBundlesV1Migrate(e, sourceVault, destVault, assetsWithdrawn, sharesRedeemed, destMaxSharePriceE27, sharesPermit, referralFeePct, referralFeeRecipient, deadline);

    mathint fees = transferBalanceChange[asset][referralFeeRecipient];

    assert transferBalanceChange[asset][e.msg.sender] == 0;
    assert withdrawnAssets == depositedAssets + fees;
}
