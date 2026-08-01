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

**Workshop analogy:** records clerk — each Satellite files a direct card under
exactly one parent; parent cards may themselves have children.
**Invariant:** `parent` must name an existing page; cycles and missing parents
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

The value must match the direct parent’s entity id (path without extension), not the
HTML URL and not a free-form title.

## Validation (hard requirements)

Both the IR compiler (`pipeline.zig`) and RAG export (`rag.zig`) call the shared
`graph.validate` entry (duplicate ids, then topology):

| Case | Severity | Code |
|------|----------|------|
| Parent id missing from the page set | **error** | `EPARENTMISSING` |
| Parent equals own id | **error** | `EPARENTSELF` |
| Cycle in parent edges | **error** | `EPARENTCYCLE` |
| Duplicate entity id | **error** | `EDUPLICATEID` |

Parent chains may be multiple levels deep. The graph remains a rooted forest:
roots are Trunks, every page with a parent is a Satellite, and all chains must
be finite and acyclic.

Cycle detection uses a DFS **visiting (gray) set**.

Graph docs (`relations.md`) order every page hub and direct-child list by
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

1. Load the root or requested page segment under `rag/content/pages/...`.
2. Follow direct child rows whose `parent_entry` equals that page’s
   `entity_id`; recurse when the hierarchy is nested (see `graph/relations.md`).
3. Read inlined asides from those page bodies (`:::kind` blocks) — not a separate tree.
