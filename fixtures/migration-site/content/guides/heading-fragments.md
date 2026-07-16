---
title: Heading fragment links
parent: guides
status: published
tags: [guides, linking]
---

# Heading fragment links

Wiki section links use the **exact** Apex-rendered heading `id` on the target
page. Boris does not invent a second slugger.

## Author form

```markdown
[[guides/heading-fragments#hello-world]]
[[guides/heading-fragments#code-x-y|Code span heading]]
```

## Headings on this page (targets)

## Hello World

Plain words → typically `hello-world`.

## Hello, World!

Punctuation stripped → typically `hello-world` as well (duplicate id allowed).

## Code `x` Y

Inline code kept in slug → typically `code-x-y`.

## Café résumé

Diacritics removed under GFM path → typically `caf-rsum`.

### Nested Deep

h3 remains a valid fragment target → typically `nested-deep`.

## Live self and cross links

- Self: [[guides/heading-fragments#nested-deep|Nested Deep]]
- Sibling: [[guides/unicode-and-punctuation#caf-rsum|Unicode demo heading]]
- Home: [[index#success-criteria|Success criteria]]

## Migration advice

1. Build HTML once.
2. Inspect rendered `id="…"` attributes (or page TOC).
3. Author fragment links using those exact strings (see fenced examples above).
4. Do **not** guess WordPress/Hugo slug rules.
