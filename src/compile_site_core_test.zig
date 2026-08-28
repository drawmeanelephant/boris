//! Tests moved verbatim from compile.zig's test region (24 tests).
//! Wiring: trailing import block in compile.zig (the `test-compile` root).

const std = @import("std");
const Io = std.Io;
const page_mod = @import("page.zig");
const parser = @import("parser.zig");
const render = @import("render.zig");
const assemble = @import("assemble.zig");
const scanner = @import("scanner.zig");
const identity = @import("identity.zig");
const cache = @import("cache.zig");
const dependency = @import("dependency.zig");
const target_mod = @import("target.zig");
const graph_mod = @import("graph.zig");
const diag = @import("diag.zig");
const html_nav = @import("html_nav.zig");
const html_relations = @import("html_relations.zig");
const html_toc = @import("html_toc.zig");
const html_body = @import("html_body.zig");
const include_mod = @import("include.zig");
const wikilink = @import("wikilink.zig");
const doclink = @import("doclink.zig");
const json_out = @import("json_out.zig");
const pipeline = @import("pipeline.zig");
const theme_mod = @import("theme.zig");
const layout_select = @import("layout_select.zig");
const textile = @import("textile.zig");
const cooklang_seam = @import("cooklang_seam.zig");
const content_asset = @import("content_asset.zig");
const source_io = @import("source_io.zig");
const source_provider = @import("source_provider.zig");
const artifact_sink = @import("artifact_sink.zig");
const search_index = @import("search_index.zig");
const site_url = @import("site_url.zig");
const github_pages = @import("github_pages.zig");
const sitemap = @import("sitemap.zig");
const standard_site = @import("standard_site.zig");
const standard_site_emit = @import("standard_site_emit.zig");
const nostr_emit = @import("nostr_emit.zig");
const link_audit = @import("link_audit.zig");
const publication_location = @import("publication_location.zig");
const artifact_inventory = @import("artifact_inventory.zig");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");
const publication_evidence_state = @import("publication_evidence_state.zig");
const publication_proof_pack = @import("publication_proof_pack.zig");
const timings = @import("timings.zig");
const compile_stage = @import("compile_stage.zig");
const compile_cache = @import("compile_cache.zig");
const compile_heading = @import("compile_heading.zig");

// Byte-identity aliases: bodies below call these bare, exactly as they
// did when they lived inside compile.zig.
const compile = @import("compile.zig");
const PageDb = compile.PageDb;
const compileHtmlSite = compile.compileHtmlSite;
const experimental = compile.experimental;
const loadAndPromote = compile.loadAndPromote;

const kit = @import("compile_test_kit.zig");

const readAllFile = kit.readAllFile;
const writeTreeFile = kit.writeTreeFile;

test "experimental flag is true (HTML path not default product)" {
    try std.testing.expect(experimental);
}

test "Textile adapter feeds the existing Oliver HTML path deterministically" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    try writeTreeFile(io, root, "layout.html", "<!doctype html><main>{{content}}</main>\n");
    const layout = try std.fmt.allocPrint(gpa, "{s}/layout.html", .{root});
    defer gpa.free(layout);
    const sequential = try std.fmt.allocPrint(gpa, "{s}/sequential", .{root});
    defer gpa.free(sequential);
    const parallel = try std.fmt.allocPrint(gpa, "{s}/parallel", .{root});
    defer gpa.free(parallel);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .jobs = 1,
        .incremental = true,
        .input_format = .textile,
    });
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .dist_dir = parallel,
        .layout_path = layout,
        .quiet = true,
        .jobs = 2,
        .input_format = .textile,
    });

    var sequential_dir = try Io.Dir.cwd().openDir(io, sequential, .{});
    defer sequential_dir.close(io);
    var parallel_dir = try Io.Dir.cwd().openDir(io, parallel, .{});
    defer parallel_dir.close(io);
    const html = try readAllFile(io, sequential_dir, "index.html", gpa);
    defer gpa.free(html);
    const html_parallel = try readAllFile(io, parallel_dir, "index.html", gpa);
    defer gpa.free(html_parallel);
    try std.testing.expectEqualStrings(html, html_parallel);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>strong</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ins>inserted</ins>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<blockquote>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ol") != null);

    const no_op = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .jobs = 1,
        .incremental = true,
        .input_format = .textile,
    });
    try std.testing.expectEqual(@as(usize, 0), no_op.pages_written);

    try std.testing.expectError(error.TextileFailed, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/invalid/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .input_format = .textile,
    }));
    try std.testing.expectError(error.InputFormatMismatch, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/mixed/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .input_format = .textile,
    }));
}

test "layout missing marker aborts before content compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-missing-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html>no marker</html>");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.LayoutMissingMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));

    // Layout fails before content compile — no published page.
    const index_out = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_out);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, index_out, .{}));
}

test "layout duplicate marker aborts before content compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-dup-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<a>{{content}}</a>{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.LayoutDuplicateMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "#421: broken layout surfaces a structured ELAYOUTDUPLICATEMARKER diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-421-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<a>{{content}}</a>{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    try std.testing.expectError(error.LayoutDuplicateMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    }));

    try std.testing.expectEqual(@as(usize, 1), collector.list.items.len);
    const d = collector.list.items[0];
    try std.testing.expectEqual(diag.Code.ELAYOUTDUPLICATEMARKER, d.code);
    try std.testing.expectEqual(diag.Severity.error_, d.severity);
    try std.testing.expectEqualStrings(layout_path, d.source_path);
    try std.testing.expect(d.line == null);
}

test "#737: unknown layout marker enumerates the closed slot set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-737-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<a>{{nosuchslot}}</a>{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    try std.testing.expectError(error.LayoutUnknownMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    }));

    try std.testing.expectEqual(@as(usize, 1), collector.list.items.len);
    const d = collector.list.items[0];
    try std.testing.expectEqual(diag.Code.ELAYOUTUNKNOWNMARKER, d.code);
    // Every accepted marker is named so the valid set is discoverable (#737).
    inline for (.{ "{{content}}", "{{nav}}", "{{breadcrumb}}", "{{title}}", "{{toc}}", "{{children}}", "{{metadata}}", "{{relations}}", "{{backlinks}}", "{{footer}}", "{{head}}", "{{asset-url" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, d.remediation, marker) != null);
    }
}

test "#421: content failures are collected with source path and position" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-421-content", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n\n{{include missing.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    }));

    try std.testing.expectEqual(@as(usize, 1), diag.countErrors(collector.list.items));
    const d = for (collector.list.items) |item| {
        if (item.code == .EINCLUDEMISSING) break item;
    } else return error.TestExpectedEqual;
    // Source paths are content-root-relative (the stderr contract).
    try std.testing.expectEqualStrings("index.md", d.source_path);
    try std.testing.expect(d.line != null);
    try std.testing.expect(d.column != null);
}

test "#395: rule-selected layout emits an info ILAYOUTSELECTED outcome finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-395-layout-outcome", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "layouts/home.html", "HOME-{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const home_path = try std.fmt.allocPrint(gpa, "{s}/layouts/home.html", .{work});
    defer gpa.free(home_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &.{
            .{ .kind = .id, .value = "index", .layout_path = home_path },
        },
        .quiet = true,
        .diagnostics = &collector,
    });

    // Exactly one finding: the rule-selected page. This fixture has no fallback page.
    try std.testing.expectEqual(@as(usize, 1), collector.list.items.len);
    const d = collector.list.items[0];
    try std.testing.expectEqual(diag.Code.ILAYOUTSELECTED, d.code);
    try std.testing.expectEqual(diag.Severity.info, d.severity);
    try std.testing.expectEqualStrings("index.md", d.source_path);
    try std.testing.expectEqualStrings("index", d.id);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "id:index") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "layouts/home.html") != null);
}

test "#557: fallback layout winners emit ILAYOUTSELECTED" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-557-layout-fallback", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "layouts/home.html", "HOME-{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    try writeTreeFile(io, work, "content/about.md", "---\nid: about\n---\n# About\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const home_path = try std.fmt.allocPrint(gpa, "{s}/layouts/home.html", .{work});
    defer gpa.free(home_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &.{
            .{ .kind = .id, .value = "index", .layout_path = home_path },
        },
        .quiet = true,
        .diagnostics = &collector,
    });

    try std.testing.expectEqual(@as(usize, 2), collector.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(collector.list.items));
    try std.testing.expectEqual(diag.Code.ILAYOUTSELECTED, collector.list.items[0].code);
    try std.testing.expectEqual(diag.Code.ILAYOUTSELECTED, collector.list.items[1].code);
    try std.testing.expectEqual(diag.Severity.info, collector.list.items[0].severity);
    var saw_rule = false;
    var saw_fallback = false;
    for (collector.list.items) |d| {
        if (std.mem.eql(u8, d.source_path, "index.md")) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "id:index") != null);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "layouts/home.html") != null);
            saw_rule = true;
        } else if (std.mem.eql(u8, d.source_path, "about.md")) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "layout fallback selected") != null);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "layouts/main.html") != null);
            try std.testing.expectEqualStrings("about", d.id);
            saw_fallback = true;
        }
    }
    try std.testing.expect(saw_rule);
    try std.testing.expect(saw_fallback);
}

test "#557: rule-less sites emit no ILAYOUTSELECTED" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-557-layout-ruleless", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    try writeTreeFile(io, work, "content/about.md", "---\nid: about\n---\n# About\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    });

    try std.testing.expectEqual(@as(usize, 0), collector.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(collector.list.items));
}

test "#448: xhtml target emits a well-formed document and fails closed on raw HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-448-xhtml", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const xhtml_layout =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<html xmlns="http://www.w3.org/1999/xhtml"><head><title>X</title></head><body>{{content}}</body></html>
    ;
    try writeTreeFile(io, work, "layouts/xhtml.html", xhtml_layout);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nHello **world**.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/xhtml.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // 1. Happy path: XHTML profile + declaration-bearing layout → document starts
    // with the XML declaration and carries the xmlns wrapper.
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .output_profile = .xhtml,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "<?xml version=\"1.0\" encoding=\"utf-8\"?>"));
    try std.testing.expect(std.mem.indexOf(u8, got, "xmlns=\"http://www.w3.org/1999/xhtml\"") != null);
    // Fragment body: heading ids are plain XML-legal attributes, list items
    // are well-formed block elements.
    try std.testing.expect(std.mem.indexOf(u8, got, "<h1 id=\"home\">Home</h1>") != null);

    // 2. Fail closed: verbatim raw HTML on an XHTML target is a hard error.
    try writeTreeFile(io, work, "content/raw.md", "before <em>raw</em> after\n");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\n[[raw]]\n");
    try std.testing.expectError(error.RawHtmlNotXmlWellFormed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .output_profile = .xhtml,
        .quiet = true,
    }));

    // 3. The same raw content renders under the default HTML profile.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
}

test "valid layout output equals prefix + rendered html + suffix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-splice", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_raw = "PRE-{{content}}-SUF";
    try writeTreeFile(io, work, "layouts/main.html", layout_raw);
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Hello **world**.
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
    try std.testing.expectEqual(@as(usize, 0), stats.last_reset_capacity);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(got);

    const layout = try assemble.Layout.split(layout_raw);
    // Expected = prefix + Oliver(body) + suffix (no mega-string in product path;
    // test builds the oracle the same way for equality only).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body_html = try render.render("# Home\n\nHello **world**.\n", &arena);
    const expected = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ layout.prefix, body_html.bytes, layout.suffix });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, got);
}

test "--timings recorder observes HTML publication phases" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-timings-html", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Timed\n\nPage **body**.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var recorder = timings.Recorder.init(io);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .timings = &recorder,
    });

    // Every HTML publication phase ran and recorded elapsed time.
    const phases = [_]timings.Phase{
        .scan,            .parse,       .graph_validate, .dependency_resolve,
        .heading_harvest, .fingerprint, .render,         .search,
        .link_audit,      .inventory,   .checks,         .claims,
        .touches,         .proof_pack,
    };
    for (phases) |phase| {
        try std.testing.expect(
            recorder.phase_ns[@intFromEnum(phase)] > 0,
        );
    }
    // One page: load/parse read, shared-state read, render read.
    try std.testing.expect(recorder.counters[@intFromEnum(timings.Counter.page_reads)] >= 3);
    try std.testing.expect(recorder.counters[@intFromEnum(timings.Counter.hash_bytes)] > 0);
}

test "--timings include_reads counts each unique fragment once per build (#760)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-include-memo", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/includes/shared.md", "SHARED_FRAGMENT\n");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\n{{include includes/shared.md}}\n");
    try writeTreeFile(io, work, "content/guides/a.md", "# A\n\n{{include includes/shared.md}}\n");
    try writeTreeFile(io, work, "content/guides/b.md", "# B\n\n{{include includes/shared.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var recorder = timings.Recorder.init(io);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .timings = &recorder,
    });

    // Three consumer pages share one fragment: exactly one read (#760), and
    // every rendered page still carries the expanded fragment bytes.
    try std.testing.expectEqual(@as(u64, 1), recorder.counters[@intFromEnum(timings.Counter.include_reads)]);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    for ([_][]const u8{ "index.html", "guides/a.html", "guides/b.html" }) |out| {
        const page = try readAllFile(io, dist_dir, out, gpa);
        defer gpa.free(page);
        try std.testing.expect(std.mem.indexOf(u8, page, "SHARED_FRAGMENT") != null);
    }
}

test "--timings zero-page site publishes successfully with honest zero counters (#775)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-zero-pages", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    // Content root exists but holds no page sources: the exact shape that made
    // #775's reporter read all-zero counters as an instrumentation failure.
    try writeTreeFile(io, work, "content/notes/readme.txt", "not a page source\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var recorder = timings.Recorder.init(io);
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .timings = &recorder,
    });

    // Empty sites stay successful (rendered-search.md), so every counter is
    // legitimately zero: no page was read, fingerprinted, rendered, or audited.
    try std.testing.expectEqual(@as(usize, 0), stats.pages_attempted);
    inline for (@typeInfo(timings.Counter).@"enum".fields) |field| {
        try std.testing.expectEqual(
            @as(u64, 0),
            recorder.counters[@intFromEnum(@field(timings.Counter, field.name))],
        );
    }

    // The target still publishes its non-page artifacts.
    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const search_bytes = try readAllFile(io, dist_dir, "_boris/search/search-index.json", gpa);
    defer gpa.free(search_bytes);
    try std.testing.expect(std.mem.indexOf(u8, search_bytes, "\"documents\"") != null);
}

test "output paths use identity.safeOutputRelativePath (via PageDb)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-paths", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "content/nested/deep/page.md", "# Deep\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    try std.testing.expectEqual(@as(usize, 1), db.len());
    const expected = try identity.safeOutputRelativePath(gpa, "nested/deep/page");
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, db.items()[0].output_path);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, expected, gpa);
    defer gpa.free(got);
    try std.testing.expect(got.len > 0);
}

test "HTML path rejects invalid parent (graph gate)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f6-graph-gate", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html>{{nav}}{{content}}</html>");
    try writeTreeFile(io, work, "content/orphan.md", "---\ntitle: Orphan\nparent: missing-trunk\n---\n\n# Orphan\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.GraphValidationFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "HTML path emits site nav and breadcrumb for forest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f6-nav-emit", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html",
        \\<html><title>{{title}}</title>{{nav}}{{breadcrumb}}{{content}}</html>
    );
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n\n# Home\n");
    try writeTreeFile(io, work, "content/guides/child.md", "---\ntitle: Child\nparent: index\n---\n\n# Child\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const child = try readAllFile(io, dist_dir, "guides/child.html", gpa);
    defer gpa.free(child);
    try std.testing.expect(std.mem.indexOf(u8, child, "site-nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "site-nav__satellite is-current") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "../index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "breadcrumb") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "<title>Child</title>") != null);
}

test "HTML path emits deterministic escaped direct children with selected layouts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-children-slot", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<main data-layout=\"fallback\">{{content}}</main>");
    try writeTreeFile(io, work, "layouts/trunk.html", "<main data-layout=\"trunk\">{{children}}{{content}}</main>");
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Parent\n---\n\n# Parent\n");
    // Discovery order is deliberately opposite canonical entity-id order.
    try writeTreeFile(io, work, "content/zeta.md", "---\nparent: index\n---\n\n# Zeta\n");
    try writeTreeFile(io, work, "content/alpha.md", "---\ntitle: A & <Alpha>\nparent: index\n---\n\n# Alpha\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const trunk_layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/trunk.html", .{work});
    defer gpa.free(trunk_layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const rules = [_]layout_select.LayoutRule{.{ .kind = .role, .value = "trunk", .layout_path = trunk_layout_path }};

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const parent = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(parent);
    const alpha = try readAllFile(io, dist_dir, "alpha.html", gpa);
    defer gpa.free(alpha);
    const zeta = try readAllFile(io, dist_dir, "zeta.html", gpa);
    defer gpa.free(zeta);

    try std.testing.expect(std.mem.indexOf(u8, parent, "data-layout=\"trunk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "page-children") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "href=\"alpha.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "A &amp; &lt;Alpha&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "href=\"zeta.html\">zeta") != null);
    const alpha_at = std.mem.indexOf(u8, parent, "alpha.html").?;
    const zeta_at = std.mem.indexOf(u8, parent, "zeta.html").?;
    try std.testing.expect(alpha_at < zeta_at);
    // Satellites select the fallback layout and never receive a children fragment.
    try std.testing.expect(std.mem.indexOf(u8, alpha, "data-layout=\"fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "page-children") == null);
    try std.testing.expect(std.mem.indexOf(u8, zeta, "page-children") == null);

    // A child label change must re-render its parent slot. The existing frozen
    // reverse-dependency expansion is deliberately conservative for graph edits.
    try writeTreeFile(io, work, "content/alpha.md", "---\ntitle: Alpha Updated\nparent: index\n---\n\n# Alpha\n");
    const incremental = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), incremental.pages_written);
    const updated_parent = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(updated_parent);
    try std.testing.expect(std.mem.indexOf(u8, updated_parent, "Alpha Updated") != null);
}

test "HTML semantic relation and backlink slots use canonical nested hrefs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-semantic-html", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "theme/layouts/main.html", "<main>{{content}}</main>");
    try writeTreeFile(io, work, "theme/layouts/relations.html", "<main>{{relations}}{{backlinks}}{{content}}</main>");
    try writeTreeFile(io, work, "content/guides/source.md", "---\ntitle: Source\nrelations: [supersedes=reference/spec, verified_by=reference/spec]\n---\n\n# Source\n");
    try writeTreeFile(io, work, "content/reference/spec.md", "---\ntitle: Specification\n---\n\n# Spec\n");
    try writeTreeFile(io, work, "content/control.md", "---\ntitle: Control\n---\n\n# Control\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const relation_layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/relations.html", .{work});
    defer gpa.free(relation_layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "guides/source", .layout_path = relation_layout_path },
        .{ .kind = .id, .value = "reference/spec", .layout_path = relation_layout_path },
    };

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const source = try readAllFile(io, dist_dir, "guides/source.html", gpa);
    defer gpa.free(source);
    const spec = try readAllFile(io, dist_dir, "reference/spec.html", gpa);
    defer gpa.free(spec);
    const control = try readAllFile(io, dist_dir, "control.html", gpa);
    defer gpa.free(control);
    try std.testing.expect(std.mem.indexOf(u8, source, "semantic-relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-relation-kind=\"supersedes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "href=\"../reference/spec.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "semantic-backlinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "data-relation-kind=\"verified_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "href=\"../guides/source.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, control, "semantic-relations") == null);
    try std.testing.expect(std.mem.indexOf(u8, control, "semantic-backlinks") == null);
}

test "HTML path emits page toc from body headings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f6-toc-emit", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html",
        \\<html>{{toc}}<main>{{content}}</main></html>
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Outline
        \\---
        \\
        \\# Top Level
        \\
        \\Intro paragraph.
        \\
        \\## Section One
        \\
        \\### Nested
        \\
        \\## Section Two
        \\
        \\#### Skipped depth
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "page-toc") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "aria-label=\"On this page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#top-level\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#section-one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#section-two\"") != null);
    // h4 is not in toc.
    try std.testing.expect(std.mem.indexOf(u8, page, "skipped-depth") == null or
        std.mem.indexOf(u8, page, "href=\"#skipped-depth\"") == null);
    // Body still has the h4 id for in-page anchors.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"skipped-depth\"") != null);
    // TOC anchors match body heading ids.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"section-one\"") != null);
}

test "html fixture golden: expected/ matches compile output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-golden", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "test/fixtures/html/content",
        .dist_dir = dist,
        .layout_path = "test/fixtures/html/layouts/main.html",
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);

    const expected_files = [_][]const u8{ "index.html", "guides/note.html" };
    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    var exp_dir = try cwd.openDir(io, "test/fixtures/html/expected", .{});
    defer exp_dir.close(io);

    for (expected_files) |rel| {
        const got = try readAllFile(io, dist_dir, rel, gpa);
        defer gpa.free(got);
        const exp = try readAllFile(io, exp_dir, rel, gpa);
        defer gpa.free(exp);
        try std.testing.expectEqualStrings(exp, got);
    }
}

test "html fixture golden: documentation links and local assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-doc-links-golden", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const first_dist = try std.fmt.allocPrint(gpa, "{s}/first", .{work});
    defer gpa.free(first_dist);
    const second_dist = try std.fmt.allocPrint(gpa, "{s}/second", .{work});
    defer gpa.free(second_dist);
    const content = "test/fixtures/doc-links/content";
    const layout = "test/fixtures/doc-links/layouts/main.html";
    const expected = "test/fixtures/doc-links/expected";
    const expected_files = [_][]const u8{
        "index.html",
        "reference.html",
        "guides/start.html",
        "guides/start.assets/diagram.svg",
    };

    const first_stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = first_dist,
        .layout_path = layout,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), first_stats.pages_written);

    const second_stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = second_dist,
        .layout_path = layout,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), second_stats.pages_written);

    var first_dir = try cwd.openDir(io, first_dist, .{});
    defer first_dir.close(io);
    var second_dir = try cwd.openDir(io, second_dist, .{});
    defer second_dir.close(io);
    var expected_dir = try cwd.openDir(io, expected, .{});
    defer expected_dir.close(io);

    for (expected_files) |rel| {
        const got_first = try readAllFile(io, first_dir, rel, gpa);
        defer gpa.free(got_first);
        const got_second = try readAllFile(io, second_dir, rel, gpa);
        defer gpa.free(got_second);
        const want = try readAllFile(io, expected_dir, rel, gpa);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, got_first);
        try std.testing.expectEqualStrings(got_first, got_second);
    }
}

test "flush-before-reset: compile defers free_all only after writePage" {
    // Structural proof via HoldUntilFlush sink (see assemble tests) plus
    // end-to-end: after compileHtmlSite, Whiteboard capacity is 0 and files
    // are complete (publication finished before last free_all).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-flush-order", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "H{{content}}T");
    try writeTreeFile(io, work, "content/p.md", "# Title\n\nParagraph.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats.last_reset_capacity);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, "p.html", gpa);
    defer gpa.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "H"));
    try std.testing.expect(std.mem.endsWith(u8, got, "T"));
    // Oliver emits header ids: <h1 id="...">
    try std.testing.expect(std.mem.indexOf(u8, got, "<h1") != null);
}
