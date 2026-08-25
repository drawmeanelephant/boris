---
title: Markdown Feature Usage Register
parent: reference
status: published
tags: [reference, markdown, editorial, audit]
---

# Markdown Feature Usage Register {#feature-register}

This page records the Markdown and Boris-native constructs intentionally used
in the public documentation. It is an editorial register, not a second product
contract; [[guides/oliver-markdown|Markdown Showcase]] and the linked contracts
own syntax details.

<Aside kind="info">

The compiled site is allowed — encouraged — to *use* the surface it
documents. [[index|The homepage]] is the living gallery. Reference pages
stay scannable on purpose.

</Aside>

## Feature matrix

| Feature | Why the site uses it | Boundary | Shown live on |
|---|---|---|---|
| `&lt;Aside&gt;` callouts | Short, semantic warnings and tips | Constrained kinds; no nesting | almost every guide; all five kinds on [[guides/asides]] |
| `&lt;Details&gt;` disclosures | Optional depth without leaving the page | Required plain `summary`; no nesting | [[index]], [[guides/publishing]], [[guides/migration]], [[comparison]] |
| Wiki-links | Stable cross-page graph references | Entity ids and optional rendered heading fragments | everywhere a page name appears |
| Include directives | Shared source prose | Fragments under `content/includes/`; fences stay literal | `identity.md`, `publish-first.md`, `shared-tip.md` |
| Tables | Compact comparisons and reference data | Oliver GFM tables; theme supplies presentation | [[index]], [[guides/publishing]], [[reference/commands]] |
| Footnotes | Method notes without interrupting the main argument | Oliver footnote refs + section | [[index#footnotes]], [[comparison]], [[technology-and-rationale]] |
| Definition lists | Glossary-style term/definition pairs | Oliver definition lists | [[index#glossary]], [[guides]], [[guides/rag-export]], [[reference/relationships]] |
| Heading IAL | Stable custom anchors and classes | Oliver heading attributes; TOC reads rendered ids | [[index#gallery-ial]], `.eyebrow` / `.hero-heading` on landings |
| GFM strikethrough | Mark retired phrasing in place | Two tildes only | [[index#inline-craft]] |
| Nested lists | Procedures and hierarchies | CommonMark tight/loose rules | [[index#lists]] |
| Block quotes | Short pull quotes, not callouts | Nested `>` is a quote, not an Aside | [[index#inline-craft]], [[guides/themes-and-layouts]], [[guides/asides]] |
| Content-local images | Viewport specimens | Sibling `{stem}.assets/` rewrite | [[index#viewport-specimens]] |
| Theme presentation hooks | Eyebrow, action row, edition cards | Trusted raw HTML classes in the default theme | [[index]] |
| Rendered search index | Searchable output for the default site | Compiler-owned JSON artifact; browser consumer is theme-owned | every default HTML build |

## Product boundaries

- Boris frontmatter is closed: `id`, `title`, `parent`, `status`, `tags`,
  `relations`, `published_at`, and `summary`.
- `&lt;Aside&gt;` and `&lt;Details&gt;` are the only registered PascalCase components.
- `[[entity-id]]`, include directives, and component tokens are handled in the
  compiler pipeline around the renderer; they are not arbitrary MDX.
- Fenced examples keep component-looking and link-looking syntax literal.
- RAG `:::kind` and `:::details` blocks are export representations, not source
  authoring syntax.

## Editorial rules

1. Use a feature when it improves comprehension, comparison, setup, or a
   concrete product example — or when the page *is* the demonstration.
2. Keep reference pages scannable; do not turn every fact into a callout.
3. Put unsupported or product-off syntax in inert fenced examples and label
   the boundary explicitly.
4. Run the real compiler after edits so heading fragments, includes, graph
   edges, and rendered search inventory remain honest.
5. Do not document a publication target the registry does not name.

## Intentionally plain references

These pages favor tables, short paragraphs, and copy-pasteable examples over
decorative syntax:

- [[reference/commands|Command Reference]]
- [[reference/diagnostics|Diagnostics & Troubleshooting]]
- [[reference/frontmatter|Frontmatter Reference]]
- [[reference/outputs|Outputs & Artifacts]]
- [[reference/relationships|Relationships]]
