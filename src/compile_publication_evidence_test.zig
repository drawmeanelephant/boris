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
const CompileOptions = compile.CompileOptions;
const compileHtmlSite = compile.compileHtmlSite;
const publishPathsEqual = compile.publishPathsEqual;
const publishStageTree = compile.publishStageTree;
const writePublicationChecksFailure = compile.writePublicationChecksFailure;

const kit = @import("compile_test_kit.zig");

const expectArtifactInventoryShape = kit.expectArtifactInventoryShape;
const expectArtifactRecord = kit.expectArtifactRecord;
const expectPublicationChecksShape = kit.expectPublicationChecksShape;
const expectPublicationClaimsShape = kit.expectPublicationClaimsShape;
const findArtifactRecord = kit.findArtifactRecord;
const readAllFile = kit.readAllFile;
const readArtifactInventory = kit.readArtifactInventory;
const readTargetPayload = kit.readTargetPayload;
const writeTreeFile = kit.writeTreeFile;

test "artifact inventory replacement is last during a failed target commit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "stage/_boris/proof");
    try tmp.dir.createDirPath(io, "final/_boris/proof");
    try tmp.dir.createDirPath(io, "final/index.html/block");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.html", .data = "new page" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/_boris/proof/artifacts.json", .data = "new inventory" });
    try tmp.dir.writeFile(io, .{ .sub_path = "final/_boris/proof/artifacts.json", .data = "old inventory" });
    try tmp.dir.writeFile(io, .{ .sub_path = "final/index.html/block/keep.txt", .data = "keep" });

    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);
    var final = try tmp.dir.openDir(io, "final", .{ .iterate = true });
    defer final.close(io);

    var failed = false;
    publishStageTree(io, gpa, stage, final, artifact_inventory.output_path) catch {
        failed = true;
    };
    try std.testing.expect(failed);

    const inventory = try readAllFile(io, final, artifact_inventory.output_path, gpa);
    defer gpa.free(inventory);
    try std.testing.expectEqualStrings("old inventory", inventory);
    const staged_inventory = try readAllFile(io, stage, artifact_inventory.output_path, gpa);
    defer gpa.free(staged_inventory);
    try std.testing.expectEqualStrings("new inventory", staged_inventory);
}

test "deferred publication paths compare across host separators" {
    try std.testing.expect(publishPathsEqual(
        "_boris/proof/artifacts.json",
        "_boris/proof/artifacts.json",
    ));
    try std.testing.expect(publishPathsEqual(
        "_boris\\proof\\artifacts.json",
        "_boris/proof/artifacts.json",
    ));
    try std.testing.expect(!publishPathsEqual(
        "_boris/proof/other.json",
        "_boris/proof/artifacts.json",
    ));
}

test "HTML publication artifact inventory is complete, deterministic, isolated, and transactional" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-artifacts", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "themes/docs/layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "themes/docs/assets/css/site.css", "body{color:red}");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "content/guides/child.md", "# Child\n\nNested page.\n");
    try writeTreeFile(io, work, "content/index.assets/diagram.txt", "diagram-v1");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/themes/docs/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const parallel_dist = try std.fmt.allocPrint(gpa, "{s}/parallel", .{work});
    defer gpa.free(parallel_dist);
    const plain_dist = try std.fmt.allocPrint(gpa, "{s}/plain", .{work});
    defer gpa.free(plain_dist);

    const deployment_owned = try std.fmt.allocPrint(gpa, "{s}/deployment-owned.txt", .{dist});
    defer gpa.free(deployment_owned);
    try writeTreeFile(io, work, "dist/deployment-owned.txt", "deployment-owned");

    const child_source = try std.fmt.allocPrint(gpa, "{s}/guides/child.md", .{content});
    defer gpa.free(child_source);
    const asset_source = try std.fmt.allocPrint(gpa, "{s}/index.assets/diagram.txt", .{content});
    defer gpa.free(asset_source);
    const stale_child = try std.fmt.allocPrint(gpa, "{s}/guides/child.html", .{dist});
    defer gpa.free(stale_child);
    const stale_asset = try std.fmt.allocPrint(gpa, "{s}/index.assets/diagram.txt", .{dist});
    defer gpa.free(stale_asset);

    const with_sitemap = [_][]const u8{
        "assets/css/site.css",
        "guides/child.html",
        "index.assets/diagram.txt",
        "index.html",
        "_boris/search/search-index.json",
        "meta/discovery.xml",
    };
    const without_sitemap = [_][]const u8{
        "assets/css/site.css",
        "index.html",
        "_boris/search/search-index.json",
    };
    const no_absent_paths = [_][]const u8{};

    const base_options: CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
        .sitemap_path = "meta/discovery.xml",
        .site_url = "https://example.test/docs",
    };
    _ = try compileHtmlSite(io, gpa, base_options);

    var inventory_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(inventory_bytes);
    try expectArtifactInventoryShape(gpa, inventory_bytes, "default", &with_sitemap, &no_absent_paths);
    try std.testing.expect(std.mem.indexOf(u8, inventory_bytes, artifact_inventory.output_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, inventory_bytes, work) == null);

    var checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    try expectPublicationChecksShape(gpa, checks_bytes, "default");
    const first_checks = try gpa.dupe(u8, checks_bytes);
    defer gpa.free(first_checks);

    var checks_failure_options = base_options;
    checks_failure_options.test_fail_publication_checks = true;
    checks_failure_options.refresh_evidence = true;
    try std.testing.expectError(
        error.PublicationChecksFailed,
        compileHtmlSite(io, gpa, checks_failure_options),
    );
    const after_checks_failure = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(after_checks_failure);
    try std.testing.expectEqualStrings(first_checks, after_checks_failure);

    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inventory_bytes, .{});
        defer parsed.deinit();
        const page = try readTargetPayload(io, gpa, dist, "index.html");
        defer gpa.free(page);
        try expectArtifactRecord(parsed.value, "index.html", "html-page", "html-render", page);
        const child = try readTargetPayload(io, gpa, dist, "guides/child.html");
        defer gpa.free(child);
        try expectArtifactRecord(parsed.value, "guides/child.html", "html-page", "html-render", child);
        const theme = try readTargetPayload(io, gpa, dist, "assets/css/site.css");
        defer gpa.free(theme);
        try expectArtifactRecord(parsed.value, "assets/css/site.css", "theme-asset", "theme-assets", theme);
        const content_asset_bytes = try readTargetPayload(io, gpa, dist, "index.assets/diagram.txt");
        defer gpa.free(content_asset_bytes);
        try expectArtifactRecord(parsed.value, "index.assets/diagram.txt", "content-asset", "content-assets", content_asset_bytes);
        const search = try readTargetPayload(io, gpa, dist, search_index.output_path);
        defer gpa.free(search);
        try expectArtifactRecord(parsed.value, search_index.output_path, "rendered-search", "rendered-search", search);
        const sitemap_bytes = try readTargetPayload(io, gpa, dist, "meta/discovery.xml");
        defer gpa.free(sitemap_bytes);
        try expectArtifactRecord(parsed.value, "meta/discovery.xml", "sitemap", "sitemap", sitemap_bytes);
    }

    const first_inventory = try gpa.dupe(u8, inventory_bytes);
    defer gpa.free(first_inventory);
    _ = try compileHtmlSite(io, gpa, base_options);
    const repeat_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(repeat_inventory);
    try std.testing.expectEqualStrings(first_inventory, repeat_inventory);
    gpa.free(checks_bytes);
    checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    try std.testing.expectEqualStrings(first_checks, checks_bytes);

    var parallel_options = base_options;
    parallel_options.dist_dir = parallel_dist;
    parallel_options.jobs = 4;
    _ = try compileHtmlSite(io, gpa, parallel_options);
    const parallel_inventory = try readArtifactInventory(io, gpa, parallel_dist);
    defer gpa.free(parallel_inventory);
    try std.testing.expectEqualStrings(first_inventory, parallel_inventory);
    const parallel_checks = try readTargetPayload(io, gpa, parallel_dist, publication_checks.output_path);
    defer gpa.free(parallel_checks);
    try std.testing.expectEqualStrings(first_checks, parallel_checks);

    var old_index_digest: [64]u8 = undefined;
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inventory_bytes, .{});
        defer parsed.deinit();
        const old_record = findArtifactRecord(parsed.value, "index.html") orelse return error.MissingArtifactRecord;
        const old_digest = old_record.object.get("sha256").?.string;
        try std.testing.expectEqual(@as(usize, 64), old_digest.len);
        @memcpy(old_index_digest[0..], old_digest);
    }

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged body.\n");
    _ = try compileHtmlSite(io, gpa, base_options);
    const changed_inventory = try readArtifactInventory(io, gpa, dist);
    try expectArtifactInventoryShape(gpa, changed_inventory, "default", &with_sitemap, &no_absent_paths);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, changed_inventory, .{});
        defer parsed.deinit();
        const changed_record = findArtifactRecord(parsed.value, "index.html") orelse return error.MissingArtifactRecord;
        try std.testing.expect(!std.mem.eql(u8, &old_index_digest, changed_record.object.get("sha256").?.string));
        const child = try readTargetPayload(io, gpa, dist, "guides/child.html");
        defer gpa.free(child);
        try expectArtifactRecord(parsed.value, "guides/child.html", "html-page", "html-render", child);
        const theme = try readTargetPayload(io, gpa, dist, "assets/css/site.css");
        defer gpa.free(theme);
        try expectArtifactRecord(parsed.value, "assets/css/site.css", "theme-asset", "theme-assets", theme);
        const content_asset_bytes = try readTargetPayload(io, gpa, dist, "index.assets/diagram.txt");
        defer gpa.free(content_asset_bytes);
        try expectArtifactRecord(parsed.value, "index.assets/diagram.txt", "content-asset", "content-assets", content_asset_bytes);
    }
    gpa.free(inventory_bytes);
    inventory_bytes = changed_inventory;

    const before_failure = try gpa.dupe(u8, inventory_bytes);
    defer gpa.free(before_failure);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nFailed transaction body.\n");
    var inventory_failure_options = base_options;
    inventory_failure_options.test_fail_before_inventory_write = true;
    try std.testing.expectError(
        error.TestInjectedInventoryWriteFailure,
        compileHtmlSite(io, gpa, inventory_failure_options),
    );
    const after_inventory_failure = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(after_inventory_failure);
    try std.testing.expectEqualStrings(before_failure, after_inventory_failure);

    var sitemap_failure_options = base_options;
    sitemap_failure_options.test_fail_after_sitemap_stage = true;
    try std.testing.expectError(
        error.TestInjectedSitemapFailure,
        compileHtmlSite(io, gpa, sitemap_failure_options),
    );
    const after_sitemap_failure = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(after_sitemap_failure);
    try std.testing.expectEqualStrings(before_failure, after_sitemap_failure);

    try cwd.deleteFile(io, child_source);
    try cwd.deleteFile(io, asset_source);
    _ = try compileHtmlSite(io, gpa, base_options);
    const pruned_inventory = try readArtifactInventory(io, gpa, dist);
    try expectArtifactInventoryShape(
        gpa,
        pruned_inventory,
        "default",
        &[_][]const u8{
            "assets/css/site.css",
            "index.html",
            "_boris/search/search-index.json",
            "meta/discovery.xml",
        },
        &[_][]const u8{ "guides/child.html", "index.assets/diagram.txt" },
    );
    gpa.free(inventory_bytes);
    inventory_bytes = pruned_inventory;
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_child, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_asset, .{}));
    try cwd.access(io, deployment_owned, .{});

    var plain_options = base_options;
    plain_options.dist_dir = plain_dist;
    plain_options.sitemap_path = null;
    plain_options.site_url = null;
    _ = try compileHtmlSite(io, gpa, plain_options);
    const plain_inventory = try readArtifactInventory(io, gpa, plain_dist);
    defer gpa.free(plain_inventory);
    try expectArtifactInventoryShape(
        gpa,
        plain_inventory,
        "default",
        &without_sitemap,
        &[_][]const u8{"meta/discovery.xml"},
    );
}

test "Pages publication location mismatches fail before target replacement" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pages-location-gate", .{tmp.sub_path});
    defer gpa.free(work);
    try writeTreeFile(io, work, "layout.html", "<html><head><link rel=\"canonical\" href=\"/boris/index.html\"></head><body><a href=\"/assets/theme.css\">asset</a>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layout.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    try writeTreeFile(io, work, "dist/sentinel.txt", "previous target");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    try std.testing.expectError(error.LinkAuditFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .publication_location = &location,
    }));
    const sentinel_after_link_failure = try readTargetPayload(io, gpa, dist, "sentinel.txt");
    defer gpa.free(sentinel_after_link_failure);
    try std.testing.expectEqualStrings("previous target", sentinel_after_link_failure);
    try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, "index.html"));

    try std.testing.expectError(error.PublicationLocationMismatch, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .sitemap_path = "sitemap.xml",
        .site_url = "https://owner.github.io",
        .publication_location = &location,
    }));
    const sentinel_after_sitemap_failure = try readTargetPayload(io, gpa, dist, "sentinel.txt");
    defer gpa.free(sentinel_after_sitemap_failure);
    try std.testing.expectEqualStrings("previous target", sentinel_after_sitemap_failure);
    try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, "index.html"));
}

test "Pages publication location fixture covers all site shapes and poisoned metadata" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixture = "docs/contracts/fixtures/publication-location";
    const content = "docs/contracts/fixtures/publication-location/content";
    const layout = "docs/contracts/fixtures/publication-location/theme/layouts/main.html";
    const shapes = [_]struct {
        base_url: []const u8,
        origin: []const u8,
        base_path: []const u8,
    }{
        .{ .base_url = "https://owner.github.io/boris", .origin = "https://owner.github.io", .base_path = "/boris" },
        .{ .base_url = "https://owner.github.io", .origin = "https://owner.github.io", .base_path = "" },
        .{ .base_url = "https://docs.example.com", .origin = "https://docs.example.com", .base_path = "" },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (shapes, 0..) |shape, index| {
        const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/valid-{d}", .{ tmp.sub_path, index });
        defer gpa.free(dist);
        var location = try github_pages.parse(gpa, shape.base_url, shape.origin, shape.base_path);
        defer location.deinit(gpa);
        _ = try compileHtmlSite(io, gpa, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout,
            .quiet = true,
            .sitemap_path = "sitemap.xml",
            .site_url = shape.base_url,
            .publication_location = &location,
        });

        const index_html = try readTargetPayload(io, gpa, dist, "index.html");
        defer gpa.free(index_html);
        const nested_html = try readTargetPayload(io, gpa, dist, "guides/start.html");
        defer gpa.free(nested_html);
        const sitemap_bytes = try readTargetPayload(io, gpa, dist, "sitemap.xml");
        defer gpa.free(sitemap_bytes);
        const search_bytes = try readTargetPayload(io, gpa, dist, "_boris/search/search-index.json");
        defer gpa.free(search_bytes);
        const expected_index = try std.fmt.allocPrint(gpa, "<loc>{s}/index.html</loc>", .{shape.base_url});
        defer gpa.free(expected_index);
        const expected_nested = try std.fmt.allocPrint(gpa, "<loc>{s}/guides/start.html</loc>", .{shape.base_url});
        defer gpa.free(expected_nested);

        try std.testing.expect(std.mem.indexOf(u8, index_html, "index.assets/logo.svg") != null);
        try std.testing.expect(std.mem.indexOf(u8, nested_html, "../assets/css/site.css") != null);
        try std.testing.expect(std.mem.indexOf(u8, nested_html, "start.assets/diagram.svg") != null);
        try std.testing.expect(std.mem.indexOf(u8, sitemap_bytes, expected_index) != null);
        try std.testing.expect(std.mem.indexOf(u8, sitemap_bytes, expected_nested) != null);
        try std.testing.expect(std.mem.indexOf(u8, search_bytes, "guides/start.html") != null);
        try std.testing.expect(std.mem.indexOf(u8, sitemap_bytes, "index.assets") == null);
    }

    const poisoned = [_]struct {
        layout_path: []const u8,
        base_url: []const u8,
        origin: []const u8,
        base_path: []const u8,
    }{
        .{
            .layout_path = fixture ++ "/poisoned/project-root-relative.html",
            .base_url = "https://owner.github.io/boris",
            .origin = "https://owner.github.io",
            .base_path = "/boris",
        },
        .{
            .layout_path = fixture ++ "/poisoned/wrong-origin.html",
            .base_url = "https://owner.github.io/boris",
            .origin = "https://owner.github.io",
            .base_path = "/boris",
        },
        .{
            .layout_path = fixture ++ "/poisoned/stale-root-prefix.html",
            .base_url = "https://owner.github.io",
            .origin = "https://owner.github.io",
            .base_path = "",
        },
        .{
            .layout_path = fixture ++ "/poisoned/custom-github-origin.html",
            .base_url = "https://docs.example.com",
            .origin = "https://docs.example.com",
            .base_path = "",
        },
    };
    for (poisoned, 0..) |case, index| {
        const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/poisoned-{d}", .{ tmp.sub_path, index });
        defer gpa.free(work);
        const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
        defer gpa.free(dist);
        try writeTreeFile(io, work, "dist/sentinel.txt", "previous target");
        var location = try github_pages.parse(gpa, case.base_url, case.origin, case.base_path);
        defer location.deinit(gpa);
        try std.testing.expectError(error.LinkAuditFailed, compileHtmlSite(io, gpa, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = case.layout_path,
            .quiet = true,
            .publication_location = &location,
        }));
        const sentinel = try readTargetPayload(io, gpa, dist, "sentinel.txt");
        defer gpa.free(sentinel);
        try std.testing.expectEqualStrings("previous target", sentinel);
        try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, "index.html"));
    }
}

test "quiet publication-check failure diagnostic is captured with the committed-target wording" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePublicationChecksFailure(&output.writer, "public", error.CheckerExecutionFailed);
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'public', but publication-check evidence was not refreshed: CheckerExecutionFailed\n",
        output.writer.buffered(),
    );
}

test "ordinary Doctor findings do not fail HTML publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ordinary-publication-finding", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nOrdinary content finding.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body><div id=duplicate></div><span id=duplicate></span>{{content}}</body></html>");
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
    const inventory_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(inventory_bytes);
    const page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(page);
    var inventory = try std.json.parseFromSlice(std.json.Value, gpa, inventory_bytes, .{});
    defer inventory.deinit();
    try expectArtifactRecord(inventory.value, "index.html", "html-page", "html-render", page);

    const checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    var checks = try std.json.parseFromSlice(std.json.Value, gpa, checks_bytes, .{});
    defer checks.deinit();
    const root = checks.value.object;
    const check_list = root.get("checks").?.array.items;
    try std.testing.expectEqualStrings("failed", check_list[1].object.get("status").?.string);
    try std.testing.expectEqualStrings("complete", check_list[1].object.get("coverage").?.string);
    var found_duplicate = false;
    for (root.get("findings").?.array.items) |finding| {
        if (std.mem.eql(u8, finding.object.get("code").?.string, "HTML_DUPLICATE_ID")) found_duplicate = true;
    }
    try std.testing.expect(found_duplicate);
}

test "post-commit checker failure preserves stale checks while exposing changed payload and inventory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/stale-publication-checks", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(old_page);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");
    var failure_options = options;
    failure_options.test_fail_publication_checks = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, failure_options));

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(new_page);
    try std.testing.expectEqualStrings(old_checks, new_checks);
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_page, new_page));
    var old_report = try std.json.parseFromSlice(std.json.Value, gpa, old_checks, .{});
    defer old_report.deinit();
    const old_binding = old_report.value.object.get("artifact_inventory").?.object.get("sha256").?.string;
    const new_digest = cache.hexDigest(cache.hashBytes(new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_binding, &new_digest));
}

// ---------------------------------------------------------------------------
// Publication claims integration.
// ---------------------------------------------------------------------------

test "claims evidence follows checks on every committed publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-fresh", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const claims_bytes = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(claims_bytes);
    try expectPublicationClaimsShape(gpa, claims_bytes, "default");

    const checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    const checks_digest = cache.hexDigest(cache.hashBytes(checks_bytes));
    var claims = try std.json.parseFromSlice(std.json.Value, gpa, claims_bytes, .{});
    defer claims.deinit();
    try std.testing.expectEqualStrings(
        &checks_digest,
        claims.value.object.get("publication_checks").?.object.get("sha256").?.string,
    );
    try std.testing.expectEqual(@as(i64, 3), claims.value.object.get("publication_checks").?.object.get("check_count").?.integer);

    const artifacts_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(artifacts_bytes);
    const artifacts_digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    try std.testing.expectEqualStrings(
        &artifacts_digest,
        claims.value.object.get("artifact_inventory").?.object.get("sha256").?.string,
    );

    _ = try compileHtmlSite(io, gpa, options);
    const repeat_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(repeat_claims);
    try std.testing.expectEqualStrings(claims_bytes, repeat_claims);
}

test "claims failure preserves committed payloads, inventory, checks, and prior claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(old_page);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");
    var failure_options = options;
    failure_options.test_fail_publication_claims = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationClaimsFailed, compileHtmlSite(io, gpa, failure_options));

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(new_page);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expectEqualStrings(old_claims, new_claims);
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_checks, new_checks));
    try std.testing.expect(!std.mem.eql(u8, old_page, new_page));
    var stale_claims = try std.json.parseFromSlice(std.json.Value, gpa, new_claims, .{});
    defer stale_claims.deinit();
    const stale_binding = stale_claims.value.object.get("publication_checks").?.object.get("sha256").?.string;
    const fresh_checks_digest = cache.hexDigest(cache.hashBytes(new_checks));
    try std.testing.expect(!std.mem.eql(u8, stale_binding, &fresh_checks_digest));
}

test "claims write failure preserves the prior claims report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-write-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    var failure_options = options;
    failure_options.test_fail_publication_claims_write = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationClaimsFailed, compileHtmlSite(io, gpa, failure_options));
    const after = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(old_claims, after);
}

test "quiet claims failure emits the captured diagnostic and preserves prior claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-captured-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");

    // The diagnostic is emitted even under --quiet; capture it instead of the
    // process stderr and prove the exact committed-target wording.
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_publication_claims = true;
    failure_options.refresh_evidence = true;
    failure_options.publication_claims_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationClaimsFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but publication-claims evidence was not refreshed: InvalidChecksReport\n",
        output.writer.buffered(),
    );

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_checks, new_checks));
    try std.testing.expectEqualStrings(old_claims, new_claims);
}

test "touches evidence follows claims on every committed publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-fresh", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const touches_bytes = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(touches_bytes);
    var touches = try std.json.parseFromSlice(std.json.Value, gpa, touches_bytes, .{});
    defer touches.deinit();
    try std.testing.expectEqualStrings(publication_touches.report_format, touches.value.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, publication_touches.schema_version), touches.value.object.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("default", touches.value.object.get("target").?.string);
    // The clean single-page site still carries the fixed registries: 1 target
    // + artifacts + 3 checks + 3 claims + 6 limitations.
    const node_count = touches.value.object.get("nodes").?.array.items.len;
    try std.testing.expect(node_count >= 1 + 3 + 3 + 6);

    const checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    const checks_digest = cache.hexDigest(cache.hashBytes(checks_bytes));
    try std.testing.expectEqualStrings(
        &checks_digest,
        touches.value.object.get("inputs").?.object.get("checks").?.object.get("sha256").?.string,
    );

    const artifacts_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(artifacts_bytes);
    const artifacts_digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    try std.testing.expectEqualStrings(
        &artifacts_digest,
        touches.value.object.get("inputs").?.object.get("artifacts").?.object.get("sha256").?.string,
    );

    _ = try compileHtmlSite(io, gpa, options);
    const repeat_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(repeat_touches);
    try std.testing.expectEqualStrings(touches_bytes, repeat_touches);
}

test "touches failure preserves committed payloads, inventory, checks, claims, and prior touches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);
    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(old_page);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");
    var failure_options = options;
    failure_options.test_fail_publication_touches = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationTouchesFailed, compileHtmlSite(io, gpa, failure_options));

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(new_page);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    // Payloads, inventory, checks, and claims all advanced; the prior touches
    // report is preserved byte-for-byte.
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_checks, new_checks));
    try std.testing.expect(!std.mem.eql(u8, old_page, new_page));
    try std.testing.expect(!std.mem.eql(u8, old_claims, new_claims));
    try std.testing.expectEqualStrings(old_touches, new_touches);
}

test "touches write failure preserves the prior touches report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-write-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);
    var failure_options = options;
    failure_options.test_fail_publication_touches_write = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationTouchesFailed, compileHtmlSite(io, gpa, failure_options));
    const after = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(old_touches, after);
}

test "quiet touches failure emits the captured diagnostic and preserves prior touches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-captured-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");

    // The diagnostic is emitted even under --quiet; capture it instead of the
    // process stderr and prove the exact committed-target wording.
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_publication_touches = true;
    failure_options.refresh_evidence = true;
    failure_options.publication_touches_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationTouchesFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but the Touch Atlas was not refreshed: InvalidClaimsReport\n",
        output.writer.buffered(),
    );

    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    try std.testing.expectEqualStrings(old_touches, new_touches);
}

test "quiet proof-pack failure emits the captured not-refreshed diagnostic and preserves all four evidence reports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-proof-pack-captured-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);
    const old_json = try readTargetPayload(io, gpa, dist, publication_proof_pack.output_path);
    defer gpa.free(old_json);
    const old_html = try readTargetPayload(io, gpa, dist, publication_proof_pack.index_output_path);
    defer gpa.free(old_html);

    // The diagnostic is emitted even under --quiet; capture it instead of the
    // process stderr and prove the exact committed-target wording. main.zig's
    // mapHtmlError maps PublicationProofPackFailed to exit 3 (io_error).
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_publication_proof_pack = true;
    failure_options.refresh_evidence = true;
    failure_options.publication_proof_pack_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationProofPackFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but Proof Pack presentation was not refreshed: InvalidTouchesReport\n",
        output.writer.buffered(),
    );

    // The execution fault fires before any presentation write, so all four
    // evidence reports and the prior pair are byte-unchanged.
    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    try std.testing.expectEqualStrings(old_inventory, new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    try std.testing.expectEqualStrings(old_checks, new_checks);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expectEqualStrings(old_claims, new_claims);
    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    try std.testing.expectEqualStrings(old_touches, new_touches);
    const new_json = try readTargetPayload(io, gpa, dist, publication_proof_pack.output_path);
    defer gpa.free(new_json);
    try std.testing.expectEqualStrings(old_json, new_json);
    const new_html = try readTargetPayload(io, gpa, dist, publication_proof_pack.index_output_path);
    defer gpa.free(new_html);
    try std.testing.expectEqualStrings(old_html, new_html);
}

test "proof-pack restore failure surfaces the recovery-failed diagnostic and preserves all four evidence reports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-proof-pack-restore-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);

    // Install HTML first, then fail its restoration: the rollback cannot
    // restore the preserved HTML, so RestoreHtmlFailed propagates and the
    // contract's recovery-failed diagnostic is emitted (even under --quiet).
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_proof_pack_install_html = true;
    failure_options.test_fail_proof_pack_restore_html = true;
    failure_options.publication_proof_pack_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationProofPackFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but Proof Pack presentation recovery failed; the current pair may be split or absent: RestoreHtmlFailed\n",
        output.writer.buffered(),
    );

    // Even when rollback itself fails, the four evidence reports committed
    // before the presentation transaction are byte-unchanged.
    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    try std.testing.expectEqualStrings(old_inventory, new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    try std.testing.expectEqualStrings(old_checks, new_checks);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expectEqualStrings(old_claims, new_claims);
    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    try std.testing.expectEqualStrings(old_touches, new_touches);
}
