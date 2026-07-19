---
title: What Boris cuts on purpose
parent: contest
status: published
tags: [build-week, scope, limitations]
---

# What Boris cuts on purpose

The project gets smaller by refusing a few tempting things. Those are design
choices, not secret missing features.

| Not in Boris | Why |
|---|---|
| A Node runtime or client framework in the publish path | The compiler should remain a local Zig binary that writes static output. |
| Arbitrary executable MDX | Content should not acquire a hidden application runtime just to render a page. |
| Full YAML frontmatter | The closed grammar keeps diagnostics and contracts predictable. |
| A universal one-click migration promise | Real sites need review; migration labs preserve uncertainty instead of erasing it. |
| A built-in deployment host | `dist/` is portable. Use whichever static host fits the site. |

## Strict is not hostile

Boris still leaves room to grow: layouts, static assets, native semantic
components, typed graph edges, and bounded migration transformations are all
extension paths. The line is that a new capability should be explicit,
testable, and deterministic before it becomes a default promise.

That is why the migration labs report boundaries, why source-RAG packs carry
manifests, and why the agent stories mark their evidence level. The project is
trying to make confidence inspectable.

For the long form, start with [[guides/overview|the content model]] and
[[reference/frontmatter|the author grammar]].
