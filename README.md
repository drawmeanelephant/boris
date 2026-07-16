# Boris

**Write Markdown docs. Run one binary. Get a site.**

Boris is a **Zig** documentation compiler: it discovers your pages, validates a
Trunk/Satellite content graph, and by default publishes HTML under `dist/`. Need
machine IR or an LLM knowledge pack? Same tool — different flags.

Named for the folk **Zouave** figure known as **Boris** — improvise under
constraint, chain the next leaf, clear the slate. Compile rhythm (narrative,
not CLI flags): **Load → Roll → Ignite → Reset**. Independent software; **not**
affiliated with any commercial tobacco or rolling-paper brand.

| | |
|--|--|
| Language | Zig **0.16.0** (`build.zig.zon` / CI pin) |
| Product | **0.3.1** / compiler **boris/0.3.1** |
| IR schema | **0.2.0** (typed dependency endpoints + reverse index) |
| License | [MIT](LICENSE) |

**v0.3.1** uses those same frozen dependencies to expand incremental HTML dirty
sets; IR remains schema 0.2.0. It builds
on the **v0.2.1** Feature 7 HTML include/wiki path and the **v0.2.0**
HTML-default cut. See
[`CHANGELOG.md`](CHANGELOG.md) and [`docs/STATUS.md`](docs/STATUS.md).

---

## Why it exists (outcomes)

| Outcome | What that means day-to-day |
|---------|----------------------------|
| **Ship a docs site without a JS toolchain** | `boris` → `dist/**/*.html`. No Node, no bundler, no React runtime for the compile. |
| **Markdown that looks like modern docs** | Real **ApexMarkdown Unified** (tables, footnotes, lists, callouts, …) — not a toy stub. |
| **Callouts that stay on the page** | Constrained `<Aside>` components in document order (not separate mini-sites). |
| **Structure you can trust** | Trunk/Satellite graph validation fails loud on broken parents, cycles, duplicates. |
| **Rebuilds that stay lean** | Unchanged pages can be skipped (`--incremental` / `--watch`). Parallel page work with `--jobs N`. Layout + body stream to disk instead of building one giant intermediate HTML string. |
| **Same content, different products** | HTML site, JSON IR (`--out`), or deterministic RAG pack (`--rag`) from one tree. |
| **Give an LLM grounded project context** | Deterministic provenance-rich Context Bundle (`--context`) from the validated graph. |
| **Draft vs production outputs** | Multi-target builds with isolated dirs and caches (`--target`). |

That last performance paragraph is **design intent**, not a stopwatch claim.
Large trees still need measurement; the architecture avoids the usual
“concatenate the whole site in memory” tax.

Living phase note: [`docs/STATUS.md`](docs/STATUS.md).

---

## Quick start

```bash
# Needs Zig 0.16 + CMake (compile-time only: builds vendored ApexMarkdown)
zig build
./zig-out/bin/boris --quiet          # site → dist/
./zig-out/bin/boris --help
zig build test
./scripts/release-gate.sh
```

```bash
./zig-out/bin/boris                              # HTML under dist/
./zig-out/bin/boris --out .boris --quiet         # JSON IR only
./zig-out/bin/boris --rag --quiet                # LLM corpus under rag/
./zig-out/bin/boris --jobs 4 --quiet
./zig-out/bin/boris --watch
./zig-out/bin/boris --target prod=dist/prod --target stage=dist/stage
```

**Migration:** older scripts that assumed bare `boris` wrote IR should pass
`--out .boris` (or `--no-rag`).

---

## CLI cheat sheet

| Command | Result |
|---------|--------|
| `boris` | **HTML site** under `dist/` (default) |
| `boris --html-dir DIR` | HTML under `DIR` |
| `boris --jobs N` / `--watch` / `--incremental` | Faster / live / skip-unchanged HTML builds |
| `boris --out DIR` | **JSON IR** under `DIR` (no HTML) |
| `boris --no-rag` | Explicit IR (default out `.boris`) |
| `boris --rag` / `--rag-dir DIR` | **RAG corpus** only |
| `boris --context` / `--context-dir DIR` | **AI Context Bundle** only |
| `boris --target name=dir` | Multi-target HTML (repeatable; order-independent) |
| `boris --help` | Usage; exit 0; no filesystem walk |

### Options (short)

| Option | Default | Notes |
|--------|---------|--------|
| `--input <DIR>` | `content` | Content root |
| `--out <DIR>` | `.boris` when IR | Selects IR mode |
| `--html-dir <DIR>` | `dist` when HTML | Selects HTML mode |
| `--html-layout <PATH>` | `layouts/main.html` | Global layout (`{{content}}` once) |
| `--target NAME=DIR` | — | Named HTML root (not with `--html-dir`); any order |
| `--target-layout N=P` | — | Per-target layout; may precede or follow `--target` |
| `--jobs N` / `-j N` | `1` | Parallel HTML workers `1–64` |
| `--incremental` / `--watch` | off | Dirty-set rebuilds; watch implies incremental; OK with `--target` |
| `--quiet` | off | Less stderr; exit codes unchanged |

Also accepted: `--input=DIR`, `--out=DIR`, `--rag-dir=DIR`, `--html-dir=DIR`,
`--jobs=N`, `-j=N`, `--target=NAME=DIR`, etc.

### Mode rules (essentials)

1. **Default = HTML** (`dist/` as target `"default"`).
2. `--out` or `--no-rag` → **IR**.
3. `--rag` / `--rag-dir` → **RAG-only**.
4. `--html` / `--html-dir` / `--target` / `--target-layout` → **HTML** (explicit).
5. Mixing IR/RAG flags with HTML selectors → exit **2**.
6. `--jobs` / `--watch` / `--incremental` with IR or RAG → exit **2**.
7. Invalid target names, collisions, workspace escape, content/layout overlap → exit **2**.
8. Equivalent `--target` / `--target-layout` permutations yield the same config (targets sorted by name).

Exit codes: **0** success · **1** content · **2** usage · **3** I/O.

### Outputs

```text
dist/**/*.html                 # default HTML (or each --target root)
.boris/{manifest,graph,build-report}.json   # IR via --out
rag/{INDEX,system,content,graph,catalog…}   # via --rag
```

**Trusted authors only on the HTML path:** raw HTML in Markdown is passed
through. Do not feed untrusted contributor content without a sanitizer.
Details: [apex-abi.md](docs/contracts/apex-abi.md).

Author frontmatter key for parents is **`parent` only** (not `parentEntry`).
See [frontmatter.md](docs/contracts/frontmatter.md).

---

## Capability status

| Behavior | Status |
|----------|--------|
| Default HTML site + real ApexMarkdown Unified | **Done** |
| Trunk/Satellite graph, closed frontmatter, Asides | **Done** |
| IR 0.2 graph-native dependencies + RAG export | **Done** |
| Bounded semantic relations + Context Bundles | **Topic branch** |
| Incremental, watch, parallel jobs, multi-target | **Done** |
| CI Linux + macOS | **Done** |
| Graph-aware HTML nav (`{{nav}}` / breadcrumb) | **Done** (Feature 6 MVP) |
| In-page heading `{{toc}}` | **Done** — outline from body h1–h3 ids |
| Full YAML / MDX | **Out of scope** |

---

## Build steps

| Step | Purpose |
|------|---------|
| `zig build` | Install `boris`, `boris-source-rag`, `boris-package` |
| `zig build run -- [args]` | Run `boris` (wrapper; prefer `zig-out/bin/boris` for exact exit codes) |
| `zig build test` | Unit + fixture tests |
| `zig build test-apex-hostile` | Hostile Apex ABI doubles |
| `zig build test-apex-sanitize` | Optional ASan/UBSan smoke |
| `zig build source-rag` | **Source-code** pack for LLM upload (`source-rag/`) — not product site RAG |
| `zig build package` | Review tar under `packages/` |
| `./scripts/release-gate.sh` | Mechanical ship gate |

---

## Documentation map

| Doc | Role |
|-----|------|
| [`docs/STATUS.md`](docs/STATUS.md) | Living phase + next work |
| [`docs/contracts/`](docs/contracts/) | **Normative** contracts (ownership in that README) |
| [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) | Release checklist |
| [`docs/rag/system/`](docs/rag/system/) | RAG architecture seeds |
| [`content/AGENT-DIRECTIVE.txt`](content/AGENT-DIRECTIVE.txt) | Brief for rebuilding sample `content/` |
| [`AGENTS.md`](AGENTS.md) | Contributor / agent hard constraints |
| [`CHANGELOG.md`](CHANGELOG.md) | What changed |


### Normative contracts (canonical)

| Contract | Topic |
|----------|-------|
| [frontmatter.md](docs/contracts/frontmatter.md) | Closed FM keys |
| [identity-and-paths.md](docs/contracts/identity-and-paths.md) | Entity ids & paths |
| [scanner.md](docs/contracts/scanner.md) | Discovery |
| [diagnostics.md](docs/contracts/diagnostics.md) | Codes & exits |
| [ir-schema.md](docs/contracts/ir-schema.md) | Graph + JSON IR |
| [rag-export.md](docs/contracts/rag-export.md) | RAG corpus |
| [components.md](docs/contracts/components.md) | `<Aside>` |
| [apex-abi.md](docs/contracts/apex-abi.md) | Apex host ABI |
| [html-output.md](docs/contracts/html-output.md) | HTML path (default CLI) |
| [parallel-rendering.md](docs/contracts/parallel-rendering.md) | `--jobs` |
| [watch-mode.md](docs/contracts/watch-mode.md) | `--watch` |
| [multi-target-isolated-output.md](docs/contracts/multi-target-isolated-output.md) | `--target` |

---

## Status (short)

- **Shipped:** content graph, IR, RAG, Asides, real Apex Unified, HTML default,
  incremental/watch/jobs/multi-target, graph nav + in-page `{{toc}}`,
  includes + wiki-links (Feature 7), typed IR dependency edges + reverse index
  (Feature 8.1–8.3). Product **v0.3.1**.
- **Next:** wiki `#heading` targets and post-F8 build-system productization — see
  [`docs/STATUS.md`](docs/STATUS.md).
