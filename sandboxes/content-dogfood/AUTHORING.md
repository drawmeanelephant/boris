# Authoring rules (sandbox)

These rules are **mechanical**. Boris will exit 1 if you violate them.  
There is no “compiler bug” for nested asides or freeform frontmatter.

---

## Frontmatter — closed set only

Allowed keys **exactly**: `id`, `title`, `parent`, `status`, `tags`.

```md
---
title: My page title
parent: guides/overview
status: published
tags: [guides, graph]
---
```

**Forbidden** (unknown key → `EFRONTMATTER`):

- `parentEntry`, `parent_entry`
- nested YAML, multiline scalars, anchors, arbitrary keys
- unquoted weird values for closed enums

Rules of thumb:

| Role | Frontmatter |
|------|-------------|
| **Trunk** | Omit `parent` |
| **Satellite** | `parent: <trunk-entity-id>` |

- No satellite-of-satellite, no self-parent, no missing parent, no cycles.
- Entity id defaults to path without `.md` (`guides/asides.md` → `guides/asides`).
- Prefer path-derived ids; only set `id:` when intentional.
- `status`: only `draft` | `published` | `archived` if present.
- `tags`: only list form `[a, b, "c"]`.

Do **not** put broken “teaching” pages that fail graph validation in this tree.

---

## Aside — only registered component

### Live Aside (real component)

```md
<Aside kind="tip" id="stable-anchor">

Body markdown here. The closing tag must start a line.

</Aside>
```

- Kinds: `note`, `tip`, `info`, `warning`, `danger` (default `note`).
- Optional `id`: `[A-Za-z0-9][A-Za-z0-9_-]*` max 64.
- Values **double-quoted**. No nested asides. No other PascalCase tags.
- Asides stay **in document order** — not graph nodes, not separate pages.

### Critical: docs-about-docs

The tokenizer treats **any** bare `<Aside…` or `<PascalCase…` **outside fenced
code** as a real tag — including:

- mid-sentence “prose”
- text inside another open Aside
- “inline code” that still contains the angle-bracket form (do not rely on it)

**Safe:**

```md
Talk about the Aside component in words.

Show syntax only inside a fence:

\`\`\`html
<Aside kind="tip">

Hello

</Aside>
\`\`\`
```

**Unsafe (will fail compile):**

```md
We support `<Aside>` mid-sentence.
Unknown tags like <Broside> or <Figure> fail.
```

If you need to mention illegal tags, use **words without angle brackets**:
“Broside” and “Figure,” not `<Broside>`.

Inside fenced code, tags are literal. That is the only safe place for examples.

---

## Markdown / Apex showcase

Use real Unified features where they teach the product:

| Feature | Sample content? |
|---------|-----------------|
| Headings, lists, links, emphasis | Yes |
| Fenced code + language tags | Yes |
| Tables | Yes (≥1 real table) |
| Footnotes | Yes (≥1 page) |
| Task lists / nested lists | Where natural |
| Math | Optional small example |
| Arbitrary MDX / JSX / executable components | **No** |
| `:::kind` as **authoring** | **No** (RAG export only) |

---

## Links

- Output: `guides/asides.md` → `…/guides/asides.html`
- Prefer site-relative HTML links: `[Asides](asides.html)`, `[Home](../index.html)`
- Do not leave author CTAs as raw `.md` paths unless labeled as source paths.

---

## Voice

- Product name: **Boris**. Metaphor Load → Roll → Ignite → Reset is fine.
- Honest phase: HTML default + Apex Unified + graph-aware **site nav** shipped;
  in-page heading TOC still roadmap — don’t claim auto-TOC if you don’t see it.
- Direct, technical, complete sentences. Prefer fewer excellent pages over stubs.
