---
title: Frontmatter Reference
parent: reference
status: published
tags: [reference, frontmatter]
---

# Frontmatter Reference

Boris uses a **closed frontmatter grammar**. Only the five keys listed here are accepted. Unknown keys produce an `EFRONTMATTER` diagnostic and fail the build.

## Accepted keys

| Key | Type | Required | Default | Description |
|---|---|---|---|---|
| `title` | string | Yes | — | The page title. Used in the browser tab, navigation sidebar, breadcrumbs, `llms.txt`, and IR |
| `parent` | string | No | — | Entity id of the parent page. Omit for Trunk pages |
| `status` | string | No | `published` | `published` or `draft`. Draft pages are excluded from all outputs |
| `id` | string | No | derived from path | Override the entity id. Must be unique across the site |
| `tags` | string array | No | `[]` | Categorization tags. Available in IR and RAG outputs |

## `title`

```yaml
title: Getting Started with Boris
```

Required on every page. The title is the authoritative display name for the page. It appears:
- In the HTML `<title>` element
- In the navigation sidebar
- In breadcrumb trails
- In `llms.txt` page listings
- In the IR `manifest.json`

## `parent`

```yaml
parent: guides/overview
```

The entity id of the parent page. This determines where the page appears in the navigation hierarchy and breadcrumb trail.

- The `parent` must resolve to an existing page. Broken parent references fail the build with `EGRAPH`.
- Setting `parent` makes this page a **Satellite**. Omitting it makes it a **Trunk**.
- There is no default parent — Trunks have no parent.
- The value is an entity id, not a file path or a display title.

## `status`

```yaml
status: published   # visible in all outputs
status: draft       # excluded from all outputs
```

Draft pages are completely excluded from HTML, IR, RAG, Context Bundle, and `llms.txt` outputs. Wiki-links to draft pages are treated as broken references and fail the build.

The default value when `status` is omitted is `published`.

## `id`

```yaml
id: my-custom-id
```

By default, Boris derives the entity id from the file path: `content/guides/building-pages.md` → `guides/building-pages`. Use `id` to override this if you need a different identifier — for example, when the file path conflicts with a reserved name or you are migrating from another system.

The entity id must be unique across the entire site. Duplicate ids fail the build.

## `tags`

```yaml
tags: [setup, quickstart, cli]
```

An array of strings for categorization. Tags are available in the IR and RAG corpus for filtering and organization. They do not affect navigation or rendering.

## Complete example

```markdown
---
id: getting-started
title: Getting Started with Boris
parent: index
status: published
tags: [setup, quickstart, cli]
---

# Getting Started with Boris

Page content starts here.
```

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `EFRONTMATTER: unknown key 'sidebar_position'` | An unknown key was found in frontmatter | Remove the unknown key |
| `EFRONTMATTER: missing required key 'title'` | The `title` key is absent | Add a `title` key |
| `EGRAPH: parent 'guides/intro' not found` | The `parent` value does not resolve to an existing page | Fix the entity id or create the parent page |
| `EGRAPH: duplicate entity id 'getting-started'` | Two pages produce the same entity id | Add an `id` override to one of them |
