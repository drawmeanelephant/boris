# RAG export contract (optional, implemented)

**Status:** normative for optional product RAG export
**Format id:** `boris-rag`
**Schema version:** `2` (integer in `manifest.json` / `catalog_meta.json` as applicable)
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
| `--scope VALUE` | Entity id or collection-prefix projection after full graph validation (working/context modes only) |
| `--split-size BYTES` | Working-pack target (default `262144`); context-bundle byte cap |
| `--bundles-only` | Accepted for compatibility with the pre-v2 scoped-bundle workflow; working packs are bundle-style by design, so it is a no-op |
| `--out` with `--rag` / `--rag-dir` | **Invalid** (usage exit 2) |
| `--complete` with `--scope` | **Invalid** (usage exit 2): complete means the entire validated corpus |
| `--complete` with `--split-size` / `--bundles-only` | **Invalid** (usage exit 2) |

Default system-seed root: `docs/rag/system`. If missing, the seed segment is
skipped (no hard error). Seeds appear **only** in complete-corpus exports;
default working packs contain site documents, never the Boris system corpus.

`--complete` is the explicit export of the **entire validated corpus**: system
seeds, path-mirrored content pages, graph docs, INDEX/UPLOAD-GUIDE, and the
machine catalog. It deliberately rejects `--scope` — a command described as
"complete" must not silently emit only part of the corpus. Working packs are
the default because they are the ergonomic normal path; completeness remains
available but explicit. Scoped exports stay available on the working surface
(`--rag --scope …`), which is also the compatibility path for pre-v2
scoped-bundle workflows.

---

## Working-context export (default `--rag`)

Output root: `rag/` (override with `--rag-dir=DIR`).

```text
<rag-root>/
  working-1.md            # model-facing upload files (bounded packs)
  working-2.md            # ...
  manifest.json           # sidecar — NOT normally uploaded
```

Working mode emits exactly these files: the model-facing packs and the
`manifest.json` sidecar. `catalog_meta.json` is not emitted in working mode
(its format/schema/version fields are already recorded in the manifest); it
belongs to the complete-corpus catalog surface.

### Pack files

Each `working-N.md` file is a bounded, deterministic pack containing complete
site source documents delimited by envelope marker lines:

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
  replacement. `<Aside>` / `<Details>` remain authoring syntax. For Textile and
  Cooklang input, the body is the deterministically adapted Boris-authorable
  Markdown (see [Authoring fidelity](#authoring-fidelity-both-modes)).
- **Boundaries are unambiguous by construction**: a source line that begins
  (after leading whitespace) with the marker prefix `<!-- boris-rag-doc:`
  would be indistinguishable from a real envelope during marker-free
  reassembly, so the export rejects such a document with `SeparatorCollision`
  instead of emitting an ambiguous pack.
- **Reassembly**: concatenating the marker-free document bytes in pack order
  reproduces the source documents; for split documents, concatenating the parts
  in `part` order reproduces the document. Reassembly metadata is `part` /
  `part_count` in the marker and the manifest — nothing more.
- **No hashes, byte counts, or provenance** appear inside pack files.

### Packing rules

- Documents pack greedily in deterministic order: content pages in entity-id
  order (freeze order). A pack is closed when adding the next document instance
  would exceed the pack target.
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
  file). `source` is content-root-relative; working mode contains site
  documents only, so no `system/**` document ever appears in this list.
- `sidecar_files` — `["manifest.json"]`.

### `catalog_meta.json` (complete mode only)

`catalog_meta.json` is **not** emitted by working mode; `manifest.json` already
records `format`, `schema_version`, and `boris_version`. Complete-corpus
exports carry the compact machine meta:

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
seeds are verbatim source documents (Markdown) or deterministically adapted
Boris-authorable Markdown (Textile, Cooklang). `INDEX.md` and `UPLOAD-GUIDE.md`
describe the tree and recommend the working packs for normal site-writing work.
There is no per-file RAG frontmatter envelope and no `:::kind` export
representation.

`--complete` rejects `--scope`: the complete export is the entire validated
corpus, never a projection. (Scoped, tree-shaped exports remain available on
the working surface via `--rag --scope`, which also covers the pre-v2
scoped-bundle workflow; that surface is deliberately not named `--complete`.)

**Catalog self-consistency:** `INDEX.md` is itself a catalog row. Its row is
appended before sorting and counting, so INDEX's catalog count, INDEX's
full-catalog table, and `catalog.jsonl` all describe the same row set, INDEX
included.

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

Emitted on **every successful complete-corpus export** as `catalog_meta.json`
(working mode records the same three fields inside `manifest.json`):

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
| Working packs / manifest documents | content pages by entity id (freeze order); no system seeds in working mode |
| System seed documents (complete mode) | normalized relative path under system docs dir (`/` separators) |
| Content pages (complete mode) | entity id (freeze order) |
| Graph hubs / satellite lists | entity id |
| Graph edge list | source id then target id |
| `catalog.jsonl` rows / INDEX table | `rag_path` (INDEX included) |

Catalog paths are relative and normalized with `/` (no `\`, no leading `/`).

RAG paths and catalog entity references are corpus-relative identifiers, not
public URLs. They have no applicable Pages origin/base-path assertion in this
slice and are not deployment-URL verified. If a future RAG manifest carries
public URLs, it must add a named projection check and contract version rather
than reusing HTML evidence implicitly.

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

- **Markdown input is verbatim.** The source document's bytes — frontmatter,
  H1 structure, and `<Aside>` / `<Details>` authoring syntax — are preserved
  byte-for-byte. There is no metadata-owned H1 rule, no demotion pass, and no
  `:::kind` directive replacement in the v2 contract.
- **Textile input is deterministically adapted.** The Textile adapter
  (`src/textile.zig`) converts the contracted Textile body subset to
  Boris-authorable Markdown (per [textile-compatibility.md](textile-compatibility.md));
  the exported document is the adapted Markdown, not the original Textile
  bytes. Textile exports are therefore deterministic, faithful *adaptations* —
  not byte-for-byte originals. Markdown exports remain verbatim.
- **Cooklang input is deterministically adapted.** The Cooklang adapter
  (`src/cooklang.zig`) converts the contracted Cooklang body subset to
  Boris-authorable Markdown (per [cooklang-compatibility.md](cooklang-compatibility.md));
  the exported document is the adapted Markdown — an `## Ingredients` list, a
  `## Cookware` list, and `## Method` numbered steps — not the original `.cook`
  bytes with their raw `@`, `#`, and `~` sigils. A model reading the corpus
  cannot be assumed to understand Cooklang sigils, so the corpus carries the
  rendered form. Only the body is adapted: Cooklang metadata is ordinary Boris
  frontmatter and is preserved verbatim.
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

Role precedence for the reported counts is **requested → structural ancestor →
semantic-only neighbor**: a page that is both an ancestor of the projection and
the target of a semantic relation counts as structural context, never as a
semantic-only neighbor. `--scope` is a working/context-surface flag; it is
rejected with `--complete`.

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
- Oliver / HTML rendering in the RAG path
- Forensic / byte-for-byte reconstruction metadata in model-facing files
  (belongs to Context Bundle and source tooling)

---

## Acceptance

1. Export twice into two distinct directories from identical inputs; byte-compare
   every file (working and complete modes).
2. Working mode emits exactly the model-facing packs plus `manifest.json` — no
   `catalog_meta.json`, no `system/**` seeds.
3. Complete mode's `catalog_meta.json` exists, parses as JSON, and matches the
   fixed shape/order above with `schema_version: 2`.
4. Working packs: every content document is present verbatim (Markdown; H1 and
   `<Aside>` / `<Details>` preserved, no `:::kind`, no hashes); documents are
   delimited by `<!-- boris-rag-doc -->` markers; repeated exports are
   byte-identical. A source line beginning with the marker prefix fails the
   export (`SeparatorCollision`).
5. `manifest.json` exists, parses as JSON, lists every document instance with
   `part` / `part_count` / `continuation`, and carries per-document
   `source_sha256`; `sidecar_files` is `["manifest.json"]`.
6. A document larger than the pack target is split at safe Markdown boundaries
   (fences intact) with minimal `part="k/n"` reassembly metadata; an
   indivisible oversized block fails explicitly without publishing a partial
   corpus.
7. Scoped exports include the requested subtree, one-hop semantic neighbors,
   and the required transitive parent chain; unrelated pages are excluded; a
   requested page's own parent counts as structural context, not as a semantic
   neighbor.
8. Complete mode publishes INDEX/UPLOAD-GUIDE/catalog/system/content/graph with
   verbatim content pages; `catalog.jsonl` rows parse with the required keys in
   order; INDEX's catalog count and full-catalog table equal the `catalog.jsonl`
   row count, INDEX's own row included.
9. `--complete` combined with `--scope` is a usage error (exit 2).
10. Graph validation failures abort export (no partial success claim); IR and
   RAG report the same diagnostic categories for the same invalid fixture.
11. `zig build test` passes; `zig build run -- --input fixtures/content/valid
   --rag-dir /tmp/boris-rag` and `--rag --complete` succeed.
