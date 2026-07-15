# Boris

**Zig-native content compiler** growing into an Apex-native static site generator:
deterministic scan → bounded frontmatter → PageDb → Trunk/Satellite graph →
JSON IR under `.boris/`, optional RAG under `rag/`, or opt-in HTML under `dist/`
(and named multi-target output roots).

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
| Typed CLI (`--input`, `--out`, `--rag`, `--html`, `--jobs`, `--watch`, `--target`, …) | **Implemented** |
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
| Opt-in HTML site mode (`--html` / `--html-dir` / `--target`) | **Implemented** — Apex + Whiteboard + layout splice ([html-output](docs/contracts/html-output.md)) |
| Incremental HTML (`--incremental`) | **Implemented** — content-addressed fingerprints + dirty-set |
| Bounded parallel HTML render (`--jobs N`) | **Implemented** — opt-in workers ([parallel-rendering](docs/contracts/parallel-rendering.md)) |
| Watch mode (`--watch`) | **Implemented** — debounced/coalesced; portable polling fallback ([watch-mode](docs/contracts/watch-mode.md)) |
| Multi-target isolated outputs (`--target`) | **Implemented** — per-target cache/stage isolation ([multi-target](docs/contracts/multi-target-isolated-output.md)) |
| `zig build test` | **Implemented** — CLI + fixtures + scanner + parser + pipeline + RAG + Apex + HTML |
| Normative contracts under [`docs/contracts/`](docs/contracts/) | **Normative + implemented** (see ownership map) |
| Apex C ABI (in-process) | **Implemented** — linked + tested; **host stub** today ([contract](docs/contracts/apex-abi.md)) |
| ApexMarkdown Unified pin | **Pinned** — `vendor/apex-markdown/` @ v1.1.11 ([VENDOR.md](vendor/apex-markdown/VENDOR.md)); **not linked yet** (Feature 1 Chat 2+) |
| HTML `dist/` as **default** CLI (no flags) | **Roadmap** — bare `boris` remains IR-first today |
| Real ApexMarkdown Unified fidelity | **In progress** — host adapter + link under existing `apex.h` ([APEX-Feature1-plan.md](APEX-Feature1-plan.md)) |
| Full YAML / MDX | **Out of scope** for v0.1 |

## What works today (CLI)

| Command | Behavior |
|---------|----------|
| `boris --help` / `boris -h` | Print usage; exit **0** (no directories opened) |
| `boris` | **IR mode (default):** scan `content/` → write `.boris/` JSON IR |
| `boris --input DIR --out DIR` | IR mode with custom paths |
| `boris --no-rag` | Explicit IR mode |
| `boris --rag` | RAG-only: shared graph validation → corpus under `rag/` |
| `boris --rag-dir DIR` | RAG-only with output directory `DIR` |
| `boris --html` | HTML site under `dist/` (single target named `default`) |
| `boris --html-dir DIR` | HTML site under `DIR` |
| `boris --html --jobs 4` | HTML with bounded parallel page workers |
| `boris --html --watch` | HTML watch mode (implies `--incremental`) |
| `boris --html --incremental` | Opt-in content-addressed incremental HTML |
| `boris --target prod=dist/prod --target stage=dist/stage` | Multi-target HTML (isolated outputs/caches) |
| content validation failure | Diagnostics on stderr; exit **1** (IR, RAG, HTML) |
| conflicting / unknown flags | Print usage; exit **2** |
| missing content root / I/O | Exit **3** |

### Options

| Option | Default | Notes |
|--------|---------|--------|
| `--input <DIR>` | `content` | Content root |
| `--out <DIR>` | `.boris` | IR output (**IR mode only**) |
| `--rag` | — | Select RAG-only mode |
| `--no-rag` | — | Explicit IR mode |
| `--rag-dir <DIR>` | `rag` (when RAG) | Implies RAG-only mode |
| `--html` | — | HTML site mode → `--html-dir` (default `dist`) |
| `--html-dir <DIR>` | `dist` (when HTML) | Implies HTML; single target `default` |
| `--html-layout <PATH>` | `layouts/main.html` | Global layout template (HTML mode) |
| `--target NAME=DIR` | — | Named HTML output root (repeatable; exclusive with `--html-dir`) |
| `--target-layout NAME=PATH` | — | Per-target layout override |
| `--incremental` | off | Content-addressed incremental HTML (requires HTML mode) |
| `--watch` | off | Debounced HTML rebuild loop (implies `--incremental`; requires HTML) |
| `--jobs N` / `-j N` | `1` | Bounded parallel HTML workers `1–64` (requires HTML) |
| `--quiet` | off | Suppress progress + diagnostic stderr (exit codes/artifacts unchanged) |
| `-h`, `--help` | — | Help; exit 0 |

Also accepted: `--input=DIR`, `--out=DIR`, `--rag-dir=DIR`, `--html-dir=DIR`,
`--html-layout=PATH`, `--target=NAME=DIR`, `--target-layout=NAME=PATH`,
`--jobs=N`, `-j=N`.

### Mode rules

1. Default mode is **IR** (bare `boris` writes `.boris/`; HTML default is roadmap).
2. `--no-rag` explicitly selects IR mode.
3. `--rag` selects **RAG-only** mode.
4. `--rag-dir DIR` implies **RAG-only** mode.
5. `--html`, `--html-dir`, or `--target` select **HTML** mode.
6. `--rag` and `--no-rag` together → usage error (exit 2).
7. `--no-rag` and `--rag-dir` together → usage error (exit 2).
8. Explicit `--out` with `--rag`, `--rag-dir`, `--html`, `--html-dir`, or `--target` → usage error (exit 2).
9. `--target` with `--html-dir` → usage error (exit 2).
10. `--watch`, `--incremental`, or `--jobs` without HTML mode → usage error (exit 2).
11. Empty values for path options → usage error (exit 2).
12. Unknown options, missing values, positionals, duplicate flags → usage error (exit 2).
13. `--help` / `-h` exit 0 without opening directories or scanning content.

### Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Success (help, valid IR, valid RAG, or valid HTML) |
| `1` | Content validation error (shared graph/frontmatter diagnostics) |
| `2` | Usage / CLI error (including target validation) |
| `3` | I/O or system error |

### RAG output (success)

```text
rag/
  INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json
  system/**  content/pages/**  graph/entity-catalog.md  graph/relations.md
```

Same scanner, parser, PageDb records, and `graph.validate` as IR mode. Aside
export uses `:::kind` / `:::kind{id="…"}` form (non-round-trippable; not an
authoring syntax). See
[docs/contracts/rag-export.md](docs/contracts/rag-export.md).

### HTML output (success)

```text
dist/**/*.html                    # or each --target output root
<target>/.boris-cache/manifest.json   # with --incremental / --watch
```

Apex renders markdown in-process (current engine is a **minimal stub**, not
CommonMark-complete). Layout default: `layouts/main.html` with one `{{content}}`
splice. See [docs/contracts/html-output.md](docs/contracts/html-output.md),
[parallel-rendering.md](docs/contracts/parallel-rendering.md),
[watch-mode.md](docs/contracts/watch-mode.md), and
[multi-target-isolated-output.md](docs/contracts/multi-target-isolated-output.md).

## Quick start

```bash
# Requires Zig 0.16.0
zig build                          # install → zig-out/bin/boris (+ boris-source-rag)
zig build run -- --help            # usage; exit 0
zig build run -- --input fixtures/content/valid --out /tmp/boris-ir --quiet
zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag --quiet
zig build run -- --input test/fixtures/html/content --html-dir /tmp/boris-dist --quiet
zig build run -- --input test/fixtures/html/content --html --jobs 4 --quiet
zig build run -- --rag --no-rag    # usage conflict; exit 2
zig build run -- --rag --out x     # usage conflict; exit 2
zig build test                     # unit tests (CLI + fixtures + scanner + pipeline + RAG + HTML)
zig build source-rag               # source pack for LLM upload → source-rag/
zig build package                  # review tar → packages/boris-package.tar
./scripts/release-gate.sh          # mechanical ship checks
```

```bash
zig-out/bin/boris --help
zig-out/bin/boris --input content --out .boris --quiet
zig-out/bin/boris --rag --input content --quiet
zig-out/bin/boris --html --input test/fixtures/html/content --quiet
zig-out/bin/boris --target prod=dist/prod --target stage=dist/stage --quiet
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
| `zig build` | Build and install `boris`, `boris-source-rag`, and `boris-package` |
| `zig build run -- [args]` | Run `boris` with optional arguments after `--` |
| `zig build test` | Run unit tests (includes fixture inventory) |
| `zig build test-apex-hostile` | Hostile Apex ABI double tests |
| `zig build test-apex-sanitize` | Optional ASan+UBSan smoke (skips cleanly if unavailable) |
| `zig build source-rag` | Generate a **source-code** RAG pack for LLM upload |
| `zig build package` | Deterministic review tar under `packages/` (IR + optional RAG) |

### Review package

After a successful IR/RAG surface, produce a single inspectable archive:

```bash
zig build package
# or: zig-out/bin/boris-package --help
tar -tf packages/boris-package.tar
# inspect: MACHINE-READABLE-VERSION.json, SHA256SUMS, ir/*.json, rag/**
```

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
| [`docs/STATUS.md`](docs/STATUS.md) | Living “where we are” snapshot + post-P3 roadmap |
| [`docs/contracts/`](docs/contracts/) | **Normative** machine contracts (ownership map in README) |
| [`docs/rag/system/`](docs/rag/system/) | Narrative architecture seeds (incl. name / Load·Roll·Ignite·Reset) |
| [`fixtures/`](fixtures/) | Content fixture corpus + manifest (inventory tests only) |
| [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) | Release checklist |
| [`tools/source-rag/README.md`](tools/source-rag/README.md) | Source RAG tool |
| [`AGENTS.md`](AGENTS.md) | Long-term direction and hard constraints for contributors |

### Normative contracts (canonical)

| Contract | Topic |
|----------|-------|
| [frontmatter.md](docs/contracts/frontmatter.md) | Closed frontmatter grammar; keys `id`, `title`, `parent`, `status`, `tags` only |
| [identity-and-paths.md](docs/contracts/identity-and-paths.md) | Entity ids, `/` paths, case-sensitive `.md`/`.mdx` |
| [scanner.md](docs/contracts/scanner.md) | Deterministic discovery, sort key, symlink policy |
| [diagnostics.md](docs/contracts/diagnostics.md) | Stable codes (`EDUPLICATEID`, …), exit behavior |
| [ir-schema.md](docs/contracts/ir-schema.md) | Trunk/Satellite graph; JSON IR under `.boris/` |
| [rag-export.md](docs/contracts/rag-export.md) | Optional RAG export; `:::kind` is export-only |
| [components.md](docs/contracts/components.md) | Constrained `<Aside>` tokenizer |
| [apex-abi.md](docs/contracts/apex-abi.md) | In-process Apex C ABI + Zig wrapper (stub ≠ CommonMark) |
| [html-output.md](docs/contracts/html-output.md) | Opt-in HTML Whiteboard, Aside stream, layout splice, Atomic publish |
| [parallel-rendering.md](docs/contracts/parallel-rendering.md) | Bounded `--jobs` HTML workers |
| [watch-mode.md](docs/contracts/watch-mode.md) | Opt-in `--watch` rebuild loop |
| [multi-target-isolated-output.md](docs/contracts/multi-target-isolated-output.md) | Multi-target outputs and cache namespaces |

Full ownership map: [docs/contracts/README.md](docs/contracts/README.md).

**Author-facing parent key is only `parent`.** Do not use `parentEntry` or
`parent_entry` in source frontmatter (rejected as `EFRONTMATTER`). RAG catalog
column `parent_entry` is export packaging only — see
[docs/contracts/frontmatter.md](docs/contracts/frontmatter.md)
(migration / compatibility note).

## Status

- **Milestones 1–10 / v0.1 content-compiler bar:** CLI, scanner, frontmatter, IR
  JSON, optional RAG, Aside, Apex ABI, hardening, dual-OS CI.
- **P2 (complete):** dependency indexes, includes, fingerprints, `--incremental`.
- **P3 (complete):** `--jobs`, `--watch`, multi-target isolation (`--target`,
  layouts, stage commit, selective watch fan-out).
- **Next:** Apex CommonMark fidelity, then HTML as default CLI mode. See
  [`docs/STATUS.md`](docs/STATUS.md).

Optional Apex checks:

```bash
zig build test-apex-hostile
zig build test-apex-sanitize   # documents skip if sanitizers unavailable
```
