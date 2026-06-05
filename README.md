# morpho-bundles

Opinionated bundle contracts wrapping Morpho-stack protocols. Each protocol has its own bundle contract; cross-protocol composition is done via the generic `BundlerV3` multicall.

- `MidnightBundles` — opinionated entries for the Midnight fixed-rate lending protocol.
- `BlueBundles` — opinionated entries for Morpho Blue: `supplyCollateralAndBorrow`, `repayAndWithdrawCollateral`.

Shared helpers (Permit2/ERC-2612 dispatch, USDT-safe max approval) live in `src/lib/BundlesUtils.sol`.
