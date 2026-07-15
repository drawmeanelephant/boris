# Project status — Boris

**As of:** 2026-07-15 · product **0.3.1** / compiler **boris/0.3.1** · Zig **0.16.0**<br>
**Phase:** **v0.3.1** — Feature 8 graph-native dependencies complete.<br>
IR `schemaVersion` is **`0.2.0`**.

**Feature 8 status:** F8.0 contracts and F8.1–F8.3 are complete. IR 0.2
publishes typed `parent` / `include` / `reference` edges and deterministic
`reverseIndex`; incremental HTML consumes the same resolver and reverse-walk
semantics. Fingerprints remain the content-addressed change detector.

Living snapshot for agents and humans. Prefer this and [`CHANGELOG.md`](../CHANGELOG.md)
over archaeology. Normative behavior: [`docs/contracts/`](contracts/).

### What 0.3.1 is

Product **0.3.1** projects direct parent/include/reference dependencies into
IR 0.2 with typed page/source endpoints, canonical edge ordering, and a target-
keyed reverse index, then reuses that dependency story to expand incremental
HTML dirty sets. Include/wiki failures gate graph publication and HTML planning.
Bare `boris` remains HTML → `dist/`; IR/RAG remain opt-in.

**0.2.0** packaged ApexMarkdown Unified, HTML default CLI, graph-aware nav +
TOC, and P2/P3 incremental / watch / jobs / multi-target. Tag: `v0.2.0`.

---

## What you get (outcomes first)

| You want… | You get… | How |
|-----------|----------|-----|
| A docs site from Markdown | HTML under `dist/` | `boris` (default) |
| Tables, footnotes, callouts, real Markdown | ApexMarkdown Unified, not a toy stub | Feature 1 — in-process render |
| Callouts that stay in the page | Constrained `<Aside>` in document order | Shared compile path |
| Shared fragments + internal page links | `{{include}}` + `[[entity-id]]` (HTML) | Feature 7 — pre-Apex |
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
| Boris-mediated includes + wiki-links | **Done** (Feature 7; HTML path; Apex FS includes off) |
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
| **Later** | Wiki `[[id#heading]]` section targets | Needs heading-id contract |
| **Later** | P4 build-system productization | Measurement-driven cache/watch improvements after F8 |
| **Hygiene** | Sample content honesty as features land | Root `content/` is current for F7; re-check after next feature |
| **Hygiene** | No parallel content sandboxes by default | Failed draft removed; root `content/` is SoT |

### Shipped (do not re-open as greenfield)

| # | Feature | Note |
|---|---------|------|
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
