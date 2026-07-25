---
title: "`src/context.zig` review state"
id: docs/boris/src/context/review-state
parent: docs/boris/src/context
status: draft
tags: [boris, zig, source-reference, review-state, context]
---

# `src/context.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and uncertain claims

- **Absolute outdir:** `content_root` absolute is rejected; outdir absolute path policy is less explicitly gated in the same guard (confirm against latest source if hardening).
- **Entity ids with path separators in filenames:** page paths use `pages/{id}.md` — ids are already validated by the pipeline; nested ids imply nested dirs via `ensureParent`.
- **Empty selection:** valid compile + scope that selects zero pages is unlikely (`InvalidScope` if seed missing); whole-site null scope selects all.
- **Large sites:** all selected page docs and the full bundle held in memory before write.
- **Bundle source:** dossier from Space packed `src/context.zig` (~23212 bytes) plus `exportscope.zig`, `main.zig` / `cli.zig` call sites, and README/CHANGELOG context-mode notes.

## Potential follow-up work

- Cross-link this dossier from the Context Bundle contract and README operator table.
- Optional golden fixture for multi-page scoped + split manifest field set (beyond the two unit tests).
- Align absolute-path policy with `llms.zig` (`AbsolutePath` on both roots) if product wants symmetry.
- Document continuation vocabulary (`single` / `continues` / `continued`) in the public contract if not already normative.
