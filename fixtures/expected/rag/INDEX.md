---
rag_id: meta/index
rag_path: INDEX.md
category: meta
tags: [index, catalog, retrieval-map]
---

# Boris RAG corpus — INDEX

Master retrieval map for the Boris complete-corpus RAG export. Upload
this directory tree to a chat LLM knowledge base. Content pages are
verbatim authoring documents (frontmatter, H1s, and `<Aside>` /
`<Details>` syntax preserved).

## Counts

| Segment | Count |
|---------|------:|
| system | 11 |
| content pages | 8 |
| graph | 2 |
| catalog entries | 22 |

## Generated artifacts

| Path | Role |
|------|------|
| `INDEX.md` | This retrieval map (catalog row) |
| `UPLOAD-GUIDE.md` | Upload notes (catalog row) |
| `catalog.jsonl` | Machine catalog — **not** a catalog row |
| `catalog_meta.json` | Format + versions — **not** a catalog row |
| `system/**` | Curated architecture seeds |
| `content/pages/**` | Verbatim content page sources |
| `graph/entity-catalog.md` | Entity table |
| `graph/relations.md` | Parent hierarchy edges |

## Full catalog

| rag_path | category | title | entity_id |
|----------|----------|-------|-----------|
| `UPLOAD-GUIDE.md` | meta | Upload guide — Grok, Gemini, and similar chat LLMs | — |
| `content/pages/empty-no-fm.md` | content | empty-no-fm | `empty-no-fm` |
| `content/pages/hierarchy-great-grandchild.md` | content | Hierarchy Great-Grandchild | `hierarchy-great-grandchild` |
| `content/pages/hierarchy-leaf.md` | content | Hierarchy Leaf | `hierarchy-leaf` |
| `content/pages/hierarchy-mid.md` | content | Hierarchy Mid | `hierarchy-mid` |
| `content/pages/hierarchy-trunk.md` | content | Hierarchy Trunk | `hierarchy-trunk` |
| `content/pages/home.md` | content | Home Trunk | `home` |
| `content/pages/nested/deep/page.md` | content | Nested Deep Page | `nested/deep/page` |
| `content/pages/satellite-child.md` | content | Child Satellite | `satellite-child` |
| `graph/entity-catalog.md` | graph | Entity catalog | — |
| `graph/relations.md` | graph | Graph relations (parent hierarchy) | — |
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
or random ids. Content documents are complete authoring sources:
frontmatter and H1s are preserved, and `<Aside>` / `<Details>`
remain authoring syntax (no `:::kind` export representation).

### catalog_meta.json

```json
{"format":"boris-rag","schema_version":2,"boris_version":"0.8.1"}
```
