// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVaultBundles} from "./IVaultBundles.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IMetaMorpho, Id as MMId} from "../../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {WAD} from "../../lib/vault-v2/src/libraries/ConstantsLib.sol";
import {IMorphoMarketV1AdapterV2} from "../../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {IMorpho, MarketParams, Id} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/morpho-blue/src/libraries/SharesMathLib.sol";

/// @dev Inherits the token safety requirements of Morpho Vaults and their dependencies.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are allowed.
/// @dev Zero checks are not systematically performed.
contract VaultBundles is IVaultBundles {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;

    constructor(address _blue) {
        BLUE = _blue;
    }

    /// STRUCTS ///

    struct SupplyData {
        address vault;
        address adapter;
        MarketParams marketParams;
        address sender;
    }

    struct FlashLoanData {
        address vault;
        MarketParams[] marketParamsList;
        address sender;
    }

    /// FORCE WITHDRAW ILLIQUID VAULT V2 ///

    /// @dev The sender must have given enough allowance over vault shares to this bundler. Using max allowance makes sure that this condition is met.
    /// @dev The deallocatedAssets amount is floor(assets * WAD / (WAD + penalty)).
    /// @dev Reverts if the deallocatedAssets amount is 0.
    /// @dev Requires Morpho Blue to have more than the deallocated assets in liquidity.
    /// @dev Requires the sender to have enough shares to withdraw ceil(assets *  penalty / WAD) and then assets, for each market in the list, where the sum of the assets is equal to deallocatedAssets.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields a position on the markets.
    /// @dev If the liquidity adapter has some liquidity, withdrawing from the vault instead of calling this function avoids the penalty.
    function forceWithdrawIlliquidVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParams,
        uint256 forceWithdrawAssets,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());
        require(marketParams.length > 0, NoMarketParams());

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 remainingToDeallocate = forceWithdrawAssets * WAD / (WAD + penalty);

        for (uint256 i = 0; remainingToDeallocate > 0; i++) {
            bytes32 id = Id.unwrap(marketParams[i].id());
            // Use the shares accounted in the adapter to compute the available to withdraw.
            uint256 supplyShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(id);
            (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), marketParams[i]);
            uint256 availableToWithdraw = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            uint256 assets = min(availableToWithdraw, remainingToDeallocate);

            // Markets for which the adapter has no shares are skipped.
            if (assets > 0) {
                TokenLib.forceApproveMax(marketParams[i].loanToken, BLUE);

                bytes memory data = abi.encode(SupplyData(vault, adapter, marketParams[i], msg.sender));
                IMorpho(BLUE).supply(marketParams[i], assets, 0, msg.sender, data);

                remainingToDeallocate -= assets;
            }
        }
    }

    function onMorphoSupply(uint256 assets, bytes memory data) external {
        require(msg.sender == BLUE, Unauthorized());
        SupplyData memory s = abi.decode(data, (SupplyData));

        IVaultV2(s.vault).forceDeallocate(s.adapter, abi.encode(s.marketParams), assets, s.sender);
        IVaultV2(s.vault).withdraw(assets, address(this), s.sender);
    }

    /// FORCE WITHDRAW LIQUID VAULT V2 ///

    /// @dev The sender must have given enough allowance over vault shares to this bundler. Using max allowance makes sure that this condition is met.
    /// @dev The deallocatedAssets amount is floor(forceWithdrawAssets * WAD / (WAD + penalty)).
    /// @dev Requires the vault to have more than the deallocated assets in liquidity.
    /// @dev Requires the sender to have enough shares to withdraw ceil(deallocatedAssets *  penalty / WAD) and then deallocatedAssets.
    function forceWithdrawLiquidVaultV2(
        address vault,
        address adapter,
        MarketParams memory marketParams,
        uint256 forceWithdrawAssets,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());
        bytes32 id = Id.unwrap(marketParams.id());
        require(IMorphoMarketV1AdapterV2(adapter).supplyShares(id) > 0, MarketNotPartOfAdapter());

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 deallocatedAssets = forceWithdrawAssets * WAD / (WAD + penalty);
        IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), deallocatedAssets, msg.sender);
        IVaultV2(vault).withdraw(deallocatedAssets, msg.sender, msg.sender);
    }

    /// FORCE WITHDRAW ILLIQUID VAULT V1 ///

    /// @dev The sender must have given enough allowance over vault shares to this bundler. Using max allowance makes sure that this condition is met.
    /// @dev Requires Morpho Blue to have more than the assets in liquidity.
    /// @dev Requires onBehalf to have enough shares to withdraw assets.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields a position on the market.
    /// @dev All markets should belong to the vault.
    function forceWithdrawIlliquidVaultV1(
        address vault,
        MarketParams[] memory marketParamsList,
        uint256 assets,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(address(IMetaMorpho(vault).MORPHO()) == BLUE, MorphoMismatch());
        require(marketParamsList.length > 0, NoMarketParams());
        address loanToken = marketParamsList[0].loanToken;
        TokenLib.forceApproveMax(loanToken, BLUE);

        bytes memory data = abi.encode(FlashLoanData(vault, marketParamsList, msg.sender));
        IMorpho(BLUE).flashLoan(loanToken, assets, data);
    }

    function onMorphoFlashLoan(uint256 assets, bytes memory data) external {
        require(msg.sender == BLUE, Unauthorized());

        uint256 remainingAssets = assets;

        FlashLoanData memory f = abi.decode(data, (FlashLoanData));
        for (uint256 i = 0; remainingAssets > 0; i++) {
            MarketParams memory marketParams = f.marketParamsList[i];
            bytes32 id = Id.unwrap(marketParams.id());
            require(IMetaMorpho(f.vault).config(MMId.wrap(id)).enabled, MarketNotPartOfVault());

            uint256 availableToWithdraw = MorphoBalancesLib.expectedSupplyAssets(IMorpho(BLUE), marketParams, f.vault);
            uint256 assetsToSupply = min(availableToWithdraw, remainingAssets);

            IMorpho(BLUE).supply(marketParams, assetsToSupply, 0, f.sender, "");
            remainingAssets -= assetsToSupply;
        }

        IMetaMorpho(f.vault).withdraw(assets, address(this), f.sender);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
