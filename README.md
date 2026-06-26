# morpho-bundles

Opinionated bundle contracts wrapping Morpho protocols.

- `MidnightBundles` — opinionated entries for the Midnight fixed-rate lending protocol.
- `BlueBundles` — opinionated entries for Morpho Blue: `blueBundlesSupplyCollateralAndBorrow`, `blueBundlesRepayAndWithdrawCollateral`.

Shared helpers (Permit2/ERC-2612 dispatch, USDT-safe max approval) live in `src/lib/BundlesUtils.sol`.
