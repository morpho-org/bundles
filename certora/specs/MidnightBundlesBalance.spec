// SPDX-License-Identifier: GPL-2.0-or-later

using Utils as Utils;

methods {
    function Utils.hashMarket(MidnightBundlesV1.Market market) external returns (bytes32) envfree;

    // Over-approximate view functions.
    function TakeAmountsLib.sellerAssetsToUnits(address, bytes32, MidnightBundlesV1.Offer memory, uint256) internal returns (uint256) => NONDET;
    function TakeAmountsLib.buyerAssetsToUnits(address, bytes32, MidnightBundlesV1.Offer memory, uint256) internal returns (uint256) => NONDET;
    function ConsumableUnitsLib.consumableUnits(address, bytes32, MidnightBundlesV1.Offer memory) internal returns (uint256) => NONDET;
    function _.toId(MidnightBundlesV1.Market) external => NONDET;

    // Allowances are not modeled, so ignore this side-effect.
    function TokenLib.forceApproveMax(address token, address spender) internal => NONDET;

    // Token modeling.
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);
    function TokenLib.pullToken(address token, address from, uint256 amount, MidnightBundlesV1.TokenPermit memory permit) internal => summaryPullToken(token, from, amount);
    function _.take(MidnightBundlesV1.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external with(env e) => summaryTake(e.msg.sender, offer, taker, receiverIfTakerIsSeller, takerCallback) expect(uint256, uint256);
    function _.repay(MidnightBundlesV1.Market, uint256 units, address, address, bytes) external => summaryRepay(units) expect void;
}

/// HELPERS ///

persistent ghost mapping(address => mapping(address => uint256)) tokenBalance;

function summaryPullToken(address token, address from, uint256 amount) {
    summarySafeTransferFrom(token, from, currentContract, amount);
}

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

function summaryTake(address msgSender, MidnightBundlesV1.Offer offer, address taker, address receiverIfTakerIsSeller, address takerCallback) returns (uint256, uint256) {
    uint256 buyerAssets;
    uint256 sellerAssets;
    boughtAssets = boughtAssets + buyerAssets;
    soldAssets = soldAssets + sellerAssets;
    return (buyerAssets, sellerAssets);
}

function summaryRepay(uint256 units) {
    repaidAssets = repaidAssets + units;
}

/// RULES ///

rule buyWithUnitsTargetAndWithdrawCollateralDoesntLoseTokens(env e, uint256 targetUnits, uint256 maxBuyerAssets, address taker, bool reduceOnly, MidnightBundlesV1.TokenPermit loanTokenPermit, MidnightBundlesV1.OfferFill[] takes, MidnightBundlesV1.CollateralWithdrawal[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) {
    address loanToken = takes[0].offer.market.loanToken;

    // Assume different addresses to have correct accounting, using hardcoded addresses as a trick.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    boughtAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[loanToken][referralFeeRecipient];
    uint256 balanceBefore = tokenBalance[loanToken][e.msg.sender];
    midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral(e, targetUnits, maxBuyerAssets, e.msg.sender, reduceOnly, loanTokenPermit, takes, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline);
    uint256 balanceAfter = tokenBalance[loanToken][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[loanToken][referralFeeRecipient];

    mathint spent = balanceBefore - balanceAfter;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert spent == boughtAssets + fees;
}

rule buyWithAssetsTargetAndWithdrawCollateralDoesntLoseTokens(env e, uint256 targetBuyerAssets, uint256 minUnits, bool reduceOnly, MidnightBundlesV1.TokenPermit loanTokenPermit, MidnightBundlesV1.OfferFill[] takes, MidnightBundlesV1.CollateralWithdrawal[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) {
    address loanToken = takes[0].offer.market.loanToken;

    // Assume different addresses to have correct accounting, using hardcoded addresses as a trick.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    boughtAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[loanToken][referralFeeRecipient];
    uint256 balanceBefore = tokenBalance[loanToken][e.msg.sender];
    midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral(e, targetBuyerAssets, minUnits, e.msg.sender, reduceOnly, loanTokenPermit, takes, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline);
    uint256 balanceAfter = tokenBalance[loanToken][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[loanToken][referralFeeRecipient];

    mathint spent = balanceBefore - balanceAfter;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert spent == boughtAssets + fees;
}

rule supplyCollateralAndSellWithUnitsTargetDoesntLoseTokens(env e, uint256 targetUnits, uint256 minSellerAssets, bool reduceOnly, address receiver, MidnightBundlesV1.CollateralSupply[] collateralSupplies, MidnightBundlesV1.OfferFill[] takes, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) {
    address loanToken = takes[0].offer.market.loanToken;

    // Assume different addresses to have correct accounting, using hardcoded addresses as a trick.
    require receiver == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";
    require e.msg.sender == 14, "ack";

    soldAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[loanToken][referralFeeRecipient];
    uint256 receiverBalanceBefore = tokenBalance[loanToken][receiver];
    midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget(e, targetUnits, minSellerAssets, e.msg.sender, reduceOnly, receiver, collateralSupplies, takes, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline);
    uint256 receiverBalanceAfter = tokenBalance[loanToken][receiver];
    uint256 feeBalanceAfter = tokenBalance[loanToken][referralFeeRecipient];

    mathint received = receiverBalanceAfter - receiverBalanceBefore;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert received == soldAssets - fees;
}

rule supplyCollateralAndSellWithAssetsTargetDoesntLoseTokens(env e, uint256 targetSellerAssets, uint256 maxUnits, bool reduceOnly, address receiver, MidnightBundlesV1.CollateralSupply[] collateralSupplies, MidnightBundlesV1.OfferFill[] takes, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline) {
    address loanToken = takes[0].offer.market.loanToken;

    // Assume different addresses to have correct accounting, using hardcoded addresses as a trick.
    require receiver == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";
    require e.msg.sender == 14, "ack";

    soldAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[loanToken][referralFeeRecipient];
    uint256 receiverBalanceBefore = tokenBalance[loanToken][receiver];
    midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget(e, targetSellerAssets, maxUnits, e.msg.sender, reduceOnly, receiver, collateralSupplies, takes, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline);
    uint256 receiverBalanceAfter = tokenBalance[loanToken][receiver];
    uint256 feeBalanceAfter = tokenBalance[loanToken][referralFeeRecipient];

    mathint received = receiverBalanceAfter - receiverBalanceBefore;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert received == soldAssets - fees;
}

rule repayAndWithdrawCollateralDoesntLoseTokens(env e, MidnightBundlesV1.Market market, uint256 assets, MidnightBundlesV1.TokenPermit loanTokenPermit, MidnightBundlesV1.CollateralWithdrawal[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline) {
    address loanToken = market.loanToken;

    // Assume different addresses to have correct accounting, using hardcoded addresses as a trick.
    require e.msg.sender == 11, "ack";
    require referralFeeRecipient == 12, "ack";
    require currentContract == 13, "ack";

    repaidAssets = 0;
    uint256 feeBalanceBefore = tokenBalance[loanToken][referralFeeRecipient];
    uint256 balanceBefore = tokenBalance[loanToken][e.msg.sender];
    midnightBundlesV1RepayAndWithdrawCollateral(e, market, assets, e.msg.sender, loanTokenPermit, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, deadline);
    uint256 balanceAfter = tokenBalance[loanToken][e.msg.sender];
    uint256 feeBalanceAfter = tokenBalance[loanToken][referralFeeRecipient];

    mathint spent = balanceBefore - balanceAfter;
    mathint fees = feeBalanceAfter - feeBalanceBefore;

    assert spent == repaidAssets + fees;
}
