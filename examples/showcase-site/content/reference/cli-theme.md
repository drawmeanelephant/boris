---
title: CLI for themes
parent: reference
status: published
tags: [reference, cli]
---

# CLI for themes

Relevant flags for this showcase (HTML mode only):

| Flag | Role |
|------|------|
| `--input DIR` | Content root |
| `--theme ROOT` | Theme root → `ROOT/layouts/main.html` + managed `assets/` |
| `--html-dir DIR` | Single HTML target (`default`) |
| `--layout-rule T S P` | Target, selector, layout path (repeatable) |
| `--incremental` | Content-addressed incremental HTML |
| `--quiet` | Suppress progress noise |

## Layout-rule grammar

```text
--layout-rule <TARGET> <SELECTOR> <LAYOUT_PATH>
```

Selectors:

- `id:<entity-id>` — exact final entity id
- `glob:<segment-pattern>` — `*` is one full path segment
- `role:trunk` / `role:satellite`

Invalid paths (`..`, absolute, backslashes) and mixed theme roots fail closed
before publish (usage exit **2**).

## Incremental re-run

```bash
./zig-out/bin/boris \
  --input examples/showcase-site/content \
  --theme themes/showcase \
  --layout-rule default id:index \
    themes/showcase/layouts/home.html \
  --layout-rule default 'glob:blog/*' \
    themes/showcase/layouts/blog.html \
  --layout-rule default role:trunk \
    themes/showcase/layouts/section.html \
  --html-dir test-output/static-theme-showcase \
  --incremental \
  --quiet
```

Cache material lives under the target as `.boris-cache/` when incremental
mode is enabled.
