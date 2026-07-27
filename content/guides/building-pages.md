---
title: Building Pages
parent: guides/overview
status: published
tags: [guides, authoring, search]
---

# Building Pages

Pages are Markdown files under `content/`. This guide covers everything you need to create, link, organize, and publish documentation pages.

## Create a Markdown file

Use a lowercase `.md` path. The file path (relative to `content/`, without the extension) becomes the page's **entity id** and its output URL. For example:

- `content/guides/deploying.md` → entity id `guides/deploying` → output `guides/deploying.html`
- `content/index.md` → entity id `index` → output `index.html`

## Write frontmatter

Every page starts with Boris frontmatter — a YAML block that declares the page's identity and position in the graph:

```markdown
---
title: Deploying a Boris Site
parent: guides/overview
status: published
tags: [deployment, html]
---

# Deploying a Boris Site

Content goes here.
```

The accepted frontmatter keys are:

| Key | Required | Description |
|---|---|---|
| `title` | Yes | Displayed in the browser tab, navigation sidebar, and TOC |
| `parent` | No | Entity id of the parent page. Omit for Trunk (root) pages |
| `status` | No | `published` (default) or `draft`. Draft pages are excluded from outputs |
| `id` | No | Override the default entity id derived from the file path |
| `tags` | No | Array of strings for categorization |

<Aside kind="warning">

Unknown frontmatter keys are rejected with `EFRONTMATTER`. Boris uses a closed grammar — only the five keys above are accepted.

</Aside>

## Set a parent

A page with `parent` is a Satellite — it appears as a child in the navigation sidebar under its parent. The parent must be the **entity id** of another page that actually exists:

```markdown
---
parent: guides/overview
---
```

A page without `parent` is a Trunk — it appears as a top-level navigation item.

Boris validates every `parent` reference before publishing. If the referenced page does not exist, the build fails with a diagnostic error.

## Link to other pages

Use wiki-links to reference other pages by entity id:

```markdown
See [[reference/frontmatter|the frontmatter reference]] for key definitions.
```

Wiki-links accept three forms:

```markdown
[[entity-id]]                     # uses the page title as link text
[[entity-id|Custom link text]]    # explicit link text
[[entity-id#heading-id|text]]     # link to a specific heading
```

Boris validates all wiki-link targets before publishing. Broken wiki-links fail the build.

## Include shared snippets

Store reusable fragments under `content/includes/`. These files are **not** published as pages — they are snippet-only:

```markdown
{{include includes/shared-warning.md}}
```

Includes are expanded before Markdown rendering. They work inside regular text but remain literal inside fenced code blocks.

## Draft pages

Mark a page as draft to exclude it from all outputs:

```markdown
---
status: draft
---
```

Draft pages are not published to HTML, IR, RAG, or `llms.txt`. Wiki-links to draft pages are treated as broken references.

## Build and view the site

```bash
./zig-out/bin/boris
```

Open `dist/index.html` or serve `dist/` with any static file server. Navigation, breadcrumbs, and the table of contents are generated automatically from the validated graph.

To rebuild automatically while authoring:

```bash
./zig-out/bin/boris --watch --quiet
```

## Add search to your site

Run the search indexer after building HTML:

```bash
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search
```

The indexer reads the rendered HTML (not Markdown) and writes `dist/_boris/search/search-index.json`. If your layout includes the Boris search UI, it loads this file automatically. See [[guides/search-and-ui|Search & Browser UI]] for layout integration details.

## Next steps

- [[guides/trunk-satellite|Trunk & Satellite]] — deeper explanation of the hierarchy rules
- [[guides/themes-and-layouts|Themes & Layouts]] — customize the site appearance
- [[reference/frontmatter|Frontmatter Reference]] — complete key specifications
