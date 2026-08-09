# Boris CLI contract

**Status:** normative command-routing contract for the v0.8 afterparty line.

Boris exposes six stable top-level commands. A missing command is equivalent to
`build` for backwards compatibility.

```text
boris build [build options]
boris validate [HTML source and target options]
boris check [--input DIR] [--format human|json] [--report PATH] [--fail-on-unreferenced]
boris impact ID [--input DIR] [--format human|json] [--report PATH]
boris watch [build options]
boris plan --profile PATH [plan overrides]
```

## Commands

| Command | Purpose | Writes by default |
|---------|---------|-------------------|
| `build` | Compile the configured site or explicitly selected export | HTML `dist/`, or the selected `--out`, `--rag-dir`, `--context-dir`, `--llms`, or `--rss` path |
| `validate` | Run the selected HTML input/configuration through the canonical prepublication compiler phases | Nothing |
| `check` | Validate the frozen graph and emit a deterministic health report | Nothing unless `--report` is supplied |
| `impact ID` | Emit the transitive dependents of a page or source endpoint | Nothing unless `--report` is supplied |
| `watch` | Run an HTML build, then rebuild after debounced source/layout changes | HTML output selected by build options |
| `plan` | Parse and normalize one publication profile without executing it | Nothing; normalized declaration JSON is written to stdout |

`watch` is the command spelling for local development. The existing
`build --watch` / bare `--watch` form remains accepted as a compatibility alias
and has identical behavior. Watch is HTML-only and implies incremental mode.

`validate`, `check`, and `impact` are read-only, but they are not aliases.
`validate` covers the selected HTML source/configuration through the shared
prepublication render boundary. `check` and `impact` operate on a valid frozen
graph and add Documentation Intelligence analysis rather than layout/theme/HTML
preflight. See the normative [validation contract](validation.md).

`validate` does not create HTML, IR, RAG, context, RSS, cache, search, or
publication-evidence artifacts. It accepts applicable existing HTML options,
including target/layout/theme and sitemap configuration, and rejects export
selectors, `--incremental`, `--watch`, `--jobs`, `--format`, and `--report`.
`check` and `impact` likewise create no product artifacts; only their explicit
`--report` path may be written.

## Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Successful build, validation, plan, watch shutdown, valid impact query, or check with no enabled policy failure |
| `1` | Content/graph failure, or an opted-in `check` policy finding such as an unreferenced page |
| `2` | Usage error: unknown command/flag, missing value, invalid ID, or conflicting mode |
| `3` | I/O or system failure |

The command parser must reject unknown positional arguments and conflicting
mode flags before touching the content tree. `--help` exits `0` without reading
content or writing artifacts.

## Machine-readable reports

Consumers should invoke:

```text
boris check --input CONTENT --format json --report REPORT.json
boris impact ID --input CONTENT --format json --report REPORT.json
```

`boris check` reports `unreferenced_page` findings without failing by default.
CI that treats those findings as fatal may add `--fail-on-unreferenced`; the
flag is rejected for other commands and does not change the report schema or
bytes.

These reports use the versioned `boris-documentation-intelligence` schema
defined in [`documentation-intelligence.md`](documentation-intelligence.md).
The report is deterministic for the same content bytes, relative paths,
compiler version, and host filesystem semantics. Arrays are sorted; it contains
no timestamps, hostnames, absolute source identities, or random IDs.

The existing compiler export remains a separate, richer artifact contract:
`build --out DIR` writes IR `manifest.json`, `graph.json`, and
`build-report.json` under the versioned [`ir-schema.md`](ir-schema.md) contract.
`build-report.json` is authoritative for compiler diagnostics and source
locations; `graph.json` is authoritative for frozen nodes and edges. Nova and
other editor integrations must consume these published contracts rather than
reimplementing frontmatter or graph resolution.

`validate` has no report artifact. It reuses canonical compiler diagnostics in
their normal deterministic stderr form and exit classes; `--quiet` suppresses
that text. `--format` and `--report` remain analysis-only flags and must not be
accepted as an invitation to invent a second validation schema.

## RSS mode

`--rss` and `--rss-path PATH` select the deterministic RSS-only projection.
It requires `--site-url`, `--rss-title`, and `--rss-description`; `--rss-limit`
is 1–500 (default 20). RSS is incompatible with every other build projection,
`validate`, `check`, and `impact`. See the normative
[RSS 2.0 contract](rss-2.0.md).

## HTML sitemap flags

`--sitemap` adds `sitemap.xml` to a single HTML target.
`--sitemap-path PATH` implies sitemap publication and selects another
target-root-relative file. Both require the reusable `--site-url` HTTP(S) base.
Sitemap flags are valid for `build` and `validate` on one selected HTML target.
They are invalid with non-HTML projections, `check`, `impact`, or an ambiguous
multi-target configuration. `--site-url` without RSS or sitemap selection is
also a usage error. Validation renders sitemap bytes in memory and discards
them; only `build` publishes the file. See the normative
[XML sitemap contract](xml-sitemap.md).

## Compatibility rule

Adding a flag or report field is additive only when it preserves existing
command routing, exit behavior, key order, and deterministic sorting. Changing
the meaning of a command, exit code, report field, or path policy requires an
amended contract and a versioned schema change.
