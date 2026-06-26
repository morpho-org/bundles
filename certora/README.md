This folder contains the verification of the bundle contracts using CVL, Certora's Verification Language.

Each spec verifies a bundler against its underlying protocol; see the repository [`README`](../README.md) and the individual bundler sources under [`src/`](../src) for the contracts themselves.

# Verified properties

- [`BundlerRepayInvertibility.spec`](specs/BundlerRepayInvertibility.spec) checks the bundler's repay formula.
  `midnightBundlesV1RepayAndWithdrawCollateralRepaysTargetUnits` proves the end-to-end property: calling `midnightBundlesV1RepayAndWithdrawCollateral` with `assets = floor(U * WAD / (WAD - pct))` decreases the on-chain debt by exactly `U`.
