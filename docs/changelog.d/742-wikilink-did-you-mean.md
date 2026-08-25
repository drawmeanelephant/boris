<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- `EREFERENCEMISSING` now appends a did-you-mean suggestion when a near-matching
  page entity id exists (for example, `[[nested/child]]` suggests
  `"deep/nested/child"`); suggestions are deterministic and never fire for
  unrelated targets. See [documentation-links](/docs/contracts/documentation-links.md)
  and [#742](https://github.com/drawmeanelephant/boris/issues/742).
