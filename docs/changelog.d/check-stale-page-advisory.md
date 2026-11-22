### Added

- `boris check` now supports deterministic age-based freshness advisories via
  the check-only `--as-of YYYY-MM-DD` and `--max-age-days N` options: pages
  whose frontmatter `published_at` UTC calendar date predates `--as-of` by
  strictly more than `N` days emit a `stale_page` finding (`count` set to age
  in UTC days), informational by default (exit 0) and promoted to exit 1 by
  `--fail-on-stale` without changing report bytes or schema `0.2.0`. When
  `--as-of` is omitted, no wall clock is read and output is byte-identical. See
  the [Documentation Intelligence contract](/docs/contracts/documentation-intelligence.md)
  and the [CLI contract](/docs/contracts/cli.md).
