---
title: Content patterns
parent: index
status: published
tags: [theme, markdown]
---

# Content patterns

The point of a theme is to make ordinary authoring artifacts feel coherent.

## A compact comparison

| Element | Theme treatment | Why it helps |
|---|---|---|
| Inline code | tinted, rounded token | separates commands from prose |
| Code block | dark, scrollable panel | preserves long lines |
| Table | bordered rows and calm header | supports comparison |

## A small command

```bash
./zig-out/bin/boris --input content --html-dir dist
```

<Aside kind="warning">

This example is intentionally static. Do not add a CSS toolchain or a runtime
just to reproduce its visual treatment.

</Aside>
