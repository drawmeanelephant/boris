---
title: Using Asides
parent: guides/overview
status: published
tags: [components, authoring]
---
# Using Asides

Boris supports a single registered custom component: the Aside admonition.

Asides are semantic callouts that stay in document order. They are not graph nodes or separate HTML pages.

## Syntax

Opening and closing tags must use the form below. The close tag must start a line.

```html
<Aside kind="tip" id="optional-anchor">

Body markdown here. Close tag must start a line.

</Aside>
```

## Available Kinds

- `note` (default)
- `tip`
- `info`
- `warning`
- `danger`

<Aside kind="danger">

**Important authoring rules**

- Attribute values must be **double-quoted**.
- Nested asides are not allowed.
- Only the Aside tag is registered. Invented names (for example Broside or Figure) fail the compile with `ECOMPONENT`.

</Aside>

## Live examples

<Aside kind="tip" id="aside-tip-example">

Prefer short, actionable tips. Asides render in place — they never become their own site pages.

</Aside>

<Aside kind="note">

Notes are the default kind when you omit `kind`.

</Aside>

## Export-only syntax

You might see `:::kind` fences in RAG export packs. That form is **export packaging only**, not an authoring dialect. In `content/` always use the Aside HTML-style tags shown in the syntax fence above.
