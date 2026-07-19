---
title: What shipped
parent: contest
status: published
tags: [build-week, features]
---

# What shipped

Boris turns one Markdown content tree into several useful, deterministic
outputs. The default is a static site under `dist/`; the other outputs are
explicit modes, not an opaque hosted service.

| Need | Boris output |
|---|---|
| A browsable documentation site | HTML with graph-aware navigation, breadcrumbs, TOC, children, layouts, assets, Asides, and Details |
| A machine-readable view of the same structure | JSON IR with typed graph edges and a reverse index |
| A retrieval-friendly corpus | RAG export with deterministic catalogs and provenance |
| Grounding for an AI workflow | Context Bundle plus `llms.txt` discovery map |
| A safer migration investigation | Standalone Zig migration labs with review manifests and bounded conversion rules |

## The compiler keeps structure honest

Author pages use closed frontmatter and a Trunk/Satellite hierarchy. Boris
checks parent references, wiki-link targets, headings, and `{{include}}`
directives before publishing. Broken structure is a compiler error, not a
quietly wrong navigation menu.

That is the project’s core distinction: Markdown remains plain text, but its
relationships are first-class and validated.

## The practical feature set

- **ApexMarkdown Unified in-process** for real Markdown rather than a toy parser.
- **Default HTML output** with zero client framework requirement.
- **Incremental, watch, bounded parallel, and multi-target builds** on the HTML path.
- **Closed native Aside and Details components**—semantic page content, not
  executable MDX.
- **Migration labs** for Astro/Starlight, WordPress, Instagram, Obsidian,
  Notion, Filed.fyi, asset names, and theme archaeology/materialization.

For the complete capability map and current limitations, see
[[guides/overview|the content-model guide]], [[guides/cli-and-modes|the CLI guide]],
and [[reference/frontmatter|the frontmatter reference]].
