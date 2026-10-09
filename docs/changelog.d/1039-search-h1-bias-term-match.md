### Fixed

- Gated the shipped search UI's `h1` section-score bias on an actual term
  match in all three themes (`boris`, `lab`, `corporate` under
  [themes/](/themes/)) and the `boris init` starter layout
  ([main.html](/src/init_templates/layouts/main.html)): a non-empty query that
  matches no term now reports "No results." instead of returning every document
  with an `h1` ([#1037](https://github.com/drawmeanelephant/boris/issues/1037)).
  Consumer rules: [rendered-search](/docs/contracts/rendered-search.md).
