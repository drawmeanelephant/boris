//! Deterministic XML Sitemap Protocol projection for published Boris HTML.

const std = @import("std");
const github_pages = @import("github_pages.zig");
const publication_location = @import("publication_location.zig");
const site_url = @import("site_url.zig");
const structured_out = @import("structured_out.zig");

const Sink = structured_out.Sink;

pub const default_output_path = "sitemap.xml";
pub const max_urls: usize = 50_000;
pub const max_uncompressed_bytes: usize = 50 * 1024 * 1024;

pub const Error = error{
    InvalidSitemapPath,
    SitemapOutputCollision,
    SitemapDuplicateUrl,
    SitemapUrlLimitExceeded,
    SitemapSizeLimitExceeded,
    SitemapPageMissing,
};

fn isPathPrefix(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or
        (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/');
}

/// Sitemap paths are target-root-relative file paths. Boris's cache and search
/// namespaces remain compiler-owned and cannot be repurposed.
pub fn validateOutputPath(path: []const u8) Error!void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return error.InvalidSitemapPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidSitemapPath;
    if (std.fs.path.isAbsolute(path) or path[0] == '/' or path[path.len - 1] == '/') return error.InvalidSitemapPath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidSitemapPath;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidSitemapPath;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidSitemapPath;
        }
    }

    if (isPathPrefix(path, ".boris-cache") or isPathPrefix(path, "_boris/search") or
        isPathPrefix(".boris-cache", path) or isPathPrefix("_boris/search", path))
    {
        return error.SitemapOutputCollision;
    }
}

/// Reject exact and file-vs-directory collisions with every output already
/// owned by pages, theme/content assets, or another structured projection.
pub fn rejectOutputCollisions(
    sitemap_path: []const u8,
    owned_paths: []const []const u8,
) Error!void {
    try validateOutputPath(sitemap_path);
    for (owned_paths) |path| {
        if (isPathPrefix(sitemap_path, path) or isPathPrefix(path, sitemap_path)) {
            return error.SitemapOutputCollision;
        }
    }
}

fn absoluteUrl(
    allocator: std.mem.Allocator,
    normalized_base: []const u8,
    output_path: []const u8,
) ![]u8 {
    var url = Sink.init(allocator);
    errdefer url.deinit();
    try url.rawTrusted("site_url.normalized admits only reviewed ASCII RFC 3986 base bytes", normalized_base);
    try url.lit("/");
    try url.uriPath(output_path);
    return try url.toOwnedSlice();
}

fn urlLess(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Render exactly one XML Sitemap Protocol URL set containing only `<loc>`
/// metadata. `page_paths` must be the final eligible HTML output set.
fn renderWithLimits(
    allocator: std.mem.Allocator,
    raw_site_url: []const u8,
    page_paths: []const []const u8,
    url_limit: usize,
    byte_limit: usize,
) ![]u8 {
    if (page_paths.len > url_limit) return error.SitemapUrlLimitExceeded;
    const normalized_base = try site_url.normalized(allocator, raw_site_url);
    defer allocator.free(normalized_base);

    var urls = try allocator.alloc([]u8, page_paths.len);
    var urls_filled: usize = 0;
    defer {
        for (urls[0..urls_filled]) |url| allocator.free(url);
        allocator.free(urls);
    }
    for (page_paths, 0..) |path, index| {
        urls[index] = try absoluteUrl(allocator, normalized_base, path);
        urls_filled = index + 1;
    }
    std.mem.sort([]u8, urls, {}, urlLess);
    if (urls.len > 1) {
        for (urls[1..], urls[0 .. urls.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current, previous)) return error.SitemapDuplicateUrl;
        }
    }

    var out = Sink.init(allocator);
    errdefer out.deinit();
    try out.lit("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try out.lit("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    for (urls) |url| {
        try out.lit("  <url><loc>");
        try out.field(.xml_text, url);
        try out.lit("</loc></url>\n");
        if (out.items().len > byte_limit) return error.SitemapSizeLimitExceeded;
    }
    try out.lit("</urlset>\n");
    if (out.items().len > byte_limit) return error.SitemapSizeLimitExceeded;
    return try out.toOwnedSlice();
}

pub fn render(
    allocator: std.mem.Allocator,
    raw_site_url: []const u8,
    page_paths: []const []const u8,
) ![]u8 {
    return renderWithLimits(allocator, raw_site_url, page_paths, max_urls, max_uncompressed_bytes);
}

/// Render a sitemap from the normalized publication identity. Each generated
/// `<loc>` is checked as a public URL before the XML is returned, so a future
/// emitter change cannot silently drop a project-site base path.
pub fn renderForLocation(
    allocator: std.mem.Allocator,
    location: *const github_pages.Location,
    page_paths: []const []const u8,
) ![]u8 {
    for (page_paths) |path| {
        const url = try absoluteUrl(allocator, location.base_url, path);
        defer allocator.free(url);
        try publication_location.validatePublicUrl(allocator, location, url);
    }
    return render(allocator, location.base_url, page_paths);
}

fn overlayContains(
    io: std.Io,
    staged_dir: std.Io.Dir,
    live_dir: std.Io.Dir,
    path: []const u8,
) !bool {
    if (staged_dir.openFile(io, path, .{})) |file| {
        file.close(io);
        return true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (live_dir.openFile(io, path, .{})) |file| {
        file.close(io);
        return true;
    } else |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    }
}

/// Verify every selected page exists in the staged/live overlay, then stage the
/// sitemap atomically. The target publisher commits it with the HTML tree.
pub fn writeOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    staged_dir: std.Io.Dir,
    live_dir: std.Io.Dir,
    output_path: []const u8,
    raw_site_url: []const u8,
    page_paths: []const []const u8,
) !void {
    try validateOutputPath(output_path);
    for (page_paths) |path| {
        if (!try overlayContains(io, staged_dir, live_dir, path)) return error.SitemapPageMissing;
    }
    const bytes = try render(allocator, raw_site_url, page_paths);
    defer allocator.free(bytes);

    var atomic = try staged_dir.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.replace(io);
}

test "sitemap XML is declaration-first, namespace-correct, escaped, Unicode-safe, and byte sorted" {
    const rendered = try render(std.testing.allocator, "https://example.test/docs&guides/", &.{
        "zeta.html",
        "index.html",
        "nested/café.html",
    });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://example.test/docs&amp;guides/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "nested/caf%C3%A9.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "index.html").? < std.mem.indexOf(u8, rendered, "zeta.html").?);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "lastmod") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "changefreq") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "priority") == null);
}

test "sitemap rejects duplicate URLs and the protocol URL limit without truncation" {
    try std.testing.expectError(error.SitemapDuplicateUrl, render(
        std.testing.allocator,
        "https://example.test",
        &.{ "same.html", "same.html" },
    ));
    const over = try std.testing.allocator.alloc([]const u8, max_urls + 1);
    defer std.testing.allocator.free(over);
    @memset(over, "index.html");
    try std.testing.expectError(error.SitemapUrlLimitExceeded, render(
        std.testing.allocator,
        "https://example.test",
        over,
    ));
    try std.testing.expectError(error.SitemapSizeLimitExceeded, renderWithLimits(
        std.testing.allocator,
        "https://example.test",
        &.{"index.html"},
        max_urls,
        80,
    ));
}

test "sitemap path validation rejects empty absolute escaping and owned paths" {
    const invalid = [_][]const u8{
        "",
        "/sitemap.xml",
        "../sitemap.xml",
        "nested/../../sitemap.xml",
        "nested/",
        "nested//sitemap.xml",
        "nested\\sitemap.xml",
        ".boris-cache/sitemap.xml",
        "_boris/search/sitemap.xml",
        "_boris",
    };
    for (invalid) |path| {
        try std.testing.expectError(
            if (std.mem.startsWith(u8, path, ".boris-cache") or std.mem.startsWith(u8, path, "_boris"))
                error.SitemapOutputCollision
            else
                error.InvalidSitemapPath,
            validateOutputPath(path),
        );
    }
    try validateOutputPath("meta/discovery.xml");
    try std.testing.expectError(error.SitemapOutputCollision, rejectOutputCollisions(
        "meta/discovery.xml",
        &.{"meta/discovery.xml/index.html"},
    ));
}

test "sitemap publication locations retain project-site prefixes" {
    const pages_location_mod = @import("github_pages.zig");
    var location = try pages_location_mod.parse(
        std.testing.allocator,
        "https://owner.github.io/boris/",
        "https://owner.github.io",
        "/boris/",
    );
    defer location.deinit(std.testing.allocator);
    const rendered = try renderForLocation(std.testing.allocator, &location, &.{ "index.html", "guides/start.html" });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://owner.github.io/boris/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://owner.github.io/boris/guides/start.html") != null);
}
