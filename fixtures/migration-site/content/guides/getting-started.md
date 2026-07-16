---
title: Getting started
parent: guides
status: published
tags: [guides, setup]
---

# Getting started

Build Boris once, then compile **this fixture** as if it were your migrated
site. Full author checklist: [Migrating to Boris](../../../docs/MIGRATION.md)
(repository path from repo root).

## Prerequisites

- Zig **0.16+**
- CMake (compile-time only, for vendored ApexMarkdown)

## Build the compiler

```bash
zig build
./zig-out/bin/boris --help
```

## Compile this fixture to HTML

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet
```

Expected: exit **0**, HTML under `test-output/migration-dist/`, theme CSS at
`test-output/migration-dist/assets/css/site.css`.

## Related

- Install notes: [[guides/installation]]
- Frontmatter: [[guides/authoring-frontmatter]]
- Ops: [[ops/incremental]]
