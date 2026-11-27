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
import {IMidnightAdapter, MarketData} from "../../lib/vault-v2/src/adapters/interfaces/IMidnightAdapter.sol";
import {MathLib} from "../../lib/vault-v2/src/libraries/MathLib.sol";
import {IIntermediary} from "../../lib/vault-v2/src/periphery/gates/interfaces/IWhitelistSendAssetsGate.sol";

/// @dev POC exit into Midnight position units purchased economically at par: they repay the user's debt first, then increase credit, and the user forgoes remaining interest.
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
    error ZeroMaxMarkets();
    error ExclusionsNotSorted();

    address public immutable MIDNIGHT;
    address public immutable MORPHO;
    address public transient initiator;

    constructor(address midnight, address morpho) {
        MIDNIGHT = midnight;
        MORPHO = morpho;
    }

    /// @dev Greedily exits through the adapter's largest net-credit positions, touching at most maxMarkets.
    /// @dev Returns the amount actually exited, capped by exitAssets, idle assets and the selected markets.
    /// @dev Repeated calls resume from the then-largest remaining positions without storing bundle state.
    function midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 maxMarkets,
        bytes32[] memory excludedMarketIds,
        uint256 maxSeed,
        Permit memory sharesPermit,
        uint256 deadline
    ) external returns (uint256) {
        require(maxMarkets != 0, ZeroMaxMarkets());
        for (uint256 i = 1; i < excludedMarketIds.length; i++) {
            require(uint256(excludedMarketIds[i - 1]) < uint256(excludedMarketIds[i]), ExclusionsNotSorted());
        }
        return _redeemByLiquidity(
            vault, adapter, exitAssets, maxMarkets, excludedMarketIds, maxSeed, sharesPermit, deadline
        );
    }

    function _redeemByLiquidity(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 maxMarkets,
        bytes32[] memory excludedMarketIds,
        uint256 maxSeed,
        Permit memory sharesPermit,
        uint256 deadline
    ) internal returns (uint256) {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMidnightAdapter(adapter).midnight() == MIDNIGHT, MidnightMismatch());
        (bytes32[] memory sortedMarketIds, uint256[] memory marketAssets) =
            _adapterMarketIdsByLiquidity(adapter, excludedMarketIds, maxMarkets);
        TokenLib.submitPermit(vault, sharesPermit);

        address asset = IVaultV2(vault).asset();
        uint256 idle = IERC20(asset).balanceOf(vault);
        uint256 selectedMarketAssets;
        for (uint256 i; i < sortedMarketIds.length; i++) {
            selectedMarketAssets += marketAssets[i];
        }
        exitAssets = MathLib.min(exitAssets, idle + selectedMarketAssets);

        Market[] memory selectedMarketList = new Market[](sortedMarketIds.length);
        for (uint256 i; i < sortedMarketIds.length; i++) {
            selectedMarketList[i] = IMidnight(MIDNIGHT).toMarket(sortedMarketIds[i]);
        }
        return _executeRedeem(vault, adapter, exitAssets, maxSeed, selectedMarketList);
    }

    function _executeRedeem(
        address vault,
        address adapter,
        uint256 exitAssets,
        uint256 maxSeed,
        Market[] memory marketList
    ) internal returns (uint256) {
        address asset = IVaultV2(vault).asset();
        uint256 idle = IERC20(asset).balanceOf(vault);
        uint256 assetsToWithdrawFromIdle = MathLib.min(idle, exitAssets);
        if (assetsToWithdrawFromIdle > 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth)
            IVaultV2(vault).withdraw(assetsToWithdrawFromIdle, address(this), msg.sender);
            SafeTransferLib.safeTransfer(asset, msg.sender, assetsToWithdrawFromIdle);
        }

        uint256 assetsToWithdrawFromVault = exitAssets - assetsToWithdrawFromIdle;
        if (assetsToWithdrawFromVault == 0) {
            initiator = address(0);
            return exitAssets;
        }
        uint256 fees;
        uint256 remaining = assetsToWithdrawFromVault;
        for (uint256 i; remaining > 0 && i < marketList.length; i++) {
            Market memory market = marketList[i];
            require(market.loanToken == asset, LoanAssetMismatch());
            bytes32 marketId = IdLib.toId(market);
            (uint128 credit, uint128 pendingFee,) = IMidnight(MIDNIGHT).updatePositionView(market, marketId, adapter);
            uint256 marketNetAssets = uint256(credit) - pendingFee;
            if (marketNetAssets == 0) continue;
            uint256 assets = MathLib.min(remaining, marketNetAssets);
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
        return exitAssets;
    }

    function onMorphoFlashLoan(uint256 seed, bytes calldata data) external {
        require(msg.sender == MORPHO && initiator != address(0), UnauthorizedCallback());
        (address vault, address adapter, Market[] memory marketList, uint256 exitAssets) =
            abi.decode(data, (address, address, Market[], uint256));
        address asset = IVaultV2(vault).asset();
        TokenLib.forceApproveMax(asset, adapter);

        uint256 remaining = exitAssets;
        for (uint256 i; remaining > 0 && i < marketList.length; i++) {
            Market memory market = marketList[i];
            require(market.loanToken == asset, LoanAssetMismatch());
            bytes32 marketId = IdLib.toId(market);
            (uint128 credit, uint128 pendingFee,) = IMidnight(MIDNIGHT).updatePositionView(market, marketId, adapter);
            uint256 marketAssets = uint256(credit) - pendingFee;
            if (marketAssets == 0) continue;
            uint256 assets = MathLib.min(remaining, marketAssets);

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

    function _adapterMarketIdsByLiquidity(
        address adapter,
        bytes32[] memory excludedMarketIds,
        uint256 maxMarkets
    )
        internal
        view
        returns (bytes32[] memory sortedIds, uint256[] memory sortedAssets)
    {
        uint256 length = IMidnightAdapter(adapter).marketIdsLength();
        bytes32[] memory ids = new bytes32[](length);
        uint256[] memory assets = new uint256[](length);
        uint256[] memory order = new uint256[](length);
        uint256 eligibleMarkets;

        for (uint256 i; i < length; i++) {
            bytes32 id = IMidnightAdapter(adapter).marketIds(i);
            ids[i] = id;
            order[i] = i;
            if (_isExcluded(id, excludedMarketIds)) continue;

            MarketData memory data = IMidnightAdapter(adapter).marketData(id);
            assets[i] = data.netCredit;
            if (IMidnight(MIDNIGHT).lossFactor(id) != 0) {
                Market memory dummyMarket;
                (uint128 credit, uint128 pendingFee,) =
                    IMidnight(MIDNIGHT).updatePositionView(dummyMarket, id, adapter);
                assets[i] = uint256(credit) - pendingFee;
            }
            if (assets[i] != 0) eligibleMarkets++;
        }

        _buildMaxHeap(order, assets, ids);
        uint256 selectedMarkets = MathLib.min(maxMarkets, eligibleMarkets);
        sortedIds = new bytes32[](selectedMarkets);
        sortedAssets = new uint256[](selectedMarkets);
        uint256 end = length;
        for (uint256 i; i < selectedMarkets; i++) {
            uint256 source = order[0];
            sortedIds[i] = ids[source];
            sortedAssets[i] = assets[source];
            end--;
            order[0] = order[end];
            _siftDown(order, assets, ids, 0, end);
        }
    }

    function _isExcluded(bytes32 id, bytes32[] memory excludedMarketIds) internal pure returns (bool) {
        uint256 low;
        uint256 high = excludedMarketIds.length;
        uint256 value = uint256(id);
        while (low < high) {
            uint256 middle = (low + high) / 2;
            uint256 candidate = uint256(excludedMarketIds[middle]);
            if (candidate < value) low = middle + 1;
            else high = middle;
        }
        return low < excludedMarketIds.length && excludedMarketIds[low] == id;
    }

    function _heapSort(uint256[] memory order, uint256[] memory assets, bytes32[] memory ids) internal pure {
        uint256 length = order.length;
        _buildMaxHeap(order, assets, ids);
        for (uint256 end = length; end > 1; end--) {
            (order[0], order[end - 1]) = (order[end - 1], order[0]);
            _siftDown(order, assets, ids, 0, end - 1);
        }
    }

    function _buildMaxHeap(uint256[] memory order, uint256[] memory assets, bytes32[] memory ids) internal pure {
        for (uint256 start = order.length / 2; start > 0; start--) {
            _siftDown(order, assets, ids, start - 1, order.length);
        }
    }

    function _siftDown(
        uint256[] memory order,
        uint256[] memory assets,
        bytes32[] memory ids,
        uint256 root,
        uint256 end
    ) internal pure {
        while (true) {
            uint256 child = root * 2 + 1;
            if (child >= end) return;
            if (child + 1 < end && _greater(order[child + 1], order[child], assets, ids)) child++;
            if (!_greater(order[child], order[root], assets, ids)) return;
            (order[root], order[child]) = (order[child], order[root]);
            root = child;
        }
    }

    function _greater(uint256 a, uint256 b, uint256[] memory assets, bytes32[] memory ids)
        internal
        pure
        returns (bool)
    {
        if (assets[a] != assets[b]) return assets[a] > assets[b];
        return uint256(ids[a]) > uint256(ids[b]);
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
