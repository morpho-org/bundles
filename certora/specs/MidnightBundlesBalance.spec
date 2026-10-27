// SPDX-License-Identifier: GPL-2.0-or-later

using Utils as Utils;

methods {
    function Utils.hashMarket(Utils.Market market) external returns (bytes32) envfree;

    // Over-approximate view functions.
    function TakeAmountsLib.sellerAssetsToUnits(address, bytes32, MidnightBundlesV2.Offer memory, uint256) internal returns (uint256) => NONDET;
    function TakeAmountsLib.buyerAssetsToUnits(address, bytes32, MidnightBundlesV2.Offer memory, uint256) internal returns (uint256) => NONDET;
    function ConsumableUnitsLib.consumableUnits(address, bytes32, MidnightBundlesV2.Offer memory) internal returns (uint256) => NONDET;

    // Wrapping native tokens only moves wrappedNative, so ignore it.
    function MidnightBundlesV2.wrapNativeToMsgSender(address wrappedNative) internal => NONDET;

    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function _.take(MidnightBundlesV2.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => summaryTake() expect(uint256, uint256);
    function _.repay(Utils.Market, uint256 units, address, address, bytes) external => summaryRepay(units) expect void;
    function _.withdraw(Utils.Market, uint256 units, address, address) external => summaryWithdraw(units) expect void;
    function _.supplyCollateral(Utils.Market market, uint256 collateralIndex, uint256 assets, address) external => summarySupplyCollateral(market.collateralParams[collateralIndex].token, assets) expect void;
    function _.supply(MidnightBundlesV2.MarketParams, uint256 assets, uint256 shares, address, bytes) external => summarySupply(assets, shares) expect(uint256, uint256);
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

persistent ghost mathint boughtAssets;

persistent ghost mathint soldAssets;

persistent ghost mathint repaidAssets;

persistent ghost mathint withdrawnAssets;

persistent ghost mapping(address => mathint) suppliedCollateral;

persistent ghost mathint parkedAssets;

function summaryTake() returns (uint256, uint256) {
    uint256 buyerAssets;
    uint256 sellerAssets;
    boughtAssets = boughtAssets + buyerAssets;
    soldAssets = soldAssets + sellerAssets;
    return (buyerAssets, sellerAssets);
}

function summaryRepay(uint256 units) {
    repaidAssets = repaidAssets + units;
}

function summaryWithdraw(uint256 units) {
    withdrawnAssets = withdrawnAssets + units;
}

function summarySupplyCollateral(address token, uint256 assets) {
    suppliedCollateral[token] = suppliedCollateral[token] + assets;
}

function summarySupply(uint256 assets, uint256 shares) returns (uint256, uint256) {
    parkedAssets = parkedAssets + assets;
    return (assets, shares);
}

/// RULES ///

rule buyWithUnitsTargetAndWithdrawCollateralDoesntLoseTokens(env e, Utils.Market market, uint256 targetUnits, uint256 maxBuyerAssets, bool reduceOnly, bool repayEnabled, MidnightBundlesV2.OfferFill[] offerFills, MidnightBundlesV2.CollateralTransfer[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline, address wrappedNative) {
    address token;
    address loanToken = market.loanToken;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    boughtAssets = 0;
    repaidAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    uint256 balanceBefore = tokenBalance[token][e.msg.sender];
    midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(e, market, targetUnits, maxBuyerAssets, reduceOnly, repayEnabled, offerFills, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline, wrappedNative);
    uint256 balanceAfter = tokenBalance[token][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint spent = balanceBefore - balanceAfter;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert token == loanToken => spent == boughtAssets + repaidAssets + fees;
    assert token != loanToken => spent == 0 && fees == 0;
}

rule buyWithAssetsTargetAndWithdrawCollateralDoesntLoseTokens(env e, Utils.Market market, uint256 targetBuyerAssets, uint256 minUnits, bool reduceOnly, bool repayEnabled, MidnightBundlesV2.OfferFill[] offerFills, MidnightBundlesV2.CollateralTransfer[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline, address wrappedNative) {
    address token;
    address loanToken = market.loanToken;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    boughtAssets = 0;
    repaidAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    uint256 balanceBefore = tokenBalance[token][e.msg.sender];
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, market, targetBuyerAssets, minUnits, reduceOnly, repayEnabled, offerFills, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline, wrappedNative);
    uint256 balanceAfter = tokenBalance[token][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint spent = balanceBefore - balanceAfter;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert token == loanToken => spent == boughtAssets + repaidAssets + fees;
    assert token != loanToken => spent == 0 && fees == 0;
}

rule supplyCollateralAndSellWithUnitsTargetDoesntLoseTokens(env e, Utils.Market market, uint256 targetUnits, uint256 minSellerAssets, bool reduceOnly, address receiver, MidnightBundlesV2.CollateralTransfer[] collateralSupplies, MidnightBundlesV2.OfferFill[] offerFills, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, address wrappedNative) {
    address token;
    address loanToken = market.loanToken;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick.
    require receiver == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";
    require e.msg.sender == 14, "ack";

    soldAssets = 0;
    withdrawnAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    mathint suppliedBefore = suppliedCollateral[token];
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    uint256 receiverBalanceBefore = tokenBalance[token][receiver];
    midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(e, market, targetUnits, minSellerAssets, reduceOnly, receiver, collateralSupplies, offerFills, referralFeePct, referralFeeRecipient, deadline, wrappedNative);
    uint256 senderBalanceAfter = tokenBalance[token][e.msg.sender];
    uint256 receiverBalanceAfter = tokenBalance[token][receiver];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint received = receiverBalanceAfter - receiverBalanceBefore;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    mathint spent = senderBalanceBefore - senderBalanceAfter;
    mathint supplied = suppliedCollateral[token] - suppliedBefore;

    assert token == loanToken => received == soldAssets + withdrawnAssets - fees;
    assert token != loanToken => received == 0 && fees == 0;
    assert spent == supplied;
}

rule supplyCollateralAndSellWithAssetsTargetDoesntLoseTokens(env e, Utils.Market market, uint256 targetSellerAssets, uint256 maxUnits, bool reduceOnly, address receiver, MidnightBundlesV2.CollateralTransfer[] collateralSupplies, MidnightBundlesV2.OfferFill[] offerFills, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, address wrappedNative) {
    address token;
    address loanToken = market.loanToken;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick.
    require receiver == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";
    require e.msg.sender == 14, "ack";

    soldAssets = 0;
    withdrawnAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[token][referralFeeRecipient];
    mathint suppliedBefore = suppliedCollateral[token];
    uint256 senderBalanceBefore = tokenBalance[token][e.msg.sender];
    uint256 receiverBalanceBefore = tokenBalance[token][receiver];
    midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(e, market, targetSellerAssets, maxUnits, reduceOnly, receiver, collateralSupplies, offerFills, referralFeePct, referralFeeRecipient, deadline, wrappedNative);
    uint256 senderBalanceAfter = tokenBalance[token][e.msg.sender];
    uint256 receiverBalanceAfter = tokenBalance[token][receiver];
    uint256 feeBalanceAfter = tokenBalance[token][referralFeeRecipient];

    mathint received = receiverBalanceAfter - receiverBalanceBefore;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    mathint spent = senderBalanceBefore - senderBalanceAfter;
    mathint supplied = suppliedCollateral[token] - suppliedBefore;

    assert token == loanToken => received == soldAssets + withdrawnAssets - fees;
    assert token != loanToken => received == 0 && fees == 0;
    assert spent == supplied;
}

rule cancelAndMakeDoesntLoseTokens(env e, MidnightBundlesV2.MarketParams blueMarket, uint256 assetsToPark, bytes32 callbackSalt, Utils.Market market, MidnightBundlesV2.CollateralTransfer[] collateralSupplies, address ratifier, bytes32 newRoot, uint256 signatureHeight, uint128 signatureNonce, uint256 signatureDeadline, uint8 v, bytes32 r, bytes32 s, MidnightBundlesV2.GroupCancellation[] groupsToCancel, bytes payload, uint256 deadline, address wrappedNative) {
    address token;
    address loanToken = blueMarket.loanToken;

    // Assume different addresses to have simpler accounting, using hardcoded addresses as a trick.
    require e.msg.sender == 11, "ack";
    require currentContract == 13, "ack";

    parkedAssets = 0;
    mathint suppliedBefore = suppliedCollateral[token];
    uint256 balanceBefore = tokenBalance[token][e.msg.sender];
    midnightBundlesV2CancelAndMake(e, blueMarket, assetsToPark, callbackSalt, market, collateralSupplies, ratifier, newRoot, signatureHeight, signatureNonce, signatureDeadline, v, r, s, groupsToCancel, payload, deadline, wrappedNative);
    uint256 balanceAfter = tokenBalance[token][e.msg.sender];

    mathint spent = balanceBefore - balanceAfter;
    mathint supplied = suppliedCollateral[token] - suppliedBefore;

    assert token == loanToken => spent == parkedAssets + supplied;
    assert token != loanToken => spent == supplied;
}
