### Added

- `boris check` now reports advisory findings for valid-but-flat corpora —
  `flat_graph`, `unlinked_page`, `zero_includes`, and `zero_relations` — all
  informational (exit 0) unless a matching `--fail-on-*` flag opts in;
  corpus-level findings use the new `graph` endpoint type in the report. See
  the [Documentation Intelligence contract](/docs/contracts/documentation-intelligence.md)
  and the [CLI contract](/docs/contracts/cli.md).
