---
title: "`src/cache.zig` review state"
id: docs/boris/src/cache/review-state
parent: docs/boris/src/cache
status: draft
tags: [boris, zig, source-reference, review-state, cache]
---

# `src/cache.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and uncertain claims

- **No golden-vector tests:** The fingerprint tests confirm determinism and content-sensitivity across two calls on the same host. They do not compare against a known byte sequence that would prove cross-platform or cross-Zig-version stability. Cross-endianness correctness is asserted by construction (`std.mem.writeInt(.little)`), but not empirically demonstrated.
- **Include order is caller-responsibility:** `computePageFingerprintThemeInput` hashes `include_deps` in caller-provided order. If the caller supplies an unstable order, the fingerprint will be unstable. The file documents this only implicitly. Whether the pipeline always supplies a sorted include list is outside this file's scope and has not been confirmed here.
- **`getAffectedPages` has no cycle guard:** The visited-set prevents revisiting individual paths, but if `DependencyIndex.reverse` were somehow constructed with cycles (e.g., `a` depends on `b`, `b` depends on `a`), the visited check would still terminate the walk correctly because each path is only visited once. This is structurally checked by the visited-set logic, not by a cycle-detection test in this file.
- **Linear node scan:** `getAffectedPages` scans `nodes` linearly for every path popped from the stack (`O(nodes.len × stack_depth)`). For large content sets with deep transitive chains, this may be a performance concern, but no profiling evidence is available in this file.
- **Pipeline integration not confirmed here:** Whether the production pipeline (`pipeline.zig` or equivalent) actually calls these functions with the correct inputs, in the correct order, and with a stable `include_deps` ordering is outside the scope of this file.
