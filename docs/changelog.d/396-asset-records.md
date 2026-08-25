### Added

- `_boris/proof/artifacts.json` records now carry pixel `dimensions`
  (`{width, height}`, parsed from image headers where determinable) and an
  explicit `semantics` value (`static` for theme-owned assets,
  `content-reference` for content-local `.assets/` trees, `null` for
  non-asset records), documented in the
  [publication artifact inventory contract](/docs/contracts/publication-artifacts.md).
  The keys are optional-on-parse, so inventories written before them still
  round-trip unchanged.
