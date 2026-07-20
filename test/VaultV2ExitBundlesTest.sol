1|// SPDX-License-Identifier: GPL-2.0-or-later
2|// Copyright (c) 2026 Morpho Association
3|pragma solidity ^0.8.0;
4|
5|import {Test} from "../lib/forge-std/src/Test.sol";
6|import {ERC20Mock} from "../lib/vault-v2/test/mocks/ERC20Mock.sol";
7|
8|import {VaultExitBundlesV1} from "../src/vault-exit/VaultExitBundlesV1.sol";
9|import {IVaultExitBundlesV1, SharesPermit} from "../src/vault-exit/interfaces/IVaultExitBundlesV1.sol";
10|
11|// Import from metamorpho/lib/morpho-blue to avoid duplicate types.
12|import {IMorpho, MarketParams, Id} from "../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
13|import {MarketParamsLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
14|import {MorphoLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";
15|import {MorphoBalancesLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
16|import {MorphoStorageLib} from "../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
17|import {ORACLE_PRICE_SCALE} from "../lib/metamorpho/lib/morpho-blue/src/libraries/ConstantsLib.sol";
18|import {OracleMock} from "../lib/metamorpho/lib/morpho-blue/src/mocks/OracleMock.sol";
19|
20|import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
21|import {IVaultV2Factory} from "../lib/vault-v2/src/interfaces/IVaultV2Factory.sol";
22|import {MAX_MAX_RATE, WAD} from "../lib/vault-v2/src/libraries/ConstantsLib.sol";
23|import {IMorphoMarketV1AdapterV2} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
24|import {
25|    IMorphoMarketV1AdapterV2Factory
26|} from "../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
27|
28|// Minimal ERC-2612 handle exposed by the vault shares, used to sign shares permits.
29|interface IERC20PermitVault {
30|    function nonces(address owner) external view returns (uint256);
31|    function DOMAIN_SEPARATOR() external view returns (bytes32);
32|}
33|
34|contract VaultV2ExitBundlesTest is Test {
35|    using MarketParamsLib for MarketParams;
36|    using MorphoLib for IMorpho;
37|    using MorphoBalancesLib for IMorpho;
38|
39|    uint256 internal constant LLTV_1 = 0.8e18;
40|    uint256 internal constant LLTV_2 = 0.9e18;
41|    uint256 internal constant PENALTY = 0.01e18;
42|
43|    uint256 internal constant MIN_ASSETS = 2; // assets == 1 ⇒ deallocatedAssets == 0 (see testInKindRedemptionTooSmallNoOp).
44|    uint256 internal constant MAX_ASSETS = 1e24;
45|
46|    IMorpho internal morpho;
47|    IVaultV2 internal vault;
48|    IMorphoMarketV1AdapterV2 internal adapter;
49|    IMorphoMarketV1AdapterV2Factory internal adapterFactory;
50|    VaultExitBundlesV1 internal vaultBundles;
51|
52|    ERC20Mock internal loanToken;
53|    ERC20Mock internal collateralToken;
54|    OracleMock internal oracle;
55|
56|    MarketParams internal marketParams; // vault market (made illiquid)
57|    MarketParams internal otherMarket; // same loan token, supplies Morpho's global liquidity
58|    MarketParams internal thirdMarket; // created in _setUpLiquidThreeMarkets
59|
60|    address internal owner = makeAddr("owner");
61|    address internal curator = makeAddr("curator");
62|    address internal allocator = makeAddr("allocator");
63|    address internal borrower = makeAddr("borrower");
64|    address internal liquidityProvider = makeAddr("liquidityProvider");
65|    address internal referralFeeRecipient = makeAddr("referralFeeRecipient");
66|
67|    // The empty shares permit (v, r and s all zero) is skipped by the bundler.
68|    SharesPermit internal noSharesPermit;
69|
70|    bytes32 internal constant PERMIT_TYPEHASH =
71|        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
72|
73|    function setUp() public {
74|        morpho = IMorpho(deployCode("Morpho.sol:Morpho", abi.encode(owner)));
75|        loanToken = new ERC20Mock(18);
76|        collateralToken = new ERC20Mock(18);
77|        oracle = new OracleMock();
78|        oracle.setPrice(ORACLE_PRICE_SCALE);
79|
80|        // IRM as address(0) to have zero borrow rate.
81|        vm.startPrank(owner);
82|        morpho.enableIrm(address(0));
83|        morpho.enableLltv(LLTV_1);
84|        morpho.enableLltv(LLTV_2);
85|        vm.stopPrank();
86|
87|        marketParams = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), LLTV_1);
88|        otherMarket = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), LLTV_2);
89|        morpho.createMarket(marketParams);
90|        morpho.createMarket(otherMarket);
91|
92|        // VaultV2 + Morpho-Market-V1 adapter (deployed via factories compiled through test/imports/VaultImport.sol).
93|        IVaultV2Factory vaultFactory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));
94|        vault = IVaultV2(vaultFactory.createVaultV2(owner, address(loanToken), bytes32(0)));
95|
96|        vm.prank(owner);
97|        vault.setCurator(curator);
98|        _submitAndExec(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
99|
100|        adapterFactory = IMorphoMarketV1AdapterV2Factory(
101|            deployCode(
102|                "MorphoMarketV1AdapterV2Factory.sol:MorphoMarketV1AdapterV2Factory", abi.encode(morpho, address(0))
103|            )
104|        );
105|        adapter = IMorphoMarketV1AdapterV2(adapterFactory.createMorphoMarketV1AdapterV2(address(vault)));
106|
107|        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
108|
109|        vm.prank(allocator);
110|        vault.setMaxRate(MAX_MAX_RATE);
111|
112|        // Caps for the adapter's three ids (adapter, collateral token, adapter+marketParams).
113|        _increaseCaps(abi.encode("this", address(adapter)));
114|        _increaseCaps(abi.encode("collateralToken", marketParams.collateralToken));
115|        _increaseCaps(abi.encode("this/marketParams", address(adapter), marketParams));
116|
117|        _submitAndExec(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(adapter), PENALTY)));
118|
119|        vaultBundles = new VaultExitBundlesV1(address(morpho));
120|        assertEq(vaultBundles.BLUE(), address(morpho));
121|    }
122|
123|    /// HELPERS ///
124|
125|    function _submitAndExec(bytes memory data) internal {
126|        vm.prank(curator);
127|        vault.submit(data);
128|        (bool success,) = address(vault).call(data);
129|        require(success, "exec failed");
130|    }
131|
132|    function _increaseCaps(bytes memory idData) internal {
133|        _submitAndExec(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
134|        _submitAndExec(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, WAD)));
135|    }
136|
137|    function optimalDeallocateAssets(uint256 assets) internal pure returns (uint256) {
138|        return assets * WAD / (WAD + PENALTY);
139|    }
140|
141|    /// @dev Wraps a single market into the singleton list expected by vaultExitBundlesV1InKindRedemptionVaultV2.
142|    function _singleton(MarketParams memory marketParams_) internal pure returns (MarketParams[] memory list) {
143|        list = new MarketParams[](1);
144|        list[0] = marketParams_;
145|    }
146|
147|    /// @dev Simulates accrued yield on a market via a storage cheat so its (and its suppliers') assets/shares ratio
148|    /// is non-round, exercising real rounding. Funds Morpho with the extra assets so they remain withdrawable.
149|    function _accrueYield(MarketParams memory mp, uint256 yield) internal {
150|        if (yield == 0) return;
151|        bytes32 slot = MorphoStorageLib.marketTotalSupplyAssetsAndSharesSlot(mp.id());
152|        uint256 packed = uint256(vm.load(address(morpho), slot));
153|        // forge-lint:disable-next-line(unsafe-typecast) truncating on purpose.
154|        uint256 totalSupplyAssets = uint128(packed);
155|        uint256 totalSupplyShares = packed >> 128;
156|        vm.store(address(morpho), slot, bytes32((totalSupplyShares << 128) | (totalSupplyAssets + yield)));
157|        deal(address(loanToken), address(morpho), loanToken.balanceOf(address(morpho)) + yield);
158|    }
159|
160|    /// @dev Signs an ERC-2612 permit of the bundler over owner's vault shares, for the given value and deadline.
161|    function _signSharesPermit(uint256 privateKey, address owner_, uint256 value, uint256 sigDeadline)
162|        internal
163|        view
164|        returns (SharesPermit memory)
165|    {
166|        uint256 nonce = IERC20PermitVault(address(vault)).nonces(owner_);
167|        bytes32 structHash =
168|            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, address(vaultBundles), value, nonce, sigDeadline));
169|        bytes32 digest =
170|            keccak256(abi.encodePacked("\x19\x01", IERC20PermitVault(address(vault)).DOMAIN_SEPARATOR(), structHash));
171|        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
172|        return SharesPermit({value: value, nonce: nonce, deadline: sigDeadline, v: v, r: r, s: s});
173|    }
174|
175|    function _setUpIlliquid(uint256 assets) internal {
176|        _setUpIlliquid(assets, address(this), true);
177|    }
178|
179|    /// @dev Deposits `assets` into the vault for `depositor`, allocates them to the Morpho market, then borrows all
180|    /// of them out so the market is fully illiquid. A second market is used so the Morpho contract still holds
181|    /// enough global loan token liquidity.
182|    /// @dev When approveBundler is false, the depositor grants no allowance, leaving it to a shares permit.
183|    function _setUpIlliquid(uint256 assets, address depositor, bool approveBundler) internal {
184|        deal(address(loanToken), depositor, assets);
185|        vm.startPrank(depositor);
186|        loanToken.approve(address(vault), type(uint256).max);
187|        vault.deposit(assets, depositor);
188|        vm.stopPrank();
189|
190|        vm.prank(allocator);
191|        vault.allocate(address(adapter), abi.encode(marketParams), assets);
192|        assertGt(adapter.supplyShares(Id.unwrap(marketParams.id())), 0, "allocation");
193|
194|        // Borrow everything out of the vault's market ⇒ illiquid.
195|        deal(address(collateralToken), borrower, 2 * assets);
196|        vm.startPrank(borrower);
197|        collateralToken.approve(address(morpho), type(uint256).max);
198|        morpho.supplyCollateral(marketParams, 2 * assets, borrower, "");
199|        morpho.borrow(marketParams, assets, 0, borrower, borrower);
200|        vm.stopPrank();
201|
202|        // Morpho global liquidity (from another market sharing the loan token).
203|        deal(address(loanToken), liquidityProvider, 2 * assets);
204|        vm.startPrank(liquidityProvider);
205|        loanToken.approve(address(morpho), type(uint256).max);
206|        morpho.supply(otherMarket, 2 * assets, 0, liquidityProvider, "");
207|        vm.stopPrank();
208|
209|        // The sender authorizes the bundler to move its vault shares (unless left to a shares permit).
210|        if (approveBundler) {
211|            vm.prank(depositor);
212|            vault.approve(address(vaultBundles), type(uint256).max);
213|        }
214|
215|        // Sanity: the depositor cannot redeem normally, yet still "owns" ~assets worth of shares.
216|        deal(address(loanToken), depositor, 0);
217|    }
218|
219|    /// @dev Deposits `assets` into the vault for address(this) and allocates them to the Morpho market. Nothing is
220|    /// borrowed out, so the market stays liquid and the assets can be deallocated directly from it.
221|    function _setUpLiquid(uint256 assets) internal {
222|        deal(address(loanToken), address(this), assets);
223|        loanToken.approve(address(vault), type(uint256).max);
224|        vault.deposit(assets, address(this));
225|
226|        vm.prank(allocator);
227|        vault.allocate(address(adapter), abi.encode(marketParams), assets);
228|        assertGt(adapter.supplyShares(Id.unwrap(marketParams.id())), 0, "allocation");
229|
230|        // The sender (this contract) authorizes the bundler to move its vault shares.
231|        vault.approve(address(vaultBundles), type(uint256).max);
232|
233|        // Reset so the final balance measures exactly what is withdrawn from the vault.
234|        deal(address(loanToken), address(this), 0);
235|    }
236|
237|    /// @dev Like _setUpLiquid but allocates across two adapter markets (`marketParams` and `otherMarket`). Nothing is
238|    /// borrowed out, so both markets stay liquid.
239|    function _setUpLiquidTwoMarkets(uint256 assets1, uint256 assets2) internal {
240|        // Allow the adapter to allocate into otherMarket too (the `this` and collateral caps are already shared).
241|        _increaseCaps(abi.encode("this/marketParams", address(adapter), otherMarket));
242|
243|        uint256 total = assets1 + assets2;
244|        deal(address(loanToken), address(this), total);
245|        loanToken.approve(address(vault), type(uint256).max);
246|        vault.deposit(total, address(this));
247|
248|        vm.startPrank(allocator);
249|        vault.allocate(address(adapter), abi.encode(marketParams), assets1);
250|        vault.allocate(address(adapter), abi.encode(otherMarket), assets2);
251|        vm.stopPrank();
252|
253|        // The sender (this contract) authorizes the bundler to move its vault shares.
254|        vault.approve(address(vaultBundles), type(uint256).max);
255|
256|        // Reset so the final balance measures exactly what is withdrawn from the vault.
257|        deal(address(loanToken), address(this), 0);
258|    }
259|
260|    /// @dev Like _setUpLiquidTwoMarkets but with a third market (`thirdMarket`, created here).
261|    function _setUpLiquidThreeMarkets(uint256 assets1, uint256 assets2, uint256 assets3) internal {
262|        vm.prank(owner);
263|        morpho.enableLltv(0.7e18);
264|        thirdMarket = MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), 0.7e18);
265|        morpho.createMarket(thirdMarket);
266|        _increaseCaps(abi.encode("this/marketParams", address(adapter), thirdMarket));
267|
268|        _setUpLiquidTwoMarkets(assets1, assets2);
269|
270|        deal(address(loanToken), address(this), assets3);
271|        vault.deposit(assets3, address(this));
272|        vm.prank(allocator);
273|        vault.allocate(address(adapter), abi.encode(thirdMarket), assets3);
274|        deal(address(loanToken), address(this), 0);
275|    }
276|
277|    /// @dev Like _setUpIlliquid but allocates across two adapter markets (`marketParams` and `otherMarket`), both
278|    /// borrowed out and given non-round share/asset ratios. A third market supplies Morpho's global loan liquidity.
279|    function _setUpIlliquidTwoMarkets(uint256 assets1, uint256 assets2) internal {
280|        // Allow the adapter to allocate into otherMarket too (the `this` and collateral caps are already shared).
281|        _increaseCaps(abi.encode("this/marketParams", address(adapter), otherMarket));
282|
283|        uint256 total = assets1 + assets2;
284|        deal(address(loanToken), address(this), total);
285|        loanToken.approve(address(vault), type(uint256).max);
286|        vault.deposit(total, address(this));
287|
288|        vm.startPrank(allocator);
289|        vault.allocate(address(adapter), abi.encode(marketParams), assets1);
290|        vault.allocate(address(adapter), abi.encode(otherMarket), assets2);
291|        vm.stopPrank();
292|
293|        // Borrow everything out of both markets ⇒ both illiquid.
294|        deal(address(collateralToken), borrower, 4 * total);
295|        vm.startPrank(borrower);
296|        collateralToken.approve(address(morpho), type(uint256).max);
297|        morpho.supplyCollateral(marketParams, 2 * assets1, borrower, "");
298|        morpho.borrow(marketParams, assets1, 0, borrower, borrower);
299|        morpho.supplyCollateral(otherMarket, 2 * assets2, borrower, "");
300|        morpho.borrow(otherMarket, assets2, 0, borrower, borrower);
301|        vm.stopPrank();
302|
303|        // Non-round share/asset ratios on both markets so the redemption math exercises real rounding.
304|        _accrueYield(marketParams, assets1 / 3);
305|        _accrueYield(otherMarket, assets2 / 7);
306|
307|        // Morpho global liquidity from a third market sharing the loan token (never borrowed).
308|        vm.prank(owner);
309|        morpho.enableLltv(0.5e18);
310|        MarketParams memory liquidityMarket =
311|            MarketParams(address(loanToken), address(collateralToken), address(oracle), address(0), 0.5e18);
312|        morpho.createMarket(liquidityMarket);
313|        deal(address(loanToken), liquidityProvider, 2 * total);
314|        vm.startPrank(liquidityProvider);
315|        loanToken.approve(address(morpho), type(uint256).max);
316|        morpho.supply(liquidityMarket, 2 * total, 0, liquidityProvider, "");
317|        vm.stopPrank();
318|
319|        vault.approve(address(vaultBundles), type(uint256).max);
320|        deal(address(loanToken), address(this), 0);
321|    }
322|
323|    /// AUTHORIZATION & VALIDATION ///
324|
325|    function testInKindRedemptionAdapterNotPartOfVault() public {
326|        uint256 assets = 100e18;
327|        _setUpIlliquid(assets);
328|
329|        vm.expectRevert(IVaultExitBundlesV1.AdapterNotPartOfVault.selector);
330|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
331|            address(vault), makeAddr("notAdapter"), _singleton(marketParams), assets, noSharesPermit, block.timestamp
332|        );
333|    }
334|
335|    /// @dev A market not allocated through the adapter (supplyShares == 0) is skipped; with no further market in the
336|    /// list to cover the requested assets, the loop runs past the list and reverts.
337|    function testInKindRedemptionMarketWithoutAdapterShares() public {
338|        uint256 assets = 100e18;
339|        _setUpIlliquid(assets);
340|
341|        // otherMarket was never allocated through the adapter ⇒ supplyShares == 0.
342|        vm.expectRevert();
343|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
344|            address(vault), address(adapter), _singleton(otherMarket), assets, noSharesPermit, block.timestamp
345|        );
346|    }
347|
348|    /// @dev The single market is allocated through the adapter but holds less than the requested amount; with no
349|    /// further market in the list to cover the remainder, the loop runs past the list and reverts.
350|    function testInKindRedemptionNotEnoughAvailable() public {
351|        uint256 assets = 100e18;
352|        _setUpIlliquid(assets);
353|
354|        // Requesting 2x the deposited assets ⇒ assetsToDeallocate ≈ 1.98x what the single market holds.
355|        uint256 tooMuch = 2 * assets;
356|        assertGt(optimalDeallocateAssets(tooMuch), assets, "precondition");
357|
358|        vm.expectRevert();
359|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
360|            address(vault), address(adapter), _singleton(marketParams), tooMuch, noSharesPermit, block.timestamp
361|        );
362|    }
363|
364|    function testInKindRedemptionInvalidAdaptersLength() public {
365|        address secondAdapter = adapterFactory.createMorphoMarketV1AdapterV2(address(vault));
366|        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (secondAdapter)));
367|
368|        vm.expectRevert(IVaultExitBundlesV1.InvalidAdaptersLength.selector);
369|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
370|            address(vault), address(adapter), new MarketParams[](0), 0, noSharesPermit, block.timestamp
371|        );
372|    }
373|
374|    function testOnMorphoSupplyOnlyBlue() public {
375|        vm.expectRevert(IVaultExitBundlesV1.UnauthorizedCallback.selector);
376|        vaultBundles.onMorphoSupply(1, "");
377|    }
378|
379|    /// @dev assets so small that deallocatedAssets rounds to 0 ⇒ the deallocation loop never runs (no-op).
380|    function testInKindRedemptionTooSmallNoOp() public {
381|        uint256 assets = 1;
382|        _setUpIlliquid(assets);
383|        assertEq(optimalDeallocateAssets(assets), 0, "precondition");
384|
385|        uint256 sharesBefore = vault.balanceOf(address(this));
386|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
387|            address(vault), address(adapter), _singleton(marketParams), assets, noSharesPermit, block.timestamp
388|        );
389|
390|        assertEq(vault.balanceOf(address(this)), sharesBefore, "vault balance unchanged");
391|        assertEq(morpho.expectedSupplyAssets(marketParams, address(this)), 0, "no supply position");
392|    }
393|
394|    /// IN-KIND REDEMPTION ///
395|
396|    /// @dev Mirrors the reference IkrTest: a normal withdraw from a fully illiquid vault reverts.
397|    function testCantWithdrawWhenIlliquid(uint256 assets) public {
398|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
399|        _setUpIlliquid(assets);
400|
401|        vm.prank(allocator);
402|        vault.setLiquidityAdapterAndData(address(adapter), abi.encode(marketParams));
403|
404|        vm.expectRevert();
405|        vault.withdraw(assets, address(this), address(this));
406|    }
407|
408|    function testInKindRedemption(uint256 assets) public {
409|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
410|        _setUpIlliquid(assets);
411|
412|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
413|            address(vault), address(adapter), _singleton(marketParams), assets, noSharesPermit, block.timestamp
414|        );
415|
416|        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
417|        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
418|        assertEq(loanToken.balanceOf(address(adapter)), 0, "adapter loan token balance");
419|        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
420|        assertEq(
421|            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
422|        );
423|        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
424|    }
425|
426|    /// @dev A sender that never approved the bundler can exit in a single transaction via sharesPermit.
427|    function testInKindRedemptionWithSharesPermit(uint256 assets) public {
428|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
429|        (address sigUser, uint256 sigUserKey) = makeAddrAndKey("sigUser");
430|        _setUpIlliquid(assets, sigUser, false);
431|
432|        assertEq(vault.allowance(sigUser, address(vaultBundles)), 0, "no prior allowance");
433|
434|        SharesPermit memory sharesPermit = _signSharesPermit(sigUserKey, sigUser, type(uint256).max, block.timestamp);
435|        vm.prank(sigUser);
436|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
437|            address(vault), address(adapter), _singleton(marketParams), assets, sharesPermit, block.timestamp
438|        );
439|
440|        assertEq(morpho.expectedSupplyAssets(marketParams, sigUser), optimalDeallocateAssets(assets), "supply position");
441|        assertApproxEqAbs(vault.balanceOf(sigUser), 0, 1, "vault balance");
442|    }
443|
444|    /// @dev When the first market does not hold enough, the loop drains it and pulls the remainder from the next
445|    /// market in the list, leaving the sender an in-kind position in both.
446|    function testInKindRedemptionMultipleMarkets() public {
447|        uint256 assets1 = 60e18;
448|        uint256 assets2 = 60e18;
449|        _setUpIlliquidTwoMarkets(assets1, assets2);
450|        _setSharePrice(1.07e18); // non-round vault share/asset ratio
451|
452|        MarketParams[] memory list = new MarketParams[](2);
453|        list[0] = marketParams;
454|        list[1] = otherMarket;
455|
456|        // The adapter's (yield-inflated) position in the first market.
457|        uint256 available1 = morpho.expectedSupplyAssets(marketParams, address(adapter));
458|
459|        // Deallocate more than the first market holds, so the remainder must come from the second.
460|        uint256 exitAssets = 90e18;
461|        uint256 deallocate = optimalDeallocateAssets(exitAssets);
462|        assertGt(deallocate, available1, "precondition: one market is not enough");
463|
464|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
465|            address(vault), address(adapter), list, exitAssets, noSharesPermit, block.timestamp
466|        );
467|
468|        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
469|        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
470|        // First market drained, remainder pulled from the second.
471|        assertApproxEqAbs(
472|            morpho.expectedSupplyAssets(marketParams, address(this)), available1, 3, "first market position"
473|        );
474|        assertApproxEqAbs(
475|            morpho.expectedSupplyAssets(otherMarket, address(this)),
476|            deallocate - available1,
477|            3,
478|            "second market position"
479|        );
480|    }
481|
482|    function testInKindRedemptionSkipsEmptyAdapterMarket() public {
483|        uint256 assets = 100e18;
484|        _setUpIlliquid(assets);
485|        assertEq(adapter.supplyShares(Id.unwrap(otherMarket.id())), 0, "otherMarket empty in adapter");
486|
487|        MarketParams[] memory list = new MarketParams[](2);
488|        list[0] = otherMarket;
489|        list[1] = marketParams;
490|
491|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
492|            address(vault), address(adapter), list, assets, noSharesPermit, block.timestamp
493|        );
494|
495|        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
496|        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
497|        assertEq(
498|            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
499|        );
500|    }
501|
502|    /// @dev The first list entry can be a market over a different loan token (the adapter holds no position in it):
503|    /// the Blue approval token is derived from the vault, so the foreign entry is skipped like any empty adapter
504|    /// market. Deriving the token from marketParamsList[0] would approve the wrong token and revert when Blue pulls
505|    /// the supplied assets.
506|    function testInKindRedemptionForeignFirstMarket(uint256 assets) public {
507|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
508|        _setUpIlliquid(assets);
509|
510|        ERC20Mock foreignToken = new ERC20Mock(18);
511|        MarketParams memory foreignMarket =
512|            MarketParams(address(foreignToken), address(collateralToken), address(oracle), address(0), LLTV_1);
513|        morpho.createMarket(foreignMarket);
514|        assertEq(adapter.supplyShares(Id.unwrap(foreignMarket.id())), 0, "foreignMarket empty in adapter");
515|
516|        MarketParams[] memory list = new MarketParams[](2);
517|        list[0] = foreignMarket;
518|        list[1] = marketParams;
519|
520|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
521|            address(vault), address(adapter), list, assets, noSharesPermit, block.timestamp
522|        );
523|
524|        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
525|        assertEq(loanToken.balanceOf(address(this)), 0, "address(this) loan token balance");
526|        assertEq(
527|            morpho.expectedSupplyAssets(marketParams, address(this)), optimalDeallocateAssets(assets), "supply position"
528|        );
529|    }
530|
531|    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
532|    function testInKindRedemptionDeadlinePassed() public {
533|        uint256 assets = 100e18;
534|        _setUpIlliquid(assets);
535|
536|        vm.expectRevert(IVaultExitBundlesV1.DeadlinePassed.selector);
537|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
538|            address(vault), address(adapter), _singleton(marketParams), assets, noSharesPermit, block.timestamp - 1
539|        );
540|    }
541|
542|    /// @dev Set a share price != 1 while keeping the vault balance consistent with the total supply.
543|    function _setSharePrice(uint256 priceWad) internal {
544|        uint256 newShares = vault.totalAssets() * WAD / priceWad;
545|        vm.store(address(vault), bytes32(uint256(11)), bytes32(newShares));
546|        vm.store(address(vault), keccak256(abi.encode(address(this), uint256(12))), bytes32(newShares));
547|        assertEq(vault.totalSupply(), newShares, "totalSupply slot");
548|        assertEq(vault.balanceOf(address(this)), newShares, "balanceOf slot");
549|    }
550|
551|    /// @dev Passing assets = previewRedeem(balanceOf(sender) - 2) never reverts and
552|    /// sweeps all but a few assets' worth of the position (on top of the 2 shares). The
553|    /// 2 shares margin keeps the two ceil-rounded withdrawals from over-burning.
554|    function testInKindRedemptionSafeExit(uint256 assets, uint256 priceWad) public {
555|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
556|        priceWad = bound(priceWad, WAD / 10, 10 * WAD);
557|        _setUpIlliquid(assets);
558|        _setSharePrice(priceWad);
559|
560|        uint256 sharesBefore = vault.balanceOf(address(this));
561|        vm.assume(sharesBefore > 2);
562|        uint256 amount = vault.previewRedeem(sharesBefore - 2);
563|        vm.assume(optimalDeallocateAssets(amount) > 0);
564|
565|        vaultBundles.vaultExitBundlesV1InKindRedemptionVaultV2(
566|            address(vault), address(adapter), _singleton(marketParams), amount, noSharesPermit, block.timestamp
567|        );
568|
569|        assertLe(
570|            vault.previewRedeem(vault.balanceOf(address(this))), 2 * priceWad / WAD + 2, "more than 2 shares worth left"
571|        );
572|    }
573|
574|    /// FORCE WITHDRAWAL ///
575|
576|    function testForceWithdrawInvalidAdaptersLength() public {
577|        address secondAdapter = adapterFactory.createMorphoMarketV1AdapterV2(address(vault));
578|        _submitAndExec(abi.encodeCall(IVaultV2.addAdapter, (secondAdapter)));
579|
580|        vm.expectRevert(IVaultExitBundlesV1.InvalidAdaptersLength.selector);
581|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
582|            address(vault), address(adapter), 0, noSharesPermit, 0, address(0), block.timestamp
583|        );
584|    }
585|
586|    function testForceWithdrawAdapterNotPartOfVault() public {
587|        uint256 assets = 100e18;
588|        _setUpLiquid(assets);
589|
590|        vm.expectRevert(IVaultExitBundlesV1.AdapterNotPartOfVault.selector);
591|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
592|            address(vault), makeAddr("notAdapter"), assets, noSharesPermit, 0, address(0), block.timestamp
593|        );
594|    }
595|
596|    /// @dev The adapter's markets hold less than the requested amount; the loop runs past the market list and reverts.
597|    function testForceWithdrawNotEnoughAvailable() public {
598|        uint256 assets = 100e18;
599|        _setUpLiquid(assets);
600|
601|        vm.expectRevert();
602|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
603|            address(vault), address(adapter), 2 * assets, noSharesPermit, 0, address(0), block.timestamp
604|        );
605|    }
606|
607|    function testForceWithdraw(uint256 assets) public {
608|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
609|        _setUpLiquid(assets);
610|
611|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
612|            address(vault), address(adapter), assets, noSharesPermit, 0, address(0), block.timestamp
613|        );
614|
615|        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
616|        assertEq(loanToken.balanceOf(address(vault)), 0, "vault loan token balance");
617|        assertEq(loanToken.balanceOf(address(adapter)), 0, "adapter loan token balance");
618|        // The user leaves the vault with the deallocated assets.
619|        assertEq(loanToken.balanceOf(address(this)), optimalDeallocateAssets(assets), "user loan token balance");
620|        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
621|    }
622|
623|    /// @dev The fee is deducted from the withdrawn assets; the remainder is sent to the user.
624|    function testForceWithdrawWithReferralFee(uint256 assets, uint256 referralFeePct) public {
625|        assets = bound(assets, MIN_ASSETS, MAX_ASSETS);
626|        referralFeePct = bound(referralFeePct, 0, WAD - 1);
627|        _setUpLiquid(assets);
628|
629|        uint256 withdrawn = optimalDeallocateAssets(assets);
630|        uint256 expectedFee = withdrawn * referralFeePct / WAD;
631|
632|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
633|            address(vault),
634|            address(adapter),
635|            assets,
636|            noSharesPermit,
637|            referralFeePct,
638|            referralFeeRecipient,
639|            block.timestamp
640|        );
641|
642|        assertEq(loanToken.balanceOf(address(vaultBundles)), 0, "bundler loan token balance");
643|        assertEq(loanToken.balanceOf(address(this)), withdrawn - expectedFee, "user net");
644|        assertEq(loanToken.balanceOf(referralFeeRecipient), expectedFee, "referralFeeRecipient fee");
645|        assertApproxEqAbs(vault.balanceOf(address(this)), 0, 1, "vault balance");
646|    }
647|
648|    function testForceWithdrawPctExceeded() public {
649|        uint256 assets = 100e18;
650|        _setUpLiquid(assets);
651|
652|        vm.expectRevert(IVaultExitBundlesV1.PctExceeded.selector);
653|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
654|            address(vault), address(adapter), assets, noSharesPermit, WAD, referralFeeRecipient, block.timestamp
655|        );
656|    }
657|
658|    /// @dev Passing assets = previewRedeem(balanceOf(sender) - 8) sweeps the three markets and leaves the sender with
659|    /// almost nothing in the vault. The 8 shares margin keeps the ceil-rounded withdrawals (one per penalty plus the
660|    /// final one) from over-burning.
661|    function testForceWithdrawThreeMarkets() public {
662|        _setUpLiquidThreeMarkets(50e18, 30e18, 20e18);
663|
664|        uint256 sharesBefore = vault.balanceOf(address(this));
665|        uint256 amount = vault.previewRedeem(sharesBefore - 8);
666|        uint256 deallocate = optimalDeallocateAssets(amount);
667|        assertGt(deallocate, 80e18, "precondition: all three markets are needed");
668|
669|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
670|            address(vault), address(adapter), amount, noSharesPermit, 0, address(0), block.timestamp
671|        );
672|
673|        assertEq(loanToken.balanceOf(address(this)), deallocate, "user loan token balance");
674|        // The first two markets are drained, the remainder is pulled from the third.
675|        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 0, "first market position");
676|        assertEq(morpho.expectedSupplyAssets(otherMarket, address(adapter)), 0, "second market position");
677|        assertApproxEqAbs(
678|            morpho.expectedSupplyAssets(thirdMarket, address(adapter)), 100e18 - deallocate, 3, "third market position"
679|        );
680|        assertLe(vault.previewRedeem(vault.balanceOf(address(this))), 10, "almost nothing left in the vault");
681|    }
682|
683|    /// @dev The first market's liquidity is partially borrowed out, so only its available liquidity is taken from it
684|    /// and the rest comes from the second market.
685|    function testForceWithdrawMarketLiquidityLimited() public {
686|        _setUpLiquidTwoMarkets(100e18, 100e18);
687|
688|        // Borrow 40 out of the first market ⇒ only 60 of the adapter's 100 position is withdrawable there.
689|        deal(address(collateralToken), borrower, 100e18);
690|        vm.startPrank(borrower);
691|        collateralToken.approve(address(morpho), type(uint256).max);
692|        morpho.supplyCollateral(marketParams, 100e18, borrower, "");
693|        morpho.borrow(marketParams, 40e18, 0, borrower, borrower);
694|        vm.stopPrank();
695|
696|        uint256 exitAssets = 101e18;
697|        assertEq(optimalDeallocateAssets(exitAssets), 100e18, "precondition");
698|
699|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
700|            address(vault), address(adapter), exitAssets, noSharesPermit, 0, address(0), block.timestamp
701|        );
702|
703|        assertEq(loanToken.balanceOf(address(this)), 100e18, "user loan token balance");
704|        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 40e18, "first market position");
705|        assertEq(morpho.expectedSupplyAssets(otherMarket, address(adapter)), 60e18, "second market position");
706|    }
707|
708|    /// @dev The liquidity available through the liquidity adapter is withdrawn first, without penalty; only the
709|    /// remainder is force deallocated.
710|    function testForceWithdrawLiquidityAdapterFirst() public {
711|        _setUpLiquidTwoMarkets(60e18, 40e18);
712|
713|        vm.prank(allocator);
714|        vault.setLiquidityAdapterAndData(address(adapter), abi.encode(marketParams));
715|
716|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
717|            address(vault), address(adapter), 80e18, noSharesPermit, 0, address(0), block.timestamp
718|        );
719|
720|        // 60 comes penalty-free through the liquidity adapter, the remaining 20 pays the penalty.
721|        assertEq(loanToken.balanceOf(address(this)), 60e18 + optimalDeallocateAssets(20e18), "user loan token balance");
722|        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 0, "first market position");
723|        assertApproxEqAbs(
724|            morpho.expectedSupplyAssets(otherMarket, address(adapter)),
725|            40e18 - optimalDeallocateAssets(20e18),
726|            2,
727|            "second market position"
728|        );
729|    }
730|
731|    /// @dev A request fully covered by the liquidity adapter pays no penalty and never force deallocates.
732|    function testForceWithdrawOnlyLiquidityAdapter() public {
733|        _setUpLiquidTwoMarkets(60e18, 40e18);
734|
735|        vm.prank(allocator);
736|        vault.setLiquidityAdapterAndData(address(adapter), abi.encode(marketParams));
737|
738|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
739|            address(vault), address(adapter), 50e18, noSharesPermit, 0, address(0), block.timestamp
740|        );
741|
742|        assertEq(loanToken.balanceOf(address(this)), 50e18, "user loan token balance");
743|        assertEq(morpho.expectedSupplyAssets(marketParams, address(adapter)), 10e18, "first market position");
744|        assertEq(morpho.expectedSupplyAssets(otherMarket, address(adapter)), 40e18, "second market position");
745|    }
746|
747|    /// @dev The vault's idle assets are withdrawn first, without penalty; only the remainder is force deallocated.
748|    function testForceWithdrawIdleAssetsFirst() public {
749|        deal(address(loanToken), address(this), 100e18);
750|        loanToken.approve(address(vault), type(uint256).max);
751|        vault.deposit(100e18, address(this));
752|
753|        // Allocate only 70 ⇒ 30 stay idle in the vault.
754|        vm.prank(allocator);
755|        vault.allocate(address(adapter), abi.encode(marketParams), 70e18);
756|
757|        vault.approve(address(vaultBundles), type(uint256).max);
758|        deal(address(loanToken), address(this), 0);
759|
760|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
761|            address(vault), address(adapter), 40e18, noSharesPermit, 0, address(0), block.timestamp
762|        );
763|
764|        // 30 comes penalty-free from the idle assets, the remaining 10 pays the penalty.
765|        assertEq(loanToken.balanceOf(address(this)), 30e18 + optimalDeallocateAssets(10e18), "user loan token balance");
766|    }
767|
768|    /// @dev Reverts once `deadline` is in the past (checkDeadline runs before the body).
769|    function testForceWithdrawDeadlinePassed() public {
770|        uint256 assets = 100e18;
771|        _setUpLiquid(assets);
772|
773|        vm.expectRevert(IVaultExitBundlesV1.DeadlinePassed.selector);
774|        vaultBundles.vaultExitBundlesV1ForceWithdrawVaultV2(
775|            address(vault), address(adapter), assets, noSharesPermit, 0, address(0), block.timestamp - 1
776|        );
777|    }
778|}