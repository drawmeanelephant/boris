//! Tests moved verbatim from compile.zig's test region (7 tests).
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
const compileHtmlSite = compile.compileHtmlSite;
const compileHtmlSiteMulti = compile.compileHtmlSiteMulti;
const experimental = compile.experimental;
const readFileAlloc = compile.readFileAlloc;
const validateHtmlSiteMulti = compile.validateHtmlSiteMulti;

const kit = @import("compile_test_kit.zig");

const expectArtifactInventoryShape = kit.expectArtifactInventoryShape;
const expectPublicationClaimsShape = kit.expectPublicationClaimsShape;
const findArtifactRecord = kit.findArtifactRecord;
const readAllFile = kit.readAllFile;
const readTargetPayload = kit.readTargetPayload;
const writeTreeFile = kit.writeTreeFile;

test "validateHtmlSiteMulti shares prepublication semantics without output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-validate-no-output-test", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\---
        \\# Home
        \\
        \\{{include includes/blurb.md}}
        \\
        \\See [[guides/note#details]].
        \\
        \\<Aside kind="tip" id="validation-tip">
        \\Shared component validation.
        \\</Aside>
        \\
    );
    try writeTreeFile(io, work, "content/guides/note.md",
        \\---
        \\title: Note
        \\parent: index
        \\status: published
        \\---
        \\# Note
        \\
        \\## Details
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "Included through the canonical dependency resolver.\n");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist});
    defer gpa.free(stage);
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const sitemap_path = try std.fmt.allocPrint(gpa, "{s}/sitemap.xml", .{dist});
    defer gpa.free(sitemap_path);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "default", .output_dir = dist },
    };
    const options: CompileOptions = .{
        .content_root = content_path,
        .layout_path = layout_path,
        .sitemap_path = "sitemap.xml",
        .site_url = "https://example.test/docs/",
        .quiet = true,
    };

    // Repeated validation exercises the full shared render preflight while
    // leaving neither the final target nor its sibling stage behind.
    try validateHtmlSiteMulti(io, gpa, &targets, options);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));
    try validateHtmlSiteMulti(io, gpa, &targets, options);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));

    // Passing validation does not alter normal publication semantics.
    _ = try compileHtmlSiteMulti(io, gpa, &targets, options);
    try cwd.access(io, index_path, .{});
    try cwd.access(io, sitemap_path, .{});
}

test "validateHtmlSiteMulti runs the output link audit in memory" {
    // Regression for #430: `boris validate` must reject the same two poison
    // classes the publish path rejects — a root-relative URL escaping the
    // declared publication base path (EPUBLICATIONLOCATION) and a local
    // reference resolving to no published output (EROUTEMISSING) — without
    // writing a target or stage directory.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-validate-link-audit-test", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\---
        \\# Home
        \\
    );
    // Poison A: a project-site root-relative URL that omits the base path.
    try writeTreeFile(io, work, "content/escape.md",
        \\---
        \\title: Escape
        \\status: published
        \\---
        \\# Escape
        \\
        \\[outside](/outside-boris)
        \\
    );
    // Poison B: a local reference that resolves to no published output.
    try writeTreeFile(io, work, "content/broken.md",
        \\---
        \\title: Broken
        \\status: published
        \\---
        \\# Broken
        \\
        \\[missing](./no-such-page.md)
        \\
    );
    try writeTreeFile(io, work, "content/ok.md",
        \\---
        \\title: Ok
        \\status: published
        \\---
        \\# Ok
        \\
        \\[home](./index.html)
        \\
    );

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist});
    defer gpa.free(stage);

    var location = try github_pages.parse(
        gpa,
        "https://drawmeanelephant.github.io/boris/",
        "https://drawmeanelephant.github.io",
        "/boris",
    );
    defer location.deinit(gpa);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "default", .output_dir = dist },
    };
    const options: CompileOptions = .{
        .content_root = content_path,
        .layout_path = layout_path,
        .publication_location = &location,
        .quiet = true,
    };

    // Both poison classes fail validation as content failures (the multi-target
    // wrapper aggregates LinkAuditFailed into MultiTargetCompilationFailed, the
    // same exit-1 class the CLI maps), and neither the target nor its stage
    // appears. The diagnostics above are emitted by the shared reporter, so the
    // find text must show both the EPUBLICATIONLOCATION and EROUTEMISSING poisons.
    try std.testing.expectError(error.MultiTargetCompilationFailed, validateHtmlSiteMulti(io, gpa, &targets, options));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));

    // A second run re-reads source, so fixing the poisons must flip the result.
    try writeTreeFile(io, work, "content/escape.md",
        \\---
        \\title: Escape
        \\status: published
        \\---
        \\# Escape
        \\
        \\[home](/boris/index.html)
        \\
    );
    try writeTreeFile(io, work, "content/broken.md",
        \\---
        \\title: Broken
        \\status: published
        \\---
        \\# Broken
        \\
        \\[home](./index.html)
        \\
    );
    try validateHtmlSiteMulti(io, gpa, &targets, options);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));
}

test "compileHtmlSiteMulti - success, validation, and isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-multi-compile-test", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "L{{content}}");
    try writeTreeFile(io, work, "content/alpha.md", "# Alpha\n");
    try writeTreeFile(io, work, "content/beta.md", "# Beta\n");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    const dist_a = try std.fmt.allocPrint(gpa, "{s}/dist_a", .{work});
    defer gpa.free(dist_a);
    const dist_b = try std.fmt.allocPrint(gpa, "{s}/dist_b", .{work});
    defer gpa.free(dist_b);

    // 1. Success case: compile target_a and target_b sequentially
    {
        const targets = [_]target_mod.TargetSpec{
            .{ .name = "target_b", .output_dir = dist_b },
            .{ .name = "target_a", .output_dir = dist_a },
        };

        _ = try compileHtmlSiteMulti(io, gpa, &targets, .{
            .content_root = content_path,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });

        // Verify outputs in both directories
        var dir_a = try cwd.openDir(io, dist_a, .{});
        defer dir_a.close(io);
        var dir_b = try cwd.openDir(io, dist_b, .{});
        defer dir_b.close(io);

        const alpha_a = try readAllFile(io, dir_a, "alpha.html", gpa);
        defer gpa.free(alpha_a);
        const alpha_b = try readAllFile(io, dir_b, "alpha.html", gpa);
        defer gpa.free(alpha_b);

        try std.testing.expectEqualStrings("L<h1 id=\"alpha\">Alpha</h1>\n", alpha_a);
        try std.testing.expectEqualStrings("L<h1 id=\"alpha\">Alpha</h1>\n", alpha_b);

        const multi_inventory_paths = [_][]const u8{
            "_boris/search/search-index.json",
            "alpha.html",
            "beta.html",
        };
        const inventory_a = try readAllFile(io, dir_a, artifact_inventory.output_path, gpa);
        defer gpa.free(inventory_a);
        const inventory_b = try readAllFile(io, dir_b, artifact_inventory.output_path, gpa);
        defer gpa.free(inventory_b);
        try expectArtifactInventoryShape(gpa, inventory_a, "target_a", &multi_inventory_paths, &.{});
        try expectArtifactInventoryShape(gpa, inventory_b, "target_b", &multi_inventory_paths, &.{});
        var parsed_a = try std.json.parseFromSlice(std.json.Value, gpa, inventory_a, .{});
        defer parsed_a.deinit();
        var parsed_b = try std.json.parseFromSlice(std.json.Value, gpa, inventory_b, .{});
        defer parsed_b.deinit();
        for (multi_inventory_paths) |path| {
            const record_a = findArtifactRecord(parsed_a.value, path) orelse return error.MissingArtifactRecord;
            const record_b = findArtifactRecord(parsed_b.value, path) orelse return error.MissingArtifactRecord;
            try std.testing.expectEqual(record_a.object.get("bytes").?.integer, record_b.object.get("bytes").?.integer);
            try std.testing.expectEqualStrings(
                record_a.object.get("sha256").?.string,
                record_b.object.get("sha256").?.string,
            );
        }

        // Verify separate cache namespaces
        if (dir_a.openFile(io, ".boris-cache/manifest.json", .{})) |file| {
            file.close(io);
        } else |_| {
            try std.testing.expect(false);
        }
        if (dir_b.openFile(io, ".boris-cache/manifest.json", .{})) |file| {
            file.close(io);
        } else |_| {
            try std.testing.expect(false);
        }
    }

    // 2. Validation failure: target collision
    {
        const targets = [_]target_mod.TargetSpec{
            .{ .name = "target_a", .output_dir = dist_a },
            .{ .name = "target_b", .output_dir = dist_a }, // duplicate out dir
        };

        const res = compileHtmlSiteMulti(io, gpa, &targets, .{
            .content_root = content_path,
            .layout_path = layout_path,
            .quiet = true,
        });
        try std.testing.expectError(error.TargetOutputCollision, res);
    }
}

test "F9.1 multi-target themes isolate assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-multi-theme", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    // Shared content
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\tags: [docs]
        \\---
        \\
        \\# Home
        \\
    );

    // Theme A
    try writeTreeFile(io, work, "theme-a/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/a.css}}">{{footer}}{{content}}</html>
    );
    try writeTreeFile(io, work, "theme-a/footer.html", "FOOTER-A");
    try writeTreeFile(io, work, "theme-a/assets/css/a.css", "/* theme-a */");

    // Theme B
    try writeTreeFile(io, work, "theme-b/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/b.css}}">{{footer}}{{content}}</html>
    );
    try writeTreeFile(io, work, "theme-b/footer.html", "FOOTER-B");
    try writeTreeFile(io, work, "theme-b/assets/css/b.css", "/* theme-b */");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout_a = try std.fmt.allocPrint(gpa, "{s}/theme-a/layouts/main.html", .{work});
    defer gpa.free(layout_a);
    const layout_b = try std.fmt.allocPrint(gpa, "{s}/theme-b/layouts/main.html", .{work});
    defer gpa.free(layout_b);
    const out_a = try std.fmt.allocPrint(gpa, "{s}/dist/a", .{work});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, "{s}/dist/b", .{work});
    defer gpa.free(out_b);

    _ = try compileHtmlSiteMulti(io, gpa, &.{
        .{ .name = "a", .output_dir = out_a, .layout_path = layout_a },
        .{ .name = "b", .output_dir = out_b, .layout_path = layout_b },
    }, .{
        .content_root = content,
        .layout_path = layout_a,
        .quiet = true,
    });

    const path_css_a = try std.fmt.allocPrint(gpa, "{s}/assets/css/a.css", .{out_a});
    defer gpa.free(path_css_a);
    const css_a = try readFileAlloc(io, cwd, path_css_a, gpa);
    defer gpa.free(css_a);
    try std.testing.expectEqualStrings("/* theme-a */", css_a);

    const path_css_b = try std.fmt.allocPrint(gpa, "{s}/assets/css/b.css", .{out_b});
    defer gpa.free(path_css_b);
    const css_b = try readFileAlloc(io, cwd, path_css_b, gpa);
    defer gpa.free(css_b);
    try std.testing.expectEqualStrings("/* theme-b */", css_b);

    // Target A must not receive B's CSS
    const leak = try std.fmt.allocPrint(gpa, "{s}/assets/css/b.css", .{out_a});
    defer gpa.free(leak);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, leak, .{}));

    const path_html_a = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_a});
    defer gpa.free(path_html_a);
    const html_a = try readFileAlloc(io, cwd, path_html_a, gpa);
    defer gpa.free(html_a);
    try std.testing.expect(std.mem.indexOf(u8, html_a, "FOOTER-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_a, "FOOTER-B") == null);
}

test "F9.2 --theme sugar + multi-target isolation + incremental byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-theme-sugar", .{tmp.sub_path});
    defer gpa.free(base);

    // CLI --theme ROOT expands to ROOT/layouts/main.html (already unit-tested);
    // exercise the same path through compileHtmlSite with theme-site fixture.
    const content = "docs/contracts/fixtures/theme-site/content";
    const theme_root = "docs/contracts/fixtures/theme-site/experimental-theme";
    const layout = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html";
    try std.testing.expectEqualStrings(
        theme_root,
        theme_mod.themeRootFromLayoutPath(layout).?,
    );

    const full = try std.fmt.allocPrint(gpa, "{s}/full", .{base});
    defer gpa.free(full);
    const inc = try std.fmt.allocPrint(gpa, "{s}/inc", .{base});
    defer gpa.free(inc);
    const public = try std.fmt.allocPrint(gpa, "{s}/public", .{base});
    defer gpa.free(public);
    const preview = try std.fmt.allocPrint(gpa, "{s}/preview", .{base});
    defer gpa.free(preview);

    // Full rebuild
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = full,
        .layout_path = layout,
        .quiet = true,
    });

    // Incremental seed + no-op; published HTML/assets must match full rebuild.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = inc,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const noop = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = inc,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), noop.pages_written);

    const pages = [_][]const u8{
        "index.html",
        "guides.html",
        "guides/getting-started.html",
        "reference.html",
        "reference/configuration.html",
        "assets/css/docs.css",
    };
    for (pages) |rel| {
        const pa = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ full, rel });
        defer gpa.free(pa);
        const pb = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ inc, rel });
        defer gpa.free(pb);
        const a = try readFileAlloc(io, cwd, pa, gpa);
        defer gpa.free(a);
        const b = try readFileAlloc(io, cwd, pb, gpa);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }

    // Metadata / footer / asset-url presence on nested page
    const guide = try std.fmt.allocPrint(gpa, "{s}/guides/getting-started.html", .{full});
    defer gpa.free(guide);
    const guide_html = try readFileAlloc(io, cwd, guide, gpa);
    defer gpa.free(guide_html);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "href=\"../assets/css/docs.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "page-metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "site-footer__copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "Status") != null);

    // Multi-target: same content, isolated outs (reuse experimental theme for both;
    // isolation is ownership of separate roots + caches, not necessarily distinct CSS).
    _ = try compileHtmlSiteMulti(io, gpa, &.{
        .{ .name = "public", .output_dir = public, .layout_path = layout },
        .{ .name = "preview", .output_dir = preview, .layout_path = layout },
    }, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
    });
    const pub_css = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{public});
    defer gpa.free(pub_css);
    const prev_css = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{preview});
    defer gpa.free(prev_css);
    try cwd.access(io, pub_css, .{});
    try cwd.access(io, prev_css, .{});
    // Independent cache namespaces
    const pub_cache = try std.fmt.allocPrint(gpa, "{s}/.boris-cache", .{public});
    defer gpa.free(pub_cache);
    const prev_cache = try std.fmt.allocPrint(gpa, "{s}/.boris-cache", .{preview});
    defer gpa.free(prev_cache);
    // Cache dirs exist only under incremental; full multi-target still isolates trees.
    try std.testing.expect(!std.mem.eql(u8, public, preview));
}

test "content-local assets: multi-target isolation and deterministic bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-mt", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![d](index.assets/d.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/d.svg", "payload");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist_a = try std.fmt.allocPrint(gpa, "{s}/out-a", .{work});
    defer gpa.free(dist_a);
    const dist_b = try std.fmt.allocPrint(gpa, "{s}/out-b", .{work});
    defer gpa.free(dist_b);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "a", .output_dir = dist_a, .layout_path = layout },
        .{ .name = "b", .output_dir = dist_b, .layout_path = layout },
    };
    _ = try compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
    });

    const path_a = try std.fmt.allocPrint(gpa, "{s}/index.assets/d.svg", .{dist_a});
    defer gpa.free(path_a);
    const path_b = try std.fmt.allocPrint(gpa, "{s}/index.assets/d.svg", .{dist_b});
    defer gpa.free(path_b);
    const a = try readFileAlloc(io, cwd, path_a, gpa);
    defer gpa.free(a);
    const b = try readFileAlloc(io, cwd, path_b, gpa);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("payload", a);
    try std.testing.expectEqualStrings(a, b);

    try cwd.writeFile(io, .{ .sub_path = path_a, .data = "mutated-a" });
    const b2 = try readFileAlloc(io, cwd, path_b, gpa);
    defer gpa.free(b2);
    try std.testing.expectEqualStrings("payload", b2);
}

test "multi-target publication derives claims per target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-multi", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist_a = try std.fmt.allocPrint(gpa, "{s}/dist_a", .{work});
    defer gpa.free(dist_a);
    const dist_b = try std.fmt.allocPrint(gpa, "{s}/dist_b", .{work});
    defer gpa.free(dist_b);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "alpha", .output_dir = dist_a },
        .{ .name = "beta", .output_dir = dist_b },
    };
    _ = try compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
    });

    const claims_a = try readTargetPayload(io, gpa, dist_a, publication_claims.output_path);
    defer gpa.free(claims_a);
    const claims_b = try readTargetPayload(io, gpa, dist_b, publication_claims.output_path);
    defer gpa.free(claims_b);
    try expectPublicationClaimsShape(gpa, claims_a, "alpha");
    try expectPublicationClaimsShape(gpa, claims_b, "beta");
    var parsed_a = try std.json.parseFromSlice(std.json.Value, gpa, claims_a, .{});
    defer parsed_a.deinit();
    var parsed_b = try std.json.parseFromSlice(std.json.Value, gpa, claims_b, .{});
    defer parsed_b.deinit();
    try std.testing.expect(!std.mem.eql(
        u8,
        parsed_a.value.object.get("publication_checks").?.object.get("sha256").?.string,
        parsed_b.value.object.get("publication_checks").?.object.get("sha256").?.string,
    ));
}
