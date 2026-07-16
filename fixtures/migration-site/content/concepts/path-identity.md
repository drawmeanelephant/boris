---
title: Path identity
parent: concepts
status: published
tags: [concepts, identity]
---

# Path identity

Discovery keeps **letter case** from the filesystem path. Only `.md` and
`.mdx` (lowercase extensions) are pages.

## Examples in this fixture

| Path | Id |
|------|-----|
| `special/CaseDemo.md` | `special/CaseDemo` |
| `special/cafe-notes.md` | `special/cafe-notes` |
| `reference/HTTP-status.md` | `reference/HTTP-status` |

## Practical constraints

- Prefer ASCII path segments when pages must be wiki-linked.
- Never rely on case-insensitive collision “fixing” two pages into one.
- Wiki targets must match ids exactly — see [[special/CaseDemo]].

## Related

[[reference/entity-ids]] · [[guides/unicode-and-punctuation]]
