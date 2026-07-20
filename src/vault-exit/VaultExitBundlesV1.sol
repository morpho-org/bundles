1|// SPDX-License-Identifier: GPL-2.0-or-later
2|// Copyright (c) 2026 Morpho Association
3|pragma solidity 0.8.34;
4|
5|import {IVaultExitBundlesV1, SharesPermit} from "./interfaces/IVaultExitBundlesV1.sol";
6|import {TokenLib} from "../libraries/TokenLib.sol";
7|import {IERC20Permit} from "../libraries/interfaces/IERC20Permit.sol";
8|import {SafeTransferLib} from "../../lib/midnight/src/libraries/SafeTransferLib.sol";
9|import {MathLib} from "../../lib/vault-v2/src/libraries/MathLib.sol";
10|import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
11|import {IERC20} from "../../lib/vault-v2/src/interfaces/IERC20.sol";
12|import {WAD} from "../../lib/vault-v2/src/libraries/ConstantsLib.sol";
13|import {IMorphoMarketV1AdapterV2} from "../../lib/vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
14|import {IMetaMorpho} from "../../lib/metamorpho/src/interfaces/IMetaMorpho.sol";
15|import {IMorpho, MarketParams, Id} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
16|import {
17|    IMorphoSupplyCallback,
18|    IMorphoFlashLoanCallback
19|} from "../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorphoCallbacks.sol";
20|import {MorphoBalancesLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
21|import {MarketParamsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
22|import {SharesMathLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/SharesMathLib.sol";
23|import {UtilsLib} from "../../lib/metamorpho/lib/morpho-blue/src/libraries/UtilsLib.sol";
24|
25|/// @dev Meant to be used to exit a vault that allocates assets to Morpho Blue. The user either gets Morpho Blue shares (in-kind redemption) or assets (force withdrawal).
26|/// @dev Vaults that are used with this contract must be Vault V1 (MetaMorpho V1 or V1.1) or Vault V2.
27|/// @dev Vault V2 that are used with this contract must have only one adapter, and that adapter must be the MorphoMarketV1AdapterV2.
28|/// @dev Inherits the token safety requirements of Morpho Vaults and their dependencies.
29|/// @dev Unusable with tokens that revert on such a sequence: approve(..., 0); approve(..., type(uint256).max).
30|/// @dev Gated vaults (Vault V2) require this contract to be permitted by receiveAssetsGate, as it receives the withdrawn assets.
31|/// @dev No-ops are not systematically prevented.
32|/// @dev Zero checks are not systematically performed.
33|contract VaultExitBundlesV1 is IVaultExitBundlesV1, IMorphoSupplyCallback, IMorphoFlashLoanCallback {
34|    using MathLib for uint256;
35|    using MarketParamsLib for MarketParams;
36|    using SharesMathLib for uint256;
37|
38|    address public immutable BLUE;
39|
40|    constructor(address _blue) {
41|        BLUE = _blue;
42|    }
43|
44|    /// IN-KIND REDEMPTION VAULT V1 ///
45|
46|    /// @dev Exit from a Vault V1 and get Morpho Blue shares, even if the vault is illiquid and if the vault roles are not cooperating.
47|    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
48|    /// @dev Requires Morpho Blue to have at least exitAssets in loan token balance.
49|    /// @dev Requires the sender to have enough shares to withdraw exitAssets.
50|    /// @dev It may be the case that the vault became liquid, but calling this function still yields positions on the markets.
51|    /// @dev It's acknowledged that it is possible to call this function with duplicate markets in the list.
52|    function vaultExitBundlesV1InKindRedemptionVaultV1(
53|        address vault,
54|        MarketParams[] memory marketParamsList,
55|        uint256 exitAssets,
56|        SharesPermit memory sharesPermit,
57|        uint256 deadline
58|    ) external {
59|        require(block.timestamp <= deadline, DeadlinePassed());
60|        require(address(IMetaMorpho(vault).MORPHO()) == BLUE, MorphoMismatch());
61|
62|        permitShares(vault, sharesPermit);
63|        address loanToken = IMetaMorpho(vault).asset();
64|        TokenLib.forceApproveMax(loanToken, BLUE);
65|
66|        bytes memory data = abi.encode(vault, marketParamsList, msg.sender);
67|        IMorpho(BLUE).flashLoan(loanToken, exitAssets, data);
68|    }
69|
70|    function onMorphoFlashLoan(uint256 exitAssets, bytes calldata data) external {
71|        require(msg.sender == BLUE, UnauthorizedCallback());
72|        (address vault, MarketParams[] memory marketParamsList, address sender) =
73|            abi.decode(data, (address, MarketParams[], address));
74|
75|        uint256 assetsToDeallocate = exitAssets;
76|        for (uint256 i; assetsToDeallocate > 0; i++) {
77|            MarketParams memory marketParams = marketParamsList[i];
78|            if (!IMetaMorpho(vault).config(marketParams.id()).enabled) continue;
79|
80|            uint256 vaultAssets = MorphoBalancesLib.expectedSupplyAssets(IMorpho(BLUE), marketParams, vault);
81|            uint256 assets = UtilsLib.min(vaultAssets, assetsToDeallocate);
82|            assetsToDeallocate -= assets;
83|
84|            if (assets > 0) {
85|                IMorpho(BLUE).supply(marketParams, assets, 0, sender, "");
86|            }
87|        }
88|
89|        IMetaMorpho(vault).withdraw(exitAssets, address(this), sender);
90|    }
91|
92|    /// IN-KIND REDEMPTION VAULT V2 ///
93|
94|    /// @dev Exit from a Vault V2 and get Morpho Blue shares, even if the vault is illiquid and if the vault roles are not cooperating.
95|    /// @dev Assumes that adapter is a Morpho Blue adapter.
96|    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
97|    /// @dev The assetsToDeallocate amount is floor(exitAssets * WAD / (WAD + penalty)).
98|    /// @dev Requires Morpho Blue to have at least assetsToDeallocate in loan token balance.
99|    /// @dev Requires the sender to have enough shares to withdraw ceil(assets * penalty / WAD) and then assets, for each market in the list, where the sum of the assets is equal to assetsToDeallocate.
100|    /// @dev It may be the case that the vault became liquid, but calling this function still yields positions on the markets, and potentially pays the penalty.
101|    /// @dev If the liquidity adapter has some liquidity, withdrawing from the vault instead of calling this function avoids the penalty.
102|    /// @dev It's acknowledged that it is possible to call this function with duplicate markets in the list.
103|    function vaultExitBundlesV1InKindRedemptionVaultV2(
104|        address vault,
105|        address adapter,
106|        MarketParams[] memory marketParamsList,
107|        uint256 exitAssets,
108|        SharesPermit memory sharesPermit,
109|        uint256 deadline
110|    ) external {
111|        require(block.timestamp <= deadline, DeadlinePassed());
112|        require(IVaultV2(vault).adaptersLength() == 1, InvalidAdaptersLength());
113|        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
114|        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());
115|
116|        permitShares(vault, sharesPermit);
117|        TokenLib.forceApproveMax(IVaultV2(vault).asset(), BLUE);
118|
119|        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
120|        uint256 assetsToDeallocate = exitAssets.mulDivDown(WAD, WAD + penalty);
121|
122|        for (uint256 i; assetsToDeallocate > 0; i++) {
123|            uint256 adapterShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(Id.unwrap(marketParamsList[i].id()));
124|            (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
125|                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), marketParamsList[i]);
126|            uint256 adapterAssets = adapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
127|            uint256 assets = UtilsLib.min(adapterAssets, assetsToDeallocate);
128|            assetsToDeallocate -= assets;
129|
130|            if (assets > 0) {
131|                bytes memory data = abi.encode(vault, adapter, marketParamsList[i], msg.sender);
132|                IMorpho(BLUE).supply(marketParamsList[i], assets, 0, msg.sender, data);
133|            }
134|        }
135|    }
136|
137|    function onMorphoSupply(uint256 assets, bytes calldata data) external {
138|        require(msg.sender == BLUE, UnauthorizedCallback());
139|        (address vault, address adapter, MarketParams memory marketParams, address sender) =
140|            abi.decode(data, (address, address, MarketParams, address));
141|
142|        IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), assets, sender);
143|        IVaultV2(vault).withdraw(assets, address(this), sender);
144|    }
145|
146|    /// FORCE WITHDRAW VAULT V2 ///
147|
148|    /// @dev Withdraw from a Vault V2, even if the vault doesn't have enough idle and liquidity adapter assets.
149|    /// @dev Requires the adapter's markets to be liquid enough, otherwise the loop runs past the market list and reverts.
150|    /// @dev Assumes that adapter is a Morpho Blue adapter.
151|    /// @dev The sender must have given enough allowance over vault shares to this bundler, beforehand or via sharesPermit.
152|    /// @dev Starts by withdrawing without penalty everything the vault can pay: its idle assets and the liquidity available through the liquidity adapter.
153|    /// @dev The assetsToDeallocate amount is floor((exitAssets - assetsToWithdraw) * WAD / (WAD + penalty)), where assetsToWithdraw is the amount withdrawn without penalty.
154|    /// @dev The assetsToDeallocate amount is force deallocated by looping over the adapter's markets, taking from each market as much as its liquidity and the adapter's position allow before moving to the next one.
155|    /// @dev The referral fee is deducted from the withdrawn assets; the remainder is sent to msg.sender.
156|    /// @dev Fee = withdrawnAssets * referralFeePct / WAD; net = withdrawnAssets - fee.
157|    function vaultExitBundlesV1ForceWithdrawVaultV2(
158|        address vault,
159|        address adapter,
160|        uint256 exitAssets,
161|        SharesPermit memory sharesPermit,
162|        uint256 referralFeePct,
163|        address referralFeeRecipient,
164|        uint256 deadline
165|    ) external {
166|        require(block.timestamp <= deadline, DeadlinePassed());
167|        require(IVaultV2(vault).adaptersLength() == 1, InvalidAdaptersLength());
168|        require(IVaultV2(vault).isAdapter(adapter), AdapterNotPartOfVault());
169|        require(IMorphoMarketV1AdapterV2(adapter).morpho() == BLUE, MorphoMismatch());
170|        require(referralFeePct < WAD, PctExceeded());
171|
172|        permitShares(vault, sharesPermit);
173|
174|        address asset = IVaultV2(vault).asset();
175|        uint256 withdrawableAssets = IERC20(asset).balanceOf(vault);
176|        address liquidityAdapter = IVaultV2(vault).liquidityAdapter();
177|        if (liquidityAdapter != address(0)) {
178|            require(liquidityAdapter == adapter, LiquidityAdapterMismatch());
179|            MarketParams memory liquidityMarketParams = abi.decode(IVaultV2(vault).liquidityData(), (MarketParams));
180|            uint256 liquidityAdapterShares =
181|                IMorphoMarketV1AdapterV2(liquidityAdapter).supplyShares(Id.unwrap(liquidityMarketParams.id()));
182|            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
183|                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), liquidityMarketParams);
184|            uint256 liquidityAdapterAssets = liquidityAdapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
185|            withdrawableAssets += UtilsLib.min(liquidityAdapterAssets, totalSupplyAssets - totalBorrowAssets);
186|        }
187|        uint256 assetsToWithdraw = UtilsLib.min(exitAssets, withdrawableAssets);
188|        IVaultV2(vault).withdraw(assetsToWithdraw, address(this), msg.sender);
189|
190|        // pre-fetching the market list because the deallocate could drop a market from the list.
191|        uint256 marketIdsLength = IMorphoMarketV1AdapterV2(adapter).marketIdsLength();
192|        bytes32[] memory marketIds = new bytes32[](marketIdsLength);
193|        for (uint256 i; i < marketIdsLength; i++) {
194|            marketIds[i] = IMorphoMarketV1AdapterV2(adapter).marketIds(i);
195|        }
196|
197|        uint256 penalty = IVaultV2(vault).forceDeallocatePenalty(adapter);
198|        uint256 assetsToDeallocate = (exitAssets - assetsToWithdraw).mulDivDown(WAD, WAD + penalty);
199|        uint256 remainingAssets = assetsToDeallocate;
200|
201|        for (uint256 i; remainingAssets > 0; i++) {
202|            MarketParams memory marketParams = IMorpho(BLUE).idToMarketParams(Id.wrap(marketIds[i]));
203|            uint256 adapterShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(marketIds[i]);
204|            (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
205|                MorphoBalancesLib.expectedMarketBalances(IMorpho(BLUE), marketParams);
206|            uint256 adapterAssets = adapterShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
207|            uint256 availableToWithdraw = UtilsLib.min(adapterAssets, totalSupplyAssets - totalBorrowAssets);
208|            uint256 assets = UtilsLib.min(availableToWithdraw, remainingAssets);
209|            remainingAssets -= assets;
210|
211|            IVaultV2(vault).forceDeallocate(adapter, abi.encode(marketParams), assets, msg.sender);
212|        }
213|
214|        IVaultV2(vault).withdraw(assetsToDeallocate, address(this), msg.sender);
215|
216|        uint256 withdrawn = assetsToWithdraw + assetsToDeallocate;
217|        uint256 referralFeeAssets = withdrawn.mulDivDown(referralFeePct, WAD);
218|        if (referralFeeAssets > 0) SafeTransferLib.safeTransfer(asset, referralFeeRecipient, referralFeeAssets);
219|        SafeTransferLib.safeTransfer(asset, msg.sender, withdrawn - referralFeeAssets);
220|    }
221|
222|    /// INTERNAL ///
223|
224|    /// @dev The parameters signed by the user should be the same as the inputs of this function.
225|    /// @dev Skipped when the permit is empty (v, r and s all zero; which doesn't correspond to a valid signature), useful when shares are already permitted.
226|    /// @dev Skipped on an already consumed nonce (e.g. a front-run submission): the permit is not submitted in that case.
227|    /// @dev The signature deadline is independent of the bundle's deadline: signature not submitted stays submittable until sharesPermit.deadline, as revoking on the vault does not consume the nonce.
228|    function permitShares(address vault, SharesPermit memory sharesPermit) internal {
229|        bool emptyPermit = sharesPermit.v == 0 && sharesPermit.r == 0 && sharesPermit.s == 0;
230|
231|        if (!emptyPermit && IERC20Permit(vault).nonces(msg.sender) <= sharesPermit.nonce) {
232|            IERC20Permit(vault)
233|                .permit(
234|                    msg.sender,
235|                    address(this),
236|                    sharesPermit.value,
237|                    sharesPermit.deadline,
238|                    sharesPermit.v,
239|                    sharesPermit.r,
240|                    sharesPermit.s
241|                );
242|        }
243|    }
244|}