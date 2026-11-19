// SPDX-License-Identifier: MIT
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

/// @dev POC exit into Midnight credit, purchased economically at par: the user forgoes remaining interest.
/// @dev The adapter collects principal before its zero-price (tick 0) Midnight sale, then returns principal to the vault.
/// @dev The user must authorize both the adapter and this bundle with Midnight.setIsAuthorized.
/// @dev Requires vault-share allowance to this bundle for withdrawals and the force-deallocation penalty.
/// @dev Requires loan-token allowance to this bundle for any settlement fee not covered by vault idle assets.
/// @dev The user pays the penalty in shares and the settlement fee, using vault assets first, then wallet assets.
/// @dev Borrows a fee-free seed from Morpho Blue and recycles it in fee-inclusive chunks until the exit is complete.
/// @dev Inherits Vault V2's token safety requirements. The vault's receiveAssetsGate must allow this bundle.
contract MidnightVaultExitBundlesV1 is IMorphoFlashLoanCallback {
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

    constructor(address midnight, address morpho) {
        MIDNIGHT = midnight;
        MORPHO = morpho;
    }

    /// @dev Buys exactly exitAssets units of credit across marketList; pending Midnight fees can reduce their net value.
    /// @dev Passing a superset of the adapter's market list makes the call immune to vault allocation changes.
    /// @dev Markets with no adapter credit are skipped, so timelocked additions can be anticipated before inclusion.
    /// @dev Requires enough vault-share allowance, beforehand or through sharesPermit, for each penalty and withdrawal.
    /// @dev The allowance/permit value can bound the maximum shares burned.
    /// @dev maxSeed == 0 uses available Blue liquidity, capped at the full exit's principal plus settlement fees.
    /// @dev A smaller seed increases round count, gas, and per-round fee/penalty rounding. The seed must fund at least one unit plus its fee.
    function midnightVaultExitBundlesV1InKindRedemptionVaultV2(
        address vault,
        address adapter,
        Market[] memory marketList,
        uint256 exitAssets,
        uint256 maxSeed,
        Permit memory sharesPermit,
        uint256 deadline
    ) external {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMidnightAdapter(adapter).midnight() == MIDNIGHT, MidnightMismatch());

        TokenLib.submitPermit(vault, sharesPermit);

        address asset = IVaultV2(vault).asset();
        uint256 remaining = exitAssets;
        uint256 fees;
        for (uint256 i; remaining > 0 && i < marketList.length; i++) {
            Market memory market = marketList[i];
            require(market.loanToken == asset, LoanAssetMismatch());
            bytes32 marketId = IdLib.toId(market);
            (uint128 credit, uint128 pendingFee,) = IMidnight(MIDNIGHT).updatePositionView(market, marketId, adapter);
            uint256 marketAssets = uint256(credit) - pendingFee;
            if (marketAssets == 0) continue;
            uint256 assets = remaining < marketAssets ? remaining : marketAssets;
            fees += assets.mulDivUp(
                IMidnight(MIDNIGHT).settlementFee(marketId, market.maturity.zeroFloorSub(block.timestamp)), 1e18
            );
            remaining -= assets;
        }
        require(remaining == 0, InsufficientMarketCredit());

        uint256 seed = exitAssets + fees;
        uint256 liquidity = IERC20(asset).balanceOf(MORPHO);
        if (seed > liquidity) seed = liquidity;
        if (maxSeed != 0 && seed > maxSeed) seed = maxSeed;
        require(seed > 0, ZeroSeed());
        // forge-lint: disable-next-item(reentrancy-no-eth) initiator locks entry until the flash loan is repaid.
        IMorpho(MORPHO).flashLoan(asset, seed, abi.encode(vault, adapter, marketList, exitAssets));
        TokenLib.safeApprove(asset, MORPHO, 0);
        initiator = address(0);
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
            if (marketAssets > remaining) marketAssets = remaining;

            uint256 feeRate = IMidnight(MIDNIGHT).settlementFee(marketId, market.maturity.zeroFloorSub(block.timestamp));
            uint256 maxChunk = seed.mulDivDown(1e18, 1e18 + feeRate);
            require(maxChunk > 0, ZeroSeed());

            while (marketAssets > 0) {
                uint256 chunk = marketAssets < maxChunk ? marketAssets : maxChunk;
                uint256 fee = chunk.mulDivUp(feeRate, 1e18);
                IVaultV2(vault).forceDeallocate(adapter, abi.encode(market, initiator), chunk, initiator);
                uint256 funding = chunk + fee;
                uint256 idle = IERC20(asset).balanceOf(vault);
                uint256 withdrawn = funding < idle ? funding : idle;
                IVaultV2(vault).withdraw(withdrawn, address(this), initiator);
                if (funding > withdrawn) {
                    SafeTransferLib.safeTransferFrom(asset, initiator, address(this), funding - withdrawn);
                }
                marketAssets -= chunk;
                remaining -= chunk;
            }
        }
        require(remaining == 0, InsufficientMarketCredit());

        TokenLib.safeApprove(asset, adapter, 0);
        TokenLib.safeApprove(asset, MORPHO, seed);
    }
}
