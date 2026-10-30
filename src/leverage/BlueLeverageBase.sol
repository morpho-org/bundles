// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IBlueLeverageBase} from "./interfaces/IBlueLeverageBase.sol";
import {IMorpho, MarketParams, Market, Position} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";

abstract contract BlueLeverageBase is IBlueLeverageBase {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;

    constructor(address blue) {
        BLUE = blue;
    }

    /// @dev Accrues interest before reading the debt so repaying all borrow shares charges exactly debtAssets.
    function readFullCloseTarget(MarketParams memory marketParams)
        internal
        returns (uint256 borrowShares, uint256 debtAssets, uint256 collateral)
    {
        IMorpho(BLUE).accrueInterest(marketParams);
        Position memory position = IMorpho(BLUE).position(marketParams.id(), msg.sender);
        borrowShares = position.borrowShares;
        collateral = position.collateral;

        if (borrowShares != 0) {
            Market memory market = IMorpho(BLUE).market(marketParams.id());
            debtAssets = borrowShares.toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        }
    }
}
