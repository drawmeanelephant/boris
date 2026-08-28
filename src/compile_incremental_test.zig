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
const CompileOptions = compile.CompileOptions;
const CompileStats = compile.CompileStats;
const PageDb = compile.PageDb;
const compileHtmlSite = compile.compileHtmlSite;
const compilePages = compile.compilePages;
const loadAndPromote = compile.loadAndPromote;
const loadLayoutOnce = compile.loadLayoutOnce;
const readFileAlloc = compile.readFileAlloc;

const kit = @import("compile_test_kit.zig");

const readAllFile = kit.readAllFile;
const readTargetPayload = kit.readTargetPayload;
const writeTreeFile = kit.writeTreeFile;

test "incremental semantic backlink material dirties only affected relation pages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-semantic-fp", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "theme/layouts/main.html", "<main>{{content}}</main>");
    try writeTreeFile(io, work, "theme/layouts/relations.html", "<main>{{relations}}{{backlinks}}{{content}}</main>");
    try writeTreeFile(io, work, "content/guides/source.md", "---\ntitle: Source\nrelations: [verified_by=reference/spec]\n---\n\n# Source\n");
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
    const options: CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    };

    try std.testing.expectEqual(@as(usize, 3), (try compileHtmlSite(io, gpa, options)).pages_written);
    try std.testing.expectEqual(@as(usize, 0), (try compileHtmlSite(io, gpa, options)).pages_written);
    try writeTreeFile(io, work, "content/guides/source.md", "---\ntitle: Source\nrelations: [validated_by=reference/spec]\n---\n\n# Source\n");
    try std.testing.expectEqual(@as(usize, 2), (try compileHtmlSite(io, gpa, options)).pages_written);
}

test "F8.3 incremental: changed page expands through parent and reference reverse edges" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f8-3-page-reverse", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n\n# Home\nOriginal body.\n");
    try writeTreeFile(io, work, "content/child.md", "---\ntitle: Child\nparent: index\n---\n\n# Child\nSee [[index]].\n");
    try writeTreeFile(io, work, "content/control.md", "---\ntitle: Control\n---\n\n# Control\nIndependent.\n");

    // Cold build and unchanged control run establish a valid cache.
    for ([_]usize{ 3, 0 }) |expected_writes| {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);
        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(expected_writes, stats.pages_written);
    }

    // Body-only target change does not alter the child's own fingerprint
    // material. The frozen reverse parent/reference edges must still dirty it;
    // the unrelated control remains cached.
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n\n# Home\nEdited body only.\n");
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);
        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 3), stats.pages_attempted);
    }
}

test "incremental HTML build mode - full verification suite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-incremental-suite", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const full_dist = try std.fmt.allocPrint(gpa, "{s}/dist-full", .{work});
    defer gpa.free(full_dist);

    // Write initial layouts and content files
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha Page
        \\---
        \\# Alpha
        \\
        \\{{include includes/sidebar.md}}
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Page
        \\---
        \\# Beta
        \\
        \\No includes here.
        \\
    );
    try writeTreeFile(io, work, "content/includes/sidebar.md", "Sidebar {{include includes/widget.md}} content.");
    try writeTreeFile(io, work, "content/includes/widget.md", "Widget nested content.");

    // ---- 1. Cold cache / first run ----
    // This is the first incremental run: must render all pages (2) and write manifest.json
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // A cold incremental build must be byte-equivalent to a full build.
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);
        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = full_dist,
            .layout_path = layout_path,
            .incremental = false,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
    }
    {
        var inc_dir = try cwd.openDir(io, dist, .{});
        defer inc_dir.close(io);
        var full_dir = try cwd.openDir(io, full_dist, .{});
        defer full_dir.close(io);
        for ([_][]const u8{ "alpha.html", "beta.html" }) |path| {
            const incremental = try readAllFile(io, inc_dir, path, gpa);
            defer gpa.free(incremental);
            const full = try readAllFile(io, full_dir, path, gpa);
            defer gpa.free(full);
            try std.testing.expectEqualSlices(u8, full, incremental);
        }
    }

    // Verify manifest was written
    {
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        const manifest_bytes = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(manifest_bytes);
        try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, cache.CACHE_FORMAT_VERSION) != null);
    }

    // ---- 2. Subsequent unchanged run ----
    // No files have changed, output exists, so zero pages should be rendered.
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 3. Modifying one page source ----
    // Edit beta.md. Only beta.md should re-render.
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Page Edited
        \\---
        \\# Beta
        \\
        \\No includes here. Some edited content!
        \\
    );

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 4. Modifying a transitive include file ----
    // Edit content/includes/widget.md.
    // Since alpha.md depends on includes/sidebar.md which depends on includes/widget.md,
    // editing widget.md should trigger a re-render of alpha.md but NOT beta.md!
    try writeTreeFile(io, work, "content/includes/widget.md", "Widget nested content edited!");

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 5. Modifying the layout template ----
    // Changing layouts/main.html. All layout-dependent pages (both alpha and beta) must re-render.
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>Layout changed! {{content}}</body></html>");

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 6. Page deletion cleans up output file and cache entry ----
    // Delete content/beta.md. The output file beta.html and its cache entry should be removed.
    {
        var content_dir = try cwd.openDir(io, content, .{});
        defer content_dir.close(io);
        try content_dir.deleteFile(io, "beta.md");
    }

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);
        try std.testing.expectEqual(@as(usize, 1), db.len());

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_attempted);

        // Verify beta.html output file is deleted
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        try std.testing.expectError(error.FileNotFound, dist_dir.openFile(io, "beta.html", .{}));
    }

    // ---- 7. Malformed cache metadata fallback ----
    // Corrupt the manifest.json file. Run again. It should safely fall back and re-render everything (1 page left).
    {
        try writeTreeFile(io, dist, ".boris-cache/manifest.json", "{ malformed json }");
    }

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        // Falls back to cold build, so it re-renders alpha.md (1 page)
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_attempted);
    }

    // ---- 8. Fault injection: compile failure leaves manifest/output intact ----
    // Modify alpha.md to trigger a compilation error, and inject test_fail_cache_publish.
    // Verify that the failure does NOT save/publish the manifest.
    try writeTreeFile(io, work, "content/alpha.md", "Modified again!");

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
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .test_fail_cache_publish = true,
            .quiet = true,
        });
        try std.testing.expectError(error.TestInjectedCachePublishFailure, res);
    }
}

test "P4 cache freshness: same-size corruption, truncation, reuse, full=inc, manifest determinism" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-p4-cache-freshness", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const dist_full = try std.fmt.allocPrint(gpa, "{s}/dist-full", .{work});
    defer gpa.free(dist_full);
    const dist_inc = try std.fmt.allocPrint(gpa, "{s}/dist-inc", .{work});
    defer gpa.free(dist_inc);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha
        \\---
        \\# Alpha
        \\
        \\Body line one.
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta
        \\---
        \\# Beta
        \\
        \\Stable body.
        \\
    );

    const runHtml = struct {
        fn call(
            gpa_: std.mem.Allocator,
            io_: Io,
            content_: []const u8,
            dist_: []const u8,
            layout_path_: []const u8,
            incremental: bool,
        ) !CompileStats {
            const cwd_ = Io.Dir.cwd();
            var layout_arena = std.heap.ArenaAllocator.init(gpa_);
            defer layout_arena.deinit();
            const layout = try loadLayoutOnce(io_, cwd_, layout_path_, layout_arena.allocator());
            var retain_arena = std.heap.ArenaAllocator.init(gpa_);
            defer retain_arena.deinit();
            var db = PageDb.init(gpa_, retain_arena.allocator());
            defer db.deinit();
            try loadAndPromote(io_, gpa_, &db, content_);
            return try compilePages(io_, gpa_, &db, layout, .{
                .content_root = content_,
                .dist_dir = dist_,
                .layout_path = layout_path_,
                .incremental = incremental,
                .quiet = true,
            });
        }
    }.call;

    // Cold incremental build writes both pages and records output digests.
    {
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        const man = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(man);
        try std.testing.expect(std.mem.indexOf(u8, man, "output_digest") != null);
        try std.testing.expect(std.mem.indexOf(u8, man, cache.CACHE_FORMAT_VERSION) != null);
    }

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const alpha_clean = try readAllFile(io, dist_dir, "alpha.html", gpa);
    defer gpa.free(alpha_clean);
    try std.testing.expect(alpha_clean.len >= 2);

    // Same-size corruption must re-render only the corrupted page.
    {
        var corrupted = try gpa.dupe(u8, alpha_clean);
        defer gpa.free(corrupted);
        corrupted[0] = if (corrupted[0] == 'X') 'Y' else 'X';
        if (corrupted.len > 1) corrupted[1] = if (corrupted[1] == 'Z') 'W' else 'Z';
        const alpha_path = try std.fmt.allocPrint(gpa, "{s}/alpha.html", .{dist});
        defer gpa.free(alpha_path);
        try cwd.writeFile(io, .{ .sub_path = alpha_path, .data = corrupted });

        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
        const restored = try readAllFile(io, dist_dir, "alpha.html", gpa);
        defer gpa.free(restored);
        try std.testing.expectEqualStrings(alpha_clean, restored);
    }

    // Truncation / replacement must re-render.
    {
        const alpha_path = try std.fmt.allocPrint(gpa, "{s}/alpha.html", .{dist});
        defer gpa.free(alpha_path);
        try cwd.writeFile(io, .{ .sub_path = alpha_path, .data = "x" });
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        const restored = try readAllFile(io, dist_dir, "alpha.html", gpa);
        defer gpa.free(restored);
        try std.testing.expectEqualStrings(alpha_clean, restored);
    }

    // Intact outputs are reused.
    {
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // Manifest is byte-identical across two no-op incremental runs.
    {
        const man1 = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(man1);
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        const man2 = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(man2);
        try std.testing.expectEqualStrings(man1, man2);
    }

    // After source / include / layout edits, full and incremental trees match.
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha Edited
        \\---
        \\# Alpha
        \\
        \\Body line one edited.
        \\
    );
    try writeTreeFile(io, work, "layouts/main.html", "<html><body class=\"v2\">{{content}}</body></html>");
    try writeTreeFile(io, work, "content/includes/note.md", "shared note");
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta
        \\---
        \\# Beta
        \\
        \\{{include includes/note.md}}
        \\
    );

    _ = try runHtml(gpa, io, content, dist_full, layout_path, false);
    _ = try runHtml(gpa, io, content, dist_inc, layout_path, true);

    const files = [_][]const u8{ "alpha.html", "beta.html" };
    for (files) |f| {
        var dir_f = try cwd.openDir(io, dist_full, .{});
        defer dir_f.close(io);
        var dir_i = try cwd.openDir(io, dist_inc, .{});
        defer dir_i.close(io);
        const bf = try readAllFile(io, dir_f, f, gpa);
        defer gpa.free(bf);
        const bi = try readAllFile(io, dir_i, f, gpa);
        defer gpa.free(bi);
        try std.testing.expectEqualStrings(bf, bi);
    }

    // Dirty rebuild from an older cache also matches the full-tree baseline.
    {
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        for (files) |f| {
            var dir_f = try cwd.openDir(io, dist_full, .{});
            defer dir_f.close(io);
            const bf = try readAllFile(io, dir_f, f, gpa);
            defer gpa.free(bf);
            const bd = try readAllFile(io, dist_dir, f, gpa);
            defer gpa.free(bd);
            try std.testing.expectEqualStrings(bf, bd);
        }
    }
}

test "incremental evidence reuse skips derivation and --refresh-evidence forces it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/evidence-reuse", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "themes/docs/layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nStable body.\n");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/themes/docs/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const state_path = publication_evidence_state.state_dir_sub_path ++ "/default.json";
    const canonical_checks = blk: {
        const base: CompileOptions = .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout,
            .incremental = true,
            .quiet = true,
        };
        _ = try compileHtmlSite(io, gpa, base);
        break :blk try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    };
    defer gpa.free(canonical_checks);

    // State was recorded by the first incremental build.
    const state_bytes = try readTargetPayload(io, gpa, dist, state_path);
    gpa.free(state_bytes);

    const expectChecksEqual = struct {
        fn go(g: std.mem.Allocator, io_l: std.Io, d: []const u8, want: []const u8) !void {
            const got = try readTargetPayload(io_l, g, d, publication_checks.output_path);
            defer g.free(got);
            try std.testing.expectEqualStrings(want, got);
        }
    }.go;

    // Unchanged tree + injected checks failure still succeeds: reuse skipped
    // the derivation entirely.
    var reuse_options: CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
        .test_fail_publication_checks = true,
    };
    _ = try compileHtmlSite(io, gpa, reuse_options);
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // The same injection with --refresh-evidence must fail loud.
    reuse_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, reuse_options));
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // A corrupt state file falls back to full derivation (injection fires).
    reuse_options.refresh_evidence = false;
    try writeTreeFile(io, work, "dist/.boris-cache/evidence-state/default.json", "{ broken");
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, reuse_options));
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // A state file with a different compiler_id forces re-derivation: an
    // upgraded binary must not silently reuse stale evidence.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    const fake_json =
        \\{"format":"boris-evidence-state-v1","compiler_id":"boris/0.9.9","target":"default","artifacts_sha256":"0000000000000000000000000000000000000000000000000000000000000000","reports":[]}
    ;
    try writeTreeFile(io, work, "dist/.boris-cache/evidence-state/default.json", fake_json);
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
        .test_fail_publication_checks = true,
    }));
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // A tampered report digest also forces re-derivation, which restores the
    // canonical bytes.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    try writeTreeFile(io, work, "dist/_boris/proof/checks.json", "{\"tampered\":true}\n");
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    try expectChecksEqual(gpa, io, dist, canonical_checks);
}

test "F9.1 referenced asset change invalidates page fingerprint material" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-asset-fp", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/a.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/a.css", "v1");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
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
        .incremental = true,
    });
    // Second build should cache (0 pages written if fingerprints match)
    const stats_cached = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats_cached.pages_written);

    // Change asset bytes
    try writeTreeFile(io, work, "theme/assets/css/a.css", "v2");
    const stats_dirty = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats_dirty.pages_written);

    const css_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/a.css", .{dist});
    defer gpa.free(css_path);
    const css = try readFileAlloc(io, cwd, css_path, gpa);
    defer gpa.free(css);
    try std.testing.expectEqualStrings("v2", css);
}

test "F9.1 footer change dirties pages; unreferenced asset does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f91-footer-unref", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html>{{footer}}<link href="{{asset-url assets/css/used.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/footer.html", "FOOTER-V1");
    try writeTreeFile(io, work, "theme/assets/css/used.css", "used-v1");
    try writeTreeFile(io, work, "theme/assets/css/unused.css", "unused-v1");

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const noop = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), noop.pages_written);

    // Unreferenced asset change: pages stay cached; asset file still republished.
    try writeTreeFile(io, work, "theme/assets/css/unused.css", "unused-v2");
    const after_unref = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), after_unref.pages_written);
    const unused_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/unused.css", .{dist});
    defer gpa.free(unused_path);
    const unused_bytes = try readFileAlloc(io, cwd, unused_path, gpa);
    defer gpa.free(unused_bytes);
    try std.testing.expectEqualStrings("unused-v2", unused_bytes);

    // Footer change dirties every page using the layout.
    try writeTreeFile(io, work, "theme/footer.html", "FOOTER-V2");
    const after_footer = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 1), after_footer.pages_written);
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "FOOTER-V2") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "FOOTER-V1") == null);
}

// =============================================================================
// Content-local page assets (post-v0.5.0)
// =============================================================================

test "content-local assets: byte change does not re-render HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-bytes", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\![d](index.assets/d.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/d.svg", "v1");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const html_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(html_path);
    const html_before = try readFileAlloc(io, cwd, html_path, gpa);
    defer gpa.free(html_before);

    try writeTreeFile(io, work, "content/index.assets/d.svg", "v2-bytes-changed");
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats.pages_written);

    const html_after = try readFileAlloc(io, cwd, html_path, gpa);
    defer gpa.free(html_after);
    try std.testing.expectEqualStrings(html_before, html_after);

    const asset_path = try std.fmt.allocPrint(gpa, "{s}/index.assets/d.svg", .{dist});
    defer gpa.free(asset_path);
    const asset = try readFileAlloc(io, cwd, asset_path, gpa);
    defer gpa.free(asset);
    try std.testing.expectEqualStrings("v2-bytes-changed", asset);
}
