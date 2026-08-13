---
title: Boris Documentation
status: published
tags: [home, zig, documentation]
---

# Markdown in. A validated graph out.

Boris is a local Zig documentation compiler. It turns Markdown into a static
HTML site, then can project the same validated content graph to JSON IR, RAG,
an AI Context Bundle, `llms.txt`, or RSS 2.0.

[[getting-started|Get started]] · [[guides/overview|Learn the content model]] ·
[[reference/commands|Open the reference]]

<Aside kind="info">

The normal path is simple: write Markdown under `content/`, run
`boris validate` when you want a no-publication preflight, then run `boris build` to
publish `dist/`. The default HTML path includes a graph-backed navigation tree,
breadcrumbs, a table of contents, copied theme assets, rendered-site search,
and target-local publication evidence.

</Aside>

## Why use Boris?

- **Local and static.** Publication is a native executable that writes files you
  can inspect, archive, or serve with any ordinary static host. Node is not part
  of the publication workflow.
- **Graph-aware.** `parent` frontmatter creates Trunk/Satellite hierarchy;
  supported wiki-links and includes are resolved before HTML is committed.
- **Closed and explicit.** Boris accepts a small author grammar instead of
  pretending to be a general YAML or MDX runtime. Exact rules live in the
  [[reference/frontmatter|frontmatter reference]].
- **One source, several projections.** HTML, IR, RAG, Context, `llms.txt`, RSS,
  and sitemap output are separate, deterministic selections over the same
  source revision.
- **In-process Markdown.** Page bodies are rendered by the Oliver library
  (pinned in `build.zig.zon`) through Boris's `src/render.zig` seam — a native
  Zig module, never a subprocess.

## The product shape

```text
Markdown + frontmatter
          │
          ▼
discover → parse → validate/freeze the graph
          │
          ├── HTML publication (default)
          ├── JSON IR, RAG, Context, or llms.txt
          └── RSS 2.0, or an HTML sitemap when selected
```

`boris validate` stops after the canonical HTML prepublication phases and
writes nothing. `boris check` answers a different question: it analyzes graph
health after validation and may report policy findings such as unreferenced
pages. [[guides/cli-and-modes|CLI & Output Modes]] explains the boundaries;
[[reference/outputs|Outputs & Artifacts]] explains what gets published.

## Choose a path

| If you want to… | Start here |
|---|---|
| Build a first site | [[getting-started|Getting Started]] |
| Create pages and links | [[guides/building-pages|Building Pages]] |
| Understand nested hierarchy | [[guides/trunk-satellite|Trunk & Satellite]] |
| Customize HTML and themes | [[guides/themes-and-layouts|Themes & Layouts]] |
| Use search in a rendered site | [[guides/search-and-ui|Search & Browser UI]] |
| Export machine-readable content | [[guides/rag-export|AI & Machine Outputs]] |
| Compare approaches or understand the design | [[comparison|Why Boris?]] and [[technology-and-rationale|Technology & Rationale]] |
| Find exact flags and diagnostics | [[reference/commands|Command Reference]] and [[reference/diagnostics|Diagnostics]] |
