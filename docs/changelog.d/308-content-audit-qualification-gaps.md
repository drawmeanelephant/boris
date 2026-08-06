<!--
Filename: 308-content-audit-qualification-gaps.md (pr-number is the real PR number)
Keep exactly one category heading.
-->

### Fixed

- [`boris-content-audit`](/tools/content-audit/) closes qualification-contract
  gaps found by independent black-box testing and Filed dogfooding: the output
  path is canonicalized and inspected for symlink components identically for
  absolute and relative `--root`/`--out` combinations; poetry-mode policies now
  require `eligible_collections` and `poetry_collections` as populated object
  fields (explicit empty objects remain valid); a closing fence line with
  trailing text no longer closes a fenced block; unregistered poetry shapes
  report one malformed/unsupported record consistently across per-record rows,
  verse totals, alignment, exceptions, and the Markdown/HTML reports; the
  reproduction command renders `--root=<project-root>`, `--policy=<policy-file>`,
  and `--out=<output-dir>` placeholders so no absolute host path is emitted;
  `--collection` filters are canonicalized (deduped, sorted) so reversed
  argument order is byte-identical; and the terminal summary reports the same
  scoped source/poetry totals as `report.json`.
