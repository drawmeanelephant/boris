//! Opt-in target-owned social metadata. No source reads, output writes, or
//! inherited publication location: one declaration resolves one page.
const std = @import("std");
const page = @import("page.zig");
const render = @import("render.zig");
const identity = @import("identity.zig");
const site_url = @import("site_url.zig");
const sitemap = @import("sitemap.zig");
const rss_date = @import("rss_date.zig");
const html_scan = @import("html_scan.zig");
const Sink = @import("structured_out.zig").Sink;

pub const Image = struct {
    source: enum { theme, static, content },
    /// Exact emitted path, not a host path or an external image URL.
    path: []const u8,
    alt: []const u8,
};
pub const PageType = enum { website, article };
pub const TwitterCard = enum { summary, summary_large_image };
pub const Fields = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    image: ?Image = null,
    type: ?PageType = null,
    twitter_card: ?TwitterCard = null,
};
pub const Override = struct {
    id: []const u8,
    values: Fields = .{},
    /// No authored modification fact exists in the current frontmatter.
    modified_time: ?[]const u8 = null,
};
pub const Declaration = struct {
    enabled: bool = false,
    base_url: ?[]const u8 = null,
    ogp: enum { optional, required } = .optional,
    defaults: Fields = .{},
    pages: []Override = &.{},
};
pub const Feed = struct {
    path: []const u8,
    title: []const u8,
    description: []const u8,
    limit: usize = 20,
};
pub const Error = error{
    InvalidHead,
    HeadBaseMismatch,
    HeadPageMissing,
    HeadImageMissing,
    HeadImageInvalid,
    HeadLayoutInvalid,
    HeadOwnedTagConflict,
    HeadOgpUnsupported,
};

pub fn isFailure(err: anyerror) bool {
    return switch (err) {
        error.InvalidHead,
        error.HeadBaseMismatch,
        error.HeadPageMissing,
        error.HeadImageMissing,
        error.HeadImageInvalid,
        error.HeadLayoutInvalid,
        error.HeadOwnedTagConflict,
        error.HeadOgpUnsupported,
        => true,
        else => false,
    };
}

fn text(value: []const u8) Error!void {
    // These are Boris resource bounds, not unverified X crawler limits.
    if (value.len == 0 or value.len > 1024 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidHead;
    for (value) |c| if (c < 0x20 or c == 0x7f) return error.InvalidHead;
}

fn validateFields(fields: Fields) !void {
    if (fields.title) |v| try text(v);
    if (fields.description) |v| try text(v);
    if (fields.image) |v| {
        try text(v.alt);
        if (v.path.len > 1024) return error.InvalidHead;
        sitemap.validateOutputPath(v.path) catch return error.InvalidHead;
        if (std.mem.startsWith(u8, v.path, "_boris/")) return error.InvalidHead;
    }
}

pub fn parse(gpa: std.mem.Allocator, value: std.json.Value) !std.json.Parsed(Declaration) {
    try rejectNulls(value);
    try checkShape(Declaration, value);
    var parsed = std.json.parseFromValue(Declaration, gpa, value, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidHead;
    };
    errdefer parsed.deinit();
    const cfg = &parsed.value;
    if (cfg.enabled and cfg.base_url == null) return error.InvalidHead;
    if (cfg.base_url) |url| {
        const normalized = site_url.normalized(gpa, url) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidHead;
        };
        defer gpa.free(normalized);
        cfg.base_url = try parsed.arena.allocator().dupe(u8, normalized);
    }
    try validateFields(cfg.defaults);
    if (cfg.pages.len > 256) return error.InvalidHead;
    std.mem.sort(Override, cfg.pages, {}, struct {
        fn less(_: void, a: Override, b: Override) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);
    for (cfg.pages, 0..) |p, i| {
        if (!identity.validateEntityId(p.id)) return error.InvalidHead;
        if (i > 0 and std.mem.eql(u8, cfg.pages[i - 1].id, p.id)) return error.InvalidHead;
        try validateFields(p.values);
        if (p.modified_time) |date| _ = rss_date.parse(date) catch return error.InvalidHead;
    }
    return parsed;
}

/// `parseFromValue` coerces: a JSON integer or numeric string becomes an enum
/// tag, and an integer array becomes a `[]const u8` byte string. The `head`
/// grammar is closed (docs/contracts/head-metadata.md): a wrong JSON type is
/// a rejection, not a coercion. Walk the value against the declared shape
/// before the lossy parse so `type: 0`, `type: "0"`, or `title: [116,105,116]`
/// fail rather than silently becoming `.article`, `.website`, or "tit" (#1042).
/// Unknown keys and missing required fields remain `parseFromValue`'s job.
fn checkShape(comptime T: type, value: std.json.Value) Error!void {
    switch (@typeInfo(T)) {
        .optional => |info| switch (value) {
            // rejectNulls already forbids null anywhere in the declaration.
            .null => return error.InvalidHead,
            else => return checkShape(info.child, value),
        },
        .bool => if (value != .bool) return error.InvalidHead,
        .int => if (value != .integer) return error.InvalidHead,
        .@"enum" => {
            const s = switch (value) {
                .string => |s| s,
                else => return error.InvalidHead,
            };
            // A tag name only: `stringToEnum` is what `parseFromValue`'s
            // numeric-string coercion bypasses.
            if (std.meta.stringToEnum(T, s) == null) return error.InvalidHead;
        },
        .pointer => |info| {
            if (info.size != .slice) return;
            if (info.child == u8) {
                if (value != .string) return error.InvalidHead;
                return;
            }
            const items = switch (value) {
                .array => |a| a.items,
                else => return error.InvalidHead,
            };
            for (items) |item| try checkShape(info.child, item);
        },
        .@"struct" => |info| {
            const obj = switch (value) {
                .object => |o| o,
                else => return error.InvalidHead,
            };
            inline for (info.field_names, info.field_types) |name, field_type| {
                if (obj.get(name)) |child| try checkShape(field_type, child);
            }
        },
        else => {},
    }
}

fn rejectNulls(value: std.json.Value) Error!void {
    switch (value) {
        .null => return error.InvalidHead,
        .array => |array| for (array.items) |v| try rejectNulls(v),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try rejectNulls(entry.value_ptr.*);
        },
        else => {},
    }
}

pub fn overrideFor(cfg: *const Declaration, id: []const u8) ?Override {
    for (cfg.pages) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

pub const Resolved = struct {
    title: []const u8,
    description: ?[]const u8,
    image: ?Image,
    type: PageType,
    twitter_card: TwitterCard,
    published_time: ?[]const u8,
    modified_time: ?[]const u8,
};

pub fn resolve(cfg: *const Declaration, p: *const page.DurablePage) Error!Resolved {
    const exact = overrideFor(cfg, p.entity_id);
    const values: Fields = if (exact) |v| v.values else .{};
    const image = values.image orelse cfg.defaults.image;
    const card = values.twitter_card orelse cfg.defaults.twitter_card orelse .summary;
    if (card == .summary_large_image and image == null) return error.InvalidHead;
    const kind = values.type orelse cfg.defaults.type orelse
        (if (p.published_at != null) PageType.article else PageType.website);
    return .{
        .title = values.title orelse p.title orelse cfg.defaults.title orelse p.entity_id,
        .description = values.description orelse p.summary orelse cfg.defaults.description,
        .image = image,
        .type = kind,
        .twitter_card = card,
        .published_time = if (kind == .article) p.published_at else null,
        .modified_time = if (kind == .article and exact != null) exact.?.modified_time else null,
    };
}

fn meta(out: *Sink, comptime attribute: []const u8, comptime name: []const u8, value: []const u8, xhtml: bool) !void {
    try out.lit("<meta " ++ attribute ++ "=\"" ++ name ++ "\" content=\"");
    try out.field(.xml_attr, value);
    if (xhtml) try out.lit("\" />\n") else try out.lit("\">\n");
}

pub fn emit(gpa: std.mem.Allocator, cfg: *const Declaration, p: *const page.DurablePage, profile: render.OutputProfile, feed: ?Feed) ![]u8 {
    if (!cfg.enabled or p.status == .draft) return gpa.dupe(u8, "");
    const strict = profile == .html4_strict;
    if (strict and cfg.ogp == .required) return error.HeadOgpUnsupported;
    const values = try resolve(cfg, p);
    const base = cfg.base_url orelse return error.InvalidHead;
    const canonical = try sitemap.absoluteUrl(gpa, base, p.output_path);
    defer gpa.free(canonical);
    const xhtml = profile == .xhtml;
    var out = Sink.init(gpa);
    errdefer out.deinit();
    try out.lit("<link rel=\"canonical\" href=\"");
    try out.field(.xml_attr, canonical);
    if (xhtml) try out.lit("\" />\n") else try out.lit("\">\n");
    if (values.description) |v| try meta(&out, "name", "description", v, xhtml);
    if (!strict) {
        try meta(&out, "property", "og:url", canonical, xhtml);
        try meta(&out, "property", "og:title", values.title, xhtml);
        try meta(&out, "property", "og:type", @tagName(values.type), xhtml);
        if (values.description) |v| try meta(&out, "property", "og:description", v, xhtml);
        if (values.published_time) |v| try meta(&out, "property", "article:published_time", v, xhtml);
        if (values.modified_time) |v| try meta(&out, "property", "article:modified_time", v, xhtml);
    }
    try meta(&out, "name", "twitter:card", @tagName(values.twitter_card), xhtml);
    try meta(&out, "name", "twitter:title", values.title, xhtml);
    if (values.description) |v| try meta(&out, "name", "twitter:description", v, xhtml);
    if (values.image) |image| {
        const url = try sitemap.absoluteUrl(gpa, base, image.path);
        defer gpa.free(url);
        if (!strict) {
            try meta(&out, "property", "og:image", url, xhtml);
            try meta(&out, "property", "og:image:alt", image.alt, xhtml);
        }
        try meta(&out, "name", "twitter:image", url, xhtml);
        try meta(&out, "name", "twitter:image:alt", image.alt, xhtml);
    }
    if (feed) |f| {
        const url = try sitemap.absoluteUrl(gpa, base, f.path);
        defer gpa.free(url);
        try out.lit("<link rel=\"alternate\" type=\"application/rss+xml\" href=\"");
        try out.field(.xml_attr, url);
        if (xhtml) try out.lit("\" />\n") else try out.lit("\">\n");
    }
    return out.toOwnedSlice();
}

fn owned(tag: html_scan.Tag, bytes: []const u8) bool {
    if (tag.closing) return false;
    if (std.ascii.eqlIgnoreCase(tag.name, "link")) {
        const rel = html_scan.attrValue(bytes, "rel") orelse "";
        return html_scan.attributeMatches(rel, "canonical", .token) or (html_scan.attributeMatches(rel, "alternate", .token) and
            html_scan.attributeMatches(html_scan.attrValue(bytes, "type") orelse "", "application/rss+xml", .exact));
    }
    if (!std.ascii.eqlIgnoreCase(tag.name, "meta")) return false;
    var attrs = html_scan.AttrIter.init(bytes);
    while (attrs.next()) |a| {
        if (!std.ascii.eqlIgnoreCase(a.name, "property") and !std.ascii.eqlIgnoreCase(a.name, "name")) continue;
        const v = a.value orelse continue;
        if (html_scan.attributeMatches(v, "description", .exact) or
            html_scan.attributeMatches(v, "og:", .prefix) or
            html_scan.attributeMatches(v, "twitter:", .prefix) or
            html_scan.attributeMatches(v, "article:published_time", .exact) or
            html_scan.attributeMatches(v, "article:modified_time", .exact)) return true;
    }
    return false;
}

/// Token-aware so examples, comments and script strings do not become tags.
/// A layout slot inside an attribute, comment, title or raw-text element is
/// not a usable head slot.
fn inspect(bytes: []const u8, require_slot: bool, xml: bool) Error!void {
    var i: usize = 0;
    var in_head = false;
    var head_count: usize = 0;
    var slots: usize = 0;
    while (i < bytes.len) {
        if (require_slot and std.mem.startsWith(u8, bytes[i..], "{{head}}")) {
            if (!in_head) return error.HeadLayoutInvalid;
            slots += 1;
            i += "{{head}}".len;
            continue;
        }
        if (bytes[i] != '<') {
            if (require_slot and in_head and !std.ascii.isWhitespace(bytes[i])) return error.HeadLayoutInvalid;
            i += 1;
            continue;
        }
        const tag = html_scan.tagAt(bytes, i) orelse {
            if (std.mem.startsWith(u8, bytes[i..], "<!") or std.mem.startsWith(u8, bytes[i..], "<?")) {
                i = (std.mem.indexOfScalarPos(u8, bytes, i, '>') orelse return error.HeadLayoutInvalid) + 1;
                continue;
            }
            return error.HeadLayoutInvalid;
        };
        if (owned(tag, bytes[i .. tag.end + 1])) return error.HeadOwnedTagConflict;
        if (std.ascii.eqlIgnoreCase(tag.name, "head")) {
            if (tag.closing) {
                if (!in_head) return error.HeadLayoutInvalid;
                in_head = false;
            } else {
                if (in_head or tag.self_closing) return error.HeadLayoutInvalid;
                head_count += 1;
                in_head = true;
            }
        } else if (require_slot and in_head and !tag.closing and
            !std.ascii.eqlIgnoreCase(tag.name, "!comment") and
            !std.ascii.eqlIgnoreCase(tag.name, "meta") and
            !std.ascii.eqlIgnoreCase(tag.name, "link") and
            !std.ascii.eqlIgnoreCase(tag.name, "base") and
            !std.ascii.eqlIgnoreCase(tag.name, "title") and
            !std.ascii.eqlIgnoreCase(tag.name, "script") and
            !std.ascii.eqlIgnoreCase(tag.name, "style") and
            !std.ascii.eqlIgnoreCase(tag.name, "template") and
            !std.ascii.eqlIgnoreCase(tag.name, "noscript"))
        {
            // HTML5 implicitly ends <head> on body-only elements.
            return error.HeadLayoutInvalid;
        }
        if (!tag.closing and (!tag.self_closing or !xml) and
            (html_scan.isRawTextElement(tag.name) or std.ascii.eqlIgnoreCase(tag.name, "title")))
        {
            i = html_scan.rawTextEnd(bytes, tag.end + 1, tag.name) orelse return error.HeadLayoutInvalid;
        } else i = tag.end + 1;
    }
    if (require_slot and (slots != 1 or head_count != 1 or in_head)) return error.HeadLayoutInvalid;
}

pub fn validateLayout(bytes: []const u8) Error!void {
    return validateLayoutProfile(bytes, .html);
}

pub fn validateLayoutProfile(bytes: []const u8, profile: render.OutputProfile) Error!void {
    return inspect(bytes, true, profile == .xhtml);
}

pub fn rejectOwnedTags(bytes: []const u8) Error!void {
    return rejectOwnedTagsProfile(bytes, .html);
}

pub fn rejectOwnedTagsProfile(bytes: []const u8, profile: render.OutputProfile) Error!void {
    return inspect(bytes, false, profile == .xhtml);
}

test "closed head declaration rejects passthrough, duplicates, unsafe URLs and missing alt" {
    const gpa = std.testing.allocator;
    const invalid = [_][]const u8{
        "{\"enabled\":true}",
        "{\"enabled\":true,\"base_url\":\"/local\"}",
        "{\"tags\":{}}",
        "{\"defaults\":{\"image\":{\"source\":\"static\",\"path\":\"a.png\"}}}",
        "{\"defaults\":{\"title\":\"bad\\nline\"}}",
        "{\"defaults\":{\"description\":null}}",
        "{\"defaults\":{\"type\":\"product\"}}",
        "{\"defaults\":{\"image\":{\"source\":\"theme\",\"path\":\"../x.png\",\"alt\":\"x\"}}}",
        "{\"pages\":[{\"id\":\"a\",\"modified_time\":\"2026-02-30T00:00:00Z\"}]}",
        "{\"pages\":[{\"id\":\"a\"},{\"id\":\"a\"}]}",
        // Wrong JSON types fail rather than coerce (#1042): numeric and
        // numeric-string enum values, and byte arrays where the grammar
        // declares a string.
        "{\"defaults\":{\"type\":0}}",
        "{\"defaults\":{\"type\":\"0\"}}",
        "{\"defaults\":{\"twitter_card\":1}}",
        "{\"ogp\":1}",
        "{\"defaults\":{\"image\":{\"source\":0,\"path\":\"a.png\",\"alt\":\"x\"}}}",
        "{\"defaults\":{\"title\":[116,105,116]}}",
        "{\"base_url\":[104,116,116,112,115]}",
        "{\"pages\":[{\"id\":[97]}]}",
        "{\"pages\":[{\"id\":\"a\",\"modified_time\":[50,48]}]}",
    };
    for (invalid) |bytes| {
        var value = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer value.deinit();
        try std.testing.expectError(error.InvalidHead, parse(gpa, value.value));
    }
}

test "head layout requires an actual slot and refuses conflicting owned tags" {
    try rejectOwnedTags("<code>{{head}}</code>");
    try validateLayoutProfile("<head><script/>{{head}}</head>{{content}}", .xhtml);
    try validateLayout("<html><head><title>T</title>{{head}}</head><body>{{content}}</body></html>");
    const bad = [_][]const u8{
        "<!-- <head>{{head}}</head> -->{{content}}",
        "<head><script>{{head}}</script></head>{{content}}",
        "<head><title>{{head}}</title></head>{{content}}",
        "<head x='{{head}}'></head>{{content}}",
        "<head></head><body>{{head}}{{content}}</body>",
        "<head><div>{{head}}</div></head>{{content}}",
        "<head><script/>{{head}}</head>{{content}}",
        "<head>body text{{head}}</head>{{content}}",
    };
    for (bad) |bytes| try std.testing.expectError(error.HeadLayoutInvalid, validateLayout(bytes));
    try std.testing.expectError(error.HeadOwnedTagConflict, validateLayout("<head><meta NAME='OG:title' content='x'>{{head}}</head>{{content}}"));
    try std.testing.expectError(error.HeadOwnedTagConflict, validateLayout("<head><link rel='&#99;anonical' href='x'>{{head}}</head>{{content}}"));
    try std.testing.expectError(error.HeadOwnedTagConflict, validateLayout("<head><meta property='og&colon;title' content='x'>{{head}}</head>{{content}}"));
    try rejectOwnedTags("<pre>&lt;meta name='description'&gt;</pre><!-- <link rel='canonical'> -->");
}

test "head resolution precedence, absent modification facts and hostile text" {
    const gpa = std.testing.allocator;
    var cfg: Declaration = .{
        .enabled = true,
        .base_url = "https://example.test/base",
        .defaults = .{ .title = "Default", .description = "Fallback" },
    };
    var p: page.DurablePage = .{
        .entity_id = "index",
        .source_path = "index.md",
        .output_path = "index.html",
    };
    try std.testing.expectEqualStrings("Default", (try resolve(&cfg, &p)).title);
    p.title = "Page";
    p.summary = "Summary";
    try std.testing.expectEqualStrings("Page", (try resolve(&cfg, &p)).title);
    try std.testing.expectEqualStrings("Summary", (try resolve(&cfg, &p)).description.?);
    var overrides = [_]Override{.{ .id = "index", .values = .{
        .title = "\"><script>alert(1)</script>",
        .description = "Exact & description",
    } }};
    cfg.pages = &overrides;
    const bytes = try emit(gpa, &cfg, &p, .html, null);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "&quot;&gt;&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Exact &amp; description") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "article:modified_time") == null);
    cfg.pages = &.{};
    cfg.defaults.title = null;
    p.title = null;
    try std.testing.expectEqualStrings("index", (try resolve(&cfg, &p)).title);
    cfg.defaults.twitter_card = .summary_large_image;
    try std.testing.expectError(error.InvalidHead, resolve(&cfg, &p));
}
