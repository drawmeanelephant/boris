<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Fixed

- Input-family mismatch diagnostics now blame the offending family: a
  `.cook`-only tree built without `--cooklang` reports `ECOOKLANG` with a
  `--cooklang` remediation instead of pointing at Textile, symmetrically for
  `.textile`. See [the scanner contract](/docs/contracts/scanner.md) and
  [#744](https://github.com/drawmeanelephant/boris/issues/744).
