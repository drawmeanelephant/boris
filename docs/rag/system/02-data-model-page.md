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

The HTML/RAG path uses `Page` (`src/page.zig`). The IR compiler path uses
`graph.Node` / pipeline page entries with the same entity-id and parent ideas.

## Page fields (HTML / RAG `Page`)

| Field | Type (concept) | Meaning |
|-------|----------------|---------|
| `source_path` | string | Path relative to `content/` (e.g. `guides/intro.md`) |
| `output_path` | string | Path relative to `dist/` (e.g. `guides/intro.html`) |
| `entity_id` | string | Stable graph key (path without extension) |
| `frontmatter` | object | Title, `parent_entry`, extras |
| `raw_source` | string | Full file (when retained) |
| `body_md` | string | Markdown after frontmatter |

**Not** a Page field: asides / components. Those exist only as parse-time tokens
on the document segment stream. The Page model does not require a fixed component list.

## Entity id rules

- `content/guides/intro.md` → entity id `guides/intro`
- `content/index.md` → entity id `index`
- Extensions `.md` and `.mdx` are stripped the same way (case-sensitive)
- Entity ids preserve letter case; case-only collisions → `E_ENTITY_CASE_COLLISION`
- Single derivation: `pathutil.canonicalEntityId`

## Frontmatter (not YAML)

Closed, line-oriented `key: value` grammar with `---` fences. See
`docs/contracts/frontmatter.md`.

### Compiler path (`frontmatter.zig`) — preferred for new content

```markdown
---
title: Introduction
parent: guides/intro
status: published
tags: [guide, intro]
---
```

Keys: `id`, `title`, `parent`, `status`, `tags`. Unknown keys error.
Legacy `parentEntry` / `parent_entry` are **rejected** here.

### HTML / RAG path (`parser.zig`)

Accepts `parent` **or** `parentEntry` **or** `parent_entry` (not together).
Same closed scalar grammar; dual aliases → `duplicate_key`.

There is **no** general YAML support and no silent “extras for forward compat”
on either path (except recognized `id` stored for RAG override on the parser path).

## Components (parse-time only)

Optional registered blocks such as `<Aside kind="tip">` are tokenized into the
ordered segment stream. They render in place and are not graph nodes.

## PageDb

`PageDb` holds:

- `pages: ArrayList(Page)` — spine allocated with the backing GPA
- `arena` — long-lived arena for path strings and promoted metadata

Scan populates paths only; compile/RAG parse fills relational metadata.
