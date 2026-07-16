# Boris

**Write Markdown docs. Run one local binary. Get a validated static site.**

Boris is a **Zig documentation compiler** — not a Node SSG. It discovers your
pages, validates a Trunk/Satellite content graph, and by default publishes HTML
under `dist/`. The same binary can also emit JSON IR, a deterministic RAG pack,
or an AI Context Bundle.

| | |
|--|--|
| Language | Zig **0.16.0** (`build.zig.zon` / CI pin) |
| Product | **0.5.0** / compiler **boris/0.5.0** |
| IR schema | **0.2.0** (typed dependency endpoints + reverse index) |
| License | [MIT](LICENSE) |

Living phase note: [`docs/STATUS.md`](docs/STATUS.md) · history:
[`CHANGELOG.md`](CHANGELOG.md).

---

## What it does

```text
Markdown + closed frontmatter
        │
        ▼
  discover → validate graph → render
        │
        ├──► HTML site      (default → dist/)
        ├──► JSON IR        (--out)
        ├──► RAG corpus     (--rag)
        └──► Context Bundle (--context)
```

Teaching rhythm (narrative only, not CLI flags): **Load → Roll → Ignite → Reset**.

Named for the folk **Zouave** figure known as **Boris** — improvise under
constraint, chain the next leaf, clear the slate. Independent software; **not**
affiliated with any commercial tobacco or rolling-paper brand.

---

## Why it exists

Most documentation stacks grew into JavaScript app toolchains. Boris takes the
opposite path: a **local Zig binary** that treats docs as a **validated content
graph**, not a mini web app.

| You want… | Boris gives you… |
|-----------|------------------|
| A docs site without a JS toolchain | `boris` → `dist/**/*.html` — no Node, bundler, or React runtime for the compile |
| Markdown that looks like modern docs | Real **ApexMarkdown Unified** in-process (tables, footnotes, lists, …) — not a toy stub |
| Callouts that stay on the page | Constrained `<Aside>` components in document order |
| Structure you can trust | Trunk/Satellite parents, wiki targets, and includes **fail the build** when invalid |
| Rebuilds that stay lean | Skip unchanged pages (`--incremental` / `--watch`); parallel HTML with `--jobs N` |
| Same content, different products | HTML, JSON IR, RAG pack, or Context Bundle from one tree |

Performance shape is **design intent** (stream layout + body, wipe page scratch,
optional incremental/parallel) — not a published stopwatch claim. Measure your
tree before advertising numbers.

---

## Why choose Boris over a Node docs stack?

Honest differentiators — not a feature-parity matrix against every plugin.

| Dimension | Typical Node SSG | Boris (today) |
|-----------|------------------|---------------|
| Runtime to **build** the site | Node + package tree | Local `boris` binary after Zig/CMake **build** of Boris itself |
| Content model | Often flexible YAML/MDX | **Closed** frontmatter (`id`, `title`, `parent`, `status`, `tags` only) |
| Internal structure | Conventions / plugins | Validated **Trunk/Satellite** graph; invalid parents fail loud |
| In-page links | Often soft warnings | `[[entity-id]]` / `[[entity-id#heading]]` **fail** if missing; ordinary Markdown `[]()` hrefs are **not** fully link-checked |
| Output products | Usually HTML (+ ad-hoc scripts) | HTML **or** IR **or** RAG **or** Context Bundle (modes do not mix) |
| Themes | Component frameworks common | Trusted **static** HTML layouts + copied assets — no CDN fetch in the compile path |
| Extensibility | MDX / JS in content | Allowlisted `<Aside>` / `<Details>` + includes — **no** unrestricted MDX |

**Host tools to *compile Boris*:** Zig **0.16** + **CMake** (CMake builds vendored
ApexMarkdown static libs at compile time only). Authors and CI that already have
`zig-out/bin/boris` do not need Node to publish docs.

**Not claimed:** universal broken-link prevention, universal Astro/MkDocs/Hugo
import, cross-OS bit-identical trees, or “zero dependencies” for building the
compiler.

---

## Five-minute quickstart

Needs **Zig 0.16** and **CMake** once, to build the binary.

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
./zig-out/bin/boris --quiet          # sample content/ → dist/
```

Open `dist/index.html` (or serve `dist/` with any static file server). You should
see site nav, breadcrumb, and an in-page TOC on pages with headings.

```bash
./zig-out/bin/boris --help
./zig-out/bin/boris --out .boris --quiet     # JSON IR
./zig-out/bin/boris --rag --quiet            # LLM corpus → rag/
./zig-out/bin/boris --context --quiet        # AI Context Bundle → context/
./zig-out/bin/boris check                    # read-only; exit 1 if unreferenced pages
./zig-out/bin/boris impact getting-started   # sample Trunk id in this repo
zig build test
```

Sample `content/` currently reports `index` as unreferenced, so `check` exits
**1** even though HTML/IR/RAG/Context builds succeed — that is the CI health
gate, not a broken compiler.

**Minimal author page** (drop under `content/`; `parent` must name an existing
Trunk entity id — after clone, `getting-started` works):

```markdown
---
title: My first satellite
parent: getting-started
status: published
tags: [guides]
---

# My first satellite

Ship docs with one binary.
```

Author key for parents is **`parent` only** (not `parentEntry` /
`parent_entry`). Full grammar: [frontmatter contract](docs/contracts/frontmatter.md).
New section landings: [migration guide](docs/MIGRATION.md) (Trunk + Satellite).

### 15-minute demo path

1. `zig build` → `./zig-out/bin/boris --quiet` → open `dist/index.html` (nav, breadcrumb, TOC).
2. `./zig-out/bin/boris --context --quiet` → skim `context/bundle.md`.
3. `./zig-out/bin/boris check` — expect exit **1** on sample unreferenced `index` (policy finding).
4. Optional convert path: [`docs/MIGRATION.md`](docs/MIGRATION.md) fixture commands.

**Migration:** older scripts that assumed bare `boris` wrote IR should pass
`--out .boris` (or `--no-rag`). Converting an existing site:
[`docs/MIGRATION.md`](docs/MIGRATION.md).

---

## What is real today (AI, migration, analysis)

| Capability | Status | How |
|------------|--------|-----|
| HTML site (default) | **Product** | `boris` → `dist/` |
| JSON IR | **Product** | `boris --out .boris` |
| RAG corpus | **Product** | `boris --rag` |
| AI Context Bundle | **Product** (v0.4.0) | `boris --context` — deterministic `bundle.md` + provenance + graph; not a hosted service |
| Graph health / impact | **Product** (v0.4.0) | `boris check`, `boris impact <id>` — read-only; unreferenced findings can exit 1 |
| Layout rules / themes | **Product** | Static layouts + `--layout-rule`; see [templating contract](docs/contracts/templating-and-themes.md) |
| Includes + wiki-links | **Product** (HTML path) | `{{include}}`, `[[id]]`, `[[id#heading]]` — fail loud when invalid |
| Migration **guide** + fixture | **Product docs** | [`docs/MIGRATION.md`](docs/MIGRATION.md), [`fixtures/migration-site/`](fixtures/migration-site/) |
| Migration **labs** (Astro, WordPress, Instagram, Obsidian, Notion, Starlight, …) | **Developer aids** | Standalone under [`tools/migration-lab/`](tools/migration-lab/) — **not** runtime dependencies of `boris`; **not** universal importers |

Context Bundle contract: [`docs/contracts/context-bundle.md`](docs/contracts/context-bundle.md).
Documentation Intelligence: [`docs/contracts/documentation-intelligence.md`](docs/contracts/documentation-intelligence.md).

---

## Author essentials

1. **Closed frontmatter** — only `id`, `title`, `parent`, `status`, `tags`.
2. **One-level graph** — Satellites parent to **Trunks** only (no satellite-of-satellite).
3. **Fail-loud structure** — bad parents, missing wiki targets/headings, missing includes, and cycles exit **1** with diagnostics. Ordinary Markdown `[](url)` links are **not** a complete site-wide link checker.
4. **Asides** — `<Aside kind="tip">…</Aside>` (and related kinds) stay in document order.
5. **Trusted HTML authors** — raw HTML in Markdown is passed through. Do not feed untrusted contributor content without a sanitizer ([apex-abi](docs/contracts/apex-abi.md)).
6. **UTF-8 without BOM** — BOM rejects the file.

Exit codes: **0** success · **1** content · **2** usage · **3** I/O.

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
| `boris check` | Read-only graph-health report (CI findings exit 1) |
| `boris impact ID` | Read-only transitive impact report for one page |
| `boris --target name=dir` | Multi-target HTML (repeatable; order-independent) |
| `boris --help` | Usage; exit 0; no filesystem walk |

### Options (short)

| Option | Default | Notes |
|--------|---------|--------|
| `--input <DIR>` | `content` | Content root |
| `--out <DIR>` | `.boris` when IR | Selects IR mode |
| `--html-dir <DIR>` | `dist` when HTML | Selects HTML mode |
| `--html-layout <PATH>` | `layouts/main.html` | Global layout (`{{content}}` once) |
| `--theme ROOT` | — | Theme sugar → `ROOT/layouts/main.html` + managed `assets/` |
| `--target NAME=DIR` | — | Named HTML root (not with `--html-dir`); any order |
| `--target-layout N=P` | — | Per-target layout; may precede or follow `--target` |
| `--layout-rule T S P` | — | Per-page HTML layout: selector is `id:`, `glob:`, or `role:` |
| `--jobs N` / `-j N` | `1` | Parallel HTML workers `1–64` |
| `--incremental` / `--watch` | off | Dirty-set rebuilds; watch implies incremental; OK with `--target` |
| `--quiet` | off | Less stderr; exit codes unchanged |

Also accepted: `--input=DIR`, `--out=DIR`, `--rag-dir=DIR`, `--html-dir=DIR`,
`--jobs=N`, `-j=N`, `--target=NAME=DIR`, etc.

### Mode rules (essentials)

1. **Default = HTML** (`dist/` as target `"default"`).
2. `--out` or `--no-rag` → **IR**.
3. `--rag` / `--rag-dir` → **RAG-only**.
4. `--context` / `--context-dir` → **Context Bundle only**.
5. `--html` / `--html-dir` / `--target` / `--target-layout` → **HTML** (explicit).
6. Mixing IR/RAG/Context flags with HTML selectors → exit **2**.
7. `--jobs` / `--watch` / `--incremental` with IR, RAG, or Context Bundle → exit **2**.
8. Invalid target names, collisions, workspace escape, content/layout overlap → exit **2**.
9. Equivalent `--target` / `--target-layout` permutations yield the same config (targets sorted by name).

### Outputs

```text
dist/**/*.html                 # default HTML (or each --target root)
.boris/{manifest,graph,build-report}.json   # IR via --out
rag/{INDEX,system,content,graph,catalog…}   # via --rag
context/{bundle.md,manifest.json,graph.json,pages/…}  # via --context
```

## Keep a content graph healthy

`check` inspects the same validated graph Boris uses to compile. It is
read-only: it does not publish HTML, IR, RAG, or a Context Bundle. `check`
returns exit **1** when it finds unreferenced pages, so CI can treat the report
as a review gate.

```yaml
# Example GitHub Actions step after `zig build`
- name: Check documentation graph
  run: |
    ./zig-out/bin/boris check \
      --input content \
      --format json \
      --report .boris/check.json
```

The JSON report is an ordinary local file — not a hosted service. To see what a
change can affect (sample Trunk id in this repo):

```bash
./zig-out/bin/boris impact getting-started
```

Add `--format json` when another local tool needs the result.

## Shape one site into more than one page type

Keep one content tree; choose a layout per page at build time. Rules are
HTML-only and do not add layout syntax to frontmatter. Selectors:
`id:<entity-id>`, `glob:<segment-pattern>`, `role:trunk|satellite`.

Copy-pasteable example from [`examples/archive-theme/`](examples/archive-theme/):

```bash
./zig-out/bin/boris \
  --input examples/archive-theme/content \
  --theme examples/archive-theme/theme \
  --layout-rule default id:archive \
    examples/archive-theme/theme/layouts/archive.html \
  --html-dir test-output/archive-theme \
  --quiet
```

Contract detail: [templating and themes](docs/contracts/templating-and-themes.md).

## Use Boris as a pipeline stage

Validate and emit JSON IR for an external renderer or integration — keep that
renderer outside Boris:

```bash
./zig-out/bin/boris --input content --out .boris
```

Consumers read `.boris/manifest.json`, `graph.json`, and `build-report.json`
after exit 0.

---

## Capability status

| Behavior | Status |
|----------|--------|
| Default HTML site + real ApexMarkdown Unified | **Done** |
| Trunk/Satellite graph, closed frontmatter, Asides | **Done** |
| IR 0.2 graph-native dependencies + RAG export | **Done** |
| Documentation Intelligence, bounded semantic relations + Context Bundles | **Done** (v0.4.0) |
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
| [`docs/MIGRATION.md`](docs/MIGRATION.md) | Convert an existing Markdown site |
| [`docs/contracts/`](docs/contracts/) | **Normative** contracts (ownership in that README) |
| [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) | Release checklist |
| [`tools/migration-lab/README.md`](tools/migration-lab/README.md) | Standalone migration laboratories |
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
| [context-bundle.md](docs/contracts/context-bundle.md) | AI Context Bundle |
| [documentation-intelligence.md](docs/contracts/documentation-intelligence.md) | `check` / `impact` |
| [components.md](docs/contracts/components.md) | `<Aside>` and `<Details>` |
| [apex-abi.md](docs/contracts/apex-abi.md) | Apex host ABI |
| [html-output.md](docs/contracts/html-output.md) | HTML path (default CLI) |
| [includes-and-wiki-links.md](docs/contracts/includes-and-wiki-links.md) | Includes + wiki |
| [templating-and-themes.md](docs/contracts/templating-and-themes.md) | Themes + layout rules |
| [parallel-rendering.md](docs/contracts/parallel-rendering.md) | `--jobs` |
| [watch-mode.md](docs/contracts/watch-mode.md) | `--watch` |
| [multi-target-isolated-output.md](docs/contracts/multi-target-isolated-output.md) | `--target` |

---

## Status (short)

- **Shipped:** content graph, IR, RAG, Asides, real Apex Unified, HTML default,
  incremental/watch/jobs/multi-target, graph nav + in-page `{{toc}}`,
  includes + wiki-links, typed IR dependency edges + reverse index,
  Documentation Intelligence, Context Bundles, layout selection, Textile
  compatibility, and migration labs as **standalone developer aids**. Product
  **v0.5.0**.
- **Next:** real-site dogfood and release follow-through — see
  [`docs/STATUS.md`](docs/STATUS.md).
