---
title: "`src/export_scope.zig` surface and execution"
id: docs/boris/src/export_scope/surface-and-execution
parent: docs/boris/src/export_scope
status: draft
tags: [boris, zig, source-reference, surface, export_scope]
---

# `src/export_scope.zig` surface and execution

## Public API

### `pub const Error`

```zig
pub const Error = error{ InvalidScope, OversizedBlock };
```

The only two error values the module surfaces. Both are propagated to callers without wrapping.

### `pub fn selectPages`

```zig
pub fn selectPages(
    allocator: std.mem.Allocator,
    pages: []const graph.Node,
    scope: ?[]const u8,
) ![]const graph.Node
```

Returns a caller-owned slice of `graph.Node` values from `pages` that satisfy the scope closure. When `scope` is `null`, all pages are included (returns a copy of the full slice). When `scope` is non-null, the three-phase closure is applied. Allocation is via `allocator`; the returned slice must be freed by the caller. The nodes themselves are not copied; the returned slice contains views into the original `pages` memory.

**Phase 1 — Seed selection:** A page is seeded if its `.id` exactly equals `scope`, or if `.id` starts with `scope` followed by `/` (prefix match for a collection). A scope that matches no page returns `error.InvalidScope`.

**Phase 2 — Semantic neighbor expansion:** For each seeded page, every page whose `.id` appears in any `semanticRelations[*].target` field is added to the included set (one hop only; not transitive).

**Phase 3 — Structural parent closure:** Runs after Phase 2. For every included page, if it has a `.parent`, the parent is included. This step repeats until no new pages are added (`changed = false`). The parent closure is therefore transitive: if A is included and A's parent is B and B's parent is C, then both B and C are included.

**Scope validation:** The scope string is rejected with `error.InvalidScope` if it is empty, begins with `.`, contains `..`, or contains `/`. This prevents path-traversal patterns and empty selectors from entering the projection.

**Ordering:** Pages are appended to `selected` in the order they appear in the input `pages` slice. The input slice is the pipeline's frozen, deterministically-ordered graph. Output ordering therefore reflects pipeline ordering, not scope insertion order.

### `pub fn partitionMarkdown`

```zig
pub fn partitionMarkdown(
    allocator: std.mem.Allocator,
    body: []const u8,
    max_body: usize,
) ![]const []const u8
```

Returns a caller-owned slice of string slices, each a sub-slice of `body` (no copying of body bytes). Each sub-slice is at most `max_body` bytes. If `body.len <= max_body`, returns a single-element slice containing the full body. If `max_body == 0`, returns `error.OversizedBlock`. Splits only at blank lines or ATX heading lines (lines whose trimmed form starts with `#`) that fall outside an open fenced code block.

**Fence tracking:** A line is a fence line if its leading whitespace is stripped and the first three characters are all ````` or all `~`. The opening fence records its character (````` or `~`) and its length. The fence is considered closed when a subsequent line uses the same character and a length ≥ the opening length. While inside a fence (`fenceChar != 0`), no split boundary is recorded.

**Split boundary selection:** The function scans forward from `cursor` up to `start + max_body`. For each line that is not inside a fence, if the line is blank (`trim(line).len == 0`) or is a heading (`trimStart(line)` starts with `#`), it records `lastBoundary`. For blank lines, `lastBoundary` is set to `lineEnd` (the position after the newline, consuming the blank line). For heading lines, `lastBoundary` is set to `cursor` (the heading begins the next piece).

**Failure modes:**

- `error.OversizedBlock` if the scan reaches the window limit without finding any safe boundary.
- `error.OversizedBlock` if the found boundary equals `start` (no progress possible).

The returned slices are views into `body`. The caller must keep `body` live for the duration of use, and must free only the outer slice (not the inner slices, which point into caller-owned memory).

***

## Fence-tracking state machine

The `isFenceLine` and `fenceLine` helpers are private to `partitionMarkdown`. Their behavior:

```text
isFenceLine(line):
    trimmed = trimStart(line, " \t")
    if trimmed.len < 3: false
    true iff trimmed[0..3] all '`' OR all '~'

fenceLine(line) -> ?{ char, length }:
    trimmed = trimStart(line, " \t")
    if trimmed.len < 3 OR trimmed not in {'`','~'}: null
    char = trimmed
    length = count of leading char
    if length < 3: null
    return { char, length }
```

State in `partitionMarkdown`:

- `fenceChar: u8 = 0` — 0 means "not inside a fence"
- `fenceLength: usize = 0`

On each line:

```text
if fenceLine(line) is fence:
    if fenceChar == 0:          # opening a fence
        fenceChar = fence.char
        fenceLength = fence.length
    else if fence.char == fenceChar AND fence.length >= fenceLength:
        fenceChar = 0           # closing the fence
        fenceLength = 0
    # else: interior fence-like line, ignored
```

Split boundary logic only executes when `fenceChar == 0`. This means a blank line or heading inside a fenced block is invisible to the splitter.

**Gap:** The fence-close condition uses `>=` for length, matching CommonMark semantics (a closing fence need not be the same length, only at least as long). However, the file does not claim CommonMark conformance, and no test exercises a mismatched-length close. This is a documented uncertainty.

***

## Allocation and ownership

| Object | Allocated by | Freed by |
| :-- | :-- | :-- |
| `included: []bool` (selectPages) | `allocator` | `defer allocator.free(included)` inside `selectPages` |
| `selectedSeed: []bool` (selectPages) | `allocator` | `defer allocator.free(selectedSeed)` inside `selectPages` |
| `selected: ArrayList(graph.Node)` (selectPages) | `allocator` | `errdefer selected.deinit(allocator)`, converted via `toOwnedSlice` |
| Returned `[]graph.Node` | `allocator` | Caller |
| `parts: ArrayList([]const u8)` (partitionMarkdown) | `allocator` | `errdefer parts.deinit(allocator)`, converted via `toOwnedSlice` |
| Returned `[][]const u8` | `allocator` | Caller (outer slice only; inner slices are views into `body`) |

The module never retains state between calls. There is no global state, no module-level allocator, and no persistent cache. Each call is self-contained.

***

## What the module cannot validate

1. **That `pages` is cycle-free.** `selectPages` performs a transitive parent-chain walk with a `changed`-flag termination loop. If the upstream pipeline were to provide a cyclic parent chain, this loop would not terminate. The implementation trusts that `pipeline.compile` has already validated the graph for cycles before any export path reaches this function. This trust is **contract-based**, not mechanically enforced within this file.
2. **That `semanticRelations[*].target` values refer to existing pages.** `selectPages` performs a string equality scan over the full `pages` slice for each relation target. If a target id is dangling (referencing a page not in `pages`), it is simply not found and no error is raised. The pipeline is assumed to have either validated or documented this condition upstream.
3. **That the fence-close detection is fully CommonMark-correct.** The detector does not handle indented fences, info strings, or the HTML block rules. It is an approximation sufficient for the Boris body format, not a general Markdown fence parser.
4. **That `partitionMarkdown` produces a minimum number of parts.** The greedy left-to-right scan finds the latest safe boundary within each window. This is locally optimal but not globally minimal. No test verifies minimality.

***
