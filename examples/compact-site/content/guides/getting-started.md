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
  --input examples/compact-site/content \
  --theme themes/compact \
  --layout-rule default id:index \
    themes/compact/layouts/home.html \
  --html-dir test-output/compact \
  --quiet
```

## What to inspect

- `index.html` uses the home layout.
- Section pages use the default reading layout.
- `assets/css/compact.css` is copied locally by the compiler.
- Every stylesheet URL is page-relative and no HTML references a CDN.

<Aside kind="warning">

The theme is intentionally an example. It does not replace the repository's
default layouts and it does not add any new Boris authoring syntax.

</Aside>
