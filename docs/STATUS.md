# Project status — Boris

**As of:** 2026-07-16 · next product cut **v0.5.0 release candidate** /
compiler **boris/0.5.0** · Zig **0.16.0**<br>
**Phase:** v0.5.0 release certification; tag pending.<br>
IR `schemaVersion` is **`0.2.0`**.

**Version boundary:** `v0.4.0` remains the latest tagged release. The prepared
`v0.5.0` cut does not change base IR `0.2.0`; semantic relations retain their
documented conditional IR `0.3.0` artifacts. The `v0.5.0` tag is pending final
release-owner review.

**Feature 8 status:** F8.0 contracts and F8.1–F8.3 are complete. IR 0.2
publishes typed `parent` / `include` / `reference` edges and deterministic
`reverseIndex`; incremental HTML consumes the same resolver and reverse-walk
semantics. Fingerprints remain the content-addressed change detector.

**Knowledge-system track:** Documentation Intelligence, bounded semantic
relations, and deterministic AI Context Bundles are merged on `main` via PRs
#43 and #44. Relations use conditional IR 0.3 artifacts; Context Bundles use
their own `boris-context` schema 1 and preserve source-relative provenance.
These capabilities shipped in v0.4.0.

Living snapshot for agents and humans. Prefer this and [`CHANGELOG.md`](../CHANGELOG.md)
over archaeology. Normative behavior: [`docs/contracts/`](contracts/).

### What 0.4.0 is

Product **v0.4.0** extends the v0.3.1 graph-native compiler with knowledge-system
exports, Documentation Intelligence, heading-aware links, hardened theme assets
and per-page layout selection, bounded Textile input, migration laboratories,
and tracked agent-lore content dogfood. Its initial Astro, WordPress, and
Instagram migration labs remain developer aids, not runtime dependencies. Bare
`boris` remains HTML → `dist/`;
IR/RAG remain opt-in. Relation-free output stays IR 0.2, while semantic relations
use their conditional IR 0.3 artifacts.

### What v0.5.0 adds

The prepared v0.5.0 cut adds the closed native `<Details>` component and
source-located invalid-component diagnostics. It also packages post-v0.4
source-RAG publication hardening, bounded Obsidian/Notion/Starlight/Filed
migration-lab evidence, and the judge-verified docs path. Migration labs remain
developer tools: they do not become Boris runtime dependencies or universal
converters.

**0.2.0** packaged ApexMarkdown Unified, HTML default CLI, graph-aware nav +
TOC, and P2/P3 incremental / watch / jobs / multi-target. Tag: `v0.2.0`.

---

## What you get (outcomes first)

| You want… | You get… | How |
|-----------|----------|-----|
| A docs site from Markdown | HTML under `dist/` | `boris` (default) |
| Tables, footnotes, callouts, real Markdown | ApexMarkdown Unified, not a toy stub | Feature 1 — in-process render |
| Callouts that stay in the page | Constrained `<Aside>` in document order | Shared compile path |
| Shared fragments + internal page links | `{{include}}` + `[[entity-id]]` / `[[entity-id#heading]]` (HTML) | Feature 7 + F9 heading fragments |
| “Did my graph still make sense?” | Fail-loud Trunk/Satellite validation | Exit **1** + diagnostics |
| Machine-readable graph/IR | JSON under `.boris/` | `boris --out .boris` |
| LLM knowledge pack of this project | Deterministic `rag/` corpus | `boris --rag` |
| Grounded context for an LLM | Deterministic bundle with hashes + graph | `boris --context` |
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
| Closed `<Details>` disclosure component | **Prepared for v0.5.0** (native HTML + deterministic RAG projection) |
| JSON IR (`--out` / `--no-rag`) | **Done** |
| RAG export (`--rag` / `--rag-dir`) | **Done** |
| Incremental / watch / `--jobs` / multi-target | **Done** (P2–P3 on HTML path) |
| CI Linux + macOS | **Done** |
| Graph-aware HTML nav (`{{nav}}` / breadcrumb / title) | **Done** (Feature 6 MVP) |
| In-page heading `{{toc}}` | **Done** (Feature 6 follow-on) |
| Boris-mediated includes + wiki-links | **Done** (Feature 7; HTML path; Apex FS includes off) |
| Wiki `[[id#heading]]` section targets | **Done** (F9; Apex heading ids; see `heading-ids.md`) |
| Page layout selection (`--layout-rule`) | **Done** (exact/glob/role; one theme/target) |
| Layout-selection hostile/path gate | **Done** (`zig build test-layout-hostile`; lexical path rejection) |
| Apex Unified compatibility matrix | **Shipped in v0.4.0** (fixtures + matrix; compatibility evidence, not a new renderer) |
| Astro, WordPress, and Instagram migration labs | **Shipped in v0.4.0** (bounded conversion/reconnaissance labs + adversarial preservation fixtures; not runtime dependencies) |
| Obsidian vault + Notion Markdown/CSV migration labs | **Prepared for v0.5.0** (phase-1 developer aids under `tools/migration-lab/`; not runtime dependencies) |
| Starlight proof slice (locale-dir + root-locale) | **Prepared for v0.5.0** (`--mode=starlight` under `tools/migration-lab/`; content-root discovery for `docs/en/` or root-locale `docs/`; bounded convert + manifests; not a runtime dependency) |
| Bounded Textile input | **Shipped in v0.4.0** (`--textile`; explicit whole-tree compatibility adapter) |
| Optional static theme showcase | **Shipped in v0.4.0** (`examples/static-theme-showcase/`; hand-authored CSS, not product chrome) |
| Agent-lore content dogfood | **Shipped in v0.4.0** (tracked sample content only; private 250MB source data remains excluded/ignored) |
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
zig build test-layout-hostile
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
| **Next** | Real-site dogfood | Exercise a substantial site/archive and record concrete migration, authoring, and publish gaps. |
| **Next** | Archive-friendly layouts | Validate layout rules and child/index presentation against real archive navigation before broadening theme features. |
| **Later** | Further docs packaging | README + migration guide now lead with outcomes, quickstart, and honest AI/migration boundaries; remaining gaps are sample-content version drift and deeper cookbook discoverability. |
| **Later** | Source-RAG ergonomics and publication safety | Keep the standalone source pack distinct from product RAG; prioritize evidence-backed output-size and partial-publish improvements. |
| **Deferred** | Measurement-driven build work | Benchmark or change cache/watch/parallel behavior only after a reproducible real-site need. |

### Current release and shipped history (do not re-open as greenfield)

| # | Feature | Note |
|---|---------|------|
| — | **Product v0.4.0** | Tagged/released: knowledge-system exports, Documentation Intelligence, layout/theme work, Textile, migration labs, static theme showcase, and agent-lore dogfood; base IR remains 0.2 |
| — | **Product v0.3.1** | F8.3 reverse-index incremental dirty-set; IR remains 0.2 |
| — | **Product v0.3.0** | Feature 8.1–8.2 / IR 0.2 graph-native dependencies |
| — | **Product v0.2.1** | Feature 7 + dogfood + F7 polish; tag `v0.2.1` |
| — | **Product v0.2.0** | Features 1+2+6 + P2/P3; tag `v0.2.0` |
| 8.0 | IR 0.2 contracts | Typed endpoint, edge order, reverse-index, and fixture contract frozen |
| 8.1–8.2 | Graph-native IR | Resolve/freeze direct dependencies; emit IR 0.2; full golden + release gate |
| 8.3 | Reverse-index dirty-set | HTML fingerprints seed dirty pages; shared reverse semantics expand dependents |
| 1 | ApexMarkdown Unified | Real engine under host ABI |
| 2 | HTML default CLI | Bare `boris` → `dist/`; IR via `--out` |
| 3 | `--jobs N` | Parallel independent page renders |
| 4 | `--watch` | Debounced rebuild loop |
| 5 | `--target` multi-output | Isolated roots + caches |
| 6 | Graph-aware HTML nav (MVP) | `{{nav}}` forest + breadcrumb + title; HTML graph gate |
| 6b | In-page `{{toc}}` | h1–h3 outline from rendered body ids (`src/html_toc.zig`) |
| 7 | Includes + wiki-links | `{{include}}` + `[[entity-id]]` pre-Apex; cycles/missing fail loud; `includes/` not pages |
| 9 | Heading-target wiki links | `[[entity-id#heading-id]]` matches Apex-rendered ids; fail loud on missing |
| 9.1 | Closed layout plan + theme assets | `metadata` / `footer` / `asset-url`; target-owned asset copy; see `templating-and-themes.md` |
| 9.2 | Theme/template hardening | Layout UTF-8 at split; orphan theme-asset scrub; fixture/failure coverage; see `templating-and-themes.md` |
| 9.3 | Page layout selection | `--layout-rule TARGET SELECTOR LAYOUT_PATH`; exact/glob/role precedence, one managed theme per target (PR #50) |
| 9.3a | Layout-selection hostile coverage | Determinism, fallback, isolation, and invalid/mixed path coverage; focused `test-layout-hostile` gate (PR #51) |
| — | Apex Unified compatibility evidence | Matrix + fixtures document the supported Boris-facing surface (PR #52) |
| — | Migration laboratories | Astro archaeology, WordPress conversion, Instagram Takeout, and adversarial preservation fixtures are developer aids, not Boris product pipelines (PRs #53–#54, #77–#78) |
| — | Agent-lore content dogfood | Tracked sample content exercises a documentation section without committing the private 250MB source dataset (PR #79) |
| — | Bounded Textile compatibility | Explicit fail-closed `.textile` tree mode through the normal Boris pipeline (PR #55) |
| — | Post-layout correctness fixes | Theme asset/page-output preservation, owned fragment keys, precise wiki diagnostics, managed-theme watch coverage, non-incremental stale sweep preservation, footer UTF-8 gate, and incremental heading-index reuse (PRs #65–#72) |

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
| Release state | **v0.4.0 released** | Knowledge-system, layout/theme, Textile, migration-lab, and showcase work shipped in the tagged v0.4.0 product release. |

---

## Documentation map (live tree only)

| Doc | Role |
|-----|------|
| [`README.md`](../README.md) | Human front door — outcomes, quickstart, AI/migration honesty |
| [`docs/MIGRATION.md`](MIGRATION.md) | Author migration path + fixture commands |
| [`AGENTS.md`](../AGENTS.md) | Hard constraints for contributors/agents |
| **This file** | Where we are + next |
| [`CHANGELOG.md`](../CHANGELOG.md) | What landed |
| [`docs/contracts/`](contracts/) | **Normative** machine contracts + fixtures |
| [`docs/RELEASE-GATE.md`](RELEASE-GATE.md) | Ship checklist / `release-gate.sh` |
| [`docs/ROADMAP-post-f8.md`](ROADMAP-post-f8.md) | Post-F8 planning history + post-F9.2 future (not living phase banner) |
| [`docs/rag/system/`](rag/system/) | RAG narrative seeds (not contracts) |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone migration laboratories (not product runtime) |
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
