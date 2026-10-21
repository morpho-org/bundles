This folder contains the verification of the bundle contracts using CVL, Certora's Verification Language.

Each spec verifies a bundler against its underlying protocol; see the repository [`README`](../README.md) and the individual bundler sources under [`src/`](../src) for the contracts themselves.

# Verified properties

## No third party pull

For each bundler, [`BlueNoThirdPartyPull`](specs/BlueNoThirdPartyPull.spec), [`MidnightNoThirdPartyPull`](specs/MidnightNoThirdPartyPull.spec), [`VaultNoThirdPartyPull`](specs/VaultNoThirdPartyPull.spec) and [`VaultExitNoThirdPartyPull`](specs/VaultExitNoThirdPartyPull.spec) prove that no entrypoint can use the funds of an account other than `msg.sender`.
Concretely, every account the bundler pulls tokens or vault shares from, and every account the bundler acts for in the underlying protocol (Blue withdrawals, borrows and authorizations, Midnight takes, withdrawals and consumption, ratifications, Vault V2 force deallocations) is `msg.sender`.
For Midnight, it is also proven that the bundler never passes a callback that Midnight would pull tokens from.

The Blue callbacks are proven to revert unless called by Blue, and are otherwise verified through the entrypoints that trigger them, assuming that Blue only calls back the caller of `flashLoan`, `repay` and `supply`.
Each spec also checks that its pull summaries are reached, so that a pull escaping the summaries would not go unnoticed for the bundler's main pulling entrypoint.
