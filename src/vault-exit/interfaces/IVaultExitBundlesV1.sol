1|// SPDX-License-Identifier: GPL-2.0-or-later
2|// Copyright (c) 2026 Morpho Association
3|pragma solidity >=0.8.0;
4|
5|import {MarketParams} from "../../../lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
6|
7|/// @dev An empty permit (v, r and s all zero) means no permit is submitted.
8|/// @dev A permit with an already consumed nonce is not submitted either.
9|struct SharesPermit {
10|    uint256 value;
11|    uint256 nonce;
12|    uint256 deadline;
13|    uint8 v;
14|    bytes32 r;
15|    bytes32 s;
16|}
17|
18|interface IVaultExitBundlesV1 {
19|    /// ERRORS ///
20|    error AdapterNotPartOfVault();
21|    error DeadlinePassed();
22|    error InvalidAdaptersLength();
23|    error LiquidityAdapterMismatch();
24|    error MorphoMismatch();
25|    error PctExceeded();
26|    error UnauthorizedCallback();
27|
28|    /// STORAGE GETTERS ///
29|    function BLUE() external view returns (address);
30|
31|    /// FUNCTIONS ///
32|    function vaultExitBundlesV1InKindRedemptionVaultV1(
33|        address vault,
34|        MarketParams[] memory marketParamsList,
35|        uint256 exitAssets,
36|        SharesPermit memory sharesPermit,
37|        uint256 deadline
38|    ) external;
39|
40|    function vaultExitBundlesV1InKindRedemptionVaultV2(
41|        address vault,
42|        address adapter,
43|        MarketParams[] memory marketParamsList,
44|        uint256 exitAssets,
45|        SharesPermit memory sharesPermit,
46|        uint256 deadline
47|    ) external;
48|
49|    function vaultExitBundlesV1ForceWithdrawVaultV2(
50|        address vault,
51|        address adapter,
52|        uint256 exitAssets,
53|        SharesPermit memory sharesPermit,
54|        uint256 referralFeePct,
55|        address referralFeeRecipient,
56|        uint256 deadline
57|    ) external;
58|}