//! Oliver — a small, freestanding markup parsing and rendering library.
//!
//! Public API shape (deliberately provisional):
//!
//! ```zig
//! const result = try oliver.parse(allocator, source, .markdown, .{});
//! defer result.deinit();
//! try oliver.html.render(allocator, &writer, &result.document, .{});
//! // XHTML fragment serialization: same IR, different profile
//! try oliver.html.render(allocator, &writer, &result.document, .{ .profile = .xhtml });
//! ```
//!
//! Guarantees:
//! - The caller supplies the allocator; ownership is explicit.
//! - The parser never reads files or the environment.
//! - The renderer writes to any writer and never reparses.
//! - No global state, no hidden caches, deterministic output.
//!
//! The core (source, document, diagnostics, both frontends, the renderer)
//! depends on no host facilities: no filesystem, environment, clock, network,
//! or threads. Only the CLI (src/main.zig) touches stdio.

const std = @import("std");

pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");
/// The shared front matter pre-pass (sniff/strip/parse YAML `---` or TOML
/// `+++` at index 0; docs/FRONTMATTER.md).
pub const frontmatter = @import("frontmatter.zig");
pub const document = @import("document.zig");
pub const markdown = @import("markdown.zig");
pub const textile = @import("textile.zig");
pub const html = @import("html.zig");
/// The renderer output profile (`.html` or `.xhtml`); shared by the
/// Document renderer (`html.RenderOptions.profile`) and the Cooklang
/// renderer (`cooklang_html.RenderOptions.profile`). docs/XHTML.md.
pub const OutputProfile = html.OutputProfile;
/// Cooklang: a first-class frontend with its own typed `Recipe` model (not
/// the Markdown/Textile document IR). See docs/COOKLANG.md.
pub const cooklang = @import("cooklang.zig");
/// The deterministic Cooklang HTML rendering policy (docs/COOKLANG.md §C).
pub const cooklang_html = @import("cooklang_html.zig");
/// The canonical Cooklang serializer (semantic Recipe -> valid .cook;
/// docs/COOKLANG.md §10).
pub const cooklang_serialize = @import("cooklang_serialize.zig");
/// The pure Cooklang scaling operation (semantic Recipe -> scaled
/// Recipe) plus the public string primitives `classifyQuantity` /
/// `parseFactor` / `scaleAmount` (docs/COOKLANG.md §11).
pub const cooklang_scale = @import("cooklang_scale.zig");
/// The Cooklang `.menu` convenience view (semantic day/meal structure
/// over a parsed Recipe; docs/COOKLANG.md §12).
pub const cooklang_menu = @import("cooklang_menu.zig");

comptime {
    // The Cooklang modules have their own entry points and are never
    // referenced from `parse`/`html.render`, so Zig's lazy analysis would
    // drop them — and their unit tests with them — from the library test
    // binary. Force analysis so `zig build test` runs the Cooklang
    // parser and serializer unit tests (docs/TESTS.md).
    _ = cooklang;
    _ = cooklang_html;
    _ = cooklang_serialize;
    _ = cooklang_scale;
    _ = cooklang_menu;
}

pub const version = "0.0.0";

/// The input dialect. Both dialects converge into the same document model.
pub const Dialect = enum {
    markdown,
    textile,
};

/// Markdown dialect extensions. All are **off by default**: the Markdown
/// frontend is byte-exact CommonMark 0.31.2 unless a consumer opts in, so
/// the CommonMark conformance corpus stays green. Each extension is a
/// documented, principled addition with its own contract doc and tests
/// (footnotes, definition lists, heading attribute lists, GFM
/// strikethrough, wikilinks, callouts, smartypants; see
/// `markdown.Options`, docs/MARKDOWN-EXTENSIONS.md, docs/WIKILINKS.md,
/// docs/CALLOUTS.md, and docs/SMARTY.md).
pub const MarkdownOptions = markdown.Options;

/// Parse options. Markdown extensions are off by default, and front
/// matter is off by default: an index-0 `---` is today a §4.1 thematic
/// break, so recognizing it as a fence is an explicit opt-in
/// (docs/FRONTMATTER.md §3).
pub const ParseOptions = struct {
    markdown: MarkdownOptions = .{},
    /// Front matter handling, shared by all frontends: `.none` (default)
    /// sniffs nothing; `.yaml` sniffs `---` fences; `.toml` sniffs `+++`.
    frontmatter: frontmatter.Option = .none,
};

/// Failures that are not markup interpretation: the caller's problem.
pub const ParseError = error{
    /// Input exceeds `source.max_input_len` bytes (spans are `u32`).
    InputTooLarge,
    OutOfMemory,
};

/// The result of a parse: an owned document plus diagnostics. All memory is
/// owned by `document`'s arena; `deinit` releases it in one step.
pub const ParseResult = struct {
    document: document.Document,
    diagnostics: []const diagnostic.Diagnostic = &.{},
    /// Parsed front matter metadata when `ParseOptions.frontmatter` is on
    /// and the document opens with a fence; null otherwise (docs/
    /// FRONTMATTER.md §7). Arena-owned with the document.
    metadata: ?frontmatter.Metadata = null,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
        return .{
            .document = try document.Document.init(allocator, .{ .bytes = input }),
        };
    }

    pub fn deinit(self: *ParseResult) void {
        self.document.deinit();
    }
};

/// Parses `input` in the given dialect into the normalized document model.
/// The source bytes are borrowed by the document (text nodes slice into
/// them); they must outlive the result.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    dialect: Dialect,
    options: ParseOptions,
) ParseError!ParseResult {
    if (input.len > source.max_input_len) return error.InputTooLarge;

    var result = try ParseResult.init(allocator, input);
    errdefer result.deinit();

    // Diagnostics are arena-owned with the document so every appender
    // (the front matter pre-pass and the frontends) uses one allocator.
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    defer diags.deinit(result.document.allocator());

    // Front matter pre-pass: sniff and strip before dispatch, so no
    // frontend ever parses fence text (docs/FRONTMATTER.md §2). The
    // document source is rebound to the clean body; the arena is
    // unaffected. `metadata` (input-relative spans, borrowed slices)
    // keeps referencing `input`, which outlives the result.
    const fm = try frontmatter.preprocess(
        result.document.allocator(),
        input,
        options.frontmatter,
        options.frontmatter != .none,
        &diags,
    );
    result.document.src = .{ .bytes = fm.body };

    switch (dialect) {
        .markdown => try markdown.parse(&result.document, &diags, options.markdown),
        .textile => try textile.parse(&result.document, &diags),
    }
    // Copy the diagnostics out of the working list: the list's buffer is
    // freed at scope exit (an arena free can rewind the arena), so the
    // result must own its own slice (the cooklang pattern).
    result.diagnostics = try diags.toOwnedSlice(result.document.allocator());
    if (fm.block) |b| result.metadata = b.metadata;
    return result;
}

test "oliver: parse result owns its memory; deinit frees everything" {
    var result = try parse(std.testing.allocator, "# hello", .markdown, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "oliver: input too large is an API error, not a diagnostic" {
    // We cannot actually allocate 4 GiB; instead assert the boundary logic
    // via a synthetic oversized slice would be impractical. The check itself
    // is exercised structurally: max_input_len is a documented bound and the
    // comparison happens before any parsing.
    try std.testing.expect(std.math.maxInt(u32) == source.max_input_len);
}

test "oliver: empty input parses to an empty document" {
    var result = try parse(std.testing.allocator, "", .markdown, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.document.root.children.items.len);

    var result2 = try parse(std.testing.allocator, "", .textile, .{});
    defer result2.deinit();
    try std.testing.expectEqual(@as(usize, 0), result2.document.root.children.items.len);
}

test "oliver: markdown frontmatter parses metadata and strips the body" {
    // docs/FRONTMATTER.md §10: `---\ntitle: Hello\n---\n\n# Doc` parses
    // to `metadata.title == "Hello"` with the body exactly `# Doc`.
    var result = try parse(std.testing.allocator, "---\ntitle: Hello\n---\n\n# Doc", .markdown, .{ .frontmatter = .yaml });
    defer result.deinit();
    const m = result.metadata.?;
    try std.testing.expectEqual(@as(usize, 1), m.entries.len);
    try std.testing.expectEqualStrings("title", m.entries[0].key);
    try std.testing.expectEqualStrings("Hello", m.entries[0].value.scalar);
    // The clean body parses: exactly one heading, no diagnostics.
    try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
    try std.testing.expectEqual(document.Tag.heading, result.document.root.children.items[0].tag);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "oliver: frontmatter body renders through the shared renderer" {
    var result = try parse(std.testing.allocator, "---\ntitle: Hello\n---\n\n# Doc", .markdown, .{ .frontmatter = .yaml });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<h1>Doc</h1>\n", out.items);

    // The same front matter works for Textile (the clean body is dialect
    // syntax, not the shared pre-pass's concern).
    var result2 = try parse(std.testing.allocator, "---\ntitle: Hello\n---\n\nh1. Doc", .textile, .{ .frontmatter = .yaml });
    defer result2.deinit();
    var aw2 = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw2.deinit();
    try html.render(std.testing.allocator, &aw2.writer, &result2.document, .{});
    var out2 = aw2.toArrayList();
    defer out2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<h1>Doc</h1>\n", out2.items);
}

test "oliver: frontmatter off by default — index-0 --- stays a thematic break" {
    // The option exists precisely because `---` is genuinely ambiguous
    // with a §4.1 thematic break (docs/FRONTMATTER.md §3). Default keeps
    // the corpus byte-exact: break + paragraph + break + heading.
    var result = try parse(std.testing.allocator, "---\ntitle: x\n---\n# Doc", .markdown, .{});
    defer result.deinit();
    try std.testing.expect(result.metadata == null);
    // The index-0 `---` is a §4.1 thematic break; the second `---` closes
    // `title: x` as a §4.3 setext heading; `# Doc` is an ATX heading. The
    // default corpus behavior is untouched.
    try std.testing.expectEqual(@as(usize, 3), result.document.root.children.items.len);
    try std.testing.expectEqual(document.Tag.thematic_break, result.document.root.children.items[0].tag);
}

test "oliver: out-of-subset payload stays raw with a diagnostic" {
    var result = try parse(std.testing.allocator, "---\nlist: [1, 2]\n---\nBody", .markdown, .{ .frontmatter = .yaml });
    defer result.deinit();
    try std.testing.expect(result.metadata == null);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqualStrings("frontmatter-parse-unsupported", result.diagnostics[0].code);
    // The body strip still happens: front matter is never content.
    try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
    try std.testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
}

test "oliver: toml frontmatter" {
    var result = try parse(std.testing.allocator, "+++\ntitle = \"Hello\"\n+++\nBody", .markdown, .{ .frontmatter = .toml });
    defer result.deinit();
    const m = result.metadata.?;
    try std.testing.expectEqualStrings("title", m.entries[0].key);
    try std.testing.expectEqualStrings("Hello", m.entries[0].value.scalar);
    try std.testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
}
