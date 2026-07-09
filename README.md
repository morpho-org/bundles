# morpho-bundles

Opinionated bundle contracts wrapping Morpho protocols.

- `MidnightBundlesV1` — opinionated entries for the Midnight fixed-rate lending protocol.
- `BlueBundlesV1` — opinionated entries for Morpho Blue: `blueBundlesV1SupplyCollateralAndBorrow`, `blueBundlesV1RepayAndWithdrawCollateral`.

Shared token helpers (Permit2/ERC-2612 dispatch, USDT-safe max approval) live in `src/libraries/TokenLib.sol`.
