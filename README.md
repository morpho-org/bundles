# Morpho Bundles

Opinionated bundles to interact with the Morpho protocols.
Each entry-point execute a chain of calls, enabling to do multiple interactions in a single transaction.
Bundles have other benefits as well: being able to do atomic checks, being able to receive callbacks (e.g. to use flashloans), and simplifying calldata verification.
Entry-points are end-user-facing: they should be usable out of the box and are not meant to be called by other contracts.

Bundles are not meant to hold token balances (including native tokens) between transactions.
Users should expect tokens left to the bundles as lost.

## Bundles

### [MidnightBundlesV1](src/midnight/MidnightBundlesV1.sol)
- `midnightBundlesV1BuyWithUnitsTargetAndWithdrawCollateral` — buy a target number of units across offers, then withdraw collateral.
- `midnightBundlesV1BuyWithAssetsTargetAndWithdrawCollateral` — buy a target loan-asset amount across offers, then withdraw collateral.
- `midnightBundlesV1SupplyCollateralAndSellWithUnitsTarget` — supply collateral, then sell a target number of units across offers.
- `midnightBundlesV1SupplyCollateralAndSellWithAssetsTarget` — supply collateral, then sell a target loan-asset amount across offers.
- `midnightBundlesV1RepayAndWithdrawCollateral` — repay debt and withdraw collateral.

### [MidnightBundlesV2](src/midnight/MidnightBundlesV2.sol)
- `midnightBundlesV2Make` — optionally park loan assets on Blue through a Midnight `BlueBuyCallback`, supply collateral on Midnight, cancel a group, and publish new maker offers in one call.
- `midnightBundlesV2Cancel` — cancel a list of groups for the caller on Midnight.

Set `assetsToPark` to zero to skip parking and pass an empty `collateralSupplies` array to skip collateral supply. Pass a non-zero `newRoot` to authorize the Setter ratifier, activate the root, and publish `payload`. Passing `bytes32(0)` skips those steps and ignores `payload`. Cancellation-only calls skip both funding steps and pass `bytes32(0)` as `newRoot`.

Reposting cancels selected groups before activating the new Setter root and publishing its payload. Group cancellation applies to offers using any ratifier and is permanent; existing roots remain unchanged. Replacement offers must use fresh group IDs when their predecessors' groups are cancelled.

New roots made through `MidnightBundlesV2` are expected to use its `SETTER_RATIFIER`. Offer roots may contain multi-market offers. Roots and publication payloads are constructed offchain and are not checked against each other, against `SETTER_RATIFIER`, or against markets passed to the bundle.

The maker must authorize `MidnightBundlesV2` on Midnight and approve it to pull any supplied loan or collateral assets. The bundle does not support token permits.

### [BlueBundlesV1](src/blue/BlueBundlesV1.sol)
- `blueBundlesV1SupplyCollateralAndBorrow` — supply collateral and borrow.
- `blueBundlesV1RepayAndWithdrawCollateral` — repay debt (optionally by shares) and withdraw collateral.
- `blueBundlesV1Supply` — supply loan assets to a market.
- `blueBundlesV1Withdraw` — withdraw supplied loan assets (optionally by shares).
- `blueBundlesV1MigrateBorrowPosition` — move a full borrow position (collateral and debt) from one market to another.

The three entrypoints that consume market liquidity (`blueBundlesV1SupplyCollateralAndBorrow`, `blueBundlesV1Withdraw`, and `blueBundlesV1MigrateBorrowPosition`) support VaultV2's BluePublicAllocator.

### [VaultBundlesV1](src/vault/VaultBundlesV1.sol)
- `vaultBundlesV1Deposit` — deposit assets into a vault.
- `vaultBundlesV1Withdraw` — withdraw assets from a vault.
- `vaultBundlesV1Migrate` — migrate assets from one vault to another.

### [VaultExitBundlesV1](src/vault-exit/VaultExitBundlesV1.sol)
- `vaultExitBundlesV1InKindRedemptionVaultV1` — in-kind redeem from an illiquid Vault V1.
- `vaultExitBundlesV1InKindRedemptionVaultV2` — withdraw idle assets and redeem the remainder in kind from an illiquid Vault V2.
- `vaultExitBundlesV1ForceWithdrawVaultV2` — force withdraw from a liquid Vault V2.

## Audits

Audits can be found in the [audits](./audits/) folder.

## License

Files in this repository are publicly available under license `GPL-2.0-or-later`, see [`LICENSE`](./LICENSE).
