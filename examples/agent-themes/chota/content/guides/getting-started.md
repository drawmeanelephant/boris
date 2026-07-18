---
title: Getting started
parent: guides
status: published
tags: [guides, cli]
---

# Getting started

The example deliberately keeps its build surface small: one content tree, one
theme root, and one local stylesheet copied into the output.

## Compile the example

```bash
./zig-out/bin/boris \
  --input examples/agent-themes/chota/content \
  --theme examples/agent-themes/chota/theme \
  --layout-rule default id:index \
    examples/agent-themes/chota/theme/layouts/home.html \
  --html-dir test-output/agent-themes-chota \
  --quiet
```

## What to inspect

- `index.html` uses the home layout.
- Section pages use the default reading layout.
- `assets/css/chota.css` is copied locally by the compiler.
- Every stylesheet URL is page-relative and no HTML references a CDN.

<Aside kind="warning">

The theme is intentionally an example. It does not replace the repository's
default layouts and it does not add any new Boris authoring syntax.

</Aside>
