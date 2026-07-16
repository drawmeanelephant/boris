# Documentation Intelligence (planned)

**Status:** design contract; not implemented by the default CLI.

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
- **satellite** — a valid page with a Trunk parent.
- **unreferenced** — no incoming `reference` edge from another page.
- **include-source** — a source dependency endpoint referenced by one or more
  pages or included sources.
- **unreachable** — reserved for a future explicit entry-point policy; the
  first slice must not emit this finding.

### Dependency health

The first slice reports facts already represented by the frozen graph:

- page count, root count, satellite count, and source endpoint count;
- incoming and outgoing edge counts by existing edge kind (`parent`, `include`,
  `reference`);
- unreferenced pages, excluding the page's own `parent` relationship;
- dependency fan-in hotspots using a declared threshold, not an arbitrary
  severity claim;
- transitive impact for a requested page or source endpoint.

No semantic relations (`relates_to`, `supersedes`, and similar) belong in this
contract. Those require a later frontmatter and IR design.

## JSON report

The initial report is a new analysis artifact, not an IR schema change. Its
arrays are sorted by canonical endpoint or entity id; no hash-map order may
enter output. It contains a format/schema/compiler header, input path, summary
counts, page/source records, stable findings, and an optional impact result.

Rules:

1. Counts and edge lists describe the validated graph, not filesystem guesses.
2. Findings use stable codes and severity only when a threshold or explicit
   policy justifies it.
3. `impact` is `null` for `check`; for `impact ID` it contains the normalized
   requested endpoint and sorted transitive dependents.
4. No timestamps, absolute paths, hostnames, random IDs, or generated prose
   enter the JSON report.
5. The report is deterministic for identical inputs on one host, matching the
   existing IR/RAG determinism claim.

## CLI and exit behavior

The eventual CLI surface is:

```text
boris check [--input DIR] [--format human|json] [--report PATH]
boris impact ID [--input DIR] [--format human|json] [--report PATH]
```

The exact option spelling remains provisional until implementation. Behavior:

- success with no findings: exit `0`;
- valid graph with policy findings: exit `1` when CI mode requests a failing
  health check, otherwise `0` for an informational report;
- invalid content or graph: existing content exit `1` and existing diagnostics;
- malformed command or ID: usage exit `2`;
- filesystem/system failure: existing I/O exit `3`.

The implementation must choose and document one default for “findings fail the
command” before shipping; CI behavior must not be implicit.

## Acceptance fixtures

The first fixture set must cover one root Trunk and two Satellites; an
unreferenced valid page; a shared include with fan-in; a multi-hop
include/reference impact chain; shuffled source creation order; invalid graph
cases proving analysis does not run on an unfrozen graph; requested page/source,
missing ID, invalid ID grammar; and empty/single-page sites.

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

