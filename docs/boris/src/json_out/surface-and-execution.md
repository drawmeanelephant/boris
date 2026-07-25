---
title: "`src/json_out.zig` surface and execution"
id: docs/boris/src/json_out/surface-and-execution
parent: docs/boris/src/json_out
status: draft
tags: [boris, zig, source-reference, surface, json_out]
---

# `src/json_out.zig` surface and execution

## Public API

The module exports seven public functions and no public types.

### `escapeAppend`

```zig
pub fn escapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void
```

Iterates over `s` byte-by-byte. For each byte, applies JSON string escape rules:


| Input byte | Emitted sequence |
| :-- | :-- |
| `"` | `\"` |
| `\` | `\\` |
| `\n` | `\n` |
| `\r` | `\r` |
| `\t` | `\t` |
| `< 0x20` (other) | `\uXXXX` (4 hex digits, zero-padded, lowercase) |
| All other bytes | Passed through unchanged |

**Important constraint:** Processing is byte-by-byte. Multi-byte UTF-8 sequences are passed through uninterpreted as long as all constituent bytes are ≥ 0x20. There is no validation that input bytes form well-formed UTF-8, no surrogate-pair handling, and no Unicode normalization. Invalid UTF-8 will be silently passed through byte-by-byte, producing a JSON string that a strict JSON parser may reject. This is behavior that can be inferred structurally from the code; whether it is a problem in practice depends on whether Boris's upstream inputs are always valid UTF-8, which this module does not enforce.

The `\uXXXX` fallback uses a 6-byte stack buffer via `std.fmt.bufPrint`. The format string `\u{x:0>4}` produces exactly 4 lowercase hex digits, zero-padded. This is structurally correct for JSON but uses the Unicode escape form for all control characters below 0x20, not just those without named escapes.

### `indent`

```zig
pub fn indent(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize) !void
```

Appends `level` repetitions of the two-space string `"  "` to `buf`. No trailing newline or other character is emitted. The loop is a simple counted iteration; it emits exactly `level * 2` space bytes.

### `writeString`

```zig
pub fn writeString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void
```

Appends `"`, then the result of `escapeAppend(s)`, then `"`. This wraps a string in JSON double-quote delimiters with proper interior escaping. It does not emit a trailing comma or newline; structural punctuation is the caller's responsibility.

### `writeNull`

```zig
pub fn writeNull(buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void
```

Appends the literal bytes `null`. Allocation can still fail (the underlying `appendSlice` propagates allocator errors), so the return type is `!void`.

### `writeBool`

```zig
pub fn writeBool(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: bool) !void
```

Appends `true` or `false` depending on `v`. No quoting.

### `writeUsize`

```zig
pub fn writeUsize(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: usize) !void
```

Formats `v` as a decimal integer using a 32-byte stack buffer (`[^1_32]u8`) via `std.fmt.bufPrint` with `{d}`. On a 64-bit target, `usize` is 64 bits; the maximum decimal representation is 20 digits, safely within the 32-byte buffer. Appends the result to `buf`.

**Note:** The buffer is 32 bytes. `usize` on a 64-bit target has a maximum decimal width of 20 characters (`18446744073709551615`). This is safe by margin, but is not structurally enforced by a compile-time assertion. If Boris is ever built for an exotic target where `usize` exceeds 64 bits, `bufPrint` would return `error.NoSpaceLeft` and propagate as an error rather than silently truncating.

### `writeOptionalU32`

```zig
pub fn writeOptionalU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: ?u32) !void
```

If `v` is non-null, formats the `u32` value as a decimal integer using a 16-byte stack buffer via `std.fmt.bufPrint` with `{d}`. The maximum decimal width of a `u32` is 10 digits (`4294967295`), safely within 16 bytes. If `v` is null, delegates to `writeNull`. No quoting; the emitted token is a bare JSON number or `null`.

## Allocator contract

Every function takes an explicit `gpa: std.mem.Allocator` parameter alongside the buffer pointer. This matches the Boris codebase convention of using unmanaged `std.ArrayList(u8)` (`.empty` initialization, all mutations passed an allocator). The module never stores the allocator, never frees memory, never calls `buf.deinit`, and never replaces `buf` with a new allocation. Ownership of the buffer remains entirely with the caller throughout. All allocation failures are propagated immediately as errors via `!void`.

## Determinism properties

The module-level comment asserts determinism by design: 2-space indent, LF line endings, fixed key order. The mechanisms supporting this claim are:

- **2-space indent:** structurally enforced by `indent`'s loop emitting exactly `"  "` per level — directly demonstrated.
- **LF line endings:** `\n` is the only newline character the module emits; `\r` is an *input* escape target, not emitted. Structural — no CR is ever appended by these helpers.
- **Fixed key order:** not enforced by this module at all. Key order is determined entirely by the explicit call sequence in `ir_emit.zig` and `rag_emit.zig`. `json_out` has no awareness of key names, object structure, or ordering. The claim is accurate but the responsibility lies entirely outside this file.
