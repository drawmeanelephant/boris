---
title: Migration Guide
parent: learn
status: published
tags: [guides, migration]
---

# Migration Guide

Migration is a reviewable sequence, not a promise that one command can absorb
any documentation framework. Start with a bounded slice, preserve what needs a
decision, and only then make it a Boris content tree.

## The safe path

1. **Inventory the old site.** Record pages, sidebar structure, shared
   snippets, link styles, frontmatter keys, and assets.
2. **Choose a small representative slice.** Include a landing page, a nested
   page, a shared fragment, and an asset if the original site uses them.
3. **Close the authoring grammar.** Keep only supported frontmatter, turn
   hierarchy into `parent`, and convert internal reader links to wiki-links.
4. **Build and inspect.** Run `boris`, then `boris check`; fix every explicit
   diagnostic rather than preserving a silently broken convention.
5. **Expand deliberately.** Treat unsupported MDX, custom runtime widgets,
   third-party navigation, and analytics as migration decisions—not compiler
   features that arrived by accident.

## Translate the common shapes

| Existing pattern | Boris shape |
|---|---|
| CMS/SSG sidebar hierarchy | Trunks and Satellites with `parent:` |
| Shared Markdown partial | A content-root-relative include directive |
| Internal `.md` route link | A Boris wiki-link by stable entity id |
| Admonition extension | A supported Aside callout |
| Collapsible prose | A registered Details block |
| Page-owned image or diagram | A sibling `page.assets/` directory |
| Arbitrary YAML or executable MDX | Review and rewrite; it is outside Boris’s author grammar |

## What Boris deliberately does not import

Boris does not pretend to be a universal converter. It does not run a Node
theme, execute MDX, infer ambiguous metadata, or bring an old site’s runtime
dependencies into a publishing build. The optional migration labs are
read-only developer aids: they produce inventories, draft material, and review
reports for named source shapes. A green report is evidence for human review,
not a claim that the conversion is done.

For the long-form maintainer procedure and lab commands, use the
[repository migration guide](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/MIGRATION.md).
