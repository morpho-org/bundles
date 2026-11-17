// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.34;

import {IMorpho, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {IBluePublicAllocator} from "../../src/blue/interfaces/IBluePublicAllocator.sol";

/// @dev Stands in for the vault side of BluePublicAllocator: it holds the idle assets and the source market's supply
/// position itself, and charges the penalty the same way (exact penalty match, pulled from the caller to the vault).
contract PublicAllocatorMock is IBluePublicAllocator {
    using UtilsLib for uint256;

    error IncorrectPenalty();

    IMorpho public immutable morpho;
    mapping(address vault => uint64) public penalty;

    constructor(IMorpho morpho_) {
        morpho = morpho_;
    }

    function setPenalty(address vault, uint64 newPenalty) external {
        penalty[vault] = newPenalty;
    }

    function reallocate(
        address vault,
        address,
        MarketParams calldata deallocateMarketParams,
        address,
        MarketParams calldata allocateMarketParams,
        uint128 assets,
        uint64 penalty_
    ) external {
        _chargePenalty(vault, allocateMarketParams.loanToken, assets, penalty_);
        morpho.withdraw(deallocateMarketParams, assets, 0, address(this), address(this));
        morpho.supply(allocateMarketParams, assets, 0, address(this), "");
    }

    function allocateFromIdle(
        address vault,
        address,
        MarketParams calldata marketParams,
        uint128 assets,
        uint64 penalty_
    ) external {
        _chargePenalty(vault, marketParams.loanToken, assets, penalty_);
        morpho.supply(marketParams, assets, 0, address(this), "");
    }

    function _chargePenalty(address vault, address token, uint256 assets, uint64 penalty_) internal {
        require(penalty[vault] == penalty_, IncorrectPenalty());
        uint256 penaltyAssets = assets.mulDivUp(penalty_, WAD);
        if (penaltyAssets > 0) SafeTransferLib.safeTransferFrom(token, msg.sender, vault, penaltyAssets);
    }
}
