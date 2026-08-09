---
title: Building Pages
parent: guides/overview
status: published
tags: [guides, authoring, search]
---

# Building Pages

Pages are Markdown files under `content/`. Their paths, frontmatter, parent
chains, and supported references determine both the published URL and the
navigation tree.

## Create a page

Use a lowercase `.md` or `.mdx` path. The path relative to `content/`, without
its extension, becomes the entity id and HTML output path by default:

- `content/guides/deploying.md` → `guides/deploying` →
  `guides/deploying.html`
- `content/index.md` → `index` → `index.html`

## Add frontmatter

Frontmatter is optional and deliberately closed. The accepted author-facing
keys are `id`, `title`, `parent`, `status`, `tags`, `relations`, `published_at`,
and `summary`. `title` is optional; if it is absent, the compiler keeps it
unset rather than inventing one from the filename.

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

Use the [[reference/frontmatter|frontmatter reference]] for exact value
grammar. Unknown keys, including `parentEntry` and `parent_entry`, are
`EFRONTMATTER` errors.

## Set hierarchy

Omit `parent` for a Trunk. Set one direct parent entity id for a Satellite:

```markdown
---
title: Deployment details
parent: guides/overview
---
```

The parent must exist, and the complete chain must be finite and acyclic.
Nested Satellites are supported. [[guides/trunk-satellite|Trunk & Satellite]]
explains the resulting navigation and breadcrumb hierarchy.

## Link to pages

Use entity ids rather than guessing `.html` paths:

```markdown
See [[reference/frontmatter|the frontmatter reference]].
See [[reference/commands#exit-codes|the exit-code table]].
```

The HTML compiler validates the page target and, for the HTML path, the
rendered heading fragment. Broken supported wiki-links fail the publication
with a diagnostic.

Ordinary Markdown links to a local `.md` or `.mdx` page can also be rewritten to
the canonical HTML route when they match a discovered source path. External
links and arbitrary HTML links remain outside that graph guarantee.

## Reuse a fragment

Put short reusable source fragments under `content/includes/`:

```markdown
{{include includes/shared-tip.md}}
```

Includes are expanded before Markdown rendering, are not standalone pages, and
remain literal inside fenced code. Missing fragments and include cycles fail
the build.

## Status and publication metadata

`status` may be `draft`, `published`, or `archived`. Draft pages are excluded
from publication and from graph targets used by published output; archived
pages remain part of the supported published graph. `relations` records one of
the bounded semantic kinds described in [[reference/relationships|Relationships]];
it is not a parent edge or a build dependency.

`published_at` and `summary` provide metadata for projections such as RSS.
When `published_at` is present, `summary` is required. RSS eligibility also
requires both fields and a non-draft status.

## Build and inspect

```bash
./zig-out/bin/boris validate --quiet
./zig-out/bin/boris build --quiet
```

Use `validate` for the authoritative no-publication HTML preflight. Use
`check` for graph-health analysis and `impact ID` for dependency impact; neither
is a substitute for `validate`.

The normal build writes `dist/`, including the compiler-owned rendered-search
index and target-local publication evidence. Serve `dist/` with any static
host if you want the browser search UI to fetch its index.

## Next steps

- [[guides/themes-and-layouts|Themes & Layouts]] — customize HTML output.
- [[guides/search-and-ui|Search & Browser UI]] — understand rendered search.
- [[reference/commands|Command Reference]] — exact flags and exit codes.
