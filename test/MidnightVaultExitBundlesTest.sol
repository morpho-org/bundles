// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";
import {MidnightVaultExitBundlesV1} from "../src/vault-exit/MidnightVaultExitBundlesV1.sol";
import {Permit} from "../src/libraries/TokenLib.sol";
import {IMorpho} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
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
import {
    IVaultV2CompatibleEnterGateFactory
} from "../lib/vault-v2/src/periphery/gates/interfaces/IVaultV2CompatibleEnterGateFactory.sol";
import {
    IVaultV2CompatibleEnterGate
} from "../lib/vault-v2/src/periphery/gates/interfaces/IVaultV2CompatibleEnterGate.sol";
import {IWhitelistEnterSubGate} from "../lib/vault-v2/src/periphery/gates/interfaces/IWhitelistEnterSubGate.sol";

interface IERC20PermitVault {
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract MidnightVaultExitBundlesTest is Test {
    using MathLib for uint256;

    IMidnight internal midnight;
    IMorpho internal morpho;
    IVaultV2 internal vault;
    IMidnightAdapter internal adapter;
    MidnightVaultExitBundlesV1 internal bundle;
    ERC20Mock internal usdc;
    Market internal market;
    IMidnightAdapterFactory internal adapterFactory;
    uint256 internal constant DEPOSIT = 10_000_000e6;
    uint256 internal constant ASSETS = 1_000_000e6;
    uint256 internal constant RATE = 0.00001e18;
    uint256 internal constant FEE = ASSETS * RATE / 1e18;
    uint256 internal constant PENALTY = 0.02e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public virtual {
        setUpMarket(false);
    }

    function setUpMarket(bool gated) internal {
        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(address(this))));
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
        adapterFactory = IMidnightAdapterFactory(
            deployCode("MidnightAdapterFactory.sol:MidnightAdapterFactory", abi.encode(address(midnight)))
        );
        address gateFactory;
        IWhitelistEnterSubGate subGate;
        if (gated) {
            gateFactory = deployCode("VaultV2CompatibleEnterGateFactory.sol:VaultV2CompatibleEnterGateFactory");
            subGate = IWhitelistEnterSubGate(
                deployCode(
                    "WhitelistEnterSubGate.sol:WhitelistEnterSubGate",
                    abi.encode(address(this), address(this), false, false)
                )
            );
            market.enterGate = IVaultV2CompatibleEnterGateFactory(gateFactory)
                .createVaultV2CompatibleEnterGate(address(subGate), bytes32(0));
            IVaultV2CompatibleEnterGate(market.enterGate).addAdmitterFactory(address(adapterFactory));
            subGate.setIsWhitelister(true, address(this), true);
            subGate.setIsWhitelister(false, address(this), true);
        }
        adapter = IMidnightAdapter(
            adapterFactory.createMidnightAdapter(address(vault), new uint256[](0), gateFactory, bytes32(0))
        );
        if (gated) subGate.setIsWhitelisted(true, address(adapter), true);
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
        if (gated) subGate.setIsWhitelisted(false, borrower, true);
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
            midnight.setMarketSettlementFee(IdLib.toId(market), i, RATE);
        }
        bundle = new MidnightVaultExitBundlesV1(address(midnight), address(morpho));
        midnight.setIsAuthorized(address(adapter), true, address(this));
        midnight.setIsAuthorized(address(bundle), true, address(this));
        vault.approve(address(bundle), type(uint256).max);
        usdc.approve(address(bundle), type(uint256).max);
        deal(address(usdc), address(this), 2 * FEE);
        // Assumption: Blue has flash liquidity; Midnight has none.
        deal(address(usdc), address(morpho), DEPOSIT);
        assertEq(usdc.balanceOf(address(midnight)), 0);
    }

    function configureVault(bytes memory data) internal {
        vault.submit(data);
        (bool success, bytes memory result) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function adapterMarkets() internal view returns (Market[] memory markets) {
        markets = new Market[](adapter.marketIdsLength());
        for (uint256 i; i < markets.length; i++) {
            markets[i] = midnight.toMarket(adapter.marketIds(i));
        }
    }

    function noPermit() internal pure returns (Permit memory) {}

    function signSharesPermit(uint256 privateKey, address owner, uint256 value) internal view returns (Permit memory) {
        uint256 nonce = IERC20PermitVault(address(vault)).nonces(owner);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(bundle), value, nonce, block.timestamp));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IERC20PermitVault(address(vault)).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return Permit({value: value, nonce: nonce, deadline: block.timestamp, v: v, r: r, s: s});
    }

    function addMarket(uint256 assets) internal returns (Market memory otherMarket) {
        ERC20 collateral = new ERC20("Other collateral", "OCOL");
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams(address(collateral), 1e18, 0.25e18, address(new Oracle()));
        otherMarket = Market(
            block.chainid,
            address(midnight),
            address(usdc),
            collaterals,
            block.timestamp + 8 days,
            0,
            address(0),
            address(0)
        );
        bytes[] memory ids = new bytes[](2);
        ids[0] =
            abi.encode("family", otherMarket.collateralParams, otherMarket.rcfThreshold, otherMarket.liquidatorGate);
        ids[1] = abi.encode("collateralToken", address(collateral));
        for (uint256 i; i < ids.length; i++) {
            configureVault(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[i], type(uint128).max)));
            configureVault(abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[i], 1e18)));
        }
        deal(address(usdc), address(this), usdc.balanceOf(address(this)) + assets);
        vault.deposit(assets, address(this));
        address borrower = makeAddr("other borrower");
        deal(address(collateral), borrower, assets);
        vm.startPrank(borrower);
        collateral.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(otherMarket, 0, assets, borrower);
        Offer memory offer;
        offer.market = otherMarket;
        offer.maker = borrower;
        offer.receiverIfMakerIsSeller = borrower;
        offer.expiry = type(uint256).max;
        offer.tick = MAX_TICK;
        offer.maxUnits = uint128(assets);
        offer.continuousFeeCap = type(uint256).max;
        offer.ratifier = address(new DummyRatifier());
        midnight.setIsAuthorized(offer.ratifier, true, borrower);
        vm.stopPrank();
        adapter.take(abi.decode(abi.encode(offer), (AdapterOffer)), "", assets, abi.encode(address(0), bytes("")));
        for (uint256 i; i < 7; i++) {
            midnight.setMarketSettlementFee(IdLib.toId(otherMarket), i, RATE);
        }
    }

    function createRedeemerDebt(uint256 units) internal {
        ERC20 collateral = ERC20(market.collateralParams[0].token);
        deal(address(collateral), address(this), collateral.balanceOf(address(this)) + units);
        collateral.approve(address(midnight), type(uint256).max);
        if (market.enterGate != address(0)) {
            IWhitelistEnterSubGate(IVaultV2CompatibleEnterGate(market.enterGate).subGate())
                .setIsWhitelisted(false, address(this), true);
        }
        midnight.supplyCollateral(market, 0, units, address(this));

        address lender = makeAddr(string.concat("debt lender", vm.toString(units)));
        if (market.enterGate != address(0)) {
            IWhitelistEnterSubGate(IVaultV2CompatibleEnterGate(market.enterGate).subGate())
                .setIsWhitelisted(true, lender, true);
        }
        deal(address(usdc), lender, units);
        vm.prank(lender);
        usdc.approve(address(midnight), type(uint256).max);
        Offer memory offer;
        offer.market = market;
        offer.buy = true;
        offer.maker = lender;
        offer.expiry = type(uint256).max;
        offer.tick = MAX_TICK;
        offer.maxUnits = uint128(units);
        offer.continuousFeeCap = type(uint256).max;
        offer.ratifier = address(new DummyRatifier());
        vm.prank(lender);
        midnight.setIsAuthorized(offer.ratifier, true, lender);
        midnight.take(offer, "", units, address(this), address(this), address(0), "");
        assertEq(midnight.debt(IdLib.toId(market), address(this)), units, "redeemer debt");
    }

    function exit(uint256 assets, uint256 maxSeed) internal {
        bundle.midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
            address(vault),
            address(adapter),
            assets,
            type(uint256).max,
            new bytes32[](0),
            maxSeed,
            noPermit(),
            block.timestamp
        );
    }

    function exitByLiquidity(uint256 maxAssets, uint256 maxMarkets) internal returns (uint256) {
        return exitByLiquidity(maxAssets, maxMarkets, new bytes32[](0));
    }

    function exitByLiquidity(uint256 maxAssets, uint256 maxMarkets, bytes32[] memory excludedMarketIds)
        internal
        returns (uint256)
    {
        return bundle.midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
            address(vault), address(adapter), maxAssets, maxMarkets, excludedMarketIds, 0, noPermit(), block.timestamp
        );
    }

    function referenceExit(uint256 assets, uint256 maxChunk)
        internal
        returns (uint256 shares, uint256 fees, uint256 walletFee)
    {
        uint256 snapshot = vm.snapshotState();
        uint256 walletBefore = usdc.balanceOf(address(this));
        uint256 idlePrincipal = MathLib.min(usdc.balanceOf(address(vault)), assets);
        if (idlePrincipal > 0) vault.withdraw(idlePrincipal, address(this), address(this));
        assets -= idlePrincipal;
        deal(address(usdc), address(this), walletBefore + idlePrincipal + maxChunk + maxChunk.mulDivUp(RATE, 1e18));
        usdc.approve(address(adapter), type(uint256).max);
        while (assets > 0) {
            uint256 chunk = assets < maxChunk ? assets : maxChunk;
            uint256 fee = chunk.mulDivUp(RATE, 1e18);
            uint256 penaltyShares = vault.previewWithdraw(chunk.mulDivUp(PENALTY, 1e18));
            assertEq(
                vault.forceDeallocate(address(adapter), abi.encode(market, address(this)), chunk, address(this)),
                penaltyShares
            );
            uint256 funding = chunk + fee;
            uint256 idle = usdc.balanceOf(address(vault));
            uint256 withdrawn = funding < idle ? funding : idle;
            uint256 withdrawnShares = vault.previewWithdraw(withdrawn);
            assertEq(vault.withdraw(withdrawn, address(this), address(this)), withdrawnShares);
            fees += fee;
            walletFee += funding - withdrawn;
            assets -= chunk;
        }
        shares = vault.balanceOf(address(this));
        vm.revertToState(snapshot);
    }

    function checkExit(uint256 assets, uint256 maxSeed) internal {
        uint256 idlePrincipal = MathLib.min(usdc.balanceOf(address(vault)), assets);
        uint256 creditAssets = assets - idlePrincipal;
        uint256 seed = creditAssets + creditAssets.mulDivUp(RATE, 1e18);
        uint256 blueBefore = usdc.balanceOf(address(morpho));
        if (seed > blueBefore) seed = blueBefore;
        if (maxSeed != 0 && seed > maxSeed) seed = maxSeed;
        uint256 maxChunk = seed.mulDivDown(1e18, 1e18 + RATE);
        (uint256 expectedShares, uint256 fees, uint256 walletFee) = referenceExit(assets, maxChunk);
        uint256 walletBefore = usdc.balanceOf(address(this));
        uint256 claimableBefore = midnight.claimableSettlementFee(address(usdc));
        vm.expectCall(
            address(morpho),
            abi.encodeCall(
                morpho.flashLoan,
                (address(usdc), seed, abi.encode(address(vault), address(adapter), adapterMarkets(), creditAssets))
            ),
            1
        );
        if (market.enterGate != address(0)) {
            assertFalse(IVaultV2CompatibleEnterGate(market.enterGate).canIncreaseCredit(address(this)));
            // forge-lint: disable-next-item(unsafe-typecast) test amounts bound the round count well below uint64.
            uint64 rounds = uint64((creditAssets + maxChunk - 1) / maxChunk);
            vm.expectCall(
                market.enterGate,
                abi.encodeCall(IVaultV2CompatibleEnterGate.admit, (address(this), address(adapterFactory))),
                rounds
            );
            vm.expectCall(market.enterGate, abi.encodeCall(IVaultV2CompatibleEnterGate.unadmit, ()), rounds);
        }
        exit(assets, maxSeed);
        assertEq(midnight.credit(IdLib.toId(market), address(this)), creditAssets, "gross credit");
        assertEq(midnight.pendingFee(IdLib.toId(market), address(this)), 0, "pending fee");
        assertEq(vault.balanceOf(address(this)), expectedShares, "penalties plus withdrawals");
        assertEq(usdc.balanceOf(address(this)), walletBefore + idlePrincipal - walletFee, "wallet balance");
        assertEq(midnight.claimableSettlementFee(address(usdc)), claimableBefore + fees, "sum of rounded fees");
        assertEq(usdc.balanceOf(address(morpho)), blueBefore, "seed repaid");
        assertEq(usdc.balanceOf(address(bundle)), 0, "bundle USDC");
        assertEq(vault.balanceOf(address(bundle)), 0, "bundle shares");
        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter USDC");
        assertEq(usdc.allowance(address(bundle), address(adapter)), 0, "adapter allowance");
        assertEq(usdc.allowance(address(bundle), address(morpho)), 0, "Blue allowance");
        assertEq(bundle.initiator(), address(0), "lock cleared");
        if (market.enterGate != address(0)) {
            assertFalse(IVaultV2CompatibleEnterGate(market.enterGate).canIncreaseCredit(address(this)), "unadmitted");
        }
    }

    function testSingleRound() public {
        checkExit(ASSETS, 0);
    }

    function testLiquidityLimitedExactRounds() public {
        uint256 chunk = ASSETS / 2;
        deal(address(usdc), address(morpho), chunk + chunk.mulDivUp(RATE, 1e18));
        checkExit(ASSETS, 0);
    }

    function testLiquidityLimitedPartialRound() public {
        deal(address(usdc), address(morpho), ASSETS / 3);
        checkExit(ASSETS, 0);
    }

    function testMaxSeedForcesRounds() public {
        checkExit(ASSETS, ASSETS / 2);
    }

    function testLiquiditySortedExitUsesLargestMarketFirst() public {
        Market memory otherMarket = addMarket(2 * DEPOSIT);

        uint256 exited = exitByLiquidity(ASSETS, 1);

        assertEq(exited, ASSETS, "exited assets");
        assertEq(midnight.credit(IdLib.toId(otherMarket), address(this)), ASSETS, "largest market");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0, "smaller market");
    }

    function testLiquiditySortedExitCapsAtSelectedMarkets() public {
        Market memory otherMarket = addMarket(ASSETS / 2);
        deal(address(usdc), address(this), 2 * DEPOSIT * RATE / 1e18);

        uint256 exited = exitByLiquidity(type(uint256).max, 1);

        assertEq(exited, DEPOSIT, "selected market capacity");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), DEPOSIT, "largest market drained");
        assertEq(midnight.credit(IdLib.toId(otherMarket), address(this)), 0, "unselected market");
    }

    function testLiquiditySortedExitResortsOnEveryCall() public {
        Market memory otherMarket = addMarket(2 * DEPOSIT);
        deal(address(usdc), address(this), 2 * DEPOSIT * RATE / 1e18);

        assertEq(exitByLiquidity(16_000_000e6, 1), 16_000_000e6, "first exit");
        assertEq(exitByLiquidity(ASSETS, 1), ASSETS, "second exit");

        assertEq(midnight.credit(IdLib.toId(otherMarket), address(this)), 16_000_000e6, "first largest market");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), ASSETS, "new largest market");
    }

    function testLiquiditySortedExitSkipsExcludedMarkets() public {
        Market memory otherMarket = addMarket(2 * DEPOSIT);
        bytes32[] memory excludedMarketIds = new bytes32[](1);
        excludedMarketIds[0] = IdLib.toId(otherMarket);

        assertEq(exitByLiquidity(ASSETS, 1, excludedMarketIds), ASSETS, "exit");

        assertEq(midnight.credit(IdLib.toId(otherMarket), address(this)), 0, "excluded largest market");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), ASSETS, "largest allowed market");
    }

    function testLiquiditySortedExitRejectsUnsortedExclusions() public {
        bytes32[] memory excludedMarketIds = new bytes32[](2);
        excludedMarketIds[0] = bytes32(uint256(2));
        excludedMarketIds[1] = bytes32(uint256(1));
        vm.expectRevert(MidnightVaultExitBundlesV1.ExclusionsNotSorted.selector);
        exitByLiquidity(ASSETS, 1, excludedMarketIds);
    }

    function testLiquiditySortedExitRejectsZeroMaxMarkets() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.ZeroMaxMarkets.selector);
        exitByLiquidity(ASSETS, 0);
    }

    function testRedeemerDebtBelowExitIsRepaidBeforeCredit() public {
        createRedeemerDebt(ASSETS / 2);
        exit(ASSETS, 0);
        assertEq(midnight.debt(IdLib.toId(market), address(this)), 0, "debt repaid");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), ASSETS / 2, "excess becomes credit");
    }

    function testRedeemerDebtAboveExitIsPartlyRepaid() public {
        createRedeemerDebt(2 * ASSETS);
        exit(ASSETS, 0);
        assertEq(midnight.debt(IdLib.toId(market), address(this)), ASSETS, "remaining debt");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0, "no excess credit");
    }

    function testSharesPermit() public {
        (address user, uint256 privateKey) = makeAddrAndKey("permit user");
        uint256 shares = vault.balanceOf(address(this));
        vault.transfer(user, shares);
        deal(address(usdc), user, 2 * FEE);
        vm.startPrank(user);
        midnight.setIsAuthorized(address(adapter), true, user);
        midnight.setIsAuthorized(address(bundle), true, user);
        usdc.approve(address(bundle), type(uint256).max);
        vm.stopPrank();

        Permit memory permit = signSharesPermit(privateKey, user, shares);
        vm.prank(user);
        bundle.midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
            address(vault),
            address(adapter),
            ASSETS,
            type(uint256).max,
            new bytes32[](0),
            0,
            permit,
            block.timestamp
        );

        assertEq(midnight.credit(IdLib.toId(market), user), ASSETS, "user credit");
        assertGt(vault.allowance(user, address(bundle)), 0, "permit submitted");
    }

    function testSharesPermitBoundsBurnedShares() public {
        (address user, uint256 privateKey) = makeAddrAndKey("limited permit user");
        vault.transfer(user, vault.balanceOf(address(this)));
        deal(address(usdc), user, 2 * FEE);
        vm.startPrank(user);
        midnight.setIsAuthorized(address(adapter), true, user);
        midnight.setIsAuthorized(address(bundle), true, user);
        usdc.approve(address(bundle), type(uint256).max);
        vm.stopPrank();

        Permit memory permit = signSharesPermit(privateKey, user, 1);
        vm.prank(user);
        vm.expectRevert();
        bundle.midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
            address(vault),
            address(adapter),
            ASSETS,
            type(uint256).max,
            new bytes32[](0),
            0,
            permit,
            block.timestamp
        );

        assertEq(midnight.credit(IdLib.toId(market), user), 0, "atomic exit");
    }

    function testIdleDoesNotCoverFees() public {
        vault.deposit(2 * FEE, address(this));
        usdc.approve(address(bundle), 0);
        vm.expectRevert();
        exit(ASSETS, ASSETS / 2);
    }

    function testFeesPartlyCoveredByIdle() public {
        vault.deposit(FEE / 2, address(this));
        checkExit(ASSETS, ASSETS / 2);
    }

    function testZeroAssets() public {
        uint256 sharesBefore = vault.balanceOf(address(this));
        exit(0, 0);
        assertEq(vault.balanceOf(address(this)), sharesBefore, "shares");
        assertEq(bundle.initiator(), address(0), "lock cleared");
    }

    function testFullyIdleExit() public {
        deal(address(usdc), address(this), usdc.balanceOf(address(this)) + ASSETS);
        vault.deposit(ASSETS, address(this));
        uint256 walletBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 burnedShares = vault.previewWithdraw(ASSETS);

        exit(ASSETS, 0);

        assertEq(usdc.balanceOf(address(this)), walletBefore + ASSETS, "idle assets");
        assertEq(vault.balanceOf(address(this)), sharesBefore - burnedShares, "burned shares");
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0, "no Midnight credit");
        assertEq(midnight.credit(IdLib.toId(market), address(adapter)), DEPOSIT, "adapter credit untouched");
        assertEq(bundle.initiator(), address(0), "lock cleared");
    }

    function testZeroLiquidity() public {
        deal(address(usdc), address(morpho), 0);
        vm.expectRevert(MidnightVaultExitBundlesV1.ZeroSeed.selector);
        exit(ASSETS, 0);
    }

    function testSeedCannotFundOneUnitAndFee() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.ZeroSeed.selector);
        exit(ASSETS, 1);
    }

    function testDeadlinePassed() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.DeadlinePassed.selector);
        bundle.midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
            address(vault),
            address(adapter),
            ASSETS,
            1,
            new bytes32[](0),
            0,
            noPermit(),
            block.timestamp - 1
        );
    }

    function testUnauthorizedCallback() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoFlashLoan(ASSETS, "");
    }

    function testUnsolicitedBlueCallback() public {
        vm.prank(address(morpho));
        vm.expectRevert(MidnightVaultExitBundlesV1.UnauthorizedCallback.selector);
        bundle.onMorphoFlashLoan(ASSETS, "");
    }

    function testMissingMidnightAuthorization(bool forAdapter) public {
        midnight.setIsAuthorized(forAdapter ? address(adapter) : address(bundle), false, address(this));
        vm.expectRevert();
        exit(ASSETS, 0);
    }

    function testInsufficientFeeAllowance() public {
        usdc.approve(address(bundle), FEE - 1);
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 blueBefore = usdc.balanceOf(address(morpho));
        vm.expectRevert();
        exit(ASSETS, ASSETS / 2);
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0, "atomic exit");
        assertEq(vault.balanceOf(address(this)), sharesBefore, "shares rolled back");
        assertEq(usdc.balanceOf(address(morpho)), blueBefore, "loan rolled back");
        assertEq(bundle.initiator(), address(0), "lock rolled back");
    }

    function testAdapterNotPartOfVault() public {
        vm.expectRevert(MidnightVaultExitBundlesV1.AdapterNotPartOfVault.selector);
        bundle.midnightVaultExitBundlesV1InKindRedemptionByLiquidity(
            address(vault),
            address(1),
            ASSETS,
            1,
            new bytes32[](0),
            0,
            noPermit(),
            block.timestamp
        );
    }

    function testMidnightMismatch() public {
        vm.mockCall(address(adapter), abi.encodeCall(adapter.midnight, ()), abi.encode(address(1)));
        vm.expectRevert(MidnightVaultExitBundlesV1.MidnightMismatch.selector);
        exit(ASSETS, 0);
    }

    function testLoanAssetMismatch() public {
        market.loanToken = address(1);
        exit(ASSETS, 0);
        assertEq(midnight.credit(IdLib.toId(market), address(this)), 0, "mutated caller market is not the book");
        market.loanToken = address(usdc);
        assertEq(midnight.credit(IdLib.toId(market), address(this)), ASSETS, "adapter market");
    }

    function recordExitGas(bytes memory data) internal {
        (bool success, bytes memory result) = address(bundle).call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        Vm.Gas memory measured = vm.lastCallGas();
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_int("refund counter", measured.gasRefunded);
        emit log_named_uint("intrinsic gas (included with --isolate)", intrinsic);
        emit log_named_uint("transaction gas before refunds", measured.gasTotalUsed);
    }

    function measureGas(uint256 rounds) internal {
        uint256 chunk = ASSETS / rounds;
        uint256 seed = chunk + chunk.mulDivUp(RATE, 1e18);
        recordExitGas(
            abi.encodeCall(
                MidnightVaultExitBundlesV1.midnightVaultExitBundlesV1InKindRedemptionByLiquidity,
                (
                    address(vault),
                    address(adapter),
                    ASSETS,
                    1,
                    new bytes32[](0),
                    seed,
                    noPermit(),
                    block.timestamp
                )
            )
        );
    }

    function testGasRound1() public {
        measureGas(1);
    }

    function testGasRound2() public {
        measureGas(2);
    }

    function testGasRound5() public {
        measureGas(5);
    }

    function testGasRound10() public {
        measureGas(10);
    }

    function testGasRound20() public {
        measureGas(20);
    }
}

contract MidnightVaultExitBundlesGatedTest is MidnightVaultExitBundlesTest {
    function setUp() public override {
        setUpMarket(true);
    }
}
