<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- `boris-recipe-scale` view 0.2.0 marks every timer entry
  `"scaling": "locked"`, so an unchanged scalable timer amount is a visible,
  self-describing policy (cooking time does not scale with yield) instead of
  reading as a bug. Contract and goldens updated in
  [cooklang-compatibility](/docs/contracts/cooklang-compatibility.md)
  ([#743](https://github.com/drawmeanelephant/boris/issues/743)).
