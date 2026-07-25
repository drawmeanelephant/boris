---
title: "`src/ir_emit.zig` review state"
id: docs/boris/src/ir_emit/review-state
parent: docs/boris/src/ir_emit
status: draft
tags: [boris, zig, source-reference, review-state, ir_emit]
---

# `src/ir_emit.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and uncertain claims

1. **Semantic-relations schema conformance:** The schema conformance test in `src/ir_schema_conformance_test.zig` only validates the base 0.2.0 output schema. Whether a published `ir-graph-0.3.0.schema.json` or `ir-manifest-0.3.0.schema.json` exists and is validated is uncertain from available evidence. The `relations` array structure is covered by the prose contract in `docs/contracts/ir-schema.md` but mechanical validation is not confirmed.
2. **Control character escaping:** `jsonout.escapeAppend` handles `\n`, `\r`, `\t`, `\b`, `\f`, `\\`, `\"`, and the `\u00XX` form for bytes below 0x20. Embedded NUL bytes (`\x00`) in page IDs or source paths would be emitted as `\u0000`, which is valid JSON but may be surprising to consumers. No adversarial test exercises this path.
3. **`hasSemanticRelations` called twice per render:** `renderGraph` calls `artifactSchemaVersion` (which calls `hasSemanticRelations`) and then `hasSemanticRelations` again directly at the `if !hasSemanticRelations(result)` branch. This is O(pages × relations) per call and is called twice. For large corpora with many relations, this is a minor redundancy. Not a correctness issue.
4. **`@TypeOf(result.edges.items[^1_0].from)` in `renderGraph`:** The inline `SemanticEdge` struct derives its `from`/`to` endpoint type from `result.edges.items[^1_0].from`. If `result.edges.items` is empty (zero edges), this comptime expression would fail. In practice, `hasSemanticRelations(result)` guards the entire `relations` block, and a result with semantic relations necessarily has at least parent edges — but this guard is semantic, not structural. The type capture would fail at compile time only if the type of `result` itself had an empty edges slice type, which is not the case for `pipeline.Result`. **Uncertain** whether this is reachable in any valid call path.
5. **No inline tests:** All coverage is via external test files. A unit test directly exercising `renderManifest` with a minimal struct literal would improve confidence and reduce coupling to `pipeline.run` in the schema conformance test.

***

## Potential follow-up work

> The following are suggestions only. No repository files should be modified based on this section alone.

- **Add inline unit tests** for `renderManifest`, `renderGraph`, and `renderBuildReport` using minimal anonymous struct literals that satisfy the duck-typed interface. This would allow testing edge cases (zero pages, empty diagnostics, pages with/without semantic relations, unicode strings, embedded special characters) without requiring a full pipeline run or fixture filesystem.
- **Add a JSON Schema for IR 0.3.0** (semantic relations) and extend `src/ir_schema_conformance_test.zig` to validate `graph.json` output from a fixture that includes semantic relations, ensuring the `relations` array structure matches the published schema.
- **Cache the `hasSemanticRelations` result** inside `renderGraph` to avoid two O(n) scans. A local `const has_relations = hasSemanticRelations(result);` before both uses would eliminate the redundancy.
- **Guard the `@TypeOf(result.edges.items[^1_0].from)` expression** with a comptime assertion or restructure to avoid potential confusion if callers ever pass a result type where the edges slice element type is different.
- **Consider a formal interface** (e.g., a comptime duck-type assertion function) for the `anytype result` parameter to provide a clear compile-time error message when a caller passes a structurally incompatible type.
