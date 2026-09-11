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

- `midnightBundlesV2CancelAndMake` — optionally park loan assets on Blue through a Midnight `BlueBuyCallback`, supply collateral on Midnight, cancel a group, and publish new maker offers in one call.

Pass an empty `groupsToCancel` array to skip cancellation. Set `assetsToPark` to zero to skip parking and pass an empty `collateralSupplies` array to skip collateral supply.
Pass a non-zero `newRoot` to authorize the Setter ratifier, activate the root, and publish `payload`. Passing `bytes32(0)` skips those steps and ignores `payload`.
Cancellation-only calls skip both funding steps and pass `bytes32(0)` as `newRoot`.

Reposting cancels selected groups before activating the new Setter root and publishing its payload.
Group cancellation applies to offers using any ratifier and is permanent; existing roots remain unchanged.
Replacement offers must use fresh group IDs when their predecessors' groups are cancelled.

New roots made through `midnightBundlesV2CancelAndMake` are expected to use its `SETTER_RATIFIER`.
Offer roots may contain multi-market offers.
Roots and publication payloads are constructed offchain and are not checked against each other, against `SETTER_RATIFIER`, or against markets passed to the bundle.

The maker must authorize `MidnightBundlesV2` on Midnight and approve it to pull any supplied loan or collateral assets.

Taker-side:

- `midnightBundlesV2BuyWithUnitsTargetAndWithdrawCollateral` — buy a target number of units across offers and, repay debt if `repayEnabled` and target is not reached, then withdraw collateral.
- `midnightBundlesV2BuyWithAssetsTargetAndWithdrawCollateral` — buy a target loan-asset amount across offers and, repay debt if `repayEnabled` and target is not reached, then withdraw collateral.
- `midnightBundlesV2SupplyCollateralAndSellWithUnitsTarget` — supply collateral, then sell a target number of units, filling it first by withdrawing credit and then across offers.
- `midnightBundlesV2SupplyCollateralAndSellWithAssetsTarget` — supply collateral, then sell a target loan-asset amount, filling it first by withdrawing credit and then across offers.

Repaying and withdrawing collateral (only) is done through the buy functions with `repayEnabled`, a nonzero target and an empty `offerFills` array.
Withdrawing credit (only) can be done through the sell functions with a nonzero target and an empty `offerFills` array.

The taker (or msg.sender if authorized by the taker) must be authorized by the taker on Midnight for these functions, and the bundle must have an allowance to pull the tokens it needs from msg.sender.

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
