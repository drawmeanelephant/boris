---
title: "`src/llms.zig` surface and execution"
id: docs/boris/src/llms/surface-and-execution
parent: docs/boris/src/llms
status: draft
tags: [boris, zig, source-reference, surface, llms]
---

# `src/llms.zig` surface and execution

## Public API surface

### `pub const format: []const u8 = "llms.txt"`

A string constant identifying the export format. Intended for use by callers (e.g., `src/main.zig`) that need to name the output or display progress.

### `pub const Options`

```zig
pub const Options = struct {
    content_root: []const u8 = "content",
    out_path: []const u8 = "llms.txt",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
};
```

All fields have defaults. `content_root` and `out_path` must be relative paths; `run` returns `error.AbsolutePath` if either is absolute. `input_format` is passed through to `pipeline.compile` and controls how the scanner classifies source files.

### `pub const Result`

```zig
pub const Result = struct {
    compile: pipeline.Result,
    published: bool = false,

    pub fn deinit(self: *Result) void { self.compile.deinit(); }
    pub fn ok(self: *const Result) bool { return self.compile.ok and self.published; }
};
```

Ownership of the compilation arena is transferred into `Result.compile`. Callers must call `result.deinit()` to free it. `published` is set only after the staged write succeeds; if pipeline compilation fails, the function returns early with `published = false` and `compile.ok = false`. The caller can distinguish "pipeline error" from "write error" by inspecting both fields.

### `pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !Result`

The sole public entry point. Returns `error.AbsolutePath` immediately if either path is absolute. On pipeline failure (`!result.compile.ok`), returns early with a valid `Result` (caller must still call `deinit`). On success, `Result.published == true`.

***

## Internal functions

### `log`

```zig
fn log(opts: Options, comptime fmt: []const u8, args: anytype) void
```

Thin conditional wrapper around `std.debug.print`. Suppressed when `opts.quiet == true`. Used only for the single completion message at the end of `run`.

### `readFileAlloc`

```zig
fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8
```

Opens a file under `dir`, reads it completely into a caller-supplied allocator, and closes the file handle. The `allocator` argument is `arena` (the pipeline result's arena allocator), so the returned slice is owned by the arena and does not need individual freeing. The function uses `reader.interface.allocRemaining(allocator, .unlimited)`, meaning there is no size cap on individual source files.

### `ensureParent`

```zig
fn ensureParent(io: Io, path: []const u8) !void
```

Creates parent directories for a given path using `Io.Dir.cwd().createDirPath`. Called by `publish` before staging the output file. Errors from `createDirPath` propagate to the caller; no special handling for already-existing directories is documented in the function body (the underlying `createDirPath` is expected to be idempotent or `createDirPath` is used in a way that tolerates existence — this is assumed of the `std.Io` API, not structurally verified here).

### `appendInline`

```zig
fn appendInline(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void
```

Appends a string to `buf` with inline escaping for `llms.txt` output. Behavior per character:

- `\`, `[`, `]`, `(`, `)` → prepend `\` (backslash escape for Markdown link syntax)
- `\n`, `\r`, `\t` → replaced with a single space (newline/tab normalization)
- All other bytes → passed through unchanged

This function is used for both page titles and summary text. The escaping is manual and character-by-character. It handles the five characters that have structural meaning in `[text](url)` Markdown link syntax, and it collapses whitespace control characters. Multi-byte UTF-8 sequences pass through byte-by-byte without interpretation; this is safe for output-only purposes since the byte stream remains valid UTF-8, but no normalization of multi-byte whitespace (e.g., U+00A0 non-breaking space) is performed.

### `pageTitle`

```zig
fn pageTitle(page: graph.Node) []const u8
```

Returns `page.title` if non-null, otherwise falls back to `page.id`. This is the only place in the module where the `title` field of `graph.Node` is read.

### `summary`

```zig
fn summary(gpa: std.mem.Allocator, source: []const u8, fallback: []const u8) ![]u8
```

Extracts a plain-text summary of up to 240 bytes from a raw Markdown source string. The algorithm:

1. Strips the frontmatter block if the source begins with `---\n` — finds the closing `---\n` and uses only the text after it. If no closing delimiter is found, uses the entire source.
2. Scans lines sequentially; skips blank lines before text is seen, and stops at the first blank line after text has been seen (paragraph boundary).
3. Skips lines beginning with `#` (ATX headings).
4. Accumulates non-blank, non-heading lines into a buffer, joining them with spaces.
5. Truncates at 240 bytes if exceeded, stopping only at a valid UTF-8 scalar boundary so a multibyte character is never split.
6. If no text was found, returns a `gpa.dupe` of `fallback`.

The function allocates its output on `gpa`. Callers are responsible for freeing it (`defer gpa.free(text)` is used in `renderPage`). The frontmatter strip is a simple `std.mem.indexOfPos` scan — it does not validate YAML structure, interpret the frontmatter, or handle edge cases such as `---\r\n` line endings.

**Test coverage (directly demonstrated):** Inline tests exercise this function against: a document with frontmatter + heading + paragraph (expected: paragraph text), a document with frontmatter + heading only (expected: fallback string), exact 240-byte and 241-byte paragraphs that end or cross a UTF-8 scalar boundary (an em dash and a four-byte emoji), and a paragraph already below the limit preserved byte-for-byte. `utf8TruncateLen` returns the longest valid UTF-8 prefix no longer than the requested byte limit.

### `appendUrl`

```zig
fn appendUrl(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, id: []const u8) !void
```

Appends a URL of the form `/<id>/` to `buf`. The ID portion is passed through `appendInline`, inheriting its escaping rules. The module comment notes the intent: "Keep the URL fallback deterministic and independent of host deployment." No base URL or configurable prefix is supported; all URLs are root-relative.

### `findChildren`

```zig
fn findChildren(pages: []const graph.Node, parent: []const u8, visited: []const bool, out: *std.ArrayList(usize), gpa: std.mem.Allocator) !void
```

Performs a linear scan over `pages` to collect unvisited nodes whose `page.parent` equals `parent` (by byte-exact string equality). Appends matching indices to `out`. This is O(n) per call; `renderPage` calls it once per visited node, making the overall render O(n²) in the number of pages. This is structurally acceptable for documentation sites with typical page counts; no profiling-backed optimization exists in the current code.

### `renderPage`

```zig
fn renderPage(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), pages: []const graph.Node, sources: []const []const u8, visited: []bool, index: usize, depth: usize) !void
```

Renders one page and its children recursively. Guards against revisiting via `visited[index]`. Sets `visited[index] = true` on entry. Renders the page as `  - [<title>](<url>): <summary>\n` (indented by `depth * 2` spaces). Then collects children via `findChildren` and recurses. Because `findChildren` respects the `visited` flag, cycles cannot produce infinite recursion even if the graph were malformed; a cycle-participating node would be marked visited on first encounter and skipped on subsequent ones. However, the `visited` guard alone does not prove the output is correct for malformed graphs — only that the render terminates.

`depth` controls indentation only; there is no maximum depth guard. In a pathological deep chain (which `graph.zig`'s `EPARENTNOTTRUNK` check is meant to prevent in v0.1), this function would recurse proportionally to chain length. The stack depth is bounded in practice by the v0.1 graph constraint (max depth 2: trunk → satellite), which is enforced at validation time rather than here.

### `render`

```zig
fn render(gpa: std.mem.Allocator, result: *pipeline.Result, sources: []const []const u8) ![]u8
```

Assembles the full `llms.txt` document. Emits a fixed header:

```
# Boris documentation

> This file is generated by Boris from a validated Trunk/Satellite content graph.

## Documentation

```

Then performs two passes over `result.pages.items`:

1. First pass: renders all root pages (`page.parent == null`) and their subtrees using `renderPage`.
2. Second pass (fallback): renders any pages not yet visited by the first pass. The comment explains: "Validated graphs should make this unnecessary, but keeping an explicit fallback makes the exporter total if a future graph role is introduced."

The second pass is defensive. In a correctly validated graph it should be a no-op. The behavior ensures that even if a future graph type introduces nodes that are not reachable from root pages, they will still appear in the output rather than being silently omitted.

The returned `[]u8` is owned by `gpa`; `run` frees it with `defer gpa.free(output)` before the function returns.

### `publish`

```zig
fn publish(io: Io, gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void
```

Writes `data` to `path` using a staged rename sequence:

```text
delete <path>.boris-llms-stage (ignore error)
delete <path>.boris-llms-prev  (ignore error)
ensureParent(<path>.boris-llms-stage)
write data → <path>.boris-llms-stage
```

rename <path> → <path>.boris-llms-prev  (ignore error if path doesn't exist)

```
```

rename <path>.boris-llms-stage → <path>

```
    ```
    on failure: rename <path>.boris-llms-prev → <path>  (restore)
    ```
delete <path>.boris-llms-prev (ignore error)
```

This is a best-effort atomic replacement: it avoids a partial-write window on the final output path by staging to a side file first. The restore step (rename `prev` back to `path` on failure of the final rename) provides a rollback for the common case where the final rename fails. Limitations:

- Atomicity is not guaranteed across all OS/filesystem combinations; `rename` is atomic on POSIX but not necessarily on all platforms.
- If the process is interrupted after the first rename (path → prev) but before the second rename (stage → path), the output file is temporarily absent. The `.boris-llms-prev` file can be recovered manually.
- Both stage and prev files use `gpa`-allocated path strings freed via `defer`.

***

## Allocation and ownership

| Resource | Owner | Lifetime |
| :-- | :-- | :-- |
| `Result.compile` (arena + pages) | Caller (via `result.deinit()`) | Until caller calls `deinit` |
| `sources` slice of `[]const u8` | Arena allocator (from `result.compile`) | Until `result.deinit()` |
| Per-page source text (`readFileAlloc`) | Arena allocator | Until `result.deinit()` |
| `output` buffer from `render` | `gpa`; freed by `defer gpa.free(output)` inside `run` | Function scope of `run` |
| `stage` and `previous` path strings | `gpa`; freed by `defer` inside `publish` | Function scope of `publish` |
| `summary` return value in `renderPage` | `gpa`; freed by `defer gpa.free(text)` | Block scope in `renderPage` |

The `sources` slice itself is allocated from `gpa` inside `run` (not the arena) and freed by `defer gpa.free(sources)`. The individual `[]const u8` elements it points to are arena-allocated. This is a mixed-ownership pattern: the spine of `sources` has a shorter, `gpa`-tied lifetime, while the contents have the longer arena lifetime. This is safe because `sources` is consumed entirely within `run` before `result.deinit()` could be called.

***
