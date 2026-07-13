---
rag_id: system/rag-export
rag_path: system/09-rag-export.md
category: system
tags: [rag, llm, grok, gemini, corpus, upload, deterministic]
related:
  - system/00-overview.md
  - system/04-components-and-admonitions.md
  - system/08-build-cli-and-layout.md
  - INDEX.md
  - UPLOAD-GUIDE.md
---

# RAG export system

Boris can generate a **Retrieval-Augmented Generation corpus**: a tree of
markdown files with stable paths, bounded frontmatter-style headers, cross-links,
and machine catalogs designed for upload into chat LLM knowledge bases (Grok,
Gemini, NotebookLM-style tools, etc.).

Normative machine contract: `docs/contracts/rag-export.md` (format `boris-rag`,
schema version `1`). Determinism is verified by dual-directory export in CI and
unit tests on the host OS; **cross-OS bit-identical corpora are not claimed**
without multi-OS CI evidence.

## Output root

Default: `rag/`

```text
rag/
  INDEX.md                 # master map — start here in a chat
  UPLOAD-GUIDE.md          # how to upload / query
  catalog.jsonl            # one JSON object per document (tooling; not a catalog row)
  catalog_meta.json        # format + schema_version + boris_version (not a catalog row)
  system/                  # how Boris works
  content/
    pages/                 # site content, path-mirrored (asides inlined)
  graph/
    entity-catalog.md      # all page entities + roles
    relations.md           # trunk → satellites edges
```

## Determinism

**Workshop analogy:** same manuscripts + same instructions → same packet.  
**Invariant:** identical inputs produce **byte-identical** corpora on a given
host. System seeds sorted by relative path; content pages and graph edges by
`entity_id`; catalog rows and INDEX tables by `rag_path`. No timestamps, random
ids, absolute paths, hostnames, or hash-map iteration order. Cross-OS
bit-identity is not claimed without multi-OS CI proof.

## Path design principles (LLM-friendly)

1. **Stable, hierarchical paths** — mirror content entity ids (`content/pages/guides/intro.md`)
2. **Self-contained segments** — YAML frontmatter holds `entity_id`, `role`, `parent_entry`, `title` (no duplicate retrieval-card tables)
3. **Machine frontmatter** — `rag_id`, `rag_path`, `category`, `tags`, `related`, `entity_id`
4. **Metadata-owned H1** — frontmatter `title` is the sole document H1; source leading H1 stripped; remaining ATX H1s demoted to H2
5. **Separate system vs content** — architecture questions hit `system/`; site copy hits `content/`
6. **Graph docs** — relations are explicit files so retrieval does not require scanning everything
7. **Asides stay on the page** — export uses `:::kind` blocks as an **export representation** only (authoring is `<Aside>`; not necessarily round-trippable)
8. **Token-efficient related** — per-page `related:` lists **direct graph neighbors only** (parent / children); `INDEX.md` is the corpus hub

## Graph validation before export

RAG reuses the shared `pipeline.compile` path (`graph.validate`) before writing
page/graph segments. Same codes as IR:

- Missing parent → `EPARENTMISSING`
- Satellite-of-satellite → `EPARENTNOTTRUNK`
- Cycles → `EPARENTCYCLE`
- Duplicate ids → `EDUPLICATEID`
- Component failures → `ECOMPONENT`

**Workshop analogy:** librarian retrieval packet — one validated catalog, stable
paths, no partial shelf after a failed audit.

## Segment categories

| category | Meaning |
|----------|---------|
| `system` | Compiler/architecture knowledge |
| `content` | Author page body + metadata (asides inlined) |
| `graph` | Catalogs and edges |
| `meta` | Index / upload guides |

## catalog_meta.json

**Workshop analogy:** edition stamp on the packet.  
**Invariant:** fixed compact JSON with `format`, `schema_version`, `boris_version`
(product version from `pipeline.boris_version`, currently `0.0.1`).

```json
{"format":"boris-rag","schema_version":1,"boris_version":"0.0.1"}
```

Present in the tree and INDEX documentation; **not** a `catalog.jsonl` entry.

## catalog.jsonl schema (pinned)

One JSON object per line, **stable field order**, sorted by `rag_path`:

```text
rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
```

| Field | Notes |
|-------|--------|
| `entity_id` | Content entity id, or `""` for system/graph/meta |
| `role` | `trunk` \| `satellite`, or `""` when N/A |
| `parent_entry` | Parent entity id for satellites, else `""` |

## Generation rules

- System docs are seeded from `docs/rag/system/*.md` (sorted by path) and normalized into `rag/system/`
- Content pages are parsed once; asides appear inline as `:::kind` export blocks in the body
- Parent graph is validated before content/graph write
- `catalog.jsonl` lists every **retrieval** document for bulk upload scripts
- Machine files (`catalog.jsonl`, `catalog_meta.json`) are not catalog rows
- `INDEX.md` is regenerated with the full sorted catalog
