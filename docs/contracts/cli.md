# Boris CLI contract

**Status:** normative command-routing contract for the v0.8 afterparty line.

Boris exposes four stable top-level commands. A missing command is equivalent to
`build` for backwards compatibility.

```text
boris build [build options]
boris check [--input DIR] [--format human|json] [--report PATH]
boris impact ID [--input DIR] [--format human|json] [--report PATH]
boris watch [build options]
```

## Commands

| Command | Purpose | Writes by default |
|---------|---------|-------------------|
| `build` | Compile the configured site or explicitly selected export | HTML `dist/`, or the selected `--out`, `--rag-dir`, `--context-dir`, `--llms`, or `--rss` path |
| `check` | Validate the frozen graph and emit a deterministic health report | Nothing unless `--report` is supplied |
| `impact ID` | Emit the transitive dependents of a page or source endpoint | Nothing unless `--report` is supplied |
| `watch` | Run an HTML build, then rebuild after debounced source/layout changes | HTML output selected by build options |

`watch` is the command spelling for local development. The existing
`build --watch` / bare `--watch` form remains accepted as a compatibility alias
and has identical behavior. Watch is HTML-only and implies incremental mode.

`check` and `impact` are read-only analysis commands. They do not create HTML,
IR, RAG, context, RSS, or cache artifacts. They require a valid frozen graph before
analysis runs.

## Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Successful build, watch shutdown, valid impact query, or check with no policy findings |
| `1` | Content/graph failure, or a `check` policy finding such as an unreferenced page |
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

## RSS mode

`--rss` and `--rss-path PATH` select the deterministic RSS-only projection.
It requires `--site-url`, `--rss-title`, and `--rss-description`; `--rss-limit`
is 1–500 (default 20). RSS is incompatible with every other build projection,
`check`, and `impact`. See the normative [RSS 2.0 contract](rss-2.0.md).

## HTML sitemap flags

`--sitemap` adds `sitemap.xml` to a single HTML target.
`--sitemap-path PATH` implies sitemap publication and selects another
target-root-relative file. Both require the reusable `--site-url` HTTP(S) base.
Sitemap flags are invalid with non-HTML projections, `check`, `impact`, or an
ambiguous multi-target configuration. `--site-url` without RSS or sitemap
selection is also a usage error. See the normative
[XML sitemap contract](xml-sitemap.md).

## Compatibility rule

Adding a flag or report field is additive only when it preserves existing
command routing, exit behavior, key order, and deterministic sorting. Changing
the meaning of a command, exit code, report field, or path policy requires an
amended contract and a versioned schema change.
