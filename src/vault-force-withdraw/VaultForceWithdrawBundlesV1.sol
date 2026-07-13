// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVaultForceWithdrawBundlesV1, SharesPermit} from "./interfaces/IVaultForceWithdrawBundlesV1.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IERC20Permit} from "../libraries/interfaces/IERC20Permit.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {WAD} from "../../lib/vault-v2/src/libraries/ConstantsLib.sol";
import {IMorphoMarketV1AdapterV2} from "../../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {IMetaMorpho} from "../../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IMorpho, MarketParams, Id} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoSupplyCallback,
    IMorphoFlashLoanCallback
} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {MorphoBalancesLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/UtilsLib.sol";

/// @dev Meant to be used to force withdraw assets from a vault that allocates assets to Morpho Blue.
/// @dev Inherits the token safety requirements of Morpho Vaults and their dependencies.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
contract VaultForceWithdrawBundlesV1 is IVaultForceWithdrawBundlesV1, IMorphoSupplyCallback, IMorphoFlashLoanCallback {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;

    constructor(address _blue) {
        BLUE = _blue;
    }

    /// FORCE WITHDRAW ILLIQUID VAULT V1 ///

    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
    /// @dev Requires Morpho Blue to have more than the assets in liquidity.
    /// @dev Requires the sender to have enough shares to withdraw assets.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields positions on the markets.
    /// @dev It's acknowledged that it is possible to call this function with duplicate markets in the list.
    function vaultBundlesV1ForceWithdrawIlliquidVaultV1(
        address vault,
        MarketParams[] memory marketParamsList,
        uint256 forceWithdrawAssets,
        SharesPermit memory sharesPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(address(IMetaMorpho(vault).MORPHO()) == BLUE, MorphoMismatch());

        permitShares(vault, sharesPermit);
        address loanToken = marketParamsList[0].loanToken;
        TokenLib.forceApproveMax(loanToken, BLUE);

        bytes memory data = abi.encode(vault, marketParamsList, msg.sender);
        IMorpho(BLUE).flashLoan(loanToken, forceWithdrawAssets, data);
    }

    function onMorphoFlashLoan(uint256 forceWithdrawAssets, bytes calldata data) external {
        require(msg.sender == BLUE, Unauthorized());
        (address vault, MarketParams[] memory marketParamsList, address sender) =
            abi.decode(data, (address, MarketParams[], address));

        uint256 assetsToDeallocate = forceWithdrawAssets;
        for (uint256 i = 0; assetsToDeallocate > 0; i++) {
            MarketParams memory marketParams = marketParamsList[i];
            if (!IMetaMorpho(vault).config(marketParams.id()).enabled) continue;

            uint256 vaultAssets = MorphoBalancesLib.expectedSupplyAssets(IMorpho(BLUE), marketParams, vault);
            uint256 assets = UtilsLib.min(vaultAssets, assetsToDeallocate);
            assetsToDeallocate -= assets;

            if (assets > 0) {
                IMorpho(BLUE).supply(marketParams, assets, 0, sender, "");
            }
        }

        IMetaMorpho(vault).withdraw(forceWithdrawAssets, address(this), sender);
    }

    /// FORCE WITHDRAW ILLIQUID VAULT V2 ///

    /// @dev Assumes that adapter is a Morpho Blue adapter.
    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
    /// @dev The assetsToDeallocate amount is floor(forceWithdrawAssets * WAD / (WAD + penalty)).
    /// @dev Requires Morpho Blue to have more than assetsToDeallocate in loan token balance.
    /// @dev Requires the sender to have enough shares to withdraw ceil(assets *  penalty / WAD) and then assets, for each market in the list, where the sum of the assets is equal to assetsToDeallocate.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields positions on the markets, and potentially pays the penalty.
    /// @dev If the liquidity adapter has some liquidity, withdrawing from the vault instead of calling this function avoids the penalty.
    /// @dev It's acknowledged that it is possible to call this function with duplicate markets in the list.
    function vaultBundlesV1ForceWithdrawIlliquidVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParams,
        uint256 forceWithdrawAssets,
        SharesPermit memory sharesPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());

        permitShares(vault, sharesPermit);
        TokenLib.forceApproveMax(marketParams[0].loanToken, BLUE);

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 assetsToDeallocate = forceWithdrawAssets * WAD / (WAD + penalty);

        for (uint256 i = 0; assetsToDeallocate > 0; i++) {
            uint256 adapterShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(Id.unwrap(marketParams[i].id()));
            (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), marketParams[i]);
            uint256 adapterAssets = adapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            uint256 assets = UtilsLib.min(adapterAssets, assetsToDeallocate);
            assetsToDeallocate -= assets;

            if (assets > 0) {
                bytes memory data = abi.encode(vault, adapter, marketParams[i], msg.sender);
                IMorpho(BLUE).supply(marketParams[i], assets, 0, msg.sender, data);
            }
        }
    }

    function onMorphoSupply(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, Unauthorized());
        (address vault, address adapter, MarketParams memory marketParams, address sender) =
            abi.decode(data, (address, address, MarketParams, address));

        IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), assets, sender);
        IVaultV2(vault).withdraw(assets, address(this), sender);
    }

    /// FORCE WITHDRAW LIQUID VAULT V2 ///

    /// @dev Assumes that adapter is a Morpho Blue adapter.
    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
    /// @dev Starts by withdrawing without penalty everything the vault can pay: its idle assets and the liquidity available through the liquidity adapter.
    /// @dev The assetsToDeallocate amount is floor(forceWithdrawAssets - assetsToWithdraw * WAD / (WAD + penalty)), where assetsToWithdraw is the amount withdrawn without penalty.
    /// @dev The assetsToDeallocate amount is force deallocated by looping over the adapter's markets, taking from each market as much as its liquidity and the adapter's position allow before moving to the next one.
    /// @dev Requires the adapter's markets to be liquid enough, otherwise the loop runs past the market list and reverts.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to msg.sender.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
    function vaultBundlesV1ForceWithdrawLiquidVaultV2(
        address vault,
        address adapter,
        uint256 forceWithdrawAssets,
        SharesPermit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());
        require(referralFeePct < WAD, PctExceeded());

        permitShares(vault, sharesPermit);

        address asset = IVaultV2(vault).asset();
        uint256 withdrawableAssets = IERC20(asset).balanceOf(vault);
        address liquidityAdapter = IVaultV2(vault).liquidityAdapter();
        if (liquidityAdapter != address(0)) {
            require(liquidityAdapter == adapter, LiquidityAdapterMismatch());
            MarketParams memory liquidityMarketParams = abi.decode(IVaultV2(vault).liquidityData(), (MarketParams));
            uint256 liquidityAdapterShares =
                IMorphoMarketV1AdapterV2(liquidityAdapter).supplyShares(Id.unwrap(liquidityMarketParams.id()));
            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), liquidityMarketParams);
            uint256 liquidityAdapterAssets = liquidityAdapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            withdrawableAssets += UtilsLib.min(liquidityAdapterAssets, totalSupplyAssets - totalBorrowAssets);
        }
        uint256 assetsToWithdraw = UtilsLib.min(forceWithdrawAssets, withdrawableAssets);
        IVaultV2(vault).withdraw(assetsToWithdraw, address(this), msg.sender);

        // pre-fetching the market list because the deallocate could drop a market from the list.
        uint256 marketIdsLength = IMorphoMarketV1AdapterV2(adapter).marketIdsLength();
        bytes32[] memory marketIds = new bytes32[](marketIdsLength);
        for (uint256 i = 0; i < marketIdsLength; i++) {
            marketIds[i] = IMorphoMarketV1AdapterV2(adapter).marketIds(i);
        }

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 assetsToDeallocate = (forceWithdrawAssets - assetsToWithdraw) * WAD / (WAD + penalty);
        uint256 remainingAssets = assetsToDeallocate;

        for (uint256 i = 0; remainingAssets > 0; i++) {
            MarketParams memory marketParams = IMorpho(BLUE).idToMarketParams(Id.wrap(marketIds[i]));
            uint256 adapterShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(marketIds[i]);
            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), marketParams);
            uint256 adapterAssets = adapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            uint256 availableToWithdraw = UtilsLib.min(adapterAssets, totalSupplyAssets - totalBorrowAssets);
            uint256 assets = UtilsLib.min(availableToWithdraw, remainingAssets);
            remainingAssets -= assets;

            IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), assets, msg.sender);
        }

        IVaultV2(vault).withdraw(assetsToDeallocate, address(this), msg.sender);

        uint256 withdrawn = assetsToWithdraw + assetsToDeallocate;
        uint256 referralFeeAssets = withdrawn * referralFeePct / WAD;
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(asset, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(asset, msg.sender, withdrawn - referralFeeAssets);
    }

    /// INTERNAL ///

    /// @dev Skipped when the permit is empty (v, r and s all zero; which doesn't correspond to a valid signature), useful shares are already permitted.
    /// @dev Skipped on an already consumed nonce (e.g. a front-run submission): the permit is not submitted in that case.
    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until sharesPermit.deadline, as revoking on the vault does not consume the nonce.
    function permitShares(address vault, SharesPermit memory sharesPermit) internal {
        bool emptyPermit = sharesPermit.v == 0 && sharesPermit.r == 0 && sharesPermit.s == 0;

        if (!emptyPermit && IERC20Permit(vault).nonces(msg.sender) <= sharesPermit.nonce) {
            IERC20Permit(vault)
                .permit(
                    msg.sender,
                    address(this),
                    sharesPermit.value,
                    sharesPermit.deadline,
                    sharesPermit.v,
                    sharesPermit.r,
                    sharesPermit.s
                );
        }
    }
}
