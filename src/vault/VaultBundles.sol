// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVaultBundles} from "./IVaultBundles.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMetaMorpho, Id as MMId} from "../../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IMorphoMarketV1AdapterV2} from "../../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IMorpho, MarketParams, Id} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {WAD} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {UtilsLib} from "../../lib/midnight/src/libraries/UtilsLib.sol";

/// @dev Inherits the token safety requirements of Morpho Vaults and their dependencies.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract VaultBundles is IVaultBundles {
    using MarketParamsLib for MarketParams;
    using UtilsLib for uint256;

    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public immutable BLUE;

    constructor(address _blue) {
        BLUE = _blue;
    }

    /// @dev Reverts if the transaction is executed after `deadline`.
    modifier checkDeadline(uint256 deadline) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    /// STRUCTS ///

    struct SupplyData {
        address vault;
        address adapter;
        MarketParams marketParams;
        address onBehalf;
    }

    struct FlashLoanData {
        address vault;
        MarketParams marketParams;
        address onBehalf;
    }

    /// FORCE WITHDRAW ILLIQUID VAULT V2 ///

    /// @dev onBehalf must have given max allowance over vault shares to msg.sender (if different from onBehalf).
    /// @dev onBehalf must have given enough allowance over vault shares to this bundler. Using max allowance makes sure that this condition is met.
    /// @dev The adapter must be part of the vault, and the market must be part of the adapter.
    /// @dev The deallocatedAssets amount is floor(assets * WAD / (WAD + penalty)).
    /// @dev Reverts if the deallocatedAssets amount is 0.
    /// @dev Requires Morpho Blue to have more than the deallocated assets in liquidity.
    /// @dev Requires onBehalf to have enough shares to withdraw ceil(deallocatedAssets *  penalty / WAD) and then deallocatedAssets.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields a position on the market.
    function forceWithdrawIlliquidVaultV2(
        address vault,
        address adapter,
        MarketParams memory marketParams,
        address onBehalf,
        uint256 assets,
        uint256 deadline
    ) external checkDeadline(deadline) {
        require(
            onBehalf == msg.sender || IVaultV2(vault).allowance(onBehalf, msg.sender) == type(uint256).max,
            Unauthorized()
        );
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        bytes32 id = Id.unwrap(marketParams.id());
        require(IMorphoMarketV1AdapterV2(adapter).supplyShares(id) > 0, MarketNotPartOfAdapter());

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 deallocatedAssets = assets.mulDivDown(WAD, WAD + penalty);
        bytes memory data = abi.encode(SupplyData(vault, adapter, marketParams, onBehalf));
        IMorpho(BLUE).supply(marketParams, deallocatedAssets, 0, onBehalf, data);
    }

    function onMorphoSupply(uint256 deallocatedAssets, bytes memory data) external {
        require(msg.sender == BLUE, Unauthorized());
        SupplyData memory s = abi.decode(data, (SupplyData));

        IVaultV2(s.vault).forceDeallocate(s.adapter, abi.encode(s.marketParams), deallocatedAssets, s.onBehalf);
        IVaultV2(s.vault).withdraw(deallocatedAssets, address(this), s.onBehalf);
    }

    /// FORCE WITHDRAW LIQUID VAULT V2 ///

    /// @dev onBehalf must have given max allowance over vault shares to msg.sender (if different from onBehalf).
    /// @dev onBehalf must have given enough allowance over vault shares to this bundler. Using max allowance makes sure that this condition is met.
    /// @dev The adapter must be part of the vault, and the market must be part of the adapter.
    /// @dev The deallocatedAssets amount is floor(assets * WAD / (WAD + penalty)).
    /// @dev Requires the vault to have more than the deallocated assets in liquidity.
    /// @dev Requires onBehalf to have enough shares to withdraw ceil(deallocatedAssets *  penalty / WAD) and then deallocatedAssets.
    function forceWithdrawLiquidVaultV2(
        address vault,
        address adapter,
        MarketParams memory marketParams,
        address onBehalf,
        uint256 assets,
        uint256 deadline
    ) external checkDeadline(deadline) {
        require(
            onBehalf == msg.sender || IVaultV2(vault).allowance(onBehalf, msg.sender) == type(uint256).max,
            Unauthorized()
        );
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        bytes32 id = Id.unwrap(marketParams.id());
        require(IMorphoMarketV1AdapterV2(adapter).supplyShares(id) > 0, MarketNotPartOfAdapter());

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 deallocatedAssets = assets.mulDivDown(WAD, WAD + penalty);
        IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), deallocatedAssets, onBehalf);
        IVaultV2(vault).withdraw(deallocatedAssets, onBehalf, onBehalf);
    }

    /// FORCE WITHDRAW ILLIQUID VAULT V1 ///

    /// @dev onBehalf must have given max allowance over vault shares to msg.sender (if different from onBehalf).
    /// @dev onBehalf must have given enough allowance over vault shares to this bundler. Using max allowance makes sure that this condition is met.
    /// @dev The market must be part of the vault.
    /// @dev Requires Morpho Blue to have more than the assets in liquidity.
    /// @dev Requires onBehalf to have enough shares to withdraw assets.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields a position on the market.
    function forceWithdrawIlliquidVaultV1(
        address vault,
        MarketParams memory marketParams,
        address onBehalf,
        uint256 assets,
        uint256 deadline
    ) external checkDeadline(deadline) {
        require(
            onBehalf == msg.sender || IMetaMorpho(vault).allowance(onBehalf, msg.sender) == type(uint256).max,
            Unauthorized()
        );
        bytes32 id = Id.unwrap(marketParams.id());
        require(IMetaMorpho(vault).config(MMId.wrap(id)).enabled, MarketNotPartOfVault());

        TokenLib.forceApproveMax(marketParams.loanToken, BLUE);

        bytes memory data = abi.encode(FlashLoanData(vault, marketParams, onBehalf));
        IMorpho(BLUE).flashLoan(marketParams.loanToken, assets, data);
    }

    function onMorphoFlashLoan(uint256 assets, bytes memory data) external {
        require(msg.sender == BLUE, Unauthorized());
        FlashLoanData memory f = abi.decode(data, (FlashLoanData));

        IMorpho(BLUE).supply(f.marketParams, assets, 0, f.onBehalf, "");
        IMetaMorpho(f.vault).withdraw(assets, address(this), f.onBehalf);
    }
}
