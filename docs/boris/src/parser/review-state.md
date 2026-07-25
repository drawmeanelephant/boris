---
title: "`src/parser.zig` review state"
id: docs/boris/src/parser/review-state
parent: docs/boris/src/parser
status: draft
tags: [boris, zig, source-reference, review-state, parser, frontmatter]
---

# `src/parser.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following items are observations only. No code changes are proposed here; they are recorded for planning purposes.

- **`EINVALIDPATH` consistency for `parent:`**: Consider whether `parent:` failing `validateEntityId` should also emit `EINVALIDPATH` rather than `EFRONTMATTER`, and whether this should be made explicit in `docs/contracts/diagnostics.md`.
- **`parent` path validation category test**: A test explicitly asserting `EFRONTMATTER` (not `EINVALIDPATH`) for a bad-path `parent:` value would make the asymmetry intentional and visible.
- **Exact source-limit acceptance test**: A test passing a source of exactly `max_source_bytes` bytes would close the off-by-one gap at the upper boundary.
- **`keyColumnInLine` unit test**: The column computation helper is untested in isolation.
- **Fixture manifest**: A checked-in manifest listing expected parse outcomes for every fixture file would let tooling verify fixture/test consistency independently of the Zig test runner.
- **Message stability contract**: If diagnostic message strings are part of the public contract (e.g. consumed by editor plugins or CI formatters), they should be listed in `docs/contracts/diagnostics.md` as stable strings rather than verified only by substring match.
