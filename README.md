# morpho-bundles

Opinionated bundle contracts wrapping Morpho protocols.
Each bundle exposes a small set of high-level entry points that chain several protocol calls into a single transaction.
Entry-points are user-facing: they should be usable out of the box and are not meant to be called by other contracts.
Compared to bundler3, bundles are not modular, but are meant to reproduce its identified core functionalities with greater safety.
Notably, there is no crafting of bundles offchain, instead the way calls are chained is fixed and this can be audited.
Users are still expected to look at the inputs of the entry-points, to decide whether they want to sign it or not.

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

### Vault bundles

[VaultBundlesV1](src/vault/VaultBundlesV1.sol) contains:

- `vaultBundlesV1Deposit` — deposit assets into a vault.
- `vaultBundlesV1Withdraw` — withdraw assets from a vault.
- `vaultBundlesV1Migrate` — migrate assets from one vault to another.

### Midnight-to-Blue bundles

[MidnightToBlueBundlesV1](src/midnight-to-blue/MidnightToBlueBundlesV1.sol) contains:

- `midnightToBlueBundlesV1MigrateBorrowPosition` — migrate a full borrow position (debt + one collateral) from a Midnight fixed-rate market to a Morpho Blue variable-rate market in one transaction. No flash loan: the destination Blue borrow is taken inside Midnight's `onRepay` callback and funds the Midnight repay.

### Vault exit bundles

[VaultExitBundlesV1](src/vault-exit/VaultExitBundlesV1.sol) contains:

- `vaultExitBundlesV1InKindRedemptionVaultV1` — in-kind redeem from an illiquid Vault V1.
- `vaultExitBundlesV1InKindRedemptionVaultV2` — in-kind redeem from an illiquid Vault V2.
- `vaultExitBundlesV1ForceWithdrawVaultV2` — force withdraw from a liquid Vault V2.

## Audits

Audits can be found in the [audits](./audits/) folder.

## License

Files in this repository are publicly available under license `GPL-2.0-or-later`, see [`LICENSE`](./LICENSE).
