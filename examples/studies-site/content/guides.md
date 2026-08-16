---
title: Guides
status: published
tags: [guides, section]
---

# Guides

Section landing pages use the **section** layout (`role:trunk`). That layout
foregrounds direct children via `{{children}}` and keeps a compact site map
via `{{nav}}`.

This page intentionally has child satellites so the “Pages in this section”
panel is populated.

## What these guides cover

| Page | Focus |
|------|--------|
| [Getting started](guides/getting-started.md) | Build commands and expected outputs |
| [Components](guides/components.md) | Aside callouts, Details disclosure, page-local figure |

<Aside kind="note">

Trunk pages are graph parents. Satellites declare `parent:` and never own
another satellite under the current one-level graph contract.

</Aside>
