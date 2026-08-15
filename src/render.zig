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
    /// Oliver's renderer rejects content it cannot guarantee XML-well-formed
    /// under the XHTML profile. Boris always renders with the default HTML
    /// profile, so this member is structurally unreachable through this seam;
    /// it exists so the error set tracks Oliver's public return type exactly
    /// (compile-time seam review when Oliver's surface changes).
    RawHtmlNotXmlWellFormed,
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
    .strikethrough = true,
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

/// A publication-safe-Markdown defect found by `inspectMarkdown`.
///
/// These are the two structural conditions NIP-23 forbids a creating client
/// from publishing (`docs/contracts/nostr-publication.md`). They are reported
/// from Oliver's typed document rather than by scanning bytes, so markup that
/// merely *looks* like HTML inside a code span or fenced block cannot trip
/// them.
pub const MarkdownDefect = enum {
    /// An HTML block or an inline raw-HTML run. NIP-23 forbids HTML in
    /// long-form content outright.
    raw_html,
    /// A paragraph broken across source lines. NIP-23 forbids hard-wrapped
    /// paragraphs because the receiving client controls the line width.
    ///
    /// An authored line break (two trailing spaces or a backslash) parses as
    /// `hard_break`, not `soft_break`, and is deliberate authorial intent —
    /// it is preserved, not reported.
    hard_wrapped_paragraph,

    pub fn name(self: MarkdownDefect) []const u8 {
        return switch (self) {
            .raw_html => "raw-html",
            .hard_wrapped_paragraph => "hard-wrapped-paragraph",
        };
    }
};

/// The first defect in document order, with a 1-based position in the
/// inspected payload.
pub const MarkdownFinding = struct {
    defect: MarkdownDefect,
    line: u32,
    column: u32,
};

/// Inspect a Markdown payload structurally and report the first
/// publication-safety defect in document order, or `null` when there is none.
///
/// This parses through the same seam and the same dialect options production
/// rendering uses, then walks Oliver's typed document — it never renders and
/// never inspects HTML. Boris owns the policy (which constructs are refused);
/// Oliver keeps owning markup semantics, so the answer cannot drift from what
/// Boris actually publishes.
///
/// Determinism: Oliver's traversal is documented pre-order with children in
/// append order, and only the first finding is returned, so identical input
/// always yields an identical finding. Parse diagnostics are not consulted,
/// matching `render`'s behavior on the same input.
pub fn inspectMarkdown(md: []const u8, arena: *std.heap.ArenaAllocator) RenderError!?MarkdownFinding {
    const a = arena.allocator();

    var result = try oliver.parse(a, md, .markdown, .{ .markdown = markdown_options });
    defer result.deinit();

    // Explicit stack, mirroring Oliver's own iterator: traversal depth must not
    // consume the call stack on deeply nested input. Each frame remembers
    // whether it sits inside a paragraph, which is what distinguishes wrapped
    // prose from a line break in some other container.
    const Frame = struct { node: *const oliver.document.Node, in_paragraph: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(a);
    try stack.append(a, .{ .node = result.document.root, .in_paragraph = false });

    while (stack.pop()) |frame| {
        const node = frame.node;
        switch (node.tag) {
            .html_block, .raw_html => return finding(&result.document, node.span.start, .raw_html),
            .soft_break => if (frame.in_paragraph) {
                return finding(&result.document, node.span.start, .hard_wrapped_paragraph);
            },
            else => {},
        }
        const in_paragraph = frame.in_paragraph or node.tag == .paragraph;
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(a, .{ .node = node.children.items[i], .in_paragraph = in_paragraph });
        }
    }
    return null;
}

fn finding(doc: *const oliver.document.Document, offset: u32, defect: MarkdownDefect) MarkdownFinding {
    const at = doc.src.lineCol(offset);
    return .{ .defect = defect, .line = at.line, .column = at.column };
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

test "docs: renderer contract pin matches build.zig.zon" {
    const io = std.testing.io;
    const gpa = testing.allocator;
    const root = std.Io.Dir.cwd();

    const zon = try readFileAlloc(io, root, "build.zig.zon", gpa);
    defer gpa.free(zon);

    // Extract the Oliver dependency pin (revision + content hash) from
    // build.zig.zon so the contract docs cannot drift from what Zig actually
    // fetches and content-verifies.
    const url_prefix = "https://github.com/drawmeanelephant/oliver/archive/";
    const url_start = std.mem.indexOf(u8, zon, url_prefix) orelse
        return error.TestUnexpectedResult;
    const sha_start = url_start + url_prefix.len;
    const sha_end = std.mem.indexOfPos(u8, zon, sha_start, ".tar.gz") orelse
        return error.TestUnexpectedResult;
    const revision = zon[sha_start..sha_end];

    const hash_prefix = ".hash = \"oliver-0.0.0-";
    const hash_start = (std.mem.indexOf(u8, zon, hash_prefix) orelse
        return error.TestUnexpectedResult) + hash_prefix.len;
    const hash_end = std.mem.indexOfPos(u8, zon, hash_start, "\"") orelse
        return error.TestUnexpectedResult;
    const package_hash = zon[hash_start..hash_end];

    // docs/contracts/oliver-renderer.md (pin table) and
    // docs/contracts/fixtures/oliver-compat/MATRIX.md must cite the same
    // revision and content hash as build.zig.zon.
    try expectDocPin(io, root, "docs/contracts/oliver-renderer.md", try std.fmt.allocPrint(gpa, "| Commit | `{s}` |", .{revision}), gpa);
    try expectDocPin(io, root, "docs/contracts/oliver-renderer.md", try std.fmt.allocPrint(gpa, "| Package hash | `oliver-0.0.0-{s}` |", .{package_hash}), gpa);
    try expectDocPin(io, root, "docs/contracts/fixtures/oliver-compat/MATRIX.md", try std.fmt.allocPrint(gpa, "Pin: Oliver `{s}`", .{revision}), gpa);
}

fn readFileAlloc(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// Asserts a doc file cites a build.zig.zon pin; fails with the offending
/// needle when the docs drift from the dependency declaration.
fn expectDocPin(io: std.Io, root: std.Io.Dir, path: []const u8, needle: []const u8, gpa: std.mem.Allocator) !void {
    defer gpa.free(needle);
    const contents = try readFileAlloc(io, root, path, gpa);
    defer gpa.free(contents);
    if (std.mem.indexOf(u8, contents, needle) == null) {
        std.debug.print(
            \\pin guard: {s} does not cite `{s}` from build.zig.zon
            \\  update the doc when the Oliver pin moves
        , .{ path, needle });
        return error.TestUnexpectedResult;
    }
}

// --- publication-safe Markdown inspection ---------------------------------

fn inspect(md: []const u8) !?MarkdownFinding {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return try inspectMarkdown(md, &arena);
}

test "inspect: ordinary single-line paragraphs are publication safe" {
    try testing.expectEqual(@as(?MarkdownFinding, null), try inspect(
        \\# Title
        \\
        \\One paragraph on one line.
        \\
        \\Another one, with *emphasis* and a [link](https://example.com/a).
        \\
    ));
}

test "inspect: an HTML block is reported at its own line" {
    const found = (try inspect(
        \\Intro line.
        \\
        \\<div class="callout">raw</div>
        \\
    )).?;
    try testing.expectEqual(MarkdownDefect.raw_html, found.defect);
    try testing.expectEqual(@as(u32, 3), found.line);
}

test "inspect: inline raw HTML is reported" {
    const found = (try inspect("Text with <span>markup</span> inline.\n")).?;
    try testing.expectEqual(MarkdownDefect.raw_html, found.defect);
    try testing.expectEqual(@as(u32, 1), found.line);
}

test "inspect: a wrapped paragraph is reported at the wrap point" {
    const found = (try inspect(
        \\This paragraph is wrapped
        \\across two source lines.
        \\
    )).?;
    try testing.expectEqual(MarkdownDefect.hard_wrapped_paragraph, found.defect);
    try testing.expectEqual(@as(u32, 1), found.line);
}

test "inspect: a wrapped list item paragraph is still wrapped prose" {
    const found = (try inspect(
        \\- an item that continues
        \\  onto the next line
        \\
    )).?;
    try testing.expectEqual(MarkdownDefect.hard_wrapped_paragraph, found.defect);
}

test "inspect: HTML-looking text inside code is not raw HTML" {
    // The whole point of inspecting the typed document instead of the bytes:
    // a fenced block and a code span are leaves, so their contents are never
    // parsed as markup.
    try testing.expectEqual(@as(?MarkdownFinding, null), try inspect(
        \\Use `<div>` for a block.
        \\
        \\```html
        \\<div class="x">not markup here</div>
        \\```
        \\
    ));
}

test "inspect: an authored hard break is deliberate, not a wrap" {
    // Two trailing spaces parse as `hard_break`; NIP-23 forbids arbitrary
    // wrapping, not an authored line break.
    try testing.expectEqual(@as(?MarkdownFinding, null), try inspect("Line one.  \nLine two.\n"));
}

test "inspect: raw HTML wins over a later wrap (first defect in document order)" {
    const found = (try inspect(
        \\<p>raw</p>
        \\
        \\wrapped prose
        \\continues here.
        \\
    )).?;
    try testing.expectEqual(MarkdownDefect.raw_html, found.defect);
    try testing.expectEqual(@as(u32, 1), found.line);
}

test "inspect: repeated inspection of one payload is stable" {
    const md = "wrapped\nprose\n";
    const first = (try inspect(md)).?;
    const second = (try inspect(md)).?;
    try testing.expectEqual(first.defect, second.defect);
    try testing.expectEqual(first.line, second.line);
    try testing.expectEqual(first.column, second.column);
}

test "inspect: empty input is publication safe" {
    try testing.expectEqual(@as(?MarkdownFinding, null), try inspect(""));
}
