This folder contains the verification of the bundle contracts using CVL, Certora's Verification Language.

Each spec verifies a bundler against its underlying protocol; see the repository [`README`](../README.md) and the individual bundler sources under [`src/`](../src) for the contracts themselves.

# Verified properties

## No third party pull

The `*NoThirdPartyPull` specs prove that the Blue, Midnight and Vault bundlers only pull tokens from `msg.sender` (the Vault exit bundler pulls no tokens).
