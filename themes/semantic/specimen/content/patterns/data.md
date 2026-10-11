---
title: Tables and definitions
parent: patterns
status: published
tags: [patterns, tables]
---

# Tables and definitions

Some content is a grid of facts; some is a glossary. HTML has an element for
each, and both are read correctly with no extra attributes.

## Tables carry their own headers

A `th` inside `thead` names its column, so a screen reader can announce the
column before the first cell. Numbers line up because they are numbers.

| Element | Read as |
|---------|---------|
| `table` | A grid of related data |
| `caption` | The table's name |
| `th` | A heading for its row or column |
| `td` | A single value |

## Definition lists define

A `dl` pairs terms with their definitions. It is not a bullet list with bolder
text; the pairing is the point.

`main`
: The single primary region of a document.

`aside`
: Support that is related but optional to follow.

`summary`
: The always-visible label of a `details` disclosure.

Back to [Native disclosure](disclosure.md).
