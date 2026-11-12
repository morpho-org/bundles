// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {Test} from "../lib/forge-std/src/Test.sol";
import {MidnightVaultExitBundlesV1} from "../src/vault-exit/MidnightVaultExitBundlesV1.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMidnightAdapter, IMidnightAdapterBase} from "../lib/vault-v2/src/adapters/interfaces/IMidnightAdapter.sol";
import {IMidnightAdapterFactory} from "../lib/vault-v2/src/adapters/interfaces/IMidnightAdapterFactory.sol";
import {Offer as AdapterOffer} from "../lib/vault-v2/lib/midnight/src/interfaces/IMidnight.sol";
import {IMidnight, Market, CollateralParams, Offer} from "../lib/midnight/src/interfaces/IMidnight.sol";
import {ERC20} from "../lib/midnight/test/erc20s/ERC20.sol";
import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {Oracle} from "../lib/midnight/test/helpers/Oracle.sol";
import {DummyRatifier} from "../lib/midnight/test/helpers/DummyRatifier.sol";
import {IdLib} from "../lib/midnight/src/libraries/IdLib.sol";
import {MAX_TICK} from "../lib/midnight/src/libraries/TickLib.sol";
import {MathLib} from "../lib/vault-v2/src/libraries/MathLib.sol";

contract MidnightVaultExitBundlesTest is Test {
    using MathLib for uint256;

    IMidnight internal midnight;
    IVaultV2 internal vault;
    IMidnightAdapter internal adapter;
    MidnightVaultExitBundlesV1 internal bundle;
    ERC20Mock internal usdc;
    Market internal market;
    uint256 internal constant DEPOSIT = 10e18;
    uint256 internal constant ASSETS = 1e18;
    uint256 internal constant FEE = 0.00001e18;
    uint256 internal constant PENALTY = 0.02e18;

    function setUp() public {
        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        midnight.setFeeSetter(address(this));
        midnight.enableLltv(1e18);
        midnight.enableLiquidationCursor(0.25e18);
        usdc = new ERC20Mock(6);
        ERC20 collateral = new ERC20("Collateral", "COL");
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams(address(collateral), 1e18, 0.25e18, address(new Oracle()));
        market = Market(
            block.chainid,
            address(midnight),
            address(usdc),
            collaterals,
            block.timestamp + 7 days,
            0,
            address(0),
            address(0)
        );
        vault = IVaultV2(deployCode("VaultV2.sol:VaultV2", abi.encode(address(this), address(usdc))));
        vault.setCurator(address(this));
        IMidnightAdapterFactory factory = IMidnightAdapterFactory(
            deployCode("MidnightAdapterFactory.sol:MidnightAdapterFactory", abi.encode(address(midnight)))
        );
        adapter =
            IMidnightAdapter(factory.createMidnightAdapter(address(vault), new uint256[](0), address(0), bytes32(0)));
        configureVault(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        configureVault(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        configureVault(abi.encodeCall(IVaultV2.setIsAllocator, (address(adapter), true)));
        configureVault(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), PENALTY)));
        bytes[] memory ids = new bytes[](3);
        ids[0] = abi.encode("this", address(adapter));
        ids[1] = abi.encode("family", market.collateralParams, market.rcfThreshold, market.liquidatorGate);
        ids[2] = abi.encode("collateralToken", address(collateral));
        for (uint256 i; i < ids.length; i++) {
            configureVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[i], type(uint128).max)));
            configureVault(abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[i], 1e18)));
        }
        bytes memory maxTtm = abi.encodeCall(IMidnightAdapterBase.increaseMaxTtm, (type(uint32).max));
        adapter.submit(maxTtm);
        adapter.increaseMaxTtm(type(uint32).max);
        deal(address(usdc), address(this), DEPOSIT);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, address(this));
        address borrower = makeAddr("borrower");
        deal(address(collateral), borrower, DEPOSIT);
        vm.startPrank(borrower);
        collateral.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, DEPOSIT, borrower);
        vm.stopPrank();
        Offer memory offer;
        offer.market = market;
        offer.maker = borrower;
        offer.receiverIfMakerIsSeller = borrower;
        offer.expiry = type(uint256).max;
        offer.tick = MAX_TICK;
        offer.maxUnits = uint128(DEPOSIT);
        offer.continuousFeeCap = type(uint256).max;
        offer.ratifier = address(new DummyRatifier());
        vm.prank(borrower);
        midnight.setIsAuthorized(offer.ratifier, true, borrower);
        adapter.take(abi.decode(abi.encode(offer), (AdapterOffer)), "", DEPOSIT, abi.encode(address(0), bytes("")));
        assertEq(usdc.balanceOf(address(vault)), 0, "fully illiquid");
        for (uint256 i; i < 7; i++) {
            midnight.setMarketSettlementFee(IdLib.toId(market), i, 0.00001e18);
        }
        bundle = new MidnightVaultExitBundlesV1(address(midnight));
        midnight.setIsAuthorized(address(adapter), true, address(this));
        midnight.setIsAuthorized(address(bundle), true, address(this));
        vault.approve(address(bundle), type(uint256).max);
        usdc.approve(address(bundle), type(uint256).max);
        deal(address(usdc), address(this), FEE);
        // Assumption: Midnight has enough USDC liquidity to fund the flash loan.
        deal(address(usdc), address(midnight), DEPOSIT);
    }

    function configureVault(bytes memory data) internal {
        vault.submit(data);
        (bool success, bytes memory result) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function testIlliquidExit() public {
        checkExit(0);
    }

    function testExitWithExtraIdle() public {
        deal(address(usdc), address(this), FEE * 2);
        vault.deposit(FEE, address(this));
        checkExit(FEE);
    }

    function checkExit(uint256 idle) internal {
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 walletBefore = usdc.balanceOf(address(this));
        uint256 penaltyAssets = ASSETS.mulDivUp(PENALTY, 1e18);
        uint256 penaltyShares = vault.previewWithdraw(penaltyAssets);
        uint256 withdrawn = ASSETS + idle;
        uint256 withdrawnShares = vault.previewWithdraw(withdrawn);
        uint256 claimableBefore = midnight.claimableSettlementFee(address(usdc));
        bundle.midnightVaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), market, ASSETS, block.timestamp
        );
        bytes32 id = IdLib.toId(market);
        assertEq(midnight.credit(id, address(this)), ASSETS, "gross credit");
        // Pending fees are continuous fees, not the separately paid settlement fee; continuous fees are zero here.
        assertEq(midnight.pendingFee(id, address(this)), 0, "pending fee");
        assertEq(vault.balanceOf(address(this)), sharesBefore - penaltyShares - withdrawnShares, "burned shares");
        assertEq(usdc.balanceOf(address(bundle)), 0, "bundle USDC");
        assertEq(vault.balanceOf(address(bundle)), 0, "bundle shares");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter USDC");
        assertEq(midnight.claimableSettlementFee(address(usdc)), claimableBefore + FEE, "claimable fee");
        assertEq(walletBefore - usdc.balanceOf(address(this)), FEE - idle, "wallet fee remainder");
        assertEq(vault.totalAssets(), totalAssetsBefore - withdrawn - penaltyAssets, "total assets");
        assertEq(bundle.initiator(), address(0), "lock cleared");
    }

    function testUnauthorizedCallback() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.UnauthorizedCallback.selector);
        bundle.onFlashLoan(address(bundle), new address[](0), new uint256[](0), "");
    }

    function testUnsolicitedMidnightCallback() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert(MidnightVaultExitBundlesV1.UnauthorizedCallback.selector);
        midnight.flashLoan(tokens, amounts, address(bundle), "");
    }

    function testDeadlinePassed() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.DeadlinePassed.selector);
        bundle.midnightVaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), market, ASSETS, block.timestamp - 1
        );
    }

    function testMissingFeeAllowance() public {
        usdc.approve(address(bundle), 0);
        vm.expectRevert();
        bundle.midnightVaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), market, ASSETS, block.timestamp
        );
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0, "atomic exit");
        assertEq(bundle.initiator(), address(0), "lock rolled back");
    }

    function testZeroAssets() public {
        uint256 sharesBefore = vault.balanceOf(address(this));
        bundle.midnightVaultExitBundlesV1InKindRedemptionVaultV2(
            address(vault), address(adapter), market, 0, block.timestamp
        );
        assertEq(vault.balanceOf(address(this)), sharesBefore);
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0);
        assertEq(usdc.balanceOf(address(bundle)), 0);
        assertEq(vault.balanceOf(address(bundle)), 0);
    }
}
