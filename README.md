# Morpho Bundles

Opinionated bundles to interact with the Morpho protocols.
Each entry-point execute a chain of calls, enabling to do multiple interactions in a single transaction.
Bundles have other benefits as well: being able to do atomic checks, being able to receive callbacks (e.g. to use flashloans), and simplifying calldata verification.
Entry-points are end-user-facing: they should be usable out of the box and are not meant to be called by other contracts.

Bundles are not meant to hold token balances (including native tokens) between transactions.
Users should expect tokens left to the bundles as lost.

## Bundles

### [MidnightBundlesV2](src/midnight/MidnightBundlesV2.sol)

Maker-side:

- `midnightBundlesV2CancelAndMake` — cancel offer groups, optionally park loan assets on Blue and/or supply collateral on Midnight, and publish new maker offers.

Supports `PriceRatifierV1` and `RateRatifierV1`, with optional signed root activation.
The maker must authorize the bundle on Midnight and approve it to pull any supplied loan or collateral assets.
See the entrypoint's NatSpec for parameters, validation limits, and ratifier authorization requirements.

Taker-side:

- `midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral` — buy a target number of units across offers and, repay debt if `repayEnabled` and target is not reached, then withdraw collateral.
- `midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral` — buy a target loan-asset amount across offers and, repay debt if `repayEnabled` and target is not reached, then withdraw collateral.
- `midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget` — supply collateral, then sell a target number of units, filling it first by withdrawing credit and then across offers.
- `midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget` — supply collateral, then sell a target loan-asset amount, filling it first by withdrawing credit and then across offers.

Repaying and withdrawing collateral (only) is done through the buy functions with `repayEnabled`, a nonzero target and an empty `offerFills` array.
Withdrawing credit (only) can be done through the sell functions with a nonzero target and an empty `offerFills` array.

The taker is msg.sender and must authorize the bundle on Midnight and approve it to pull the tokens it needs.

### [BlueBundlesV1](src/blue/BlueBundlesV1.sol)

- `blueBundlesV1SupplyCollateralAndBorrow` — supply collateral and borrow.
- `blueBundlesV1RepayAndWithdrawCollateral` — repay debt (optionally by shares) and withdraw collateral.
- `blueBundlesV1Supply` — supply loan assets to a market.
- `blueBundlesV1Withdraw` — withdraw supplied loan assets (optionally by shares).
- `blueBundlesV1MigrateBorrowPosition` — move a full borrow position (collateral and debt) from one market to another.

The three entrypoints that consume market liquidity (`blueBundlesV1SupplyCollateralAndBorrow`, `blueBundlesV1Withdraw`, and `blueBundlesV1MigrateBorrowPosition`) support VaultV2's BluePublicAllocator.

## Leverage bundles (PoC)

Callers must authorize `VeloraLeverageBundlesV1` on Morpho Blue; opening also requires approval to pull collateral.

All three entrypoints are non-reentrant; attempts by Augustus to call them again during a swap are rejected.

### [VeloraLeverageBundlesV1](src/leverage/VeloraLeverageBundlesV1.sol)

- `veloraLeverageBundlesV1Open` — supply `collateralAssets` from the caller and borrow up to `maxBorrowAssets` to buy and supply `collateralToBuy` additional collateral.
- `veloraLeverageBundlesV1Delever` — repay part of the debt by swapping withdrawn collateral for loan tokens.
- `veloraLeverageBundlesV1Close` — resize the quoted swap to the current debt, repay all borrow shares and return the remaining collateral.

Opening takes concrete token amounts in base units. `collateralToBuy` must be nonzero, and the collateral added to the caller's position is exactly `collateralAssets + collateralToBuy`. Unspent loan tokens are repaid, and excess collateral received from the swap is returned to the caller.

Frontends compute these amounts from the user's contribution and desired exposure. For a WAD-scaled collateral multiplier `L`, use `collateralToBuy = floor(collateralAssets * (L - 1e18) / 1e18)`, then obtain an exact-output quote and set `maxBorrowAssets` from its cost and the user's slippage tolerance. A target financial leverage instead requires accounting for quoted swap costs and any existing collateral and debt; the contract does not target a leverage ratio.

Open and delever take `maxLtv`, which caps the caller's resulting LTV using the market oracle price; `type(uint256).max` disables the check.

Swaps run inside Morpho Blue's supply-collateral and repay callbacks; the bundle does not use a flash loan. The position must remain healthy at the `maxBorrowAssets` or `maxCollateralIn` limit. Opening also requires market liquidity for the full `maxBorrowAssets` cap.

The bundle calls the Augustus v6.2 address fixed at deployment: `0x6A000F20005980200259B80c5102003040001068`, shared by Ethereum, Base, Arbitrum and Robinhood. Set `beneficiary` to the bundle. For open and delever, calldata is forwarded unchanged: its exact-output target must cover the amount the operation needs, plus one token base unit for Augustus's payout rounding. Positive slippage is retained unless a partner is configured. Excess loan tokens are returned to the user.

Only `swapExactAmountOut`, `swapExactAmountOutOnUniswapV2` and `swapExactAmountOutOnUniswapV3` are accepted; other selectors revert with `InvalidSelector`. Request quotes with `excludeRFQ=true` and `includeContractMethods=swapExactAmountOut,swapExactAmountOutOnUniswapV2,swapExactAmountOutOnUniswapV3`, then check `priceRoute.contractMethod` in the response because Velora silently ignores unknown method names.

Close takes the following arguments:

```solidity
veloraLeverageBundlesV1Close(
    MarketParams marketParams,
    uint256 maxCollateralIn,
    bytes swapData,
    uint256 deadline
)
```

The bundle derives the offsets for the 32-byte exact-output, maximum-input and quoted-input words from the selector in `swapData`. These offsets count bytes from the start of calldata, including the four-byte selector. For canonical Augustus v6.2 calldata:

| Method | `exactAmount` | `limitAmount` | `quotedAmount` |
| --- | ---: | ---: | ---: |
| `swapExactAmountOut` | 132 | 100 | 164 |
| `swapExactAmountOutOnUniswapV2` / `swapExactAmountOutOnUniswapV3` | 196 | 164 | 228 |

Morpho accrues interest and supplies the actual repayment amount to the close callback. The bundle sets the swap's exact output to `debtAssets + 1`, scales its maximum and quoted input amounts by `newOutput / originalOutput` (rounding down), and clamps the maximum input to `maxCollateralIn`. The original exact-output amount must be nonzero. The extra base unit covers Augustus's payout rounding; any excess received is refunded.

The route data must support changing these amounts; the bundle does not rewrite nested route data or reprice the route. All offset reads and writes are bounds-checked. The absolute spending cap and the post-swap token-balance checks still apply, so a stale route that cannot deliver the current debt within the cap reverts the entire close. A position without debt simply returns its collateral without using the swap data.

### [VaultBundlesV1](src/vault/VaultBundlesV1.sol)

- `vaultBundlesV1Deposit` — deposit assets into a vault.
- `vaultBundlesV1Withdraw` — withdraw assets from a vault.
- `vaultBundlesV1Migrate` — migrate assets from one vault to another.

### [VaultExitBundlesV1](src/vault-exit/VaultExitBundlesV1.sol)

- `vaultExitBundlesV1InKindRedemptionVaultV1` — in-kind redeem from an illiquid Vault V1.
- `vaultExitBundlesV1InKindRedemptionVaultV2` — withdraw idle assets and redeem the remainder in kind from an illiquid Vault V2.
- `vaultExitBundlesV1ForceWithdrawVaultV2` — force withdraw from a liquid Vault V2.

## Changelog

Changes between versions and source code of all versions are listed in the [CHANGELOG](./CHANGELOG.md).

## Developers

Compilation, testing and formatting are done with [forge](https://book.getfoundry.sh/getting-started/installation).

Formal verification of the bundles is done with the [Certora Prover](https://www.certora.com/prover).
See the [Certora README](./certora/README.md) for the full list of verified properties and the modeling assumptions they rely on.

## Audits

Audits can be found in the [audits](./audits/) folder.

## License

Files in this repository are publicly available under `MIT`, see [LICENSE](./LICENSE).
