// SPDX-License-Identifier: MIT

// Also proves that the bundler never passes Midnight a callback that Midnight would pull tokens from, since it could hold someone else's tokens: no taker callback when the taker buys, and no repay callback.

import "NoThirdPartyPull.spec";

methods {
    function _.take(Midnight.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => noTakerBuyerCallbackReturns(offer.buy, takerCallback) expect(uint256, uint256);
    function _.repay(Midnight.Market market, uint256 units, address onBehalf, address callback, bytes data) external => noRepayCallback(callback) expect void;
}

// When the taker buys, Midnight pulls the tokens owed from the taker callback, if one is passed, instead of from the bundler.
function noTakerBuyerCallbackReturns(bool offerBuy, address takerCallback) returns (uint256, uint256) {
    if (!offerBuy && takerCallback != 0) pulledFromOther = true;
    uint256 buyerAssets;
    uint256 sellerAssets;
    return (buyerAssets, sellerAssets);
}

// Midnight pulls the repaid tokens from the callback, if one is passed, instead of from the bundler.
function noRepayCallback(address callback) {
    if (callback != 0) pulledFromOther = true;
}

use rule noThirdPartyPull;
