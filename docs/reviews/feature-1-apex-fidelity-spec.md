# Feature 1 — Apex fidelity (cmark-gfm under `apex.h`)

**Status:** specification only — **do not implement until an agent is explicitly
assigned this card.**  
**Date:** 2026-07-14  
**Baseline tree:** post-P3 complete; residual docs audit committed; bare CLI
still IR-first; vendor engine is still the minimal stub.

This document is the handoff for a **fresh session**. Prefer it over the long
corpus audit wall and the STATUS card alone.

---

## Goal

Replace the minimal `vendor/apex/apex.c` stub with an in-process CommonMark
(plus GFM tables) engine **without changing** the public C ABI in
`vendor/apex/apex.h` or the Zig wrapper contracts in `src/apex.zig` /
`docs/contracts/apex-abi.md`.

Authors get tables, nested lists, blockquotes, and fenced code blocks in
opt-in HTML output. IR/RAG paths still do not call Apex.

---

## Non-goals (hard)

| Do not | Why |
|--------|-----|
| Subprocess markdown (`pandoc`, `cmark` CLI, etc.) | `AGENTS.md` / `apex-abi.md` |
| Change `apex_render` signature or status codes | Host contract |
| Make HTML the bare-CLI default | Feature 2 (separate session) |
| Full GFM task lists / autolinks / strikethrough unless free with the library | Tables are the required extension; keep surface tight |
| MDX / nested asides / multi-component registry | Still deferred |
| Rewrite Aside tokenizer | Aside segments bypass Apex (`aside.renderHtml`) |
| Touch P3 multi-target / watch / jobs logic except via existing compile path | Already shipped |

---

## Engine choice

| | `cmark` | **`cmark-gfm` (required)** |
|--|---------|---------------------------|
| CommonMark | yes | yes |
| Tables → `<table>` | no | **yes** (Feature 1 acceptance) |
| Allocator hooks | `cmark_mem` | same shape |
| License | BSD-2 | MIT |

**Decision:** vendor **cmark-gfm** (pinned tag / commit, sources in-tree, no
network at build time). Do not default to plain `cmark` — STATUS acceptance
explicitly requires tables.

---

## Architecture (required shape)

```text
src/apex.zig  →  @cImport(apex.h)  →  apex_render(...)
                                          │
                                          ▼
                              vendor/apex/apex.c   ← thin SHIM only
                                          │
                                          ▼
                              vendor/cmark-gfm/*   ← real parser/renderer
```

1. **Keep** `vendor/apex/apex.h` byte-stable (normative ABI).
2. **Replace body** of `vendor/apex/apex.c` with a shim that:
   - zeros `*out_html` / `*out_len` on entry;
   - validates null `md` / outs / incomplete allocator → `APEX_ERR_ARGS`;
   - builds a `cmark_mem` (or gfm equivalent) that routes:
     - `calloc` / `realloc` / `free` through `ApexAllocator`;
   - parses markdown **by length** (`md`, `md_len`) — never `strlen(md)`;
   - renders HTML into a single contiguous buffer owned by the host allocator;
   - returns `APEX_OK` / `APEX_ERR_OOM` / `APEX_ERR_ARGS`;
   - retains **no** pointers after return (sync only).
3. **Do not** change the hostile double (`apex_hostile.c`) or its build path —
   it tests the Zig wrapper, not the engine.
4. **Optional rollback:** keep the old stub as `vendor/apex/apex_stub.c` and a
   `build.zig` option (e.g. `-Dapex-stub=true`) for one or two cycles. Default
   must be the real engine.

### Allocator / lifetime (highest risk)

Whiteboard path: `ApexAllocator.free` is a **hard no-op**; reclaim is
`ArenaAllocator.reset(.free_all)` per page.

cmark-gfm expects real `realloc` semantics. Emulate:

```text
realloc(ptr, old_implied, new_size):
  new = alloc(new_size)
  if fail → OOM path
  if ptr: memcpy(min(old, new)); free(ptr)  // free is no-op on arena
  return new
```

**Consequence:** intermediate buffers accumulate in the arena until page
`free_all`. That is acceptable (per-page Whiteboard). **Forbidden:** calling
`apex_free` / libc `free` on arena pointers.

Also implement:

- `calloc(n, size)` → alloc + zero (overflow-checked `n * size`);
- OOM → free intermediate engine objects as far as the API allows, clear outs,
  return `APEX_ERR_OOM`.

Libc path (`allocator == NULL`) must still use malloc and remain freeable with
`apex_free` (tests / sanitize smoke may exercise it).

### Version string

`apex_version()` should report something like `apex-cmark-gfm/<pinned>` so
failures are diagnosable. Do not claim “CommonMark” without tests green.

---

## Build integration

| File | Change |
|------|--------|
| `build.zig` `linkApex` | Compile shim + all required cmark-gfm `.c` units; include paths for gfm headers; keep `-std=c11`; libc already linked |
| Hostile path | Still only `apex_hostile.c` (no gfm) |
| Sanitize step | Still smoke against production engine (`apex.c` shim + gfm) |

Pin exact upstream revision in a short `vendor/cmark-gfm/README.md` (URL + tag
+ date + license). Prefer vendored amalgamation or the minimal source set gfm
needs to render HTML with the table extension enabled.

Enable **only** extensions required for acceptance (tables). Document any extra
GFM extension left on by default.

---

## Test plan (gates)

| Gate | Command / check | Must |
|------|-----------------|------|
| A1 | `zig build` | Links cleanly |
| A2 | `zig build test` | All existing tests pass |
| A3 | `zig build test-apex-hostile` | Unchanged wrapper behavior |
| A4 | New unit or HTML fixture: pipe table → contains `<table` | **Acceptance** |
| A5 | Nested list, blockquote, fenced code render sanely | New fixture(s) |
| A6 | Existing `test/fixtures/html/` goldens | Pass **or** intentionally update if stub HTML differed (document why) |
| A7 | `zig build test-apex-sanitize` | Pass or documented skip |
| A8 | `./scripts/release-gate.sh` | Pass before claiming done |

### Fixture guidance

- Prefer adding under `test/fixtures/html/` (or apex unit tests in
  `src/apex.zig`) rather than inventing a second pipeline.
- Aside pages: ensure `<Aside>` still streams correctly (Aside HTML is not
  produced by Apex).
- Keep HTML goldens deterministic (no timestamps, stable attribute order if
  the engine allows).

### Expected golden churn

Current goldens assume **stub** output (minimal tags). After the swap, expect
possible differences in whitespace, wrapping `<p>`, or empty-document handling.
Update goldens only when the new output is correct CommonMark/GFM; do not
weaken tests to preserve stub quirks.

---

## Docs / contracts (same change set)

| Doc | Update when engine lands |
|-----|--------------------------|
| `docs/contracts/apex-abi.md` | “Stub vs production” → name cmark-gfm; keep ABI rules |
| `docs/STATUS.md` | Feature 1 / Card 1 → **Done** when gates green |
| `docs/RELEASE-GATE.md` | Apex note: engine is CommonMark+GFM tables, not stub |
| `docs/rag/system/06-apex-native-engine.md` | Narrative: stub → cmark-gfm |
| `CHANGELOG.md` | Unreleased bullet: Apex engine upgrade |
| This file | Disposition: **Implemented** + commit hash |

Do **not** bump IR `schemaVersion` — Apex is HTML-path only.

---

## Suggested implementation order

1. Vendor pin + `build.zig` compile of gfm sources alone (empty main / smoke).
2. Rewrite `apex.c` as shim; `apex_version` + empty md + simple heading.
3. Wire allocator bridge; force-OOM path still returns `OutOfMemory`.
4. Enable table extension; add table fixture.
5. Broader fixtures; update HTML goldens.
6. Hostile + sanitize + release-gate.
7. Docs/STATUS/CHANGELOG.

Commit early and often (per `AGENTS.md`) — engine drop-ins are bisect-hostile.

---

## Files most likely touched

```text
vendor/apex/apex.c                 # shim
vendor/apex/apex_stub.c            # optional preserved stub
vendor/cmark-gfm/**                # new
build.zig                          # linkApex
src/apex.zig                       # tests only if needed
test/fixtures/html/**              # goldens + new pages
docs/contracts/apex-abi.md
docs/STATUS.md
docs/rag/system/06-apex-native-engine.md
CHANGELOG.md
```

Avoid: `src/cli.zig` default mode (Feature 2), graph/IR, multi-target, watch.

---

## Risks (read before coding)

1. **`realloc` on no-op free** — arena growth accumulates; OK per page; watch
   peak Whiteboard capacity on huge pages.
2. **NUL termination** — host passes length; if gfm APIs require C strings,
   allocate a temporary `md_len+1` copy via host alloc (never assume `md` is
   terminated).
3. **Extensions / unsafe HTML** — raw HTML pass-through may differ from stub;
   document behavior; do not invent a sanitizer in this feature unless
   required for tests.
4. **Determinism** — two HTML builds of the same tree must stay dual-run
   identical on one host.
5. **License** — keep MIT/BSD attribution in vendor tree; do not pull GPL.

---

## Definition of done

- [ ] Gates A1–A8 satisfied (or A7 documented skip).
- [ ] Table acceptance criterion true under `--html` / fixture.
- [ ] `apex.h` unchanged; hostile still green.
- [ ] Contracts + STATUS + CHANGELOG updated in the same change set.
- [ ] No Feature 2 default-CLI flip snuck in.
- [ ] This spec marked **Implemented** with landing commit.

---

## Prompt seed for the implementing agent

```text
Implement Feature 1 per docs/reviews/feature-1-apex-fidelity-spec.md only.
Do not start Feature 2. Keep apex.h ABI. Vendor cmark-gfm in-tree, thin
apex.c shim, arena-safe cmark_mem (realloc emulate, free no-op on Whiteboard).
Gates: zig build test, test-apex-hostile, release-gate, table→<table> fixture.
Update apex-abi.md stub section, STATUS Card 1, CHANGELOG. Commit often.
```
