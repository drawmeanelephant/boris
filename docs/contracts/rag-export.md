# RAG export contract (optional, implemented)

**Status:** normative for optional product RAG export  
**Format id:** `boris-rag`  
**Schema version:** `1` (integer in `catalog_meta.json`)  
**Product version field:** `boris_version` (package version string, currently `0.6.1`)
**Milestone:** 7 implements this contract via `src/rag.zig` + CLI `--rag` / `--rag-dir`.

RAG is an **optional** export with explicit schema versioning. It is **not**
required for IR acceptance (`.boris/` JSON). When export succeeds, the corpus
**must** satisfy this document.

Standalone **source-code** packing (`zig build source-rag` → `source-rag/`) is
a separate tool and is **not** this contract.

---

## Relationship to IR

| Surface | Role |
|---------|------|
| Default CLI output | HTML site under `dist/` ([html-output.md](html-output.md)) |
| Optional JSON IR | Deterministic JSON under `--out DIR` / `--no-rag` ([ir-schema.md](ir-schema.md)) |
| Optional RAG export | Separate corpus tree (`rag/` by default) for LLM retrieval |

### Shared validation (hard requirement)

Both IR mode and RAG mode call the **same** compile path:

```text
scanner.scan → parser.parse → PageDb.promote → graph.validate → freeze (when clean)
```

Implemented as `pipeline.compile` (`src/pipeline.zig`). Graph validation is the
single entry `graph.validate` (not reimplemented in RAG). Diagnostic **codes /
categories** for invalid content must match between modes.

Graph-dependent RAG artifacts (`content/pages/**`, `graph/**`, catalog rows for
those segments, and a complete published tree) are written **only after**
validation succeeds. A failed graph does **not** publish a valid-looking
partial corpus (staging is discarded; prior `rag/` is left untouched).

---

## CLI

| Flag | Behavior |
|------|----------|
| `--rag` | RAG-only; default output dir `rag` |
| `--rag-dir DIR` | RAG-only; output dir `DIR` (implies RAG-only) |
| `--out` with `--rag` / `--rag-dir` | **Invalid** (usage exit 2) |

Default system-seed root: `docs/rag/system`. If missing, the `system/` segment
is skipped (no hard error).

---

## Output tree

Default root: `rag/` (override with `--rag-dir=DIR`).

```text
<rag-root>/
  INDEX.md                 # meta retrieval map (catalog entry)
  UPLOAD-GUIDE.md          # meta upload notes (catalog entry)
  catalog.jsonl            # machine catalog (NOT a catalog entry)
  catalog_meta.json        # machine meta (NOT a catalog entry)
  system/**/*.md           # curated seeds (when seed root exists)
  content/pages/**/*.md    # content pages (entity_id mirrored)
  graph/
    entity-catalog.md
    relations.md
```

### Publication / staging

1. Validate graph (shared `pipeline.compile`).
2. Write the full tree under `{out_dir}.boris-rag-stage`.
3. On success: replace `out_dir` via directory rename when possible; otherwise
   file-by-file copy then delete the stage.
4. On validation failure: do not publish; leave any prior `out_dir` alone.

### Cross-platform limitations (honest)

- Same-host dual export is byte-identical by construction (stable sorts, no
  wall-clock / host fields).
- **Not claimed:** cross-OS bit-identical corpora without multi-OS CI evidence
  (line endings of copied seeds follow source files; absolute path handling
  differs by OS conventions).
- Directory rename is best-effort same-filesystem; cross-volume atomic replace
  is **not** claimed. Concurrent readers may observe a missing tree between
  delete and rename/copy.

---

## Schema versioning

Emitted on **every successful** RAG export as `catalog_meta.json`:

```json
{"format":"boris-rag","schema_version":1,"boris_version":"0.6.1"}
```

| Field | Type | Notes |
|-------|------|--------|
| `format` | string | Always `boris-rag` |
| `schema_version` | number | Integer; bump when this contract breaks consumers |
| `boris_version` | string | Product version that produced the corpus |

Field order is fixed: `format`, `schema_version`, `boris_version`. Compact JSON
plus trailing LF. No timestamps or host fields.

Breaking changes to corpus layout, catalog fields, or title/H1 rules require a
`schema_version` bump.

---

## Determinism

Identical inputs on the **same host** → **byte-identical** corpus trees.

### Forbidden in deterministic corpus files

- Wall-clock timestamps
- Random / UUID identifiers
- Absolute filesystem paths
- Hostnames, usernames, environment variables
- Hash-map iteration order as emit order
- Filesystem walk order as emit order

### Required stable sort keys

| Set | Sort key (ascending, byte-wise) |
|-----|----------------------------------|
| Content pages | entity id (freeze order) |
| System seed documents | normalized relative path under system docs dir (`/` separators) |
| Graph hubs / satellite lists | entity id |
| Graph edge list | source id then target id |
| `catalog.jsonl` rows / INDEX table | `rag_path` |

Catalog paths are relative and normalized with `/` (no `\`, no leading `/`).

---

## `catalog.jsonl` field order (normative)

Every line is independently valid JSON. Keys in **this exact order**:

```text
rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
```

| Field | Content pages | System / graph / meta |
|-------|---------------|------------------------|
| `rag_id` | `content/<entity_id>` | stable id |
| `rag_path` | corpus-relative path | corpus-relative path |
| `category` | `content` | `system` \| `graph` \| `meta` |
| `title` | human title | human title |
| `entity_id` | entity id | `""` |
| `role` | `trunk` \| `satellite` | `""` |
| `parent_entry` | parent id or `""` | `""` |
| `tags` | string form of tag list | string form of tag list |

**Note on `parent_entry`:** catalog column name only. Author-facing frontmatter
and IR use **`parent`** exclusively ([frontmatter.md](frontmatter.md),
[ir-schema.md](ir-schema.md)). The catalog field stores the same entity-id
string; it is not a license to accept `parentEntry` in source frontmatter.

Machine files `catalog.jsonl` and `catalog_meta.json` are part of the tree and
documented in `INDEX.md` but are **not** catalog rows.

---

## Aside / `:::kind` export representation

- **Canonical authoring grammar** is constrained `<Aside …>` (see
  [components.md](components.md)). Unknown PascalCase tags fail compile with
  `ECOMPONENT` on the shared pipeline before RAG export.
- **Export representation:** each parsed Aside becomes an inline directive block
  in the parent page segment:

  ```md
  :::tip{id="006-1"}
  body…
  :::
  ```

  Without id: `:::note` … `:::`. Kind/id are already allowlist-validated.
- This form is for **LLM retrieval only**. It is **not** authoring syntax and
  is **not** round-trippable as Boris input. Raw `<Aside>` tags do **not** remain
  in exported content pages.
- No per-aside files under `rag/content/`.

---

## Content page title / H1 ownership

**Model: metadata-owned.**

1. Catalog `title` and the document H1 come from frontmatter `title`, else
   entity id.
2. The exporter emits exactly one ATX H1: `# <title>`.
3. A leading ATX H1 in the source body is **stripped**.
4. Any remaining ATX H1 lines in the body are **demoted to H2**.
5. Therefore each exported content page has **exactly one** document H1.

---

## Related neighbors

When `related` is emitted on a content page, it lists **direct graph neighbors
only** (parent and immediate satellites), in stable order: parent first (if
any), then children by entity id ascending.

---

## Out of scope

- Chunking
- Embeddings
- Database storage
- Upload integrations / network clients
- Making RAG the default CLI output
- Treating `:::kind` as authoring syntax
- Apex / HTML rendering in the RAG path

---

## Acceptance

1. Export twice into two distinct directories from identical inputs; byte-compare
   every file.
2. `catalog_meta.json` exists, parses as JSON, and matches the fixed shape/order
   above.
3. Each `catalog.jsonl` line parses as JSON with the required keys in order.
4. Deterministic ordering under shuffled fixture creation order (system seeds
   and content pages).
5. Exactly one ATX H1 per exported content page.
6. Graph validation failures abort export (no partial success claim); IR and RAG
   report the same diagnostic categories for the same invalid fixture.
7. `zig build test` passes;  
   `zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag`
   succeeds.
