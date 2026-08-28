//! Tests moved verbatim from compile.zig's test region (2 tests).
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
const compilePages = compile.compilePages;
const loadAndPromote = compile.loadAndPromote;
const loadLayoutOnce = compile.loadLayoutOnce;

const kit = @import("compile_test_kit.zig");

const readTargetPayload = kit.readTargetPayload;
const writeTreeFile = kit.writeTreeFile;

test "standard-site verification emits head links, well-known file, and report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-standard-site-emit", .{tmp.sub_path});
    defer gpa.free(work);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    try writeTreeFile(io, work, "layouts/main.html",
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>{{title}}</title>
        \\  {{head}}
        \\</head>
        \\<body>{{content}}</body>
        \\</html>
        \\
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\published_at: 2026-08-15T00:00:00Z
        \\summary: The front page.
        \\---
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "content/guide.md",
        \\---
        \\title: Guide
        \\published_at: 2026-08-15T00:00:00Z
        \\summary: The guide.
        \\---
        \\# Guide
        \\
    );
    try writeTreeFile(io, work, "content/draft.md",
        \\---
        \\title: Draft
        \\status: draft
        \\---
        \\# Draft
        \\
    );

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
    try std.testing.expect(layout.has_head);

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    var page_inputs: std.ArrayList(standard_site.PageInput) = .empty;
    defer page_inputs.deinit(gpa);
    for (db.items()) |p| {
        try page_inputs.append(gpa, .{
            .entity_id = p.entity_id,
            .output_path = p.output_path,
            .title = p.title,
            .status = if (p.status) |s| switch (s) {
                .published => .published,
                .archived => .archived,
                .draft => .draft,
            } else .none,
            .published_at = p.published_at,
            .summary = p.summary,
            .tags = p.tags,
        });
    }

    var config: standard_site.TargetConfig = .{
        .location = try standard_site.parseLocation(gpa, "https://example.com/", "https://example.com", ""),
        .did = try gpa.dupe(u8, "did:plc:testtesttesttesttest"),
    };
    defer config.deinit(gpa);
    var projection = try standard_site.project(gpa, .{
        .config = &config,
        .site_title = "Boris",
        .pages = page_inputs.items,
    });
    defer projection.deinit(gpa);
    const surfaces = try standard_site.verificationSurfaces(gpa, &config, &projection);
    defer {
        gpa.free(surfaces.well_known.content);
        gpa.free(surfaces.well_known.required_public_url);
        if (surfaces.well_known.project_path) |path| gpa.free(path);
        for (surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(surfaces.document_links);
    }
    const vctx: standard_site_emit.VerificationContext = .{ .surfaces = &surfaces, .projection = &projection };

    const stats = try compilePages(io, gpa, &db, layout, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .standard_site_verification = &vctx,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    // Eligible pages carry the exact document AT-URI in <head>, never the body.
    const index_html = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(index_html);
    const index_at_uri = standard_site_emit.documentAtUri(gpa, &surfaces, "index").?;
    try std.testing.expect(std.mem.indexOf(u8, index_html, index_at_uri) != null);
    const head_open = std.mem.indexOf(u8, index_html, "<head>").?;
    const body_open = std.mem.indexOf(u8, index_html, "<body>").?;
    const link_pos = std.mem.indexOf(u8, index_html, "site.standard.document").?;
    try std.testing.expect(link_pos > head_open and link_pos < body_open);

    // The well-known file matches the configured publication location.
    const well_known_bytes = try readTargetPayload(io, gpa, dist, standard_site.well_known_path);
    defer gpa.free(well_known_bytes);
    try std.testing.expectEqualStrings(projection.publication.at_uri, well_known_bytes);

    // The report records emitted documents (never ineligible drafts).
    const report_json = try readTargetPayload(io, gpa, dist, standard_site_emit.report_output_path);
    defer gpa.free(report_json);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"emitted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"draft\"") == null);
}

test "standard-site base-path build records limited and reports missing head slots" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-standard-site-limited", .{tmp.sub_path});
    defer gpa.free(work);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    // Layout deliberately omits the compiler-owned {{head}} slot.
    try writeTreeFile(io, work, "layouts/main.html",
        \\<html>
        \\<head><title>{{title}}</title></head>
        \\<body>{{content}}</body>
        \\</html>
        \\
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\published_at: 2026-08-15T00:00:00Z
        \\summary: The front page.
        \\---
        \\# Home
        \\
    );

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
    try std.testing.expect(!layout.has_head);

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    var page_inputs: std.ArrayList(standard_site.PageInput) = .empty;
    defer page_inputs.deinit(gpa);
    for (db.items()) |p| {
        try page_inputs.append(gpa, .{
            .entity_id = p.entity_id,
            .output_path = p.output_path,
            .title = p.title,
            .status = if (p.status) |s| switch (s) {
                .published => .published,
                .archived => .archived,
                .draft => .draft,
            } else .none,
            .published_at = p.published_at,
            .summary = p.summary,
            .tags = p.tags,
        });
    }

    var config: standard_site.TargetConfig = .{
        .location = try standard_site.parseLocation(gpa, "https://example.com/repo/", "https://example.com", "/repo"),
        .did = try gpa.dupe(u8, "did:plc:testtesttesttesttest"),
    };
    defer config.deinit(gpa);
    var projection = try standard_site.project(gpa, .{
        .config = &config,
        .site_title = "Boris",
        .pages = page_inputs.items,
    });
    defer projection.deinit(gpa);
    const surfaces = try standard_site.verificationSurfaces(gpa, &config, &projection);
    defer {
        gpa.free(surfaces.well_known.content);
        gpa.free(surfaces.well_known.required_public_url);
        if (surfaces.well_known.project_path) |path| gpa.free(path);
        for (surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(surfaces.document_links);
    }
    const vctx: standard_site_emit.VerificationContext = .{ .surfaces = &surfaces, .projection = &projection };

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();

    const stats = try compilePages(io, gpa, &db, layout, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .standard_site_verification = &vctx,
        .diagnostics = &collector,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);

    // The base-path limitation is explicit: no plausible public well-known
    // file, the exact bytes preserved as a sideband artifact, and the
    // report records `limited` plus the missing-head `not_verified` page.
    try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, standard_site.well_known_path));
    const sideband = try readTargetPayload(io, gpa, dist, standard_site_emit.sideband_output_path);
    defer gpa.free(sideband);
    try std.testing.expectEqualStrings(projection.publication.at_uri, sideband);

    const report_json = try readTargetPayload(io, gpa, dist, standard_site_emit.report_output_path);
    defer gpa.free(report_json);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"limited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"not_verified\"") != null);

    // Layouts that omit {{head}} are reported so absence is never silent.
    var saw_head_warning = false;
    for (collector.list.items) |d| {
        if (d.code == .EVERIFICATIONHEAD and d.severity == .warning) saw_head_warning = true;
    }
    try std.testing.expect(saw_head_warning);
}
