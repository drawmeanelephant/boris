### Added

- Unchanged incremental builds now reuse the committed publication-evidence
  reports under a strict digest gate instead of re-deriving them, and
  `--refresh-evidence` forces full re-derivation on demand. The reuse gate
  now also pins the compiler identity (`compiler_id`), so an upgraded binary
  automatically rejects stale evidence from a prior version. See
  [publication-checks](/docs/contracts/publication-checks.md#incremental-evidence-reuse)
  and [#728](https://github.com/drawmeanelephant/boris/issues/728).
