---
rag_id: system/data-model-page
rag_path: system/02-data-model-page.md
category: system
tags: [page, data-model, frontmatter, entity-id]
related:
  - system/03-trunk-and-satellite.md
  - system/04-components-and-admonitions.md
  - system/01-architecture-pipeline.md
---

# Data model: Page and Frontmatter

**Workshop analogy:** permanent card catalog (PageDb) vs temporary workbench
notes (Whiteboard / source buffers).  
**Invariant:** durable fields are duplicated into a retain arena; never store
raw parser slices on PageDb.

Discovery and promotion use `src/page.zig`. The IR path uses `graph.Node` with
the same entity-id and `parent` ideas.

## Durable Page fields (PageDb)

| Field | Meaning |
|-------|---------|
| `source_path` | Path relative to content root (e.g. `guides/intro.md`) |
| `output_path` | Safe path relative to output root (e.g. `guides/intro.html`) |
| `entity_id` | Stable graph key (path without extension, or `id:` override) |
| `title`, `parent`, `status`, `tags` | Promoted frontmatter copies |
| `body_offset` | Integer offset into source (not a live buffer) |

**Not** a Page field: asides / components. Those exist only as parse-time tokens
on the document segment stream.

## Entity id rules

- `content/guides/intro.md` → entity id `guides/intro`
- `content/index.md` → entity id `index`
- Extensions `.md` and `.mdx` are stripped the same way (case-sensitive)
- Single derivation: `identity.canonicalEntityId`

## Frontmatter (not YAML)

Closed, line-oriented `key: value` grammar with `---` fences. See
`docs/contracts/frontmatter.md`.

### Authoring keys (compiler dialect)

```markdown
---
title: Introduction
parent: guides/intro
status: published
tags: [guide, intro]
---
```

Keys: `id`, `title`, `parent`, `status`, `tags`. Unknown keys error.
Legacy `parentEntry` is **rejected** (`EFRONTMATTER`). There is **no** general
YAML support.

## Components (parse-time only)

Optional `<Aside kind="tip">` blocks are tokenized into the ordered segment
stream (`src/aside.zig`). They render in place (HTML path) or export as
`:::kind` (RAG). They are not graph nodes.

## PageDb

Long-lived retain arena for promoted metadata only. Scan populates paths;
promote copies frontmatter strings before source free.
