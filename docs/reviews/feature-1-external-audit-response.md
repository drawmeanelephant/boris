# Feature 1 — External audit response (campaign Chat 7)

**Date:** 2026-07-15  
**Audit under response:** Perplexity AI independent review (“Feature 1 External
Audit”), corpus tip area `c24d4db`  
**Repo HEAD at response start:**
`c24d4db4ab794e1f4a5aa3ab14425d73fa69a5a3`  
**Verdict accepted:** **Accept with conditions** — conditions addressed below  
**Internal review:** [`feature-1-internal-review.md`](feature-1-internal-review.md)

---

## Disposition summary

| ID | Severity | Disposition | Action |
|----|----------|-------------|--------|
| F-001 | Low | **Fixed** | Full SHA recorded in internal review sign-off |
| F-002 | Medium | **Already fixed + hardened** | `build/` was already gitignored and **not tracked**; source-rag now skips `build` / `CMakeFiles` so corpora do not re-include host CMake trees |
| F-003 | Medium | **Fixed** | Trusted-author / `unsafe=true` notice in README + STATUS |
| F-004 | Medium | **Fixed** | Exact golden HTML for table (U1), footnote (U7), math (U9), callout (U10) |
| F-005 | Medium | **Deferred (tracked)** | D3 in STATUS with resolve trigger |
| F-006 | Low | **Deferred (comment)** | Documented empty-md sentinel lifetime next to `empty_md_sentinel` |
| F-007 | Low | **Fixed (docs)** | Sanitizer PASS vs documented SKIP distinguished in internal review |
| F-008 | Low | **Fixed (docs)** | D2 / D4 (and D3) in STATUS with concrete triggers |
| F-009 | Info | **Wontfix** | `n + 0` checked-add placeholder left as intentional future-hook |
| F-010 | Info | **Fixed** | Feature-1 supersession note on `docs/AUDIT-v0.1.md` |

---

## F-001 — Commit identity

Recorded full tip SHA in
[`feature-1-internal-review.md`](feature-1-internal-review.md):

`c24d4db4ab794e1f4a5aa3ab14425d73fa69a5a3`

---

## F-002 — `vendor/apex-markdown/build/` “committed”

**Finding was overstated against git history.** At the audit tip:

- Repo-root `.gitignore` already lists `/vendor/apex-markdown/build/` (and
  nested `**/build/`).
- `git ls-files vendor/apex-markdown/build` → **0 paths** (not versioned).
- [`vendor/apex-markdown/VENDOR.md`](../../vendor/apex-markdown/VENDOR.md)
  already documents `build/` as CMake output, regenerated at compile time.

The auditor saw CMake artifacts in a **source-RAG working-tree dump**, not in
git. That is a pack-tool hygiene issue: `tools/source-rag` walked into local
`build/` and packed `.txt` CMake files.

**Response:**

1. No `git rm` required — nothing to untrack.
2. `tools/source-rag/main.zig` now skips directory basenames `build` and
   `CMakeFiles` so future LLM / external-audit packs stay free of host CMake
   trees.

---

## F-003 — `unsafe=true` trust notice

Author-facing one-sentence notice added under HTML rendering in:

- `README.md`
- `docs/STATUS.md` (Vendor contract / assumptions)

Normative adapter table in `docs/contracts/apex-abi.md` already stated the
assumption; this surfaces it for content authors and integrators.

---

## F-004 — Golden HTML pins

Exact `expectEqualStrings`-style goldens (via `fidelityEqualGolden`) for:

| Construct | Test | Pin |
|-----------|------|-----|
| GFM table | U1 | full `<table>…</table>` fragment |
| Footnote | U7 | ref + footnotes section (ids, backref attrs) |
| Math | U9 | inline `\(x\)` + display `\[ y \]` spans |
| Callout NOTE | U10 | `callout-note` title/content structure |

Structural substring checks remain for the rest of U1–U17. Full Apex 1800-suite
import stays rejected (D7).

**Note on IDs:** the external report mapped footnotes/math to U3/U5; product
suite numbering is U7/U9. Pins follow the product test IDs.

---

## F-005 — `ensure_apex` side effects

Deferred as **D3** with STATUS trigger: resolve when CI/dev build time or
step-graph caching is a measured pain. Behavior remains correct (cmake is
incremental).

---

## F-006 — Empty-md sentinel

Implementation left as-is (ABI-correct). Comment expanded at
`empty_md_sentinel` explaining program-lifetime stability and `md_len == 0`
non-read.

---

## F-007 — Sanitizer PASS vs SKIP

Internal review gate table annotated: Chat 6 “PASS” means the step exited
successfully on that host; it is **not** proof ASan linked. Documented skip
still exits 0 when sanitizers are unavailable. True sanitizer green remains
host/CI-qualified.

---

## F-008 — D2 / D4 tracking

Added to `docs/STATUS.md` under **Feature 1 deferred risks** with resolve
triggers:

- **D2 libyaml:** before any YAML metadata is passed into `apex_render`
- **D4 thread-safety:** before `--jobs N` is default or recommended
- **D3 ensure_apex:** tracked alongside (F-005)

---

## F-009 — `zigAlloc` `n + 0`

**Wontfix.** Placeholder documents the “checked growth” rule for future
padding; logic is correct.

---

## F-010 — Stale AUDIT-v0.1 stub language

Top-level NOTE added to `docs/AUDIT-v0.1.md`: Feature 1 resolves the stub
fidelity risk; historical open-risk bullets remain for archive fidelity.

---

## Gates re-run (this response)

| Gate | Result |
|------|--------|
| `zig build test` | PASS (incl. golden fidelity pins) |
| `zig build test-apex-hostile` | PASS |
| `./scripts/release-gate.sh` | PASS |
| `nm` / `strings` product binary | PASS (`apex_markdown_to_html`, `boris-apex/apex-markdown-1.1.11+unified`) |
| Full SHA at response start | `c24d4db4ab794e1f4a5aa3ab14425d73fa69a5a3` |
| Response commit | `67b66c1` (Chat 7) |

---

## Recommendation

Feature 1 remains **Done**. External-audit conditions for ship are addressed
(fix-now) or tracked with triggers (defer). Next product priority stays
**Feature 2** (HTML default CLI), not further Apex mode sprawl.
