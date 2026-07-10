# morpho-bundles

Opinionated bundle contracts wrapping Morpho protocols.
Each bundle exposes a small set of high-level entry points that chain several protocol calls into a single transaction.

## Midnight bundles

[MidnightBundlesV1](src/midnight/MidnightBundlesV1.sol) contains:

- `midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral` — buy a target number of units across offers, then withdraw collateral.
- `midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral` — buy a target loan-asset amount across offers, then withdraw collateral.
- `midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget` — supply collateral, then sell a target number of units across offers.
- `midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget` — supply collateral, then sell a target loan-asset amount across offers.
- `midnightBundlesV1RepayAndWithdrawCollateral` — repay debt and withdraw collateral.

## Blue bundles

[BlueBundlesV1](src/blue/BlueBundlesV1.sol) contains:

- `blueBundlesV1SupplyCollateralAndBorrow` — supply collateral and borrow.
- `blueBundlesV1RepayAndWithdrawCollateral` — repay debt (optionally by shares) and optionally withdraw collateral.
- `blueBundlesV1Supply` — supply loan assets to a market.
- `blueBundlesV1Withdraw` — withdraw supplied loan assets (optionally by shares).
- `blueBundlesV1MigrateBorrowPosition` — move a full borrow position (collateral and debt) from one market to another.

## Vault force withdraw bundles

[VaultForceWithdrawBundlesV1](src/vault-force-withdraw/VaultForceWithdrawBundlesV1.sol) contains:

- `vaultBundlesV1ForceWithdrawIlliquidVaultV1` — force withdraw from an illiquid Morpho Vault V1.
- `vaultBundlesV1ForceWithdrawIlliquidVaultV2` — force withdraw from an illiquid Morpho Vault V2.
- `vaultBundlesV1ForceWithdrawLiquidVaultV2` — force withdraw from a liquid Morpho Vault V2.
