//! Shared source-to-HTML body pipeline for the HTML publish and heading-index paths.
//!
//! This module deliberately stops at the page body. Layout slots, staging and
//! publication remain owned by `compile.zig`; the caller owns the Whiteboard
//! and must keep it alive until every borrowed output slice has been consumed.

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const aside = @import("aside.zig");
const apex = @import("apex.zig");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");
const include_mod = @import("include.zig");
const wikilink = @import("wikilink.zig");
const textile = @import("textile.zig");

pub const Options = struct {
    input_format: identity.InputFormat = .markdown,
    quiet: bool = true,
    nodes: []const graph_mod.Node = &.{},
    heading_index: ?*const wikilink.HeadingIndex = null,
};

fn sourceLineAt(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (source[0..@min(offset, source.len)]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

/// Convert a parsed page body when the whole tree explicitly uses Textile.
/// Returned bytes are views into the supplied Whiteboard allocator.
pub fn bodyForInput(
    allocator: std.mem.Allocator,
    input_format: identity.InputFormat,
    source: []const u8,
    body: []const u8,
    body_offset: usize,
    source_path: []const u8,
    quiet: bool,
) ![]const u8 {
    if (input_format == .markdown) return body;
    const adapted = try textile.toMarkdown(body, allocator);
    if (adapted.diagnostic) |td| {
        if (!quiet) {
            std.debug.print("error: ETEXTILE: {s}:{d}:{d}: {s} [Use only the bounded Textile compatibility subset]\n", .{
                source_path,
                sourceLineAt(source, body_offset) + td.line - 1,
                td.column,
                td.message,
            });
        }
        return error.TextileFailed;
    }
    return adapted.markdown;
}

/// Render one already-read page source through Boris's ordered HTML body path.
///
/// Ordering is contractual: parse/adapt, include expansion, wiki rewrite,
/// Aside tokenization, then Apex/Aside body streaming. Diagnostics retain the
/// same source-locus behavior as the old compile-local implementation.
pub fn renderSource(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    doc_arena: *std.heap.ArenaAllocator,
    source: []const u8,
    source_path: []const u8,
    output_path: []const u8,
    options: Options,
) ![]const u8 {
    const arena = doc_arena.allocator();
    const parsed = parser.parse(source);
    if (parsed.diagnostic != null) return error.ParseFailed;
    const body = try bodyForInput(arena, options.input_format, source, parsed.doc.body, parsed.doc.body_offset, source_path, options.quiet);

    var include_fail: include_mod.FailInfo = .{};
    const expanded = include_mod.expandIncludes(
        io,
        content_dir,
        gpa,
        arena,
        body,
        source_path,
        &include_fail,
    ) catch |err| {
        if (!options.quiet) include_mod.printDiagnostic(gpa, err, source_path, include_fail);
        return error.IncludeFailed;
    };

    var wiki_fail: wikilink.FailInfo = .{};
    const with_wiki = wikilink.rewriteWikiLinksOpts(arena, expanded, options.nodes, output_path, &wiki_fail, .{
        .heading_index = options.heading_index,
        .validate_fragments = options.heading_index != null,
    }) catch |err| {
        if (!options.quiet) wikilink.printDiagnostic(gpa, err, source_path, wiki_fail);
        return error.ReferenceFailed;
    };

    const tok = try aside.tokenizeBody(with_wiki, arena);
    if (tok.hasErrors()) return error.ComponentFailed;

    var html_buf: std.ArrayList(u8) = .empty;
    for (tok.segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                const h = try apex.render(md, doc_arena);
                try html_buf.appendSlice(arena, h.bytes);
            },
            .aside => |component| {
                const h = try aside.renderHtml(component, doc_arena);
                try html_buf.appendSlice(arena, h);
            },
        }
    }
    return html_buf.items;
}

fn writeTestFile(io: Io, root: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, rel });
    defer std.testing.allocator.free(path);
    const cwd = Io.Dir.cwd();
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try cwd.createDirPath(io, parent);
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

test "shared body pipeline preserves include wiki Aside render order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/html-body", .{tmp.sub_path});
    defer gpa.free(root);
    try writeTestFile(io, root, "content/includes/fragment.md", "## Included\n");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{root});
    defer gpa.free(content_path);
    var content_dir = try Io.Dir.cwd().openDir(io, content_path, .{});
    defer content_dir.close(io);
    var whiteboard = std.heap.ArenaAllocator.init(gpa);
    defer whiteboard.deinit();

    const nodes = [_]graph_mod.Node{.{
        .id = "guides/target",
        .source_path = "target.md",
        .title = "Target",
    }};
    const html = try renderSource(io, gpa, content_dir, &whiteboard,
        "Before\n\n{{include includes/fragment.md}}\n\n[[guides/target]]\n\n<Aside kind=\"tip\">\nInside\n</Aside>\n\nAfter\n",
        "index.md", "index.html", .{ .nodes = &nodes });

    const before = std.mem.indexOf(u8, html, "Before").?;
    const included = std.mem.indexOf(u8, html, "Included").?;
    const wiki = std.mem.indexOf(u8, html, "href=\"guides/target.html\"").?;
    const aside_at = std.mem.indexOf(u8, html, "<aside").?;
    const after = std.mem.indexOf(u8, html, "After").?;
    try std.testing.expect(before < included and included < wiki and wiki < aside_at and aside_at < after);
}
