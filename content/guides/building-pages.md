---
title: Building Pages
parent: learn
status: published
tags: [guides, authoring, search]
---

# Building Pages

Pages are ordinary Markdown files under `content/`. Boris discovers them,
checks their relationships, renders them to HTML, and builds the search index
from the HTML that was actually published.

## 1. Create a Markdown file

Use a lowercase, case-sensitive `.md` or `.mdx` path. The path becomes the
default entity id and the output route. For example,
`content/guides/deploying.md` becomes `guides/deploying.html`.

Start each page with Boris frontmatter:

```markdown
---
title: Deploying a Boris Site
parent: guides/overview
status: published
tags: [deployment, html]
---

# Deploying a Boris Site

Write the page here. Use normal Markdown headings so the page gets a useful
table of contents and searchable sections.
```

The accepted author keys are `id`, `title`, `parent`, `status`, and `tags`.
Use [[reference/frontmatter|the frontmatter reference]] for defaults and
failure cases. A page without `parent` is a Trunk; a page with `parent` is a
Satellite whose value must be another page's entity id.

## 2. Link and reuse content

Link to another page by entity id rather than by output filename:

```markdown
See [[guides/trunk-satellite|the page hierarchy]] or
[[reference/frontmatter#parent|the parent key]].
```

Shared snippets live under `content/includes/` and are not published as pages:

```markdown
{{include includes/shared-tip.md}}
```

Includes and wiki-links are expanded before Markdown rendering. They remain
literal inside fenced code blocks.

## 3. Build and inspect the site

From the repository root:

```bash
zig build
./zig-out/bin/boris --quiet
```

Open `dist/index.html`, or serve `dist/` with any static file server. The
default managed theme supplies navigation, breadcrumbs, a table of contents,
responsive styling, and the search box. To rebuild quickly while editing:

```bash
./zig-out/bin/boris --watch --quiet
```

## Search that stays in sync

The HTML compiler automatically writes:

```text
dist/_boris/search/search-index.json
```

That artifact is generated from the final rendered pages, not from Markdown or
IR. It includes page titles, headings, prose, and code; it excludes navigation,
footers, scripts, styles, hidden content, and explicit search-exclude regions.

The search box in the default layout loads that JSON in the browser. Search is
case-insensitive, folds accents, collapses whitespace, ranks title and heading
matches above body text, and returns up to twelve section links with excerpts.
Press `/` to focus it and `Escape` to clear it. If JavaScript is disabled, the
normal documentation navigation remains available.

For a custom layout, keep the search root marker on the page body:

```html
<main data-boris-search-root>{{content}}</main>
```

If you are indexing an already-rendered site outside the normal compiler path,
the same producer is available as `boris-search-index`; see the
[[reference/outputs|outputs reference]] for the command and artifact contract.

## Before committing a page

```bash
zig build test
./zig-out/bin/boris --quiet
```

If a parent, wiki-link, include, or frontmatter key is wrong, the build fails
with a diagnostic. Fix the source and rebuild; Boris does not silently publish
broken navigation.
