---
title: Trunk & Satellite — Content Hierarchy
parent: guides/overview
status: published
tags: [guides, graph, hierarchy]
---

# Trunk & Satellite — Content Hierarchy

Boris organizes every page into one of two roles based on whether it has a `parent` key in its frontmatter. This determines where the page appears in navigation and how Boris validates the site structure.

## The two roles

**Trunk** — A page without a `parent`. It is a root node in the content graph. A site can have multiple Trunks. Each Trunk becomes a top-level item in the navigation sidebar.

**Satellite** — A page with a `parent` key. It is a child of its parent in the content graph. Satellites appear nested under their parent in navigation.

## Declaring a parent

Set `parent` to the entity id of the parent page:

```markdown
---
title: Advanced Configuration
parent: getting-started
status: published
---
```

The entity id is the file path relative to `content/`, without the `.md` extension. So:

- `content/getting-started.md` has entity id `getting-started`
- `content/guides/building-pages.md` has entity id `guides/building-pages`

## Validation rules

Boris enforces these rules before publishing:

1. **Every `parent` must resolve.** The parent's entity id must be a page that exists. If it does not exist, Boris exits with a `EGRAPH` diagnostic.

2. **No cycles.** A page cannot be its own ancestor. Boris checks for cycles and rejects them.

3. **Satellites must have exactly one parent.** A page cannot declare multiple parents.

4. **Includes and wiki-links must also resolve.** Broken references anywhere in the content tree fail the build.

<Aside kind="tip">

Run `boris check` to validate the graph without publishing. This is useful in CI pipelines where you want to verify content structure without writing any output files.

</Aside>

## Navigation output

When your HTML layout includes the `{{nav}}` marker, Boris generates a sidebar from the validated graph:

- Trunk pages appear as top-level items
- Satellite pages appear indented under their parent
- The current page is marked as active
- Ancestors of the current page are marked as ancestors

The `{{breadcrumb}}` marker generates a breadcrumb trail from the current page back to its root Trunk.

## Deep hierarchies

There is no depth limit on nesting. A Satellite can itself be the parent of other Satellites:

```text
index (Trunk)
  getting-started (Satellite of index)
  guides (Satellite of index)
    guides/overview (Satellite of guides)
    guides/building-pages (Satellite of guides)
      guides/building-pages/examples (Satellite of guides/building-pages)
```

Boris validates the full chain at graph freeze time, not page-by-page.

## Impact analysis

Use `boris impact` to see which pages depend on a given page:

```bash
./zig-out/bin/boris impact guides/overview
```

This shows all pages that have `guides/overview` in their ancestor chain, plus any pages that wiki-link or include it. Useful when you are about to rename or restructure a page.
