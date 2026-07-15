---
title: CLI and Run Modes
parent: getting-started
status: published
tags: [cli, guides]
---
# CLI and Run Modes

With Feature 2 complete, Boris now explicitly defaults to compiling an HTML site. The old "JSON IR first" behavior is strictly gated behind flags.

## 1. HTML Site (Default)

Produces the `dist/` directory.

```bash
./zig-out/bin/boris
./zig-out/bin/boris --html-dir custom_dist/
./zig-out/bin/boris --jobs 4 --watch
```

## 2. JSON IR (Data Export)

Produces `.boris/manifest.json` and `.boris/graph.json`.

```bash
./zig-out/bin/boris --out .boris
```

<Aside kind="warning">
Do not use `--out` if you just want to view the site! This skips HTML rendering.
</Aside>

## 3. Product RAG Corpus

Produces flat markdown files with injected metadata.

```bash
./zig-out/bin/boris --rag
./zig-out/bin/boris --rag-dir ./custom_rag
```

## Conflicts

You cannot mix incompatible output modes. For example, running:
```bash
./zig-out/bin/boris --out .boris --rag
```
will result in an `exit 2` error.
