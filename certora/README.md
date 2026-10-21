This folder contains the verification of the bundle contracts using CVL, Certora's Verification Language.

Each spec verifies a bundler against its underlying protocol; see the repository [`README`](../README.md) and the individual bundler sources under [`src/`](../src) for the contracts themselves.

# Verified properties

## No third party pull

The `*NoThirdPartyPull` specs prove that no bundler entrypoint pulls tokens or shares from, or acts in the underlying protocol for, an account other than `msg.sender`.
