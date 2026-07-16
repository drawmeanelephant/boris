---
title: Multi-target builds
parent: ops
status: published
tags: [ops, targets]
---

# Multi-target builds

Publish draft and production trees without sharing caches or overwriting each
other.

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --target prod=test-output/migration-prod \
  --target stage=test-output/migration-stage \
  --target-layout prod=fixtures/migration-site/theme/layouts/main.html \
  --target-layout stage=fixtures/migration-site/theme/layouts/main.html \
  --quiet
```

Each target owns its output directory, staging tree, and cache namespace. Theme
assets are copied **per target**.

See also [[reference/cli]].
