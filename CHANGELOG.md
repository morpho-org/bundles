# Changelog

## Changes

### MidnightBundlesV1 → [MidnightBundlesV2](https://github.com/morpho-org/bundles/blob/main/src/midnight/MidnightBundlesV2.sol)

Maker side:

- Add `midnightBundlesV2CancelAndMake`, which lets a maker update their offers in one transaction (batch cancel, lend limit with callback, borrow limit, sell including multi market offers, and buy). In order, it:
  - cancels the given offer groups, reverting if a group was consumed beyond the given maximum, which avoids reposting oversized offers if fills happen before the cancellation.
  - optionally supplies collateral to Midnight.
  - optionally supplies loan assets to a Blue market on behalf of the maker's `BlueBuyCallback` (created if needed), so that buy offers using this callback are funded from Blue.
  - if a new root is given: authorizes the ratifier on the maker's Midnight account, ratifies the root on the ratifier (directly or with a signature), and publishes the offers' payload to the log contract.
- The bundle does not check that the root, the payload, the funding and the collateral are consistent with each other, nor that previous offers are cancelled when reposting.

Taker side:

- Sell functions now first withdraw as much as possible, before taking offers for the remaining target.
- Buy functions can now repay what's left after taking offers. Buy functions can also target the current debt of the caller, which allows exiting a borrow position fully.
- `midnightBundlesV1RepayAndWithdrawCollateral` is removed in favor of the buy functions with repayment enabled and no offers. Repay fully with the units target set to `type(uint256).max`; repaying a given amount of assets is still possible with the assets target.
- Collateral withdrawals can withdraw the full collateral balance by passing `type(uint256).max`.
- The maximum continuous fee check is removed from sell functions.
- Takes on reduce-only offers are capped by the maker's position, and sell functions cap takes by the funding bound `buyerAssetsBound` of the offer's callback.
- Functions take an explicit `market` parameter, instead of the one of the first offer.

All functions:

- Operations always apply to `msg.sender`.
- Permit and Permit2 are removed: approvals must be given in a separate transaction.
- Native tokens are accepted: they are wrapped and sent to `msg.sender` before the token pulls.
- All functions now take a `deadline` parameter.

## Source code

| Contract                       | Source code                                                                                                                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| BlueBundlesV1                  | [BlueBundlesV1@main](https://github.com/morpho-org/bundles/blob/main/src/blue/BlueBundlesV1.sol)                                                                                     |
| MidnightBundlesV1 [deprecated] | [MidnightBundlesV1@068d625de4623a522b25196928fc4b053a953141](https://github.com/morpho-org/bundles/blob/068d625de4623a522b25196928fc4b053a953141/src/midnight/MidnightBundlesV1.sol) |
| MidnightBundlesV2              | [MidnightBundlesV2@main](https://github.com/morpho-org/bundles/blob/main/src/midnight/MidnightBundlesV2.sol)                                                                         |
| VaultBundlesV1                 | [VaultBundlesV1@main](https://github.com/morpho-org/bundles/blob/main/src/vault/VaultBundlesV1.sol)                                                                                  |
| VaultExitBundlesV1             | [VaultExitBundlesV1@main](https://github.com/morpho-org/bundles/blob/main/src/vault-exit/VaultExitBundlesV1.sol)                                                                     |
