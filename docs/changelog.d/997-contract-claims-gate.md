<!--
Filename: 907-contract-claims-gate.md
-->

### Added

- A **contract-claim gate** makes the load-bearing rules in `docs/contracts/`
  executable. `test/contract-claims.txt` records a verbatim quote from a
  contract together with a black-box check against the built binary, and
  `scripts/test-contract-claims.sh` (also `zig build test-contract-claims`)
  fails when the implementation does not honor a claim, when the quoted
  contract prose drifts out from under its check, or when a recorded known
  divergence vanishes without the record being reclassified. It runs on every
  `zig build test`; `--audit` lists contracts whose rules still have no quoted
  tether. Ships with six records, including the open Cooklang
  `{`-adjacency divergence. Links:
  [the Cooklang adapter contract](/docs/contracts/cooklang-compatibility.md),
  [the diagnostics contract](/docs/contracts/diagnostics.md),
  [the harness README](/test/README.md),
  [#907](https://github.com/drawmeanelephant/boris/issues/907).
