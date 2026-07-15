---
rag_id: meta/index
rag_path: INDEX.md
category: meta
tags: [index, catalog, retrieval-map]
---

# Boris RAG corpus — INDEX

Master retrieval map for the Boris product RAG pack. Upload this
directory tree to a chat LLM knowledge base.

## Counts

| Segment | Count |
|---------|------:|
| system | 11 |
| content pages | 4 |
| graph | 2 |
| catalog entries | 19 |

## Generated artifacts

| Path | Role |
|------|------|
| `INDEX.md` | This retrieval map (catalog row) |
| `UPLOAD-GUIDE.md` | Upload notes (catalog row) |
| `catalog.jsonl` | Machine catalog — **not** a catalog row |
| `catalog_meta.json` | Format + versions — **not** a catalog row |
| `system/**` | Curated architecture seeds |
| `content/pages/**` | Content page segments |
| `graph/entity-catalog.md` | Entity table |
| `graph/relations.md` | Trunk → Satellite edges |

## Full catalog

| rag_path | category | title | entity_id |
|----------|----------|-------|-----------|
| `INDEX.md` | meta | Boris RAG corpus — INDEX | — |
| `UPLOAD-GUIDE.md` | meta | Upload guide — Grok, Gemini, and similar chat LLMs | — |
| `content/pages/empty-no-fm.md` | content | empty-no-fm | `empty-no-fm` |
| `content/pages/home.md` | content | Home Trunk | `home` |
| `content/pages/nested/deep/page.md` | content | Nested Deep Page | `nested/deep/page` |
| `content/pages/satellite-child.md` | content | Child Satellite | `satellite-child` |
| `graph/entity-catalog.md` | graph | Entity catalog | — |
| `graph/relations.md` | graph | Graph relations (Trunk → Satellite) | — |
| `system/00-overview.md` | system | Boris overview | — |
| `system/01-architecture-pipeline.md` | system | Architecture and compile pipeline | — |
| `system/02-data-model-page.md` | system | Data model: Page and Frontmatter | — |
| `system/03-trunk-and-satellite.md` | system | Trunk and Satellite graph model | — |
| `system/04-components-and-admonitions.md` | system | Components and admonitions | — |
| `system/05-memory-whiteboard.md` | system | Memory: the Whiteboard strategy | — |
| `system/06-apex-native-engine.md` | system | Apex: native C-ABI markdown engine | — |
| `system/07-zero-copy-assembly.md` | system | Zero-copy layout splicing | — |
| `system/08-build-cli-and-layout.md` | system | Build system, CLI, and layout contract | — |
| `system/09-rag-export.md` | system | RAG export system | — |
| `system/10-name-and-metaphor.md` | system | Name and metaphor | — |

## Catalog schema (stable field order)

```text
rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
```

Rows sorted by `rag_path`. No timestamps, absolute paths, hostnames,
or random ids. Content title H1 is metadata-owned (frontmatter `title`
else entity id). Source leading H1 stripped; remaining ATX H1s demoted
to H2. Parsed `<Aside>` callouts are emitted as `:::kind` blocks
(export representation only — not round-trippable authoring syntax).

### catalog_meta.json

```json
{"format":"boris-rag","schema_version":1,"boris_version":"0.2.1"}
```
