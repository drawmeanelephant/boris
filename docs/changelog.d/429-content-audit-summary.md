### Fixed

- `boris-content-audit`'s terminal summary now lists exactly the report
  files emitted for the selected `--format`, instead of always claiming
  `report.json`, `REPORT.md`, and `site/` (a `--format=json` run no
  longer overclaims the Markdown and HTML outputs).
