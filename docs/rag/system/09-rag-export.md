---
rag_id: system/rag-export
rag_path: system/09-rag-export.md
category: system
tags: [rag, llm, grok, gemini, corpus, upload, deterministic, working-context]
related:
  - system/00-overview.md
  - system/04-components-and-admonitions.md
  - system/08-build-cli-and-layout.md
  - INDEX.md
  - UPLOAD-GUIDE.md
---

# RAG export system

Boris can generate a **working-context pack** for AI site authoring: a small
set of bounded Markdown files containing complete, verbatim **site** documents
(never the `docs/rag/system` corpus — that belongs to the complete-corpus
export), plus a sidecar manifest that is not meant to be uploaded. It can also
export the **complete corpus** explicitly.

Normative machine contract: `docs/contracts/rag-export.md` (format
`boris-rag`, schema version `2`). Determinism is verified by dual-directory
export in CI and unit tests on the host OS; **cross-OS bit-identical corpora
are not claimed** without multi-OS CI evidence.

## Why working packs?

Upload systems charge per attachment, cap attachment counts, and share one
context window with the conversation. A useful working context is therefore:

- **few files** — whole documents packed into bounded upload files, not one
  attachment per page plus indexes and manifests;
- **verbatim documents** — the model reads the site's real frontmatter, H1s,
  and `<Aside>` / `<Details>` authoring syntax, and can hand generated Markdown
  straight back to Boris validation;
- **lean** — no per-piece hashes, byte counts, graph reports, or upload guides
  in the model-facing bytes; integrity lives in the sidecar manifest.

## Output root (working context, default)

Default: `rag/`

```text
rag/
  working-1.md              # model-facing upload packs (bounded, complete docs)
  manifest.json             # sidecar — NOT normally uploaded (scope, counts, hashes)
```

Working mode emits exactly these two shapes of file. `catalog_meta.json` is
complete-mode surface only; the manifest already records format, schema
version, and Boris version.

Documents inside a pack are delimited by marker lines:

```text
<!-- boris-rag-doc: id="content/guides/intro" source="guides/intro.md" category="content" -->
```

Split documents add `part="k/n"`. Reassembly is the marker-free concatenation
of the parts in order. A source line beginning (after leading whitespace) with
the marker prefix is rejected (`SeparatorCollision`) so packs are unambiguous
by construction.

## Complete-corpus export (`--rag --complete`)

```text
rag/
  INDEX.md                 # master map — start here in a chat
  UPLOAD-GUIDE.md          # how to upload / query
  catalog.jsonl            # one JSON object per document (tooling; not a catalog row)
  catalog_meta.json        # format + schema_version + boris_version (not a catalog row)
  system/                  # how Boris works (verbatim seeds)
  content/
    pages/                 # site content, path-mirrored (verbatim authoring sources)
  graph/
    entity-catalog.md      # all page entities + roles
    relations.md           # direct parent → child edges
```

Content pages and system seeds are **verbatim authoring documents** (Markdown;
Textile input is deterministically adapted to Boris-authorable Markdown): H1s
and `<Aside>` / `<Details>` syntax are preserved, and there is no `:::kind`
export representation.

`--complete` rejects `--scope`: the complete export is the entire validated
corpus. `INDEX.md` is itself a catalog row, and its catalog count and
full-catalog table equal the `catalog.jsonl` row count.

## Determinism

**Workshop analogy:** same manuscripts + same instructions → same packet.
**Invariant:** identical inputs produce **byte-identical** corpora on a given
host. Working packs order content pages by entity id (no seeds); complete mode
sorts system seeds by relative path, content pages and graph edges by entity
id, and catalog rows by rag_path (INDEX included). No timestamps, random ids,
absolute paths, hostnames, or hash-map iteration order. Cross-OS bit-identity
is not claimed without multi-OS CI proof.

## Authoring fidelity (both modes)

1. **Verbatim Markdown, adapted Textile** — Markdown payloads are the actual
   authoring file, frontmatter included; Textile payloads are the deterministic
   adapted Boris-authorable Markdown.
2. **H1s preserved** — no metadata-owned H1, no stripping, no demotion.
3. **Components preserved** — `<Aside>` and `<Details>` stay authoring syntax.
4. **No export dialect** — `:::kind` blocks are gone from product RAG.
5. **Whole documents first** — only a single document larger than the pack
   target is split, at safe Markdown boundaries outside fenced code.

## Scope

`--scope` projects the requested subtree plus one-hop semantic neighbors and
the required transitive parent chain on the working/context surfaces; it is
rejected with `--complete`. Unrelated pages stay out of the upload files.
`--scope` counts are reported in the export summary and the manifest, with
role precedence requested → structural ancestor → semantic-only neighbor.

## Graph validation before export

RAG reuses the shared `pipeline.compile` path (`graph.validate`) before writing
any graph-dependent artifact. Same codes as IR:

- Missing parent → `EPARENTMISSING`
- Nested Satellite parents are valid; every chain must terminate at a Trunk
- Retired `EPARENTNOTTRUNK` is not emitted by the current validator
- Cycles → `EPARENTCYCLE`
- Duplicate ids → `EDUPLICATEID`
- Component failures → `ECOMPONENT`

**Workshop analogy:** librarian retrieval packet — one validated catalog, stable
paths, no partial shelf after a failed audit.

## catalog_meta.json (complete mode)

**Workshop analogy:** edition stamp on the packet.
**Invariant:** fixed compact JSON with `format`, `schema_version`, `boris_version`
(product version from `pipeline.boris_version`, currently `0.8.2`).

```json
{"format":"boris-rag","schema_version":2,"boris_version":"0.8.2"}
```

Emitted on complete-corpus exports and documented in INDEX; **not** a
`catalog.jsonl` entry. Working mode records the same three fields inside
`manifest.json` and does not emit this file.

## manifest.json schema (working context, pinned)

The sidecar records what the model-facing packs intentionally omit:

| Field | Notes |
|-------|--------|
| `scope` | Requested entity id / prefix (`""` when unscoped) |
| `selected_page_count` | Pages in the working set |
| `structural_parent_count` / `semantic_neighbor_count` | Why extra pages were included |
| `pack_target` | Working-pack byte target |
| `approximate_tokens` | Deterministic estimate: model-facing bytes / 4 |
| `upload_files` | Pack paths, byte counts, document counts |
| `documents` | Per-document-instance records: `part` / `part_count` / `continuation`, `bytes`, `source_sha256` |

## Generation rules

- Content pages are verbatim and ordered by entity id; system seeds appear
  only in complete mode, sorted and included verbatim.
- Whole documents pack greedily into bounded `working-N.md` files; only an
  oversized single document is split (at blank-line / heading boundaries
  outside fenced code, with minimal `part="k/n"` reassembly metadata).
- `catalog.jsonl` (complete mode) lists every retrieval document for bulk
  upload scripts.
- Machine files (`catalog.jsonl`, `catalog_meta.json`, `manifest.json`) are
  not catalog rows, and `manifest.json` is explicitly not intended for upload.
