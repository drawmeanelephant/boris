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

## Diagnostic Troubleshooting & Common Errors

Boris enforces strict, closed frontmatter syntax. Any key outside `title`, `parent`, `status`, `id`, and `tags` produces an immediate `EFRONTMATTER` diagnostic and halts the build.

### Diagnostic Matrix

| Error Diagnostic | Root Cause | Exact Resolution |
|---|---|---|
| `EFRONTMATTER: unknown key 'sidebar_position'` | Unrecognized key in YAML frontmatter header | Remove the unsupported key or move metadata to body content |
| `EFRONTMATTER: unknown key 'parent_entry'` | Used legacy `parent_entry` or `parentEntry` key name | Rename the key to `parent:` (Boris only accepts `parent`) |
| `EFRONTMATTER: missing required key 'title'` | Page header omitted the required `title` key | Add a string `title: "Page Title"` to the frontmatter block |
| `EFRONTMATTER: invalid status value` | Value of `status:` is not `published` or `draft` | Set `status: published` or `status: draft` |
| `EGRAPH: parent 'guides/intro' not found` | `parent:` ID does not match any published entity | Verify target page exists and has `status: published` |
| `EGRAPH: duplicate entity id 'getting-started'` | Two Markdown files derive or set the same ID | Use an explicit `id:` override or rename one of the files |

### Step-by-Step Frontmatter Audit

1. **Verify Closed Grammar**: Ensure frontmatter contains *only* `title`, `parent`, `status`, `id`, or `tags`.
2. **Check Parent Key Name**: Confirm parent key is written as `parent:` — not `parent_entry`, `parentEntry`, or `parent_id`.
3. **Confirm Parent Target**: Run `boris check` to verify every `parent:` value maps to a valid published Trunk or Satellite entity ID.
