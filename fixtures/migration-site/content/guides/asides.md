---
title: Asides and callouts
parent: guides
status: published
tags: [guides, components]
---

# Asides and callouts

Boris supports constrained Aside components that stay **in document order**.
They are not separate pages and are not graph nodes.

(Write the tag only inside fenced code samples or as real callouts — bare
angle-bracket tags outside fences are parsed as components.)

## Syntax

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

## Live examples

<Aside kind="tip">

Prefer Asides for callouts. Do not invent executable MDX components.

</Aside>

<Aside kind="warning">

Unknown Aside kinds fail compile validation. Stick to the allowlisted kinds in
the table above.

</Aside>

## Migration note

If your old site used Markdown admonition plugins (`!!! note`, `:::warning`),
convert each block to an Aside wrapper with ordinary Markdown inside (see the
fenced syntax above). Body content still goes through Apex.
