# Project status — Boris milestone 2

**As of:** 2026-07-13 (product **0.0.1** foundation + contracts)  
**Zig target:** 0.16.0 (`build.zig.zon` / CI pin **0.16.0**)

This file is the living **“where we are”** note. Prefer it (and
[`CHANGELOG.md`](../CHANGELOG.md)) over archaeology in git history when
starting a session.

---

## One-line product (current phase)

**Boris milestone 2 freezes normative contracts and a fixture inventory** for the
future content compiler. The default CLI remains a `--help` stub; no scanner or
parser is shipped yet.

---

## What works today

| Capability | Status | Notes |
|------------|--------|--------|
| `zig build` → `boris` executable | **Shipped** | `zig-out/bin/boris` |
| `zig build run -- [args]` | **Shipped** | Forwards args after `--` |
| `zig build test` | **Shipped** | CLI + **fixture inventory** + source-rag tool tests |
| CLI `--help` / `-h` | **Shipped** | Usage on stdout; exit 0; no filesystem scan |
| Unknown CLI args | **Shipped** | Usage + exit 2 |
| Normative contracts | **Shipped (docs)** | [`docs/contracts/`](contracts/) — design law, not binary proof |
| Fixture corpus | **Shipped (inventory)** | [`fixtures/`](../fixtures/) + `src/fixtures_test.zig` |
| Source RAG tool (`boris-source-rag`) | **Shipped** | Standalone; `zig build source-rag` → `source-rag/` |
| Content discovery / frontmatter | **Not started** | Contracts written; implementation next |
| Parent graph / JSON IR | **Not started** | |
| Product RAG export (`boris-rag`) | **Not started** | Contract: [contracts/rag-export.md](contracts/rag-export.md) |
| Apex / HTML assemble | **Not started** (default product) | Tree may contain experimental modules; not wired into default CLI |
| Watch / incremental / parallel workers | **Not started** | |

### How to run

```bash
zig build                 # binary → zig-out/bin/boris (+ boris-source-rag)
zig build run -- --help   # usage; exit 0
zig build test            # unit tests (includes fixture inventory)
zig build source-rag      # source-code pack for LLM upload → source-rag/
```

Exit codes (milestone 1 product CLI): `0` success, `2` usage/flags.  
Future compiler: `1` content validation, `3` I/O — see
[contracts/diagnostics.md](contracts/diagnostics.md).  
Source-rag tool also uses `3` for I/O failures.

### Source RAG (standalone — not product pipeline)

Pack repo sources for LLM notebooks. Details: [`tools/source-rag/README.md`](../tools/source-rag/README.md).

```bash
zig build source-rag                    # → source-rag/
zig build source-rag -- --out=./uploads/source-rag
zig-out/bin/boris-source-rag --help
```

| Product `rag/` (if present) | `source-rag/` from this tool |
|-----------------------------|------------------------------|
| Site content + narrative seeds | `src/**`, docs, build files, tools, … |
| Not regenerable on m1 CLI | Regenerable anytime via `zig build source-rag` |

---

## Documentation map

| Doc | Role |
|-----|------|
| `README.md` | Human front door; implemented vs planned |
| `AGENTS.md` | Long-term direction and hard constraints |
| `docs/contracts/` | **Normative** v0.1 contracts (frontmatter, paths, IR, diagnostics, RAG plan) |
| `fixtures/` | Content fixture inventory + expected category list |
| `tools/source-rag/README.md` | Source RAG tool (LLM codebase pack) |
| `docs/RELEASE-GATE.md` | Checklist (mostly unchecked at m2) |
| `CHANGELOG.md` | What changed |

### Normative contract index

| File | Topic |
|------|-------|
| [frontmatter.md](contracts/frontmatter.md) | Closed grammar; five keys only; no `parentEntry` |
| [identity-and-paths.md](contracts/identity-and-paths.md) | Ids, `/` paths, case-sensitive `.md`/`.mdx` |
| [diagnostics.md](contracts/diagnostics.md) | `EDUPLICATEID`, `EPARENT*`, `EFRONTMATTER`, … |
| [ir-schema.md](contracts/ir-schema.md) | Trunk/Satellite; `.boris/` JSON IR |
| [rag-export.md](contracts/rag-export.md) | Optional future export; `:::kind` export-only |

---

## Known gaps (expected at m2)

- No scanner, parser, graph, IR emit, or diagnostics pipeline on the default CLI
- Fixtures are **inventory-tested only** — not compiler-validated
- No Apex C-ABI product path on the default CLI
- No **product** RAG export (`boris --rag`), HTML `dist/`, or configuration framework
- Source RAG tool is available; product content RAG is not
- Release-gate checklist items beyond foundation remain unchecked
- Experimental modules may exist under `src/` / `docs/contracts/fixtures/` from
  earlier exploration; they are **not** the m2 fixture surface (use root
  `fixtures/`) and are **not** wired into the default CLI
