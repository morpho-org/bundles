// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.0;

import {Test} from "../../lib/forge-std/src/Test.sol";

import {ERC20Permit} from "../../lib/midnight/test/erc20s/ERC20Permit.sol";
import {ERC20NoRevert} from "../../lib/midnight/test/erc20s/ERC20NoRevert.sol";
import {ERC20USDT} from "../../lib/midnight/test/erc20s/ERC20USDT.sol";
import {ERC20RevertToZero} from "../../lib/midnight/test/erc20s/ERC20RevertToZero.sol";
import {ERC20NoReturn} from "../../lib/midnight/test/erc20s/ERC20NoReturn.sol";

/// @dev approve, transfer and transferFrom return nothing so calls work on tokens that return
/// nothing; the return data of bool-returning tokens is simply ignored.
interface ITestToken {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function nonces(address) external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    // forge-lint: disable-next-line(mixed-case-function)
    function PERMIT_TYPEHASH() external view returns (bytes32);
    function decimals() external view returns (uint8);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function approve(address spender, uint256 amount) external;
    function transfer(address to, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external;
}

contract TestERC20Permit is ERC20Permit {
    constructor(string memory name_, string memory symbol_) ERC20Permit(name_, symbol_) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract TestERC20NoRevert is ERC20NoRevert {
    constructor(string memory name_) ERC20NoRevert(name_) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract TestERC20USDT is ERC20USDT {
    constructor(string memory name_) ERC20USDT(name_) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract TestERC20RevertToZero is ERC20RevertToZero {
    constructor(string memory name_) ERC20RevertToZero(name_) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract TestERC20NoReturn is ERC20NoReturn {
    constructor(string memory name_) ERC20NoReturn(name_) {}

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

abstract contract TokenTest is Test {
    /// @dev Resets to 0 before re-approving when the approval fails, to support USDT-like tokens.
    function safeApprove(ITestToken token, address spender, uint256 amount) internal {
        try token.approve(spender, amount) {}
        catch {
            token.approve(spender, 0);
            token.approve(spender, amount);
        }
    }

    /// @dev Deploys the token selected by TOKEN_TYPE, as in midnight's BaseTest:
    /// 0 = standard, 1 = no-revert, 2 = usdt, 3 = revert-to-zero, 4 = no-return.
    function deployToken(string memory name_) internal returns (ITestToken) {
        uint256 tokenType = vm.envOr("TOKEN_TYPE", uint256(0));
        if (tokenType == 0) return ITestToken(address(new TestERC20Permit(name_, name_)));
        if (tokenType == 1) return ITestToken(address(new TestERC20NoRevert(name_)));
        if (tokenType == 2) return ITestToken(address(new TestERC20USDT(name_)));
        if (tokenType == 3) return ITestToken(address(new TestERC20RevertToZero(name_)));
        if (tokenType == 4) return ITestToken(address(new TestERC20NoReturn(name_)));
        revert("unknown TOKEN_TYPE");
    }
}
