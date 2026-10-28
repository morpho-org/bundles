// SPDX-License-Identifier: MIT

// No token residue: every entry point preserves the bundler's balance of every token, and sends out exactly msg.value of native tokens (wrapped and forwarded to the caller).
// Scope: all entry points.
// Assumptions shared with the BlueBundles suite:
//   - no bundler donations: the caller, the referral fee recipient and the token receivers are different from the bundler.
//   - well-behaved ERC20 (no fee-on-transfer/rebasing).
//   - calls not summarized below (Midnight views, setConsumed, setIsAuthorized, the ratifier, the callback factory, the buyer assets bound and LOG) don't change the bundler's balance of any token.
// Assumptions specific to the Midnight bundles:
//   - Midnight moves exactly the amounts it reports: take pulls buyerAssets from the bundler when the offer sells and there is no taker callback and sends sellerAssets to the receiver when it sells, repay pulls units, withdraw sends units.
//   - market ids are injective in the loan token: offers whose id matches the market's id have the market's loan token.

methods {
    // ERC20 transfers.
    function _.transferFrom(address from, address to, uint256 amt) external => cvlTransferFrom(calledContract, from, to, amt) expect(bool);
    function _.transfer(address to, uint256 amt) external with(env e) => cvlTransferFrom(calledContract, e.msg.sender, to, amt) expect(bool);

    // Midnight transfers.
    function _.take(MidnightBundlesV2.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => summaryTake(offer.market.loanToken, offer.buy, receiverIfTakerIsSeller, takerCallback) expect(uint256, uint256);
    function _.repay(Utils.Market market, uint256 units, address onBehalf, address callback, bytes data) external => summaryRepay(market.loanToken, units, callback) expect void;
    function _.withdraw(Utils.Market market, uint256 units, address onBehalf, address receiver) external => summaryMidnightWithdraw(market.loanToken, units, receiver) expect void;
    function _.supplyCollateral(Utils.Market market, uint256 collateralIndex, uint256 assets, address onBehalf) external => summarySupplyCollateral(market, collateralIndex, assets) expect void;
    function _.withdrawCollateral(Utils.Market market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver) external => summaryWithdrawCollateral(market, collateralIndex, assets, receiver) expect void;
    function _.touchMarket(Utils.Market market) external => cvlToId(market.loanToken) expect(bytes32);

    // Morpho transfers.
    function _.supply(Utils.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) external => summaryBlueSupply(marketParams.loanToken, assets, shares) expect(uint256, uint256);

    // Wrapped native transfers.
    function _.deposit() external with(env e) => summaryWrapNative(calledContract, e.msg.value) expect void;

    // Balance-neutral calls.
    function TokenLib.safeApprove(address token, address spender, uint256 value) internal => NONDET;

    // The offer's id is compared with the market's id, so both are modeled by the same function of the loan token.
    function IdLib.toId(Utils.Market memory market) internal returns (bytes32) => cvlToId(market.loanToken);

    // Avoid non-linear arithmetic by using non-determinism (reverts are not checked by the specification).
    function UtilsLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256) => NONDET;
    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256) => NONDET;
    function ConsumableUnitsLib.consumableUnits(address midnight, bytes32 id, MidnightBundlesV2.Offer memory offer) internal returns (uint256) => NONDET;
    function TakeAmountsLib.buyerAssetsToUnits(address midnight, bytes32 id, MidnightBundlesV2.Offer memory offer, uint256 targetBuyerAssets) internal returns (uint256) => NONDET;
    function TakeAmountsLib.sellerAssetsToUnits(address midnight, bytes32 id, MidnightBundlesV2.Offer memory offer, uint256 targetSellerAssets) internal returns (uint256) => NONDET;
}

// Bundler ERC20 balances.
persistent ghost mapping(address => mathint) bundlerBalance;

// Successful native outflow from the bundler.
persistent ghost mathint nativeSentByBundler;

// Market id of a loan token, injective thanks to its inverse.
ghost idOf(address) returns bytes32;

ghost loanTokenOf(bytes32) returns address {
    axiom forall address token. loanTokenOf(idOf(token)) == token;
}

hook CALL(uint g, address target, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint success {
    if (executingContract == currentContract && success != 0) {
        nativeSentByBundler = nativeSentByBundler + value;
    }
}

function cvlToId(address loanToken) returns bytes32 {
    return idOf(loanToken);
}

function cvlTransferFrom(address token, address from, address to, uint256 amount) returns bool {
    if (from == currentContract) bundlerBalance[token] = bundlerBalance[token] - amount;
    if (to == currentContract) bundlerBalance[token] = bundlerBalance[token] + amount;
    return true;
}

// The bundler is the caller of Midnight, so it pays when it is the buyer without a callback.
function summaryTake(address token, bool offerIsBuy, address receiverIfTakerIsSeller, address takerCallback) returns (uint256, uint256) {
    uint256 buyerAssets;
    uint256 sellerAssets;
    if (!offerIsBuy && takerCallback == 0) bundlerBalance[token] = bundlerBalance[token] - buyerAssets;
    if (offerIsBuy && receiverIfTakerIsSeller == currentContract) bundlerBalance[token] = bundlerBalance[token] + sellerAssets;
    return (buyerAssets, sellerAssets);
}

function summaryRepay(address token, uint256 units, address callback) {
    if (callback == 0) bundlerBalance[token] = bundlerBalance[token] - units;
}

function summaryMidnightWithdraw(address token, uint256 units, address receiver) {
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + units;
}

function summarySupplyCollateral(Utils.Market market, uint256 collateralIndex, uint256 assets) {
    address token = market.collateralParams[collateralIndex].token;
    bundlerBalance[token] = bundlerBalance[token] - assets;
}

function summaryWithdrawCollateral(Utils.Market market, uint256 collateralIndex, uint256 assets, address receiver) {
    address token = market.collateralParams[collateralIndex].token;
    if (receiver == currentContract) bundlerBalance[token] = bundlerBalance[token] + assets;
}

function summaryBlueSupply(address token, uint256 assets, uint256 shares) returns (uint256, uint256) {
    assert shares == 0;
    bundlerBalance[token] = bundlerBalance[token] - assets;
    uint256 returnedShares;
    return (assets, returnedShares);
}

function summaryWrapNative(address token, uint256 value) {
    bundlerBalance[token] = bundlerBalance[token] + value;
}

rule cancelAndMakePreservesBalance(env e, Utils.MarketParams blueMarket, uint256 assetsToPark, bytes32 callbackSalt, Utils.Market market, MidnightBundlesV2.CollateralTransfer[] collateralSupplies, address ratifier, bytes32 newRoot, uint256 signatureHeight, uint128 signatureNonce, uint256 signatureDeadline, uint8 v, bytes32 r, bytes32 s, MidnightBundlesV2.GroupCancellation[] groupsToCancel, bytes payload, uint256 deadline, address wrappedNative, address token) {
    require e.msg.sender != currentContract, "external caller";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    midnightBundlesV2CancelAndMake(e, blueMarket, assetsToPark, callbackSalt, market, collateralSupplies, ratifier, newRoot, signatureHeight, signatureNonce, signatureDeadline, v, r, s, groupsToCancel, payload, deadline, wrappedNative);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore == e.msg.value;
}

rule buyWithUnitsTargetAndWithdrawCollateralPreservesBalance(env e, Utils.Market market, uint256 targetUnits, uint256 maxBuyerAssets, bool reduceOnly, bool repayEnabled, MidnightBundlesV2.OfferFill[] offerFills, MidnightBundlesV2.CollateralTransfer[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline, address wrappedNative, address token) {
    require e.msg.sender != currentContract, "external caller";
    require collateralReceiver != currentContract, "no collateral residue";
    require referralFeeRecipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral(e, market, targetUnits, maxBuyerAssets, reduceOnly, repayEnabled, offerFills, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline, wrappedNative);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore == e.msg.value;
}

rule supplyCollateralAndSellWithUnitsTargetPreservesBalance(env e, Utils.Market market, uint256 targetUnits, uint256 minSellerAssets, bool reduceOnly, address receiver, MidnightBundlesV2.CollateralTransfer[] collateralSupplies, MidnightBundlesV2.OfferFill[] offerFills, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, address wrappedNative, address token) {
    require e.msg.sender != currentContract, "external caller";
    require receiver != currentContract, "no loan residue";
    require referralFeeRecipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget(e, market, targetUnits, minSellerAssets, reduceOnly, receiver, collateralSupplies, offerFills, referralFeePct, referralFeeRecipient, deadline, wrappedNative);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore == e.msg.value;
}

rule buyWithAssetsTargetAndWithdrawCollateralPreservesBalance(env e, Utils.Market market, uint256 targetBuyerAssets, uint256 minUnits, bool reduceOnly, bool repayEnabled, MidnightBundlesV2.OfferFill[] offerFills, MidnightBundlesV2.CollateralTransfer[] collateralWithdrawals, address collateralReceiver, uint256 referralFeePct, address referralFeeRecipient, uint256 maxContinuousFee, uint256 deadline, address wrappedNative, address token) {
    require e.msg.sender != currentContract, "external caller";
    require collateralReceiver != currentContract, "no collateral residue";
    require referralFeeRecipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral(e, market, targetBuyerAssets, minUnits, reduceOnly, repayEnabled, offerFills, collateralWithdrawals, collateralReceiver, referralFeePct, referralFeeRecipient, maxContinuousFee, deadline, wrappedNative);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore == e.msg.value;
}

rule supplyCollateralAndSellWithAssetsTargetPreservesBalance(env e, Utils.Market market, uint256 targetSellerAssets, uint256 maxUnits, bool reduceOnly, address receiver, MidnightBundlesV2.CollateralTransfer[] collateralSupplies, MidnightBundlesV2.OfferFill[] offerFills, uint256 referralFeePct, address referralFeeRecipient, uint256 deadline, address wrappedNative, address token) {
    require e.msg.sender != currentContract, "external caller";
    require receiver != currentContract, "no loan residue";
    require referralFeeRecipient != currentContract, "no fee residue";

    mathint before = bundlerBalance[token];
    mathint nativeSentBefore = nativeSentByBundler;
    midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget(e, market, targetSellerAssets, maxUnits, reduceOnly, receiver, collateralSupplies, offerFills, referralFeePct, referralFeeRecipient, deadline, wrappedNative);
    assert bundlerBalance[token] == before;
    assert nativeSentByBundler - nativeSentBefore == e.msg.value;
}
