# Project status — Boris (post-P2 / post-P3)

**As of:** 2026-07-15 (product **0.0.1** / compiler **boris/0.1.1** IR + RAG + Aside + **real ApexMarkdown Unified** + opt-in HTML; **P2 + P3 complete**; **Feature 1 Done**)  
**Zig target:** 0.16.0 (`build.zig.zon` / CI pin **0.16.0**)

This file is the living **“where we are”** note. Prefer it (and
[`CHANGELOG.md`](../CHANGELOG.md)) over archaeology in git history when
starting a session.

---

## One-line product (current phase)

**Boris v0.1 ships a single-threaded content compiler** with validated JSON IR,
optional deterministic RAG (including `:::kind` Aside export), constrained
`<Aside>` tokenization on the shared compile path, and an **opt-in HTML** site
mode (`--html` / `--html-dir` / `--target`, Apex + Whiteboard + layout splice).
Graph-native foundations (P2) and scale-out primitives (P3.1 jobs, P3.2 watch,
P3.3 multi-target isolation) are **implemented** on the HTML path. Default CLI
remains IR; HTML is not yet the default product surface.

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
| Apex C ABI + Zig wrapper | **Implemented & tested** | Hostile + opt-in sanitizer; **real ApexMarkdown Unified** via host adapter |
| Opt-in HTML + Aside stream | **Implemented & tested** | Opt-in via `--html` / `--html-dir` |
| CI matrix Linux + macOS | **Implemented & tested** | GitHub Actions |
| Content-addressed cache fingerprints (P2.3) | **Implemented & tested** | SHA256 fingerprints on layout, page, and transitively resolved includes |
| Explicit Incremental HTML build mode (P2.4) | **Implemented & tested** | `--incremental` skips unchanged renders, cleans stale assets safely and atomically |
| Bounded Parallel HTML page rendering (P3.1) | **Implemented & tested** | `--jobs N` enables opt-in parallel rendering of independent HTML pages |
| Opt-in Local Development Watch Mode (P3.2) | **Implemented & tested** | `--watch` enables live, debounced, coalesced, serialized HTML rebuilds |
| Multi-target isolated outputs (P3.3) | **Implemented & tested** | `--target`, `--html-layout`, `--target-layout`; path-boundary isolation; stage commit; selective watch fan-out; review `docs/reviews/p3.3-multi-target-review.md` |
| HTML as default CLI (replacing IR) | **Now** (roadmap) | IR remains default until Feature 2 lands |
| Real ApexMarkdown Unified fidelity | **Implemented & tested** | Feature 1 Done: pin @ v1.1.11, cmake static link, Unified host adapter, U1–U17; CMake compile-time host dep |
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
zig build run -- --input test/fixtures/html/content --target prod=dist/prod --target stage=dist/stage \
  --html-layout layouts/main.html --target-layout stage=layouts/main.html
zig build run -- --input docs/contracts/fixtures/valid/content --out .boris
zig build source-rag
zig build package                  # optional review tar → packages/
./scripts/release-gate.sh
```

**Feature 1 host tools:** **CMake** is required as a **compile-time** dependency
to build static ApexMarkdown (`scripts/build-apex-markdown.sh` / `zig build
build-apex`). Not a runtime dep; `zig build` stays the user entrypoint. Pin:
[`vendor/apex-markdown/VENDOR.md`](../vendor/apex-markdown/VENDOR.md).

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

- Real **ApexMarkdown Unified** via host adapter (`vendor/apex/apex.c` →
  `apex_markdown_to_html`); pin `vendor/apex-markdown` @ v1.1.11
- Synchronous `apex_render`; copy-in + `apex_free_string`; never `apex_free` on
  Whiteboard HTML
- Hostile double tests mechanical wrapper rules; full C non-retention against
  arbitrary engines remains a contract (see `docs/contracts/apex-abi.md`)
- **CMake** is a compile-time host dependency for static lib build
- **Trusted-author HTML:** adapter sets `unsafe=true` (raw HTML passthrough).
  Content is assumed trusted. Do not feed untrusted contributor content through
  the HTML path without a separate sanitization layer.

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
| **P3.3** multi-target isolated outputs | **Complete** — CLI, validation, cache namespaces, stage commit, selective watch fan-out |

P3 scale-out is closed. Concurrent product tracks:

1. **Close immediate usability gaps** — CLI defaults still IR-first (Feature 2).
2. **Product depth** — TOC / graph-aware HTML nav (Feature 6); Apex fidelity is Done (Feature 1).

---

## Priority list (post-P2 / post-P3 reevaluation)

**Phase context:** v0.1 content-compiler surface is **in force**. Graph-native
foundations (P2) and scale-out (P3.1–P3.3) have landed on the HTML path. Next
work should **not** reopen polyglot frameworks, subprocess markdown, or
unrestricted MDX. Prefer authoring fidelity and product ergonomics.

### P0 — finish / keep clean (low blast radius)

| Priority | Item | Why now |
|----------|------|---------|
| P0.1 | Contract navigation & stale planning notes | Contributors must not treat redirects or m2 stubs as truth; ownership is in `docs/contracts/README.md` |
| P0.2 | Fix remaining doc drift | **Done** (post-P3 reconciliation pass: README, RELEASE-GATE, contracts, narrative seeds) |
| P0.3 | Point code comments at canonical contracts | Avoid citing non-normative redirects |
| P0.4 | Dual frontmatter path clarity | Product path is `parser.zig` + **`parent` only** (rejects `parentEntry` / `parent_entry` as `EFRONTMATTER`). Residual: RAG export field name `parent_entry`; non-product `frontmatter.zig` (fuzz) + historical `harness.zig` — must not reintroduce a second author dialect |

### P1 — sequential SSG usability (historical; mostly complete)

| Priority | Item | Status |
|----------|------|--------|
| P1.1 | Promote experimental HTML to **opt-in** CLI (`--html` / `--html-dir`) | **Implemented & tested** |
| P1.2 | Graph-aware navigation from frozen Trunk–Satellite graph | **IR done** (`graph.json` → `nav`). HTML/TOC render still deferred |
| P1.3 | Apex markdown fidelity (stub → real ApexMarkdown Unified) | **Done** — Feature 1 |
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
| P3.3 | Multi-target isolated output dirs / cache namespaces | **Implemented & tested** | Contract: `multi-target-isolated-output.md`; review: `docs/reviews/p3.3-multi-target-review.md` |

---

## Post-P3 prioritized feature roadmap

Priorities below are **product/authoring** work relative to the landed P2/P3
foundation. Features already shipped are marked complete so they are not
re-opened as greenfield tickets.

### Feature 1 — Real ApexMarkdown engine (Unified mode)

| Field | Detail |
|-------|--------|
| **Priority** | **Done** (implementation Chats 1–5; internal/external review Chats 6–7 optional hardening) |
| **Campaign status** | **Done for product** + Chat 6 internal review + Chat 7 external audit response ([feature-1-internal-review.md](reviews/feature-1-internal-review.md), [feature-1-external-audit-response.md](reviews/feature-1-external-audit-response.md)). |
| **User-visible payoff** | Authors get full **Apex Unified** Markdown (tables, footnotes, def lists, math, callouts, IAL, …) — real [ApexMarkdown/apex](https://github.com/ApexMarkdown/apex) under frozen host `apex.h` |
| **Modules** | `vendor/apex/*` (host ABI + adapter), `vendor/apex-markdown/*`, `scripts/build-apex-markdown.sh`, `build.zig`, `src/apex.zig` / `aside.zig` tests |
| **Acceptance** | Met: Unified constructs (U1–U17); `test-apex-hostile`; includes/plugins/highlighters off; Whiteboard copy + `apex_free_string` |
| **Dependencies** | **CMake** compile-time host tool — [`VENDOR.md`](../vendor/apex-markdown/VENDOR.md) |
| **Contract / schema** | `docs/contracts/apex-abi.md` — host ABI unchanged |
| **Authority** | [`APEX-Feature1-plan.md`](../APEX-Feature1-plan.md) |

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
| **Known residual (optional)** | Cross-volume stage rename not claimed; per-target content roots still out of scope |
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
| 1 | **ApexMarkdown Unified** (real engine under host `apex.h` ABI) | **Done** | Chats 1–5; plan + `apex-abi.md` |
| 2 | **HTML as default CLI mode** (promote opt-in SSG to default) | **Now** | Layout edges on freeze (landed); Feature 1 Done |
| 3 | **Bounded worker pool** (parallel rendering) | **Done** | Dirty-set / incremental path (landed) |
| 4 | **Watch mode** (FS events → dirty-set run) | **Done** | Worker pool / incremental (landed) |
| 5 | **Multi-target isolated outputs** (config / `--target`) | **Done** | Watch + incremental (landed); contract + post-land hardening |
| 6 | **In-page navigation (TOC)** (`{{toc}}` splice) | **Later** | None hard |

---

## First implementation cards (active)

### Card 1 — Real ApexMarkdown Unified (`src/apex-fidelity`) — **Done**

* **Plan:** [`APEX-Feature1-plan.md`](../APEX-Feature1-plan.md) §10 DoD checked (Chats 1–5).
* **Landed:** pin v1.1.11 · cmake static link · Unified adapter · U1–U17 · docs.
* **Chat 6 (done):** Internal review + residual doc/adapter hardenings — [feature-1-internal-review.md](reviews/feature-1-internal-review.md).
* **Chat 7 (done):** External audit response — [feature-1-external-audit-response.md](reviews/feature-1-external-audit-response.md).
* **Out of scope (still):** Feature 2; `--apex-mode`; Strategy B pure zig-cc.

### Card 2 — HTML default CLI mode (`src/html-default-cli`)

* **Scope:** Toggle the default compilation mode from IR output to HTML site output.
* **Tasks:**
  * Modify `cli.zig` `parseOptions` so omitting mode flags defaults to `Mode.html`.
  * Ensure `--out <DIR>` continues to select `Mode.ir` for contract/fixture compatibility.
  * Adjust `main.zig` to invoke `compile.compileHtmlSite` on default runs.
  * Update `scripts/release-gate.sh` (and help text) for the new default.
* **Acceptance:** Invoking `boris` with no arguments produces a navigable site under `dist/`.

### Card 3 — Multi-target isolated outputs (P3.3) — **Done**

Landed: `--target` / `--html-layout` / `--target-layout`, path-boundary validation,
per-target cache namespaces, sibling stage commit, selective watch fan-out.
See `docs/contracts/multi-target-isolated-output.md` and
`docs/reviews/p3.3-multi-target-review.md`.

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
| **v0.2.0** — Apex fidelity & default HTML surface | Features 1 + 2 land (real ApexMarkdown Unified + HTML default CLI) | Update `compiler` / product id toward `boris/0.2.0`. **`schemaVersion` stays `"0.1.0"`** unless JSON IR shape changes. May also package already-landed P2/P3 Unreleased work (including multi-target) if not cut earlier. |
| **v0.3.0** — P2/P3 packaging polish (if not already cut with 0.2) | Docs/release polish for `--incremental`, `--jobs`, `--watch`, `--target` as stable product flags | *If these ship inside 0.2.0, this cut can collapse or become a polish-only release.* P3.3 itself is **already implemented** — this row is packaging, not a greenfield trigger. |

**IR rule (unchanged):** Breaking IR changes must bump `schemaVersion` and update
`docs/contracts/` in the same change set. CLI-default flips and flag additions do
not by themselves change IR schema.

---

## Open risks (track; not automatic next tickets)

1. Feature 1 product land + Chat 6 internal review + Chat 7 external audit
   response Done. Residual Apex hygiene tracked below (D2/D3/D4).
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

### Feature 1 deferred risks (explicit triggers)

| ID | Risk | Trigger to resolve | Notes |
|----|------|--------------------|-------|
| **D2** | Host may pick up system **libyaml** during cmake → non-reproducible `libapex.a` feature surface | **Before** any YAML metadata is passed into `apex_render` / Apex markdown options | Body-fragment HTML path does not require YAML today |
| **D3** | `ensure_apex.has_side_effects = true` re-invokes cmake script every `zig build` | When CI/dev build time or step-graph caching becomes a measured pain | Correct first; wire input/output hashing / file-existence step later |
| **D4** | Upstream Apex not formally proven **thread-safe** under `--jobs N` | **Before** `--jobs N` becomes the default or recommended product path; re-check on Apex pin upgrades | **Mitigated by evidence, not closed as proof:** U18 concurrent smoke + compile parallel Unified job test + contract note in `parallel-rendering.md`. Workers use thread-local Whiteboards; plugins/includes off. Full global-registry audit still deferred. |

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
| `docs/contracts/multi-target-isolated-output.md` | P3.3 multi-target (normative; implemented) |
| `docs/AUDIT-v0.1.md` | Self-audit report (m10 historical) |
| `docs/reviews/post-p3-reconciliation.md` | Post-P3 docs reconciliation audit |
| `APEX-Feature1-plan.md` | Feature 1 authority (real ApexMarkdown Unified) — product Done |
| `docs/reviews/feature-1-apex-fidelity-spec.md` | Feature 1 handoff pointer |
| `docs/reviews/feature-1-internal-review.md` | Feature 1 Chat 6 internal review record |
| `docs/reviews/feature-1-external-audit-response.md` | Feature 1 Chat 7 external audit dispositions |
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
