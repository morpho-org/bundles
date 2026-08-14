# morpho-bundles

Opinionated bundle contracts wrapping Morpho protocols.
Each bundle exposes a small set of high-level entry points that chain several protocol calls into a single transaction.
Entry-points are user-facing: they should be usable out of the box and are not meant to be called by other contracts.
Compared to bundler3, bundles are not modular, but are meant to reproduce its identified core functionalities with greater safety.
Notably, there is no crafting of bundles offchain, instead the way calls are chained is fixed and this can be audited.
Users are still expected to look at the inputs of the entry-points, to decide whether they want to sign it or not.
Bundles are not meant to hold token balances (including native tokens) between transactions.
Users should expect tokens left to the bundles as lost.

## Bundles

### Midnight bundles

[MidnightBundlesV1](src/midnight/MidnightBundlesV1.sol) contains:

- `midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral` — buy a target number of units across offers, then withdraw collateral.
- `midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral` — buy a target loan-asset amount across offers, then withdraw collateral.
- `midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget` — supply collateral, then sell a target number of units across offers.
- `midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget` — supply collateral, then sell a target loan-asset amount across offers.
- `midnightBundlesV1RepayAndWithdrawCollateral` — repay debt and withdraw collateral.

### Blue bundles

[BlueBundlesV1](src/blue/BlueBundlesV1.sol) contains:

- `blueBundlesV1SupplyCollateralAndBorrow` — supply collateral and borrow.
- `blueBundlesV1RepayAndWithdrawCollateral` — repay debt (optionally by shares) and optionally withdraw collateral.
- `blueBundlesV1Supply` — supply loan assets to a market.
- `blueBundlesV1Withdraw` — withdraw supplied loan assets (optionally by shares).
- `blueBundlesV1MigrateBorrowPosition` — move a full borrow position (collateral and debt) from one market to another.

The three entrypoints that consume market liquidity — `blueBundlesV1SupplyCollateralAndBorrow`, `blueBundlesV1Withdraw` and `blueBundlesV1MigrateBorrowPosition` — take a list of `PublicAllocations`.
Each allocation calls Vault V2's public allocator to move a vault's assets into its caller-selected destination (`PublicAllocations.marketParams`), from another of the vault's markets or from its idle assets.
The destination may differ from the market the bundle acts on, but its `loanToken` must match that market's loan token because all penalties are paid and flash loaned in the same token.
The bundle reads and validates the live penalty rates, calculates their exact per-allocation upward-rounded cost, and flash loans only the aggregate loan-token penalty from Blue. Penalties are deducted from borrow and withdrawal proceeds, and added to the destination debt of a borrow-position migration.
Each allocation includes a `maxPenalty`, which caps the live WAD-scaled penalty rate while accepting favorable decreases.
The flash loan temporarily reduces Blue's global token balance by the penalty: market-sourced allocations need their deallocation amount plus the penalty in global liquidity, and idle-sourced allocations still require Blue to fund the initial penalty flash loan.

### Vault bundles

[VaultBundlesV1](src/vault/VaultBundlesV1.sol) contains:

- `vaultBundlesV1Deposit` — deposit assets into a vault.
- `vaultBundlesV1Withdraw` — withdraw assets from a vault.
- `vaultBundlesV1Migrate` — migrate assets from one vault to another.

### Vault exit bundles

[VaultExitBundlesV1](src/vault-exit/VaultExitBundlesV1.sol) contains:

- `vaultExitBundlesV1InKindRedemptionVaultV1` — in-kind redeem from an illiquid Vault V1.
- `vaultExitBundlesV1InKindRedemptionVaultV2` — withdraw idle assets and redeem the remainder in kind from an illiquid Vault V2.
- `vaultExitBundlesV1ForceWithdrawVaultV2` — force withdraw from a liquid Vault V2.

## Audits

Audits can be found in the [audits](./audits/) folder.

## License

Files in this repository are publicly available under license `GPL-2.0-or-later`, see [`LICENSE`](./LICENSE).
