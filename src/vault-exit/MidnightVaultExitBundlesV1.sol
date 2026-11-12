// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {TokenLib} from "../libraries/TokenLib.sol";
import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IMidnight, Market} from "../../lib/midnight/src/interfaces/IMidnight.sol";
import {IFlashLoanCallback} from "../../lib/midnight/src/interfaces/ICallbacks.sol";
import {IdLib} from "../../lib/midnight/src/libraries/IdLib.sol";
import {CALLBACK_SUCCESS} from "../../lib/midnight/src/libraries/ConstantsLib.sol";
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
/// @dev Midnight must have sufficient loan-token liquidity for the fee-free flash loan.
/// @dev Inherits Vault V2's token safety requirements. The vault's receiveAssetsGate must allow this bundle.
contract MidnightVaultExitBundlesV1 is IFlashLoanCallback {
    using MathLib for uint256;

    error AlreadyInitiated();
    error DeadlinePassed();
    error AdapterNotPartOfVault();
    error MidnightMismatch();
    error LoanAssetMismatch();
    error UnauthorizedCallback();

    address public immutable MIDNIGHT;
    address public transient initiator;

    constructor(address midnight) {
        MIDNIGHT = midnight;
    }

    /// @dev Buys exactly assets units of credit; pending Midnight fees can reduce its net value.
    function midnightVaultExitBundlesV1InKindRedemptionVaultV2(
        address vault,
        address adapter,
        Market memory market,
        uint256 assets,
        uint256 deadline
    ) external {
        require(initiator == address(0), AlreadyInitiated());
        initiator = msg.sender;
        require(block.timestamp <= deadline, DeadlinePassed());
        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
        require(IMidnightAdapter(adapter).midnight() == MIDNIGHT, MidnightMismatch());
        require(market.loanToken == IVaultV2(vault).asset(), LoanAssetMismatch());

        uint256 fee = assets.mulDivUp(
            IMidnight(MIDNIGHT).settlementFee(IdLib.toId(market), market.maturity.zeroFloorSub(block.timestamp)), 1e18
        );
        address[] memory tokens = new address[](1);
        tokens[0] = market.loanToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = assets + fee;
        // forge-lint: disable-next-item(reentrancy-no-eth) initiator locks entry until the flash loan is repaid.
        IMidnight(MIDNIGHT).flashLoan(tokens, amounts, address(this), abi.encode(vault, adapter, market, assets));
        initiator = address(0);
    }

    function onFlashLoan(address caller, address[] memory tokens, uint256[] memory amounts, bytes memory data)
        external
        returns (bytes32)
    {
        require(msg.sender == MIDNIGHT && caller == address(this) && initiator != address(0), UnauthorizedCallback());
        (address vault, address adapter, Market memory market, uint256 assets) =
            abi.decode(data, (address, address, Market, uint256));
        TokenLib.forceApproveMax(tokens[0], adapter);
        IVaultV2(vault).forceDeallocate(adapter, abi.encode(market, initiator), assets, initiator);
        uint256 withdrawn =
            amounts[0] < IERC20(tokens[0]).balanceOf(vault) ? amounts[0] : IERC20(tokens[0]).balanceOf(vault);
        IVaultV2(vault).withdraw(withdrawn, address(this), initiator);
        if (amounts[0] > withdrawn) {
            SafeTransferLib.safeTransferFrom(tokens[0], initiator, address(this), amounts[0] - withdrawn);
        }
        TokenLib.forceApproveMax(tokens[0], MIDNIGHT);
        return CALLBACK_SUCCESS;
    }
}
