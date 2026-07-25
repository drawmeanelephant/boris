---
title: "`src/compile.zig` review state"
id: docs/boris/src/compile/review-state
parent: docs/boris/src/compile
status: draft
tags: [boris, zig, source-reference, review-state, compile]
---

# `src/compile.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and uncertain claims

- **`experimental = true`:** name is historical; product default is HTML — do not treat flag as “off by default.”
- **Process RSS:** not measured; only arena capacity after `free_all`.
- **Publish atomicity:** same-filesystem rename preferred; cross-device copy+delete; concurrent readers during replace not claimed.
- **Apex under `--jobs`:** serialized at wrapper; C engine not proven re-entrant; U18 smoke is separate.
- **Fingerprint completeness:** depends on callers supplying stable include order (this file sorts transitive include paths before hash) and on wiki/theme material builders; pipeline/HTML parity of every edge kind should be verified against `cache.zig` + `pipeline.populateDependencyIndexFormat` when diagnosing “stale skip.”
- **Watch mode:** implemented outside this file; rebuilds call compile APIs — debounce/ignore roots not defined here.
- **Bundle evidence:** this dossier is based on the packed `src/compile.zig` document in the Space source bundle (~253534 bytes) plus collaborator modules already inspected (`cache`, `graph`, `dependency`, `cli`, `build.zig`). Live GitHub raw fetch failed once; if the tree moves, re-diff against `main`.

## Potential follow-up work

- Optional golden fingerprint vectors for one frozen fixture (cross-OS).
- Explicit same-size corrupt HTML incremental fixture if not already named.
- Clarify or retire `experimental` constant to avoid operator confusion.
- Cross-link `docs/contracts/html-output.md`, `parallel-rendering.md`, and cache format in a short operator “HTML compile phases” note (docs only).
