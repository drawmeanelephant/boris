<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Fixed

- `boris check` no longer reports `unreferenced_page` for pages consumed
  through `{{include}}` composition; an incoming include edge now counts as
  inbound use. Contract vocabulary and acceptance fixtures updated in
  [documentation-intelligence](/docs/contracts/documentation-intelligence.md)
  ([#739](https://github.com/drawmeanelephant/boris/issues/739)).
