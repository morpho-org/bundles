This folder contains the verification of the bundle contracts using CVL, Certora's Verification Language.

Each spec verifies a bundler against its underlying protocol; see the repository [`README`](../README.md) and the individual bundler sources under [`src/`](../src) for the contracts themselves.

# Verified properties

- [`BundlerRepayInvertibility.spec`](specs/BundlerRepayInvertibility.spec) checks the bundler's repay formula.
  `repayUnitsFormula` proves the pure arithmetic identity: for `assets = floor(D * WAD / (WAD - pct))`, the net units `assets - floor(assets * pct / WAD)` equal `D`.
  `repayAndWithdrawCollateralRepaysTargetUnits` proves the end-to-end property: calling `repayAndWithdrawCollateral` with those assets decreases the on-chain debt by exactly `U`.
