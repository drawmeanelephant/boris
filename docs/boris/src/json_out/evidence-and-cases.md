---
title: "`src/json_out.zig` evidence and cases"
id: docs/boris/src/json_out/evidence-and-cases
parent: docs/boris/src/json_out
status: draft
tags: [boris, zig, source-reference, evidence, json_out]
---

# `src/json_out.zig` evidence and cases

## Inline test

```zig
test "escapeAppend quotes and newlines" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try escapeAppend(&buf, gpa, "a\"b\nc");
    try std.testing.expectEqualStrings("a\\\"b\\nc", buf.items);
}
```

This test uses `std.testing.allocator` (which detects leaks), provides input containing a double-quote and a newline embedded in regular ASCII characters, and asserts the exact escaped byte sequence. It demonstrates:

- `"` → `\"` (directly demonstrated)
- `\n` → `\n` (directly demonstrated)
- Surrounding ASCII bytes pass through unchanged (directly demonstrated)

It does not cover:

- `\r`, `\t`, or `\\` escaping (untested by this file's test)
- The `\uXXXX` control-character path (untested by this file's test)
- Multi-byte UTF-8 passthrough (untested)
- Invalid UTF-8 input (untested)
- Zero-length input (untested)
- Allocation failure paths (untested)

Whether any of these gaps are covered by callers' tests in `ir_emit.zig` or `rag_emit.zig` is a separate question. `rag_emit.zig` contains one test (`"catalog JSONL field order and escaping are stable"`) that exercises `escapeAppend` indirectly via `renderCatalogJsonl` with a title containing `"` and `\n`, which provides partial additional coverage for those two cases through a caller. The `\r`, `\t`, `\\`, and `\uXXXX` paths are not demonstrated by any test visible in this inspection.
