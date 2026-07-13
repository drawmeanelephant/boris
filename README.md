# Boris

**Zig-native content compiler foundation** with typed CLI (m3), deterministic
content discovery + identity (m4), bounded frontmatter parser (m5), and
normative contracts / fixtures (m2).

Named for the folk **Zouave** figure known as **Boris** — improvise under
constraint, chain the next leaf, clear the slate. Compile rhythm (narrative,
not CLI flags): **Load → Roll → Ignite → Reset**. See
[`docs/rag/system/10-name-and-metaphor.md`](docs/rag/system/10-name-and-metaphor.md).
Independent software; **not** affiliated with any commercial tobacco or
rolling-paper brand.

Boris is growing into a documentation static-site toolchain. **The default CLI
does not yet run the content pipeline** — valid build modes print a controlled
stub message and exit 0 until discovery is wired in.

| | |
|--|--|
| Language | Zig **0.16.0** (`build.zig.zon` / CI pin) |
| Product | **0.0.1** (CLI surface + contracts) |
| License | [MIT](LICENSE) |

## Implemented vs planned

| Behavior | Status |
|----------|--------|
| Typed CLI (`--input`, `--out`, `--rag`, …) | **Implemented** — parse + mode rules |
| `boris --help` / `-h` | **Implemented** — usage on stdout; exit 0; no FS |
| Flag conflicts / unknown args | **Implemented** — usage; exit **2** |
| Exit codes 0 / 1 / 2 / 3 | **Implemented** (1 reserved for content pipeline) |
| Deterministic content scanner | **Implemented** (library) — `src/scanner.zig` |
| Canonical entity id / paths | **Implemented** (library) — `src/identity.zig` |
| `zig build test` | **Implemented** — CLI + fixtures + scanner + source-rag |
| Normative contracts under [`docs/contracts/`](docs/contracts/) | **Documented** (+ scanner contract) |
| Fixture corpus under [`fixtures/`](fixtures/) | **Inventory + scanner fixture tests** |
| Frontmatter parse / graph IR | **Planned** — see contracts |
| Content discovery wired into default CLI | **Planned** (library ready; CLI still stubs pipeline) |
| Trunk/Satellite graph + diagnostics | **Planned** — see contracts |
| Deterministic JSON IR under `.boris/` | **Planned** (default v0.1 output) |
| Optional product RAG export | **Planned** — [docs/contracts/rag-export.md](docs/contracts/rag-export.md) |
| Apex markdown render / HTML `dist/` | **Not** default product surface for v0.1 |
| Concurrency / watch / full YAML | **Out of scope** for v0.1 |

## What works today (CLI)

| Command | Behavior |
|---------|----------|
| `boris --help` / `boris -h` | Print usage; exit **0** (no directories opened) |
| `boris` | IR mode defaults; stub message; exit **0** |
| `boris --no-rag` | Explicit IR mode; stub; exit **0** |
| `boris --rag` | RAG-only mode; stub; exit **0** |
| `boris --rag-dir DIR` | RAG-only with corpus dir; stub; exit **0** |
| conflicting / unknown flags | Print usage; exit **2** |

### Options

| Option | Default | Notes |
|--------|---------|--------|
| `--input <DIR>` | `content` | Content root |
| `--out <DIR>` | `.boris` | IR output (IR mode only) |
| `--rag` | — | Select RAG-only mode |
| `--no-rag` | — | Explicit IR mode |
| `--rag-dir <DIR>` | `rag` (when RAG) | Implies RAG-only mode |
| `--quiet` | off | Suppress stub / progress messages |
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
| `0` | Success (help, or valid mode stub) |
| `1` | Content validation error (reserved; pipeline later) |
| `2` | Usage / CLI error |
| `3` | I/O or system error |

## Quick start

```bash
# Requires Zig 0.16.0
zig build                          # install → zig-out/bin/boris (+ boris-source-rag)
zig build run -- --help            # usage; exit 0
zig build run -- --quiet           # IR stub; exit 0
zig build run -- --rag --quiet     # RAG stub; exit 0
zig build run -- --rag-dir x --quiet
zig build run -- --rag --no-rag    # usage conflict; exit 2
zig build run -- --rag --out x     # usage conflict; exit 2
zig build test                     # unit tests (CLI + fixtures + scanner + source-rag)
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
| [`docs/contracts/`](docs/contracts/) | **Normative** machine contracts (frontmatter, paths, IR, diagnostics, RAG plan) |
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
| [rag-export.md](docs/contracts/rag-export.md) | Optional future RAG export; `:::kind` is export-only |

**Author-facing parent key is only `parent`.** Do not use `parentEntry`.

## Status

- **Milestone 1:** reproducible Zig 0.16 package, CLI help stub, tests, CI.
- **Milestone 2:** normative contracts + fixture inventory tests (no scanner/parser yet).
- **Milestone 3:** typed CLI parser, mode rules, exit-code model; pipeline still stubbed.
- **Milestone 4:** deterministic scanner + centralized identity (`scanner` /
  `identity` / discovery-only `Page`); CLI pipeline still stubbed.

Later milestones wire discovery into the CLI and implement frontmatter, graph IR,
and related features against these contracts.
