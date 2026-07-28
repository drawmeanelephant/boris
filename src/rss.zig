//! Deterministic RSS 2.0 projection of a validated Boris graph.

const std = @import("std");
const Io = std.Io;
const graph = @import("graph.zig");
const identity = @import("identity.zig");
const pipeline = @import("pipeline.zig");
const rss_date = @import("rss_date.zig");
const target = @import("target.zig");

pub const Options = struct {
    content_root: []const u8 = "content",
    out_path: []const u8 = "rss.xml",
    site_url: []const u8,
    title: []const u8,
    description: []const u8,
    limit: usize = 20,
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
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

pub const Error = error{ InvalidSiteUrl, InvalidXml, InvalidLimit };

fn isUrlSpace(byte: u8) bool {
    return byte <= 0x20 or byte == 0x7f;
}

/// Validate a bounded absolute deployment URL and return the no-trailing-slash
/// channel form. URL path bytes are intentionally preserved as supplied.
pub fn normalizedSiteUrl(allocator: std.mem.Allocator, raw: []const u8) (Error || std.mem.Allocator.Error)![]u8 {
    if (raw.len == 0 or raw.len > 2048) return error.InvalidSiteUrl;
    const scheme_end: usize = if (std.mem.startsWith(u8, raw, "https://")) 8 else if (std.mem.startsWith(u8, raw, "http://")) 7 else return error.InvalidSiteUrl;
    if (scheme_end >= raw.len) return error.InvalidSiteUrl;
    var host_end = scheme_end;
    while (host_end < raw.len and raw[host_end] != '/' and raw[host_end] != '?' and raw[host_end] != '#') : (host_end += 1) {
        if (isUrlSpace(raw[host_end])) return error.InvalidSiteUrl;
    }
    if (host_end == scheme_end) return error.InvalidSiteUrl;
    for (raw[host_end..]) |byte| if (isUrlSpace(byte) or byte == '?' or byte == '#') return error.InvalidSiteUrl;
    var end = raw.len;
    while (end > host_end and raw[end - 1] == '/') : (end -= 1) {}
    return try allocator.dupe(u8, raw[0..end]);
}

fn appendPercentEncodedPath(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (path) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == '/';
        if (safe) {
            try buf.append(allocator, byte);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[byte >> 4]);
            try buf.append(allocator, hex[byte & 0x0f]);
        }
    }
}

pub fn appendPageUrl(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, site_url: []const u8, entity_id: []const u8) !void {
    const output_path = try identity.safeOutputRelativePath(allocator, entity_id);
    defer allocator.free(output_path);
    try buf.appendSlice(allocator, site_url);
    try buf.append(allocator, '/');
    try appendPercentEncodedPath(buf, allocator, output_path);
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

pub fn appendXmlText(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) (Error || std.mem.Allocator.Error)!void {
    try validateXml(value);
    for (value) |byte| switch (byte) {
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        else => try buf.append(allocator, byte),
    };
}

pub fn appendXmlAttribute(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) (Error || std.mem.Allocator.Error)!void {
    try validateXml(value);
    for (value) |byte| switch (byte) {
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        '"' => try buf.appendSlice(allocator, "&quot;"),
        '\'' => try buf.appendSlice(allocator, "&apos;"),
        else => try buf.append(allocator, byte),
    };
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

fn appendElement(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: []const u8, name: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, indent);
    try buf.append(allocator, '<');
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '>');
    try appendXmlText(buf, allocator, value);
    try buf.appendSlice(allocator, "</");
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, ">\n");
}

pub fn render(allocator: std.mem.Allocator, pages: []const graph.Node, options: Options) ![]u8 {
    if (options.limit < 1 or options.limit > 500) return error.InvalidLimit;
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

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\">\n  <channel>\n");
    try appendElement(&out, allocator, "    ", "title", options.title);
    try appendElement(&out, allocator, "    ", "link", site_url);
    try appendElement(&out, allocator, "    ", "description", options.description);
    try appendElement(&out, allocator, "    ", "generator", pipeline.compiler_id);
    for (items.items) |item| {
        try out.appendSlice(allocator, "    <item>\n");
        try appendElement(&out, allocator, "      ", "title", item.node.title orelse item.node.id);
        var url: std.ArrayList(u8) = .empty;
        defer url.deinit(allocator);
        try appendPageUrl(&url, allocator, site_url, item.node.id);
        try appendElement(&out, allocator, "      ", "link", url.items);
        try out.appendSlice(allocator, "      <guid isPermaLink=\"true\">");
        try appendXmlText(&out, allocator, url.items);
        try out.appendSlice(allocator, "</guid>\n");
        try appendElement(&out, allocator, "      ", "description", item.node.summary.?);
        try out.appendSlice(allocator, "      <pubDate>");
        try rss_date.appendRfc822(&out, allocator, item.timestamp);
        try out.appendSlice(allocator, "</pubDate>\n");
        for (item.node.tags) |tag| try appendElement(&out, allocator, "      ", "category", tag);
        try out.appendSlice(allocator, "    </item>\n");
    }
    try out.appendSlice(allocator, "  </channel>\n</rss>\n");
    return try out.toOwnedSlice(allocator);
}

fn ensureParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
}

fn publish(io: Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const stage = try std.fmt.allocPrint(allocator, "{s}.boris-stage", .{path});
    defer allocator.free(stage);
    const previous = try std.fmt.allocPrint(allocator, "{s}.boris-prev", .{path});
    defer allocator.free(previous);
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
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendXmlAttribute(&out, std.testing.allocator, "\"'&<>");
    try std.testing.expectEqualStrings("&quot;&apos;&amp;&lt;&gt;", out.items);
    try std.testing.expectError(error.InvalidXml, appendXmlText(&out, std.testing.allocator, "bad\x01"));
    try std.testing.expectError(error.InvalidSiteUrl, normalizedSiteUrl(std.testing.allocator, "https://example.test/?x=1"));
}
