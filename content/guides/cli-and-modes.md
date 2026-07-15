---
title: CLI and Run Modes
parent: getting-started
status: published
tags: [cli, guides]
---

# CLI and Run Modes

Boris has three product surfaces. **Default is HTML.** Older scripts that
assumed bare `boris` wrote IR must pass `--out` (or `--no-rag`).

## 1. HTML site (default)

Writes under `dist/` (or `--html-dir`).

```bash
./zig-out/bin/boris
./zig-out/bin/boris --html-dir custom_dist/
./zig-out/bin/boris --jobs 4 --quiet
./zig-out/bin/boris --watch
./zig-out/bin/boris --incremental --quiet
```

Multi-target isolated outputs:

```bash
./zig-out/bin/boris \
  --target prod=dist/prod \
  --target stage=dist/stage
```

| Flag | Default | Notes |
|------|---------|--------|
| `--jobs N` / `-j N` | `1` | Parallel page workers `1–64` |
| `--incremental` | off | Skip unchanged pages |
| `--watch` | off | Debounced rebuild; implies incremental |
| `--html-layout PATH` | `layouts/main.html` | Must contain `{{content}}` once |

On this path Boris also expands includes and wiki-links before Apex (see
[[getting-started]] and [[guides/overview|content model]]).

## 2. JSON IR

```bash
./zig-out/bin/boris --out .boris
./zig-out/bin/boris --no-rag --quiet
```

Emits `manifest.json`, `graph.json`, and `build-report.json`. IR
`schemaVersion` is still **`0.1.0`** in product v0.2.x unless the emit shape
changes.

<Aside kind="warning">

`--out` selects **IR mode** — it does not write the HTML site. Use bare `boris`
(or `--html-dir`) for `dist/`.

</Aside>

## 3. RAG corpus

```bash
./zig-out/bin/boris --rag --quiet
./zig-out/bin/boris --rag-dir ./uploads/rag --quiet
```

There is **no** `zig build rag` product step. Details:
[[guides/rag-export|RAG export]].

## Conflicts

Incompatible mode combinations exit **2** (usage). Example:

```bash
./zig-out/bin/boris --out .boris --rag   # invalid
```

Exit codes: `0` ok · `1` content · `2` usage · `3` I/O.

Back to [[getting-started|Getting started]].
