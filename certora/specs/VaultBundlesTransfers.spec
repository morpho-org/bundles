// SPDX-License-Identifier: MIT

methods {
    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function _.permitTransferFrom(ISignatureTransfer.PermitTransferFrom permit, ISignatureTransfer.SignatureTransferDetails transferDetails, address owner, bytes signature) external => summarySafeTransferFrom(permit.permitted.token, owner, transferDetails.to, transferDetails.requestedAmount) expect void;
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;

    function _.asset() external => assetOf[calledContract] expect(address);
    function _.deposit(uint256 assets, address) external => summaryDeposit(assets) expect(uint256);
    function _.withdraw(uint256 assets, address, address) external => summaryWithdraw(assets) expect(uint256);
    function _.redeem(uint256, address, address) external => summaryRedeem() expect(uint256);
}

/// HELPERS ///

persistent ghost mapping(address => mapping(address => uint256)) tokenBalance;

function summarySafeTransfer(address token, address to, uint256 amount) {
    summarySafeTransferFrom(token, currentContract, to, amount);
}

function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    if (amount > tokenBalance[token][from] || amount + tokenBalance[token][to] > max_uint256) {
        revert();
    }
    tokenBalance[token][from] = assert_uint256(tokenBalance[token][from] - amount);
    tokenBalance[token][to] = assert_uint256(tokenBalance[token][to] + amount);
}

persistent ghost mathint wrappedAssets;

function summaryWrapNative(address token, uint256 value) {
    if (value + tokenBalance[token][currentContract] > max_uint256) {
        revert();
    }
    tokenBalance[token][currentContract] = assert_uint256(tokenBalance[token][currentContract] + value);
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
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultBundlesV1 never compares these addresses.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    wrappedAssets = 0;
    depositedAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    vaultBundlesV1Deposit(e, vault, assets, maxSharePriceE27, assetPermit, referralFeePct, referralFeeRecipient, deadline);
    uint256 senderBalanceAfter = tokenBalance[token][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint spent = senderBalanceBefore - senderBalanceAfter;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert token == asset => spent + wrappedAssets == depositedAssets + fees;
    assert token != asset => spent == 0 && fees == 0;
}

rule withdrawDoesntLoseTokens(env e, address vault, uint256 assets, uint256 shares, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;
    address asset = assetOf[vault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultBundlesV1 never compares these addresses.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    withdrawnAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    vaultBundlesV1Withdraw(e, vault, assets, shares, sharesPermit, referralFeePct, referralFeeRecipient, deadline);
    uint256 senderBalanceAfter = tokenBalance[token][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint received = senderBalanceAfter - senderBalanceBefore;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert token == asset => received == withdrawnAssets - fees;
    assert token != asset => received == 0 && fees == 0;
}

rule migrateDoesntLoseTokens(env e, address sourceVault, address destVault, uint256 assetsWithdrawn, uint256 sharesRedeemed, uint256 destMaxSharePriceE27, TokenLib.Permit sharesPermit, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address token;
    address asset = assetOf[sourceVault];

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick. Sound since VaultBundlesV1 never compares these addresses.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    withdrawnAssets = 0;
    depositedAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    vaultBundlesV1Migrate(e, sourceVault, destVault, assetsWithdrawn, sharesRedeemed, destMaxSharePriceE27, sharesPermit, referralFeePct, referralFeeRecipient, deadline);
    uint256 senderBalanceAfter = tokenBalance[token][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert senderBalanceAfter == senderBalanceBefore;
    assert token == asset => withdrawnAssets == depositedAssets + fees;
    assert token != asset => fees == 0;
}
