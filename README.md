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

### [ZeroExLeverageBundlesV1](src/leverage/ZeroExLeverageBundlesV1.sol)

The bundle provides exact-output BUY and exact-input SELL variants of open, delever and close. Callers must authorize the bundle on Morpho Blue and approve it to pull collateral for open operations.

For the constructor, pass the chain's Morpho Blue address, the 0x AllowanceHolder (`0x0000000000001fF3684f28c67538d4D072C22734`) and the 0x registry/deployer (`0x00000000000004533Fe15556B1E086BB1A72cEae`); the latter two addresses are shared by Ethereum, Base, Arbitrum and Robinhood.

Request each 0x Swap API quote with `taker` set to the deployed bundle, then pass `transaction.data` unchanged as `swapData`:

- `zeroExLeverageBundlesV1Open`: BUY `collateralToBuy`; keep `maxSellAmount` within `maxBorrowAssets`.
- `zeroExLeverageBundlesV1OpenExactIn`: SELL `borrowAssets` with `minBuyAmount=minCollateralOut`.
- `zeroExLeverageBundlesV1Delever`: BUY `repayAssets`; keep `maxSellAmount` within `maxCollateralIn`.
- `zeroExLeverageBundlesV1DeleverExactIn`: SELL `collateralToSell` with `minBuyAmount=minRepayAssets`.
- `zeroExLeverageBundlesV1Close`: BUY current debt plus a small buffer for interest accrued before execution, keeping `maxSellAmount` within `maxCollateralIn`; the bundle sets Settler's minimum output to callback debt so unused input is returned as collateral.
- `zeroExLeverageBundlesV1CloseExactIn`: SELL with a `minBuyAmount` that covers both `minLoanOut` and debt. The bundle overwrites the first action's sell amount with the full collateral balance, so `sellEntireBalance` is optional.

Exact-output open and delever overwrite Settler's `minAmountOut` with the operation target; exact-input operations overwrite both that floor and the first action's input amount. Exact-output close sets `minAmountOut` to the callback debt, so the route's unused sell-token input is returned as collateral. No one-wei adjustment is needed. Quote exact-input routes close to the execution amounts: the bundle cannot rescale per-hop minimums inside route actions. Leverage and debt reduction depend on the executed price, bounded by the minimum output and `maxLtv` where applicable; exact-input close returns equity as loan tokens.

The bundle accepts only a registered Settler: `ownerOf(2)` or `prev(2)` must match the quote's Settler. A paused registry's `ownerOf` revert is bubbled up. The quoted AllowanceHolder `exec.amount` is ignored; each swap uses the operation's cap, checks balance deltas to ensure spent input does not exceed that cap and received output meets the required floor, then resets the allowance. Settler can make arbitrary calls, so the bundle locks its entrypoints through callbacks; Morpho Blue acts only on the caller's authorized position. Affiliate fees set via API params are reflected in the quote and covered by the bundle's checks.

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
