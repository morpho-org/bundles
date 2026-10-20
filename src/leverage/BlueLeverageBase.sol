// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IBlueLeverageBase} from "./interfaces/IBlueLeverageBase.sol";
import {IMorpho, MarketParams, Market, Position} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "../../lib/morpho-blue/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "../../lib/morpho-blue/src/libraries/ConstantsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

abstract contract BlueLeverageBase is IBlueLeverageBase {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;

    constructor(address blue) {
        BLUE = blue;
    }

    /// @dev Reverts unless the user's LTV is at or below maxLtv; type(uint256).max disables the check.
    function requireMaxLtv(MarketParams memory marketParams, address user, uint256 maxLtv) internal {
        if (maxLtv != type(uint256).max) {
            Position memory position = IMorpho(BLUE).position(marketParams.id(), user);
            if (position.borrowShares != 0) {
                Market memory market = IMorpho(BLUE).market(marketParams.id());
                if (market.lastUpdate != block.timestamp) {
                    IMorpho(BLUE).accrueInterest(marketParams);
                    market = IMorpho(BLUE).market(marketParams.id());
                }

                uint256 borrowed =
                    uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
                uint256 price = IOracle(marketParams.oracle).price();
                uint256 maxBorrow =
                    uint256(position.collateral).mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(maxLtv, WAD);
                require(borrowed <= maxBorrow, LtvExceeded());
            }
        }
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
