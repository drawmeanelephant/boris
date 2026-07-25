---
title: "`src/intelligence.zig` review state"
id: docs/boris/src/intelligence/review-state
parent: docs/boris/src/intelligence
status: draft
tags: [boris, zig, source-reference, review-state, intelligence]
---

# `src/intelligence.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and uncertain areas

The following are explicitly uncertain or unconfirmed from the inspected evidence:

- **Call site in production binary**: No import of `intelligence_mod` into `root_mod` or any other production module is visible in `build.zig`. The build comment says "CLI wiring remains a separate product slice." Whether `intelligence.zig` is transitively reachable from the product binary cannot be confirmed from the build configuration alone.
- **Duplicate page IDs**: `analyze` does not detect or reject duplicate IDs in the `pages` slice. Both entries would be independently processed and would both generate separate unreferenced-page findings. This is not tested and no contract document for this case was inspected.
- **Edges referencing unknown pages**: An edge whose `to` or `from` endpoint names a page ID not present in the `pages` slice is silently handled — the incoming count is tracked, and the source endpoint is registered, but no diagnostic is emitted. Whether this is intended behavior is not documented in the code or in any contract inspected.
- **`fan_in_threshold` for `.page` endpoints**: The `incoming` tracking counts edges to any endpoint type, but only `.source` endpoints are tracked in `known_sources`. If a `.page` endpoint receives multiple incoming edges and the threshold is met, a `fan_in_hotspot` finding is emitted for it. The summary's `hotspots` counter reflects this, but the test only exercises `.source` endpoints. Whether `.page` hotspot detection is intentional is not confirmed.
- **Relationship to `src/graph.zig`**: The intelligence module defines its own `Page` and `Edge` structs that are structurally similar to but distinct from any types in `src/graph.zig`. Whether callers are expected to map from the pipeline's graph types to these analysis types, or whether these are the canonical shared types, is not confirmed by the inspected evidence.

## Potential follow-up work

> *This section contains suggestions only. No repository files should be modified based on this document.*

- **Lifetime enforcement**: Consider having callers pass endpoint strings by providing an arena or making `analyze` copy string values into the report's allocation. The current borrow is safe but fragile across async or multi-step rendering pipelines.
- **Edge kind as enum or comptime constant**: The `edge.kind.len == 9` pre-check is a latent fragility. A bounded kind enum or a named constant for `"reference"` would make it robust against future kind additions.
- **Additional test coverage**: Empty-input behavior, duplicate page IDs, edges to unknown pages, `fan_in_threshold = 1`, and cyclic graphs would strengthen the test suite.
- **CLI wiring confirmation**: A clear import or adapter confirming where `analyze` is called from the product CLI would resolve the production integration uncertainty.
- **`collectImpact` complexity note**: The O(n²) containment scan in `seen` is acceptable for expected Documentation Intelligence graph sizes but is not documented as a known tradeoff. A comment noting the linear-scan approach and its acceptable scale would aid future readers.
