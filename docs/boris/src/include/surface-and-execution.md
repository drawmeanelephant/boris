---
title: "`src/include.zig` surface and execution"
id: docs/boris/src/include/surface-and-execution
parent: docs/boris/src/include
status: draft
tags: [boris, zig, source-reference, surface, include]
---

# `src/include.zig` surface and execution

## Public API surface

### Constants

| Name | Value | Meaning |
| --- | --- | --- |
| `max_include_depth` | `32` | Maximum recursive nesting before `DepthExceeded` |
| `max_expanded_bytes` | `16 * 1024 * 1024` (16 MiB) | Maximum total bytes produced by one expansion call; also the per-file read ceiling in `readSourceAlloc` |
| `max_include_expansions` | `4096` | Maximum number of individual directive substitutions in one expansion call |
| `max_fail_str` | `512` | Maximum bytes copied into each `FailInfo` inline string buffer |

### Error set `IncludeError`

| Tag | `diag.Code` mapping | Meaning |
| --- | --- | --- |
| `IncludeSyntax` | `EINCLUDESYNTAX` | `&#123;&#123;include …&#125;&#125;` directive is structurally malformed |
| `IncludeMissing` | `EINCLUDEMISSING` | Target path not found or unreadable |
| `IncludeCycle` | `EINCLUDECYCLE` | Circular include chain detected on the stack |
| `InvalidPath` | `EINVALIDPATH` | Path fails the content-root-relative grammar |
| `DepthExceeded` | `EINCLUDECYCLE` | Stack depth exceeds `max_include_depth` |
| `ExpansionBudgetExceeded` | `EINCLUDECYCLE` | Byte or expansion-count budget exceeded |
| `OutOfMemory` | `EIO` | Allocator returned an error |
| `ReadFailed` | `EIO` | OS-level read failure other than StreamTooLong / OOM |

Note: `DepthExceeded` and `ExpansionBudgetExceeded` are both mapped to `EINCLUDECYCLE` by `errorCode`. This is a lossy mapping — a consumer inspecting only the `diag.Code` cannot distinguish depth overflow or budget exhaustion from a true reference cycle. Whether this conflation is intentional is not documented beyond the `remediationFor` text, which gives a single message for all three.

### `FailInfo`

Fixed-size struct with two `[^1_512]u8` inline string buffers. Stores the line, column, a detail string (typically the offending path), and a locus string (the content-root path of the file that contained the bad directive — empty when the failure is in the top-level page body). Strings are always copied via `copyCap` — never stored as slices into caller memory — so `FailInfo` values remain valid after the file buffers that produced them have been freed. This is structurally enforced: `copyCap` performs `@memcpy` bounded to `min(s.len, 512)`.

The `setAt` method recomputes line and column from a byte offset using `lineColAt`, which performs a linear forward scan. For typical include files this is proportional to file size, not a constant-time operation.

### `ScanHit`

A path slice (a view into the caller-supplied `body`), a byte offset, and a 1-based line/column. Because `path` is a slice into `body`, callers that need `ScanHit` values to outlive the source buffer must dupe them. The public `collectTransitiveIncludes` and `expandIncludes` APIs handle this internally; `ScanHit` is not exposed to external callers via those paths.

### `validateIncludePath(path: []const u8) bool`

Pure predicate. Accepts a content-root-relative path satisfying:
- Non-empty
- Does not begin with `/` or `\`
- Contains no `\` anywhere
- No segment is empty (catches `//`)
- No segment equals `.` or `..`
- No segment begins with `.` (blocks dotfiles and hidden directories)
- Each segment character is in `[A-Za-z0-9._-]`

This is a closed positive grammar: paths with spaces, tildes, colons, percent-encoding, or any non-listed byte are rejected. The test `"validateIncludePath accepts relative fragments"` directly demonstrates all of the above accept/reject cases.

### `bodyOfSource(source: []const u8) []const u8`

Delegates to `parser.parse(source)`. Returns `parsed.doc.body` if the parse succeeded, otherwise the entire source. The parser is allocation-free and returns source views. This function is used to strip frontmatter before recursively expanding a nested include file.

### `readSourceAlloc(io, dir, path, allocator) IncludeError![]u8`

The security-critical read function. Traverses every directory component of `path` by opening each directory segment individually with `follow_symlinks = false`. If any segment is a symlink, `openDir` fails and `IncludeMissing` is returned. The final file is opened with both `follow_symlinks = false` and `resolve_beneath = true`. Reading is bounded to `max_expanded_bytes` via `allocRemaining(.limited(max_expanded_bytes))`; `StreamTooLong` is mapped to `ExpansionBudgetExceeded`. The returned slice is heap-allocated by `allocator`; the caller is responsible for freeing it.

The `owned_dir` / `current_dir` pattern ensures intermediate directory handles are closed correctly via `defer`; the outermost dir handle `dir` is never closed by this function — ownership stays with the caller.

### `scanIncludeDirectives`

Linear scanner over `body`. Maintains a fence state machine: when a line starting at a line-start position opens a fence (3+ backticks or tildes), the scanner advances past all content until a matching or longer fence of the same character. Directives inside fences are not yielded. The scan recognises `&#123;&#123;include` only when followed immediately by ASCII space or tab; `&#123;&#123;includeX` is silently skipped. Path parsing trims leading and trailing space/tab from the bracketed content. Returns `IncludeSyntax` if the closing `&#125;&#125;` is absent or the newline intervenes, `InvalidPath` if the path fails validation.

**Fence correctness note:** The scanner tests only the fence-at-line-start condition. A `&#123;&#123;include …&#125;&#125;` directive embedded in the middle of a non-fenced line (not at line-start) is still matched. The test body includes `After &#123;&#123;include includes/b.md&#125;&#125;` which confirms mid-line directives are intentionally scanned and expanded.

### `collectTransitiveIncludes`

Dry-run walk. Uses a `stack` (cycle detection) and a `seen` set (visit deduplication) backed by `gpa`. Discovered paths are appended to `out_paths` as `gpa`-owned duplicates. The root body's locus is left empty; the `FailInfo` strings from nested failures are copied into a local `nested_fail` before the file buffer is freed, then propagated to `fail_out`.

### `expandIncludes` / `expandIncludesWithBudget` / `expandRecursive`

Two-allocator expansion engine. `gpa` owns short-lived file-read buffers, the path stack, and the `cache` map keys. `arena` owns the expanding output buffer and the cache values (expanded text slices). The separation is load-bearing: file read buffers are freed promptly via `defer gpa.free(file_bytes)` after the nested body is extracted; the cache value must outlive the current frame since it is reused across sibling directives.

`expandRecursive` maintains a `copy_from` cursor to accumulate literal text segments between directives. When a directive is encountered, `body[copy_from..start]` is appended to `out` before the expanded content, then `copy_from` is advanced past the closing `&#125;&#125;`. At the end, `body[copy_from..]` flushes any remaining literal text. `out` is arena-owned via `errdefer out.deinit(arena)` — on error the partial buffer is cleaned up, and on success `out.toOwnedSlice(arena)` hands ownership to the arena.

Budget checking occurs before the file read: `chargeExpansion` increments the counter, `chargeBytes` increments the byte accumulator using saturating subtraction (`byte_limit -| bytes`) to prevent unsigned overflow in the limit comparison. A test directly verifies that `budget.bytes <= budget.byte_limit` after termination.

### `makeDiagnostic` / `printDiagnostic` / `errorCode` / `remediationFor`

Mapping layer from `IncludeError` + `FailInfo` to the `diag.Diagnostic` struct. All string fields of the resulting `Diagnostic` are owned by `retain` (the passed allocator); no slice points into `FailInfo`'s inline buffers or any temporary. `makeDiagnostic` selects the `source_path` field as `fail.locus()` when the locus is non-empty (failure inside a nested include), otherwise uses the caller-supplied `source_path`. The test `"makeDiagnostic prefers nested locus path"` verifies this branch directly.

## Behavioral analysis by subsystem

### Path grammar (`validateIncludePath`)

The grammar is a closed positive allowlist: only segments matching `[A-Za-z0-9._-]+`, separated by `/`, with no leading `.` on any segment, and no absolute or backslash prefix. The function's loop processes the path as an array of `/`-delimited segments, detecting boundary cases by synthesising a virtual `/` at `i == path.len`. This means the last segment is also validated through the same branch — there is no off-by-one between middle and final segment handling. The test corpus is complete for the documented rule set; it does not include Unicode path characters (which are implicitly rejected by the character allowlist).

### Fence tracking in `scanIncludeDirectives` and `expandRecursive`

Both the scan and expand paths reimplement the same fence state machine independently. The machine tracks the opening fence character and minimum run length; a closing line requires the same character and a run at least as long. The `atLineStart` check guards both opening and closing recognition. Because both paths share the same logic (without factoring it into a shared function), any future bug fix would need to be applied to both. This is an observation about code structure, not a demonstrated defect.

### Two-allocator ownership in `expandIncludes`

The `gpa` / `arena` split is load-bearing:

```text
expandIncludesWithBudget
  └─ expandRecursive
       ├─ out: ArrayList(u8) [arena] — accumulates output
       ├─ stack: ArrayList([]const u8) [gpa] — cycle detection, freed on return
       ├─ cache: StringHashMap([]const u8) [gpa keys, arena values]
       │         keys duped into arena; values are prior expandRecursive results
       └─ for each directive:
            readSourceAlloc → file_bytes [gpa]
            defer gpa.free(file_bytes)
            bodyOfSource → nested_body (slice into file_bytes)
            expandRecursive(nested_body, …) → expanded [arena]
            cache.put(gpa, arena-duped key, expanded)
            out.appendSlice(arena, expanded)
```

`file_bytes` is freed immediately after `expandRecursive` returns, before the next directive. The `nested_body` slice is used only within the recursive call and never stored after `gpa.free(file_bytes)`. The cache value (`expanded`) is arena-owned and lives for the duration of the top-level call. Cache keys are duped into the arena (not into gpa) — this means cache keys are arena-owned while the cache map itself is gpa-owned. On `errdefer out.deinit(arena)`, partial output is cleaned up; the arena retains any previously cached values (they will be freed when the arena is torn down by the caller).

### FailInfo propagation

Nested failures copy their `FailInfo` into a local `nested_fail: FailInfo = .{}` before the recursive return:

```text
walkIncludes / expandRecursive
  └─ var nested_fail: FailInfo = .{};
       walkIncludes(..., &nested_fail) catch |err| {
           if (fail_out) |f| f.* = nested_fail;
           return err;
       };
```

This is necessary because the `nested_fail` copy does not hold any pointer into `file_bytes`; it copies strings into its own inline buffers. The `set` function's `copyCap` call ensures the copy is bounded and never overflows the 512-byte buffer. If a detail or locus string is longer than 512 bytes it is silently truncated — there is no error and no indication to the diagnostic consumer that truncation occurred.

### Symlink rejection

`readSourceAlloc` opens each directory segment with `follow_symlinks = false`. On POSIX, this prevents traversal through a symlinked directory component into an out-of-root location. On Windows, the test is skipped (`if (builtin.os.tag == .windows) return`). The `resolve_beneath = true` flag on the final file open adds a second guard at the OS layer for systems that support it. Whether `resolve_beneath` is a no-op on systems where the underlying syscall is not available is determined by the `std.Io` implementation, not by `include.zig` — this is uncertain from inspection of this file alone.

### Budget vs. cache interaction

The expansion cache prevents re-expanding the same file's text, but the byte budget charges for each time a cached value is *used*, not just when it is first computed. This means the budget correctly reflects the total output bytes regardless of caching. The expansion counter also charges per directive substitution, not per unique file. This is consistent with the goal of bounding output size and work done, not just file diversity.
