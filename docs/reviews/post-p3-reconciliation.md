# Post-P3 reconciliation audit

**Date:** 2026-07-14  
**Scope:** Documentation-only alignment with landed P2/P3. No runtime or IR
`schemaVersion` changes.

## Mechanical baseline (recorded)

| Command | Result |
|---------|--------|
| `zig build` | Pass |
| `zig build test` | Pass |
| `zig build test-apex-hostile` | Pass |
| `zig build test-apex-sanitize` | Pass (`apex_sanitize_smoke: ok` on this host) |
| `./scripts/release-gate.sh` | **RELEASE GATE PASSED** |
| Runtime / IR schema | Unchanged (`schemaVersion` `0.1.0`, `boris/0.1.1`) |

## Corrected drift items

| # | Location | Original (stale) claim | Replacement | Why correct |
|---|----------|------------------------|-------------|-------------|
| 1 | `README.md` implemented table | “Concurrency / watch / full YAML — **Out of scope** for v0.1”; no HTML flags | Lists opt-in HTML, `--jobs`, `--watch`, multi-target as **Implemented**; YAML/MDX out of scope; CommonMark + HTML default as roadmap | Matches CLI in `src/cli.zig` and STATUS |
| 2 | `README.md` CLI options / modes | IR/RAG only | Full option table + mode conflicts including HTML | Aligns with `printUsage` |
| 3 | `docs/RELEASE-GATE.md` | Milestone 9 “Deferred further: … watch mode, concurrency”; no P2/P3 checks | Checklist marks P2/P3 complete; deferred limited to HTML default, CommonMark, mmap, subprocess MD | Post-P3 reality; CI already runs hostile Apex |
| 4 | `docs/contracts/README.md` status | “closing P3”; non-goal “MDX / concurrency” | “post-P3”; concurrency limited to unbounded shared-mutable outside `--jobs` | Contracts map matches STATUS |
| 5 | `docs/contracts/v0.1-overview.md` | “Concurrency / watch … **Out of scope**” | P2/P3 **Implemented** on HTML path; YAML/MDX out of scope | Non-normative overview was contradicting contracts |
| 6 | `docs/contracts/acceptance.md` | “not required: incremental … concurrency, watch” (read as missing) | Split: not required for IR acceptance bar vs landed HTML capabilities | Prevents “deferred” misread |
| 7 | `docs/contracts/html-output.md` | “Single-threaded only — no concurrency”; library-only entry | Opt-in CLI; sequential coordinator; `--jobs` via parallel-rendering contract | HTML is product opt-in CLI |
| 8 | `docs/contracts/ir-schema.md` | “No concurrency in v0.1” / IR non-support table | Sequential **IR emit**; workers are HTML-only | IR stages remain sequential |
| 9 | `docs/contracts/watch-mode.md` | Single `--html-dir` root; no `--target` | Multi-target ignore roots, layouts, `--target` requires HTML | Aligns with P3.3 |
| 10 | `docs/contracts/identity-and-paths.md` | “No watch mode / concurrent discovery” | No concurrent discovery; `--watch` rebuilds sequentially | Discovery still sequential |
| 11 | `docs/rag/system/*` | Experimental HTML; no worker pools; incomplete CLI flags | Opt-in HTML; documented `--jobs`/`--watch`/`--target`; stub Apex honesty | Narrative presented as current |
| 12 | `docs/AUDIT-v0.1.md` | Deferred list as living | Historical banner + residual gaps only | Archival snapshot after m10 |
| 13 | `docs/STATUS.md` title | “closing P3” | “post-P3”; P0.2 drift marked done | Title matched body status |
| 14 | `AGENTS.md` long-term note | “Do not add concurrency until…” | Bounded `--jobs` only; no uncoordinated shared-mutable concurrency | P3.1 already landed |
| 15 | `src/compile.zig` module header | “Experimental… No concurrency” | Opt-in HTML + sequential coordinator + optional workers | Comment matched implementation |
| 16 | `src/fixtures_test.zig` header | “pipeline not implemented on default CLI” | Inventory-only; goldens elsewhere | IR pipeline long implemented |
| 17 | `CHANGELOG.md` Unreleased | (missing reconciliation bullet) | Docs — post-P3 reconciliation | Records this pass |

Historical CHANGELOG sections that describe *past* milestones (e.g. early
“pipeline not implemented”) were left intact.

## Residual cleanup (2026-07-14, docs-only follow-up)

A later corpus audit restated several items already fixed above, plus real
residuals that this follow-up closed without touching Feature 1 (cmark):

| Item | Disposition |
|------|-------------|
| RELEASE-GATE title / P2–P3 checklist | Already fixed in this recon pass |
| acceptance / AUDIT deferred wording | Already fixed |
| RAG seeds for `--jobs` / `--watch` / `--target` | Already fixed |
| Underscore diagnostic codes in contract fixture READMEs + seed `03` | **Fixed** in residual pass (`EDUPLICATEID`, `EPARENT*`, `EFRONTMATTER`, …) |
| STATUS v0.4.0 ghost “P3.3 complete” trigger | **Fixed** — packaging only under 0.2/0.3 |

## Remaining known gaps

1. **CommonMark / Apex fidelity** — vendor `apex.c` is still a minimal stub
   (Feature 1 proposal only; not started).
2. **HTML as default CLI mode** — bare `boris` remains IR-first (`--out` IR).
3. **In-page TOC** — explicitly later (benefits from Apex fidelity first).
4. **Platform-qualified publication** — not whole-tree atomic on every volume;
   cross-OS byte identity not overclaimed; watch backends portable-polling-first.
5. **Dual frontmatter helper containment** — product path `parser.zig` + `parent`
   only; residual `frontmatter.zig` (fuzz) / historical `harness.zig` / RAG export
   field name `parent_entry` must not reintroduce a second author dialect.
   Historical `harness.zig` still uses pre-canonical enum-style names and is not
   on the default test graph.
