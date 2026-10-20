### Fixed

- HTML `build`/`validate` now classify Cooklang refusals and the xhtml
  raw-HTML refusal as content errors (exit 1) instead of I/O failures
  (exit 3): `--report` records structured `ECOOKLANG` with the real
  `path:line:col` locus rather than a bare `EIO` fallback, the xhtml
  refusal names the refusing page via a new `EXHTML` code, and the
  zero-width `EUNICODE` advisory prints once on the HTML path as the
  contract requires. The Oliver pin advances to `af2233b` (oliver#205)
  so single-word Cooklang names stop at `~`, `~~` stays prose, and
  nested `{`/`(` inside closed quantity/preparation degrade to literal
  text (#1122, #1123, #1124). Links:
  [diagnostics.md](/docs/contracts/diagnostics.md),
  [oliver-renderer.md](/docs/contracts/oliver-renderer.md).
