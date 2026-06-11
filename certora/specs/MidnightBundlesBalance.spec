// SPDX-License-Identifier: GPL-2.0-or-later

methods {
    function SafeTransferLib.safeTransfer(address token, address receiver, uint256 amount) internal => summarySafeTransfer(token, receiver, amount);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 amount) internal => summarySafeTransferFrom(token, from, to, amount);

    function _.take(MidnightBundles.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external with(env e) => summaryTake(e.msg.sender, offer, taker, receiverIfTakerIsSeller, takerCallback) expect(uint256, uint256);
}

/// HELPERS ///

ghost mapping(address => mapping(address => uint256)) tokenBalance;

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

ghost uint256 boughtAssets;

ghost uint256 soldAssets;

function summaryTake(address msgSender, MidnightBundles.Offer offer, address taker, address receiverIfTakerIsSeller, address takerCallback) returns (uint256, uint256) {
    uint256 buyerAssets;
    uint256 sellerAssets;
    boughtAssets = require_uint256(boughtAssets + buyerAssets);
    soldAssets = require_uint256(soldAssets + sellerAssets);
    return (buyerAssets, sellerAssets);
}

/// RULES ///

rule buyWithUnitsTargetAndWithdrawCollateralDoesntLoseTokens(env e, uint256 targetUnits, uint256 maxBuyerAssets, address taker, MidnightBundles.TokenPermit loanTokenPermit, MidnightBundles.Take[] takes, MidnightBundles.CollateralWithdrawal[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient) {
    address loanToken = takes[0].offer.market.loanToken;

    boughtAssets = 0;

    uint256 balanceBefore = tokenBalance[loanToken][taker];
    buyWithUnitsTargetAndWithdrawCollateral(e, targetUnits, maxBuyerAssets, taker, loanTokenPermit, takes, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient);
    uint256 balanceAfter = tokenBalance[loanToken][taker];

    assert balanceBefore - balanceAfter == boughtAssets;
}
