<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- `html-build-report` 0.2.0 adds an optional `proofPack` section to
  `--report PATH`: when the build committed target evidence, the report
  mirrors per-check verdicts (`allPassed`, `checks[]`) from
  `_boris/proof/checks.json`, so CI sees check failures in the same file it
  already parses. Contract updated in
  [diagnostics](/docs/contracts/diagnostics.md); schema:
  [schemas/html-build-report-0.2.0.schema.json](/docs/contracts/schemas/html-build-report-0.2.0.schema.json)
  ([#741](https://github.com/drawmeanelephant/boris/issues/741)).
