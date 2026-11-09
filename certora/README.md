This folder contains the verification of the bundle contracts using CVL, Certora's Verification Language.

Each spec verifies a bundler against its underlying protocol; see the repository [`README`](../README.md) and the individual bundler sources under [`src/`](../src) for the contracts themselves.

# Verified properties

## No third party pull

`NoThirdPartyPull` proves that each bundler only pulls tokens from, and only withdraws or redeems ERC-4626 shares of, `msg.sender`. `MidnightNoThirdPartyPull` extends it to the take and repay callbacks of Midnight, and `VaultExitNoThirdPartyPull` checks the Blue callbacks through the entrypoints that trigger them.
