# boris-content-audit

A standalone, deterministic, read-only source-content audit tool for Boris
content trees. The initial mode audits **poetry coverage** — verse presence,
canonical parent alignment, verse density, placeholders, and mapping exceptions.

The tool **observes and reports**. It never generates poetry, never modifies
source content, never creates agent assignments, never scaffolds placeholder
records, and never injects instructions into archive pages.

## Status and scope

- **Not part of publication.** Findings never alter Boris graph semantics.
  Reports are generated projections of the source tree at audit time.
- **Not wired into the root `zig build test` gate.** It builds and tests under
  its own `build.zig`. The root repo exposes aggregate commands, see below.
- **No dependency** on JavaScript, Node, Astro, Starlight, MDX, or any
  network. It parses a small bounded frontmatter grammar of its own.
- **Mode registry.** `--mode=poetry` is the only implemented mode. The CLI is
  designed so future audit modes can be registered, but none are implemented
  here.

## Build and test

From the Boris repository root:

```sh
zig build --build-file tools/content-audit/build.zig
zig build --build-file tools/content-audit/build.zig test
```

From inside `tools/content-audit/` the same commands work without the
`--build-file` flag. Root-level aggregate commands:

```sh
zig build content-audit          # build boris-content-audit
zig build test-content-audit     # run its unit + fixture tests
```

Run against a project:

```sh
zig build --build-file tools/content-audit/build.zig run -- \
  --mode=poetry \
  --root=/path/to/project \
  --content-root=content \
  --policy=/path/to/policy.json \
  --out=/tmp/poetry-audit
```

`--out` is **required**. The tool never writes into the source tree.

## CLI

```
boris-content-audit --mode=poetry --root=DIR --content-root=content --out=DIR [options]
```

| Flag | Meaning |
| --- | --- |
| `--mode=poetry` | Audit mode (registry; poetry is the initial mode). |
| `--root=DIR` | Project root (default `.`). Never mutated. |
| `--content-root=RELATIVE_DIR` | Content root relative to `--root` (default `content`). |
| `--out=DIR` | Output directory (required). Tool-owned, atomic, never inside the content root. |
| `--policy=FILE` | Optional versioned JSON policy defining editorial expectations. |
| `--previous-report=FILE` | Optional earlier `report.json` for delta comparison. |
| `--collection=NAME` | Repeatable filter restricting coverage/records. |
| `--format=json\|markdown\|html\|all` | Report formats to emit (default `all`). |
| `--quiet` | Suppress the summary line. |
| `--fail-on=none\|structural\|policy` | Failure class that makes exit code 1 (default `structural`). |
| `--revision=STRING` | Optional explicit source revision (never host-derived). |
| `--help` | Show help. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Audit completed and no selected failure class was triggered. |
| `1` | Findings selected by `--fail-on` were present. |
| `2` | Usage error. |
| `3` | I/O or output-ownership error. |
| `4` | Malformed source, policy, or previous-report contract. |

By default: missing poetry is a report finding, not a failure; placeholder
poetry is a finding, not a failure; density extremes are informational.
Duplicate IDs, impossible mappings, malformed frontmatter, and deterministic
output failures are **structural** failures.

## Policy file

A policy defines editorial expectations. The schema is versioned:

```json
{
  "schema_version": 1,
  "eligible_collections": {
    "lorelog": ["aphorism", "haiku", "limerick"],
    "mascots": ["aphorism", "haiku", "limerick"],
    "reference": ["aphorism", "haiku", "limerick"],
    "posts": ["aphorism", "haiku", "limerick"]
  },
  "poetry_collections": {
    "aphorisms": "aphorism",
    "haikus": "haiku",
    "limericks": "limerick"
  },
  "excluded_statuses": ["draft"],
  "excluded_ids": [],
  "placeholder": {
    "exact_lines": ["Awaiting context"],
    "title_prefixes": ["Stub:"],
    "case_sensitive": false
  },
  "density_bands": {
    "aphorism": [1, 5, 8],
    "haiku": [1, 3, 5],
    "limerick": [1, 5, 10]
  },
  "exact_mappings": {}
}
```

Field semantics:

- `eligible_collections` — source collections that must have poetry, and the
  poetry types each must carry.
- `poetry_collections` — directories whose records are poetry of the given type.
- `excluded_statuses` / `excluded_ids` — records excluded from coverage.
- `placeholder` — placeholder signatures: exact body lines and title prefixes.
  **Filed-specific placeholder language is not a universal Boris default**;
  this schema is a documented example. The policy is the only place such
  signatures live.
- `density_bands` — optional exact-count bands per type (replacing the old
  hardcoded "Cromulent Seven" presentation). The policy may label a band, but
  the engine stays generic.
- `exact_mappings` — policy-supplied exact mapping table keyed by canonical
  IDs (poetry id → source id).

`tools/content-audit/fixtures/policy.example.json` ships the example shape.

## Identity and mapping

One canonical index is built keyed by exact frontmatter `id`. Never used:
substring filename matching, punctuation-stripped fuzzy matching,
case-insensitive path aliasing, title similarity, numeric-prefix guessing, or
reverse relationships invented by the audit.

Poetry ownership is resolved only from explicit current-Boris graph evidence,
in this precedence order:

1. A poetry record whose canonical `parent` is a non-poetry source record.
   (A `parent` naming the record's own poetry collection, e.g. `parent: haikus`,
   is a collection grouping, not a graph edge.)
2. An explicit semantic relationship (`relations`) between a source record and
   a poetry record when direction and type are unambiguous.
3. A policy-supplied exact mapping (`exact_mappings`) keyed by canonical IDs.

When two evidence sources disagree, the record is classified as
`mapping_disagreement` — the audit does not pick a winner. One poetry record
must never silently map to multiple source records (`duplicate_mapping`).

### Alignment statuses

`mapped`, `orphan`, `ambiguous`, `dead_reference`, `mapping_disagreement`,
`duplicate_mapping`, `missing_target`, `malformed_record`.

The old Astro-era `isMascotMatch()` filename/token matcher is deliberately not
reproduced.

## Coverage model

For each eligible source record and each expected poetry type, the audit
classifies coverage as one of:

`missing`, `present_empty`, `present_placeholder`, `present_substantive`,
`ambiguous_mapping`, `malformed`.

Structural, substantive, and placeholder-only coverage are kept distinct — a
placeholder-shaped poem never produces the same green result as substantive
verse.

## Verse counting

See [`docs/poetry-shapes.md`](docs/poetry-shapes.md) for the written shape
contract and fixtures. Counting is by semantic verse units, never by raw MDX
component names: frontmatter is ignored, fenced code is ignored, collection
label headings are ignored, only complete non-empty units are counted,
malformed/partial units are classified separately, Unicode is preserved
exactly, and embedded HTML/directives are never executed.

## Reports

An atomically replaced, tool-owned output tree:

```
<out>/
├── .boris-content-audit-output   # ownership marker
├── report.json                   # canonical output
├── REPORT.md
└── site/
    ├── index.html
    ├── coverage.html
    ├── density.html
    ├── alignment.html
    ├── exceptions.html
    ├── changes.html
    └── audit.css
```

`report.json` is canonical. It includes: schema version, an explicit source
root label (never an absolute host path), policy digest, totals by source
collection and poetry type, structural/substantive/placeholder-only/missing
coverage, verse-unit totals, density statistics, every mapping with its
evidence, every exception, deterministic per-record results, and optional
comparison with a previous report.

Never emitted: absolute filesystem paths, host usernames, current timestamps,
nondeterministic map ordering, random IDs. A source revision string is
permitted only when supplied via `--revision`.

The HTML site is static — no JavaScript, no remote assets, no network
requests, accessible tables, links between pages, works from `file://` and
GitHub Pages. The report site is operational telemetry, not Boris content and
not archive canon.

## Delta mode

With `--previous-report`, the audit verifies schema and policy identity, then
reports: coverage-state changes, added/removed records, newly orphaned or
newly resolved poetry, verse-count changes, and placeholder-to-substantive
transitions. Reordered source files are not treated as changes.

## Safety and output ownership

The tool:

- refuses source/output overlap;
- refuses output paths inside the content root;
- refuses symlink traversal (both in discovery and for the content root);
- refuses replacing a non-empty unmarked output directory;
- stages output in a sibling temporary directory and publishes only an output
  containing the exact ownership marker;
- cleans temporary stages after failure and leaves the previous valid report
  intact;
- never mutates source files (tests hash source trees before and after).

## Determinism

Sorted path traversal, sorted canonical IDs, fixed JSON field ordering, stable
Markdown/HTML ordering, no host timestamps, no random temporary values in
final reports. A second execution produces byte-identical output — covered by
the `byte-identical second run` test.

## Consumer example

See [`docs/github-actions.md`](docs/github-actions.md) for a consumer-repo
workflow that runs the audit on pull requests, uploads the report artifact,
writes an executive summary to the step summary, publishes `site/` to GitHub
Pages from main, and never commits generated reports back into the content
repository.
