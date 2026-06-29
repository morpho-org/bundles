// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ERC20Permit} from "../lib/midnight/test/erc20s/ERC20Permit.sol";
import {IEIP712} from "../lib/permit2/src/interfaces/IEIP712.sol";
import {TokenLib, TokenPermit, PermitKind} from "../src/libraries/TokenLib.sol";

/// @dev Exposes TokenLib's internal token pulls so they can be exercised directly.
contract TokenLibHarness {
    function pullToken(address token, address from, uint256 amount, TokenPermit memory permit) external {
        TokenLib.pullToken(token, from, amount, permit);
    }
}

contract TokenLibTest is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    TokenLibHarness internal harness;
    ERC20Permit internal token;
    address internal holder;
    uint256 internal holderKey;

    function setUp() public {
        harness = new TokenLibHarness();
        token = new ERC20Permit("token", "token");
        deployCodeTo("Permit2", PERMIT2);

        (holder, holderKey) = makeAddrAndKey("holder");
        deal(address(token), holder, type(uint256).max);
    }

    function _noPermit() internal pure returns (TokenPermit memory) {}

    function _permit(uint256 amount, uint256 nonce, uint256 deadline) internal view returns (TokenPermit memory) {
        bytes32 structHash =
            keccak256(abi.encode(token.PERMIT_TYPEHASH(), holder, address(harness), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderKey, digest);
        return TokenPermit({kind: PermitKind.ERC2612, data: abi.encode(deadline, v, r, s)});
    }

    function _permit2(uint256 amount, uint256 nonce, uint256 deadline) internal view returns (TokenPermit memory) {
        bytes32 tokenPermissionsHash =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), address(token), amount));
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                tokenPermissionsHash,
                address(harness),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IEIP712(PERMIT2).DOMAIN_SEPARATOR(), permitHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderKey, digest);
        return TokenPermit({kind: PermitKind.Permit2, data: abi.encode(nonce, deadline, abi.encodePacked(r, s, v))});
    }

    function testPullTokenNoPermit() public {
        uint256 amount = 100e18;
        vm.prank(holder);
        token.approve(address(harness), amount);

        harness.pullToken(address(token), holder, amount, _noPermit());

        assertEq(token.allowance(holder, address(harness)), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    function testPullTokenPermit() public {
        uint256 amount = 100e18;
        TokenPermit memory permit = _permit(amount, 0, vm.getBlockTimestamp() + 1);

        harness.pullToken(address(token), holder, amount, permit);

        assertEq(token.allowance(holder, address(harness)), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    /// @dev A third party may consume the permit before the pull; the stale permit is tolerated and the transfer still goes through on the allowance it set.
    function testPullTokenPermitAlreadyConsumed() public {
        uint256 amount = 100e18;
        TokenPermit memory permit = _permit(amount, 0, vm.getBlockTimestamp() + 1);

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = abi.decode(permit.data, (uint256, uint8, bytes32, bytes32));
        token.permit(holder, address(harness), amount, deadline, v, r, s);

        harness.pullToken(address(token), holder, amount, permit);

        assertEq(token.allowance(holder, address(harness)), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    function testPullTokenPermit2() public {
        uint256 amount = 100e18;
        vm.prank(holder);
        token.approve(PERMIT2, amount);

        TokenPermit memory permit = _permit2(amount, 0, vm.getBlockTimestamp() + 1);
        harness.pullToken(address(token), holder, amount, permit);

        assertEq(token.allowance(holder, PERMIT2), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    /// @dev Unlike ERC2612, the Permit2 path pulls atomically and does not tolerate a spent nonce: replaying the same permit reverts instead of silently transferring again.
    function testPullTokenPermit2AlreadyConsumed() public {
        uint256 amount = 100e18;
        vm.prank(holder);
        token.approve(PERMIT2, 2 * amount);

        TokenPermit memory permit = _permit2(amount, 0, vm.getBlockTimestamp() + 1);
        harness.pullToken(address(token), holder, amount, permit);

        vm.expectRevert();
        harness.pullToken(address(token), holder, amount, permit);
    }
}
