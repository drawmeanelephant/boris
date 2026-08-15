## 421: HTML-path machine-readable diagnostics report (`--report`)

`boris build --report PATH` and `boris validate --report PATH` now write a
deterministic JSON diagnostics report on both success and failure
(`html-build-report-0.1.0`, same diagnostic-object shape as the IR
`build-report.json`). It covers every HTML-path diagnostic class — parse/graph,
component, include, wiki-link, asset, link-audit (`EROUTE*`,
`EPUBLICATIONLOCATION`), and the new `ELAYOUT*` layout/theme family — with
stable codes, content-root-relative source paths, and line/column positions
where the failing phase has them. Layout failures that previously surfaced only
as bare `error:` text (`LayoutDuplicateMarker`, invalid asset urls, rule/globe
selection failures, invalid layout paths) are now structured too. The surface
is additive: stderr text, exit codes, and artifact bytes are unchanged with or
without `--report`, and `--report` stays rejected on `watch` and on non-HTML
modes. Schema twin: `docs/contracts/schemas/html-build-report-0.1.0.schema.json`.
