---
title: "Unicode, punctuation, and titles"
parent: guides
status: published
tags: [guides, i18n]
---

# Unicode and punctuation

Migrations often carry curly quotes, em dashes, and non-ASCII titles. Boris
source must be **valid UTF-8** without a BOM.

## Titles

This page’s title uses a comma and ASCII quotes in frontmatter (double-quoted
value). Curly punctuation is fine in the **body**.

## Café résumé

Diacritics in headings are allowed. Apex GFM heading ids typically strip them
(see [[guides/heading-fragments]]). Link with the rendered id, not a guessed
Unicode slug.

## “Smart” quotes and — dashes

Authors may keep typographic punctuation in prose. Prefer plain ASCII in
**entity ids** used by wiki links and in **include paths** for portability.

## Related fixture pages

- Unicode body demo: [[special/cafe-notes]]
- Case-sensitive id: [[special/CaseDemo]]
