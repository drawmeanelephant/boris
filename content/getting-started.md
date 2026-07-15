---
title: Getting Started with Boris
status: published
tags: [setup, cli]
---

# Getting Started

Build Boris, compile this sample site, and try the three product modes.

## Prerequisites

- **Zig 0.16+** (CI pin: 0.16.0)
- **CMake** at *compile time only* (builds vendored ApexMarkdown static libs)

## First site build

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
./zig-out/bin/boris --quiet          # HTML → dist/
```

Open `dist/index.html` (or serve `dist/` with any static file server). You should
see site nav on the left, breadcrumb, and a page TOC when the body has headings.

## Three modes

| Mode | Command | Output |
|------|---------|--------|
| **HTML (default)** | `./zig-out/bin/boris` | `dist/` |
| **JSON IR** | `./zig-out/bin/boris --out .boris` | `.boris/` |
| **RAG corpus** | `./zig-out/bin/boris --rag` | `rag/` |

```bash
./zig-out/bin/boris --out .boris --quiet
./zig-out/bin/boris --rag --quiet
```

<Aside kind="tip">

HTML helpers (valid alone, no extra mode flag): `--watch`, `--incremental`,
`--jobs N` (default jobs is still 1). See [CLI and modes](guides/cli-and-modes.html).

</Aside>

## What you need as an author

1. Markdown under `content/` (case-sensitive `.md` / `.mdx`).
2. Closed frontmatter — only `id`, `title`, `parent`, `status`, `tags`
   ([reference](reference/frontmatter.html)).
3. Optional layout chrome in `layouts/main.html` (`{{content}}` required;
   `{{nav}}` / `{{breadcrumb}}` / `{{title}}` / `{{toc}}` optional).
4. Optional includes and wiki-links (expanded before Apex):

```markdown
{{include includes/shared-tip.md}}

See also [[guides/overview|the content model]].
```

{{include includes/shared-tip.md}}

Next: the [[guides/overview|content model]] or jump straight to
[[guides/trunk-satellite|Trunk vs Satellite]].
