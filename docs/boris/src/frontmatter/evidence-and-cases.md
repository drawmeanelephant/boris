---
title: "`src/frontmatter.zig` evidence and cases"
id: docs/boris/src/frontmatter/evidence-and-cases
parent: docs/boris/src/frontmatter
status: draft
tags: [boris, zig, source-reference, evidence, frontmatter]
---

# `src/frontmatter.zig` evidence and cases

## Test harness construction

`src/frontmatter.zig` carries its own tests using Zig's built-in `test` blocks. These tests are compiled and run as part of the `parser_mod` test step declared in `build.zig`:

```zig
const parser_mod = b.createModule(.{
    .root_source_file = b.path("src/parser.zig"),
    ...
});
const parser_tests = b.addTest(.{ .root_module = parser_mod });
```

`src/parser.zig` imports `frontmatter.zig` as a dependency, so when the Zig test runner processes `parser_mod` it discovers and runs the `test` blocks in `frontmatter.zig` transitively. The tests are therefore not run from a separate root module — they are pulled in through the import graph of `src/parser.zig`.

The tests are also reachable via the default `zig build test` step, which includes `run_parser_tests`.

No hostile C implementation, no `build_options`, no `linkApex`, and no special flags are involved. The tests use only the Zig standard library testing allocator (`std.testing.allocator`) for the `list_gpa` role and an `ArenaAllocator` wrapping it for the `retain` role.

The production binary also links `frontmatter.zig` (via `parser.zig` which is in the root module's import chain). There is no conditional compilation that would swap in a different frontmatter implementation.

***

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `Status` | `pub const enum` | Closed three-value content-status vocabulary | — | `draft`, `published`, `archived` only | Closed vocabulary; no other values accepted |
| `Status.parse` | `pub fn` | Parse a string to `Status` or null | Exact lowercase spellings | Returns enum variant or `null` | Tested in `page.zig`; `frontmatter.zig` mirrors the same logic |
| `Status.name` | `pub fn` | Return `@tagName` string | Any `Status` variant | Lowercase string | Thin wrapper |
| `Meta` | `pub const struct` | Parsed frontmatter result; all string fields arena-owned | — | Fields default to null/empty; `body_offset` and `has_frontmatter` set by parser | String lifetime: owned by caller's `retain` allocator |
| `validateId` | `pub fn` | Delegate to `pathutil.validateEntityId` (→ `identity.validateEntityId`) | `[]const u8` candidate id | `bool` | Length ≤ 255, no `/` prefix, no trailing sep, no empty segments, no `.`/`..`, no whitespace, no `\` |
| `parse` | `pub fn` | Full frontmatter extraction with diagnostics | Raw source bytes, source_path, retain allocator, list_gpa allocator, `*ArrayList(Diagnostic)` | `Meta` (never error except OOM); diagnostics appended to list | UTF-8 validity, fence structure, closed key set, value format, size bounds, arena protection |
| `test "parse title parent status tags"` | test | Happy-path: all five fields correctly parsed | Well-formed four-field frontmatter | Zero diagnostics; all fields populated with correct values | Base correctness |
| `test "parse rejects parentEntry as unknown key"` | test | Legacy key `parentEntry` is not in the closed set | `parentEntry: guides/intro` | `meta.parent == null`; exactly one `EFRONTMATTER` diagnostic; message contains `"parentEntry"` | Closed-key enforcement; no silent aliasing |
| `test "parse rejects unknown key and continues"` | test | Unknown key does not abort parse; subsequent keys still parsed | `tags: nope` (malformed) among valid keys | At least one `EFRONTMATTER` diagnostic with code `EFRONTMATTER` | Resilient continuation after error |
| `test "parse duplicate key"` | test | Second occurrence of a key is rejected | Two `title:` lines | One `EFRONTMATTER` diagnostic; `meta.title` holds first value `"A"` | First-wins semantics; duplicate detection |
| `test "parse rejects tags with a trailing comma"` | test | Tag list `[alpha, \t]` has no token after trailing comma | Inline whitespace-only after comma | One `EFRONTMATTER` diagnostic | Trailing-comma detection in tag list |
| `test "validateId"` | test | Shape rules for entity IDs | Empty, double-slash, `../x`, space, 255-byte all-`a`, 256-byte all-`a` | Correct boolean per rule; 255-byte accepted, 256-byte rejected | Length and segment rules via `identity.validateEntityId` |
| `test "parse rejects oversize title without retaining it"` | test | 10,000-byte title must not enter retain arena | `---\ntitle: XXXXX…\n---` | `meta.title == null`; one `EFRONTMATTER`; message contains `"512"` and `"10000"`; `arena.queryCapacity() < 10_000` | Arena-protection contract; size rejection before dupe |
| `test "parse rejects oversize id without retaining it"` | test | `max_entity_id_bytes + 50`-byte id | `---\nid: eee…\n---` | `meta.id == null`; one `EFRONTMATTER`; message contains `"255"` | Same arena-protection contract for id |
| `test "parse accepts title and id at exact length limits"` | test | Boundary: `max_title_bytes` and `max_entity_id_bytes` exactly | `title:` of 512 T's, `id:` of 255 i's | Zero diagnostics; `meta.title.?.len == 512`; `meta.id.?.len == 255` | Off-by-one correctness at both upper limits |


***

## Hostile-case walkthrough

### UTF-8 BOM rejection

**Injected behavior:**
Source begins with bytes `0xEF 0xBB 0xBF`.

**Wrapper boundary exercised:**
First three bytes of `source` checked explicitly before any fence detection.

**Expected response:**
`pushDiag` with code `EINVALIDUTF8`, line 1, column 1, message `"UTF-8 BOM is not allowed"`. Returns `meta` immediately with all fields null/default; `has_frontmatter` stays false.

**Forbidden unsafe response:**
Passing BOM bytes to `utf8ValidateSlice` or the line-scanning loop, which would produce confusing downstream diagnostics or misidentify the opening fence.

**Evidence strength:**
Structurally checked by code; not covered by a co-located test (the BOM check is present in the source but no `test "parse rejects BOM"` block exists in the file). Uncertain whether integration tests cover it.

**Residual gap:**
No co-located test for BOM. A BOM followed by `---` is the most plausible real-world occurrence; also no test for BOM inside the body (which is fine, only the file start is checked).

***

### Invalid UTF-8 byte sequence

**Injected behavior:**
Source contains a byte sequence that is not valid UTF-8 (e.g., `0x80` bare continuation byte).

**Wrapper boundary exercised:**
`std.unicode.utf8ValidateSlice(source)` called after BOM check.

**Expected response:**
`pushDiag` with `EINVALIDUTF8`, message `"source is not valid UTF-8"`. Returns immediately.

**Forbidden unsafe response:**
Proceeding to parse line-by-line over invalid UTF-8 bytes, which could produce incorrect column positions or slice into the middle of a multi-byte sequence.

**Evidence strength:**
Structurally checked; no co-located test.

**Residual gap:**
No co-located test. Multi-byte sequences that are structurally valid UTF-8 but semantically confusing (e.g., non-BMP codepoints in key names) are not separately tested.

***

### Opening fence with trailing content

**Injected behavior:**
File begins with `---x\n` or `--- \n` — `---` is present but the remainder of the first line is not empty (after stripping optional `\r`).

**Wrapper boundary exercised:**
After finding `---` at offset 0, the parser checks that position 3 (or 4 after `\r`) is `\n`. If not, `pushDiag` with `EFRONTMATTER` is emitted.

**Expected response:**
One diagnostic; `meta` returned with `has_frontmatter` false.

**Forbidden unsafe response:**
Treating `--- title: x` as a valid fence-opening and extracting `title: x` as a field.

**Evidence strength:**
Structurally checked; no co-located test for this specific case.

**Residual gap:**
No test for `--- ` (fence with trailing space), which is a common authoring mistake. Behavior is correct per code but unconfirmed by test.

***

### Unclosed frontmatter

**Injected behavior:**
File has an opening `---` fence and key-value content but no closing `---` before EOF.

**Wrapper boundary exercised:**
The line loop detects `line_end >= source.len` after advancing the cursor; the outer `while (i <= source.len)` guard also catches the case where the loop exits without seeing a closing fence.

**Expected response:**
`pushDiag` with `EFRONTMATTER`, message `"unclosed frontmatter: missing closing ---"`. `meta.body_offset` set to `source.len`.

**Forbidden unsafe response:**
Returning partially-populated `meta` silently; treating EOF as an implicit closing fence without a diagnostic.

**Evidence strength:**
Structurally checked; no co-located test for this specific case.

**Residual gap:**
No test confirms the exact diagnostic message text or that `meta.body_offset == source.len`.

***

### Unknown key (resilience and key name in message)

**Injected behavior:**
A key not in the closed set `{id, title, parent, status, tags}` appears in the frontmatter — specifically `parentEntry` (legacy key) and an arbitrary unsupported key.

**Wrapper boundary exercised:**
The `else` branch of the key-dispatch chain formats the key name into the diagnostic message and appends an `EFRONTMATTER` diagnostic, then advances to the next line.

**Expected response:**
One diagnostic per unknown key with `code == .EFRONTMATTER` and the key name embedded in `message`. Parsing continues; subsequent valid keys are still extracted.

**Forbidden unsafe response:**
Treating `parentEntry` as an alias for `parent` (which would silently smuggle a non-canonical value into the graph). Aborting the parse on first unknown key.

**Evidence strength:**
Directly demonstrated by `test "parse rejects parentEntry as unknown key"` and `test "parse rejects unknown key and continues"`.

**Residual gap:**
The second test uses a malformed tag value to generate the diagnostic, which also verifies resilience, but the assertion `diags.items.len >= 1` is weak — it does not confirm that parsing continued and populated `meta.title`. A tighter assertion would confirm both the error and the continued successful parse.

***

### Duplicate key (first-wins)

**Injected behavior:**
The same supported key appears twice, e.g., two `title:` lines.

**Wrapper boundary exercised:**
Each key has a corresponding `bool` flag in `KeyFlags`. On second occurrence, the flag is already `true`; the duplicate-detection branch emits `EFRONTMATTER` and skips the new value.

**Expected response:**
Exactly one `EFRONTMATTER` diagnostic; `meta.title` holds the first value; second value is discarded.

**Forbidden unsafe response:**
Second value silently overwriting first; no diagnostic.

**Evidence strength:**
Directly demonstrated by `test "parse duplicate key"`.

**Residual gap:**
Only `title` duplication is tested. The same logic path exists for `id`, `parent`, `status`, and `tags` but is not individually tested.

***

### YAML-incompatible value forms

**Injected behavior:**
A value begins with `|`, `>`, `[` (outside tags), `{`, `&`, or `*`, or is single-quoted.

**Wrapper boundary exercised:**
`parsePlainOrQuoted` checks the first byte of the trimmed value before any further processing.

**Expected response:**
Returns an error (`BlockScalar`, `FlowCollection`, `AnchorAlias`, or `SingleQuote`) that the caller converts to a diagnostic and a null field value.

**Forbidden unsafe response:**
Attempting to parse YAML block syntax as a plain value, producing a garbled string in the retain arena.

**Evidence strength:**
Structurally checked; the rejection cases are present in code but no co-located test exercises them individually. The `test "parse rejects tags with a trailing comma"` exercises `BadTags` but not the YAML-form rejections.

**Residual gap:**
No test for `id: &anchor`, `title: |block`, `parent: {flow}`, etc. These are plausible authoring mistakes; their rejection is code-only, not demonstrated.

***

### Oversize title (arena protection)

**Injected behavior:**
`title:` value is 10,000 bytes — well above `max_title_bytes = 512`.

**Wrapper boundary exercised:**
After `parsePlainOrQuoted` succeeds (the value is syntactically valid), `val.len > max_title_bytes` is checked before `retain.dupe`. If true, a diagnostic message is formatted (using `retain` for the message string itself, which is small) and `meta.title` is left null.

**Expected response:**
`meta.title == null`; one `EFRONTMATTER` diagnostic whose message contains both `"512"` and `"10000"`; `arena.queryCapacity() < 10_000` (the 10 KB title body was never copied into the retain arena).

**Forbidden unsafe response:**
Calling `retain.dupe(u8, val)` before the size check, which would copy 10,000 bytes into the compile-run arena.

**Evidence strength:**
Directly demonstrated by `test "parse rejects oversize title without retaining it"`, including the arena capacity assertion.

**Residual gap:**
The arena capacity check uses `arena.queryCapacity()` which returns the arena's *committed capacity*, not the amount of live allocations. On some platforms or allocator implementations, capacity can exceed the sum of allocations. The test's assertion that `capacity < 10_000` is therefore a heuristic rather than a proof that the title bytes were never written, though it is strong circumstantial evidence on the tested allocator. A stricter check would compare arena capacity before and after the parse call.

***

### Oversize id (arena protection)

**Injected behavior:**
`id:` value is `max_entity_id_bytes + 50` bytes — all alphabetic, syntactically valid except for length.

**Wrapper boundary exercised:**
After `parsePlainOrQuoted` succeeds, `v.len > max_entity_id_bytes` is checked. If true, diagnostic is emitted and `meta.id` stays null.

**Expected response:**
`meta.id == null`; one `EFRONTMATTER` diagnostic with message containing `"255"`.

**Forbidden unsafe response:**
Passing the oversize value to `validateId` before the length check (which would reject it anyway, but would also have called `identity.validateEntityId` on a string longer than 255 bytes, which is safe but wasteful); or calling `retain.dupe` before the check.

**Evidence strength:**
Directly demonstrated by `test "parse rejects oversize id without retaining it"`.

**Residual gap:**
No corresponding arena capacity assertion for `id` (unlike the `title` test). The test confirms null and the diagnostic text but does not assert the retain arena was not inflated.

***

### Exact-length boundary acceptance

**Injected behavior:**
`title:` is exactly `max_title_bytes` (512) bytes; `id:` is exactly `max_entity_id_bytes` (255) bytes of single alphabetic character `i`.

**Wrapper boundary exercised:**
`val.len > max_title_bytes` (strict greater-than) and `v.len > max_entity_id_bytes` — both are false at the exact limit.

**Expected response:**
Zero diagnostics; `meta.title.?.len == 512`; `meta.id.?.len == 255`.

**Forbidden unsafe response:**
Treating the exact limit as an error (off-by-one); or accepting `len == limit + 1`.

**Evidence strength:**
Directly demonstrated by `test "parse accepts title and id at exact length limits"`.

**Residual gap:**
The 255-byte `id` is all `i` characters, which are valid for `validateEntityId`. The test does not separately confirm that a 255-byte id with structure (slashes, mixed chars) is also accepted.

***

### Trailing comma in tag list

**Injected behavior:**
`tags: [alpha, \t]` — after the comma there is only whitespace before the closing `]`, meaning no token follows the separator.

**Wrapper boundary exercised:**
`parseTagsList` advances past the comma, trims whitespace, and checks `if (i >= inner.len) return error.BadTags` — the trailing-comma guard.

**Expected response:**
One `EFRONTMATTER` diagnostic; `meta.tags` is set to `&.{}`.

**Forbidden unsafe response:**
Treating the comma as a valid separator and returning an empty final tag, or returning a slice with a zero-length string element.

**Evidence strength:**
Directly demonstrated by `test "parse rejects tags with a trailing comma"`.

**Residual gap:**
Only a single-comma trailing case is tested. A list like `[a, b,]` (trailing comma before `]`) is the more common authoring mistake. That case hits the same guard (`if (i >= inner.len) return error.BadTags` after consuming the comma), so it should also be rejected, but is not separately tested.

***

### validateId length and shape rules

**Injected behavior:**
Various candidate strings: empty, double-slash, `../x`, space, 255-byte all-`a`, 256-byte all-`a`.

**Wrapper boundary exercised:**
`frontmatter.validateId` → `pathutil.validateEntityId` → `identity.validateEntityId`.

**Expected response:**
`true` for `"guides/intro"` and the 255-byte string; `false` for empty, double-slash, parent-traversal, space, and 256-byte string.

**Forbidden unsafe response:**
Accepting any string that would produce an invalid or traversal-capable graph key.

**Evidence strength:**
Directly demonstrated by `test "validateId"` for all listed cases.

**Residual gap:**
`frontmatter.validateId` is a one-line delegation to `pathutil.validateEntityId`; the delegation itself is trivially verified. More exhaustive shape testing is done in `identity.zig`'s own tests. No test for backslash in an id through this call site (though `identity.validateEntityId` rejects it).

***

## Control flow

```text
frontmatter.parse(source, source_path, retain, list_gpa, diags)
    │
    ├─ BOM check (bytes 0–2)
    │      → pushDiag EINVALIDUTF8, return meta
    │
    ├─ utf8ValidateSlice(source)
    │      → pushDiag EINVALIDUTF8, return meta
    │
    ├─ startsWith(source, "---") check
    │      false → body_offset=0, return meta (no frontmatter)
    │
    ├─ fence line-end check (source[^1_3] must be '\n' after optional '\r')
    │      fail → pushDiag EFRONTMATTER, return meta
    │
    ├─ meta.has_frontmatter = true
    │
    └─ line loop (i advances through source bytes)
           │
           ├─ line == "---" → meta.body_offset = after fence, return meta (success)
           │
           ├─ trimmed empty → skip
           │
           ├─ contains ':' → key/value dispatch
           │      │
           │      ├─ key == "id"
           │      │      ├─ flags.id already set → pushDiag EFRONTMATTER (duplicate)
           │      │      └─ parsePlainOrQuoted(raw_val)
           │      │             ├─ error → pushDiag EFRONTMATTER, meta.id stays null
           │      │             └─ ok → size check, validateId check
           │      │                    ├─ oversize → pushDiag EFRONTMATTER, meta.id null
           │      │                    ├─ invalid shape → pushDiag EFRONTMATTER, meta.id null
           │      │                    └─ ok → retain.dupe → meta.id = slice
           │      │
           │      ├─ key == "title" (analogous; uses max_title_bytes)
           │      ├─ key == "parent" (analogous; uses max_entity_id_bytes + validateId)
           │      ├─ key == "status"
           │      │      └─ parsePlainOrQuoted → Status.parse(val)
           │      │             ├─ null → pushDiag EFRONTMATTER
           │      │             └─ ok → meta.status = enum variant
           │      │
           │      ├─ key == "tags"
           │      │      └─ parseTagsList(retain, raw_val)
           │      │             ├─ error → pushDiag EFRONTMATTER, meta.tags = &.{}
           │      │             └─ ok → meta.tags = owned slice
           │      │
           │      └─ unknown key → pushDiag EFRONTMATTER (key name in message)
           │
           ├─ no ':' in line → pushDiag EFRONTMATTER (malformed line)
           │
           └─ EOF without closing fence
                  → pushDiag EFRONTMATTER (unclosed), meta.body_offset = source.len, return meta
```


***
