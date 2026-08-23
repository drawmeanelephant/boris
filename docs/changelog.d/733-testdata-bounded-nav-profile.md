### Added

- `boris-testdata` gains a `bounded-nav-v1` profile (and an optional `"nav"`
  profile field) whose generated theme bounds per-page navigation to breadcrumb
  plus direct children, keeping scale-corpus anchors and memory flat as page
  count grows. See the [testdata generator](/tools/testdata-generator/README.md)
  and [#729](https://github.com/drawmeanelephant/boris/issues/729).
