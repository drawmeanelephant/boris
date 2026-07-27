---
title: Command Reference
parent: reference
status: published
tags: [reference, cli, commands]
---

# Command Reference

Every flag, mode, and exit code.

## Basic usage

```bash
./zig-out/bin/boris              # HTML site → dist/ (default)
./zig-out/bin/boris --help       # show all flags and exit
```

Running with no arguments is equivalent to `boris build --html-dir dist`.

---

## Output modes

Each mode is exclusive — one mode per invocation.

### HTML site (default)

```bash
./zig-out/bin/boris
./zig-out/bin/boris --html-dir public
./zig-out/bin/boris --theme my-theme --html-dir dist
```

| Flag | Default | Description |
|---|---|---|
| `--html-dir DIR` | `dist` | Output directory for the HTML site |
| `--theme ROOT` | — | Theme root directory (shorthand for `--html-layout ROOT/layouts/main.html`) |
| `--html-layout PATH` | `layouts/main.html` | Path to the HTML layout template |
| `--incremental` | off | Only re-render pages that have changed (content-addressed) |
| `--watch` | off | Build, then watch and rebuild on file changes (implies incremental) |
| `--jobs N`, `-j N` | `1` | Number of parallel page rendering workers (max 64) |

### JSON IR

```bash
./zig-out/bin/boris --out .boris
./zig-out/bin/boris --no-rag
```

| Flag | Default | Description |
|---|---|---|
| `--out DIR` | `.boris` | Output directory for IR JSON files |
| `--no-rag` | — | Explicit IR mode (same as `--out` without a directory argument) |

### RAG corpus

```bash
./zig-out/bin/boris --rag
./zig-out/bin/boris --rag-dir ./uploads/rag
./zig-out/bin/boris --rag --scope guides --split-size 2000000
```

| Flag | Default | Description |
|---|---|---|
| `--rag` | — | Enable RAG corpus export |
| `--rag-dir DIR` | `rag` | Output directory for the RAG corpus |
| `--scope VALUE` | — | Export only pages whose entity id starts with VALUE |
| `--split-size BYTES` | — | Split corpus into parts of at most BYTES each |
| `--bundles-only` | off | Omit per-page files; emit only bundled parts |

### AI Context Bundle

```bash
./zig-out/bin/boris --context
./zig-out/bin/boris --context-dir ./context-output
```

| Flag | Default | Description |
|---|---|---|
| `--context` | — | Enable Context Bundle export |
| `--context-dir DIR` | `context` | Output directory for the Context Bundle |
| `--split-size BYTES` | — | Split bundle into parts of at most BYTES |

### `llms.txt`

```bash
./zig-out/bin/boris --llms
./zig-out/bin/boris --llms-path public/llms.txt
```

| Flag | Default | Description |
|---|---|---|
| `--llms` | — | Enable `llms.txt` export |
| `--llms-path PATH` | `llms.txt` | Output path for the `llms.txt` file |

---

## Read-only commands

These commands validate or inspect without writing output files (unless `--report` is specified).

```bash
./zig-out/bin/boris check
./zig-out/bin/boris check --format json --report health.json
./zig-out/bin/boris impact guides/overview
./zig-out/bin/boris impact guides/overview --format json
```

| Command | Description |
|---|---|
| `check` | Validate the full content graph. Exit `1` if there are errors |
| `impact ID` | List all pages transitively depending on the given entity id |

| Flag | Default | Description |
|---|---|---|
| `--format human\|json` | `human` | Output format for check/impact results |
| `--report PATH` | stdout | Write analysis report to a file instead of stdout |

---

## Common options

| Flag | Description |
|---|---|
| `--input DIR` | Content root directory (default: `content`) |
| `--quiet` | Suppress progress output to stderr (exit codes and artifacts unchanged) |
| `--help`, `-h` | Print help and exit successfully |

---

## Layout rules

Override the layout for specific pages or page roles:

```bash
./zig-out/bin/boris \
  --theme my-theme \
  --layout-rule default id:index my-theme/layouts/home.html \
  --layout-rule default role:trunk my-theme/layouts/section.html \
  --html-dir dist
```

| Flag | Description |
|---|---|
| `--layout-rule TARGET SELECTOR PATH` | Apply layout PATH to pages matching SELECTOR in output target TARGET |
| `--target-layout NAME=PATH` | Set the layout for a named output target |

Selectors: `id:ENTITY_ID`, `role:trunk`, `role:satellite`, `glob:PATTERN`.

---

## Multiple output targets

```bash
./zig-out/bin/boris \
  --target docs=dist/docs \
  --target api=dist/api \
  --target-layout docs=themes/docs/layouts/main.html \
  --target-layout api=themes/api/layouts/main.html
```

| Flag | Description |
|---|---|
| `--target NAME=DIR` | Define a named output target with output directory DIR |
| `--target-layout NAME=PATH` | Assign a layout to the named target |

`--target` is exclusive with `--html-dir`.

---

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Success |
| `1` | Content or graph validation error; or `check` found policy violations |
| `2` | Invalid flag or flag combination |
| `3` | I/O or system error |
