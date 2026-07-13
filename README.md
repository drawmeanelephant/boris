# Boris

**Zig-native content compiler** with IR + optional deterministic RAG export (m7):
deterministic scan → bounded frontmatter → PageDb → Trunk/Satellite graph →
JSON IR under `.boris/`, or RAG corpus under `rag/`.

Named for the folk **Zouave** figure known as **Boris** — improvise under
constraint, chain the next leaf, clear the slate. Compile rhythm (narrative,
not CLI flags): **Load → Roll → Ignite → Reset**. See
[`docs/rag/system/10-name-and-metaphor.md`](docs/rag/system/10-name-and-metaphor.md).
Independent software; **not** affiliated with any commercial tobacco or
rolling-paper brand.

| | |
|--|--|
| Language | Zig **0.16.0** (`build.zig.zon` / CI pin) |
| Product | **0.0.1** / compiler **boris/0.1.1** |
| License | [MIT](LICENSE) |

## Implemented vs planned

| Behavior | Status |
|----------|--------|
| Typed CLI (`--input`, `--out`, `--rag`, …) | **Implemented** |
| `boris --help` / `-h` | **Implemented** — exit 0; no FS |
| Flag conflicts / unknown args | **Implemented** — exit **2** |
| Exit codes 0 / 1 / 2 / 3 | **Implemented** |
| Deterministic content scanner | **Implemented** — `src/scanner.zig` |
| Canonical entity id / paths | **Implemented** — `src/identity.zig` |
| Bounded frontmatter parser | **Implemented** — `src/parser.zig` |
| Trunk/Satellite graph + diagnostics | **Implemented** — `src/graph.zig` |
| Deterministic JSON IR under `.boris/` | **Implemented** — `src/pipeline.zig` |
| Optional product RAG export (`--rag`) | **Implemented** — `src/rag.zig` ([contract](docs/contracts/rag-export.md)) |
| Content discovery wired into default CLI | **Implemented** (IR and RAG modes) |
| `zig build test` | **Implemented** — CLI + fixtures + scanner + parser + pipeline + RAG + Apex ABI |
| Normative contracts under [`docs/contracts/`](docs/contracts/) | **Normative + implemented** |
| Apex C ABI (in-process) | **Implemented** — linked + tested; **not** on default IR/RAG path ([contract](docs/contracts/apex-abi.md)) |
| Apex HTML `dist/` assemble | **Not** default product surface for v0.1 |
| Concurrency / watch / full YAML | **Out of scope** for v0.1 |

## What works today (CLI)

| Command | Behavior |
|---------|----------|
| `boris --help` / `boris -h` | Print usage; exit **0** (no directories opened) |
| `boris` | IR mode: scan `content/` → write `.boris/` JSON IR |
| `boris --input DIR --out DIR` | IR mode with custom paths |
| `boris --no-rag` | Explicit IR mode |
| `boris --rag` | RAG-only: shared graph validation → corpus under `rag/` |
| `boris --rag-dir DIR` | RAG-only with output directory `DIR` |
| content validation failure | Diagnostics on stderr; exit **1** (IR and RAG) |
| conflicting / unknown flags | Print usage; exit **2** |
| missing content root / I/O | Exit **3** |

### Options

| Option | Default | Notes |
|--------|---------|--------|
| `--input <DIR>` | `content` | Content root |
| `--out <DIR>` | `.boris` | IR output (IR mode only) |
| `--rag` | — | Select RAG-only mode |
| `--no-rag` | — | Explicit IR mode |
| `--rag-dir <DIR>` | `rag` (when RAG) | Implies RAG-only mode |
| `--quiet` | off | Suppress progress logging only (not diagnostics/IR) |
| `-h`, `--help` | — | Help; exit 0 |

Also accepted: `--input=DIR`, `--out=DIR`, `--rag-dir=DIR`.

### Mode rules

1. Default mode is **IR**.
2. `--no-rag` explicitly selects IR mode.
3. `--rag` selects **RAG-only** mode.
4. `--rag-dir DIR` implies **RAG-only** mode.
5. `--rag` and `--no-rag` together → usage error (exit 2).
6. `--no-rag` and `--rag-dir` together → usage error (exit 2).
7. Explicit `--out` with `--rag` or `--rag-dir` → usage error (exit 2); never silently ignored.
8. Empty values for `--input`, `--out`, `--rag-dir` → usage error (exit 2).
9. Unknown options, missing values, positionals, duplicate flags → usage error (exit 2).
10. `--help` / `-h` exit 0 without opening directories or scanning content.

### Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Success (help, valid IR, or valid RAG export) |
| `1` | Content validation error (shared graph/frontmatter diagnostics) |
| `2` | Usage / CLI error |
| `3` | I/O or system error |

### RAG output (success)

```text
rag/
  INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json
  system/**  content/pages/**  graph/entity-catalog.md  graph/relations.md
```

Same scanner, parser, PageDb records, and `graph.validate` as IR mode. Asides
are **not** rewritten to `:::kind` in this milestone (deferred). See
[docs/contracts/rag-export.md](docs/contracts/rag-export.md).

## Quick start

```bash
# Requires Zig 0.16.0
zig build                          # install → zig-out/bin/boris (+ boris-source-rag)
zig build run -- --help            # usage; exit 0
zig build run -- --input fixtures/content/valid --out /tmp/boris-ir --quiet
zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag --quiet
zig build run -- --rag --no-rag    # usage conflict; exit 2
zig build run -- --rag --out x     # usage conflict; exit 2
zig build test                     # unit tests (CLI + fixtures + scanner + pipeline + RAG)
zig build source-rag               # source pack for LLM upload → source-rag/
```

```bash
zig-out/bin/boris --help
zig-out/bin/boris --input content --out .boris --quiet
zig-out/bin/boris --rag --input content --quiet
zig-out/bin/boris --rag-dir ./uploads/boris-rag --quiet
zig-out/bin/boris --rag --no-rag   # exits 2
zig-out/bin/boris --rag --out x    # exits 2
```

Process exit codes are those of the `boris` binary. `zig build run -- …` is a
convenience wrapper: when the binary exits non-zero, the build step fails and
the shell typically sees exit `1` from `zig build` itself. Prefer
`zig-out/bin/boris` (or unit tests) when asserting exact codes `1`/`2`/`3`.

## Build steps

| Step | Purpose |
|------|---------|
| `zig build` | Build and install `boris` and `boris-source-rag` |
| `zig build run -- [args]` | Run `boris` with optional arguments after `--` |
| `zig build test` | Run unit tests (includes fixture inventory) |
| `zig build source-rag` | Generate a **source-code** RAG pack for LLM upload |

### Source RAG (standalone tool)

For dumping **repo sources** into an LLM notebook/chat knowledge pack (not the
product content/site RAG). Full guide: [`tools/source-rag/README.md`](tools/source-rag/README.md).

```bash
zig build source-rag
# custom output:
zig build source-rag -- --out=./uploads/source-rag
# or after install:
zig-out/bin/boris-source-rag --help
```

Output defaults to `source-rag/` (`INDEX.md`, `files/**`, catalogs). Separate
binary under `tools/source-rag/` — not wired into the product `boris` CLI.

## Documentation

| Doc | Role |
|-----|------|
| [`docs/STATUS.md`](docs/STATUS.md) | Living “where we are” snapshot |
| [`docs/contracts/`](docs/contracts/) | **Normative** machine contracts (frontmatter, paths, IR, diagnostics, RAG export, Apex ABI) |
| [`docs/rag/system/`](docs/rag/system/) | Narrative architecture seeds (incl. name / Load·Roll·Ignite·Reset) |
| [`fixtures/`](fixtures/) | Content fixture corpus + manifest (inventory tests only) |
| [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) | Release checklist |
| [`tools/source-rag/README.md`](tools/source-rag/README.md) | Source RAG tool |
| [`AGENTS.md`](AGENTS.md) | Long-term direction and hard constraints for contributors |

### Normative contracts (milestone 2)

| Contract | Topic |
|----------|-------|
| [frontmatter.md](docs/contracts/frontmatter.md) | Closed frontmatter grammar; keys `id`, `title`, `parent`, `status`, `tags` only |
| [identity-and-paths.md](docs/contracts/identity-and-paths.md) | Entity ids, `/` paths, case-sensitive `.md`/`.mdx` |
| [scanner.md](docs/contracts/scanner.md) | Deterministic discovery, sort key, symlink policy |
| [diagnostics.md](docs/contracts/diagnostics.md) | Stable codes (`EDUPLICATEID`, …), exit behavior |
| [ir-schema.md](docs/contracts/ir-schema.md) | Trunk/Satellite graph; JSON IR under `.boris/` |
| [rag-export.md](docs/contracts/rag-export.md) | Optional RAG export; `:::kind` is export-only / deferred |
| [apex-abi.md](docs/contracts/apex-abi.md) | In-process Apex C ABI + Zig wrapper (m8; not default CLI) |

**Author-facing parent key is only `parent`.** Do not use `parentEntry`.

## Status

- **Milestones 1–7:** CLI, scanner, frontmatter, IR JSON, optional RAG export.
- **Milestone 8:** in-process Apex C ABI + defensive Zig wrapper (linked and
  tested; default IR/RAG paths do not call Apex). See
  [`docs/STATUS.md`](docs/STATUS.md).

Optional Apex checks:

```bash
zig build test-apex-hostile
zig build test-apex-sanitize   # documents skip if sanitizers unavailable
```
