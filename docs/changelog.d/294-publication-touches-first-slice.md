### Added

- Boris now derives and atomically replaces a deterministic target-local
  `touches.json` Touch Atlas after the claims report commits. The atlas is a
  relationship index over the exact committed bytes of `artifacts.json`,
  `checks.json`, and `claims.json` only: it connects targets to inventory
  artifacts, artifacts to check subjects and supporting inputs, checks to
  findings and claims, and claims to limitations. A malformed or stale
  upstream report prevents a new atlas, and a failure preserves any prior
  report and emits the committed-target diagnostic even under `--quiet`.
  Links:
  [publication Touch Atlas contract](/docs/contracts/publication-touches.md).
- Publication Touch Atlas status moved from "contract drafted, implementation
  not yet shipped" to "implemented first slice". The contract's documented
  non-claims (source provenance, runtime transformation traces, deployment
  graphs, accessibility/prose inference, proof-pack presentation, and repair
  actions) remain explicitly out of scope. Links:
  [STATUS](/docs/STATUS.md).
