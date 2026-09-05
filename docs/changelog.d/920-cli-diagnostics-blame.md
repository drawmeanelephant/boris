### Fixed

- CLI usage diagnostics name the offending option instead of misattributing it: duplicate `--layout-rule` selectors blame `--layout-rule` (#867), bad `--site-url` values blame `--site-url` (#880), `--site-url` without `--rss`/`--sitemap` and `--out` with `nostr plan` name their conflict pairs (#905). Session-family flags (`--did`, `--prune`, `--dist`, …) are now rejected outside `standard-site` instead of silently ignored (#872). The `--help` conflict list documents the new pairs ([cli](/docs/contracts/cli.md)).
