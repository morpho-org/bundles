// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.34;

import {IERC20} from "midnight/interfaces/IERC20.sol";
import {SafeTransferLib} from "midnight/libraries/SafeTransferLib.sol";
import {IERC20Permit} from "../interfaces/IERC20Permit.sol";
import {IPermit2} from "../interfaces/IPermit2.sol";

enum PermitKind {
    None,
    ERC2612,
    Permit2
}

struct TokenPermit {
    PermitKind kind;
    bytes data;
}

/// @title BlueBundlesUtils
/// @notice BlueBundles' own helpers: Permit2/ERC-2612 token pulls, USDT-safe max approvals.
/// @dev Mirrors the inlined helpers in MidnightBundles (the reference) without modifying it. Each bundle owns its
/// utils, so this copy is independent of any other bundle's.
library BlueBundlesUtils {
    error ApproveReturnedFalse();

    /// @dev Canonical Permit2 singleton.
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Skips the approval entirely to save gas when the current allowance is already 2^95 - 1 (value chosen
    /// because some tokens like COMP and UNI on ethereum have a max allowance of type(uint96).max).
    /// @dev Resets to 0 before re-approving to support USDT like tokens.
    function forceApproveMax(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) >= type(uint96).max / 2) return;
        safeApprove(token, spender, 0);
        safeApprove(token, spender, type(uint256).max);
    }

    /// @dev Not checking the code size because a transfer will do it in the same call.
    function safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory returndata) = token.call(abi.encodeCall(IERC20.approve, (spender, value)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        require(returndata.length == 0 || abi.decode(returndata, (bool)), ApproveReturnedFalse());
    }

    /// @dev Pulls `amount` of `token` from `from` to address(this), optionally using ERC2612 or Permit2.
    function pullToken(address token, address from, uint256 amount, TokenPermit memory permit) internal {
        if (permit.kind == PermitKind.ERC2612) {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
                abi.decode(permit.data, (uint256, uint8, bytes32, bytes32));
            // Tolerate revert: a third party may have already consumed the permit.
            try IERC20Permit(token).permit(from, address(this), amount, deadline, v, r, s) {} catch {}
            SafeTransferLib.safeTransferFrom(token, from, address(this), amount);
        } else if (permit.kind == PermitKind.Permit2) {
            (uint256 nonce, uint256 deadline, bytes memory signature) =
                abi.decode(permit.data, (uint256, uint256, bytes));
            IPermit2(PERMIT2)
                .permitTransferFrom(
                    IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amount), nonce, deadline),
                    IPermit2.SignatureTransferDetails(address(this), amount),
                    from,
                    signature
                );
        } else {
            SafeTransferLib.safeTransferFrom(token, from, address(this), amount);
        }
    }
}
