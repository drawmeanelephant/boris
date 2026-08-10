# RAG export contract (optional, implemented)

**Status:** normative for optional product RAG export
**Format id:** `boris-rag`
**Schema version:** `2` (integer in `catalog_meta.json`)
**Product version field:** `boris_version` (package version string, currently `0.8.1`)
**Milestone:** 7 implements this contract via `src/rag.zig` + CLI `--rag` /
`--rag-dir` / `--complete`.

RAG is an **optional** export with explicit schema versioning. It is **not**
required for IR acceptance (`.boris/` JSON). When export succeeds, the corpus
**must** satisfy this document.

Standalone **source-code** packing (`zig build source-rag` → `source-rag/`) is
a separate tool and is **not** this contract.

---

## Product philosophy

Product RAG is a **retrieval / working-context projection**, not an archive or
a forensic record. Its job is to give an AI model the smallest useful context —
in the fewest practical upload files — to read a site and continue authoring it
in a way Boris accepts.

The constraints that shape the default surface are the ones users actually hit
when they load generated files into an AI system: attachment-count limits,
per-attachment cost, finite context windows, and context shared with the
conversation and its working output. **Attachment count and token overhead are
first-class product constraints.**

Consequences of that stance:

- **Authoring fidelity is intentional.** The retrieval payload is the actual
  complete Boris-authorable Markdown document — frontmatter, H1 structure, and
  `<Aside>` / `<Details>` authoring syntax included, verbatim. A model can read
  the site's real conventions and hand generated Markdown straight to Boris
  validation without a RAG-specific reverse transformation. There is no
  intermediate RAG-only authoring dialect and no export-only `:::kind`
  representation.
- **Whole documents are the preferred packing unit.** Normal documents are not
  split "because RAGs use chunks". Multiple complete documents pack into
  bounded upload files. Only an individual document larger than the pack target
  is split, deterministically, at safe Markdown boundaries.
- **Integrity lives at the coarsest useful boundary.** Model-facing packs do
  not repeat cryptographic fingerprints or byte counts per piece. Completeness
  and identity records (source path, expected bytes, optional document digest,
  pack membership, part count) live in a sidecar manifest that is explicitly
  **not intended for model upload**.
- **Scope determines the working set.** Requested subtree + one-hop semantic
  neighbors + required transitive parent chain is the conservative default
  closure; unrelated pages stay out.
- **Individual splits are exceptional**, and a full-corpus export is an
  explicit, distinct mode — not the default.

Provenance-rich reconstruction, byte-for-byte supply-chain verification, and
forensic evidence belong to other Boris surfaces (the
[Context Bundle](context-bundle.md) and source-oriented tooling) and are
**not** weakened by this contract.

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

Graph-dependent RAG artifacts (working packs, complete-corpus pages/graph, and
a complete published tree) are written **only after** validation succeeds. A
failed graph does **not** publish a valid-looking partial corpus (staging is
discarded; prior `rag/` is left untouched).

---

## CLI

| Flag | Behavior |
|------|----------|
| `--rag` | Working-context packs; default output dir `rag` |
| `--rag-dir DIR` | RAG output dir `DIR` (implies RAG-only) |
| `--complete` | Complete-corpus export (requires `--rag` / `--rag-dir`) |
| `--scope VALUE` | Entity id or collection-prefix projection after full graph validation |
| `--split-size BYTES` | Working-pack target (default `262144`); context-bundle byte cap |
| `--bundles-only` | Accepted for compatibility with the pre-v2 scoped-bundle workflow; working packs are bundle-style by design, so it is a no-op |
| `--out` with `--rag` / `--rag-dir` | **Invalid** (usage exit 2) |
| `--complete` with `--split-size` / `--bundles-only` | **Invalid** (usage exit 2) |

Default system-seed root: `docs/rag/system`. If missing, the seed segment is
skipped (no hard error).

`--complete` is the explicit full-corpus export: system seeds, path-mirrored
content pages, graph docs, INDEX/UPLOAD-GUIDE, and the machine catalog. Working
packs are the default because they are the ergonomic normal path; completeness
remains available but explicit.

---

## Working-context export (default `--rag`)

Output root: `rag/` (override with `--rag-dir=DIR`).

```text
<rag-root>/
  working-1.md            # model-facing upload files (bounded packs)
  working-2.md            # ...
  manifest.json           # sidecar — NOT normally uploaded
  catalog_meta.json       # machine format meta (not a catalog row)
```

### Pack files

Each `working-N.md` file is a bounded, deterministic pack containing complete
source documents delimited by envelope marker lines:

```text
<!-- boris-rag-doc: id="content/guides/intro" source="guides/intro.md" category="content" -->
```

A split document's marker additionally carries `part="k/n"`:

```text
<!-- boris-rag-doc: id="content/big" source="big.md" category="content" part="2/3" -->
```

- **Envelope metadata is minimal**: id, source, category, and (only for split
  documents) part position. Document titles and tags come from the document's
  own frontmatter; nothing else is repeated.
- **Documents are verbatim**: each document's bytes are the source file
  (frontmatter + body). No H1 stripping or demotion, no `:::kind` directive
  replacement. `<Aside>` / `<Details>` remain authoring syntax.
- **Reassembly**: concatenating the marker-free document bytes in pack order
  reproduces the source documents; for split documents, concatenating the parts
  in `part` order reproduces the document. Reassembly metadata is `part` /
  `part_count` in the marker and the manifest — nothing more.
- **No hashes, byte counts, or provenance** appear inside pack files.

### Packing rules

- Documents pack greedily in deterministic order: system seeds first (sorted
  by normalized relative path), then content pages in entity-id order (freeze
  order). A pack is closed when adding the next document instance would exceed
  the pack target.
- The pack target (default `262144` bytes, `--split-size` to override) caps the
  **sum of rendered document instances** (envelope + body + separators) per
  pack; the small fixed pack header is not counted against the target.
- **Whole documents are never split merely to meet the target.** A single
  document that cannot fit alongside anything else gets its own pack, even if
  its envelope overhead pushes that pack slightly over the target.
- An individual document **larger than the target** is split deterministically
  at blank-line or heading boundaries **outside fenced code**
  (`export_scope.partitionMarkdown`), preserving fence correctness. An
  indivisible block that cannot fit the target fails the export explicitly
  (`OversizedBlock`), and no partial output is published.
- Repeated exports produce **byte-identical** packs (same-host); ordering never
  depends on filesystem or hash-map iteration.

### `manifest.json` (sidecar)

The sidecar is the integrity and bookkeeping record. It is **not intended for
model upload**; its presence is announced in the export summary.

Field order is fixed:

```text
format, schema_version, boris_version, mode, scope, scope_closure,
graph_page_count, selected_page_count, structural_parent_count,
semantic_neighbor_count, graph_relation_count, selected_relation_count,
pack_target, approximate_tokens, upload_files, documents, sidecar_files
```

- `scope` — the requested entity id / prefix (`""` when unscoped).
- `scope_closure` — always `parents+semantic-relations`.
- `structural_parent_count` / `semantic_neighbor_count` — how many of the
  selected pages arrived via the transitive parent closure vs. one-hop
  semantic relations (0 when unscoped).
- `approximate_tokens` — deterministic approximation: total model-facing pack
  bytes divided by 4 (integer division). Documented approximation, no
  tokenizer dependency.
- `upload_files` — each pack path, byte count, and document count.
- `documents` — one record per document instance (split documents appear once
  per part): `rag_id`, `source`, `category`, `entity_id`, `pack`, `part`,
  `part_count`, `continuation` (`single` / `continues` / `continued`), `bytes`
  (document body bytes), and `source_sha256` (SHA-256 of the original source
  file). `source` is content-root-relative for content documents and
  seed-root-relative for system documents.
- `sidecar_files` — `["manifest.json", "catalog_meta.json"]`.

### `catalog_meta.json`

```json
{"format":"boris-rag","schema_version":2,"boris_version":"0.8.1"}
```

Field order fixed: `format`, `schema_version`, `boris_version`. Compact JSON
plus trailing LF. No timestamps or host fields.

---

## Complete-corpus export (`--rag --complete`)

The explicit full export for users who genuinely want everything, deterministic
and still model-usable:

```text
<rag-root>/
  INDEX.md                 # meta retrieval map (catalog entry)
  UPLOAD-GUIDE.md          # meta upload notes (catalog entry)
  catalog.jsonl            # machine catalog (NOT a catalog entry)
  catalog_meta.json        # machine meta (NOT a catalog entry)
  system/**/*.md           # curated seeds (verbatim)
  content/pages/**/*.md    # content pages (verbatim authoring documents)
  graph/
    entity-catalog.md
    relations.md
```

Same authoring-fidelity rules as the working packs: content pages and system
seeds are verbatim source documents. `INDEX.md` and `UPLOAD-GUIDE.md` describe
the tree and recommend the working packs for normal site-writing work. There is
no per-file RAG frontmatter envelope and no `:::kind` export representation.

`--scope` narrows the complete tree the same way it narrows the working set
(subtree + parents + one-hop neighbors). System seeds are not narrowed by
`--scope`, matching the working packs.

Schema-versioned machine surfaces (`catalog_meta.json`, `catalog.jsonl`,
`INDEX.md` table) are shared with the schema v1 family; see
[Schema versioning](#schema-versioning).

---

## Publication / staging

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
{"format":"boris-rag","schema_version":2,"boris_version":"0.8.1"}
```

| Field | Type | Notes |
|-------|------|--------|
| `format` | string | Always `boris-rag` |
| `schema_version` | number | Integer; bump when this contract breaks consumers |
| `boris_version` | string | Product version that produced the corpus |

Field order is fixed: `format`, `schema_version`, `boris_version`. Compact JSON
plus trailing LF. No timestamps or host fields.

**Version history:**

- `1` — original corpus tree (INDEX/UPLOAD-GUIDE/catalog, `content/pages/**`
  with metadata-owned H1 and `:::kind` aside export, `--split-size` parts).
- `2` — working-context packs become the default `--rag` tree; `--complete`
  becomes the explicit full-corpus export; content documents are verbatim
  authoring sources (H1 and `<Aside>` / `<Details>` preserved); per-document
  integrity moved to the `manifest.json` sidecar; parts machinery removed from
  complete mode (working packs cover bounded uploads).

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
| Working packs / manifest documents | seeds by normalized seed-relative path, then content pages by entity id (freeze order) |
| System seed documents | normalized relative path under system docs dir (`/` separators) |
| Content pages (complete mode) | entity id (freeze order) |
| Graph hubs / satellite lists | entity id |
| Graph edge list | source id then target id |
| `catalog.jsonl` rows / INDEX table | `rag_path` |

Catalog paths are relative and normalized with `/` (no `\`, no leading `/`).

---

## `catalog.jsonl` field order (complete mode, normative)

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

## Authoring fidelity (both modes)

- **H1s are never rewritten.** The source document's heading structure is
  preserved byte-for-byte. There is no metadata-owned H1 rule and no demotion
  pass in the v2 contract.
- **`<Aside>` / `<Details>` remain authoring syntax.** The v1 `:::kind`
  export representation is gone; component tags survive as the author wrote
  them. Unknown PascalCase tags still fail compile with `ECOMPONENT` on the
  shared pipeline before any export.
- **Frontmatter is preserved** (including author keys such as `id`, `parent`,
  `status`, and `summary`). The catalog and graph docs remain
  emitter-generated containers and are encoded through the structured sink;
  verbatim documents are raw author content by design.

## Scoped and segmented exports

`--scope` accepts an exact entity id or collection prefix (`mascots` selects
`mascots` and descendants). Boris validates the complete graph first, then
projects selected pages, transitive structural parents, and one-hop semantic
relation neighbors. Related pages receive their own parent closure; ordinary
Markdown links are not semantic edges. Unscoped exports include every page.

The working-context path is scope-first: ask for "this part of the site and the
context needed to understand it" with `--scope`, and unrelated content stays
out of the upload files. No broad semantic expansion is invented; one-hop
relations plus required structural closure is the conservative baseline.

## Out of scope

- Embeddings
- Database storage
- Upload integrations / network clients
- Making RAG the default CLI output
- Treating `:::kind` as authoring syntax
- Apex / HTML rendering in the RAG path
- Forensic / byte-for-byte reconstruction metadata in model-facing files
  (belongs to Context Bundle and source tooling)

---

## Acceptance

1. Export twice into two distinct directories from identical inputs; byte-compare
   every file (working and complete modes).
2. `catalog_meta.json` exists, parses as JSON, and matches the fixed shape/order
   above with `schema_version: 2`.
3. Working packs: every content document is present verbatim (H1 and
   `<Aside>` / `<Details>` preserved, no `:::kind`, no hashes); documents are
   delimited by `<!-- boris-rag-doc -->` markers; repeated exports are
   byte-identical.
4. `manifest.json` exists, parses as JSON, lists every document instance with
   `part` / `part_count` / `continuation`, and carries per-document
   `source_sha256`; `sidecar_files` is present.
5. A document larger than the pack target is split at safe Markdown boundaries
   (fences intact) with minimal `part="k/n"` reassembly metadata; an
   indivisible oversized block fails explicitly without publishing a partial
   corpus.
6. Scoped exports include the requested subtree, one-hop semantic neighbors,
   and the required transitive parent chain; unrelated pages are excluded.
7. Complete mode publishes INDEX/UPLOAD-GUIDE/catalog/system/content/graph with
   verbatim content pages; `catalog.jsonl` rows parse with the required keys in
   order.
8. Graph validation failures abort export (no partial success claim); IR and
   RAG report the same diagnostic categories for the same invalid fixture.
9. `zig build test` passes; `zig build run -- --input fixtures/content/valid
   --rag-dir /tmp/boris-rag` and `--rag --complete` succeed.
