<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- Unknown layout markers now fail with a dedicated `ELAYOUTUNKNOWNMARKER`
  diagnostic whose remediation enumerates the full closed marker set (eleven
  slots plus `{{asset-url PATH}}`) and states the once-per-layout rule.
  Contract table updated in
  [diagnostics](/docs/contracts/diagnostics.md)
  ([#737](https://github.com/drawmeanelephant/boris/issues/737)).
