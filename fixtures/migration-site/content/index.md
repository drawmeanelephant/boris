---
title: Contoso Product Documentation
status: published
tags: [home, migration]
---

# Contoso Docs

Welcome to the **Contoso** product documentation sample — a realistic tree for
migrating an existing Markdown site into Boris.

{{include includes/migration-banner.md}}

## Start here

| Path | Why it matters for migration |
|------|------------------------------|
| [[guides/getting-started|Getting started]] | First successful Boris HTML build |
| [[concepts/trunk-satellite|Trunk / Satellite]] | Graph model replaces flat menus |
| [[reference/frontmatter|Frontmatter]] | Closed five-key grammar only |
| [[cookbook/rename-pages|Rename checklist]] | Safe ID and parent rewrites |

## What this fixture exercises

- One-level **Trunk → Satellite** parents (no satellite-of-satellite)
- Include fragments under `includes/` (not pages)
- Wiki links by entity id, including heading fragments
- Theme layout slots + page-relative theme assets
- Unicode titles/headings, punctuation, deep paths, case-sensitive IDs

Example author syntax (literal in fences only):

```markdown
{{include includes/shared-callout.md}}
[[guides/getting-started|Getting started]]
[[guides/heading-fragments#hello-world]]
```

## Section map

- [[guides|Guides]] — authoring and linking
- [[reference|Reference]] — CLI, IDs, graph rules
- [[concepts|Concepts]] — graph vocabulary
- [[ops|Operations]] — incremental, jobs, multi-target
- [[cookbook|Cookbook]] — convert from other SSGs
- [[special/CaseDemo|Case-sensitive ID demo]] · [[special/cafe-notes|Unicode body demo]]

## Home anchors for fragment demos

### Migration goals

Ship static HTML without a Node SSG stack.

### Success criteria

Graph validates; wiki targets resolve; theme assets copy into the HTML root.
