// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightVaultExitBundlesTest} from "./MidnightVaultExitBundlesTest.sol";
import {Offer as AdapterOffer} from "../lib/vault-v2/lib/midnight/src/interfaces/IMidnight.sol";
import {Market, Offer} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";
import {MidnightVaultExitBundlesV1} from "../src/vault-exit/MidnightVaultExitBundlesV1.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";

/// @dev Pro-rata in-kind redemption touching every adapter market, run under each target chain's per-transaction gas cap.
/// @dev The call gets cap - intrinsic gas (21000 + calldata), as an EOA transaction would.
/// @dev Run: forge test --match-path test/MidnightIKRChainGasLimitPoC.t.sol -vv
contract MidnightIKRChainGasLimitPoC is MidnightVaultExitBundlesTest {
    uint256 internal constant PER_MARKET = 10_000e6;
    uint256 internal constant MAX_MARKETS = 250;

    function addSibling(uint256 i) internal {
        Market memory m = market;
        m.maturity += (i + 1) * 1 days;
        address borrower = makeAddr(string.concat("sibling", vm.toString(i)));
        ERC20 collateral = ERC20(m.collateralParams[0].token);
        deal(address(usdc), address(this), PER_MARKET);
        vault.deposit(PER_MARKET, address(this));
        deal(address(collateral), borrower, PER_MARKET);
        vm.startPrank(borrower);
        collateral.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(m, 0, PER_MARKET, borrower);
        Offer memory offer;
        offer.market = m;
        offer.maker = borrower;
        offer.receiverIfMakerIsSeller = borrower;
        offer.expiry = type(uint256).max;
        offer.tick = MAX_TICK;
        offer.maxUnits = uint128(PER_MARKET);
        offer.continuousFeeCap = type(uint256).max;
        offer.ratifier = address(new DummyRatifier());
        midnight.setIsAuthorized(offer.ratifier, true, borrower);
        vm.stopPrank();
        adapter.take(abi.decode(abi.encode(offer), (AdapterOffer)), "", PER_MARKET, abi.encode(address(0), bytes("")));
        for (uint256 j; j < 7; j++) {
            midnight.setMarketSettlementFee(IdLib.toId(m), j, RATE);
        }
    }

    function redeemCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(
            MidnightVaultExitBundlesV1.midnightVaultExitBundlesV1InKindRedemptionProRata,
            (address(vault), address(adapter), ASSETS, 0, noPermit(), block.timestamp)
        );
    }

    function intrinsicGas(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Returns whether the redemption succeeds with txGasCap, leaving state unchanged.
    function fits(uint256 txGasCap) internal returns (bool success) {
        bytes memory data = redeemCalldata();
        uint256 snapshot = vm.snapshotState();
        (success,) = address(bundle).call{gas: txGasCap - intrinsicGas(data)}(data);
        vm.revertToState(snapshot);
    }

    function setupMarkets(uint256 n) internal {
        for (uint256 i; i < n - 1; i++) {
            addSibling(i);
        }
        assertEq(adapter.marketIdsLength(), n);
        deal(address(usdc), address(this), 10 * FEE);
    }

    function assertBoundary(uint256 txGasCap, uint256 maxMarkets) internal {
        setupMarkets(maxMarkets);
        assertTrue(fits(txGasCap), "documented maximum should fit");
        addSibling(maxMarkets - 1);
        assertFalse(fits(txGasCap), "one market above maximum should run out of gas");
    }

    function test_capacity_16_777_216_is_51_markets() public {
        assertBoundary(16_777_216, 51);
    }

    function test_capacity_30_000_000_is_92_markets() public {
        assertBoundary(30_000_000, 92);
    }

    function test_capacity_32_000_000_is_98_markets() public {
        assertBoundary(32_000_000, 98);
    }

    function test_capacity_33_554_432_is_103_markets() public {
        assertBoundary(33_554_432, 103);
    }

    function test_capacity_36_000_000_is_110_markets() public {
        assertBoundary(36_000_000, 110);
    }

    function test_capacity_40_000_000_is_122_markets() public {
        assertBoundary(40_000_000, 122);
    }

    function test_250_markets_exceeds_every_target_chain_cap() public {
        setupMarkets(MAX_MARKETS);
        assertFalse(fits(40_000_000), "250 markets should exceed the largest target chain cap");
    }
}
