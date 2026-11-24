// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {TokenLib, Permit} from "../libraries/TokenLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IMorpho} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
import {IMidnightAdapter} from "../../lib/vault-v2/src/adapters/interfaces/IMidnightAdapter.sol";
import {MathLib} from "../../lib/vault-v2/src/libraries/MathLib.sol";
import {IIntermediary} from "../../lib/vault-v2/src/periphery/gates/interfaces/IWhitelistSendAssetsGate.sol";

/// @dev POC exit into Midnight credit, purchased economically at par: the user forgoes remaining interest.
/// @dev The adapter collects principal before its zero-price (tick 0) Midnight sale, then returns principal to the vault.
/// @dev The user must authorize both the adapter and this bundle with Midnight.setIsAuthorized.
/// @dev Requires vault-share allowance to this bundle for withdrawals and the force-deallocation penalty.
/// @dev Requires loan-token allowance to this bundle for settlement fees.
/// @dev Vault idle assets are paid out first as principal. The user pays the penalty in shares and the settlement fee from their wallet.
/// @dev Borrows a fee-free seed from Morpho Blue and recycles it in fee-inclusive chunks until the exit is complete.
/// @dev Inherits Vault V2's token safety requirements. The vault's receiveAssetsGate must allow this bundle.
contract MidnightVaultExitBundlesV1 is IMorphoFlashLoanCallback, IIntermediary {
    using MathLib for uint256;

    error AlreadyInitiated();
    error DeadlinePassed();
    error AdapterNotPartOfVault();
    error MidnightMismatch();
    error LoanAssetMismatch();
    error InsufficientMarketCredit();
    error UnauthorizedCallback();
    error ZeroSeed();

    address public immutable MIDNIGHT;
    address public immutable MORPHO;
    address public transient initiator;
    bool internal transient proRataRedemption;

    constructor(address midnight, address morpho) {
        MIDNIGHT = midnight;
        MORPHO = morpho;
    }

    /// @dev Exit from a Vault V2 and get idle assets and/or Midnight shares, even if the vault is illiquid and if the vault roles are not cooperating.
    /// @dev Buys exactly exitAssets - assetsToWithdrawFromIdle units of credit across the adapter's live markets, in marketIds order. Pending Midnight fees can reduce their net value.
    /// @dev The market list is always read from the adapter. A caller-supplied list would let an exit select markets and give up non-custodiality.
    /// @dev Markets with no adapter credit are skipped.
    /// @dev Requires enough vault-share allowance, beforehand or through sharesPermit, for each penalty and withdrawal.
    /// @dev The allowance/permit value can bound the maximum shares burned.
    /// @dev maxSeed == 0 means no caller cap. Otherwise it caps the flash-loan seed. The seed is the remainder after the idle withdrawal plus settlement fees, and is also limited by Blue's loan-token balance.
    /// @dev A smaller seed increases round count, gas, and per-round fee/penalty rounding. The seed must fund at least one unit plus its fee.
    function midnightVaultExitBundlesV1InKindRedemption(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 maxSeed,
        Permit memory sharesPermit,
        uint256 deadline
    ) external {
        _redeem(vault, adapter, exitAssets, maxSeed, sharesPermit, deadline, false);
    }

    /// @dev Same book as the in-kind exit, split across the adapter's live markets in proportion to their net credit.
    function midnightVaultExitBundlesV1InKindRedemptionProRata(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 maxSeed,
        Permit memory sharesPermit,
        uint256 deadline
    ) external {
        _redeem(vault, adapter, exitAssets, maxSeed, sharesPermit, deadline, true);
    }

    function _redeem(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 maxSeed,
        Permit memory sharesPermit,
        uint256 deadline,
        bool proRata
    ) internal {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        proRataRedemption = proRata;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMidnightAdapter(adapter).midnight() == MIDNIGHT, MidnightMismatch());
        Market[] memory marketList = _adapterMarkets(adapter);

        TokenLib.submitPermit(vault, sharesPermit);

        address asset = IVaultV2(vault).asset();
        uint256 assetsToWithdrawFromIdle = MathLib.min(IERC20(asset).balanceOf(vault), exitAssets);
        if (assetsToWithdrawFromIdle > 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth)
            IVaultV2(vault).withdraw(assetsToWithdrawFromIdle, address(this), msg.sender);
            SafeTransferLib.safeTransfer(asset, msg.sender, assetsToWithdrawFromIdle);
        }

        uint256 assetsToWithdrawFromVault = exitAssets - assetsToWithdrawFromIdle;
        if (assetsToWithdrawFromVault == 0) {
            initiator = address(0);
            proRataRedemption = false;
            return;
        }
        uint256 fees;
        uint256 remaining = assetsToWithdrawFromVault;
        uint256[] memory amounts;
        if (proRata) amounts = _proRataAmounts(adapter, marketList, assetsToWithdrawFromVault);
        for (uint256 i; remaining > 0 && i < marketList.length; i++) {
            Market memory market = marketList[i];
            require(market.loanToken == asset, LoanAssetMismatch());
            bytes32 marketId = IdLib.toId(market);
            (uint128 credit, uint128 pendingFee,) = IMidnight(MIDNIGHT).updatePositionView(market, marketId, adapter);
            uint256 marketAssets = uint256(credit) - pendingFee;
            if (marketAssets == 0) continue;
            uint256 assets = proRata ? amounts[i] : MathLib.min(remaining, marketAssets);
            fees += assets.mulDivUp(
                IMidnight(MIDNIGHT).settlementFee(marketId, market.maturity.zeroFloorSub(block.timestamp)), 1e18
            );
            remaining -= assets;
        }
        require(remaining == 0, InsufficientMarketCredit());

        uint256 seed = assetsToWithdrawFromVault + fees;
        uint256 liquidity = IERC20(asset).balanceOf(MORPHO);
        if (seed > liquidity) seed = liquidity;
        if (maxSeed != 0 && seed > maxSeed) seed = maxSeed;
        require(seed > 0, ZeroSeed());
        // forge-lint: disable-next-item(reentrancy-no-eth) initiator locks entry until the flash loan is repaid.
        IMorpho(MORPHO).flashLoan(asset, seed, abi.encode(vault, adapter, marketList, assetsToWithdrawFromVault));
        TokenLib.safeApprove(asset, MORPHO, 0);
        initiator = address(0);
        proRataRedemption = false;
    }

    function onMorphoFlashLoan(uint256 seed, bytes calldata data) external {
        require(msg.sender == MORPHO && initiator != address(0), UnauthorizedCallback());
        (address vault, address adapter, Market[] memory marketList, uint256 exitAssets) =
            abi.decode(data, (address, address, Market[], uint256));
        bool proRata = proRataRedemption;
        address asset = IVaultV2(vault).asset();
        TokenLib.forceApproveMax(asset, adapter);

        uint256 remaining = exitAssets;
        uint256[] memory amounts;
        if (proRata) amounts = _proRataAmounts(adapter, marketList, exitAssets);
        for (uint256 i; remaining > 0 && i < marketList.length; i++) {
            Market memory market = marketList[i];
            require(market.loanToken == asset, LoanAssetMismatch());
            bytes32 marketId = IdLib.toId(market);
            (uint128 credit, uint128 pendingFee,) = IMidnight(MIDNIGHT).updatePositionView(market, marketId, adapter);
            uint256 marketAssets = uint256(credit) - pendingFee;
            if (marketAssets == 0) continue;
            uint256 assets = proRata ? amounts[i] : MathLib.min(remaining, marketAssets);

            uint256 feeRate = IMidnight(MIDNIGHT).settlementFee(marketId, market.maturity.zeroFloorSub(block.timestamp));

            while (assets > 0) {
                (uint256 chunk,, uint256 funding) = _chunk(seed, feeRate, assets);
                IVaultV2(vault).forceDeallocate(adapter, abi.encode(market, initiator), chunk, initiator);
                uint256 idle = IERC20(asset).balanceOf(vault);
                uint256 withdrawn = funding < idle ? funding : idle;
                IVaultV2(vault).withdraw(withdrawn, address(this), initiator);
                if (funding > withdrawn) {
                    SafeTransferLib.safeTransferFrom(asset, initiator, address(this), funding - withdrawn);
                }
                assets -= chunk;
                remaining -= chunk;
            }
        }
        require(remaining == 0, InsufficientMarketCredit());

        TokenLib.safeApprove(asset, adapter, 0);
        TokenLib.safeApprove(asset, MORPHO, seed);
    }

    function _adapterMarkets(address adapter) internal view returns (Market[] memory marketList) {
        uint256 length = IMidnightAdapter(adapter).marketIdsLength();
        marketList = new Market[](length);
        for (uint256 i; i < length; i++) {
            marketList[i] = IMidnight(MIDNIGHT).toMarket(IMidnightAdapter(adapter).marketIds(i));
        }
    }

    function _proRataAmounts(address adapter, Market[] memory markets, uint256 assets)
        internal
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](markets.length);
        uint256 total;
        for (uint256 i; i < markets.length; i++) {
            (uint128 credit, uint128 pendingFee,) =
                IMidnight(MIDNIGHT).updatePositionView(markets[i], IdLib.toId(markets[i]), adapter);
            amounts[i] = uint256(credit) - pendingFee;
            total += amounts[i];
        }
        return _distributeProRata(amounts, assets, total);
    }

    function _distributeProRata(uint256[] memory amounts, uint256 assets, uint256 total)
        internal
        pure
        returns (uint256[] memory)
    {
        require(total >= assets, InsufficientMarketCredit());
        uint256 remainingAssets = assets;
        uint256 remainingCredit = total;
        for (uint256 i; i < amounts.length; i++) {
            uint256 marketCredit = amounts[i];
            uint256 marketAssets = marketCredit == remainingCredit
                ? remainingAssets
                : remainingAssets.mulDivDown(marketCredit, remainingCredit);
            amounts[i] = marketAssets;
            remainingAssets -= marketAssets;
            remainingCredit -= marketCredit;
        }
        return amounts;
    }

    function _chunk(uint256 seed, uint256 feeRate, uint256 assets)
        internal
        pure
        returns (uint256 chunk, uint256 fee, uint256 funding)
    {
        uint256 maxChunk = seed.mulDivDown(1e18, 1e18 + feeRate);
        require(maxChunk > 0, ZeroSeed());
        chunk = assets < maxChunk ? assets : maxChunk;
        fee = chunk.mulDivUp(feeRate, 1e18);
        funding = chunk + fee;
    }
}
