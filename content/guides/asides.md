---
title: Using Asides
parent: guides/overview
status: published
tags: [components, authoring]
---

# Using Asides

Boris registers one authoring component: **Aside**. Asides are semantic
callouts that stay **in document order**. They are not graph nodes and not
separate HTML pages.

(Write the tag only inside fenced code samples or as real callouts — bare
angle-bracket tags outside fences are parsed as components.)

## Syntax

Opening and closing tags use the form below. The close tag must start a line.

```html
<Aside kind="tip" id="optional-anchor">

Body markdown here. Close tag must start a line.

</Aside>
```

## Kinds

| Kind | Typical use |
|------|-------------|
| `note` | Default when `kind` is omitted |
| `tip` | Actionable advice |
| `info` | Neutral context |
| `warning` | Caution |
| `danger` | Hard stop / do-not |

## Authoring rules

<Aside kind="danger">

- Attribute values must be **double-quoted**.
- Nested asides are not allowed.
- Only `Aside` is registered — invented tags (Figure, Broside, …) fail with
  `ECOMPONENT`.
- Optional `id`: `[A-Za-z0-9][A-Za-z0-9_-]*`, max 64 characters.

</Aside>

## Live examples

<Aside kind="tip" id="aside-tip-example">

Prefer short, actionable tips. Asides render in place — they never become their
own site pages.

</Aside>

<Aside kind="note">

Notes are the default kind when you omit `kind`.

</Aside>

## Export-only `:::kind`

RAG packs may contain `:::kind` fences. That form is **export packaging only**,
not an authoring dialect. In `content/` always use the Aside tags shown above.
