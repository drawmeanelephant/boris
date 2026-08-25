# Archived audits

> **Archived 2026-08-21 — issue [#693](https://github.com/drawmeanelephant/boris/issues/693).**

Completed audit reports were moved from `docs/audits/` to `docs/archived/audits/` as a historical record. They are **not standing agent context** — `docs/STATUS.md` no longer references them, and `docs/archived/*` is excluded from the live `zig build test-doc-links` guard. Git history preserves the originals.

## What was archived

| File (new location) | Original | Lines | Reason |
|---|---|---|---|
| `optimization-audit.md` | `docs/audits/optimization-audit.md` | 1,988 | Completed audit — findings addressed, deferred, or captured in the triage backlog. Measurement harness and corpus procedure documented in the audit remain reproducible from git history. |
| `optimization-backlog.md` | `docs/audits/optimization-backlog.md` | 681 | Triage backlog extracted from the optimization audit. 35 `PERF-*` candidates were triaged but not filed as separate GitHub issues; the table is stale and the audit remains the evidence source in git history. No surviving action items were extracted — file once at large stale. |
| `publication-surface.md` | `docs/audits/publication-surface.md` | 455 | Completed surface audit as of 2026-07-29. Implemented surface is now `docs/contracts/publication-profile.md`; audit is historical. |
| `project-health-surface.md` | `docs/audits/project-health-surface.md` | 360 | Completed health check / Doctor design input as of 2026-07-29. Doctor kernel remains in `src/doctor.zig`; audit guidance is historical. |
| `test-throughput-audit.md` | `docs/audits/test-throughput-audit.md` | 183 | Completed throughput measurement 2026-08-02. Conclusion: `zig build test` is already parallel; floor is structural. |
| `editor-browser-audit.md` | `docs/audits/editor-browser-audit.md` | 75 | Completed browser review for editor M0–M5. |
| `publication-conformance/REPORT.md` | `docs/audits/publication-conformance/REPORT.md` | 535 | Completed conformance round for C01–C08 (round-2 remediation). Fixtures remain active under `docs/audits/publication-conformance/` for `zig build test-publication-conformance`. |

## What remains active

`docs/audits/` still contains **active test fixtures**, not audits:

- `docs/audits/publication-conformance/c0*` — 8 fixture families (Textile, includes/fragments, sitemap, RSS, layout precedence, cache/watch, asset collisions/SVG, parser/Unicode) used by `scripts/verify-publication-conformance.sh` via `zig build test-publication-conformance`.
- `docs/audits/publication-proof-pack/` and `docs/audits/publication-touches/` — hand-checkable JSON/HTML examples for the Proof Pack / Touch Atlas contracts. These are illustrative evidence snapshots, not audits.

## Why no new GitHub issues were filed

`optimization-backlog.md` proposed filing each `PERF-*` as a GitHub issue. At archival time the audit is 10 days old and its triage duplicates existing perf discussion; the backlog is largely stale (measurement infrastructure and scaling cliffs are captured at a high level in open roadmap issues, and the detailed per-candidate acceptance criteria remain in git history). Similarly, `project-health-surface.md` is design input, not product defects. To avoid filing ~35 stale issues, the archival preserves the full triage in history and does not mint new issues. If a specific `PERF-*` is revived, file it from the archived audit with a fresh measurement on the current `afterparty` tip.

## Verification

- `zig build test` (including `test-doc-links`) passes with `docs/archived/*` excluded.
- `zig build test-publication-conformance` still passes (fixtures remain at the original path).
- No active docs under `docs/` (outside `docs/archived/`) link to the archived audits as required navigation; one historical `README.md` benchmark note was retargeted to the archived path.
