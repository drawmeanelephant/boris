---
title: "`src/html_body.zig` surface and execution"
id: docs/boris/src/html_body/surface-and-execution
parent: docs/boris/src/html_body
status: draft
tags: [boris, zig, source-reference, surface, html_body]
---

# `src/html_body.zig` surface and execution

## Public API

### `Options`

```zig
pub const Options = struct {
    input_format: identity.InputFormat = .markdown,
    quiet: bool = true,
    nodes: []const graph_mod.Node = &.{},
    heading_index: ?*const wikilink.HeadingIndex = null,
    page_assets: ?*const content_asset.PageAssetBundle = null,
};
```

The configuration struct parameterises the pipeline. Defaults are conservative: Markdown input, quiet mode (no diagnostic printing to stderr), empty node table, no heading index, and no asset bundle. All optional pointers must remain valid for the duration of `renderSource`; the module does not copy them.

### `bodyForInput`

```zig
pub fn bodyForInput(
    allocator: std.mem.Allocator,
    input_format: identity.InputFormat,
    source: []const u8,
    body: []const u8,
    body_offset: usize,
    source_path: []const u8,
    quiet: bool,
) ![]const u8
```

Handles the optional Textile → Markdown adaptation step. If `input_format == .markdown` it returns `body` unchanged (no copy, zero allocation). For `.textile` input it calls `textile.toMarkdown(body, allocator)` and returns the adapted Markdown slice allocated into `allocator`. On Textile parse failure it optionally prints a diagnostic and returns `error.TextileFailed`. The returned slice is arena-owned; the caller must not free it separately.

### `renderSource`

```zig
pub fn renderSource(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    doc_arena: *std.heap.ArenaAllocator,
    source: []const u8,
    source_path: []const u8,
    output_path: []const u8,
    options: Options,
) ![]const u8
```

The primary entry point. Executes the full ordered pipeline and returns the HTML body as a `[]const u8` slice owned by `doc_arena`. The caller must keep `doc_arena` alive until the slice has been fully consumed. Errors are returned as typed error values; the function never panics on well-formed inputs. The `gpa` parameter is used for temporary allocations that must outlive individual pipeline steps but not the document (e.g., diagnostic message formatting); the `arena` is used for all output slices.

***

## Pipeline ordering contract

The module comment states and the code enforces this exact ordering:

```text
1. parser.parse(source)            — frontmatter + body extraction
2. bodyForInput(...)               — optional Textile → Markdown
3. include_mod.expandIncludes(...)  — {{include ...}} expansion (reads disk)
4. wikilink.rewriteWikiLinksOpts(...)  — [[wiki-link]] → href rewrite
5. content_asset.rewriteImageLinks(...)  — Markdown image URL rewrite (conditional on page_assets)
6. aside.tokenizeBody(...)          — split body into .markdown / .aside / .details segments
7. for each segment:
     .markdown → apex.render(md, doc_arena)
     .aside    → aside.renderHtml(component, doc_arena)
     .details  → aside.renderDetailsHtml(component, doc_arena)
   → append to html_buf
```

This ordering is contractual, not incidental. Include expansion must precede wiki-link rewriting so included fragments can contain wiki links. Asset rewriting must precede Aside tokenization so image URLs in Markdown segments are rewritten before the body is split. Aside tokenization must precede Apex so that `&lt;Aside>` markup is never passed to the C engine.

A notable detail: whitespace-only Markdown segments are skipped before calling `apex.render` (`if (std.mem.trim(u8, md, ...).len == 0) continue`). This avoids a zero-content call to the C engine but also means the C engine is never asked to render purely-whitespace input within a larger body.

***

## Allocator and lifetime model

The module uses two allocators with distinct roles:

- **`arena` (from `doc_arena.allocator()`)**: All output slices — expanded body after include, wiki-rewritten body, asset-rewritten body, tokenized segments, and the final `html_buf.items` — are allocated into the arena. The arena is the Whiteboard; its lifetime is the page document. `renderSource` returns a view of `html_buf.items`, which is arena-allocated. Callers must not use this slice after `doc_arena.reset(.free_all)` or `doc_arena.deinit()`.
- **`gpa`**: Used for transient allocations whose lifetimes cross sub-call boundaries but are not returned as output: diagnostic message strings (formatted with `std.fmt.allocPrint` and freed with `gpa.free` via `defer`), `include_fail`, `wiki_fail`, `asset_fail` locals. The module uses `defer gpa.free(...)` consistently for these.

The `html_buf` accumulator is declared as `std.ArrayList(u8)` with `.empty` but its underlying storage is allocated via `html_buf.appendSlice(arena, h.bytes)`. This is `std.ArrayList`'s arena-backed append path; the list's storage lives in the arena, not in a GPA-owned heap segment. A consequence is that `html_buf.deinit` is never called — the arena owns the memory.

***

## Private helpers

### `sourceLineAt`

Counts newlines in `source[0..@min(offset, source.len)]` to map a byte offset to a 1-based line number. Used by `componentDiagnostic` and `bodyForInput` to compute source-locus line numbers that are relative to the full original source file (not the body-only slice). This is important because `body_offset` is the byte offset of the body within the full source, and component/Textile diagnostics report line numbers relative to the body; `sourceLineAt(source, body_offset) + diagnostic.line - 1` reconstructs the full-file line.

### `componentDiagnostic`

Constructs a `diag.Diagnostic` from an `aside.Diagnostic`. Allocates the `message` field with `gpa` (caller must free). Computes the full-file line number using `sourceLineAt`. Sets `code = .ECOMPONENT` and a fixed remediation string.

### `printComponentDiagnostics`

Iterates `aside.Diagnostic` slices, calls `componentDiagnostic` for each, then calls `diag.formatText` and prints to `std.debug.print`. Both the message and formatted text strings are freed with `defer gpa.free(...)`. Only called when `!options.quiet`.

### `writeTestFile`

A test-only helper that writes a file at a relative path under a given root directory. Uses `std.testing.allocator` for path construction. Not exported; visible only within the module's test declarations. Requires `Io` because it uses `Io.Dir` and `createFile`/`writeStreamingAll`.

***

## Error paths

`renderSource` returns typed errors for each stage failure:


| Error | Source | Condition |
| :-- | :-- | :-- |
| `error.ParseFailed` | `parser.parse` | `parsed.diagnostic != null` |
| `error.TextileFailed` | `bodyForInput` | `textile.toMarkdown` returns a diagnostic |
| `error.IncludeFailed` | `include_mod.expandIncludes` | Any error from include expansion |
| `error.ReferenceFailed` | `wikilink.rewriteWikiLinksOpts` | Any error from wiki-link rewriting |
| `error.AssetFailed` | `content_asset.rewriteImageLinks` | Any error from image URL rewriting (only when `page_assets != null`) |
| `error.ComponentFailed` | `aside.tokenizeBody` | `tok.hasErrors()` returns true |
| `error.OutOfMemory` | `apex.render` or any arena alloc | OOM from arena or C engine |
| `error.RenderFailed` | `apex.render` | C engine returns non-OOM error status |

None of these error paths are tested by the two inline tests. The error-path coverage depends on tests in `compile.zig`, `hardening_test.zig`, and `pipeline.zig` that call `renderSource` with inputs designed to trigger each stage.

***

## Relationship to `compile.zig`

The module header states that `renderSource` "deliberately stops at the page body" and that "layout slots, staging and publication remain owned by `compile.zig`." The caller is expected to:

1. Supply a live `doc_arena` (Whiteboard) that it controls.
2. Consume the returned `[]const u8` before calling `doc_arena.reset(.free_all)`.
3. Not free the returned slice directly.

`compile.zig` owns the broader page lifecycle: it builds the `Options` struct from per-document metadata, calls `renderSource`, then passes the result to the assembler. The `html_body.zig` module has no knowledge of layout templates, page titles, navigation, or output file paths (beyond what is needed for asset rewriting).

***
