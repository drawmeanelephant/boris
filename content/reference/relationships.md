---
title: Relationships
parent: reference
status: published
tags: [reference, graph]
---

# Relationships

Boris distinguishes the relationships that organize a site from the ones that
reuse source or point a reader elsewhere. Keeping them explicit makes broken
structure detectable before publication.

| Relationship | Write it as | What it does |
|---|---|---|
| Parent/child hierarchy | `parent: guides` | Builds navigation and breadcrumbs |
| Reader-facing cross-link | A Boris wiki-link | Links to a page by its stable entity id |
| Reader-facing heading link | A wiki-link with a heading fragment | Links to a rendered heading id |
| Shared source fragment | An include directive | Expands a content-root-relative Markdown fragment |
| Knowledge relation | `relations: [relates_to=guides/intro]` | Adds a typed semantic relation for supported IR use |

## Parent chains create the site shape

Omit `parent` for a Trunk. Give a Satellite the exact id of its direct parent.
Nested parent chains are valid, but every chain must terminate at a Trunk and
must never cycle.

```yaml
---
title: Install on macOS
parent: guides/install
---
```

The parent is not a loose label: a missing id, self-reference, or cycle stops
the build. Start with [[guides/trunk-satellite|Trunk and Satellite Pages]] for
the authoring model.

## Wiki-links are safer than path guesses

Use a page entity id rather than a `.md` filename in a Boris wiki-link:

<pre><code>&#91;&#91;reference/frontmatter|the frontmatter rules&#93;&#93;.
&#91;&#91;reference/commands#exit-codes|exit codes&#93;&#93;.</code></pre>

The compiler verifies that the target page and requested heading exist. Regular
Markdown links remain useful for external sites; they are not a whole-site link
checker.

## Includes are source reuse, not navigation

Put a reusable fragment under `content/includes/` and include it by a path
relative to the content root:

<pre><code>&#123;&#123;include includes/shared-tip.md&#125;&#125;</code></pre>

Files in `includes/` are intentionally not published as pages. An include may
include another fragment, but cycles and missing files fail with a diagnostic.

## Semantic relations are not dependencies

`relations` describes author-intended knowledge links such as `relates_to`,
`implements`, `depends_on`, and `supersedes`. It does not alter the navigation
tree or make a page rebuild when the related page changes. Keep it for a
meaningful conceptual assertion, not as another way to make a sidebar.
