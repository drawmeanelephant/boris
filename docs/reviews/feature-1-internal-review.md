# Feature 1 — Internal review (campaign Chat 6)

**Date:** 2026-07-15  
**Range reviewed:** `9f6c538..HEAD` (Chats 1–5 land: pin → link → adapter →
fidelity → docs Done)  
**Authority:** [`APEX-Feature1-plan.md`](../../APEX-Feature1-plan.md) §10–§12,
[`docs/contracts/apex-abi.md`](../contracts/apex-abi.md)  
**Verdict:** **Ship-intent accepted** after P1 doc drift cleanup and two small
adapter hardenings in this review session.

---

## Gates re-run (this session)

| Gate | Result |
|------|--------|
| `zig build` | PASS |
| `zig build test` | PASS |
| `zig build test-apex-hostile` | PASS |
| `zig build test-apex-sanitize` | PASS |
| `./scripts/release-gate.sh` | PASS |

---

## Plan §12 + Boris checklist

| Check | Status | Notes |
|-------|--------|-------|
| Engine is **ApexMarkdown**, not cmark-as-product | **Pass** | cmark-gfm is static dep only; product version string is `boris-apex/apex-markdown-1.1.11+unified` |
| Default mode **Unified** | **Pass** | `APEX_MODE_UNIFIED` hardcoded in adapter |
| Host `apex.h` lifetime rules intact | **Pass** | Copy into host allocator; `apex_free_string` on Apex heap; never `apex_free` on Whiteboard |
| Copy + `apex_free_string` | **Pass** | Both custom and libc paths |
| Includes / plugins / highlighters off | **Pass** | Explicitly forced; review also set `allow_external_plugin_detection=false` |
| Hostile isolated | **Pass** | `linkApex(..., true)` links only `apex_hostile.c`; no `ensure_apex` dep on hostile |
| Docs no longer “replace Apex with cmark” / stub-as-product | **Pass** (after fixes) | Residual contract/RELEASE-GATE stub lines closed this session |
| No Feature 2 / mode sprawl / IR schema bump | **Pass** | Bare CLI still IR-first; no `--apex-mode` |
| CI cmake dependency documented | **Pass** | `.github/workflows/ci.yml` installs cmake; README/STATUS/RELEASE-GATE note compile-time dep |
| Offline pin works | **Pass** | Flat snapshot under `vendor/apex-markdown/`; no nested `.git` |
| Parallel `--jobs` safety | **Pass with residual** | Adapter is sync and stack-local; terminal-output globals exist in Apex sources but product uses HTML fragment only. Not a formal multi-thread audit of upstream Apex |
| No secret subprocess highlighters | **Pass** | `code_highlighter = NULL` |

---

## Findings

### Fixed this session (P1 / small P0)

| ID | Severity | Finding | Disposition |
|----|----------|---------|-------------|
| F1 | **P1** | Residual “stub ≠ CommonMark” / “fidelity still next” wording in `docs/contracts/README.md`, `acceptance.md`, `v0.1-overview.md`, `docs/RELEASE-GATE.md` after Feature 1 Done | **Fixed** — docs now claim Unified adapter; RELEASE-GATE notes CMake host tool |
| F2 | **P1** | Default `allow_external_plugin_detection` true from upstream defaults (plugins already off, but CWD probe path exists if plugins re-enabled) | **Fixed** — adapter forces `false` |
| F3 | **P2** | `malloc(md_len + 1)` theoretically wraps when `md_len == SIZE_MAX` | **Fixed** — reject with `APEX_ERR_ARGS` |
| F4 | **nit** | Stale `build.zig` comment (“adapter lands in Chat 3”) | **Fixed** |

### Deferred (P2+ / intentional)

| ID | Severity | Finding | Disposition |
|----|----------|---------|-------------|
| D1 | **P2** | Vendor tree is large (~10MB sources + nested tests/docs/icons) | **Defer** — offline pin correctness preferred over slim; optional follow-up |
| D2 | **P2** | Host may pick up system **libyaml** during cmake if present (non-reproducible feature surface for YAML-rich metadata) | **Defer** — body fragment HTML does not require it; document if CI variance appears |
| D3 | **P2** | `ensure_apex.has_side_effects = true` re-invokes cmake script every build (incremental, but chatty) | **Defer** — correct first; can wire input/output hashing later |
| D4 | **P2** | Upstream Apex not formally proven thread-safe under `--jobs N` | **Defer** — workers use thread-local Whiteboards; no known shared Apex API from adapter; measure under load if issues appear |
| D5 | **P3** | Strategy B (pure zig-cc, no cmake) | **Out of campaign** |
| D6 | **P3** | `--apex-mode` allowlist + cache key | **Out of campaign** (Phase F) |
| D7 | **P3** | Import full Apex 1800-suite | **Rejected** as product gate |

### No P0 product defects found

Lifetime bridge, SSG boundary, hostile isolation, fidelity suite, and release-gate
were green. No lifetime-contract weakenings observed.

---

## Architecture snapshot (as landed)

```text
Zig src/apex.zig  →  host apex_render (vendor/apex/apex.h)
                         │
                         ▼
              vendor/apex/apex.c  (adapter)
                         │  apex_markdown_to_html + Unified opts
                         ▼
              libapex.a + cmark-gfm  (cmake static; vendor/apex-markdown)
                         │
                         ▼
              copy → Whiteboard / malloc → apex_free_string
```

---

## Recommendation

- **Product Feature 1:** remains **Done**.
- **Campaign Chat 7:** ready for external audit fielding when reports arrive.
- **Next product priority:** Feature 2 (HTML default CLI), not further Apex
  mode sprawl.

---

## Sign-off

| Role | Result |
|------|--------|
| Internal reviewer (this chat) | Accept with listed deferrals |
| Gates | All green (see table) |
| Fixes committed with this review | F1–F4 |
