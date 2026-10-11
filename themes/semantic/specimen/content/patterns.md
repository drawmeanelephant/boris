---
title: Patterns
parent: index
status: published
tags: [patterns, components]
---

# Patterns

Every interaction on this page is a browser feature wearing a stylesheet.
Disclosure, tables, and definition lists arrive with their behaviour, their
keyboard handling, and their spoken names already attached.

## Reach for the element first

The default question is *which element already means this*. A component is
only rebuilt when the standard element genuinely cannot do the job — and even
then, the rebuild has to earn its script.

| You want | Reach for | Not |
|----------|-----------|-----|
| Optional depth | `details` + `summary` | A scripted accordion |
| A grid of facts | `table` with `th` | Aligned `div`s |
| Term and definition | `dl`, `dt`, `dd` | A bolded list |
| A quoted passage | `blockquote` + `cite` | A styled paragraph |

## The pages below

Two patterns, each in place: native disclosure, then tables and definitions.
