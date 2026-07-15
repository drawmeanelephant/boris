# Intermediate representation (IR) schema (v0.1)

**Status:** normative contract — **implemented** by the milestone 6 default CLI  
**Compiler id:** `boris/0.1.1`  
**schemaVersion:** `0.1.0`

Default v0.1 product output is **deterministic JSON IR** under `.boris/` (or
`--out`). **HTML is not** a default product surface for v0.1 acceptance.

---

## Artifacts

On a **successful** compile (`ok: true`), Boris publishes three files under the
output directory (CLI default `.boris/`):

```text
.boris/
  manifest.json       # required — page summaries
  graph.json          # required — frozen nodes + parent edges + nav
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

There is **no** `pages.json`. Full page body text is **not** emitted in v0.1
IR; nodes carry `bodyOffset` only (byte offset of body start in the source
file). Consumers that need raw body re-read source from `sourcePath`.

No HTML, no RAG tree, no per-page fragment files under this IR contract.

| File | On success (`ok: true`) | On content failure (`ok: false`) |
|------|-------------------------|-----------------------------------|
| `manifest.json` | Full page list, sorted by `id` | **Not published** |
| `graph.json` | `frozen: true`, nodes + edges + nav | **Not published** |
| `build-report.json` | `ok: true`, empty diagnostics | `ok: false`, non-empty diagnostics |

---

## schemaVersion

Every top-level IR document **must** include:

```json
"schemaVersion": "0.1.0"
```

| Rule | Detail |
|------|--------|
| Type | JSON string |
| v0.1 value | exactly `"0.1.0"` |
| Breaking change | New `schemaVersion`; old writers must not silently emit new shapes under `"0.1.0"` |

Also required on success paths: a compiler id string of the form `boris/<product-version>`
(currently `boris/0.1.1`). Product patch bumps may update this string; IR
`schemaVersion` stays `"0.1.0"` until the emit shape breaks.

---

## Pipeline stages (normative order)

| Stage | Name | Input | Output |
|------:|------|-------|--------|
| 1 | Discover | content root on disk | set of source paths (`.md` / `.mdx`) |
| 2 | Identify | source paths | `sourcePath` + path-derived `id` per page |
| 3 | Parse + promote | file bytes | durable PageDb fields + `bodyOffset` |
| 4 | Validate | pages + `parent` fields | diagnostics; **no freeze yet** |
| 5 | Freeze | only if zero errors | stable indices + edges; `frozen: true` |
| 6 | Emit | pages + edges + diagnostics | JSON under `--out` (see publication) |

IR emit stages run **sequentially** in a single process. (Bounded HTML page
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
4. **Stable key order** within each object (order listed below).
5. No wall-clock timestamps, hostnames, absolute machine paths for **source**
   identity, or random IDs in the IR (`sourcePath` is content-root-relative;
   `contentRoot` / `outDir` are the CLI path strings as passed).
6. Newlines: **LF only**. Pretty-print with **2-space indent**, no trailing
   spaces, final newline at EOF.
7. Integers only where specified (no floats).
8. Do **not** iterate a hash map while serializing; arrays are built from
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
| `schemaVersion` | string | yes | `"0.1.0"` |
| `compiler` | string | yes | e.g. `"boris/0.1.1"` |
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
  "schemaVersion": "0.1.0",
  "compiler": "boris/0.1.1",
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
schemaVersion, frozen, nodes, edges, nav
```

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string | `"0.1.0"` |
| `frozen` | boolean | `true` only after successful graph freeze |
| `nodes` | array | Full node objects, sorted by `id` |
| `edges` | array | Parent edges after freeze (sorted by `from`, then `to`) |
| `nav` | array | Per-page navigation derived from the frozen graph (see below) |

### Ownership: why `nav` lives on `graph.json`

| Artifact | Owns |
|----------|------|
| `manifest.json` | Lightweight page **summaries** (role, parent id, title, status) for inventory |
| `graph.json` | Frozen **topology** — nodes, parent edges, and derived navigation |
| `build-report.json` | Success flag + diagnostics only |

`nav` is computed **only** from the already-validated, already-frozen node list
(`parent_index` / role). It is not page inventory metadata, so it does **not**
belong on `manifest.json`. It is published only when `frozen: true` (same
gate as `nodes` / `edges`); on content failure, `graph.json` is not published
and no nav is emitted.

**Non-goals for this field:** no filesystem re-walk, no frontmatter re-parse,
no reverse dependency index, no incremental rebuild data, no HTML or RAG
consumption requirements.

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

### Edge object

Key order: `from`, `to`, `kind`

| Field | Type | Description |
|-------|------|-------------|
| `from` | integer | Child node index |
| `to` | integer | Parent node index |
| `kind` | string | `"parent"` in v0.1 |

v0.1 does **not** put a derived `children` array on node objects. Child and
sibling lists live only under the top-level `nav` array.

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
   v0.1 one-level forest this is `[parentIndex, selfIndex]`.
3. **Children:** every node `c` with `c.parentIndex == page.index`, ordered by
   entity id. Equivalent to scanning the id-sorted node array once and
   appending — **do not** sort via hash-map iteration.
4. **Siblings:** if the page is a Satellite with parent `P`, the direct
   children of `P` excluding self (id order). If the page is a Trunk,
   `siblings` is `[]` (other roots are **not** siblings).
5. **Empty arrays** are written as `[]`, never omitted.
6. v0.1 forests are one-level: satellites never have children under valid
   graphs; multi-hop chains remain hard errors at validate time.

Example (shape only; matches the valid contract fixture):

```json
{
  "schemaVersion": "0.1.0",
  "frozen": true,
  "nodes": [ "…" ],
  "edges": [ "…" ],
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
| `schemaVersion` | string | `"0.1.0"` |
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

Consumers of `"0.1.0"` may rely on:

- Required keys listed above (including `graph.json` → `nav` on success)
- Deterministic sort and key order **on a given host**
- Role/parent invariants after `ok: true` and `frozen: true`
- The single parent key name **`parent`** (never `parentEntry`)
- `nav` arrays ordered by entity id; indices consistent with `nodes` / `edges`

Consumers must not require HTML fields, full body text, RAG paths, or
component lists under this schema version.

---

## Explicit non-support in default v0.1 IR

| Feature | Status |
|---------|--------|
| HTML `dist/` as IR output | **Out of IR** — HTML is the default CLI mode but not part of this schema; see [html-output.md](html-output.md) |
| Apex markdown render | Out of IR acceptance |
| Product RAG export | Optional product path; separate [rag-export.md](rag-export.md) |
| Full YAML frontmatter | Rejected — [frontmatter.md](frontmatter.md) |
| Concurrency / worker pools | **Out of IR emit** — HTML-only via [parallel-rendering.md](parallel-rendering.md) |
| `parentEntry` in IR fields | **Forbidden** — use `parent` only |
