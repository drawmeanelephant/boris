# Project status — Boris

**As of:** 2026-07-15 · product **0.2.0** / compiler **boris/0.2.0** · Zig **0.16.0**  
**Phase:** **v0.2.0** HTML-default site compiler (ApexMarkdown Unified, Feature 6 nav+toc, P2/P3).  
IR `schemaVersion` remains **`0.1.0`**.

Living snapshot for agents and humans. Prefer this and [`CHANGELOG.md`](../CHANGELOG.md)
over archaeology. Normative behavior: [`docs/contracts/`](contracts/).

### What 0.2 is

Product **0.2.0** packages the shippable docs compiler: bare `boris` → `dist/`
HTML; real ApexMarkdown; Trunk/Satellite graph; layout nav/breadcrumb/title/toc;
incremental, watch, jobs, multi-target. IR and RAG stay opt-in; IR shape is still
schema **0.1.0**. Tag: `v0.2.0`.

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
| In-page heading `{{toc}}` | **Done** (Feature 6 follow-on) |
| Boris-mediated includes + wiki-links | **Next** (foundation only today) |
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
| **Next** | **Boris-mediated includes + wiki-links** | Resolve includes and wiki-link targets (entity id) in Zig from the frozen dependency graph **before** Apex; detect transclusion cycles at the Boris graph level; included bytes must contribute to the parent page’s cache fingerprint. Apex stays sandboxed: `enable_file_includes = false` always (never Apex FS reads). |
| **Now** | Keep sample content honest as features land | `content/` dogfood refreshed for v0.2.0; re-check after next feature |
| **Later** | IR schema bump only if emit shape changes | Do not bump `schemaVersion` for product-only work |
| **Hygiene** | Historical campaign notes | Removed from tree (`archive/`); do not reintroduce as default agent context |

### Foundation already present (not the full feature)

P2 left plumbing only — do not claim product includes/wiki-links:

| Piece | Where | What it does **not** do |
|-------|--------|-------------------------|
| Apex includes off | `vendor/apex/apex.c`, U17 | Engine never pulls disk files |
| `DependencyKind.include` + reverse index | `src/dependency.zig` | No authoring syntax, no splice |
| Fingerprint can hash include bytes | `src/cache.zig` | Only when deps are registered |
| Crude `includes/` path scan | `src/compile.zig` | Dep edges for dirty-set — **no** body expansion before `apex.render` |

### Shipped (do not re-open as greenfield)

| # | Feature | Note |
|---|---------|------|
| — | **Product v0.2.0** | Version package of Features 1+2+6 + P2/P3; tag `v0.2.0` |
| 1 | ApexMarkdown Unified | Real engine under host ABI |
| 2 | HTML default CLI | Bare `boris` → `dist/`; IR via `--out` |
| 3 | `--jobs N` | Parallel independent page renders |
| 4 | `--watch` | Debounced rebuild loop |
| 5 | `--target` multi-output | Isolated roots + caches |
| 6 | Graph-aware HTML nav (MVP) | `{{nav}}` forest + breadcrumb + title; HTML graph gate |
| 6b | In-page `{{toc}}` | h1–h3 outline from rendered body ids (`src/html_toc.zig`) |

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

## Risks (mitigated / permanent honesty)

| ID | Status | Resolution |
|----|--------|------------|
| **D2** | **Mitigated** | `scripts/build-apex-markdown.sh` configures Apex with system libyaml discovery disabled. Product never feeds YAML metadata into Apex options; frontmatter is Boris-owned. See `vendor/apex-markdown/VENDOR.md`. |
| **D3** | **Mitigated** | Same script stamps `build/.boris-apex-stamp` and skips cmake when archives + policy are current. Force rebuild: `BORIS_FORCE_APEX_BUILD=1`. |
| **D4** | **Mitigated (not formal proof)** | U18 + parallel Unified site compile gates permanent. CLI default stays `--jobs 1`; `--jobs N` smoke-validated for product Apex options (plugins/includes off). See `docs/contracts/parallel-rendering.md`. |
| Publish | **Honest limit + fallback** | Cross-volume **atomic** replace still not claimed. HTML stage / IR publish fall back to copy+delete on `error.CrossDevice`; RAG already had directory copy fallback. Same-parent staging remains the common path. |
| Dialect | **Enforced** | Author key is **`parent` only**. `parentEntry` / `parent_entry` → `EFRONTMATTER` on all product parse paths. Do not reintroduce aliases. |
| Migration | **Documented** | Bare `boris` is HTML under `dist/`. Old IR scripts need `--out` / `--no-rag`. README + help text carry the note. |

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
