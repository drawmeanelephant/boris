---
rag_id: system/trunk-and-satellite
rag_path: system/03-trunk-and-satellite.md
category: system
tags: [graph, trunk, satellite, parent, relations]
related:
  - system/02-data-model-page.md
  - system/04-components-and-admonitions.md
  - system/10-name-and-metaphor.md
  - graph/entity-catalog.md
  - graph/relations.md
---

# Trunk and Satellite graph model

Boris does **not** treat the content tree as a flat list of unrelated files. It
uses a **Trunk and Satellite** relational model.

**Workshop analogy:** records clerk — each satellite files a direct card under
exactly one trunk; no satellite-of-satellite filing.  
**Invariant:** `parent` must name an existing Trunk; cycles and missing parents
are hard errors (`EPARENT*`).

## Definitions

- **Trunk** — a canonical page with no parent foreign key. Primary document in the graph.
- **Satellite** — a page whose frontmatter declares a parent entity id. Supporting material (tips, errata, deep-dives).

## Foreign key

**Author key (only):**

```markdown
parent: guides/intro
```

Legacy names `parentEntry` / `parent_entry` are **rejected** as unknown keys
(`EFRONTMATTER`) on every product parse path (IR, HTML, RAG input). RAG export
may still emit a catalog field named `parent_entry` for the same parent id —
that is packaging, not author grammar.

The value must match the trunk’s entity id (path without extension), not the
HTML URL and not a free-form title.

## Validation (hard requirements)

Both the IR compiler (`pipeline.zig`) and RAG export (`rag.zig`) call the shared
`graph.validate` entry (duplicate ids, then topology):

| Case | Severity | Code |
|------|----------|------|
| Parent id missing from the page set | **error** | `EPARENTMISSING` |
| Parent equals own id | **error** | `EPARENTSELF` |
| Parent exists but is itself a satellite (multi-hop) | **error** | `EPARENTNOTTRUNK` |
| Cycle in parent edges | **error** | `EPARENTCYCLE` |
| Duplicate entity id | **error** | `EDUPLICATEID` |

v0.1 is **one-level only**: satellites attach to trunks. Satellite-of-satellite
is a hard error, not a multi-hop tree feature.

Cycle detection uses a DFS **visiting (gray) set**.

Graph docs (`relations.md`) order trunk hubs and satellite lists by
**`entity_id` lexicographic** order for deterministic builds.

## Role detection

```text
if parent is set → role = "satellite"
else             → role = "trunk"
```

## Why this exists

Folder hierarchy alone cannot express “this tip pack belongs to that guide”
when files live as siblings or in parallel trees. Explicit foreign keys make
the graph LLM-readable and compile-time queryable.

## Example

| File | entity_id | parent | role |
|------|-----------|--------|------|
| `content/guides/intro.md` | `guides/intro` | (none) | trunk |
| `content/guides/intro-tips.md` | `guides/intro-tips` | `guides/intro` | satellite |
| `content/index.md` | `index` | (none) | trunk |

## What is *not* a graph node

Asides / admonitions are **in-page content**, not Trunk or Satellite entities.
They do not get separate entity ids or RAG fragment documents.

## Retrieval hints for LLMs

When answering questions about a guide:

1. Load the trunk segment under `rag/content/pages/...`
2. Load satellites whose `parent_entry` equals that trunk `entity_id` (see `graph/relations.md`)
3. Read inlined asides from those page bodies (`:::kind` blocks) — not a separate tree
