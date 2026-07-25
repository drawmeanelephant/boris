---
title: "`src/json_out.zig` review state"
id: docs/boris/src/json_out/review-state
parent: docs/boris/src/json_out
status: draft
tags: [boris, zig, source-reference, review-state, json_out]
---

# `src/json_out.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

- **UTF-8 validation gate:** The byte-by-byte passthrough in `escapeAppend` does not validate multi-byte sequences. If Boris receives non-UTF-8 input (e.g., a malformed frontmatter string), the emitted JSON string would contain invalid UTF-8 bytes, which strict consumers may reject. An optional validation step or a documented explicit non-goal would clarify the contract.
- **`\r`, `\t`, `\\` escape coverage in tests:** The inline test covers only `"` and `\n`. Adding test cases for `\r`, `\t`, `\\`, and the `\uXXXX` path would complete unit coverage for all branches of `escapeAppend`'s switch.
- **Compile-time buffer size assertion:** `writeUsize` uses a 32-byte buffer for a `usize`. A `comptime` assertion (`std.debug.assert(@sizeOf(usize) <= 8)` or equivalent) would make the implicit size assumption explicit without runtime cost.
- **`writeOptionalString` promotion:** `ir_emit.zig` defines a private `writeOptionalString` wrapper that calls either `writeString` or `writeNull`. This pattern is used repeatedly across both `ir_emit` and implicitly in `rag_emit`. Promoting it to `json_out` as a public function would reduce caller duplication, though this is a minor refactor with no correctness implication.
