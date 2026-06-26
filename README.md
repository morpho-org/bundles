# morpho-bundles

Opinionated bundle contracts wrapping Morpho protocols.

- `MidnightBundlesV1` — opinionated entries for the Midnight fixed-rate lending protocol.
- `BlueBundlesV1` — opinionated entries for Morpho Blue: `blueBundlesV1SupplyCollateralAndBorrow`, `blueBundlesV1RepayAndWithdrawCollateral`.

Shared helpers (Permit2/ERC-2612 dispatch, USDT-safe max approval) live in `src/lib/BundlesUtils.sol`.
