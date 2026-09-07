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

[MidnightBundlesV2](src/midnight/MidnightBundlesV2.sol) is a standalone bundle containing:

- `midnightBundlesV2LendLimitWithBlueBuyCallback` — park loan assets on Blue through a Midnight `BlueBuyCallback`, then repost maker offers.
- `midnightBundlesV2BorrowLimit` — supply collateral on Midnight, then repost maker offers.
- `midnightBundlesV2Repost` — repost maker offers without moving assets.

Reposting deactivates selected roots and cancels selected groups before activating the new Setter-ratified root. Root deactivation is reversible, whereas group cancellation is not. Replacement offers must use fresh group IDs when their predecessors' groups are cancelled.

Offer roots may contain multi-market offers. Roots and publication payloads are constructed offchain and are not checked against each other or against markets passed to the bundle.

The maker must authorize `MidnightBundlesV2` on Midnight and approve it to pull any supplied loan or collateral assets. The PoC does not support token permits.

### Blue bundles

[BlueBundlesV1](src/blue/BlueBundlesV1.sol) contains:

- `blueBundlesV1SupplyCollateralAndBorrow` — supply collateral and borrow.
- `blueBundlesV1RepayAndWithdrawCollateral` — repay debt (optionally by shares) and withdraw collateral.
- `blueBundlesV1Supply` — supply loan assets to a market.
- `blueBundlesV1Withdraw` — withdraw supplied loan assets (optionally by shares).
- `blueBundlesV1MigrateBorrowPosition` — move a full borrow position (collateral and debt) from one market to another.

The three entrypoints that consume market liquidity (`blueBundlesV1SupplyCollateralAndBorrow`, `blueBundlesV1Withdraw`, and `blueBundlesV1MigrateBorrowPosition`) support VaultV2's BluePublicAllocator.

`blueBundlesV1SupplyCollateralAndBorrow` allows supplying collateral without borrowing and borrowing without supplying collateral.
`blueBundlesV1RepayAndWithdrawCollateral` allows withdrawing collateral without repaying and repaying without withdrawing collateral.

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
