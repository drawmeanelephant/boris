---
title: "`src/dependency.zig` evidence and cases"
id: docs/boris/src/dependency/evidence-and-cases
parent: docs/boris/src/dependency
status: draft
tags: [boris, zig, source-reference, evidence, dependency]
---

# `src/dependency.zig` evidence and cases

## Embedded test

### `test "DependencyIndex basic adding and rendering"`

**Setup:** Creates a `DependencyIndex` with `std.testing.allocator`. Adds five edges across two source documents and three target documents, covering three distinct `DependencyKind` values (`.layout`, `.reference`, `.asset`, `.parent`). Calls `renderJson(gpa)` and defers `gpa.free(json)`.

**Assertions:**

1. The output contains `"schemaVersion": "0.1.0"` — verifies the version string is present.
2. The output contains `"forward"` — verifies the forward index key is emitted.
3. The output contains `"reverse"` — verifies the reverse index key is emitted.

**What this directly demonstrates:**

- The full `addDependency` → `renderJson` round-trip runs without error under the test allocator.
- The output is a non-empty string containing the three expected substrings.
- Memory management is correct under `std.testing.allocator` leak detection (any allocation leak would cause the test to fail with a leak report).

**What this does not demonstrate:**

- Correctness of sorted key order in the output.
- That deduplication works (no duplicate edges are added in the fixture).
- That the `reverse` map contains the correct source paths (only substring `"reverse"` is checked, not any specific value).
- That `kind` values appear correctly in the output.
- Behavior with zero edges, single edges, or edges sharing the same source and target.
- Behavior when `source` == `target` (self-loop).
- That forward and reverse edge counts match (consistency invariant).
- Behavior when path strings contain characters requiring JSON escaping.
- Partial-update rollback behavior on allocation failure.

***
