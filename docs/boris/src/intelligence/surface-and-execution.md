---
title: "`src/intelligence.zig` surface and execution"
id: docs/boris/src/intelligence/surface-and-execution
parent: docs/boris/src/intelligence
status: draft
tags: [boris, zig, source-reference, surface, intelligence]
---

# `src/intelligence.zig` surface and execution

## Threat model

`src/intelligence.zig` does not interface with external C code, the filesystem, or any concurrent infrastructure. It operates on caller-provided in-memory slices with a standard Zig allocator. The threat categories relevant to hostile ABI testing (pointer validity, C status codes, callback misuse, integer-width mismatch) do not apply here. The relevant correctness concerns are:

**Lifetime / borrow hazards (not mechanically prevented):**
The `Report` struct borrows endpoint string slices (`[]const u8`) from the input `pages` and `edges` slices without copying them. The `analyze` doc comment documents this: "the caller's endpoint strings outlive the report." If the caller frees its page/edge backing store before calling `report.deinit()` or rendering the findings/impact, the `Report.findings` and `Report.impact` entries contain dangling pointers. This is a **contract-only** property; the Zig type system does not enforce it.

**`errdefer` correctness on partial allocation:**
`analyze` uses `errdefer report.deinit()` at the top, which means any allocation failure after report initialization will correctly free the `findings` and `impact` ArrayLists. The intermediate locals (`known_sources`, `incoming`) use `defer` unconditionally. This structure is **structurally checked** as correct for normal allocation failure paths.

**Cycle safety in `collectImpact`:**
The BFS in `collectImpact` maintains a `seen` list and checks `containsEndpoint` before appending new nodes. This prevents infinite loops in cyclic graphs. The check is a linear scan of the `seen` list, which is correct but O(n²) for large impact sets. Cycle safety is **structurally checked** by the containment guard; performance at scale is untested.

**Hotspot threshold boundary:**
When `options.fan_in_threshold == 0`, the entire hotspot block is skipped via `if (options.fan_in_threshold > 0)`. This means a threshold of zero is treated as "disabled." This is **structurally checked** behavior but is not explicitly tested with an assertion that zero produces no hotspot findings.

**Edge kind matching:**
The unreferenced-page detection checks `edge.kind.len == 9 and std.mem.eql(u8, edge.kind, "reference")`. The length pre-check is a micro-optimization that is safe only because "reference" is exactly 9 bytes. This is **structurally correct** but ties correctness to the byte length of a string literal — a fragile coupling that would silently misfire if the kind value were ever changed. It is not tested with a near-miss kind string (e.g., "reference1").

**Missing-parent pages (satellite pages with no corresponding trunk):**
The `analyze` function counts satellites vs. roots based on `page.parent` being non-null, but does not validate that a named parent exists in the pages slice. This means `summary.satellites` can include pages whose declared parent has no corresponding entry. The test suite does not cover this case explicitly.

## Lifetime and ownership model

The ownership model is split between the report and its callers:

- **`Report.findings` and `Report.impact`**: owned by the `Report`. `Report.deinit()` frees both `ArrayListUnmanaged` backing arrays using `report.allocator`. The `allocator` field must be kept valid until `deinit` is called.
- **`Endpoint.value` strings inside findings and impact**: borrowed from the caller's `pages` and `edges` slices. The `Report` does not copy these strings. The doc comment documents this constraint: "safe to render after inputs are released only when the caller's endpoint strings outlive the report." This is a **contract-only** guarantee; the type system does not enforce it.
- **`incoming` and `known_sources`** (locals in `analyze`): deferred unconditionally. They are freed before `analyze` returns whether successfully or with an error, because they use `defer` rather than `errdefer`. This is correct — these locals do not need to outlive the function.
- **`seen`** (local in `collectImpact`): deferred unconditionally within `collectImpact`. This is correct.

The `errdefer report.deinit()` at the top of `analyze` covers partial allocation failure: if any `append` or `getOrPut` call returns `error.OutOfMemory`, the already-allocated findings and impact arrays are freed before the error propagates to the caller. This is **structurally checked** as correct.
