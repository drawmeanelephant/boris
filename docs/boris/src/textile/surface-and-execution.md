---
title: "`src/textile.zig` surface and execution"
id: docs/boris/src/textile/surface-and-execution
parent: docs/boris/src/textile
status: draft
tags: [boris, zig, source-reference, surface, textile]
---

# `src/textile.zig` surface and execution

## Public API surface

### `adapter_identity`

```zig
pub const adapter_identity = "boris-textile-adapter-v1";
```

A fixed string constant used by the incremental cache fingerprint to detect intentional adapter changes. The `textile-compatibility.md` contract specifies that a change to this string must invalidate cached Textile pages.

### `Diagnostic`

```zig
pub const Diagnostic = struct {
    line: u32 = 1,    // 1-based body-relative line
    column: u32 = 1,  // 1-based byte column within the original Textile line
    message: []const u8,
};
```

Carries the location and description of the first content error. Columns are byte offsets, not codepoint counts. The `message` slice always points to a string literal; it is never allocated and does not require freeing.

### `Result`

```zig
pub const Result = struct {
    markdown: []const u8 = "",
    diagnostic: ?Diagnostic = null,
    pub fn isOk(self: Result) bool { return self.diagnostic == null; }
};
```

On success, `markdown` is an allocator-owned `[]const u8` that the caller must free. On failure, `markdown` is the empty string `""` (not a heap allocation, safe to ignore), and `diagnostic` is populated. The two fields are mutually exclusive by convention; `isOk()` is the canonical check. No intermediate partially-successful allocation escapes: `errdefer out.deinit(allocator)` in `toMarkdown` and explicit `out.deinit(allocator)` before returning a failure `Result` ensure that the output buffer is freed on every failure path.

### `toMarkdown`

```zig
pub fn toMarkdown(body: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Result
```

The sole public entry point. Accepts a body slice (assumed to be post-frontmatter; the function does not strip or handle frontmatter). Returns `error.OutOfMemory` on allocator failure, otherwise always returns a `Result`. A non-UTF-8 body is detected before any block processing and returns a `Result` with a diagnostic immediately.

***
