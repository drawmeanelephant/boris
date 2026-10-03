const std = @import("std");
const compile = @import("compile.zig");
const head = @import("head_metadata.zig");
const kit = @import("compile_test_kit.zig");
const target = @import("target.zig");
const diag = @import("diag.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;
const layout = "<!DOCTYPE html><html><head><title>{{title}}</title>{{head}}</head><body><main data-boris-search-root>{{content}}</main></body></html>";
const article = "---\ntitle: A & B\npublished_at: 2026-10-01T12:30:00Z\nsummary: A <summary>\n---\n# Hello\n";

test "social head: canonical route, metadata precedence, escaping, dates, RSS and draft exclusion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    const out = try std.fmt.allocPrint(a, "{s}/dist", .{root});
    const lp = try std.fmt.allocPrint(a, "{s}/layouts/main.html", .{root});
    try kit.writeTreeFile(io, root, "layouts/main.html", layout);
    try kit.writeTreeFile(io, root, "content/guides/café.md", article);
    try kit.writeTreeFile(io, root, "content/draft.md", "---\nstatus: draft\n---\n# Draft\n");
    try kit.writeTreeFile(io, root, "static/social.png", "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01");
    const overrides = [_]head.Override{.{
        .id = "guides/café",
        .values = .{ .title = "Exact \"title\"", .twitter_card = .summary_large_image },
        .modified_time = "2026-10-02T00:00:00Z",
    }};
    var cfg = head.Declaration{
        .enabled = true,
        .base_url = "https://example.test/project",
        .defaults = .{ .title = "Default", .description = "Default description", .image = .{ .source = .static, .path = "social.png", .alt = "A \"picture\"" } },
        .pages = @constCast(&overrides),
    };
    var options = compile.CompileOptions{
        .content_root = content,
        .dist_dir = out,
        .layout_path = lp,
        .static_dir = try std.fmt.allocPrint(a, "{s}/static", .{root}),
        .head = &cfg,
        .feed = .{ .path = "feeds/rss.xml", .title = "Updates", .description = "News" },
        .incremental = true,
    };
    _ = try compile.compileHtmlSite(io, gpa, options);
    const html = try kit.readTargetPayload(io, a, out, "guides/café.html");
    try std.testing.expect(std.mem.indexOf(u8, html, "rel=\"canonical\" href=\"https://example.test/project/guides/caf%C3%A9.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "property=\"og:url\" content=\"https://example.test/project/guides/caf%C3%A9.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "property=\"og:title\" content=\"Exact &quot;title&quot;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"description\" content=\"A &lt;summary&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "property=\"article:published_time\" content=\"2026-10-01T12:30:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "property=\"article:modified_time\" content=\"2026-10-02T00:00:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"twitter:card\" content=\"summary_large_image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"application/rss+xml\" href=\"https://example.test/project/feeds/rss.xml\"") != null);
    const draft = try kit.readTargetPayload(io, a, out, "draft.html");
    try std.testing.expect(std.mem.indexOf(u8, draft, "canonical") == null);
    try std.testing.expect(std.mem.indexOf(u8, draft, "twitter:") == null);
    const feed = try kit.readTargetPayload(io, a, out, "feeds/rss.xml");
    try std.testing.expect(std.mem.indexOf(u8, feed, "https://example.test/project/guides/caf%C3%A9.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, feed, "draft.html") == null);
    const specs = [_]target.TargetSpec{.{ .name = "default", .output_dir = out, .layout_path = lp, .head = &cfg, .feed = options.feed }};
    try compile.validateHtmlSiteMulti(io, gpa, &specs, options);
    const repeat = try compile.compileHtmlSite(io, gpa, options);
    try std.testing.expectEqual(@as(usize, 0), repeat.pages_written);
    options.jobs = 4;
    options.incremental = false;
    _ = try compile.compileHtmlSite(io, gpa, options);
    try std.testing.expectEqualStrings(html, try kit.readTargetPayload(io, a, out, "guides/café.html"));
    _ = try compile.compileHtmlSite(io, gpa, options);
    try std.testing.expectEqualStrings(html, try kit.readTargetPayload(io, a, out, "guides/café.html"));
    cfg.defaults.description = "Changed fallback";
    cfg.base_url = "https://example.test/changed";
    options.incremental = true;
    _ = try compile.compileHtmlSite(io, gpa, options);
    const changed = try kit.readTargetPayload(io, a, out, "guides/café.html");
    try std.testing.expect(std.mem.indexOf(u8, changed, "https://example.test/changed/guides/caf%C3%A9.html") != null);
    // A missing image fails before staging and preserves the last-good page.
    cfg.defaults.image.?.path = "missing.png";
    try std.testing.expectError(error.HeadImageMissing, compile.compileHtmlSite(io, gpa, options));
    try std.testing.expectEqualStrings(changed, try kit.readTargetPayload(io, a, out, "guides/café.html"));
    cfg.defaults.image.?.path = "social.png";
    options.feed = null;
    _ = try compile.compileHtmlSite(io, gpa, options);
    try std.testing.expectError(error.FileNotFound, kit.readTargetPayload(io, a, out, "feeds/rss.xml"));
}

test "social head: Strict optional omission is visible and required OGP preserves last-good output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const out = try std.fmt.allocPrint(a, "{s}/dist", .{root});
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try kit.writeTreeFile(io, root, "content/index.md", article);
    var cfg: head.Declaration = .{ .enabled = true, .base_url = "https://example.test" };
    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    const options: compile.CompileOptions = .{
        .content_root = content,
        .dist_dir = out,
        .layout_path = "themes/html4-strict/layouts/main.html",
        .output_profile = .html4_strict,
        .head = &cfg,
        .diagnostics = &collector,
    };
    _ = try compile.compileHtmlSite(io, gpa, options);
    const html = try kit.readTargetPayload(io, a, out, "index.html");
    try std.testing.expect(std.mem.indexOf(u8, html, "property=") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"og:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"twitter:card\"") != null);
    try std.testing.expectEqual(diag.Code.WHEADOGP, collector.list.items[0].code);
    cfg.ogp = .required;
    try std.testing.expectError(error.HeadOgpUnsupported, compile.compileHtmlSite(io, gpa, options));
    try std.testing.expectEqualStrings(html, try kit.readTargetPayload(io, a, out, "index.html"));
    try std.testing.expectEqual(diag.Code.EHEAD, collector.list.items[collector.list.items.len - 1].code);
}

test "social head: disabled configuration retains bytes and conflicts fail before publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const out = try std.fmt.allocPrint(a, "{s}/dist", .{root});
    const lp = try std.fmt.allocPrint(a, "{s}/layouts/main.html", .{root});
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try kit.writeTreeFile(io, root, "content/index.md", article);
    try kit.writeTreeFile(io, root, "layouts/main.html", layout);
    var options: compile.CompileOptions = .{ .content_root = content, .dist_dir = out, .layout_path = lp, .incremental = true };
    _ = try compile.compileHtmlSite(io, gpa, options);
    const baseline = try kit.readTargetPayload(io, a, out, "index.html");
    var cfg: head.Declaration = .{ .base_url = "https://example.test" };
    options.head = &cfg;
    try std.testing.expectEqual(@as(usize, 0), (try compile.compileHtmlSite(io, gpa, options)).pages_written);
    try std.testing.expectEqualStrings(baseline, try kit.readTargetPayload(io, a, out, "index.html"));
    cfg.enabled = true;
    try kit.writeTreeFile(io, root, "layouts/main.html", "<head><meta name='description' content='manual'>{{head}}</head><body>{{content}}</body>");
    try std.testing.expectError(error.HeadOwnedTagConflict, compile.compileHtmlSite(io, gpa, options));
    try std.testing.expectEqualStrings(baseline, try kit.readTargetPayload(io, a, out, "index.html"));
    try kit.writeTreeFile(io, root, "layouts/main.html", "<head></head><body>{{head}}{{content}}</body>");
    try std.testing.expectError(error.HeadLayoutInvalid, compile.compileHtmlSite(io, gpa, options));
    try kit.writeTreeFile(io, root, "layouts/main.html", layout);
    try kit.writeTreeFile(io, root, "content/index.md", article ++ "\n<meta name='twitter:card' content='manual'>\n");
    try std.testing.expectError(error.HeadOwnedTagConflict, compile.compileHtmlSite(io, gpa, options));
    try std.testing.expectEqualStrings(baseline, try kit.readTargetPayload(io, a, out, "index.html"));
}

test "social head: target bases, theme inventories and profiles cannot be borrowed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try kit.writeTreeFile(io, root, "content/index.md", article);
    try kit.writeTreeFile(io, root, "themes/one/layouts/main.html", layout);
    try kit.writeTreeFile(io, root, "themes/two/layouts/main.html", layout);
    const svg = "<svg width=\"32\" height=\"32\"></svg>";
    try kit.writeTreeFile(io, root, "themes/one/assets/social.svg", svg);
    try kit.writeTreeFile(io, root, "themes/two/assets/social.svg", svg);
    const one: head.Declaration = .{ .enabled = true, .base_url = "https://one.test/base", .defaults = .{ .image = .{ .source = .theme, .path = "assets/social.svg", .alt = "One" } } };
    const two: head.Declaration = .{ .enabled = true, .base_url = "https://two.test", .defaults = .{ .image = .{ .source = .theme, .path = "assets/social.svg", .alt = "Two" } } };
    const out_one = try std.fmt.allocPrint(a, "{s}/one", .{root});
    const out_two = try std.fmt.allocPrint(a, "{s}/two", .{root});
    const out_local = try std.fmt.allocPrint(a, "{s}/local", .{root});
    const specs = [_]target.TargetSpec{
        .{ .name = "one", .output_dir = out_one, .layout_path = try std.fmt.allocPrint(a, "{s}/themes/one/layouts/main.html", .{root}), .head = &one },
        .{ .name = "two", .output_dir = out_two, .layout_path = try std.fmt.allocPrint(a, "{s}/themes/two/layouts/main.html", .{root}), .head = &two, .html_profile = .xhtml },
        .{ .name = "local", .output_dir = out_local, .layout_path = try std.fmt.allocPrint(a, "{s}/themes/one/layouts/main.html", .{root}) },
    };
    const options: compile.CompileOptions = .{ .content_root = content, .incremental = true, .head = &one };
    _ = try compile.compileHtmlSiteMulti(io, gpa, &specs, options);
    const first = try kit.readTargetPayload(io, a, out_one, "index.html");
    const second = try kit.readTargetPayload(io, a, out_two, "index.html");
    const local = try kit.readTargetPayload(io, a, out_local, "index.html");
    try std.testing.expect(std.mem.indexOf(u8, first, "https://one.test/base/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "https://two.test") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "https://two.test/index.html\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, local, "canonical") == null);
    try std.Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(a, "{s}/themes/two/assets/social.svg", .{root}));
    try std.testing.expectError(error.MultiTargetCompilationFailed, compile.compileHtmlSiteMulti(io, gpa, &specs, options));
    try std.testing.expectEqualStrings(second, try kit.readTargetPayload(io, a, out_two, "index.html"));
}
