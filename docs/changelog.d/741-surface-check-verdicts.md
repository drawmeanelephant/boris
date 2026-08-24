<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- Failed publication checks now print a stderr warning naming the check, the
  target, and where the per-finding evidence lives
  (`_boris/proof/checks.json` `findings[]`), visible even under `--quiet`;
  a failing check still never fails the committed target by design. See
  [publication-checks](/docs/contracts/publication-checks.md)
  ([#740](https://github.com/drawmeanelephant/boris/issues/740),
  [#741](https://github.com/drawmeanelephant/boris/issues/741)).
