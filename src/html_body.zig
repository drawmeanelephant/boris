//! Shared source-to-HTML body pipeline for the HTML publish and heading-index paths.
//!
//! This module deliberately stops at the page body. Layout slots, staging and
//! publication remain owned by `compile.zig`; the caller owns the Whiteboard
//! and must keep it alive until every borrowed output slice has been consumed.

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const aside = @import("aside.zig");
const render = @import("render.zig");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");
const include_mod = @import("include.zig");
const wikilink = @import("wikilink.zig");
const textile = @import("textile.zig");
const cooklang_seam = @import("cooklang_seam.zig");
const diag = @import("diag.zig");
const content_asset = @import("content_asset.zig");
const doclink = @import("doclink.zig");

pub const Options = struct {
    input_format: identity.InputFormat = .markdown,
    nodes: []const graph_mod.Node = &.{},
    heading_index: ?*const wikilink.HeadingIndex = null,
    /// When non-null, rewrite Markdown image destinations into this page's
    /// sibling asset tree (see `docs/contracts/content-local-assets.md`).
    page_assets: ?*const content_asset.PageAssetBundle = null,
};

fn sourceLineAt(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (source[0..@min(offset, source.len)]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

fn componentDiagnostic(
    gpa: std.mem.Allocator,
    source: []const u8,
    body_offset: usize,
    source_path: []const u8,
    component_diag: aside.Diagnostic,
) !diag.Diagnostic {
    const message = if (component_diag.name.len > 0)
        try std.fmt.allocPrint(gpa, "{s}: {s}", .{ component_diag.name, component_diag.message })
    else
        try gpa.dupe(u8, component_diag.message);
    return .{
        .severity = .error_,
        .code = .ECOMPONENT,
        .message = message,
        .remediation = "Use only <Aside kind=\"…\" id=\"…\"> with allowlisted kind/id, outside fenced code",
        .source_path = source_path,
        .line = sourceLineAt(source, body_offset) + component_diag.line - 1,
        .column = component_diag.column,
    };
}

fn printComponentDiagnostics(
    gpa: std.mem.Allocator,
    source: []const u8,
    body_offset: usize,
    source_path: []const u8,
    diagnostics: []const aside.Diagnostic,
) !void {
    for (diagnostics) |component_diag| {
        const structured = try componentDiagnostic(gpa, source, body_offset, source_path, component_diag);
        defer gpa.free(structured.message);
        const text = try diag.formatText(structured, gpa);
        defer gpa.free(text);
        std.debug.print("{s}\n", .{text});
    }
}

fn parserDiagnostic(source_path: []const u8, parsed: parser.Diagnostic) diag.Diagnostic {
    return .{
        .severity = .error_,
        .code = diag.parserCategoryToCode(parsed.category),
        .message = parsed.message,
        .remediation = if (parsed.remediation.len > 0) parsed.remediation else "Fix the frontmatter or encoding for this file",
        .source_path = source_path,
        .line = parsed.line,
        .column = parsed.column,
    };
}

fn printParserDiagnostic(gpa: std.mem.Allocator, source_path: []const u8, parsed: parser.Diagnostic) !void {
    const structured = parserDiagnostic(source_path, parsed);
    const text = try diag.formatText(structured, gpa);
    defer gpa.free(text);
    std.debug.print("{s}\n", .{text});
}

/// An adapted page body plus whatever structured data the adapter recovered.
pub const AdaptedBody = struct {
    markdown: []const u8,
    /// Non-empty only for Cooklang input.
    recipe: cooklang_seam.Recipe = .{},
};

/// Convert a parsed page body when the whole tree explicitly uses one of the
/// non-Markdown input formats. Returned bytes are views into the supplied
/// allocator, so a caller that needs the recipe to outlive a per-page scratch
/// arena must pass a longer-lived one.
///
/// An adaptation diagnostic is fatal, so it is never gated on `--quiet`: that
/// flag suppresses progress and success output only.
pub fn bodyForInput(
    allocator: std.mem.Allocator,
    input_format: identity.InputFormat,
    source: []const u8,
    body: []const u8,
    body_offset: usize,
    source_path: []const u8,
) !AdaptedBody {
    switch (input_format) {
        .markdown => return .{ .markdown = body },
        .textile => {
            const adapted = try textile.toMarkdown(body, allocator);
            if (adapted.diagnostic) |td| {
                std.debug.print("error: ETEXTILE: {s}:{d}:{d}: {s} [Use only the bounded Textile compatibility subset]\n", .{
                    source_path,
                    sourceLineAt(source, body_offset) + td.line - 1,
                    td.column,
                    td.message,
                });
                return error.TextileFailed;
            }
            return .{ .markdown = adapted.markdown };
        },
        .cook => {
            const adapted = try cooklang_seam.toMarkdown(body, allocator);
            if (adapted.diagnostic) |cd| {
                std.debug.print("error: ECOOKLANG: {s}:{d}:{d}: {s} [Use only the bounded Cooklang subset]\n", .{
                    source_path,
                    sourceLineAt(source, body_offset) + cd.line - 1,
                    cd.column,
                    cd.message,
                });
                return error.CooklangFailed;
            }
            // Oliver's structural warnings degrade to literal text; they
            // surface as warnings, not failures.
            for (adapted.warnings) |w| {
                std.debug.print("warning: ECOOKLANG: {s}:{d}:{d}: {s}\n", .{
                    source_path,
                    sourceLineAt(source, body_offset) + w.line - 1,
                    w.column,
                    w.message,
                });
            }
            return .{ .markdown = adapted.markdown, .recipe = adapted.recipe };
        },
    }
}

/// Render one already-read page source through Boris's ordered HTML body path.
///
/// Ordering is contractual: parse/adapt, include expansion, wiki rewrite,
/// content-local image rewrite, Aside tokenization, then Oliver/Aside body
/// streaming. Diagnostics retain the same source-locus behavior as the old
/// compile-local implementation.
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
    if (parsed.diagnostic) |pd| {
        try printParserDiagnostic(gpa, source_path, pd);
        return error.ParseFailed;
    }
    const body = (try bodyForInput(arena, options.input_format, source, parsed.doc.body, parsed.doc.body_offset, source_path)).markdown;

    // Graph-backed Markdown documentation links → canonical page URLs
    // (pre-render). This runs before include expansion so source-relative links
    // retain the owning page's source context; included fragments are a
    // deliberate first-slice limitation.
    const with_doc_links = doclink.rewrite(arena, body, .{
        .nodes = options.nodes,
        .source_path = source_path,
        .output_path = output_path,
    }) catch return error.ReferenceFailed;

    // Scanners below measure offsets in the body slice, but the diagnostics
    // contract specifies the full-source line. Shift by the frontmatter.
    const fail_line_base = include_mod.frontmatterLineBase(source, parsed.doc.body_offset);

    var include_fail: include_mod.FailInfo = .{ .line_base = fail_line_base };
    const expanded = include_mod.expandIncludes(
        io,
        content_dir,
        gpa,
        arena,
        with_doc_links,
        source_path,
        &include_fail,
    ) catch |err| {
        include_mod.printDiagnostic(gpa, err, source_path, include_fail);
        return error.IncludeFailed;
    };

    var wiki_fail: wikilink.FailInfo = .{ .line_base = fail_line_base };
    const with_wiki = wikilink.rewriteWikiLinksOpts(arena, expanded, options.nodes, output_path, &wiki_fail, .{
        .heading_index = options.heading_index,
        .validate_fragments = options.heading_index != null,
    }) catch |err| {
        wikilink.printDiagnostic(gpa, err, source_path, wiki_fail);
        return error.ReferenceFailed;
    };

    // Content-local Markdown images → published sibling-tree URLs (pre-render).
    const with_assets = if (options.page_assets) |bundle| blk: {
        var asset_fail: content_asset.FailInfo = .{ .line_base = fail_line_base };
        break :blk content_asset.rewriteImageLinks(arena, with_wiki, bundle, output_path, &asset_fail) catch |err| {
            content_asset.printDiagnostic(gpa, err, source_path, asset_fail);
            return error.AssetFailed;
        };
    } else with_wiki;

    const tok = try aside.tokenizeBody(with_assets, arena);
    if (tok.hasErrors()) {
        try printComponentDiagnostics(gpa, source, parsed.doc.body_offset, source_path, tok.diagnostics);
        return error.ComponentFailed;
    }

    var html_buf: std.ArrayList(u8) = .empty;
    for (tok.segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                const h = try render.render(md, doc_arena);
                try html_buf.appendSlice(arena, h.bytes);
            },
            .aside => |component| {
                const h = try aside.renderHtml(component, doc_arena);
                try html_buf.appendSlice(arena, h);
            },
            .details => |component| {
                const h = try aside.renderDetailsHtml(component, doc_arena);
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

test "component diagnostics use ECOMPONENT and full-source locator" {
    const source =
        "---\n" ++
        "title: Bad Component\n" ++
        "---\n" ++
        "\n" ++
        "# Bad Component\n" ++
        "\n" ++
        "<Figure src=\"x.png\">\n";
    const parsed = parser.parse(source);
    try std.testing.expect(parsed.diagnostic == null);

    const structured = try componentDiagnostic(std.testing.allocator, source, parsed.doc.body_offset, "bad-component.md", .{
        .kind = .unregistered_component,
        .line = 4,
        .column = 1,
        .message = "unregistered component tag",
        .name = "Figure",
    });
    defer std.testing.allocator.free(structured.message);

    try std.testing.expectEqual(diag.Code.ECOMPONENT, structured.code);
    try std.testing.expectEqual(@as(?u32, 7), structured.line);
    try std.testing.expectEqual(@as(?u32, 1), structured.column);
    const text = try diag.formatText(structured, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "error: ECOMPONENT: bad-component.md:7:1: Figure: unregistered component tag [Use only <Aside kind=\"…\" id=\"…\"> with allowlisted kind/id, outside fenced code]",
        text,
    );
}

test "parser diagnostics retain shared code and source locator" {
    const parsed = parser.parse("---\nunknown: value\n---\n\nBody\n");
    try std.testing.expect(parsed.diagnostic != null);
    const structured = parserDiagnostic("bad-frontmatter.md", parsed.diagnostic.?);

    try std.testing.expectEqual(diag.Code.EFRONTMATTER, structured.code);
    try std.testing.expectEqual(@as(?u32, 2), structured.line);
    try std.testing.expectEqual(@as(?u32, 1), structured.column);
    const text = try diag.formatText(structured, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "error: EFRONTMATTER: bad-frontmatter.md:2:1: "));
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
        .source_path = "guides/target.md",
        .title = "Target",
    }};
    const html = try renderSource(io, gpa, content_dir, &whiteboard, "Before\n\n{{include includes/fragment.md}}\n\n[[guides/target]]\n\n[Docs](guides/target.md?x=1&y=2#section)\n\n<Aside kind=\"tip\">\nInside\n</Aside>\n\nAfter\n", "index.md", "index.html", .{ .nodes = &nodes });

    const before = std.mem.indexOf(u8, html, "Before").?;
    const included = std.mem.indexOf(u8, html, "Included").?;
    const wiki = std.mem.indexOf(u8, html, "href=\"guides/target.html\"").?;
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"guides/target.html?x=1&amp;y=2#section\"") != null);
    const aside_at = std.mem.indexOf(u8, html, "<aside").?;
    const after = std.mem.indexOf(u8, html, "After").?;
    try std.testing.expect(before < included and included < wiki and wiki < aside_at and aside_at < after);
}
