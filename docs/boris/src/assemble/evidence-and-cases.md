---
title: "`src/assemble.zig` evidence and cases"
id: docs/boris/src/assemble/evidence-and-cases
parent: docs/boris/src/assemble
status: draft
tags: [boris, zig, source-reference, evidence, assemble]
---

# `src/assemble.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- |
| `layout split is zero-copy into raw` | test | prefix/suffix alias raw | pointer identity | Zero-copy plan |
| `layout missing content marker` | test | no content | `MissingContentMarker` | Required marker |
| `layout split rejects invalid UTF-8` | test | truncated sequence | `InvalidUtf8` | Load gate |
| `layout duplicate content marker` | test | two content | `DuplicateContentMarker` | Uniqueness |
| `layout multi-slot nav breadcrumb title toc` | test | all chrome flags | flags set; no content-only prefix | Multi-slot plan |
| duplicate optional markers / unknown | test | nav×2, `&#123;&#123;nope&#125;&#125;` | `DuplicateLayoutMarker` / `UnknownLayoutMarker` | Closed grammar |
| `layout metadata footer and asset-url plan` | test | F9.1 helpers | paths + flags | asset-url parse |
| invalid asset-url matrix | test | `..`, abs, non-assets, spaces | `InvalidAssetUrl` | Path grammar |
| `writePage resolves asset-url slots in order` | test | href injection | published order | Slot stream |
| `writePage sequential splice…` | test | PRE/BODY/SUF | exact concat on disk | No mega-string |
| replace-over-prior / failed write keeps prior | test | atomic publish | new bytes or old kept; no stray temps | Publish IO |
| `HoldUntilFlush correct order` | test | flush then freeall | snapshot survives reset | Whiteboard ordering |
| premature invalidation (via HoldUntilFlush) | test | wipe before flush | `PrematureInvalidation` | Lifetime discipline |
| static fixture missing/duplicate | test | on-disk layouts | hard errors | Integration with files |
| Compile: layout missing aborts before content | integration | bad layout | `LayoutMissingMarker`; no dist page | Fail-fast load |


***

## Correctness properties and non-goals

**Holds (by design + tests):**

- Exactly one content slot in a valid plan.
- Optional slots are unique; unknown markers fail at load.
- Segment slices never copy template HTML.
- Page assembly is N sequential writes, not `prefix ++ body ++ suffix` allocation in product code.
- Successful publish replaces final via same-dir atomic temp+rename pattern.
- Failed write before replace preserves prior final and cleans current temp.
- Callers must not `arena.reset(.free_all)` until `writePage*` returns (enforced in tests via HoldUntilFlush).[^4_1]

**Does not claim:**

- Cross-volume atomic replace.
- That empty optional slots are rejected (empty string splice is allowed).
- HTML safety of slot contents (producers escape; assemble writes bytes blindly).
- Layout hot-reload inside the module (watch/recompile is compile/CLI).
- Generic templating or i18n.

***
