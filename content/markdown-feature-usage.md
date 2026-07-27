---
title: Markdown Feature Usage Register
parent: reference
status: published
tags: [reference, markdown, editorial, audit]
---

# Markdown Feature Usage Register

This document tracks every Markdown feature used across the Boris documentation site, its editorial rationale, support tier, rendering caveats, and plain page justifications.

---

## 1. Feature Usage Matrix

| Feature | Pages Using It | Editorial Rationale | Support Tier | Rendering / Export Caveats |
| :--- | :--- | :--- | :--- | :--- |
| **Callout `&lt;Aside&gt;` Components** | `index.md`, `getting-started.md`, `comparison.md`, `overview.md`, `building-pages.md`, `asides.md` | Provide structured, non-disruptive warnings, tips, and layer summaries | **Product Core** | Converted to `:::kind` format in RAG export; rejected if nested |
| **Wiki-Links (`&#91;&#91;id&#93;&#93;`)** | `index.md`, `getting-started.md`, `comparison.md`, `overview.md`, `building-pages.md`, `rag-export.md` | Demonstrate fail-loud graph-aware cross-referencing | **Product Core** | Verified during Roll phase before rendering; dead links exit 1 |
| **Transclusion Includes (`&#123;&#123;include path&#125;&#125;`)** | `getting-started.md`, `apex-markdown.md` | Single-source shared authoring tips across pages | **Product Core** | Expanded in memory before Apex; literal inside code fences |
| **Definition Lists** | `index.md`, `overview.md`, `trunk-satellite.md`, `technology-and-rationale.md` | Define core terminology cleanly without verbose headers | **Engine Feature** | Rendered as HTML `<dl><dt><dd>`; flattened to prose paragraphs in text exports |
| **Task Lists** | `index.md`, `getting-started.md`, `apex-markdown.md` | Provide interactive, step-by-step setup validation checklists | **Engine Feature** | Rendered as HTML checkboxes `<input type="checkbox">` |
| **Footnotes (`[^label]`, `^[inline]`)** | `comparison.md`, `technology-and-rationale.md`, `apex-markdown.md` | Keep methodology and memory allocation details from cluttering prose | **Engine Feature** | Definitions hoisted to page bottom with back-links in HTML |
| **Advanced Tables (rowspan/colspan/caption)** | `comparison.md`, `apex-markdown.md` | Structure complex multi-dimensional architectural comparisons cleanly | **Engine Feature** | Requires CSS styling in theme layout for alignment and borders |
| **Critic Markup (`{++add++}`, `{--del--}`)** | `migration.md`, `apex-markdown.md` | Show visual revision diffs during SSG migration | **Engine Feature** | Rendered as `<ins>` and `<del>` HTML tags |
| **Stable Heading IDs (`{#id}`)** | `building-pages.md`, `commands.md`, `apex-markdown.md` | Ensure stable deep-link anchors across releases | **Engine Feature** | Embedded as `id="id"` on heading HTML tags |

---

## 2. Intentionally Plain Pages & Editorial Rationale

The following pages are kept intentionally plain (using standard headings, concise prose, and clean code blocks without decorative Markdown features):

| Page Path | Primary Purpose | Editorial Rationale for Plain Presentation |
| :--- | :--- | :--- |
| `content/reference/commands.md` | Complete CLI Command & Flag Reference | Technical reference tool. Authors and agents need uncluttered flag tables and rapid scanning without visual distraction. |
| `content/reference/diagnostics.md` | Error Code & Diagnostic Reference | Emergency troubleshooting guide. Needs raw, un-adorned diagnostic matrices and copy-pasteable fix steps. |
| `content/reference/frontmatter.md` | Closed Frontmatter Grammar Spec | Specification contract. Enforces closed grammar rules; requires high visual clarity and zero decorative overhead. |
| `content/reference/outputs.md` | Build Artifact & Schema Specification | Programmatic schema documentation. Needs dense tables and code blocks showing JSON IR / RAG schemas. |
| `content/reference/relationships.md` | Content Topology & Relationship Rules | Graph relationship spec. Plain tabular presentation prevents ambiguity in parent chain and wiki-link rules. |

---

## 3. Rejection & Quality Audit

Every Markdown feature used on this site satisfies the following quality criteria:

1. **No Gratuitous Clutter:** Every callout, table, footnote, and definition list serves a specific editorial purpose (comprehension, comparison, setup, or proof).
2. **Source Maintainability:** Raw Markdown source files remain clean, readable, and easy to update.
3. **Machine Export Integrity:** All features render cleanly into RAG corpus Markdown, JSON IR graph nodes, and single-pass Context bundles without corrupting agent parsing.
