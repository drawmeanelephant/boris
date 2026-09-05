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
const source_provider = @import("source_provider.zig");

pub const Options = struct {
    input_format: identity.InputFormat = .markdown,
    nodes: []const graph_mod.Node = &.{},
    /// Prebuilt wiki id→node map covering exactly `nodes` (#726). When set, the
    /// wiki rewrite reuses it instead of rebuilding a per-page map; callers
    /// rendering many pages against one frozen graph should supply it.
    shared_node_map: ?*const wikilink.NodeMap = null,
    /// Prebuilt source_path→node map covering exactly `nodes` (#726), for the
    /// documentation-link rewrite. Same sharing contract as `shared_node_map`.
    shared_doclink_map: ?*const doclink.SourceNodeMap = null,
    heading_index: ?*const wikilink.HeadingIndex = null,
    /// When non-null, rewrite Markdown image destinations into this page's
    /// sibling asset tree (see `docs/contracts/content-local-assets.md`).
    page_assets: ?*const content_asset.PageAssetBundle = null,
    /// Optional HTML-path report collector; every diagnostic printed by this
    /// module is also appended here.
    diagnostics: ?*diag.Collector = null,
    /// Oliver serialization profile (#448). `.html` is the byte-identical
    /// default; `.xhtml` renders XML-compatible output and fails closed on
    /// verbatim raw HTML (`error.RawHtmlNotXmlWellFormed`).
    output_profile: render.OutputProfile = .html,
    /// When set, include expansion reads through this provider instead of `content_dir`.
    sources: ?source_provider.Provider = null,
    /// Build-scoped include expansion memo (#760). Callers rendering many
    /// pages in one build supply one shared cache; each unique fragment is
    /// then read and expanded once instead of once per consuming page.
    include_cache: ?*include_mod.IncludeCache = null,
};

fn readIncludeFromProvider(ptr: *anyopaque, path: []const u8, allocator: std.mem.Allocator) include_mod.IncludeError![]u8 {
    const provider: *source_provider.Provider = @ptrCast(@alignCast(ptr));
    return provider.readInclude(path, allocator);
}

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
    sink: ?*diag.Collector,
) !void {
    for (diagnostics) |component_diag| {
        const structured = try componentDiagnostic(gpa, source, body_offset, source_path, component_diag);
        defer gpa.free(structured.message);
        if (sink) |s| s.append(structured);
        diag.printText(structured, gpa);
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

fn printParserDiagnostic(gpa: std.mem.Allocator, source_path: []const u8, parsed: parser.Diagnostic, sink: ?*diag.Collector) !void {
    const structured = parserDiagnostic(source_path, parsed);
    if (sink) |s| s.append(structured);
    diag.printText(structured, gpa);
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
    /// Print degraded-structure warnings to stderr. Only the load-time
    /// validation call in `compile.zig` prints; the render and heading-harvest
    /// passes pass false so each warning surfaces exactly once per build.
    print_warnings: bool,
) !AdaptedBody {
    switch (input_format) {
        .markdown => return .{ .markdown = body },
        .textile => {
            const adapted = try textile.toMarkdown(body, allocator);
            if (adapted.diagnostic) |td| {
                if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: ETEXTILE: {s}:{d}:{d}: {s} [Use only the bounded Textile compatibility subset]\n", .{
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
                if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: ECOOKLANG: {s}:{d}:{d}: {s} [Use only the bounded Cooklang subset]\n", .{
                    source_path,
                    sourceLineAt(source, body_offset) + cd.line - 1,
                    cd.column,
                    cd.message,
                });
                return error.CooklangFailed;
            }
            // Oliver's structural warnings degrade to literal text; they
            // surface as warnings, not failures. The load-time validation call
            // passes `print_warnings = true`; the render and heading-harvest
            // passes stay silent so the build prints each warning once.
            if (print_warnings and !diag.text_suppressed.load(.unordered)) {
                for (adapted.warnings) |w| {
                    std.debug.print("warning: ECOOKLANG: {s}:{d}:{d}: {s}\n", .{
                        source_path,
                        sourceLineAt(source, body_offset) + w.line - 1,
                        w.column,
                        w.message,
                    });
                }
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
// ---------------------------------------------------------------------------
// Footnote reconciliation across component boundaries (#860)
// ---------------------------------------------------------------------------

/// One footnote definition in a markdown segment: its label and the
/// [start, end) source range of the definition lines (the `[^label]:` line
/// plus indented continuation lines up to a blank line).
const FootnoteDef = struct { label: []const u8, start: usize, end: usize };

const SegmentFootnotes = struct {
    refs: std.StringHashMapUnmanaged(void) = .empty,
    defs: std.ArrayList(FootnoteDef) = .empty,
};

const FootnoteFence = struct { ch: u8, run: usize };

fn footnoteFenceOpener(line: []const u8) ?FootnoteFence {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ' and i < 3) : (i += 1) {}
    if (i >= line.len) return null;
    const ch = line[i];
    if (ch != '`' and ch != '~') return null;
    var run: usize = 0;
    while (i + run < line.len and line[i + run] == ch) : (run += 1) {}
    if (run < 3) return null;
    return .{ .ch = ch, .run = run };
}

/// Collect `[^label]` references on one line, skipping inline code spans
/// (backtick-run matched; code spans do not cross lines).
fn scanFootnoteRefsOnLine(arena: std.mem.Allocator, line: []const u8, refs: *std.StringHashMapUnmanaged(void)) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
            var j = i + run;
            var closed = false;
            while (j < line.len) {
                if (line[j] == '`') {
                    var run2: usize = 0;
                    while (j + run2 < line.len and line[j + run2] == '`') : (run2 += 1) {}
                    if (run2 == run) {
                        i = j + run2;
                        closed = true;
                        break;
                    }
                    j += run2;
                } else {
                    j += 1;
                }
            }
            if (!closed) i += run;
            continue;
        }
        if (line[i] == '[' and i + 2 < line.len and line[i + 1] == '^') {
            var j = i + 2;
            while (j < line.len and line[j] != ']' and line[j] != '[' and line[j] != ' ' and line[j] != '\t') : (j += 1) {}
            if (j < line.len and line[j] == ']' and j > i + 2) {
                try refs.put(arena, line[i + 2 .. j], {});
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
}

/// Scan one markdown segment for footnote references and definition lines.
/// Fenced blocks are skipped; a definition is a `[^label]:` line at up to
/// three spaces of indentation.
fn scanSegmentFootnotes(arena: std.mem.Allocator, md: []const u8, out: *SegmentFootnotes) !void {
    var fence: ?FootnoteFence = null;
    var pos: usize = 0;
    while (pos < md.len) {
        const nl = std.mem.indexOfScalarPos(u8, md, pos, '\n') orelse md.len;
        const line = md[pos..nl];
        const line_end = if (nl < md.len) nl + 1 else nl;
        if (fence) |f| {
            if (footnoteFenceOpener(line)) |op| {
                if (op.ch == f.ch and op.run >= f.run) fence = null;
            }
        } else if (footnoteFenceOpener(line)) |op| {
            fence = op;
        } else {
            var indent: usize = 0;
            while (indent < line.len and line[indent] == ' ' and indent < 3) : (indent += 1) {}
            var def_label_end: ?usize = null;
            if (std.mem.startsWith(u8, line[indent..], "[^")) {
                const base = indent + 2;
                var j = base;
                while (j < line.len and line[j] != ']' and line[j] != '[' and line[j] != ' ' and line[j] != '\t') : (j += 1) {}
                if (j < line.len and line[j] == ']' and j + 1 < line.len and line[j + 1] == ':' and j > base) {
                    def_label_end = j;
                }
            }
            if (def_label_end) |dle| {
                const label = line[indent + 2 .. dle];
                var end = line_end;
                // Indented continuation lines belong to the definition.
                var cpos = end;
                while (cpos < md.len) {
                    const cnl = std.mem.indexOfScalarPos(u8, md, cpos, '\n') orelse md.len;
                    const cline = md[cpos..cnl];
                    if (cline.len == 0 or (cline[0] != ' ' and cline[0] != '\t') or footnoteFenceOpener(cline) != null) break;
                    end = if (cnl < md.len) cnl + 1 else cnl;
                    cpos = if (cnl < md.len) cnl + 1 else cnl;
                }
                try out.defs.append(arena, .{ .label = label, .start = pos, .end = end });
                // References inside the definition body count, but the def
                // label itself is not a reference.
                try scanFootnoteRefsOnLine(arena, line[dle + 1 ..], &out.refs);
                pos = cpos;
                continue;
            }
            try scanFootnoteRefsOnLine(arena, line, &out.refs);
        }
        pos = line_end;
    }
}

const FootnoteMove = struct { to_seg: usize, text: []const u8 };
const FootnoteRemoval = struct { seg: usize, start: usize, end: usize };

/// Move footnote definitions that a component split from their references
/// (#860): a definition whose own segment never references its label is
/// relocated — source text moved, never duplicated — to the first segment
/// that references it, so that segment's parse renders the reference and the
/// footnotes section. Definitions nothing references stay where the author
/// put them. Returns the input segments unchanged when nothing moves.
fn reconcileFootnotes(arena: std.mem.Allocator, segments: []const aside.Segment) ![]const aside.Segment {
    const scans = try arena.alloc(SegmentFootnotes, segments.len);
    for (scans) |*sc| sc.* = .{};
    for (segments, 0..) |seg, i| {
        if (seg == .markdown) try scanSegmentFootnotes(arena, seg.markdown, &scans[i]);
    }

    var moves: std.ArrayList(FootnoteMove) = .empty;
    var removals: std.ArrayList(FootnoteRemoval) = .empty;
    for (segments, 0..) |seg, i| {
        if (seg != .markdown) continue;
        for (scans[i].defs.items) |def| {
            if (scans[i].refs.contains(def.label)) continue;
            var target: ?usize = null;
            for (scans, 0..) |*other, j| {
                if (j == i) continue;
                if (other.refs.contains(def.label)) {
                    target = j;
                    break;
                }
            }
            const t = target orelse continue;
            try moves.append(arena, .{ .to_seg = t, .text = segments[i].markdown[def.start..def.end] });
            try removals.append(arena, .{ .seg = i, .start = def.start, .end = def.end });
        }
    }
    if (moves.items.len == 0) return segments;

    const rebuilt = try arena.dupe(aside.Segment, segments);
    const rebuilt_md = try arena.alloc([]const u8, segments.len);
    for (rebuilt_md, 0..) |*slot, i| {
        slot.* = if (segments[i] == .markdown) segments[i].markdown else "";
    }

    // Removals per segment, applied descending so ranges stay valid.
    for (rebuilt_md, 0..) |*slot, i| {
        var seg_removals: std.ArrayList(FootnoteRemoval) = .empty;
        defer seg_removals.deinit(arena);
        for (removals.items) |r| {
            if (r.seg == i) try seg_removals.append(arena, r);
        }
        if (seg_removals.items.len == 0) continue;
        std.mem.sort(FootnoteRemoval, seg_removals.items, {}, struct {
            fn less(_: void, a: FootnoteRemoval, b: FootnoteRemoval) bool {
                return a.start > b.start;
            }
        }.less);
        var md = slot.*;
        for (seg_removals.items) |r| {
            const joined = try std.fmt.allocPrint(arena, "{s}{s}", .{ md[0..r.start], md[r.end..] });
            md = joined;
        }
        slot.* = md;
    }

    // Appends: a moved definition lands at the end of its referencing
    // segment, blank-line separated so it cannot lazily continue prose.
    for (moves.items) |move| {
        const base = std.mem.trim(u8, rebuilt_md[move.to_seg], "\n");
        rebuilt_md[move.to_seg] = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base, move.text });
    }

    for (rebuilt, 0..) |*seg, i| {
        if (seg.* == .markdown) seg.* = .{ .markdown = rebuilt_md[i] };
    }
    return rebuilt;
}

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
    const prepared = try prepareBody(io, gpa, content_dir, doc_arena, source, source_path, output_path, options);

    // Footnote reconciliation (#860): a component between a footnote
    // reference and its definition splits them across Oliver parses, which
    // drops the definition and leaves the reference literal. Move split
    // definitions to a referencing segment before rendering.
    const segs = try reconcileFootnotes(arena, prepared.tok.segments);

    var html_buf: std.ArrayList(u8) = .empty;
    for (segs) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                const h = try render.renderProfile(md, doc_arena, options.output_profile);
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

/// Render one already-read page source through the same ordered preprocessing
/// as `renderSource`, then project each segment to deterministic semantic
/// plain text (`docs/contracts/plain-text-projection.md`). Markdown segments go
/// through the Oliver typed-document walk in `render.renderPlainText`; Aside and
/// Details components render their body text without their admonition chrome.
pub fn renderSourcePlainText(
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
    const prepared = try prepareBody(io, gpa, content_dir, doc_arena, source, source_path, output_path, options);

    var text_buf: std.ArrayList(u8) = .empty;
    for (prepared.tok.segments) |seg| {
        const text: []const u8 = switch (seg) {
            .markdown => |md| blk: {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) break :blk "";
                break :blk (try render.renderPlainText(md, doc_arena)).bytes;
            },
            .aside => |component| try aside.renderPlainText(component, doc_arena),
            .details => |component| try aside.renderDetailsPlainText(component, doc_arena),
        };
        try appendPlainSegment(&text_buf, arena, text);
    }
    if (text_buf.items.len > 0) try text_buf.append(arena, '\n');
    return text_buf.items;
}

/// Preprocessing shared by the HTML and plain-text body paths: parse/adapt,
/// documentation-link rewrite, include expansion, wiki rewrite, content-local
/// image rewrite, and Aside tokenization — in that fixed order. The returned
/// segments are slices into `doc_arena`.
const PreparedBody = struct {
    tok: aside.TokenizeResult,
};

fn prepareBody(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    doc_arena: *std.heap.ArenaAllocator,
    source: []const u8,
    source_path: []const u8,
    output_path: []const u8,
    options: Options,
) !PreparedBody {
    const arena = doc_arena.allocator();
    const parsed = parser.parse(source);
    if (parsed.diagnostic) |pd| {
        try printParserDiagnostic(gpa, source_path, pd, options.diagnostics);
        return error.ParseFailed;
    }
    const body = (try bodyForInput(arena, options.input_format, source, parsed.doc.body, parsed.doc.body_offset, source_path, false)).markdown;

    // Graph-backed Markdown documentation links → canonical page URLs
    // (pre-render). This runs before include expansion so source-relative links
    // retain the owning page's source context; included fragments are a
    // deliberate first-slice limitation.
    const with_doc_links = (if (options.shared_doclink_map) |shared_map|
        doclink.rewriteWithSourceMap(arena, body, .{
            .nodes = options.nodes,
            .source_path = source_path,
            .output_path = output_path,
        }, shared_map)
    else
        doclink.rewrite(arena, body, .{
            .nodes = options.nodes,
            .source_path = source_path,
            .output_path = output_path,
        })) catch return error.ReferenceFailed;

    // Scanners below measure offsets in the body slice, but the diagnostics
    // contract specifies the full-source line. Shift by the frontmatter.
    const fail_line_base = include_mod.frontmatterLineBase(source, parsed.doc.body_offset);

    var include_fail: include_mod.FailInfo = .{ .line_base = fail_line_base };
    var provider_storage = options.sources;
    const include_reader: ?include_mod.IncludeReader = if (provider_storage) |*p| .{
        .ptr = @ptrCast(p),
        .readFn = readIncludeFromProvider,
    } else null;
    const expanded = (if (options.include_cache) |cache|
        include_mod.expandIncludesWithCache(
            io,
            content_dir,
            include_reader,
            gpa,
            arena,
            with_doc_links,
            source_path,
            &include_fail,
            cache,
        )
    else
        include_mod.expandIncludesWithReader(
            io,
            content_dir,
            include_reader,
            gpa,
            arena,
            with_doc_links,
            source_path,
            &include_fail,
        )) catch |err| {
        include_mod.printDiagnostic(gpa, err, source_path, include_fail, options.diagnostics);
        return error.IncludeFailed;
    };

    var wiki_fail: wikilink.FailInfo = .{ .line_base = fail_line_base };
    const with_wiki = (if (options.shared_node_map) |shared_map|
        wikilink.rewriteWikiLinksWithMapOpts(arena, expanded, shared_map, output_path, &wiki_fail, .{
            .heading_index = options.heading_index,
            .validate_fragments = options.heading_index != null,
        })
    else
        wikilink.rewriteWikiLinksOpts(arena, expanded, options.nodes, output_path, &wiki_fail, .{
            .heading_index = options.heading_index,
            .validate_fragments = options.heading_index != null,
        })) catch |err| {
        wikilink.printDiagnostic(gpa, err, source_path, wiki_fail, options.diagnostics);
        return error.ReferenceFailed;
    };

    // Content-local Markdown images → published sibling-tree URLs (pre-render).
    const with_assets = if (options.page_assets) |bundle| blk: {
        var asset_fail: content_asset.FailInfo = .{ .line_base = fail_line_base };
        break :blk content_asset.rewriteImageLinks(arena, with_wiki, bundle, output_path, &asset_fail, null) catch |err| {
            content_asset.printDiagnostic(gpa, err, source_path, asset_fail, options.diagnostics);
            return error.AssetFailed;
        };
    } else with_wiki;

    const tok = try aside.tokenizeBody(with_assets, arena);
    if (tok.hasErrors()) {
        try printComponentDiagnostics(gpa, source, parsed.doc.body_offset, source_path, tok.diagnostics, options.diagnostics);
        return error.ComponentFailed;
    }
    return .{ .tok = tok };
}

/// Join one segment's plain text into the accumulated output with a single
/// blank line between non-empty segments. Trailing whitespace of each segment
/// (typically a code block's terminal newline) is treated as a terminator, not
/// content.
fn appendPlainSegment(buf: *std.ArrayList(u8), arena: std.mem.Allocator, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    if (buf.items.len > 0) try buf.appendSlice(arena, "\n\n");
    try buf.appendSlice(arena, trimmed);
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

test "footnote definition split by an Aside reconciles (#860)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/html-body-fn", .{tmp.sub_path});
    defer gpa.free(root);
    try writeTestFile(io, root, "content/index.md", "placeholder\n");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{root});
    defer gpa.free(content_path);
    var content_dir = try Io.Dir.cwd().openDir(io, content_path, .{});
    defer content_dir.close(io);
    var whiteboard = std.heap.ArenaAllocator.init(gpa);
    defer whiteboard.deinit();

    // Reference before, definition after: the component splits them.
    const html = try renderSource(io, gpa, content_dir, &whiteboard, "A footnote[^1].\n\n<Aside kind=\"tip\">\ntip body\n</Aside>\n\n[^1]: note body\n", "index.md", "index.html", .{});
    try std.testing.expect(std.mem.indexOf(u8, html, "footnote-ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-footnotes") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "note body") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "tip body") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "[^1]") == null);

    // Definition before, reference after: the other split direction.
    const html2 = try renderSource(io, gpa, content_dir, &whiteboard, "[^1]: note body\n\n<Aside kind=\"tip\">\ntip body\n</Aside>\n\nA footnote[^1].\n", "index.md", "index.html", .{});
    try std.testing.expect(std.mem.indexOf(u8, html2, "footnote-ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, html2, "data-footnotes") != null);
    try std.testing.expect(std.mem.indexOf(u8, html2, "note body") != null);
    try std.testing.expect(std.mem.indexOf(u8, html2, "[^1]") == null);

    // An unreferenced definition stays where the author put it (consumed by
    // the segment parse, unchanged behavior).
    const html3 = try renderSource(io, gpa, content_dir, &whiteboard, "Plain.\n\n<Aside kind=\"tip\">\ntip\n</Aside>\n\n[^1]: orphan body\n", "index.md", "index.html", .{});
    try std.testing.expect(std.mem.indexOf(u8, html3, "footnote-ref") == null);
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

test "plain-text body pipeline keeps words and drops chrome across segments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/plain-body", .{tmp.sub_path});
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
    const text = try renderSourcePlainText(io, gpa, content_dir, &whiteboard, "Before\n\n{{include includes/fragment.md}}\n\n[[guides/target]]\n\n[Docs](guides/target.md?x=1&y=2#section)\n\n<Aside kind=\"tip\">\nInside **aside**\n</Aside>\n\n<Details summary=\"More\">\nBody text\n</Details>\n\nAfter\n", "index.md", "index.html", .{ .nodes = &nodes });

    // Markdown syntax, admonition chrome, and the `<Aside>`/`<Details>` tags
    // are gone; include-expanded headings, wiki link labels, and link labels
    // survive as prose, and segments join with single blank lines.
    try std.testing.expectEqualStrings(
        "Before\n\nIncluded\n\nTarget\n\nDocs\n\nInside aside\n\nMore\nBody text\n\nAfter\n",
        text,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "<Aside") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<Details") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**") == null);
}
