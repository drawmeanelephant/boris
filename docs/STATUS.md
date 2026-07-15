# Project status — Boris (post-P2 / closing P3)

**As of:** 2026-07-15 (product **0.0.1** / compiler **boris/0.1.1** IR + RAG + Aside + Apex + opt-in HTML; P2 complete; P3 complete)  
**Zig target:** 0.16.0 (`build.zig.zon` / CI pin **0.16.0**)

This file is the living **“where we are”** note. Prefer it (and
[`CHANGELOG.md`](../CHANGELOG.md)) over archaeology in git history when
starting a session.

---

## One-line product (current phase)

**Boris v0.1 ships a single-threaded content compiler** with validated JSON IR,
optional deterministic RAG (including `:::kind` Aside export), constrained
`<Aside>` tokenization on the shared compile path, and an **opt-in HTML** site
mode (`--html` / `--html-dir`, Apex + Whiteboard + layout splice). Graph-native
foundations (P2) and scale-out primitives (P3.1 parallel jobs, P3.2 watch) are
**implemented** on the HTML path. Default CLI remains IR; HTML is not yet the
default product surface.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| **Implemented & tested** | Covered by `zig build test` / release gate on CI |
| **Platform-qualified** | Behavior depends on host OS/FS; not overclaimed |
| **Vendor contract** | Relies on Apex C ABI assumptions (not fully Zig-provable) |
| **Intentionally deferred** | Explicit non-goal for current phase |
| **In progress** | Design and/or partial implementation underway |
| **Now / Next / Later** | Roadmap priority for upcoming work |

---

## What works today

| Capability | Status | Notes |
|------------|--------|--------|
| `zig build` → `boris` executable | **Implemented & tested** | Apex C linked in-process |
| Typed CLI (`--input`, `--out`, `--rag`, `--html`, `--jobs`, `--watch`, …) | **Implemented & tested** | Exit 0/1/2/3 |
| Deterministic scanner | **Implemented & tested** | Sort by entity id; symlink reject |
| Canonical identity + safe output paths | **Implemented & tested** | No `..` escape |
| Bounded frontmatter parser | **Implemented & tested** | Not YAML |
| Aside component tokenizer | **Implemented & tested** | `src/aside.zig`; `ECOMPONENT` |
| Graph validate + freeze (shared IR/RAG) | **Implemented & tested** | One entry point; layout edges on freeze |
| Deterministic JSON IR | **Implemented & tested** | `.boris/` staging publish |
| Graph-aware nav in IR (`graph.json` → `nav`) | **Implemented & tested** | From frozen graph only; not HTML/RAG |
| Optional RAG + `:::kind` Aside export | **Implemented & tested** | Non-round-trippable export form |
| Apex C ABI + Zig wrapper | **Implemented & tested** | Hostile + opt-in sanitizer; **stub ≠ CommonMark** |
| Opt-in HTML + Aside stream | **Implemented & tested** | Opt-in via `--html` / `--html-dir` |
| CI matrix Linux + macOS | **Implemented & tested** | GitHub Actions |
| Content-addressed cache fingerprints (P2.3) | **Implemented & tested** | SHA256 fingerprints on layout, page, and transitively resolved includes |
| Explicit Incremental HTML build mode (P2.4) | **Implemented & tested** | `--incremental` skips unchanged renders, cleans stale assets safely and atomically |
| Bounded Parallel HTML page rendering (P3.1) | **Implemented & tested** | `--jobs N` enables opt-in parallel rendering of independent HTML pages |
| Opt-in Local Development Watch Mode (P3.2) | **Implemented & tested** | `--watch` enables live, debounced, coalesced, serialized HTML rebuilds |
| Multi-target isolated outputs (P3.3) | **Implemented & tested** | `--target NAME=DIR`; path-boundary validation; per-target `.boris-cache`; review hardening in `docs/reviews/p3.3-multi-target-review.md` |
| HTML as default CLI (replacing IR) | **Now** (roadmap) | IR remains default until Feature 2 lands |
| Full CommonMark Apex fidelity | **Now** (roadmap) | Stub engine is minimal markdown subset |
| Full YAML / MDX / mmap | **Intentionally deferred** | See non-goals / Not Now |

### How to run

```bash
zig build
zig build test
zig build test-apex-hostile
zig build test-apex-sanitize   # opt-in; skips cleanly if unavailable
zig build run -- --help
zig build run -- --input fixtures/content/valid --out /tmp/boris-ir
zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag
zig build run -- --input test/fixtures/html/content --html-dir /tmp/boris-dist
zig build run -- --input test/fixtures/html/content --html --jobs 4
zig build run -- --input test/fixtures/html/content --html --watch
zig build run -- --input test/fixtures/html/content --target prod=dist/prod --target stage=dist/stage
zig build run -- --input docs/contracts/fixtures/valid/content --out .boris
zig build source-rag
zig build package                  # optional review tar → packages/
./scripts/release-gate.sh
```

### Shared pipeline surface

```text
Load  → scanner.scan
Roll  → parser.parse + aside.tokenizeBody + PageDb.promote
Ignite → graph.validate (+ freeze when clean)
         + IR JSON emit  OR  RAG corpus export
Reset → retain arena lifetime ends with Result.deinit
```

**Opt-in HTML (`--html` / `--html-dir`):**

```text
Layout load → PageDb promote → graph freeze (layout edges) → cache / dirty-set
  → per dirty page (sequential or --jobs N workers):
       Whiteboard → parse/tokenize → Apex + Aside HTML → writePage → free_all
  → optional --watch loop (debounced rebuild of affected set)
```

Exit codes: `0` success, `1` content, `2` usage, `3` I/O.

---

## Platform-qualified behavior

- Symlink unit tests skipped on Windows / when symlink create is denied
- IR/RAG publication: staging + rename/copy; **not** whole-tree atomic replace;
  cross-volume atomicity **not** claimed
- HTML Atomic replace: same-directory rename; multi-OS CI covers Linux + macOS
  unit tests, not every filesystem
- Cross-OS bit-identical RAG/IR trees **not** claimed beyond dual-run tests on
  each CI host
- Watch mode: portable polling fallback; host-native FS events are platform-qualified

## Vendor contract / assumptions (Apex)

- Synchronous `apex_render`; no retained pointers after return
- Custom allocator path; never `apex_free` on whiteboard HTML
- Stub engine is a **minimal** markdown subset — not CommonMark
- Hostile double tests mechanical wrapper rules; full C non-retention against
  arbitrary engines remains a contract (see `docs/contracts/apex-abi.md`)

## Intentionally deferred (current non-goals)

- Markdown-native `:::` **authoring** (export representation only)
- Nested asides, multi-component registry, MDX
- mmap for large file I/O, process RSS flatness claims
- Full YAML frontmatter
- Embedded HTTP dev server (compiler only; use external static servers)

---

## Audit snapshot (P2 / P3 foundations)

An audit of `src/cache.zig`, `src/dependency.zig`, `src/compile.zig`,
`src/cli.zig`, `src/watch.zig`, and related modules confirms:

| Area | Status |
|------|--------|
| **Milestone P2** (graph-native build foundations) | **Complete** — content-addressed SHA-256 fingerprints, transitive reverse-dependency / affected-set calculation, opt-in `--incremental` HTML path |
| **Layout edges on freeze** | **Landed** — layout dependencies integrated into the frozen graph |
| **P3.1** bounded worker pool (`--jobs N`) | **Complete** (opt-in HTML path) |
| **P3.2** watch mode (`--watch`) | **Complete** (opt-in HTML path) |
| **P3.3** multi-target isolated outputs | **Last P3 item** — design contract present; implementation in flight |

That leaves two concurrent tracks after / while finishing P3.3:

1. **Close immediate usability gaps** in the sequential SSG pipeline (minimal Markdown rendering stub; CLI defaults still IR-first).
2. **Ship remaining scale-out surface** (P3.3 multi-target), then product depth (TOC, Apex fidelity packaging).

---

## Priority list (post-P2 reevaluation)

**Phase context:** v0.1 content-compiler surface is **in force**. Graph-native
foundations (P2) and parallel/watch scale-out (P3.1–P3.2) have landed on the
HTML path. Next work should **not** reopen polyglot frameworks, subprocess
markdown, or unrestricted MDX. Prefer authoring fidelity and product ergonomics
while finishing multi-target isolation.

### P0 — finish / keep clean (low blast radius)

| Priority | Item | Why now |
|----------|------|---------|
| P0.1 | Contract navigation & stale planning notes | Contributors must not treat redirects or m2 stubs as truth; ownership is in `docs/contracts/README.md` |
| P0.2 | Fix remaining doc drift | STATUS/contracts/README must match landed P2/P3 reality |
| P0.3 | Point code comments at canonical contracts | Avoid citing non-normative redirects |
| P0.4 | Dual frontmatter path clarity | Product path is `parser.zig` + **`parent` only** (rejects `parentEntry` / `parent_entry` as `EFRONTMATTER`). Residual: RAG export field name `parent_entry`; non-product `frontmatter.zig` (fuzz) + historical `harness.zig` — must not reintroduce a second author dialect |

### P1 — sequential SSG usability (historical; mostly complete)

| Priority | Item | Status |
|----------|------|--------|
| P1.1 | Promote experimental HTML to **opt-in** CLI (`--html` / `--html-dir`) | **Implemented & tested** |
| P1.2 | Graph-aware navigation from frozen Trunk–Satellite graph | **IR done** (`graph.json` → `nav`). HTML/TOC render still deferred |
| P1.3 | Apex markdown fidelity (stub → real docs needs) | **Now** — see Feature 1 |
| P1.4 | Layout / asset dependency edges (typed, validated) | **Implemented** — layout edges on freeze |

### P2 — graph-native build foundations — COMPLETED

| Priority | Item | Status | Notes |
|----------|------|--------|-------|
| P2.1 | Forward + reverse dependency indexes (pages, layouts, includes, assets) | **Implemented & tested** | Indexes created sequentially; frozen after validation |
| P2.2 | Includes / transclusion as first-class edges | **Implemented & tested** | Includes scanned transitively with cycle check / protection |
| P2.3 | Content-addressed cache keys + affected-set calculation | **Implemented & tested** | SHA256 fingerprints computed deterministically (`src/cache.zig`) |
| P2.4 | Incremental rebuild | **Implemented & tested** | Opt-in `--incremental` rebuild skipping identical page renders |

### P3 — scale-out

| Priority | Item | Status | Notes |
|----------|------|--------|-------|
| P3.1 | Bounded worker pool for independent render jobs | **Implemented & tested** | `--jobs N`; thread-local Whiteboard; deterministic vs sequential |
| P3.2 | Watch mode | **Implemented & tested** | `--watch`; debounced, coalesced, serialized rebuilds (`src/watch.zig`) |
| P3.3 | Multi-target isolated output dirs / cache namespaces | **In progress** | Contract: `multi-target-isolated-output.md`; last P3 gate |

---

## Post-P3 prioritized feature roadmap

Priorities below are **product/authoring** work relative to the landed P2/P3.1–P3.2
foundation. Features already shipped are marked complete so they are not
re-opened as greenfield tickets.

### Feature 1 — Upgrading Apex C Engine to Full CommonMark Compliance

| Field | Detail |
|-------|--------|
| **Priority** | **Now** (authoring fidelity bottleneck) |
| **User-visible payoff** | Authors can write standard documentation structures (tables, nested lists, blockquotes, fenced code blocks) and see them rendered correctly without switching to an external renderer |
| **Smallest shippable vertical slice** | Swap the minimal `vendor/apex/apex.c` stub with a lightweight, compliant C CommonMark library (e.g. `cmark` or `cmark-gfm`) that compiles in-process and adheres strictly to the existing `apex.h` ABI |
| **Modules** | `vendor/apex/*`, `build.zig` (link new C translation units) |
| **Acceptance** | (1) Input containing a standard Markdown table compiles to `<table>` elements under `dist/`; (2) `zig build test-apex-hostile` continues to pass |
| **Dependencies** | None |
| **Contract / schema** | None — conform to `docs/contracts/apex-abi.md` |

### Feature 2 — Promoting HTML to the Default CLI Surface (`dist/` product mode)

| Field | Detail |
|-------|--------|
| **Priority** | **Now** (site-building ergonomics) |
| **User-visible payoff** | Running `boris` with no mode flags generates a navigable HTML site under `dist/` instead of JSON IR under `.boris/` |
| **Smallest shippable vertical slice** | Default mode `.html` instead of `.ir` in `cli.zig`; preserve `--out` as opt-in JSON IR |
| **Modules** | `src/cli.zig`, `src/main.zig`, `scripts/release-gate.sh` |
| **Acceptance** | (1) `boris` with no flags → `dist/index.html` (and nested pages), exit 0; (2) `boris --out .boris` skips HTML and writes only JSON IR |
| **Dependencies** | None (layout edges already landed) |
| **Contract / schema** | **CLI surface change** (new default; old options preserved) |

### Feature 3 — Bounded Worker Pool for Page Rendering (P3.1)

| Field | Detail |
|-------|--------|
| **Priority** | **Done** (landed under Unreleased) |
| **User-visible payoff** | Large documentation sites build faster via parallel independent page renders |
| **Status** | Implemented: `--jobs N` / `-j N`, thread-local arenas, deterministic ordering vs sequential |
| **Contract** | `docs/contracts/parallel-rendering.md` |

### Feature 4 — Watch Mode (P3.2)

| Field | Detail |
|-------|--------|
| **Priority** | **Done** (landed under Unreleased) |
| **User-visible payoff** | Output rebuilds near-instantly on file saves while authoring |
| **Status** | Implemented: `--watch`, debounce/coalesce, FakeWatcher + PollingWatcher, signal-safe shutdown |
| **Contract** | `docs/contracts/watch-mode.md` |

### Feature 5 — Multi-Target Isolated Output Configurations (P3.3)

| Field | Detail |
|-------|--------|
| **Priority** | **Done** (landed; post-land hardening 2026-07-14) |
| **User-visible payoff** | Maintainers can build distinct site variants (e.g. internal draft vs public production) from the same content root with isolated configs and separate cache manifests |
| **Landed slice** | CLI `--target NAME=DIR`; `--html`/`--html-dir` → target `default`; path-boundary workspace/nest checks; content+layout non-overlap; sequential sorted compile; per-target `.boris-cache` + multitarget fingerprints; watch multi-root ignore |
| **Modules** | `src/cli.zig`, `src/main.zig`, `src/target.zig`, `src/compile.zig`, `src/cache.zig`, `src/watch.zig` |
| **Acceptance** | (1) Two targets compile both outputs; (2) cache namespaces isolated under each output root; (3) validation failures exit 2 |
| **Known residual (optional)** | Watch ignore-root precompute; shared fingerprint/dep prep across targets; orphan atomic-temp scrub; intermediate symlink walk; per-target layouts |
| **Dependencies** | Stable incremental + watch path (landed) |
| **Contract / schema** | `docs/contracts/multi-target-isolated-output.md` · review: `docs/reviews/p3.3-multi-target-review.md` |

### Feature 6 — In-Page Navigation (TOC)

| Field | Detail |
|-------|--------|
| **Priority** | **Later** |
| **User-visible payoff** | Templates can splice a generated table of contents (e.g. `{{toc}}`) for long pages |
| **Dependencies** | None hard; benefits from Apex fidelity (Feature 1) |
| **Contract / schema** | Likely HTML/layout contract extension when designed |

---

## Prioritized roadmap (6 items)

| # | Feature | Priority | Phase gate / dependency |
|---|---------|----------|-------------------------|
| 1 | **Apex fidelity upgrade** (CommonMark C lib under `apex.h` ABI) | **Now** | Existing `apex-abi.md` contract |
| 2 | **HTML as default CLI mode** (promote opt-in SSG to default) | **Now** | Layout edges on freeze (landed) |
| 3 | **Bounded worker pool** (parallel rendering) | **Done** | Dirty-set / incremental path (landed) |
| 4 | **Watch mode** (FS events → dirty-set run) | **Done** | Worker pool / incremental (landed) |
| 5 | **Multi-target isolated outputs** (config / `--target`) | **Done** | Watch + incremental (landed); contract + post-land hardening |
| 6 | **In-page navigation (TOC)** (`{{toc}}` splice) | **Later** | None hard |

---

## First implementation cards (active)

### Card 1 — Replace Apex C stub with cmark (`src/apex-fidelity`)

* **Scope:** Swap the minimal C parser inside `vendor/apex/` with a stable CommonMark library.
* **Tasks:**
  * Drop in `cmark` (or `cmark-gfm` if tables are required) under `vendor/apex/`.
  * Map the library’s rendering entry point to `apex_render` and `APEX_*` status codes in `apex.h`.
  * Respect custom `ApexAllocator` callbacks; do not retain pointers or invoke libc `free` on custom memory.
  * Update `build.zig` to link the new C source file(s).
* **Acceptance:** `zig build test` and `zig build test-apex-hostile` pass. Standard Markdown tables and lists render to correct HTML.

### Card 2 — HTML default CLI mode (`src/html-default-cli`)

* **Scope:** Toggle the default compilation mode from IR output to HTML site output.
* **Tasks:**
  * Modify `cli.zig` `parseOptions` so omitting mode flags defaults to `Mode.html`.
  * Ensure `--out <DIR>` continues to select `Mode.ir` for contract/fixture compatibility.
  * Adjust `main.zig` to invoke `compile.compileHtmlSite` on default runs.
  * Update `scripts/release-gate.sh` (and help text) for the new default.
* **Acceptance:** Invoking `boris` with no arguments produces a navigable site under `dist/`.

### Card 3 — Multi-target isolated outputs (`src/multi-target` / P3.3)

* **Scope:** Finish the last P3 item: isolated targets with separate output dirs and cache namespaces.
* **Tasks:**
  * Implement CLI / config grammar per `docs/contracts/multi-target-isolated-output.md`.
  * Validate unique names and non-overlapping output roots before any render.
  * Namespace cache fingerprints per target; run targets sequentially with isolated staging.
  * Keep `--watch` / `--jobs` / `--incremental` global semantics as specified.
* **Acceptance:** Two-target build succeeds; draft invalidation does not touch production target cache.

---

## Not Now list

| Feature | Reason |
|---------|--------|
| **Subprocess Markdown rendering** | **Rejected** — `apex-abi.md` and `AGENTS.md` require in-process C ABI calls |
| **JS framework / bundler integration** | **Rejected** — no Astro, Next.js, or npm runtimes in the core SSG |
| **Unrestricted MDX expressions** | **Rejected** — asides via constrained `<Aside>` parser only; no JS evaluation |
| **Full YAML 1.2 frontmatter parser** | **Rejected** — line-oriented closed key-value grammar is intentional |
| **Embedded HTTP dev server** | **Rejected** — Boris is a compiler, not a runtime; use `python -m http.server`, `serve`, etc. |
| Nested asides / multi-component registry (unbounded) | Expand registry carefully; no executable MDX |
| Process RSS flatness claims | Measure before claiming; Whiteboard capacity only today |
| Cross-volume atomic publish guarantees | Platform-qualified; document, don’t overclaim |

---

## Release boundary & versioning plan

Layout edges, IR navigation, incremental builds, `--jobs`, and `--watch` currently
live under **Unreleased** on the **0.1.x / boris/0.1.1** baseline. Suggested
product cuts once acceptance is green:

| Version | Trigger | Notes |
|---------|---------|--------|
| **v0.2.0** — Apex fidelity & default HTML surface | Features 1 + 2 land (CommonMark integration + HTML default CLI) | Update `compiler` / product id toward `boris/0.2.0`. **`schemaVersion` stays `"0.1.0"`** unless JSON IR shape changes. May also package already-landed P2/P3.1–P3.2 Unreleased work if not cut earlier. |
| **v0.3.0** — Parallel scale & watch (if not already cut with 0.2) | Stable Feature 3 + 4 packaging / docs polish | CLI documents `--jobs N` and `--watch` as supported product flags. *If these ship inside 0.2.0, this cut can collapse or become a polish release.* |
| **v0.4.0** — Multi-target configuration | Feature 5 / P3.3 complete | Introduces normative configuration / target grammar as product surface (`multi-target-isolated-output.md`). |

**IR rule (unchanged):** Breaking IR changes must bump `schemaVersion` and update
`docs/contracts/` in the same change set. CLI-default flips and flag additions do
not by themselves change IR schema.

---

## Open risks (track; not automatic next tickets)

1. Apex stub ≠ CommonMark — fidelity gap for real authoring (**Feature 1**).
2. Publication atomicity across volumes/OSes not fully proven.
3. Residual dual-helper surface: product IR/RAG/HTML input uses `parser.zig` with
   author key **`parent` only** (`parentEntry` / `parent_entry` rejected).
   `frontmatter.zig` remains for fuzz; historical `harness.zig` is not on the
   default test graph. RAG export still names the parent id column
   `parent_entry` (export-only; not author frontmatter). Narrative seeds may
   still mention older alias wording — contracts win.
4. Root `fixtures_test.zig` is inventory-only; compiler goldens live under contract fixtures + hardening tests (wording must stay honest).
5. Default CLI flip (Feature 2) will break scripts that assume bare `boris` ⇒ IR;
   preserve `--out` and document migration.

**North star:** Zig Markdown documentation compiler — load, roll, ignite, reset —
validated metadata and graph-aware docs, not a polyglot web framework.

---

## Documentation map

| Doc | Role |
|-----|------|
| `README.md` | Human front door |
| `AGENTS.md` | Hard constraints |
| `docs/contracts/` | Normative contracts (canonical list in `README.md`) |
| `docs/contracts/acceptance.md` | v0.1 acceptance checklist (non-normative) |
| `docs/contracts/v0.1-overview.md` | Orientation snapshot (non-normative) |
| `docs/contracts/components.md` | Aside tokenizer (m10) |
| `docs/contracts/parallel-rendering.md` | P3.1 parallel HTML workers |
| `docs/contracts/watch-mode.md` | P3.2 watch mode |
| `docs/contracts/multi-target-isolated-output.md` | P3.3 multi-target (design / in progress) |
| `docs/AUDIT-v0.1.md` | Self-audit report |
| `docs/rag/system/` | Narrative seeds (RAG system segment) |
| `CHANGELOG.md` | What changed |
| This file | Living status + priority / roadmap list |

---

## Identity metaphor (narrative → code)

| Teaching beat | Current mapping |
|---------------|-----------------|
| **Load** | `scanner.scan` |
| **Roll** | frontmatter + Aside tokenize + PageDb promote + graph classify |
| **Ignite** | validate + freeze + emit IR or RAG; HTML render/publish (sequential or `--jobs`) |
| **Reset** | IR/RAG: arena deinit; HTML: Whiteboard `free_all` per page (per worker when parallel) |

Namesake = folk Zouave improviser known as Boris — independent homage, **not**
affiliated with any commercial tobacco / rolling-paper brand. Do **not** invent
branded component names (no “Broside”).
