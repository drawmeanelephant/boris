# Project status — Boris

**As of:** 2026-07-15 · product **0.0.1** / compiler **boris/0.1.1** · Zig **0.16.0**  
**Phase:** HTML-default site compiler with real ApexMarkdown Unified.  
P2/P3 foundations, Feature 1 (Apex), and Feature 2 (HTML default) are **Done**.

Living snapshot for agents and humans. Prefer this and [`CHANGELOG.md`](../CHANGELOG.md)
over archaeology. Normative behavior: [`docs/contracts/`](contracts/).

---

## What you get (outcomes first)

| You want… | You get… | How |
|-----------|----------|-----|
| A docs site from Markdown | HTML under `dist/` | `boris` (default) |
| Tables, footnotes, callouts, real Markdown | ApexMarkdown Unified, not a toy stub | Feature 1 — in-process render |
| Callouts that stay in the page | Constrained `<Aside>` in document order | Shared compile path |
| “Did my graph still make sense?” | Fail-loud Trunk/Satellite validation | Exit **1** + diagnostics |
| Machine-readable graph/IR | JSON under `.boris/` | `boris --out .boris` |
| LLM knowledge pack of this project | Deterministic `rag/` corpus | `boris --rag` |
| Edit → rebuild only what changed | Incremental dirty-set HTML | `--incremental` / `--watch` |
| Faster multi-page HTML | Bounded parallel page workers | `--jobs N` |
| Draft vs prod from one tree | Isolated multi-target outputs | `--target name=dir` |

**Why it feels quick (honest, not brochure):** pages are not glued into one giant
HTML string. Layout chrome and body slices stream to the writer; per-page scratch
is wiped after each page. Unchanged pages can be skipped when you ask for
`--incremental`. That is a **design for lean builds**, not a published benchmark
claim — measure your tree before advertising numbers.

Internal names you may see in contracts (Whiteboard, host `apex_render`,
fingerprints) are **implementation detail**. Authors and most sessions should
think in outcomes above.

---

## One-line product

**Boris is a Zig documentation compiler:** load Markdown, validate a
Trunk/Satellite graph, ignite HTML (default), IR, or RAG, reset page scratch —
not a Node SSG stack.

Teaching beat (narrative only): **Load → Roll → Ignite → Reset**.

---

## What works (capability map)

| Capability | Status |
|------------|--------|
| Default HTML site (`boris` → `dist/`) | **Done** (Feature 2) |
| ApexMarkdown Unified (tables, footnotes, …) | **Done** (Feature 1; pin v1.1.11) |
| Trunk/Satellite graph + closed frontmatter | **Done** |
| `<Aside>` kinds + document order | **Done** |
| JSON IR (`--out` / `--no-rag`) | **Done** |
| RAG export (`--rag` / `--rag-dir`) | **Done** |
| Incremental / watch / `--jobs` / multi-target | **Done** (P2–P3 on HTML path) |
| CI Linux + macOS | **Done** |
| Graph-aware HTML nav (`{{nav}}` / breadcrumb / title) | **Done** (Feature 6 MVP) |
| In-page heading `{{toc}}` | **Later** (Feature 6 follow-on) |
| Full YAML / MDX / embedded HTTP server | **Not now** |

### Commands

```bash
zig build
zig build test
./scripts/release-gate.sh

./zig-out/bin/boris --help
./zig-out/bin/boris --quiet                         # HTML → dist/
./zig-out/bin/boris --out .boris --quiet            # IR only
./zig-out/bin/boris --rag --quiet                   # RAG → rag/
./zig-out/bin/boris --jobs 4 --quiet
./zig-out/bin/boris --watch
./zig-out/bin/boris --target prod=dist/prod --target stage=dist/stage

# CMake is compile-time only (static ApexMarkdown libs)
zig build test-apex-hostile
zig build test-apex-sanitize   # optional
```

Host tools: **Zig 0.16** + **CMake** at build time. Pin:
[`vendor/apex-markdown/VENDOR.md`](../vendor/apex-markdown/VENDOR.md).

Exit codes: `0` ok · `1` content · `2` usage · `3` I/O.

### Pipeline (short)

```text
Load  → discover Markdown under content/
Roll  → frontmatter + Aside tokenize + graph roles
Ignite → validate → HTML | IR | RAG
Reset → free per-page scratch (HTML) / arena (IR/RAG)
```

---

## Next (active roadmap)

| Priority | Item | Why |
|----------|------|-----|
| **Now** | Feature 6 follow-on — in-page heading `{{toc}}` | Per-page outline from body headings |
| **Next** | Polish sample content as product evolves | Keep `content/` green with nav + Apex reality |
| **Later** | v0.2.0 product cut | Package Feature 1+2+6 MVP + P2/P3 under a real version bump (`schemaVersion` stays `0.1.0` unless IR shape changes) |
| **Hygiene** | Historical campaign notes | Removed from tree (`archive/`); do not reintroduce as default agent context |

### Shipped (do not re-open as greenfield)

| # | Feature | Note |
|---|---------|------|
| 1 | ApexMarkdown Unified | Real engine under host ABI |
| 2 | HTML default CLI | Bare `boris` → `dist/`; IR via `--out` |
| 3 | `--jobs N` | Parallel independent page renders |
| 4 | `--watch` | Debounced rebuild loop |
| 5 | `--target` multi-output | Isolated roots + caches |
| 6 | Graph-aware HTML nav (MVP) | `{{nav}}` forest + breadcrumb + title; HTML graph gate |

P2 (fingerprints, incremental, layout edges) and P3 scale-out are **complete**
on the HTML path. Detail lives in contracts and `CHANGELOG.md`, not here.

---

## Not now

| Idea | Why |
|------|-----|
| Subprocess markdown (`pandoc`, etc.) | Forbidden — in-process Apex only |
| Next/Astro/React as the site compiler | Boris *is* the compiler |
| Unrestricted MDX | Asides only; no JS evaluation |
| Full YAML frontmatter | Closed key grammar is intentional |
| Embedded HTTP dev server | Use any static file server on `dist/` |
| “Instant” or RSS-flat performance claims | Measure first; design is lean, not magic |

---

## Risks worth remembering

| ID | Risk | When it matters |
|----|------|-----------------|
| **D2** | cmake may see system libyaml | Before feeding YAML metadata into Apex options |
| **D3** | Apex cmake step re-runs every `zig build` | When build-time pain is measured |
| **D4** | Apex thread-safety not formally proven | Before making `--jobs` the recommended default (smoke evidence exists) |
| Publish | Cross-volume atomic rename not claimed | Multi-disk CI / deploy oddities |
| Dialect | Author key is **`parent` only** | Never reintroduce `parentEntry` on product parse |
| Migration | Bare `boris` is HTML, not IR | Old scripts need `--out` |

---

## Documentation map (live tree only)

| Doc | Role |
|-----|------|
| [`README.md`](../README.md) | Human front door — outcomes + CLI |
| [`AGENTS.md`](../AGENTS.md) | Hard constraints for contributors/agents |
| **This file** | Where we are + next |
| [`CHANGELOG.md`](../CHANGELOG.md) | What landed |
| [`docs/contracts/`](contracts/) | **Normative** machine contracts + fixtures |
| [`docs/RELEASE-GATE.md`](RELEASE-GATE.md) | Ship checklist / `release-gate.sh` |
| [`docs/rag/system/`](rag/system/) | RAG narrative seeds (not contracts) |
| [`content/AGENT-DIRECTIVE.txt`](../content/AGENT-DIRECTIVE.txt) | Sample-content rebuild brief |

---

## Platform notes (do not overclaim)

- Symlink tests skipped when the host denies create
- IR/RAG/HTML publish uses staging + rename; not every FS is whole-tree atomic
- Dual-run determinism claimed per CI host, not cross-OS bit-identical trees
- Watch uses portable polling fallback; native FS events are platform-qualified
- HTML path assumes **trusted** authors (raw HTML passthrough in Apex adapter)

**North star:** Zig Markdown documentation compiler — load, roll, ignite, reset —
validated metadata and graph-aware docs, not a polyglot web framework.
