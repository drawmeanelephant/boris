---
title: Entity IDs
parent: reference
status: published
tags: [reference, identity]
---

# Entity IDs

Entity ids are the graph primary keys used by `parent` and wiki links.

## Path derivation

```text
id = sourcePath without trailing .md / .mdx
```

| Source path | Entity id |
|-------------|-----------|
| `index.md` | `index` |
| `guides/wiki-links.md` | `guides/wiki-links` |
| `guides/deep/nested/path/note.md` | `guides/deep/nested/path/note` |
| `reference/HTTP-status.md` | `reference/HTTP-status` |
| `special/CaseDemo.md` | `special/CaseDemo` |
| `special/cafe-notes.md` | `special/cafe-notes` |

## Case sensitivity

Comparison is **byte-exact**. `special/CaseDemo` is not `special/casedemo`.
On case-insensitive filesystems, avoid two paths that differ only by case.

## Wiki-link character set

Live wiki targets use an ASCII entity-id grammar. Prefer ASCII path stems (or
an ASCII `id:` override) for any page authors will link with wiki syntax.
Unicode is fine in titles and body prose — see [[special/cafe-notes]].

## Overrides

Optional frontmatter `id:` replaces the path-derived id. Overrides must pass
the same validation (no `..`, no absolute, ≤ 255 bytes). Prefer path-derived
ids unless you are staging a deliberate rename (see [[cookbook/rename-pages]]).

## Output mapping

HTML path is `{entity_id}.html` under the target root. Nested ids create nested
directories automatically.
