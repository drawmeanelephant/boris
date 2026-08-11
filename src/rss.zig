//! Deterministic RSS 2.0 projection of a validated Boris graph.

const std = @import("std");
const Io = std.Io;
const graph = @import("graph.zig");
const github_pages = @import("github_pages.zig");
const identity = @import("identity.zig");
const pipeline = @import("pipeline.zig");
const publication_location = @import("publication_location.zig");
const rss_date = @import("rss_date.zig");
const site_url_mod = @import("site_url.zig");
const structured_out = @import("structured_out.zig");
const target = @import("target.zig");

const Sink = structured_out.Sink;

pub const Options = struct {
    content_root: []const u8 = "content",
    out_path: []const u8 = "rss.xml",
    site_url: []const u8,
    title: []const u8,
    description: []const u8,
    limit: usize = 20,
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
    /// Optional normalized Pages identity. When present, every RSS public URL
    /// is required to use its exact origin and base path.
    publication_location: ?*const github_pages.Location = null,
};

pub const Result = struct {
    compile: pipeline.Result,
    published: bool = false,

    pub fn deinit(self: *Result) void {
        self.compile.deinit();
    }

    pub fn ok(self: *const Result) bool {
        return self.compile.ok and self.published;
    }
};

const Item = struct {
    node: graph.Node,
    timestamp: rss_date.Timestamp,
};

pub const Error = error{ InvalidSiteUrl, InvalidXml, InvalidLimit, PublicationLocationMismatch };

/// Validate a bounded absolute deployment URL and return the no-trailing-slash
/// channel form. URL path bytes are intentionally preserved as supplied.
pub fn normalizedSiteUrl(allocator: std.mem.Allocator, raw: []const u8) (Error || std.mem.Allocator.Error)![]u8 {
    return site_url_mod.normalized(allocator, raw);
}

fn appendPageUrl(buf: *Sink, allocator: std.mem.Allocator, site_url: []const u8, entity_id: []const u8) !void {
    const output_path = try identity.safeOutputRelativePath(allocator, entity_id);
    defer allocator.free(output_path);
    try buf.rawTrusted("normalizedSiteUrl admits only ASCII RFC 3986 URL bytes", site_url);
    try buf.lit("/");
    try buf.uriPath(output_path);
}

fn validateXml(value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidXml;
    var index: usize = 0;
    while (index < value.len) {
        const first = value[index];
        const width: usize = if (first < 0x80) 1 else if (first < 0xe0) 2 else if (first < 0xf0) 3 else 4;
        var codepoint: u32 = switch (width) {
            1 => first,
            2 => first & 0x1f,
            3 => first & 0x0f,
            4 => first & 0x07,
            else => unreachable,
        };
        var offset: usize = 1;
        while (offset < width) : (offset += 1) codepoint = (codepoint << 6) | (value[index + offset] & 0x3f);
        const permitted = codepoint == 0x9 or codepoint == 0xa or codepoint == 0xd or
            (codepoint >= 0x20 and codepoint <= 0xd7ff) or
            (codepoint >= 0xe000 and codepoint <= 0xfffd) or
            (codepoint >= 0x10000 and codepoint <= 0x10ffff);
        if (!permitted) return error.InvalidXml;
        index += width;
    }
}

fn itemLess(_: void, a: Item, b: Item) bool {
    if (rss_date.lessThan(a.timestamp, b.timestamp)) return false;
    if (rss_date.lessThan(b.timestamp, a.timestamp)) return true;
    return std.mem.order(u8, a.node.id, b.node.id) == .lt;
}

fn eligible(node: graph.Node) bool {
    if (node.published_at == null or node.summary == null) return false;
    return node.status == null or std.mem.eql(u8, node.status.?, "published") or std.mem.eql(u8, node.status.?, "archived");
}

fn appendElement(buf: *Sink, comptime indent: []const u8, comptime name: []const u8, value: []const u8) !void {
    try validateXml(value);
    try buf.lit(indent ++ "<" ++ name ++ ">");
    try buf.field(.xml_text, value);
    try buf.lit("</" ++ name ++ ">\n");
}

pub fn render(allocator: std.mem.Allocator, pages: []const graph.Node, options: Options) ![]u8 {
    if (options.limit < 1 or options.limit > 500) return error.InvalidLimit;
    if (options.publication_location) |location| {
        publication_location.validateSiteUrl(allocator, location, options.site_url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PublicationLocationMismatch,
        };
    }
    const site_url = try normalizedSiteUrl(allocator, options.site_url);
    defer allocator.free(site_url);
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(allocator);
    for (pages) |node| {
        if (!eligible(node)) continue;
        const timestamp = rss_date.parse(node.published_at.?) catch return error.InvalidXml;
        try items.append(allocator, .{ .node = node, .timestamp = timestamp });
    }
    std.mem.sort(Item, items.items, {}, itemLess);
    if (items.items.len > options.limit) items.shrinkRetainingCapacity(options.limit);

    var out = Sink.init(allocator);
    errdefer out.deinit();
    try out.lit("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\">\n  <channel>\n");
    try appendElement(&out, "    ", "title", options.title);
    try appendElement(&out, "    ", "link", site_url);
    try appendElement(&out, "    ", "description", options.description);
    try appendElement(&out, "    ", "generator", pipeline.compiler_id);
    for (items.items) |item| {
        try out.lit("    <item>\n");
        try appendElement(&out, "      ", "title", item.node.title orelse item.node.id);
        var url = Sink.init(allocator);
        defer url.deinit();
        try appendPageUrl(&url, allocator, site_url, item.node.id);
        try appendElement(&out, "      ", "link", url.items());
        try out.lit("      <guid isPermaLink=\"true\">");
        try out.field(.xml_text, url.items());
        try out.lit("</guid>\n");
        try appendElement(&out, "      ", "description", item.node.summary.?);
        var date: std.ArrayList(u8) = .empty;
        defer date.deinit(allocator);
        try rss_date.appendRfc822(&date, allocator, item.timestamp);
        try appendElement(&out, "      ", "pubDate", date.items);
        for (item.node.tags) |tag| try appendElement(&out, "      ", "category", tag);
        try out.lit("    </item>\n");
    }
    try out.lit("  </channel>\n</rss>\n");
    return try out.toOwnedSlice();
}

fn ensureParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
}

fn readFileAlloc(io: Io, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn publish(io: Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = allocator;
    var stage_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stage = try std.fmt.bufPrint(&stage_buf, "{s}.boris-stage", .{path});
    var previous_buf: [std.fs.max_path_bytes]u8 = undefined;
    const previous = try std.fmt.bufPrint(&previous_buf, "{s}.boris-prev", .{path});
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, stage) catch {};
    cwd.deleteFile(io, previous) catch {};
    try ensureParent(io, stage);
    try cwd.writeFile(io, .{ .sub_path = stage, .data = data });
    cwd.rename(path, cwd, previous, io) catch {};
    cwd.rename(stage, cwd, path, io) catch |err| {
        cwd.rename(previous, cwd, path, io) catch {};
        return err;
    };
    cwd.deleteFile(io, previous) catch {};
}

pub fn run(io: Io, allocator: std.mem.Allocator, options: Options) !Result {
    if (std.fs.path.isAbsolute(options.content_root) or std.fs.path.isAbsolute(options.out_path)) return error.AbsolutePath;
    if (options.limit < 1 or options.limit > 500) return error.InvalidLimit;
    const normalized = try normalizedSiteUrl(allocator, options.site_url);
    defer allocator.free(normalized);
    try target.validateExportPath(io, allocator, options.content_root, options.out_path);
    var result = Result{ .compile = try pipeline.compile(io, allocator, .{
        .content_root = options.content_root,
        .quiet = options.quiet,
        .input_format = options.input_format,
    }) };
    errdefer result.deinit();
    if (!result.compile.ok) return result;
    const data = try render(allocator, result.compile.pages.items, options);
    defer allocator.free(data);
    try publish(io, allocator, options.out_path, data);
    result.published = true;
    return result;
}

test "RSS renderer is deterministic, sorted, escaped, and bounded" {
    const pages = [_]graph.Node{
        .{ .id = "posts/z", .source_path = "posts/z.md", .title = "Z & <Z>", .published_at = "2026-07-28T14:30:00Z", .summary = "z & <summary>", .tags = &.{ "news", "zig" } },
        .{ .id = "posts/a", .source_path = "posts/a.md", .published_at = "2026-07-28T14:30:00Z", .summary = "A", .tags = &.{} },
        .{ .id = "old", .source_path = "old.md", .status = "archived", .published_at = "2025-01-01T00:00:00Z", .summary = "Old" },
        .{ .id = "draft", .source_path = "draft.md", .status = "draft", .published_at = "2027-01-01T00:00:00Z", .summary = "No" },
    };
    const rendered = try render(std.testing.allocator, &pages, .{ .site_url = "https://example.test/docs/", .title = "Docs & Stuff", .description = "Updates <here>", .limit = 2 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://example.test/docs/posts/a.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Z &amp; &lt;Z&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "draft.html") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "old.html") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "posts/a.html").? < std.mem.indexOf(u8, rendered, "posts/z.html").?);
}

test "XML escaping and site URL validation reject unsafe values" {
    try std.testing.expectError(error.InvalidXml, validateXml("bad\x01"));
    const invalid = [_][]const u8{
        "https://example.test/?x=1",
        "https://example.test/<not-a-url>",
        "https://example.test/%not-encoded",
        "https:///docs",
        "https://example.test:port/docs",
        "https://user@example.test/docs",
        "https://exa mple.test/docs",
        "https://[::1/docs",
    };
    for (invalid) |url| try std.testing.expectError(error.InvalidSiteUrl, normalizedSiteUrl(std.testing.allocator, url));
    const normalized = try normalizedSiteUrl(std.testing.allocator, "https://[2001:db8::1]:8443/docs/%E2%9C%93/");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("https://[2001:db8::1]:8443/docs/%E2%9C%93", normalized);
}

test "RSS publication URLs retain a project-site base path" {
    const gpa = std.testing.allocator;
    const pages_location_mod = @import("github_pages.zig");
    var location = try pages_location_mod.parse(gpa, "https://owner.github.io/boris/", "https://owner.github.io", "/boris/");
    defer location.deinit(gpa);
    const pages = [_]graph.Node{
        .{ .id = "guides/start", .source_path = "guides/start.md", .published_at = "2026-07-28T14:30:00Z", .summary = "Start" },
    };
    const rendered = try render(gpa, &pages, .{
        .site_url = "https://owner.github.io/boris",
        .title = "Docs",
        .description = "Description",
        .publication_location = &location,
    });
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://owner.github.io/boris/guides/start.html") != null);
    try std.testing.expectError(error.PublicationLocationMismatch, render(gpa, &pages, .{
        .site_url = "https://owner.github.io",
        .title = "Docs",
        .description = "Description",
        .publication_location = &location,
    }));
}

test "RSS fixture uses project root and custom Pages locations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
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
        var out_buf: [std.fs.max_path_bytes]u8 = undefined;
        const out = try std.fmt.bufPrint(&out_buf, ".zig-cache/tmp/{s}/rss-{d}.xml", .{ tmp.sub_path, index });
        var location = try github_pages.parse(gpa, shape.base_url, shape.origin, shape.base_path);
        defer location.deinit(gpa);
        var result = try run(io, gpa, .{
            .content_root = "docs/contracts/fixtures/publication-location/content",
            .out_path = out,
            .site_url = shape.base_url,
            .title = "Location Fixture",
            .description = "Publication-location fixture feed",
            .quiet = true,
            .publication_location = &location,
        });
        defer result.deinit();
        try std.testing.expect(result.ok());
        const bytes = try readFileAlloc(io, out, gpa);
        defer gpa.free(bytes);
        const expected = switch (index) {
            0 => "https://owner.github.io/boris/guides/start.html",
            1 => "https://owner.github.io/guides/start.html",
            2 => "https://docs.example.com/guides/start.html",
            else => unreachable,
        };
        try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    }
}
