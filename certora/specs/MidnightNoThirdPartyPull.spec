// SPDX-License-Identifier: MIT

// Also proves that the bundler never makes Midnight pull tokens from a callback, which could hold someone else's tokens.

import "NoThirdPartyPull.spec";

methods {
    function _.take(Midnight.Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) external => noCallbackReturns(takerCallback) expect(uint256, uint256);
    function _.repay(Midnight.Market market, uint256 units, address onBehalf, address callback, bytes data) external => noCallback(callback) expect void;
}

// When a callback is passed, Midnight pulls the tokens owed from it instead of from the bundler.
function noCallback(address callback) {
    if (callback != 0) pulledFromOther = true;
}

function noCallbackReturns(address callback) returns (uint256, uint256) {
    noCallback(callback);
    uint256 buyerAssets;
    uint256 sellerAssets;
    return (buyerAssets, sellerAssets);
}
