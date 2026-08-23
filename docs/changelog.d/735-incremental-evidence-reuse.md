### Added

- Unchanged incremental builds now reuse the committed publication-evidence
  reports under a strict digest gate instead of re-deriving them, and
  `--refresh-evidence` forces full re-derivation on demand. See
  [publication-checks](/docs/contracts/publication-checks.md#incremental-evidence-reuse)
  and [#728](https://github.com/drawmeanelephant/boris/issues/728).
