# Project status — Boris milestone 10 (v0.1 harden)

**As of:** 2026-07-13 (product **0.0.1** / compiler **boris/0.1.1** IR + RAG + Aside + Apex + experimental HTML)  
**Zig target:** 0.16.0 (`build.zig.zon` / CI pin **0.16.0**)

This file is the living **“where we are”** note. Prefer it (and
[`CHANGELOG.md`](../CHANGELOG.md)) over archaeology in git history when
starting a session.

---

## One-line product (current phase)

**Boris v0.1 ships a single-threaded content compiler** with validated JSON IR,
optional deterministic RAG (including `:::kind` Aside export), constrained
`<Aside>` tokenization on the shared compile path, and an **opt-in HTML** site
mode (`--html` / `--html-dir`, Apex + Whiteboard + layout splice). Default CLI
remains IR; HTML is not the default product surface but is wired for deliberate
use.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| **Implemented & tested** | Covered by `zig build test` / release gate on CI |
| **Platform-qualified** | Behavior depends on host OS/FS; not overclaimed |
| **Vendor contract** | Relies on Apex C ABI assumptions (not fully Zig-provable) |
| **Intentionally deferred** | Explicit non-goal for v0.1 |

---

## What works today

| Capability | Status | Notes |
|------------|--------|--------|
| `zig build` → `boris` executable | **Implemented & tested** | Apex C linked in-process |
| Typed CLI (`--input`, `--out`, `--rag`, `--html`, …) | **Implemented & tested** | Exit 0/1/2/3 |
| Deterministic scanner | **Implemented & tested** | Sort by entity id; symlink reject |
| Canonical identity + safe output paths | **Implemented & tested** | No `..` escape |
| Bounded frontmatter parser | **Implemented & tested** | Not YAML |
| Aside component tokenizer | **Implemented & tested** | `src/aside.zig`; `ECOMPONENT` |
| Graph validate + freeze (shared IR/RAG) | **Implemented & tested** | One entry point |
| Deterministic JSON IR | **Implemented & tested** | `.boris/` staging publish |
| Optional RAG + `:::kind` Aside export | **Implemented & tested** | Non-round-trippable export form |
| Apex C ABI + Zig wrapper | **Implemented & tested** | Hostile + opt-in sanitizer |
| Experimental HTML + Aside stream | **Implemented & tested** | Opt-in via `--html` / `--html-dir` |
| CI matrix Linux + macOS | **Implemented & tested** | GitHub Actions |
| HTML as default CLI (replacing IR) | **Intentionally deferred** | IR remains default; HTML is opt-in |
| Full YAML / MDX / concurrency / watch | **Intentionally deferred** | See non-goals |

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
Layout load → PageDb promote → per page:
  Whiteboard → parse/tokenize → Apex + Aside HTML → writePage → free_all
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

## Vendor contract / assumptions (Apex)

- Synchronous `apex_render`; no retained pointers after return
- Custom allocator path; never `apex_free` on whiteboard HTML
- Stub engine is a **minimal** markdown subset — not CommonMark
- Hostile double tests mechanical wrapper rules; full C non-retention against
  arbitrary engines remains a contract (see `docs/contracts/apex-abi.md`)

## Intentionally deferred (v0.1 non-goals)

- Default CLI HTML `dist/` product mode
- Markdown-native `:::` **authoring** (export representation only)
- Nested asides, multi-component registry, MDX
- Incremental rebuild / reverse dependency index
- Concurrency / worker pools / watch mode / mmap
- Process RSS flatness claims
- Full YAML frontmatter

---

## Priority list (post-m10 reevaluation)

**Phase context:** v0.1 content-compiler surface is **in force** (IR + optional
RAG + Aside + Apex + experimental HTML). Next work should **not** reopen
polyglot frameworks or concurrency-before-correctness. Prefer sequential
product depth, then graph-native dependency tracking (AGENTS long-term), then
parallelism.

### P0 — finish / keep clean (do first; low blast radius)

| Priority | Item | Why now |
|----------|------|---------|
| P0.1 | Contract navigation & stale planning notes | Contributors must not treat redirects or m2 stubs as truth; ownership is in `docs/contracts/README.md` |
| P0.2 | Fix remaining doc drift (e.g. “CLI still stubs pipeline”, dual-dialect confusion) | STATUS/contracts/README must match m10 reality |
| P0.3 | Point code comments at canonical contracts (e.g. `graph.zig` → `ir-schema.md`) | Avoid citing non-normative redirects |
| P0.4 | Dual frontmatter path clarity | Product path is `parser.zig` + **`parent` only** (rejects `parentEntry` / `parent_entry` as `EFRONTMATTER`). Residual: RAG export field name `parent_entry`; non-product `frontmatter.zig` (fuzz) + historical `harness.zig` — must not reintroduce a second author dialect |

### P1 — next product surface (sequential SSG path)

| Priority | Item | Why this order |
|----------|------|----------------|
| **P1.1** | **Promote experimental HTML to opt-in CLI** (e.g. explicit flag; still not default over IR) | Path already tested (Whiteboard, Aside stream, Atomic publish); natural m11 without new languages |
| P1.2 | Graph-aware navigation / TOC from frozen Trunk–Satellite graph | Uses existing IR; no reverse index required yet |
| P1.3 | Apex markdown fidelity (stub → real docs needs) | HTML quality bottleneck; keep C ABI, no child-process renderers |
| P1.4 | Layout / asset dependency edges (typed, validated) | First step toward long-term dependency graph; still sequential |

### P2 — graph-native build foundations (before incremental / parallel)

| Priority | Item | Gate |
|----------|------|------|
| P2.1 | Forward + reverse dependency indexes (pages, layouts, includes, assets) | Design + implement sequentially; freeze after validate |
| P2.2 | Includes / transclusion as first-class edges | Only with deterministic discovery + cycle rules |
| P2.3 | Content-addressed cache keys + affected-set calculation | After indexes exist and are tested |
| P2.4 | Incremental rebuild | **After** P2.1–P2.3; do not ship partial “maybe stale” caches |

### P3 — scale-out (only after sequential correctness + benchmarks)

| Priority | Item | Gate |
|----------|------|------|
| P3.1 | Bounded worker pool for independent render jobs | Graph frozen; workers must not mutate shared graph/outputs |
| P3.2 | Watch mode | Incremental path proven first |
| P3.3 | Multi-target isolated output dirs / cache namespaces | Explicit cross-target rules |

### Explicitly deprioritized (do not pull forward without a design ask)

| Item | Rationale |
|------|-----------|
| Nested asides / multi-component registry / MDX | Expand registry carefully; no executable MDX |
| `:::` authoring | Export-only representation is enough for v0.1/RAG |
| Full YAML frontmatter | Closed grammar is intentional |
| Process RSS flatness claims | Measure before claiming; Whiteboard capacity only today |
| Cross-volume atomic publish guarantees | Platform-qualified; document, don’t overclaim |

### Open risks (track; not automatic next tickets)

1. Apex stub ≠ CommonMark — fidelity gap for real authoring.
2. Publication atomicity across volumes/OSes not fully proven.
3. Residual dual-helper surface: product IR/RAG/HTML input uses `parser.zig` with
   author key **`parent` only** (`parentEntry` / `parent_entry` rejected).
   `frontmatter.zig` remains for fuzz; historical `harness.zig` is not on the
   default test graph. RAG export still names the parent id column
   `parent_entry` (export-only; not author frontmatter). Narrative seeds may
   still mention older alias wording — contracts win.
4. Root `fixtures_test.zig` is inventory-only; compiler goldens live under contract fixtures + hardening tests (wording must stay honest).

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
| `docs/AUDIT-v0.1.md` | Self-audit report |
| `docs/rag/system/` | Narrative seeds (RAG system segment) |
| `CHANGELOG.md` | What changed |
| This file | Living status + priority list |

---

## Identity metaphor (narrative → code)

| Teaching beat | Current mapping |
|---------------|-----------------|
| **Load** | `scanner.scan` |
| **Roll** | frontmatter + Aside tokenize + PageDb promote + graph classify |
| **Ignite** | validate + freeze + emit IR or RAG; experimental HTML write |
| **Reset** | IR/RAG: arena deinit; HTML: Whiteboard `free_all` per page |

Namesake = folk Zouave improviser known as Boris — independent homage, **not**
affiliated with any commercial tobacco / rolling-paper brand. Do **not** invent
branded component names (no “Broside”).
