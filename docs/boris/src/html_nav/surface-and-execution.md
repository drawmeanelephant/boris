---
title: "`src/html_nav.zig` surface and execution"
id: docs/boris/src/html_nav/surface-and-execution
parent: docs/boris/src/html_nav
status: draft
tags: [boris, zig, source-reference, surface, html_nav]
---

# `src/html_nav.zig` surface and execution

## Public API surface

### `appendEscaped`

```zig
pub fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void
```

Appends `text` to `buf`, replacing `&`, `<`, `>`, and `"` with their HTML entity equivalents (`&amp;`, `&lt;`, `&gt;`, `&quot;`). All other bytes are appended verbatim. The function is character-by-character; it does not batch writes. It is used internally by all render functions at every point where user-controlled content (title text, href values) is written into the output buffer.

**Note:** The escaping policy covers the four characters necessary to prevent HTML injection in element text content and attribute values delimited by `"`. It does not cover `'` (single-quote attribute delimiters are not used by this file's output), nor does it handle non-UTF-8 byte sequences in any special way — bytes are passed through one at a time regardless of encoding validity.

### `siteNavMaterial`

```zig
pub fn siteNavMaterial(allocator: std.mem.Allocator, nodes: []const graph_mod.Node) ![]u8
```

Serializes the frozen node array into a null-byte–delimited fingerprint buffer of `id\0title\0parent\0role\n` records, one per node in frozen (id-sorted) order. Returns a caller-owned, allocator-allocated slice. The `errdefer buf.deinit(allocator)` guard ensures no leak on partial failure.

This function's stability guarantee depends entirely on the stability of the `nodes` order, which `graph.freeze` provides by sorting by id before returning. The output is therefore deterministic for a given input set.

### `renderNav`

```zig
pub fn renderNav(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8
```

Renders the full site-nav forest as a `<nav class="site-nav" aria-label="Site">` element with a flat `<ul>`. Only nodes with `parent == null` (Trunks) appear at the top level. For each Trunk, direct children (from `nav[i].children`) are rendered as a nested `<ul>` of `<li class="site-nav__satellite">` items. The `is-current` CSS class and `aria-current="page"` attribute are applied to whichever `<li>` and `<a>` corresponds to `current_index`. All hrefs are relative, computed via `identity.relativeHref`. Title text and href values are both escaped via `appendEscaped`. Intermediate allocations (per-node `out_path` and `href` strings) are individually freed with `defer` before the function returns.

**Precondition not enforced in code:** The function iterates `nodes` by index position and checks `node.parent != null` to identify Trunks. It does not verify that the passed `nodes` slice is the frozen, id-sorted output of `graph.freeze`. Passing a pre-freeze or re-ordered slice is undefined behavior with respect to correctness (not memory safety, in safe build modes).

**Child index safety:** Children are stored in `nav[i].children` as `u32` node indices. The function indexes into `nodes[ci]` without a redundant bounds check in the Zig source; safe-mode Zig will trap an out-of-bounds child index at runtime. In `ReleaseFast` or `ReleaseSmall` modes, an out-of-bounds `ci` would cause undefined behavior.

### `renderChildren`

```zig
pub fn renderChildren(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8
```

Renders a `<nav class="page-children" aria-label="Children">` element listing the direct children of the current node. Returns the empty string literal `""` (not an allocated string) when `nav[current_index].children` is empty — callers must not `allocator.free` this return value without checking. The function explicitly documents that Satellites have no children in the Boris one-level Trunk/Satellite model, so their fragment is always empty.

**Ownership subtlety:** The empty-children early return is `return "";` — a pointer to a compile-time string literal, not a heap allocation. The non-empty path returns `try buf.toOwnedSlice(allocator)` — a heap allocation. Callers that unconditionally `defer allocator.free(result)` will double-free or misuse the literal pointer in the empty case. The test `"renderChildren is id-sorted, escaped, relative, and empty for satellite"` calls `renderChildren` for the satellite case and does not `defer gpa.free` the empty result, which is correct, but this asymmetry is not documented in the function signature.

### `renderBreadcrumb`

```zig
pub fn renderBreadcrumb(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8
```

Renders the root-to-self ancestor chain as a `<nav class="breadcrumb" aria-label="Breadcrumb"><ol>` element. The last crumb item (self) is rendered as `<li aria-current="page">escaped-title</li>` without an anchor; all prior items are rendered as linked `<li>` elements. The breadcrumb indices come from `nav[current_index].breadcrumb`, which `graph.buildNav` builds by walking `parent_index` chains from self to root and reversing.

### `renderTitle`

```zig
pub fn renderTitle(allocator: std.mem.Allocator, node: graph_mod.Node) ![]u8
```

Returns the HTML-escaped display title for a single node, using `node.title` if present, falling back to `node.id`. Always returns a heap allocation (even if the content is empty, `toOwnedSlice` on an empty `ArrayList` returns a zero-length allocated slice).

***

## Internal helpers

### `displayTitle`

```zig
fn displayTitle(node: graph_mod.Node) []const u8
```

Returns `node.title orelse node.id`. Private to the module. Called at every point where a human-readable label is needed; ensures the id-fallback behavior is not reimplemented inconsistently across render functions.

### `outputPathFor`

```zig
fn outputPathFor(allocator: std.mem.Allocator, node: graph_mod.Node) ![]u8
```

Returns `"{node.id}.html"` as a freshly allocated string. Called immediately before each `relativeHref` invocation and freed with `defer` in the same scope. Reproduces the `id + ".html"` convention locally; this is the same derivation as `identity.safeOutputRelativePath` but without that function's entity-id validation gate. If a `node.id` somehow bypassed `graph.validate` and contained path-traversal characters, `outputPathFor` would emit them without rejection.

***

## Allocation and ownership model

Every public render function follows the same pattern:

1. `var buf: std.ArrayList(u8) = .empty;` — empty, no initial capacity allocated.
2. `errdefer buf.deinit(allocator);` — releases the buffer on any error path before ownership transfer.
3. Intermediate per-node strings (`out_path`, `href`) are individually allocated and freed with `defer allocator.free(...)` within the loop iteration.
4. `return try buf.toOwnedSlice(allocator);` — transfers ownership of the grown buffer to the caller. After this point the `ArrayList` is empty and the `errdefer` is a no-op.

Callers receive a `[]u8` that must be freed with the same allocator. The one exception is `renderChildren` when the children list is empty: it returns the compile-time string literal `""`, which must not be freed. This is a known ownership asymmetry in the API that is not reflected in the return type or documented in the function signature.

`siteNavMaterial` follows the same `errdefer buf.deinit` + `toOwnedSlice` pattern and is always heap-allocated.

***

## Precision of relative href computation

The relative href calculation is fully delegated to `identity.relativeHref`. That function:

- Splits both paths into directory components using `/` as the sole separator
- Finds the longest common directory prefix
- Prepends one `../` per remaining source directory component
- Appends remaining target directory components and the target basename

The `relativeHref` function uses a fixed `[^1_32][]const u8` stack array for path components. Paths with more than 32 directory levels would silently truncate in `splitPathComponents`. Boris's practical content depth is one or two levels (Trunk / Satellite), so this limit is not currently a risk, but it is not enforced or documented at the call site in `html_nav.zig`.

***
