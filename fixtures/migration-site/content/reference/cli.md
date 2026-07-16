---
title: CLI reference (migration)
parent: reference
status: published
tags: [reference, cli]
---

# CLI reference (migration)

Commands below assume the product binary at `./zig-out/bin/boris` after
`zig build`. Paths are from the **repository root**.

## HTML site (default product mode)

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet
```

| Expect | Detail |
|--------|--------|
| Exit | `0` |
| Pages | `test-output/migration-dist/**/*.html` |
| Assets | `test-output/migration-dist/assets/css/site.css` |
| Favicon | `test-output/migration-dist/assets/img/mark.svg` |

## JSON IR

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --out test-output/migration-ir \
  --quiet
```

| Expect | Detail |
|--------|--------|
| Exit | `0` |
| Files | `manifest.json`, `graph.json`, `build-report.json` |

## RAG pack (optional)

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --rag-dir test-output/migration-rag \
  --quiet
```

Do **not** commit `test-output/` trees, repo `dist/`, `rag/`, or cache dirs.

## Parallel and incremental HTML

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --jobs 4 \
  --incremental \
  --quiet
```

## Multi-target

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --target prod=test-output/migration-prod \
  --target stage=test-output/migration-stage \
  --target-layout prod=fixtures/migration-site/theme/layouts/main.html \
  --target-layout stage=fixtures/migration-site/theme/layouts/main.html \
  --quiet
```

## Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | Success |
| 1 | Content / graph / include / wiki failure |
| 2 | Usage / flag conflict |
| 3 | I/O |
