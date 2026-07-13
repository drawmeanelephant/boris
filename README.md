# Boris

**Zig project foundation** (milestone 1) plus **normative contracts and fixture
inventory** (milestone 2).

Boris is intended to grow into a Zig-native content compiler / documentation
static-site toolchain. **The default product CLI does not compile content yet.**

| | |
|--|--|
| Language | Zig **0.16.0** (`build.zig.zon` / CI pin) |
| Product | **0.0.1** (foundation + contracts) |
| License | [MIT](LICENSE) |

## Implemented vs planned

| Behavior | Status |
|----------|--------|
| `boris --help` / `-h` | **Implemented** — usage on stdout; exit 0 |
| Unknown CLI args | **Implemented** — usage; exit 2 |
| `zig build test` | **Implemented** — CLI unit tests + fixture inventory + source-rag tests |
| Normative contracts under [`docs/contracts/`](docs/contracts/) | **Documented** (design law for future code) |
| Fixture corpus under [`fixtures/`](fixtures/) | **Inventory only** — files + manifest; not compiler-validated yet |
| Content discovery / frontmatter parse | **Planned** — see contracts |
| Trunk/Satellite graph + diagnostics | **Planned** — see contracts |
| Deterministic JSON IR under `.boris/` | **Planned** (default v0.1 output) |
| Optional product RAG export | **Planned** — [docs/contracts/rag-export.md](docs/contracts/rag-export.md) |
| Apex markdown render / HTML `dist/` | **Not** default product surface for v0.1 |
| Concurrency / watch / full YAML | **Out of scope** for v0.1 |

## What works today (CLI)

| Command | Behavior |
|---------|----------|
| `boris --help` / `boris -h` | Print concise usage; exit **0** |
| `boris` (no args) | Print concise usage; exit **0** |
| any other argument | Print usage; exit **2** |

Nothing else is implemented on the default CLI path: no content scan, frontmatter
parse, graph validation, JSON IR emit, Apex markdown render, product RAG export,
HTML `dist/` output, watch mode, or concurrency.

## Quick start

```bash
# Requires Zig 0.16.0
zig build                 # install → zig-out/bin/boris (+ boris-source-rag)
zig build run -- --help   # print usage (exit 0)
zig build test            # unit tests (CLI + fixtures inventory + source-rag)
zig build source-rag      # source pack for LLM upload → source-rag/
```

```bash
zig-out/bin/boris --help
zig-out/bin/boris --unknown   # exits 2
```

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
| [`fixtures/`](fixtures/) | Content fixture corpus + manifest (inventory tests only) |
| [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) | Release checklist |
| [`tools/source-rag/README.md`](tools/source-rag/README.md) | Source RAG tool |
| [`AGENTS.md`](AGENTS.md) | Long-term direction and hard constraints for contributors |

### Normative contracts (milestone 2)

| Contract | Topic |
|----------|-------|
| [frontmatter.md](docs/contracts/frontmatter.md) | Closed frontmatter grammar; keys `id`, `title`, `parent`, `status`, `tags` only |
| [identity-and-paths.md](docs/contracts/identity-and-paths.md) | Entity ids, `/` paths, case-sensitive `.md`/`.mdx` |
| [diagnostics.md](docs/contracts/diagnostics.md) | Stable codes (`EDUPLICATEID`, …), exit behavior |
| [ir-schema.md](docs/contracts/ir-schema.md) | Trunk/Satellite graph; JSON IR under `.boris/` |
| [rag-export.md](docs/contracts/rag-export.md) | Optional future RAG export; `:::kind` is export-only |

**Author-facing parent key is only `parent`.** Do not use `parentEntry`.

## Status

- **Milestone 1:** reproducible Zig 0.16 package, CLI help stub, tests, CI.
- **Milestone 2:** normative contracts + fixture inventory tests (no scanner/parser yet).

Later milestones implement discovery, frontmatter, graph IR, and related features
against these contracts. Treat narrative architecture notes elsewhere in the tree
as **intent**, not as a claim that those features ship today.
