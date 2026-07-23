// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {IVaultExitBundlesV1, SharesPermit} from "./interfaces/IVaultExitBundlesV1.sol";
import {TokenLib} from "../libraries/TokenLib.sol";
import {IERC20Permit} from "../libraries/interfaces/IERC20Permit.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {MathLib} from "../../lib/vault-v2/src/libraries/MathLib.sol";
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

/// @dev Meant to be used to exit a vault that allocates assets to Morpho Blue. The user either gets Morpho Blue shares (in-kind redemption) or assets (force withdrawal).
/// @dev Vaults that are used with this contract must be Vault V1 (MetaMorpho V1 or V1.1) or Vault V2.
/// @dev Vault V2 that are used with this contract must have only one adapter, and that adapter must be the MorphoMarketV1AdapterV2.
/// @dev The Morpho Blue fee recipient shouldn't be a vault that is used with this contract, otherwise its expected supply assets are underestimated since the shares internally computed do not include the accrued fee shares.
/// @dev Inherits the token safety requirements of Morpho Vaults and their dependencies.
/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
/// @dev Gated vaults (Vault V2) require this contract to be permitted by receiveAssetsGate, as it receives the withdrawn assets.
/// @dev No-ops are not systematically prevented.
/// @dev Zero checks are not systematically performed.
contract VaultExitBundlesV1 is IVaultExitBundlesV1, IMorphoSupplyCallback, IMorphoFlashLoanCallback {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address public immutable BLUE;

    constructor(address _blue) {
        BLUE = _blue;
    }

    /// IN-KIND REDEMPTION VAULT V1 ///

    /// @dev Exit from a Vault V1 and get Morpho Blue shares, even if the vault is illiquid and if the vault roles are not cooperating.
    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
    /// @dev Requires Morpho Blue to have at least exitAssets in loan token balance.
    /// @dev Requires the sender to have enough shares to withdraw exitAssets.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields positions on the markets.
    /// @dev It's acknowledged that it is possible to call this function with duplicate markets in the list.
    /// @dev minSharePriceE27 lower-bounds the realized exit share price (exit assets per share, scaled by 1e27).
    /// @dev The minted Morpho Blue shares are not checked: at most a wei per supply is lost to rounding, assuming a supply share price of at most one asset per share.
    function vaultExitBundlesV1InKindRedemptionVaultV1(
        address vault,
        MarketParams[] memory marketParamsList,
        uint256 exitAssets,
        uint256 minSharePriceE27,
        SharesPermit memory sharesPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(address(IMetaMorpho(vault).MORPHO()) == BLUE, MorphoMismatch());

        permitShares(vault, sharesPermit);
        address loanToken = IMetaMorpho(vault).asset();
        TokenLib.forceApproveMax(loanToken, BLUE);

        uint256 sharesBefore = IERC20(vault).balanceOf(msg.sender);
        bytes memory data = abi.encode(vault, marketParamsList, msg.sender);
        IMorpho(BLUE).flashLoan(loanToken, exitAssets, data);

        uint256 sharesBurned = sharesBefore - IERC20(vault).balanceOf(msg.sender);
        require(sharesBurned == 0 || exitAssets.mulDivDown(1e27, sharesBurned) >= minSharePriceE27, SlippageExceeded());
    }

    function onMorphoFlashLoan(uint256 exitAssets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (address vault, MarketParams[] memory marketParamsList, address sender) =
            abi.decode(data, (address, MarketParams[], address));

        uint256 assetsToDeallocate = exitAssets;
        for (uint256 i; assetsToDeallocate > 0; i++) {
            MarketParams memory marketParams = marketParamsList[i];
            if (!IMetaMorpho(vault).config(marketParams.id()).enabled) continue;

            uint256 vaultAssets = MorphoBalancesLib.expectedSupplyAssets(IMorpho(BLUE), marketParams, vault);
            uint256 assets = UtilsLib.min(vaultAssets, assetsToDeallocate);
            assetsToDeallocate -= assets;

            if (assets > 0) {
                IMorpho(BLUE).supply(marketParams, assets, 0, sender, "");
            }
        }

        IMetaMorpho(vault).withdraw(exitAssets, address(this), sender);
    }

    /// IN-KIND REDEMPTION VAULT V2 ///

    /// @dev Exit from a Vault V2 and get Morpho Blue shares, even if the vault is illiquid and if the vault roles are not cooperating.
    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
    /// @dev The assetsToDeallocate amount is floor(exitAssets * WAD / (WAD + penalty)).
    /// @dev Requires Morpho Blue to have at least assetsToDeallocate in loan token balance.
    /// @dev Requires the sender to have enough shares to withdraw ceil(assets * penalty / WAD) and then assets, for each market in the list, where the sum of the assets is equal to assetsToDeallocate.
    /// @dev It may be the case that the vault became liquid, but calling this function still yields positions on the markets, and potentially pays the penalty.
    /// @dev If the liquidity adapter has some liquidity, withdrawing from the vault instead of calling this function avoids the penalty.
    /// @dev It's acknowledged that it is possible to call this function with duplicate markets in the list.
    /// @dev minSharePriceE27 lower-bounds the realized exit share price (withdrawn assets per share, scaled by 1e27). The force deallocate penalty counts as withdrawn assets, so it does not lower this price.
    /// @dev The minted Morpho Blue shares are not checked: at most a wei per supply is lost to rounding, assuming a supply share price of at most one asset per share (which the adapter checks at each allocation).
    function vaultExitBundlesV1InKindRedemptionVaultV2(
        address vault,
        address adapter,
        MarketParams[] memory marketParamsList,
        uint256 exitAssets,
        uint256 minSharePriceE27,
        SharesPermit memory sharesPermit,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).adaptersLength() == 1, InvalidAdaptersLength());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());

        permitShares(vault, sharesPermit);
        TokenLib.forceApproveMax(IVaultV2(vault).asset(), BLUE);

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 assetsToDeallocate = exitAssets.mulDivDown(WAD, WAD + penalty);
        uint256 sharesBefore = IERC20(vault).balanceOf(msg.sender);
        uint256 withdrawnAssets;

        for (uint256 i; assetsToDeallocate > 0; i++) {
            bytes32 marketId = Id.unwrap(marketParamsList[i].id());
            uint256 adapterAssets = IMorphoMarketV1AdapterV2(adapter).expectedSupplyAssets(marketId);
            uint256 assets = UtilsLib.min(adapterAssets, assetsToDeallocate);
            assetsToDeallocate -= assets;

            if (assets > 0) {
                withdrawnAssets += assets + assets.mulDivUp(penalty, WAD);
                bytes memory data = abi.encode(vault, adapter, marketParamsList[i], msg.sender);
                IMorpho(BLUE).supply(marketParamsList[i], assets, 0, msg.sender, data);
            }
        }

        uint256 sharesBurned = sharesBefore - IERC20(vault).balanceOf(msg.sender);
        require(
            sharesBurned == 0 || withdrawnAssets.mulDivDown(1e27, sharesBurned) >= minSharePriceE27, SlippageExceeded()
        );
    }

    function onMorphoSupply(uint256 assets, bytes calldata data) external {
        require(msg.sender == BLUE, UnauthorizedCallback());
        (address vault, address adapter, MarketParams memory marketParams, address sender) =
            abi.decode(data, (address, address, MarketParams, address));

        IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), assets, sender);
        IVaultV2(vault).withdraw(assets, address(this), sender);
    }

    /// FORCE WITHDRAW VAULT V2 ///

    /// @dev Withdraw from a Vault V2, even if the vault doesn't have enough idle and liquidity adapter assets.
    /// @dev Requires the adapter's markets to be liquid enough, otherwise the loop runs past the market list and reverts.
    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
    /// @dev Starts by withdrawing without penalty everything the vault can pay: its idle assets and the liquidity available through the liquidity adapter.
    /// @dev The assetsToDeallocate amount is floor((exitAssets - assetsToWithdraw) * WAD / (WAD + penalty)), where assetsToWithdraw is the amount withdrawn without penalty.
    /// @dev The assetsToDeallocate amount is force deallocated by looping over the adapter's markets, taking from each market as much as its liquidity and the adapter's position allow before moving to the next one.
    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to msg.sender.
    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
    /// @dev minSharePriceE27 lower-bounds the realized exit share price (exit assets per share, scaled by 1e27). The force deallocate penalty is included in the exit assets, so it does not lower this price.
    function vaultExitBundlesV1ForceWithdrawVaultV2(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 minSharePriceE27,
        SharesPermit memory sharesPermit,
        uint256 referralFeePct,
        address referralFeeRecipient,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).adaptersLength() == 1, InvalidAdaptersLength());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());
        require(referralFeePct < WAD, PctExceeded());

        permitShares(vault, sharesPermit);
        uint256 sharesBefore = IERC20(vault).balanceOf(msg.sender);

        address asset = IVaultV2(vault).asset();
        uint256 withdrawableAssets = IERC20(asset).balanceOf(vault);
        address liquidityAdapter = IVaultV2(vault).liquidityAdapter();
        if (liquidityAdapter != address(0)) {
            MarketParams memory liquidityMarketParams = abi.decode(IVaultV2(vault).liquidityData(), (MarketParams));
            uint256 liquidityAdapterShares =
                IMorphoMarketV1AdapterV2(liquidityAdapter).supplyShares(Id.unwrap(liquidityMarketParams.id()));
            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), liquidityMarketParams);
            uint256 liquidityAdapterAssets = liquidityAdapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            withdrawableAssets += UtilsLib.min(liquidityAdapterAssets, totalSupplyAssets - totalBorrowAssets);
        }
        uint256 assetsToWithdraw = UtilsLib.min(exitAssets, withdrawableAssets);
        IVaultV2(vault).withdraw(assetsToWithdraw, address(this), msg.sender);

        // pre-fetching the market list because the deallocate could drop a market from the list.
        uint256 marketIdsLength = IMorphoMarketV1AdapterV2(adapter).marketIdsLength();
        bytes32[] memory marketIds = new bytes32[](marketIdsLength);
        for (uint256 i; i < marketIdsLength; i++) {
            marketIds[i] = IMorphoMarketV1AdapterV2(adapter).marketIds(i);
        }

        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
        uint256 assetsToDeallocate = (exitAssets - assetsToWithdraw).mulDivDown(WAD, WAD + penalty);
        uint256 remainingAssets = assetsToDeallocate;

        for (uint256 i; remainingAssets > 0; i++) {
            MarketParams memory marketParams = IMorpho(BLUE).idToMarketParams(Id.wrap(marketIds[i]));
            uint256 adapterShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(marketIds[i]);
            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), marketParams);
            uint256 adapterAssets = adapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
            uint256 availableToWithdraw = UtilsLib.min(adapterAssets, totalSupplyAssets - totalBorrowAssets);
            uint256 assets = UtilsLib.min(availableToWithdraw, remainingAssets);
            remainingAssets -= assets;

            if (assets > 0) {
                IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), assets, msg.sender);
            }
        }

        IVaultV2(vault).withdraw(assetsToDeallocate, address(this), msg.sender);

        uint256 withdrawn = assetsToWithdraw + assetsToDeallocate;
        uint256 sharesBurned = sharesBefore - IERC20(vault).balanceOf(msg.sender);
        require(sharesBurned == 0 || exitAssets.mulDivDown(1e27, sharesBurned) >= minSharePriceE27, SlippageExceeded());

        uint256 referralFeeAssets = withdrawn.mulDivDown(referralFeePct, WAD);
        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(asset, referralFeeRecipient, referralFeeAssets);
        SafeTransferLib.safeTransfer(asset, msg.sender, withdrawn - referralFeeAssets);
    }

    /// INTERNAL ///

    /// @dev The parameters signed by the user should be the same as the inputs of this function.
    /// @dev Skipped when the permit is empty (v, r and s all zero; which doesn't correspond to a valid signature), useful when shares are already permitted.
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
