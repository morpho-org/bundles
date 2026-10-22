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

Callers must authorize the selected bundle on Morpho Blue; opening also requires approval to pull collateral.

### [UniswapV4LeverageBundlesV1](src/leverage/UniswapV4LeverageBundlesV1.sol)

- `uniswapV4LeverageBundlesV1Open` — supply collateral and increase leverage with an exact-output Uniswap v4 swap.
- `uniswapV4LeverageBundlesV1Delever` — repay part of the debt by swapping collateral for loan tokens through Uniswap v4.
- `uniswapV4LeverageBundlesV1Close` — repay all borrow shares and withdraw the remaining collateral through Uniswap v4.

### [UniversalRouterLeverageBundlesV1](src/leverage/UniversalRouterLeverageBundlesV1.sol)

- `universalRouterLeverageBundlesV1Open` — supply collateral and increase leverage with an exact-output Universal Router route.
- `universalRouterLeverageBundlesV1Delever` — repay part of the debt by routing collateral for loan tokens.
- `universalRouterLeverageBundlesV1Close` — repay all borrow shares and withdraw the remaining collateral through a Universal Router route.

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
