//! Tests moved verbatim from compile.zig's test region (8 tests).
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
const CompileStats = compile.CompileStats;
const PageDb = compile.PageDb;
const compileHtmlSite = compile.compileHtmlSite;
const compilePages = compile.compilePages;
const isContentCompileFailure = compile.isContentCompileFailure;
const loadAndPromote = compile.loadAndPromote;
const loadLayoutOnce = compile.loadLayoutOnce;
const observeWhiteboardLifecycle = compile.observeWhiteboardLifecycle;
const readFileAlloc = compile.readFileAlloc;
const renderAndPublishPage = compile.renderAndPublishPage;

const kit = @import("compile_test_kit.zig");

const readAllFile = kit.readAllFile;
const writeTreeFile = kit.writeTreeFile;

test "multi-target failure classification keeps I/O distinct from content" {
    try std.testing.expect(isContentCompileFailure(error.ParseFailed));
    try std.testing.expect(isContentCompileFailure(error.LayoutMissingMarker));
    try std.testing.expect(isContentCompileFailure(error.LayoutInvalidNavMarker));
    try std.testing.expect(isContentCompileFailure(error.AssetUnsafeSvg));
    try std.testing.expect(isContentCompileFailure(error.LinkAuditFailed));
    try std.testing.expect(!isContentCompileFailure(error.AccessDenied));
    try std.testing.expect(!isContentCompileFailure(error.OutOfMemory));
}

test "render failure: whiteboard resets and no final output published" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-render-fail", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/index.md", "# Never published\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Manual loop so we can observe the arena after the error path.
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    try cwd.createDirPath(io, dist);
    var content_dir = try cwd.openDir(io, content, .{});
    defer content_dir.close(io);
    var dist_dir = try cwd.openDir(io, dist, .{ .iterate = true });
    defer dist_dir.close(io);

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    // Warm the whiteboard so free_all is observable.
    _ = try doc_arena.allocator().alloc(u8, 256);

    const page = &db.items()[0];
    const result = renderAndPublishPage(io, gpa, content_dir, dist_dir, page, layout, &doc_arena, .{
        .test_fail_render_at = 0,
    }, 0, .{});
    try std.testing.expectError(error.TestInjectedRenderFailure, result);

    // Production loop always resets after return — do so here.
    _ = doc_arena.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), doc_arena.queryCapacity());

    // No final HTML published.
    var it = dist_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            try std.testing.expect(false); // unexpected file
        }
    }
}

test "write failure: prior final remains and temp cleaned" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-write-fail", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<x>{{content}}</x>");
    try writeTreeFile(io, work, "content/index.md", "# Page\n\nbody text\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // First successful publish.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{ .iterate = true });
    defer dist_dir.close(io);
    const prior = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(prior);
    try std.testing.expect(prior.len > 0);

    // Second attempt fails at publish; prior must remain.
    try std.testing.expectError(error.TestInjectedWriteFailure, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .test_fail_publish_at = 0,
    }));

    const after = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(prior, after);

    // No leftover createFileAtomic hex temps.
    var it = dist_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try std.testing.expectEqualStrings("index.html", entry.name);
    }
}

test "B-02 regression: failed rebuild preserves prior assets/0123456789abcdef and assets/worker.tmp" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-b02-rebuild-preserve-assets", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<x>{{content}}</x>");
    try writeTreeFile(io, work, "content/index.md", "# Page\n\nbody text\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    try writeTreeFile(io, work, "dist/assets/0123456789abcdef", "legitimate-asset-hex-data");
    try writeTreeFile(io, work, "dist/assets/worker.tmp", "legitimate-asset-tmp-data");

    // Second build fails (injected publish failure).
    try std.testing.expectError(error.TestInjectedWriteFailure, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .test_fail_publish_at = 0,
    }));

    var dist_dir = try cwd.openDir(io, dist, .{ .iterate = true });
    defer dist_dir.close(io);

    const hex_asset = try readAllFile(io, dist_dir, "assets/0123456789abcdef", gpa);
    defer gpa.free(hex_asset);
    try std.testing.expectEqualStrings("legitimate-asset-hex-data", hex_asset);

    const tmp_asset = try readAllFile(io, dist_dir, "assets/worker.tmp", gpa);
    defer gpa.free(tmp_asset);
    try std.testing.expectEqualStrings("legitimate-asset-tmp-data", tmp_asset);
}

test "success publish then whiteboard reset; PageDb metadata intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-pagedb", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: TITLE_ALPHA_UNIQUE
        \\status: draft
        \\tags: [a, one]
        \\---
        \\
        \\# Alpha
        \\
        \\BODY_MARKER_ALPHA
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: TITLE_BETA_UNIQUE
        \\parent: alpha
        \\---
        \\
        \\# Beta
        \\
        \\BODY_MARKER_BETA
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);
    try std.testing.expectEqual(@as(usize, 2), db.len());

    // Capture promoted metadata pointers before any whiteboard activity.
    const t0 = db.items()[0].title.?;
    const t1 = db.items()[1].title.?;
    const p1 = db.items()[1].parent.?;
    const tags0 = db.items()[0].tags;

    const stats = try compilePages(io, gpa, &db, layout, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
    try std.testing.expectEqual(@as(usize, 0), stats.last_reset_capacity);

    // PageDb still valid after every free_all.
    try std.testing.expectEqualStrings("TITLE_ALPHA_UNIQUE", t0);
    try std.testing.expectEqualStrings("TITLE_BETA_UNIQUE", t1);
    try std.testing.expectEqualStrings("alpha", p1);
    try std.testing.expectEqual(@as(usize, 2), tags0.len);
    try std.testing.expectEqualStrings("a", tags0[0]);
    try std.testing.expectEqualStrings("TITLE_ALPHA_UNIQUE", db.items()[0].title.?);
    try std.testing.expectEqualStrings("TITLE_BETA_UNIQUE", db.items()[1].title.?);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const a_html = try readAllFile(io, dist_dir, "alpha.html", gpa);
    defer gpa.free(a_html);
    const b_html = try readAllFile(io, dist_dir, "beta.html", gpa);
    defer gpa.free(b_html);
    try std.testing.expect(std.mem.indexOf(u8, a_html, "BODY_MARKER_ALPHA") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_html, "BODY_MARKER_BETA") == null);
    try std.testing.expect(std.mem.indexOf(u8, b_html, "BODY_MARKER_BETA") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_html, "BODY_MARKER_ALPHA") == null);
}

test "whiteboard lifecycle: many small + one large (allocator observation only)" {
    const gpa = std.testing.allocator;
    const obs = try observeWhiteboardLifecycle(gpa, 12, 32 * 1024);
    // free_all returns capacity to 0 for this ArenaAllocator model.
    try std.testing.expectEqual(@as(usize, 0), obs.after_small_reset);
    try std.testing.expectEqual(@as(usize, 0), obs.after_large_reset);
    // Large page required non-trivial capacity before reset.
    try std.testing.expect(obs.peak_large > 1024);
    // Deliberately no process-RSS assertion.
}

test "compilePages: parallel rendering success, determinism, and error paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist_seq = try std.fmt.allocPrint(gpa, "{s}/dist-seq", .{work});
    defer gpa.free(dist_seq);
    const dist_par = try std.fmt.allocPrint(gpa, "{s}/dist-par", .{work});
    defer gpa.free(dist_par);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    // Write a set of pages to render
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha
        \\---
        \\# Alpha page content
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta
        \\---
        \\# Beta page content
    );
    try writeTreeFile(io, work, "content/gamma.md",
        \\---
        \\title: Gamma
        \\---
        \\# Gamma page content
    );

    // Run sequential build
    var stats_seq: CompileStats = undefined;
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        stats_seq = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist_seq,
            .layout_path = layout_path,
            .jobs = 1,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 3), stats_seq.pages_written);
    }

    // Run parallel build
    var stats_par: CompileStats = undefined;
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        stats_par = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist_par,
            .layout_path = layout_path,
            .jobs = 4,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 3), stats_par.pages_written);
    }

    // Verify output determinism and byte-for-byte correctness
    const files = [_][]const u8{ "alpha.html", "beta.html", "gamma.html" };
    for (files) |f| {
        const path_seq = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_seq, f });
        defer gpa.free(path_seq);
        const path_par = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_par, f });
        defer gpa.free(path_par);

        const bytes_seq = try readFileAlloc(io, cwd, path_seq, gpa);
        defer gpa.free(bytes_seq);
        const bytes_par = try readFileAlloc(io, cwd, path_par, gpa);
        defer gpa.free(bytes_par);

        try std.testing.expectEqualStrings(bytes_seq, bytes_par);
    }

    // Run parallel build with injected render failure
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const res = compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist_par,
            .layout_path = layout_path,
            .jobs = 4,
            .test_fail_render_at = 1,
            .quiet = true,
        });
        try std.testing.expectError(error.TestInjectedRenderFailure, res);
    }
}

// D4 product-path smoke: rich pages under `--jobs` must match sequential
// HTML and two parallel runs must be byte-identical. Distinctive markers detect
// cross-talk if concurrent Oliver renders share mutable state.
test "compilePages: parallel Unified constructs stable under jobs (D4)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist_seq = try std.fmt.allocPrint(gpa, "{s}/dist-seq", .{work});
    defer gpa.free(dist_seq);
    const dist_par_a = try std.fmt.allocPrint(gpa, "{s}/dist-par-a", .{work});
    defer gpa.free(dist_par_a);
    const dist_par_b = try std.fmt.allocPrint(gpa, "{s}/dist-par-b", .{work});
    defer gpa.free(dist_par_b);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    try writeTreeFile(io, work, "content/table.md",
        \\---
        \\title: Table
        \\---
        \\| a | b |
        \\|---|---|
        \\| TBL-PAGE | 2 |
        \\
    );
    try writeTreeFile(io, work, "content/footnote.md",
        \\---
        \\title: Footnote
        \\---
        \\Hi[^1] FOOT-PAGE.
        \\
        \\[^1]: note body FOOT-PAGE
        \\
    );
    try writeTreeFile(io, work, "content/math.md",
        \\---
        \\title: Math
        \\---
        \\Inline $x$ MATH-PAGE
        \\
        \\$$
        \\y
        \\$$
        \\
    );
    try writeTreeFile(io, work, "content/callout.md",
        \\---
        \\title: Callout
        \\---
        \\> [!NOTE]
        \\> callout body CALL-PAGE
        \\
    );
    try writeTreeFile(io, work, "content/lists.md",
        \\---
        \\title: Lists
        \\---
        \\- item LIST-PAGE
        \\  - nested LIST-PAGE
        \\
        \\```c
        \\int CODE_PAGE = 1 < 2;
        \\```
        \\
    );
    try writeTreeFile(io, work, "content/deflist.md",
        \\---
        \\title: DefList
        \\---
        \\Term DL-PAGE
        \\: Definition DL-PAGE
        \\
        \\~~strike STRIKE-PAGE~~
        \\
    );

    const out_files = [_][]const u8{
        "table.html",
        "footnote.html",
        "math.html",
        "callout.html",
        "lists.html",
        "deflist.html",
    };
    const markers = [_][]const u8{
        "TBL-PAGE",
        "FOOT-PAGE",
        "MATH-PAGE",
        "CALL-PAGE",
        "LIST-PAGE",
        "DL-PAGE",
    };

    const runOnce = struct {
        fn go(
            io_: Io,
            gpa_: std.mem.Allocator,
            content_: []const u8,
            dist: []const u8,
            layout_path_: []const u8,
            jobs: usize,
        ) !void {
            const cwd_ = Io.Dir.cwd();
            var layout_arena = std.heap.ArenaAllocator.init(gpa_);
            defer layout_arena.deinit();
            const layout = try loadLayoutOnce(io_, cwd_, layout_path_, layout_arena.allocator());

            var retain_arena = std.heap.ArenaAllocator.init(gpa_);
            defer retain_arena.deinit();
            var db = PageDb.init(gpa_, retain_arena.allocator());
            defer db.deinit();
            try loadAndPromote(io_, gpa_, &db, content_);

            const stats = try compilePages(io_, gpa_, &db, layout, .{
                .content_root = content_,
                .dist_dir = dist,
                .layout_path = layout_path_,
                .jobs = jobs,
                .quiet = true,
            });
            try std.testing.expectEqual(@as(usize, 6), stats.pages_written);
        }
    }.go;

    try runOnce(io, gpa, content, dist_seq, layout_path, 1);
    try runOnce(io, gpa, content, dist_par_a, layout_path, 8);
    try runOnce(io, gpa, content, dist_par_b, layout_path, 8);

    for (out_files, 0..) |f, fi| {
        const path_seq = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_seq, f });
        defer gpa.free(path_seq);
        const path_a = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_par_a, f });
        defer gpa.free(path_a);
        const path_b = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_par_b, f });
        defer gpa.free(path_b);

        const bytes_seq = try readFileAlloc(io, cwd, path_seq, gpa);
        defer gpa.free(bytes_seq);
        const bytes_a = try readFileAlloc(io, cwd, path_a, gpa);
        defer gpa.free(bytes_a);
        const bytes_b = try readFileAlloc(io, cwd, path_b, gpa);
        defer gpa.free(bytes_b);

        try std.testing.expectEqualStrings(bytes_seq, bytes_a);
        try std.testing.expectEqualStrings(bytes_a, bytes_b);
        try std.testing.expect(std.mem.indexOf(u8, bytes_a, markers[fi]) != null);

        // Foreign markers must not appear (cross-talk).
        for (markers, 0..) |tok, mi| {
            if (mi == fi) continue;
            try std.testing.expect(std.mem.indexOf(u8, bytes_a, tok) == null);
        }
    }
}
