---
title: From MkDocs
parent: cookbook
status: published
tags: [cookbook, mkdocs]
---

# From MkDocs

## Typical mapping

| MkDocs | Boris |
|--------|-------|
| `docs/` | `--input` content root |
| `mkdocs.yml` nav tree | Trunk / Satellite `parent` graph |
| `pymdownx.snippets` | Include directives under `includes/` |
| Admonitions (`!!!`) | Aside components |
| Theme CSS | Theme `assets/css` + layout link |
| Plugins / macros | **Out of scope** — pre-render or delete |

```markdown
{{include includes/shared-callout.md}}

<Aside kind="note">
Converted from an MkDocs admonition.
</Aside>
```

## Nav conversion

MkDocs nested nav deeper than one child level must be **flattened** into
Trunks with Satellite children only. Extra visual nesting can use headings or
separate Trunks, not satellite-of-satellite parents.
