---
title: Getting Started
status: published
tags: [setup, quickstart, cli]
---

# Getting Started with Boris

Boris compiles the Markdown in `content/` into a static documentation site.
The shortest useful path is: build Boris, preflight the sample content, build
the site, and open the resulting HTML.

<Aside kind="info">

The default HTML build also publishes a rendered-search artifact and
target-local publication evidence. You do not need to run a second search
index command for a normal Boris build.

</Aside>

{{include includes/shared-tip.md}}

## 1. Build Boris

Building Boris itself requires:

- **Zig 0.16+** — the compiler language Boris is written in. Markdown
  rendering uses the Oliver library, pinned in `build.zig.zon` and fetched by
  Zig at build time — no CMake or other host tools are required.

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
```

The binary is written to `./zig-out/bin/boris`.

## 2. Inspect the sample content

Pages are ordinary Markdown files under `content/`. The path without its
extension is normally the page's entity id: `content/guides/overview.md`
becomes `guides/overview`. Start with
[[guides/building-pages|Building Pages]] if you want to add a page.

## 3. Preflight without publishing

```bash
./zig-out/bin/boris validate --quiet
```

`validate` runs Boris's authoritative HTML source and configuration checks,
including graph resolution, component parsing, layout loading, and bounded
render preparation. It creates no HTML, cache, search, or publication-evidence
files.

## 4. Publish the static site

```bash
./zig-out/bin/boris build --quiet
```

The default target is `dist/`. Open `dist/index.html` directly for reading, or
serve the `dist/` directory with any static file server when you want the
browser search UI to fetch its same-origin index.

## What to learn next

- [[guides/overview|Content Model & Pipeline]] — how discovery, graph
  validation, rendering, and projections fit together.
- [[guides/cli-and-modes|CLI & Output Modes]] — build, validate, watch, graph
  analysis, layouts, and machine exports.
- [[reference/frontmatter|Frontmatter Reference]] — the complete closed author
  grammar.
- [[reference/outputs|Outputs & Artifacts]] — HTML, search, IR, RAG, Context,
  `llms.txt`, RSS, sitemap, and publication evidence.
