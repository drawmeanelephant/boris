//! Boris's single Markdown → HTML rendering seam.
//!
//! Production Markdown rendering is delegated to the **Oliver** library
//! (pinned in `build.zig.zon`), consumed natively as a Zig module — never a
//! subprocess, never a shell-out to a provisional CLI. This module is the only
//! place Boris touches Oliver's API, so a future Oliver upgrade has exactly one
//! seam to review (see `docs/contracts/oliver-renderer.md` for the pin and
//! upgrade procedure).
//!
//! ## Boundary
//!
//! Boris owns everything outside this seam — filesystem discovery, frontmatter,
//! include expansion, wiki-link rewriting, Aside tokenization, graph semantics,
//! layout/template assembly, publication paths, and evidence. Oliver owns
//! source bytes → typed document → deterministic HTML. This module is the
//! adapter between the two.
//!
//! ## Output contract
//!
//! - Heading auto-ids (`heading_ids`) so wiki fragments and `{{toc}}` anchors
//!   resolve against the rendered body (`docs/contracts/heading-ids.md`). The
//!   slug rule matches the previous renderer's observed behavior: ASCII
//!   lowercase, punctuation/non-ASCII dropped, whitespace runs → `-`, duplicate
//!   headings share the same id (no `-1`/`-2` suffix).
//! - Footnotes (`footnotes` parse + render options) and heading attribute lists
//!   (`heading_attributes`) and definition lists (`definition_lists`) match the
//!   constructs Boris actually publishes (see
//!   `docs/contracts/oliver-renderer.md`).
//!
//! ## Memory model
//!
//! Input `md` is a slice into Whiteboard arena memory; Oliver borrows it (text
//! nodes slice into it) and the document outlives the render call. Oliver's
//! parse and render allocate through the same Whiteboard arena, so the returned
//! `Html.bytes` view stays valid until the caller's `arena.reset(.free_all)` —
//! the identical lifetime contract the previous renderer's `Html` had.
//!
//! ## Concurrency
//!
//! Oliver is a pure library with no global state, no hidden caches, and no
//! clock/network/filesystem access; simultaneous renders on different arenas
//! are safe. No process-global mutex is needed (the previous C engine required
//! one — see `docs/contracts/parallel-rendering.md`).
//!
//! ## Diagnostics
//!
//! Oliver reports input-size violations as `error.InputTooLarge` before any
//! markup interpretation. All other failures are `OutOfMemory` or a diagnostic
//! on the document (Boris surfaces those through its own diagnostic pipeline).

const std = @import("std");
const oliver = @import("oliver");

/// Failures surfaced by the rendering seam. Boris callers map these onto
/// their own error/diagnostic paths (typically render → publication failure).
pub const RenderError = error{
    OutOfMemory,
    /// Input exceeds Oliver's documented `max_input_len` bound.
    InputTooLarge,
    /// The output writer failed (surfaced by Oliver's renderer).
    WriteFailed,
    /// The output writer ran out of space.
    NoSpaceLeft,
};

/// Zig-side view of rendered HTML.
///
/// **Borrowed lifetime:** `bytes` is a view of Whiteboard (arena) memory
/// produced by `render`. Valid only until the arena is reset or deinitialized.
/// Do not free these bytes individually.
pub const Html = struct {
    bytes: []const u8,
};

/// Bounded stress size for large-input tests (keeps CI bounded). Mirrors the
/// value the previous renderer's fuzz harness used.
pub const test_large_md_bytes: usize = 64 * 1024;

/// Oliver's Markdown dialect options — the exact set Boris publishes with.
/// All are off by default in Oliver; Boris opts in deliberately.
const markdown_options = oliver.MarkdownOptions{
    .footnotes = true,
    .definition_lists = true,
    .heading_attributes = true,
};

/// Oliver's render options — heading auto-ids and the footnotes section.
const render_options = oliver.html.RenderOptions{
    .heading_ids = true,
    .footnotes = true,
};

/// Render a markdown payload to HTML through Oliver into the Whiteboard arena.
///
/// `arena` owns all produced bytes; the returned `Html.bytes` slice is a view
/// into it and must be consumed before `arena.reset(.free_all)`.
pub fn render(md: []const u8, arena: *std.heap.ArenaAllocator) RenderError!Html {
    const a = arena.allocator();

    var result = try oliver.parse(a, md, .markdown, .{ .markdown = markdown_options });
    defer result.deinit();

    var aw = std.Io.Writer.Allocating.init(a);
    errdefer aw.deinit();
    try oliver.html.render(a, &aw.writer, &result.document, render_options);
    // The buffer was allocated through the Whiteboard arena; handing it to the
    // caller as a view keeps the same lifetime contract as the previous
    // renderer's Html (valid until arena reset, no individual free).
    const list = aw.toArrayList();
    return .{ .bytes = list.items };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Renders and calls `f` with the arena-backed HTML view. The arena stays
/// alive for the duration of `f` — the seam contract is that `Html.bytes` is
/// valid only until the arena is reset or deinitialized.
fn withRender(md: []const u8, f: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const html = try render(md, &arena);
    try f(html.bytes);
}

test "render: ordinary markdown through Oliver" {
    try withRender("# Home\n\nHello **world**.\n", struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"home\">Home</h1>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<p>Hello <strong>world</strong>.</p>") != null);
        }
    }.run);
}

test "render: exact body bytes match the compile golden pin" {
    // src/compile.zig pins `L<h1 id="alpha">Alpha</h1>\n` for `# Alpha\n`.
    try withRender("# Alpha\n", struct {
        fn run(html: []const u8) !void {
            try testing.expectEqualStrings("<h1 id=\"alpha\">Alpha</h1>\n", html);
        }
    }.run);
}

test "render: heading auto-ids follow the observed contract" {
    try withRender(
        \\# Hello, World!
        \\
        \\## Café résumé
        \\
        \\### Code `span` here
        \\
    , struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"hello-world\">Hello, World!</h1>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"caf-rsum\">Café résumé</h2>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<h3 id=\"code-span-here\">Code <code>span</code> here</h3>") != null);
        }
    }.run);
}

test "render: duplicate headings share the same id (no -1 suffix)" {
    try withRender(
        \\## Dup
        \\
        \\## Dup
        \\
    , struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"dup\">Dup</h2>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"dup-1\">") == null);
        }
    }.run);
}

test "render: heading IAL id wins over the auto slug" {
    try withRender("## Exit codes {#exit-codes}\n", struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"exit-codes\">Exit codes</h2>") != null);
        }
    }.run);
}

test "render: footnotes render with refs and a back-ref section" {
    try withRender(
        \\Hi[^1].
        \\
        \\[^1]: note body
        \\
    , struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<sup class=\"footnote-ref\">") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<section class=\"footnotes\" data-footnotes>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "note body") != null);
        }
    }.run);
}

test "render: definition lists render as dl/dt/dd" {
    try withRender(
        \\Term
        \\: Definition
        \\
    , struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<dl>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<dt>Term</dt>") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<dd>Definition</dd>") != null);
        }
    }.run);
}

test "render: GFM tables render as tables" {
    try withRender(
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
    , struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<table") != null);
            try testing.expect(std.mem.indexOf(u8, html, "<td>1</td>") != null);
        }
    }.run);
}

test "render: fenced code is escaped and language-tagged" {
    try withRender(
        \\```c
        \\int x = 1 < 2;
        \\```
        \\
    , struct {
        fn run(html: []const u8) !void {
            try testing.expect(std.mem.indexOf(u8, html, "<pre><code class=\"language-c\">") != null);
            try testing.expect(std.mem.indexOf(u8, html, "&lt;") != null);
        }
    }.run);
}

test "render: empty input yields empty html" {
    try withRender("", struct {
        fn run(html: []const u8) !void {
            try testing.expectEqualStrings("", html);
        }
    }.run);
}

test "render: dual render is byte-identical (determinism)" {
    const md = "# Dual\n\n**bold** and *em* and `code`\n\n| t |\n|---|\n| 1 |\n";
    var arena_a = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_b.deinit();
    const a = try render(md, &arena_a);
    const b = try render(md, &arena_b);
    try testing.expectEqualStrings(a.bytes, b.bytes);
}

test "render: large input stays bounded" {
    var md_buf: std.ArrayList(u8) = .empty;
    defer md_buf.deinit(testing.allocator);
    try md_buf.appendSlice(testing.allocator, "# Big\n\n");
    const line = "word **bold** and *em* and `code`\n";
    var n: usize = 0;
    while (n < test_large_md_bytes / line.len) : (n += 1) {
        try md_buf.appendSlice(testing.allocator, line);
    }
    try withRender(md_buf.items, struct {
        fn run(html: []const u8) !void {
            try testing.expect(html.len > 0);
            try testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"big\">Big</h1>") != null);
        }
    }.run);
}
