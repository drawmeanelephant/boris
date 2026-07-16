---
title: Café notes (Unicode body)
status: published
tags: [special, unicode]
---

# Café notes

Source path (ASCII stem — wiki-linkable):

```text
special/cafe-notes.md
```

Entity id:

```text
special/cafe-notes
```

## Why ASCII paths for migration

Wiki-link entity ids use an ASCII grammar (`A–Z`, `a–z`, `0–9`, `/`, `_`,
`-`, `.`). Prefer ASCII path stems (or an ASCII `id:` override) so authors can
write `[[special/cafe-notes]]`. Unicode belongs freely in **titles and body**.

## Body Unicode

Product prose may include café, naïve, Zürich, and 日本語 freely when the file
is valid UTF-8 **without** a leading BOM.

## Heading for fragment practice

## Notes de café

Prefer inspecting the rendered heading `id` before authoring fragment links.
Diacritic stripping depends on Apex GFM id generation — see
[[guides/heading-fragments]].

## Cross links

- Case demo: [[special/CaseDemo]]
- Unicode guide: [[guides/unicode-and-punctuation]]
