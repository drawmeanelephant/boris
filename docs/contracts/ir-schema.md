# Intermediate representation (IR) schema (v0.2)

**Status:** normative Feature 8 contract — F8.1–F8.3 implemented
**Target product / compiler id:** `0.5.0` / `boris/0.5.0`
**schemaVersion:** `0.2.0`

IR is explicit (`--out DIR` / `--no-rag`) and deterministic. Bare `boris`
continues to emit HTML under `dist/`; this schema does not change CLI mode
selection.

The v0.5.0 compiler emits this unchanged dependency shape with
`schemaVersion: "0.2.0"` and compiler id `boris/0.5.0`.

---

## Artifacts

On a **successful** compile (`ok: true`), Boris publishes three files under the
output directory (CLI default `.boris/`):

```text
.boris/
  manifest.json       # required — page summaries
  graph.json          # required — frozen nodes + dependency edges + reverse index + nav
  build-report.json   # required — ok flag, errorCount, diagnostics
```

On **content validation failure** (`ok: false`):

- `build-report.json` is written with `ok: false` and diagnostics
- **Graph-dependent** artifacts (`manifest.json`, `graph.json`) are **not**
  published; any prior copies under the out directory are removed
- The process exits **1**

On **I/O/system failure** (exit **3**), files may be missing or partial;
`build-report.json` may still be written when the failure is detected after
output setup.

There is **no** `pages.json`. Full page body text is **not** emitted in v0.2
IR; nodes carry `bodyOffset` only (byte offset of body start in the source
file). Consumers that need raw body re-read source from `sourcePath`.

No HTML, no RAG tree, no per-page fragment files under this IR contract.
HTML-only layout slots, including `{{children}}`, do not change this IR shape
or its `schemaVersion`.

| File | On success (`ok: true`) | On content failure (`ok: false`) |
|------|-------------------------|-----------------------------------|
| `manifest.json` | Full page list, sorted by `id` | **Not published** |
| `graph.json` | `frozen: true`, nodes + edges + reverseIndex + nav | **Not published** |
| `build-report.json` | `ok: true`, empty diagnostics | `ok: false`, non-empty diagnostics |

---

## schemaVersion

Every top-level IR document **must** include:

```json
"schemaVersion": "0.2.0"
```

| Rule | Detail |
|------|--------|
| Type | JSON string |
| v0.2 value | exactly `"0.2.0"` |
| Breaking change | Typed dependency endpoints and `reverseIndex`; old writers must not silently emit these under `"0.1.0"` |

Also required on success paths: a compiler id string of the form
`boris/<product-version>` (target `boris/0.5.0`). Product version bumps may
update this string without changing the IR schema, but this breaking IR change
requires both the schema and compiler/product bumps.

### v0.1 → v0.2 migration

| Surface | `0.1.0` | `0.2.0` |
|---------|---------|---------|
| `manifest.json` pages | unchanged shape | unchanged shape; document version + compiler bump |
| `graph.json` nodes/nav | page nodes + nav | unchanged page node/nav shape |
| `graph.json` edges | numeric page indices; `parent` only | typed endpoints; `parent`, `include`, `reference` |
| Reverse dependencies | not emitted | required `reverseIndex` over every emitted edge |
| Include/wiki validation in IR | not performed | required before freeze/publication |
| `build-report.json` | schema `0.1.0` | same shape, schema `0.2.0` |

Consumers MUST branch on `schemaVersion`; they must not infer the edge shape
from the compiler id.

---

## Pipeline stages (normative order)

| Stage | Name | Input | Output |
|------:|------|-------|--------|
| 1 | Discover | content root on disk | set of source paths (`.md` / `.mdx`) |
| 2 | Identify | source paths | `sourcePath` + path-derived `id` per page |
| 3 | Parse + promote | file bytes | durable PageDb fields + `bodyOffset` |
| 4 | Validate pages | pages + `parent` fields | identity/topology diagnostics; **no freeze yet** |
| 5 | Resolve + validate dependencies | validated page id set + page bodies + reachable include sources | direct include/reference edges + diagnostics |
| 6 | Freeze | only if zero errors | stable indices, sorted edges + reverse index; `frozen: true` |
| 7 | Emit | pages + frozen graph + diagnostics | JSON under `--out` (see publication) |

IR discovery, dependency resolution, freeze, and emit run **sequentially** in a single process. (Bounded HTML page
workers via `--jobs` are out of IR scope — see
[parallel-rendering.md](parallel-rendering.md).)

**Ownership rule:** after promote, no parser slice into a temporary file buffer
may be retained. PageDb strings live on a long-lived retain arena.

---

## Trunk / Satellite graph rules

Every page has exactly one role after resolution:

| Role | Condition |
|------|-----------|
| **trunk** | `parent` is null / omitted |
| **satellite** | `parent` is a non-null string |

### Normative rules

1. A **Trunk** has no `parent`.
2. A **Satellite** has **exactly one** `parent` naming a **Trunk** entity id.
3. The `parent` value is a full **entity id** (see
   [identity-and-paths.md](identity-and-paths.md)), **not** a filesystem path
   with `.md`, a URL, or a display title.
4. Comparison is case-sensitive string equality with another page’s `id`.
5. Hard validation errors (build fails):

| Condition | Code |
|-----------|------|
| Two pages share the same `id` | [`EDUPLICATEID`](diagnostics.md) |
| `parent` id not present in the page set | [`EPARENTMISSING`](diagnostics.md) |
| `parent` equals own `id` | [`EPARENTSELF`](diagnostics.md) |
| `parent` resolves to a Satellite | [`EPARENTNOTTRUNK`](diagnostics.md) |
| Cycle in parent edges | [`EPARENTCYCLE`](diagnostics.md) |

6. **Satellite-of-satellite** is unsupported: multi-hop chains are hard errors,
   not a nested navigation feature.
7. Multiple satellites may share the same Trunk parent.
8. Valid graphs are a **one-level forest**: roots are Trunks; every Satellite
   edges to exactly one Trunk.
9. **Do not claim the structure is a DAG (or frozen forest) until validation
   succeeds and freeze runs.** On failure, `frozen` is never true and
   `graph.json` is not published.

### Validation order (when multiple issues exist)

1. Encoding / path / frontmatter errors for that file (during parse)
2. [`EDUPLICATEID`](diagnostics.md) (global; detected before map overwrite can hide it)
3. [`EPARENTSELF`](diagnostics.md)
4. [`EPARENTMISSING`](diagnostics.md)
5. [`EPARENTNOTTRUNK`](diagnostics.md)
6. After all pages processed: [`EPARENTCYCLE`](diagnostics.md) (global)
7. Include/reference diagnostics in stable locus order after page identity and
   topology are known valid

Diagnostics are sorted for emit by (`sourcePath`, `line`, `column`, `code`,
`message`) — deterministic and non-duplicative for a given content tree.

### Non-goals (graph)

- No multi-parent / tags-as-parents
- No automatic parent inference from directory layout
- No requirement that a satellite’s path be nested under the parent’s path
- No component graph nodes — only pages

---

## Determinism requirements

Given the same content-root **bytes**, same relative path strings passed to
the CLI, same compiler version, and the **same host OS/filesystem semantics**:

1. Byte-for-byte identical `manifest.json` and `graph.json` (LF, same key order).
2. `build-report.json` identical when `outDir` / `contentRoot` strings match.
3. **Sorted** `pages` / `nodes` by `id` ascending (unsigned byte order of UTF-8).
4. **Sorted** `edges` and `reverseIndex` by their canonical endpoint comparators;
   reverse entries contain ascending final edge indices.
5. **Stable key order** within each object (order listed below).
6. No wall-clock timestamps, hostnames, absolute machine paths for **source**
   identity, or random IDs in the IR (`sourcePath` is content-root-relative;
   `contentRoot` / `outDir` are the CLI path strings as passed).
7. Newlines: **LF only**. Pretty-print with **2-space indent**, no trailing
   spaces, final newline at EOF.
8. Integers only where specified (no floats).
9. Do **not** iterate a hash map while serializing; arrays are built from
   sorted lists.

**Not claimed:** bit-identical IR across operating systems without
cross-platform CI evidence.

---

## Output publication behavior

Implementation (`src/pipeline.zig`):

1. Build and validate **entirely in memory** first.
2. **Success:** write all three JSON files into a sibling staging directory
   `{outDir}.boris-stage`, then **rename each file** into `outDir` (Zig
   `Dir.rename`, which replaces an existing file of the same name). Remove the
   staging directory afterward.
3. **Content failure:** write only `build-report.json`; delete any existing
   `manifest.json` / `graph.json` under `outDir`.

### Platform limitations (documented, not over-claimed)

| Claim | Status |
|-------|--------|
| Same-directory file rename after staging | Used on success path |
| Whole-directory atomic replace of `outDir` | **Not** used |
| Cross-volume / cross-device atomic publish | **Not claimed** |
| Concurrent readers never observe a torn three-file set | Best-effort via staging; not formally proven on all hosts |
| Staging path names inside JSON | Never — only final `outDir` string as passed to the CLI |

---

## `manifest.json` schema

Key order (root):

```text
schemaVersion, compiler, contentRoot, pageCount, pages
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | string | yes | `"0.2.0"` |
| `compiler` | string | yes | e.g. `"boris/0.5.0"` |
| `contentRoot` | string | yes | Content root path string as passed to the pipeline (no trailing slash) |
| `pageCount` | integer | yes | `pages.length` |
| `pages` | array | yes | Summary entries sorted by `id` |

Diagnostics are **not** on the manifest; they live in `build-report.json`.

### Manifest page summary object

Key order: `index`, `id`, `sourcePath`, `role`, `parent`, `title`, `status`

| Field | Type | Description |
|-------|------|-------------|
| `index` | integer | Stable 0-based index after id sort / freeze |
| `id` | string | Entity id |
| `sourcePath` | string | Canonical source path (content-relative) |
| `role` | string | `"trunk"` or `"satellite"` |
| `parent` | string \| null | Parent id or `null` |
| `title` | string \| null | From frontmatter or null |
| `status` | string \| null | `draft` \| `published` \| `archived` or null |

Example (shape only):

```json
{
  "schemaVersion": "0.2.0",
  "compiler": "boris/0.5.0",
  "contentRoot": "content",
  "pageCount": 2,
  "pages": [
    {
      "index": 0,
      "id": "guides/intro",
      "sourcePath": "guides/intro.md",
      "role": "trunk",
      "parent": null,
      "title": "Introduction",
      "status": "published"
    },
    {
      "index": 1,
      "id": "guides/intro-tips",
      "sourcePath": "guides/intro-tips.md",
      "role": "satellite",
      "parent": "guides/intro",
      "title": "Intro Tips",
      "status": "draft"
    }
  ]
}
```

---

## `graph.json` schema

Key order (root):

```text
schemaVersion, frozen, nodes, edges, reverseIndex, nav
```

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string | `"0.2.0"` |
| `frozen` | boolean | `true` only after successful graph freeze |
| `nodes` | array | Full node objects, sorted by `id` |
| `edges` | array | Direct dependency edges after freeze (canonical order below) |
| `reverseIndex` | array | Target-keyed incoming-edge index in canonical endpoint order |
| `nav` | array | Per-page navigation derived from the frozen graph (see below) |

### Ownership: why `nav` lives on `graph.json`

| Artifact | Owns |
|----------|------|
| `manifest.json` | Lightweight page **summaries** (role, parent id, title, status) for inventory |
| `graph.json` | Frozen **topology** — page nodes, dependency edges, reverse index, and derived navigation |
| `build-report.json` | Success flag + diagnostics only |

`nav` is computed **only** from the already-validated, already-frozen node list
(`parent_index` / role). It is not page inventory metadata, so it does **not**
belong on `manifest.json`. It is published only when `frozen: true` (same
gate as `nodes` / `edges`); on content failure, `graph.json` is not published
and no nav is emitted.

**Non-goals for `nav`:** no filesystem re-walk, no frontmatter re-parse, no
HTML or RAG consumption requirements. Dependency topology and reverse lookup
live beside `nav`; they are not duplicated into nav entries.

### Node object

Key order:

```text
index, id, sourcePath, role, parent, parentIndex, title, status, tags, bodyOffset
```

| Field | Type | Description |
|-------|------|-------------|
| `index` | integer | Stable index |
| `id` | string | Entity id |
| `sourcePath` | string | Canonical source path |
| `role` | string | `"trunk"` \| `"satellite"` |
| `parent` | string \| null | Parent id or null |
| `parentIndex` | integer \| null | Index of parent node, or null |
| `title` | string \| null | From frontmatter |
| `status` | string \| null | Validated status or null |
| `tags` | array of string | May be empty; author order preserved |
| `bodyOffset` | integer | Byte offset of body start in source (≥ 0) |

**No `body` field.** Re-read the file when raw body is needed.

### Dependency endpoints

Edges do not overload numeric page indices for non-page inputs. Every endpoint
has one fixed object shape and key order:

```text
type, value
```

| `type` | `value` | Meaning |
|--------|---------|---------|
| `"page"` | canonical entity id | A discovered page node in the same `graph.json` |
| `"source"` | canonical content-root-relative path | File bytes consumed through `{{include}}`; the file is not promoted to a page node merely because it is an endpoint |

Endpoint values never contain an absolute path. `source` uses `/` separators
and the same beneath-content-root safety policy as include resolution. A file
that is both a discovered page and an include target may legitimately have two
identities: `page` represents its entity semantics; `source` represents its
bytes as a transclusion target.

For directives in the normally compiled body of a page, `from` is that
`page` endpoint. When a reachable file body is inspected as an included
fragment, `from` is its `source` endpoint, even if that file is also a page.

### Edge object

Key order: `from`, `to`, `kind`. Endpoint object key order is `type`, `value`.

| Field | Type | Description |
|-------|------|-------------|
| `from` | endpoint object | Direct dependent/consumer |
| `to` | endpoint object | Direct dependency/target |
| `kind` | string | Closed v0.2 edge kind below |

| `kind` | Allowed `from` | Required `to` | Meaning |
|--------|----------------|---------------|---------|
| `"parent"` | `page` | `page` | Satellite depends on its Trunk parent |
| `"include"` | `page` or `source` | `source` | Body directly contains an active include of target bytes |
| `"reference"` | `page` or `source` | `page` | Body directly contains an active wiki-link to target entity |

`layout` and `asset` may exist in internal dependency code, but are not valid
IR v0.2 edge kinds. Adding an emitted kind requires a contract amendment and a
schema compatibility decision.

#### Edge production and order

1. Emit only **direct authored edges**. Do not emit transitive include closure
   as extra edges. Forward dependents of a target are recovered via
   `reverseIndex` (then `edges[i]`); what a locus transitively includes is
   recovered by walking the sorted `edges` array outward from that locus.
2. Ignore directives/wiki syntax inside fenced code exactly as the Feature 7
   contract requires.
3. Repeated occurrences of the exact `(from, to, kind)` tuple produce one edge.
   A `parent` and `reference` between the same two pages remain distinct.
4. Sort by (`from.type`, `from.value`, `to.type`, `to.value`, `kind`) using
   unsigned UTF-8 byte order. The array position after this sort is the stable
   **edge index** used by `reverseIndex`.
5. Missing/malformed include or reference targets produce the existing stable
   diagnostics and prevent freeze/publication; no partial dependency graph is
   emitted.

v0.2 does **not** put dependency arrays on node objects. Child and sibling lists
remain only under `nav`.

### Reverse dependency index

`reverseIndex` contains one entry for every distinct endpoint that appears as
an edge `to`. Targets with no incoming edge are omitted. Entry key order:

```text
target, incomingEdges
```

| Field | Type | Description |
|-------|------|-------------|
| `target` | endpoint object | Exact target endpoint represented by this entry |
| `incomingEdges` | array of integer | Ascending indices into the final sorted `edges` array |

Entries sort by (`target.type`, `target.value`) in unsigned UTF-8 byte order.
`incomingEdges` is never omitted and contains no duplicates. Consumers recover
the dependent endpoint and edge kind from `edges[incomingEdges[i]]`; the index
does not duplicate or weaken edge semantics.

Reverse traversal is kind-aware. Starting from a changed `source` endpoint or
changed `page` entity, follow `incomingEdges` to recover each dependent
`from` and `kind`, then continue through intermediate `source` endpoints until
page dependents are reached. Forward walks (e.g. “what does this page
transitively include?”) use the sorted `edges` array, not `reverseIndex`
alone. Since F8.3, incremental HTML builds use this same direct-edge resolver:
fingerprints identify changed page-input seeds, then the frozen reverse
semantics expand parent/reference dependents before rendering. Watch retains
full rediscovery plus fingerprinting. No new IR edge kinds or schema bump are
introduced by this consumption path.

### `nav` entry object

One entry per page, **same order as `nodes`** (entity id ascending). Index
arrays reference stable node indices (post-freeze).

Key order:

```text
index, id, breadcrumb, children, siblings
```

| Field | Type | Description |
|-------|------|-------------|
| `index` | integer | Same as the page’s node `index` |
| `id` | string | Entity id (redundant with `nodes[i].id`; stable for consumers) |
| `breadcrumb` | array of integer | Parent chain **root → self** (inclusive), node indices |
| `children` | array of integer | Direct child node indices, entity id ascending |
| `siblings` | array of integer | Same-Trunk satellite peers **excluding self**, id ascending; **empty for Trunk** |

#### Normative rules

1. **Input:** frozen nodes only (`parent_index` remapped after id sort). No I/O.
2. **Breadcrumb:** walk `parent_index` from the page to the root Trunk, then
   emit root → self. For a Trunk this is `[selfIndex]`. For a Satellite in the
   v0.2 one-level forest this is `[parentIndex, selfIndex]`.
3. **Children:** every node `c` with `c.parentIndex == page.index`, ordered by
   entity id. Equivalent to scanning the id-sorted node array once and
   appending — **do not** sort via hash-map iteration.
4. **Siblings:** if the page is a Satellite with parent `P`, the direct
   children of `P` excluding self (id order). If the page is a Trunk,
   `siblings` is `[]` (other roots are **not** siblings).
5. **Empty arrays** are written as `[]`, never omitted.
6. v0.2 forests are one-level: satellites never have children under valid
graphs; multi-hop chains remain hard errors at validate time.

Example (dependency fields abbreviated; the F8 fixture pins the complete edge
and reverse-index skeleton):

```json
{
  "schemaVersion": "0.2.0",
  "frozen": true,
  "nodes": [ "…" ],
  "edges": [
    {
      "from": {"type": "page", "value": "index"},
      "to": {"type": "source", "value": "includes/shared.md"},
      "kind": "include"
    }
  ],
  "reverseIndex": [
    {
      "target": {"type": "source", "value": "includes/shared.md"},
      "incomingEdges": [0]
    }
  ],
  "nav": [
    {
      "index": 0,
      "id": "guides/intro",
      "breadcrumb": [0],
      "children": [1],
      "siblings": []
    },
    {
      "index": 1,
      "id": "guides/intro-tips",
      "breadcrumb": [0, 1],
      "children": [],
      "siblings": []
    },
    {
      "index": 2,
      "id": "index",
      "breadcrumb": [2],
      "children": [],
      "siblings": []
    }
  ]
}
```

---

## `build-report.json` schema

Key order (root):

```text
schemaVersion, ok, contentRoot, outDir, pageCount, errorCount, diagnostics
```

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string | `"0.2.0"` |
| `ok` | boolean | `true` iff zero error diagnostics and freeze succeeded |
| `contentRoot` | string | Same string as pipeline option |
| `outDir` | string | Same string as pipeline option |
| `pageCount` | integer | Number of page nodes retained after successful parses |
| `errorCount` | integer | Count of severity=`error` diagnostics |
| `diagnostics` | array | Sorted diagnostics (see [diagnostics.md](diagnostics.md)) |

### Diagnostic object (in report)

Key order:

```text
severity, code, message, remediation, sourcePath, line, column, id
```

See [diagnostics.md](diagnostics.md) for field meanings and the closed code set.

---

## Failure output

On hard content error (CLI exit `1`):

1. Diagnostics printed to stderr (text form).
2. Only `build-report.json` is published under `--out` (`ok: false`).
3. Do not treat the out directory as a valid frozen graph for consumers.

On I/O/system failure (CLI exit `3`), files may be missing or partial.

---

## Consumer expectations

Consumers of `"0.2.0"` may rely on:

- Required keys listed above (including `graph.json` → `reverseIndex` and `nav` on success)
- Deterministic sort and key order **on a given host**
- Role/parent invariants after `ok: true` and `frozen: true`
- The single parent key name **`parent`** (never `parentEntry`)
- `nav` arrays ordered by entity id; indices consistent with `nodes`
- Typed dependency endpoints, direct-edge semantics, and reverse edge indices

Consumers must not require HTML fields, full body text, RAG paths, or
component lists under this schema version.

---

## Explicit non-support in v0.2 IR

| Feature | Status |
|---------|--------|
| HTML `dist/` as IR output | **Out of IR** — HTML is the default CLI mode but not part of this schema; see [html-output.md](html-output.md) |
| Apex markdown render | Out of IR acceptance |
| Product RAG export | Optional product path; separate [rag-export.md](rag-export.md) |
| Full YAML frontmatter | Rejected — [frontmatter.md](frontmatter.md) |
| Concurrency / worker pools | **Out of IR emit** — HTML-only via [parallel-rendering.md](parallel-rendering.md) |
| `parentEntry` in IR fields | **Forbidden** — use `parent` only |
