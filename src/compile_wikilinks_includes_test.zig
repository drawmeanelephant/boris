//! Tests moved verbatim from compile.zig's test region (18 tests).
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
const HEADING_HARVEST_FORMAT = compile.HEADING_HARVEST_FORMAT;
const PageDb = compile.PageDb;
const compileHtmlSite = compile.compileHtmlSite;
const compilePages = compile.compilePages;
const loadAndPromote = compile.loadAndPromote;
const loadLayoutOnce = compile.loadLayoutOnce;
const readFileAlloc = compile.readFileAlloc;

const kit = @import("compile_test_kit.zig");

const readAllFile = kit.readAllFile;
const writeTreeFile = kit.writeTreeFile;

test "Feature 7 HTML: include expands and wiki becomes relative href" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-include-wiki-ok", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\# Home
        \\
        \\{{include includes/blurb.md}}
        \\
        \\See [[guides/note]] for more.
        \\
    );
    try writeTreeFile(io, work, "content/guides/note.md",
        \\---
        \\title: Note
        \\parent: index
        \\---
        \\# Note
        \\
        \\Satellite page.
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "INCLUDED_BLURB and [[guides/note|Note link]].\n");

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
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "INCLUDED_BLURB") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "{{include") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "[[") == null);
    // Wiki rewrite → Markdown link → Oliver <a href="…">
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"guides/note.html\"") != null);
}

test "Feature 7 HTML: fail-loud missing include" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-missing-include", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\{{include includes/does-not-exist.md}}
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: fail-loud include cycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-include-cycle", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\{{include includes/c1.md}}
        \\
    );
    try writeTreeFile(io, work, "content/includes/c1.md", "{{include includes/c2.md}}\n");
    try writeTreeFile(io, work, "content/includes/c2.md", "{{include includes/c1.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: nested include missing reports fragment locus" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-nested-locus", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\{{include includes/outer.md}}
        \\
    );
    try writeTreeFile(io, work, "content/includes/outer.md", "line1\n{{include includes/nope.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Plan-time collect fails; FailInfo locus is the outer fragment (unit-tested).
    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: fail-loud missing wiki target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-missing-wiki", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\See [[no/such/page]] please.
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.ReferenceFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: fenced and inline-code include and wiki stay literal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-fences", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\# Home
        \\
        \\```
        \\{{include includes/secret.md}}
        \\[[fenced/wiki]]
        \\```
        \\
        \\~~~
        \\{{include includes/secret.md}}
        \\[[fenced/wiki]]
        \\~~~
        \\
        \\Inline `{{include includes/secret.md}}` and `[[fenced/wiki]]` remain literal.
        \\
        \\Live text.
        \\
    );
    // If fences were broken, missing include / missing wiki would fail loud.
    try writeTreeFile(io, work, "content/includes/secret.md", "SHOULD_NOT_APPEAR\n");

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

    try std.testing.expect(std.mem.indexOf(u8, page, "SHOULD_NOT_APPEAR") == null);
    // Literal directive text survives inside code blocks (HTML-escaped or raw).
    try std.testing.expect(
        std.mem.indexOf(u8, page, "{{include") != null or
            std.mem.indexOf(u8, page, "{{include includes/secret.md}}") != null or
            std.mem.indexOf(u8, page, "include includes/secret") != null,
    );
}

test "Feature 7 incremental: title rename dirties parent that only wiki-links via include" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-wiki-via-include", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    // alpha: wiki only via include (no direct [[beta]])
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha
        \\---
        \\# Alpha
        \\
        \\{{include includes/blurb.md}}
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Original
        \\---
        \\# Beta
        \\
    );
    // gamma: control page — must stay cached when only beta title changes
    try writeTreeFile(io, work, "content/gamma.md",
        \\---
        \\title: Gamma
        \\---
        \\# Gamma independent
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "See [[beta]] from include.\n");

    // Cold build
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
        try std.testing.expectEqual(@as(usize, 3), stats.pages_written);
    }

    // Unchanged → zero writes
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
    }

    // Rename beta title only — beta source dirty + alpha via multi-body wiki material.
    // gamma must remain cached.
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Renamed
        \\---
        \\# Beta
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
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 3), stats.pages_attempted);
    }

    // alpha HTML should show the new wiki label from the renamed title
    {
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        const alpha_html = try readAllFile(io, dist_dir, "alpha.html", gpa);
        defer gpa.free(alpha_html);
        try std.testing.expect(std.mem.indexOf(u8, alpha_html, "Beta Renamed") != null);
        try std.testing.expect(std.mem.indexOf(u8, alpha_html, "href=\"beta.html\"") != null);
    }
}

test "Feature 9 HTML: heading fragment wiki links resolve to rendered ids" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-heading-ok", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Page-only: [[guides/target]].
        \\
        \\Fragment: [[guides/target#section-one]].
        \\
        \\Labeled: [[guides/target#code-x-y|Code heading]].
        \\
        \\Dup: [[guides/target#dup]].
        \\
        \\Unicode: [[guides/target#caf-rsum]].
        \\
        \\Punctuation: [[guides/target#hello-world]].
        \\
        \\Via include:
        \\
        \\{{include includes/blurb.md}}
        \\
    );
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: index
        \\---
        \\
        \\# Target Page
        \\
        \\## Section One
        \\
        \\## Code `x` Y
        \\
        \\## Café résumé
        \\
        \\## Hello, World!
        \\
        \\## Dup
        \\
        \\## Dup
        \\
        \\### Nested Deep
        \\
        \\#### Deep Four
        \\
        \\See trunk [[index#home]].
        \\
    );
    try writeTreeFile(io, work, "content/guides/from.md",
        \\---
        \\title: From Satellite
        \\parent: index
        \\---
        \\
        \\# From Satellite
        \\
        \\[[index#home]] and [[guides/target#nested-deep]] and [[guides/target#deep-four]].
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "Include-borne: [[guides/target#section-one|Section from include]].\n");

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
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);

    const index_html = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#section-one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#code-x-y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#dup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#caf-rsum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#hello-world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "[[") == null);

    const target_html = try readAllFile(io, dist_dir, "guides/target.html", gpa);
    defer gpa.free(target_html);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"section-one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"code-x-y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"caf-rsum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"dup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "href=\"../index.html#home\"") != null);

    const from_html = try readAllFile(io, dist_dir, "guides/from.html", gpa);
    defer gpa.free(from_html);
    try std.testing.expect(std.mem.indexOf(u8, from_html, "href=\"../index.html#home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, from_html, "href=\"target.html#nested-deep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, from_html, "href=\"target.html#deep-four\"") != null);

    // Determinism: second full build matches first.
    const dist2 = try std.fmt.allocPrint(gpa, "{s}/dist2", .{work});
    defer gpa.free(dist2);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist2,
        .layout_path = layout_path,
        .quiet = true,
    });
    var dist2_dir = try cwd.openDir(io, dist2, .{});
    defer dist2_dir.close(io);
    const index2 = try readAllFile(io, dist2_dir, "index.html", gpa);
    defer gpa.free(index2);
    try std.testing.expectEqualStrings(index_html, index2);

    // Incremental rebuild is byte-identical for unchanged pages.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    const index_inc = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_inc);
    try std.testing.expectEqualStrings(index_html, index_inc);
}

test "Feature 9 incremental: heading harvest cache skips rendering on no-op (#58)" {
    // Sites with [[entity#heading]] must not re-render every fragment target on a
    // no-op incremental build. Cold build writes heading-harvest.json; warm
    // no-op reuses harvest keys and still emits correct fragment hrefs.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-heading-harvest", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: guides
        \\---
        \\
        \\# Section One
        \\
        \\Body.
        \\
    );
    try writeTreeFile(io, work, "content/guides.md",
        \\---
        \\title: Guides
        \\---
        \\
        \\# Guides
        \\
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\See [[guides/target#section-one]].
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Cold incremental: harvest + publish.
    const stats_cold = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expect(stats_cold.pages_written >= 1);

    const harvest_path = try std.fmt.allocPrint(gpa, "{s}/.boris-cache/heading-harvest.json", .{dist});
    defer gpa.free(harvest_path);
    const harvest1 = try readFileAlloc(io, cwd, harvest_path, gpa);
    defer gpa.free(harvest1);
    try std.testing.expect(std.mem.indexOf(u8, harvest1, HEADING_HARVEST_FORMAT) != null);
    try std.testing.expect(std.mem.indexOf(u8, harvest1, "guides/target") != null);
    try std.testing.expect(std.mem.indexOf(u8, harvest1, "section-one") != null);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const index_html = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "guides/target.html#section-one") != null);

    // No-op warm: zero pages written; harvest file stable; HTML unchanged.
    const stats_warm = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats_warm.pages_written);

    const harvest2 = try readFileAlloc(io, cwd, harvest_path, gpa);
    defer gpa.free(harvest2);
    try std.testing.expectEqualStrings(harvest1, harvest2);

    const index_warm = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_warm);
    try std.testing.expectEqualStrings(index_html, index_warm);

    // Change only non-heading body text on the target → harvest key changes,
    // fragment id `section-one` still valid, rebuild succeeds and harvest updates.
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: guides
        \\---
        \\
        \\# Section One
        \\
        \\Body changed.
        \\
    );
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    const harvest3 = try readFileAlloc(io, cwd, harvest_path, gpa);
    defer gpa.free(harvest3);
    try std.testing.expect(std.mem.indexOf(u8, harvest3, "section-one") != null);
    // Harvest key must have changed (source bytes changed).
    try std.testing.expect(!std.mem.eql(u8, harvest1, harvest3));

    const index_after = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_after);
    try std.testing.expect(std.mem.indexOf(u8, index_after, "guides/target.html#section-one") != null);
}

test "Feature 9 HTML: missing heading fragment fails loud" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-heading-missing", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Broken: [[guides/target#does-not-exist]].
        \\
    );
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: index
        \\---
        \\
        \\# Target Page
        \\
        \\## Real Section
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.ReferenceFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 9 HTML: empty fragment is syntax failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-empty-frag", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Bad: [[index#]].
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.ReferenceFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 9 HTML: missing entity still fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-missing-entity", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\[[no/such/page#heading]].
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.ReferenceFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 9 HTML: fenced fragment wiki stays literal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-fence", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Live: [[index#home]].
        \\
        \\```
        \\[[index#home]]
        \\```
        \\
    );

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

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"index.html#home\"") != null);
    // Fenced form remains as author text (escaped or raw in code block).
    try std.testing.expect(std.mem.indexOf(u8, page, "[[index#home]]") != null);
}

test "Feature 9 HTML: jobs path resolves fragments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-jobs", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\[[guides/a#alpha]] [[guides/b#beta]]
        \\
    );
    try writeTreeFile(io, work, "content/guides/a.md",
        \\---
        \\title: A
        \\parent: index
        \\---
        \\
        \\# A
        \\
        \\## Alpha
        \\
    );
    try writeTreeFile(io, work, "content/guides/b.md",
        \\---
        \\title: B
        \\parent: index
        \\---
        \\
        \\# B
        \\
        \\## Beta
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
        .jobs = 4,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"guides/a.html#alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"guides/b.html#beta\"") != null);
}

test "Feature 9 HTML: include-borne missing fragment reports locus" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-inc-miss", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\{{include includes/bad.md}}
        \\
    );
    try writeTreeFile(io, work, "content/includes/bad.md", "See [[index#no-such-heading]].\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.ReferenceFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 9 HTML: manual heading id with slash is percent-encoded in href" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-manual-id", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\## Manual {#has/slash}
        \\
        \\Link: [[index#has/slash]].
        \\
    );

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

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"has/slash\"") != null);
    // Destination uses percent-encoding; browsers decode back to the id.
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"index.html#has%2Fslash\"") != null);
}

test "Feature 9 HTML: heading introduced by include is a valid target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-inc-heading", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\{{include includes/extra.md}}
        \\
        \\Jump: [[index#from-include]].
        \\
    );
    try writeTreeFile(io, work, "content/includes/extra.md", "## From Include\n\nBlurb.\n");

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

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"from-include\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"index.html#from-include\"") != null);
}

test "Feature 9 HTML: no fragment links skips heading-index render work path" {
    // Regression: pages with only page-only wiki still compile; empty index ok.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-no-frag", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\See [[guides/a]].
        \\
    );
    try writeTreeFile(io, work, "content/guides/a.md",
        \\---
        \\title: A
        \\parent: index
        \\---
        \\
        \\# A
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
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
}
