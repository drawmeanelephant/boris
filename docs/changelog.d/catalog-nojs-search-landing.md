### Fixed

- The `blueprint`, `corporate`, and `lab` catalog themes now ship a themed
  `assets/search.html` landing page, and their no-JavaScript search forms
  submit there instead of the missing `_boris/search/` route — the same
  fallback the default `boris` theme gained in #1187. Links:
  [the rendered-search contract](/docs/contracts/rendered-search.md),
  [#1188](https://github.com/drawmeanelephant/boris/issues/1188).
