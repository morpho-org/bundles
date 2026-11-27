// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {Offer} from "../../../lib/midnight/src/interfaces/IMidnight.sol";

interface IMidnightAdapter {
    function parentVault() external view returns (address);
    function take(Offer memory offer, bytes calldata ratifierData, uint256 units, bytes calldata takerCallbackData)
        external
        returns (uint256 buyerAssets, uint256 sellerAssets);
}
