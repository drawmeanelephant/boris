---
title: Watch mode and jobs
parent: ops
status: published
tags: [ops, cli]
---

# Watch mode and jobs

## Parallel page workers

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --jobs 4 \
  --quiet
```

`--jobs` bounds **HTML page** workers only. Discover, parse, graph freeze, and
fingerprint phases stay sequential.

## Watch

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --watch
```

Watch implies incremental rebuilds. Use for local authoring after the first
green full build.

## Not valid with IR/RAG

`--jobs`, `--watch`, and `--incremental` require HTML mode (exit **2** if mixed
with `--out` / `--rag`).
