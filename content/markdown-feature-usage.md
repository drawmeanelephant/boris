---
title: Markdown Feature Usage Register
parent: reference
status: published
tags: [reference, markdown, editorial, audit]
---

# Markdown Feature Usage Register

This page records the Markdown and Boris-native constructs intentionally used
in the public documentation. It is an editorial register, not a second product
contract; [[guides/apex-markdown|Apex Markdown Showcase]] and the linked
contracts own syntax details.

## Feature matrix

| Feature | Why the site uses it | Boundary |
|---|---|---|
| `&lt;Aside&gt;` callouts | Short, semantic warnings and tips | Constrained kinds; no nesting |
| `&lt;Details&gt;` disclosures | Optional detail without leaving the page | Required plain `summary`; no nesting |
| Wiki-links | Stable cross-page graph references | Entity ids and optional rendered heading fragments |
| Include directives | Shared source prose | Fragments under `content/includes/`; fences stay literal |
| Tables | Compact comparisons and reference data | ApexMarkdown rendering; theme supplies presentation |
| Footnotes | Method notes without interrupting the main argument | ApexMarkdown output |
| Task lists | Setup/checklist communication | Static HTML checkboxes |
| Heading IAL | Stable custom anchors and classes | Apex heading syntax; TOC reads rendered ids |
| Critic markup | Migration examples | Apex rendering only |
| Math | Technical notation | Theme-dependent CSS/JS; not required by the compiler |
| Rendered search index | Searchable output for the default site | Compiler-owned JSON artifact; browser consumer is theme-owned |

## Product boundaries

- Boris frontmatter is closed: `id`, `title`, `parent`, `status`, `tags`,
  `relations`, `published_at`, and `summary`.
- `&lt;Aside&gt;` and `&lt;Details&gt;` are the only registered PascalCase components.
- `[[entity-id]]`, include directives, and component tokens are handled in the
  compiler pipeline around Apex; they are not arbitrary MDX.
- Fenced examples keep component-looking and link-looking syntax literal.
- RAG `:::kind` and `:::details` blocks are export representations, not source
  authoring syntax.

## Editorial rules

1. Use a feature when it improves comprehension, comparison, setup, or a
   concrete product example.
2. Keep reference pages scannable; do not turn every fact into a callout.
3. Put unsupported or product-off Apex syntax in inert fenced examples and
   label the boundary explicitly.
4. Run the real compiler after edits so heading fragments, includes, graph
   edges, and rendered search inventory remain honest.

## Intentionally plain references

These pages favor tables, short paragraphs, and copy-pasteable examples over
decorative syntax:

- [[reference/commands|Command Reference]]
- [[reference/diagnostics|Diagnostics & Troubleshooting]]
- [[reference/frontmatter|Frontmatter Reference]]
- [[reference/outputs|Outputs & Artifacts]]
- [[reference/relationships|Relationships]]
