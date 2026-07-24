// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity >=0.8.0;

import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
import {IERC20Permit} from "./interfaces/IERC20Permit.sol";
import {IPermit2, ISignatureTransfer} from "../../lib/permit2/src/interfaces/IPermit2.sol";

enum PermitKind {
    None,
    ERC2612,
    Permit2
}

struct TokenPermit {
    PermitKind kind;
    bytes data;
}

/// @dev An empty permit (v, r and s all zero) means no permit is submitted.
/// @dev A permit with an already consumed nonce is not submitted either.
struct Permit {
    uint256 value;
    uint256 nonce;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

library TokenLib {
    error ApproveReturnedFalse();

    /// @dev Canonical Permit2 singleton.
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Not checking the code size because a transfer will do it in the same call.
    function safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory returndata) = token.call(abi.encodeCall(IERC20Permit.approve, (spender, value)));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        require(returndata.length == 0 || abi.decode(returndata, (bool)), ApproveReturnedFalse());
    }

    /// @dev Skips the approval entirely to save gas when the current allowance is already at least 2^95 - 1 (some tokens like COMP and UNI on Ethereum have a max allowance of type(uint96).max).
    /// @dev Resets to 0 before re-approving to support USDT-like tokens.
    function forceApproveMax(address token, address spender) internal {
        if (IERC20Permit(token).allowance(address(this), spender) >= type(uint96).max / 2) return;
        safeApprove(token, spender, 0);
        safeApprove(token, spender, type(uint256).max);
    }

    /// @dev Pulls `amount` of `token` from `from` to this bundler, optionally using ERC2612 or Permit2.
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
                    ISignatureTransfer.PermitTransferFrom(
                        ISignatureTransfer.TokenPermissions(token, amount), nonce, deadline
                    ),
                    ISignatureTransfer.SignatureTransferDetails(address(this), amount),
                    from,
                    signature
                );
        } else {
            SafeTransferLib.safeTransferFrom(token, from, address(this), amount);
        }
    }

    /// @dev The parameters signed by the user should be the same as the inputs of this function.
    /// @dev Skipped when the permit is empty (v, r and s all zero; which doesn't correspond to a valid signature), useful when the tokens are already permitted.
    /// @dev Skipped on an already consumed nonce (e.g. a front-run submission): the permit is not submitted in that case.
    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until permit.deadline.
    function submitPermit(address token, Permit memory permit) internal {
        bool emptyPermit = permit.v == 0 && permit.r == 0 && permit.s == 0;

        if (!emptyPermit && IERC20Permit(token).nonces(msg.sender) <= permit.nonce) {
            IERC20Permit(token)
                .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s);
        }
    }
}
