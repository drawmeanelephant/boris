# Documentation Intelligence

**Status:** first slice implemented and merged; normative for `check` /
`impact`. Semantic relations and Context Bundles are separate contracts with
their own shipped implementations.

Documentation Intelligence is a read-only analysis layer over Boris's already
validated, frozen content graph. It must not alter HTML output, IR 0.2 shape,
RAG output, frontmatter grammar, or incremental build semantics.

## Product boundary

The analysis pipeline is:

```text
discover → parse → validate/freeze → dependency resolution → analyze → report
```

Analysis runs only after the graph and dependency resolver succeed. A content
or graph failure returns the existing diagnostics and publishes no analysis
report. Analysis never repairs content, rewrites source files, follows network
links, or invents relationships.

The first slice is intentionally narrow:

- `boris check` — deterministic graph and dependency health report.
- `boris impact ID` — deterministic transitive dependents of one page/source.
- JSON output suitable for CI and a stable human-readable summary.

The commands are analysis commands, not another compiler mode. They must not
write `dist/`, `.boris/`, `rag/`, or cache manifests unless the user explicitly
selects a report path in a later, separately specified interface.

## Analysis vocabulary

### Reachability and entry points

The first release must not call every root Trunk an orphan. A root Trunk is a
valid page by definition. Until configurable entry points exist, the report
uses these precise categories:

- **root** — a valid Trunk with no `parent`.
- **satellite** — a valid page with a direct parent; that parent may itself be
  a Satellite.
- **unreferenced** — no incoming `reference` edge from another page and no
  incoming `include` edge naming it. Include composition is inbound use: a
  page consumed through `{{include}}` is never reported as unreferenced,
  because composition by other pages is real dependency even without a
  wiki-link.
- **include-source** — a source dependency endpoint referenced by one or more
  pages or included sources.
- **unreachable** — reserved for a future explicit entry-point policy; the
  first slice must not emit this finding.

### Advisory findings

Advisory findings describe a valid-but-flat corpus: legal content whose
missing structure is worth surfacing, not failing. They ride the same
findings array and sorting rules as `unreferenced_page` and are
informational unless a matching `--fail-on-*` flag opts into exit `1`
(#1023). The closed advisory code set:

- **flat_graph** — the corpus holds at least two pages and the frozen graph
  carries no `parent`, `include`, or `reference` edges at all. The finding's
  `count` is the page count.
- **unlinked_page** — a page with no incoming or outgoing edge of any kind
  and no `include` edge naming its source path. It is strictly stronger than
  `unreferenced_page`, which weighs only inbound use: a page that only links
  outward is unreferenced but not unlinked.
- **zero_includes** — a non-empty corpus with no `include` edges.
- **zero_relations** — a non-empty corpus with no `reference` edges.

Corpus-level advisories (`flat_graph`, `zero_includes`, `zero_relations`)
name the whole graph rather than a node: their finding endpoint is
`{"type": "graph", "value": "corpus"}` with `null` source location fields.
The `graph` endpoint type appears only in findings — never in `nodes`,
`edges`, `impact`, or `sourceLocations`. An empty corpus emits no advisory
findings.

### Dependency health

The first slice reports facts already represented by the frozen graph:

- page count, root count, satellite count, and source endpoint count;
- incoming and outgoing edge counts by existing edge kind (`parent`, `include`,
  `reference`);
- unreferenced pages, excluding the page's own `parent` relationship;
- advisory findings for valid-but-flat corpora (`unlinked_page`,
  `flat_graph`, `zero_includes`, `zero_relations`); see below;
- dependency fan-in hotspots using a declared threshold, not an arbitrary
  severity claim;
- transitive impact for a requested page or source endpoint.

No semantic relations (`relates_to`, `supersedes`, and similar) belong in this
contract. Those require a later frontmatter and IR design.

The machine-readable twin is [`schemas/documentation-intelligence-0.2.0.schema.json`](schemas/documentation-intelligence-0.2.0.schema.json).

## JSON report (schema 0.2.0)

The initial report is a new analysis artifact, not an IR schema change. Its
arrays are sorted by canonical endpoint or entity id; no hash-map order may
enter output. It contains a format/schema/compiler header, input path, summary
counts, page nodes, typed dependency edges, source locations, stable findings,
an optional impact result, and a diagnostics array. The `nodes` and `edges`
arrays are the consumer-facing graph projection; the older `pages` and
`sources` arrays remain as compatibility summaries. The summary carries
`edgeCounts`: incoming and outgoing edge counts by edge kind, split by
endpoint class (`pages`, `sources`), with zero-filled fixed keys for the
closed kind set. `sourceLocations` uses
content-relative paths and 1-based line/column values. Valid analysis reports
have an empty diagnostics array; invalid content returns the compiler's
deterministic `build-report.json` diagnostics contract instead of a partial
analysis report.

Rules:

1. Counts and edge lists describe the validated graph, not filesystem guesses.
2. Findings use stable codes and severity only when a threshold or explicit
   policy justifies it.
3. `impact` is `null` for `check`; for `impact ID` it contains the normalized
   requested endpoint and sorted transitive dependents.
4. Node, edge, finding, and source-location arrays use fixed key order and
   canonical sorting. Diagnostics use the shared diagnostic field contract.
5. No timestamps, absolute paths, hostnames, random IDs, or generated prose
   enter the JSON report.
6. The report is deterministic for identical inputs on one host, matching the
   existing IR/RAG determinism claim.

## CLI and exit behavior

The eventual CLI surface is:

```text
boris check [--input DIR] [--format human|json] [--report PATH]
            [--fail-on-unreferenced] [--fail-on-unlinked]
            [--fail-on-flat-graph] [--fail-on-zero-includes]
            [--fail-on-zero-relations]
boris impact ID [--input DIR] [--format human|json] [--report PATH]
```

The option spelling is implemented as shown above. Behavior:

- success with no findings: exit `0`;
- valid graph with policy findings: exit `1` when CI mode requests a failing
  health check, otherwise `0` for an informational report;
- invalid content or graph: existing content exit `1` and existing diagnostics;
- malformed command or ID: usage exit `2`;
- filesystem/system failure: existing I/O exit `3`.

The shipped first slice reports `unreferenced_page` findings and the advisory
findings above without failing by default. Each `--fail-on-*` flag opts into
exit `1` when one or more findings of its class are present:
`--fail-on-unreferenced` for `unreferenced_page`, `--fail-on-unlinked` for
`unlinked_page`, `--fail-on-flat-graph` for `flat_graph`,
`--fail-on-zero-includes` for `zero_includes`, and `--fail-on-zero-relations`
for `zero_relations`. The flags are check-only — `impact` and every other
command rejects them — and `impact` returns exit `0` when the requested page
or source endpoint exists and the graph is valid. Parse, graph, and I/O
failures retain their existing exit classes. The report schema and bytes do
not depend on these policies.

## Acceptance fixtures

The first fixture set must cover one root Trunk and two Satellites; an
unreferenced valid page; a shared include with fan-in; an include-consumed
page outside the reserved `includes/` library that must not be flagged
unreferenced; a multi-hop
include/reference impact chain; shuffled source creation order; invalid graph
cases proving analysis does not run on an unfrozen graph; requested page/source,
missing ID, invalid ID grammar; a flat multi-page corpus (no `parent`,
`include`, or `reference` edges) covering every advisory finding and each
`--fail-on-*` opt-in; and empty/single-page sites.

Acceptance requires fixture goldens for JSON and human summaries, plus proof
that `check` and `impact` do not modify HTML, IR, RAG, or cache outputs.

## Deliberate non-goals

- semantic author relations or ownership/lifecycle frontmatter;
- automatic source rewriting or “fix” commands;
- network link checking;
- layout/theme analysis;
- content-quality judgments based on an LLM;
- IR 0.2 schema changes;
- a generic plugin or scripting system.
