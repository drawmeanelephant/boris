---
title: Incremental builds
parent: ops
status: published
tags: [ops, performance]
---

# Incremental builds

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --incremental \
  --quiet
```

## What dirties a page

- Page source bytes change
- Transitive **include** fragment bytes change
- Wiki target title/path material changes (including via includes)
- Layout / theme material used by the page changes

## Migration tip

After bulk renames, run a **full** HTML build once, then enable
`--incremental` for edit loops. Measure on your tree; do not advertise
unmeasured speedups.
