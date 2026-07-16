//! Notion “Markdown & CSV” export → Boris migration laboratory (phase 1).
//!
//! Discovers Markdown/MDX-like page files in an official Notion export tree,
//! maps nested folders/filenames (with 32-hex page ids stripped) to Boris
//! entity ids, rewrites unambiguous local page links and attachments, copies
//! local media with a deterministic manifest, and emits provenance plus
//! human-review reports. Never mutates the export. No Notion API, OAuth,
//! network, zip extraction, or product-compiler imports.
//!
//! Not part of the Boris product compiler pipeline.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-notion-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const max_entity_id_bytes: usize = 255;

pub const RunOptions = struct {
    /// Unpacked Notion Markdown & CSV export root (never modified).
    export_dir: []const u8,
    /// Output root: content/ + media/ + reports + manifests.
    out_dir: []const u8,
    quiet: bool = false,
};

pub const ConversionClass = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    pub fn jsonName(self: ConversionClass) []const u8 {
        return switch (self) {
            .exact => "exact",
            .transformed => "transformed",
            .unsupported => "unsupported",
            .human_review => "human_review",
        };
    }

    pub fn rank(self: ConversionClass) u8 {
        return switch (self) {
            .exact => 0,
            .transformed => 1,
            .unsupported => 2,
            .human_review => 3,
        };
    }

    pub fn worse(a: ConversionClass, b: ConversionClass) ConversionClass {
        return if (a.rank() >= b.rank()) a else b;
    }
};

pub const LinkStatus = enum {
    resolved,
    unresolved,
    ambiguous,
    external_skipped,
    skipped_fence,
    unsupported_embed,

    pub fn jsonName(self: LinkStatus) []const u8 {
        return switch (self) {
            .resolved => "resolved",
            .unresolved => "unresolved",
            .ambiguous => "ambiguous",
            .external_skipped => "external_skipped",
            .skipped_fence => "skipped_fence",
            .unsupported_embed => "unsupported_embed",
        };
    }
};

// ---------------------------------------------------------------------------
// Directory skip policy
// ---------------------------------------------------------------------------

const skip_dir_names = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "dist",
    ".output",
    ".vercel",
    ".netlify",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    ".trash",
    ".DS_Store",
    ".notion",
    "__MACOSX",
};

pub fn isSkippedDirName(name: []const u8) bool {
    for (skip_dir_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    // hidden tooling dirs (leading '.') except we already list known ones;
    // skip any remaining .foo directories that are not page content
    if (name.len > 0 and name[0] == '.') return true;
    return false;
}

pub fn isMarkdownPage(path: []const u8) bool {
    // Fixture / tooling docs next to an export are not Notion pages.
    const base = basenameOf(path);
    if (std.mem.eql(u8, base, "README.md") or std.mem.eql(u8, base, "README.mdx")) return false;
    return endsWithIgnoreCase(path, ".md") or endsWithIgnoreCase(path, ".mdx");
}

pub fn isCsvDatabase(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".csv");
}

fn endsWithIgnoreCase(hay: []const u8, suffix: []const u8) bool {
    if (hay.len < suffix.len) return false;
    const tail = hay[hay.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        const al: u8 = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const bl: u8 = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (al != bl) return false;
    }
    return true;
}

fn trimSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

pub fn isNotionPageId(s: []const u8) bool {
    if (s.len != 32) return false;
    for (s) |c| {
        if (!isHexChar(c)) return false;
    }
    return true;
}

/// Split a Notion export stem/basename into display title + optional 32-hex id.
/// `Page Title abcdef…` → title=`Page Title`, page_id=`abcdef…`.
pub fn stripNotionPageId(stem: []const u8) struct { title: []const u8, page_id: ?[]const u8 } {
    if (stem.len >= 33) {
        const id = stem[stem.len - 32 ..];
        if (isNotionPageId(id) and stem[stem.len - 33] == ' ') {
            var title = stem[0 .. stem.len - 33];
            title = trimSpace(title);
            if (title.len == 0) title = "untitled";
            return .{ .title = title, .page_id = id };
        }
    }
    const t = trimSpace(stem);
    return .{ .title = if (t.len == 0) "untitled" else t, .page_id = null };
}

// ---------------------------------------------------------------------------
// Path / entity-id helpers
// ---------------------------------------------------------------------------

pub fn normalizeRelPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    if (i + 1 < path.len and path[i] == '.' and (path[i + 1] == '/' or path[i + 1] == '\\')) i += 2;
    var need_slash = false;
    while (i < path.len) {
        while (i < path.len and (path[i] == '/' or path[i] == '\\')) : (i += 1) {}
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/' and path[i] != '\\') : (i += 1) {}
        const seg = path[start..i];
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) return error.IllegalSegment;
        if (need_slash) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
        need_slash = true;
    }
    if (out.items.len == 0) return error.EmptyPath;
    return try out.toOwnedSlice(allocator);
}

/// Map export-relative page path to a Boris entity id (ids stripped, sanitized).
pub fn pathToEntityId(allocator: std.mem.Allocator, export_rel: []const u8) ![]u8 {
    const norm = try normalizeRelPathAlloc(allocator, export_rel);
    defer allocator.free(norm);
    var stem = norm;
    if (endsWithIgnoreCase(stem, ".mdx")) {
        stem = stem[0 .. stem.len - 4];
    } else if (endsWithIgnoreCase(stem, ".md")) {
        stem = stem[0 .. stem.len - 3];
    }
    // Strip Notion ids per path segment, then sanitize.
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    var i: usize = 0;
    var first = true;
    while (i < stem.len) {
        while (i < stem.len and stem[i] == '/') : (i += 1) {}
        if (i >= stem.len) break;
        const start = i;
        while (i < stem.len and stem[i] != '/') : (i += 1) {}
        const seg = stem[start..i];
        const stripped = stripNotionPageId(seg);
        if (!first) try cleaned.append(allocator, '/');
        try cleaned.appendSlice(allocator, stripped.title);
        first = false;
    }
    if (cleaned.items.len == 0) return try allocator.dupe(u8, "untitled");
    return try sanitizeEntityId(allocator, cleaned.items);
}

pub fn sanitizeEntityIdBuf(buf: []u8, stem: []const u8) ?[]const u8 {
    if (buf.len == 0) return null;
    var len: usize = 0;
    var prev_dash = false;
    var i: usize = 0;
    while (i < stem.len) {
        const c = stem[i];
        if (c == '/') {
            if (len > 0 and buf[len - 1] == '-') len -= 1;
            if (len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) return null;
                buf[len] = '/';
                len += 1;
            }
            prev_dash = false;
            i += 1;
            continue;
        }
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '.' or c == '-';
        if (ok) {
            if (len >= buf.len) return null;
            buf[len] = c;
            len += 1;
            prev_dash = c == '-';
        } else if (c == ' ' or c == '\t') {
            if (!prev_dash and len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) return null;
                buf[len] = '-';
                len += 1;
                prev_dash = true;
            }
        } else {
            if (!prev_dash and len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) return null;
                buf[len] = '-';
                len += 1;
                prev_dash = true;
            }
        }
        i += 1;
    }
    while (len > 0 and buf[len - 1] == '-') len -= 1;
    if (len == 0) {
        const untitled = "untitled";
        if (untitled.len > buf.len) return null;
        @memcpy(buf[0..untitled.len], untitled);
        return buf[0..untitled.len];
    }
    if (len > max_entity_id_bytes) return null;
    if (buf[0] == '/' or buf[len - 1] == '/') return null;
    return buf[0..len];
}

pub fn sanitizeEntityId(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    var buf: [max_entity_id_bytes]u8 = undefined;
    const s = sanitizeEntityIdBuf(&buf, stem) orelse return error.IdTooLong;
    return try allocator.dupe(u8, s);
}

pub fn basenameOf(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    return path[start..];
}

pub fn basenameStem(path: []const u8) []const u8 {
    const base = basenameOf(path);
    if (endsWithIgnoreCase(base, ".mdx")) return base[0 .. base.len - 4];
    if (endsWithIgnoreCase(base, ".md")) return base[0 .. base.len - 3];
    return base;
}

fn dirNameOf(path: []const u8) []const u8 {
    if (std.fs.path.dirname(path)) |d| return d;
    return "";
}

/// Relative href from a content page file to a media file under out root.
pub fn relativeLink(allocator: std.mem.Allocator, from_file: []const u8, to_file: []const u8) ![]u8 {
    const from_dir = dirNameOf(from_file);
    var ups: usize = 0;
    if (from_dir.len > 0) {
        ups = 1;
        for (from_dir) |c| {
            if (c == '/') ups += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var u: usize = 0;
    while (u < ups) : (u += 1) {
        if (u > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, "..");
    }
    if (ups > 0) try out.append(allocator, '/');
    try out.appendSlice(allocator, to_file);
    return try out.toOwnedSlice(allocator);
}

/// Percent-decode a URL path (Notion exports often encode spaces as %20).
pub fn percentDecodeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len and isHexChar(s[i + 1]) and isHexChar(s[i + 2])) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

/// Join dir + relative target without leaving the export root (.. rejected).
pub fn resolveRelativePath(allocator: std.mem.Allocator, from_file: []const u8, target: []const u8) ![]u8 {
    const t = trimSpace(target);
    if (t.len == 0) return error.EmptyPath;
    // Absolute-looking export path (no leading / expected for Notion; treat as root-rel)
    if (t[0] == '/') {
        return try normalizeRelPathAlloc(allocator, t[1..]);
    }
    const from_dir = dirNameOf(from_file);
    if (from_dir.len == 0) {
        return try normalizeRelPathAlloc(allocator, t);
    }
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from_dir, t });
    defer allocator.free(joined);
    return try normalizeRelPathAlloc(allocator, joined);
}

// ---------------------------------------------------------------------------
// Frontmatter (compatible subset only)
// ---------------------------------------------------------------------------

const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

fn isBorisKey(key: []const u8) bool {
    for (boris_keys) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

pub const FrontmatterInfo = struct {
    present: bool = false,
    body_offset: usize = 0,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tags_raw: ?[]const u8 = null,
    id_override: ?[]const u8 = null,
    unknown_keys: []const []const u8 = &.{},
    incompatible: bool = false,
    notes: []const []const u8 = &.{},
};

pub fn parseFrontmatterLite(allocator: std.mem.Allocator, source: []const u8) !FrontmatterInfo {
    var info: FrontmatterInfo = .{};
    if (!std.mem.startsWith(u8, source, "---\n") and !std.mem.startsWith(u8, source, "---\r\n")) {
        return info;
    }
    const after_open: usize = if (std.mem.startsWith(u8, source, "---\r\n")) 5 else 4;
    var i = after_open;
    var fm_end: ?usize = null;
    var body_off: ?usize = null;
    while (i < source.len) {
        const line_start = i;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        var line = source[line_start..i];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) {
            fm_end = line_start;
            body_off = if (i < source.len and source[i] == '\n') i + 1 else i;
            break;
        }
        if (i < source.len) i += 1;
    }
    if (fm_end == null or body_off == null) {
        info.present = true;
        info.incompatible = true;
        info.body_offset = 0;
        info.notes = try allocator.dupe([]const u8, &[_][]const u8{"unclosed frontmatter fence; body kept intact"});
        return info;
    }
    info.present = true;
    info.body_offset = body_off.?;

    var unknown: std.ArrayList([]const u8) = .empty;
    defer unknown.deinit(allocator);
    var notes: std.ArrayList([]const u8) = .empty;
    defer notes.deinit(allocator);

    var pos = after_open;
    const fields_end = fm_end.?;
    while (pos < fields_end) {
        const line_start = pos;
        while (pos < fields_end and source[pos] != '\n') : (pos += 1) {}
        var line = source[line_start..pos];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (pos < fields_end) pos += 1;
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t' or std.mem.startsWith(u8, line, "- ")) {
            info.incompatible = true;
            try notes.append(allocator, try allocator.dupe(u8, "nested YAML / sequence form in frontmatter"));
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            info.incompatible = true;
            try notes.append(allocator, try allocator.dupe(u8, "malformed frontmatter field"));
            continue;
        };
        const key = trimSpace(line[0..colon]);
        var value = trimSpace(line[colon + 1 ..]);
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (!isBorisKey(key)) {
            try unknown.append(allocator, try allocator.dupe(u8, key));
            continue;
        }
        if (std.mem.eql(u8, key, "title")) info.title = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "parent")) info.parent = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "status")) info.status = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "tags")) {
            if (value.len > 0 and value[0] == '[') {
                info.tags_raw = try allocator.dupe(u8, value);
            } else {
                info.incompatible = true;
                try notes.append(allocator, try allocator.dupe(u8, "tags must be [a, b] form for Boris"));
            }
        }
        if (std.mem.eql(u8, key, "id")) info.id_override = try allocator.dupe(u8, value);
    }
    info.unknown_keys = try unknown.toOwnedSlice(allocator);
    info.notes = try notes.toOwnedSlice(allocator);
    return info;
}

pub fn escapeFmValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var need_quote = false;
    for (value) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '\'' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ' ' or c == '\t')
            need_quote = true;
    }
    if (!need_quote) return try allocator.dupe(u8, value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |c| {
        if (c == '"') continue;
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

pub fn buildFrontmatter(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    title: ?[]const u8,
    parent: ?[]const u8,
    status: ?[]const u8,
    tags_raw: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "---\n");
    if (id) |v| {
        const esc = try escapeFmValue(allocator, v);
        defer allocator.free(esc);
        try buf.appendSlice(allocator, "id: ");
        try buf.appendSlice(allocator, esc);
        try buf.append(allocator, '\n');
    }
    if (title) |v| {
        const esc = try escapeFmValue(allocator, v);
        defer allocator.free(esc);
        try buf.appendSlice(allocator, "title: ");
        try buf.appendSlice(allocator, esc);
        try buf.append(allocator, '\n');
    }
    if (parent) |v| {
        const esc = try escapeFmValue(allocator, v);
        defer allocator.free(esc);
        try buf.appendSlice(allocator, "parent: ");
        try buf.appendSlice(allocator, esc);
        try buf.append(allocator, '\n');
    }
    if (status) |v| {
        if (std.mem.eql(u8, v, "draft") or std.mem.eql(u8, v, "published") or std.mem.eql(u8, v, "archived")) {
            try buf.appendSlice(allocator, "status: ");
            try buf.appendSlice(allocator, v);
            try buf.append(allocator, '\n');
        }
    }
    if (tags_raw) |v| {
        try buf.appendSlice(allocator, "tags: ");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "---\n");
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Hazard detection (Notion-specific)
// ---------------------------------------------------------------------------

pub const HazardKind = enum {
    database_csv,
    relation_or_rollup,
    synced_block,
    embed,
    unsupported_block,
    unknown_frontmatter_key,
    incompatible_frontmatter,
    ambiguous_link,
    unresolved_link,
    deep_hierarchy,

    pub fn jsonName(self: HazardKind) []const u8 {
        return switch (self) {
            .database_csv => "database_csv",
            .relation_or_rollup => "relation_or_rollup",
            .synced_block => "synced_block",
            .embed => "embed",
            .unsupported_block => "unsupported_block",
            .unknown_frontmatter_key => "unknown_frontmatter_key",
            .incompatible_frontmatter => "incompatible_frontmatter",
            .ambiguous_link => "ambiguous_link",
            .unresolved_link => "unresolved_link",
            .deep_hierarchy => "deep_hierarchy",
        };
    }
};

pub const Hazard = struct {
    kind: HazardKind,
    source_path: []const u8,
    detail: []const u8,
};

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            const hc = hay[i + j];
            const hl: u8 = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const nl: u8 = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            if (hl != nl) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

pub fn detectBodyHazards(allocator: std.mem.Allocator, source_path: []const u8, body: []const u8) ![]Hazard {
    var list: std.ArrayList(Hazard) = .empty;
    errdefer list.deinit(allocator);

    if (containsIgnoreCase(body, "relation:") or containsIgnoreCase(body, "rollup:") or
        containsIgnoreCase(body, "| relation") or containsIgnoreCase(body, "| rollup") or
        containsIgnoreCase(body, "relation |") or containsIgnoreCase(body, "rollup |"))
    {
        try list.append(allocator, .{
            .kind = .relation_or_rollup,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "relation/rollup property markers retained raw (not evaluated)"),
        });
    }
    if (containsIgnoreCase(body, "synced block") or containsIgnoreCase(body, "notion-synced") or
        containsIgnoreCase(body, "<!-- synced") or std.mem.indexOf(u8, body, "synced_block") != null)
    {
        try list.append(allocator, .{
            .kind = .synced_block,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "synced block marker retained raw (not expanded)"),
        });
    }
    if (containsIgnoreCase(body, "<iframe") or containsIgnoreCase(body, "youtube.com/embed") or
        containsIgnoreCase(body, "www.notion.so") and containsIgnoreCase(body, "embed") or
        containsIgnoreCase(body, "figma.com/embed") or containsIgnoreCase(body, "twitter.com/") and containsIgnoreCase(body, "<blockquote"))
    {
        try list.append(allocator, .{
            .kind = .embed,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "embed/iframe-like content retained raw (not fetched)"),
        });
    }
    if (containsIgnoreCase(body, "unsupported block") or containsIgnoreCase(body, "<!-- unsupported") or
        containsIgnoreCase(body, "<unknown") or containsIgnoreCase(body, "block type not supported"))
    {
        try list.append(allocator, .{
            .kind = .unsupported_block,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "unsupported Notion block placeholder retained raw"),
        });
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Markdown link / image scanning (fence-aware)
// ---------------------------------------------------------------------------

pub const MdLinkHit = struct {
    is_image: bool,
    text: []const u8,
    target: []const u8,
    start: usize,
    end: usize,
    in_fence: bool,
};

fn scanFenceMap(body: []const u8, allocator: std.mem.Allocator) ![]bool {
    const map = try allocator.alloc(bool, body.len);
    @memset(map, false);
    var i: usize = 0;
    var in_fence = false;
    while (i < body.len) {
        if (i + 2 < body.len and body[i] == '`' and body[i + 1] == '`' and body[i + 2] == '`') {
            in_fence = !in_fence;
            map[i] = in_fence;
            map[i + 1] = in_fence;
            map[i + 2] = in_fence;
            i += 3;
            continue;
        }
        map[i] = in_fence;
        i += 1;
    }
    return map;
}

pub fn isExternalOrSpecialTarget(target: []const u8) bool {
    const t = trimSpace(target);
    if (t.len == 0) return true;
    if (t[0] == '#') return true;
    if (std.mem.startsWith(u8, t, "http://") or std.mem.startsWith(u8, t, "https://") or
        std.mem.startsWith(u8, t, "mailto:") or std.mem.startsWith(u8, t, "data:") or
        std.mem.startsWith(u8, t, "tel:"))
        return true;
    return false;
}

pub fn scanMarkdownLinks(allocator: std.mem.Allocator, body: []const u8) ![]MdLinkHit {
    const fence = try scanFenceMap(body, allocator);
    defer allocator.free(fence);

    var hits: std.ArrayList(MdLinkHit) = .empty;
    errdefer hits.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) {
        const is_image = i + 1 < body.len and body[i] == '!' and body[i + 1] == '[';
        const is_link = body[i] == '[';
        if (!is_image and !is_link) {
            i += 1;
            continue;
        }
        // avoid matching `![` twice as `[`
        if (is_link and i > 0 and body[i - 1] == '!') {
            i += 1;
            continue;
        }
        const start = if (is_image) i else i;
        const text_open = if (is_image) i + 2 else i + 1;
        // find matching ]
        var j = text_open;
        var depth: usize = 1;
        while (j < body.len and depth > 0) : (j += 1) {
            if (body[j] == '[') depth += 1;
            if (body[j] == ']') {
                if (depth == 1) break;
                depth -= 1;
            }
            if (body[j] == '\n') break;
        }
        if (j >= body.len or body[j] != ']') {
            i = text_open;
            continue;
        }
        const text = body[text_open..j];
        if (j + 1 >= body.len or body[j + 1] != '(') {
            i = j + 1;
            continue;
        }
        const url_open = j + 2;
        var k = url_open;
        var paren_depth: usize = 1;
        while (k < body.len and paren_depth > 0) : (k += 1) {
            if (body[k] == '(') paren_depth += 1;
            if (body[k] == ')') {
                if (paren_depth == 1) break;
                paren_depth -= 1;
            }
            if (body[k] == '\n') break;
        }
        if (k >= body.len or body[k] != ')') {
            i = url_open;
            continue;
        }
        var target = trimSpace(body[url_open..k]);
        // strip optional title "..."
        if (target.len >= 2 and target[0] == '<') {
            if (std.mem.indexOfScalar(u8, target, '>')) |gt| {
                target = target[1..gt];
            }
        } else if (std.mem.indexOfScalar(u8, target, ' ')) |sp| {
            target = trimSpace(target[0..sp]);
        }
        const end = k + 1;
        try hits.append(allocator, .{
            .is_image = is_image,
            .text = text,
            .target = target,
            .start = start,
            .end = end,
            .in_fence = fence[start],
        });
        i = end;
    }
    return try hits.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Export inventory
// ---------------------------------------------------------------------------

pub const ExportFileKind = enum { page, media, database_csv, other };

pub const ExportFile = struct {
    rel_path: []const u8,
    kind: ExportFileKind,
};

fn collectFiles(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList(ExportFile),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = entry.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.eql(u8, name, ".DS_Store") or std.mem.eql(u8, name, "Thumbs.db")) continue;

        if (entry.kind == .directory) {
            if (isSkippedDirName(name)) continue;
            const rel = if (prefix.len == 0)
                try retain.dupe(u8, name)
            else
                try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, name });
            var child = try dir.openDir(io, name, .{ .iterate = true });
            defer child.close(io);
            try collectFiles(io, gpa, retain, child, rel, out);
            continue;
        }
        if (entry.kind != .file) continue;

        const rel = if (prefix.len == 0)
            try retain.dupe(u8, name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, name });

        // Prefer classifying unknown extensions as media for inventory (never silent drop).
        const kind: ExportFileKind = if (isMarkdownPage(name))
            .page
        else if (isCsvDatabase(name))
            .database_csv
        else
            .media;
        try out.append(gpa, .{ .rel_path = rel, .kind = kind });
    }
}

// ---------------------------------------------------------------------------
// Resolution index
// ---------------------------------------------------------------------------

const PageEntry = struct {
    export_path: []const u8,
    export_stem: []const u8, // path without extension, original Notion names+ids
    entity_id: []const u8,
    output_path: []const u8,
    basename: []const u8, // original basename stem (with id)
    title_basename: []const u8, // id-stripped basename title
    page_id: ?[]const u8,
    parent_entity: ?[]const u8,
    depth: usize, // 0 = root
};

const MediaEntry = struct {
    export_path: []const u8,
    output_path: []const u8,
};

const ResolveResult = union(enum) {
    none,
    page: *const PageEntry,
    media: *const MediaEntry,
    ambiguous_pages: []const []const u8,
    ambiguous_media: []const []const u8,
};

const Index = struct {
    pages: []PageEntry,
    media: []MediaEntry,

    fn resolvePage(self: *const Index, target_path: []const u8) ResolveResult {
        const t = trimSpace(target_path);
        if (t.len == 0) return .none;
        var t_stem = t;
        if (endsWithIgnoreCase(t_stem, ".mdx")) t_stem = t_stem[0 .. t_stem.len - 4];
        if (endsWithIgnoreCase(t_stem, ".md")) t_stem = t_stem[0 .. t_stem.len - 3];

        // 1. exact export stem
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.export_stem, t_stem)) return .{ .page = p };
        }
        // 2. exact export path with extension
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.export_path, t)) return .{ .page = p };
        }
        // 3. entity id
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.entity_id, t_stem)) return .{ .page = p };
        }
        // 4. unique basename (with Notion id)
        {
            var matches: [64]*const PageEntry = undefined;
            var n: usize = 0;
            const base = basenameOf(t_stem);
            for (self.pages) |*p| {
                if (std.mem.eql(u8, p.basename, base) or std.mem.eql(u8, p.basename, t_stem)) {
                    if (n < matches.len) {
                        matches[n] = p;
                        n += 1;
                    }
                }
            }
            if (n == 1) return .{ .page = matches[0] };
            if (n > 1) return .none;
        }
        // 5. unique title basename (id-stripped)
        {
            var matches: [64]*const PageEntry = undefined;
            var n: usize = 0;
            const base = basenameOf(t_stem);
            const stripped = stripNotionPageId(base);
            for (self.pages) |*p| {
                if (std.mem.eql(u8, p.title_basename, stripped.title) or
                    std.mem.eql(u8, p.title_basename, base))
                {
                    if (n < matches.len) {
                        matches[n] = p;
                        n += 1;
                    }
                }
            }
            if (n == 1) return .{ .page = matches[0] };
            if (n > 1) return .none;
        }
        // 6. path-suffix on export stem
        {
            var matches: [64]*const PageEntry = undefined;
            var n: usize = 0;
            for (self.pages) |*p| {
                if (pathSuffixMatch(p.export_stem, t_stem)) {
                    if (n < matches.len) {
                        matches[n] = p;
                        n += 1;
                    }
                }
            }
            if (n == 1) return .{ .page = matches[0] };
        }
        return .none;
    }

    fn collectAmbiguousPages(self: *const Index, target_path: []const u8, buf: []*const PageEntry) usize {
        const t = trimSpace(target_path);
        var t_stem = t;
        if (endsWithIgnoreCase(t_stem, ".mdx")) t_stem = t_stem[0 .. t_stem.len - 4];
        if (endsWithIgnoreCase(t_stem, ".md")) t_stem = t_stem[0 .. t_stem.len - 3];
        const base = basenameOf(t_stem);
        const stripped = stripNotionPageId(base);
        var n: usize = 0;
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.title_basename, stripped.title) or
                std.mem.eql(u8, p.basename, base) or
                std.mem.eql(u8, p.title_basename, base))
            {
                if (n < buf.len) {
                    buf[n] = p;
                    n += 1;
                }
            }
        }
        if (n > 1) return n;
        // path suffix multi-match
        n = 0;
        for (self.pages) |*p| {
            if (pathSuffixMatch(p.export_stem, t_stem)) {
                if (n < buf.len) {
                    buf[n] = p;
                    n += 1;
                }
            }
        }
        return n;
    }

    fn resolveMedia(self: *const Index, target_path: []const u8) ResolveResult {
        const t = trimSpace(target_path);
        if (t.len == 0) return .none;
        for (self.media) |*m| {
            if (std.mem.eql(u8, m.export_path, t)) return .{ .media = m };
        }
        const want = basenameOf(t);
        var matches: [64]*const MediaEntry = undefined;
        var n: usize = 0;
        for (self.media) |*m| {
            if (std.mem.eql(u8, basenameOf(m.export_path), want)) {
                if (n < matches.len) {
                    matches[n] = m;
                    n += 1;
                }
            }
        }
        if (n == 1) return .{ .media = matches[0] };
        return .none;
    }

    fn collectAmbiguousMedia(self: *const Index, target_path: []const u8, buf: []*const MediaEntry) usize {
        const t = trimSpace(target_path);
        const want = basenameOf(t);
        var n: usize = 0;
        for (self.media) |*m| {
            if (std.mem.eql(u8, basenameOf(m.export_path), want)) {
                if (n < buf.len) {
                    buf[n] = m;
                    n += 1;
                }
            }
        }
        return n;
    }
};

pub fn pathSuffixMatch(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (std.mem.eql(u8, hay, needle)) return true;
    if (hay.len > needle.len and
        hay[hay.len - needle.len - 1] == '/' and
        std.mem.endsWith(u8, hay, needle))
        return true;
    return false;
}

fn entityIdIsWikiSafe(id: []const u8) bool {
    if (id.len == 0 or id.len > max_entity_id_bytes) return false;
    for (id) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '.' or c == '-' or c == '/';
        if (!ok) return false;
    }
    return id[0] != '/' and id[id.len - 1] != '/';
}

// ---------------------------------------------------------------------------
// Body rewrite
// ---------------------------------------------------------------------------

pub const LinkFinding = struct {
    source_path: []const u8,
    raw: []const u8,
    status: LinkStatus,
    resolved_to: ?[]const u8 = null,
    note: []const u8 = "",
};

fn rewriteBody(
    retain: std.mem.Allocator,
    page_export_path: []const u8,
    body: []const u8,
    page: *const PageEntry,
    index: *const Index,
    page_links: *std.ArrayList(LinkFinding),
    all_hazards: *std.ArrayList(Hazard),
    referenced: *std.ArrayList([]const u8),
) !struct { []const u8, ConversionClass } {
    _ = all_hazards;
    var class: ConversionClass = .exact;
    const hits = try scanMarkdownLinks(retain, body);
    if (hits.len == 0) {
        return .{ try retain.dupe(u8, body), class };
    }

    // Process hits reverse so offsets stay valid when building output sequentially...
    // We'll rebuild left-to-right with a cursor instead.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(retain);
    var cursor: usize = 0;

    for (hits) |hit| {
        if (hit.start < cursor) continue; // overlapping skip
        try out.appendSlice(retain, body[cursor..hit.start]);
        cursor = hit.end;

        const raw_full = body[hit.start..hit.end];
        if (hit.in_fence) {
            try out.appendSlice(retain, raw_full);
            try page_links.append(retain, .{
                .source_path = page_export_path,
                .raw = try retain.dupe(u8, raw_full),
                .status = .skipped_fence,
                .note = "inside fenced code; left unchanged",
            });
            continue;
        }

        const decoded = try percentDecodeAlloc(retain, hit.target);
        // retain owns decoded for the rest of the page

        if (isExternalOrSpecialTarget(decoded)) {
            try out.appendSlice(retain, raw_full);
            try page_links.append(retain, .{
                .source_path = page_export_path,
                .raw = try retain.dupe(u8, raw_full),
                .status = .external_skipped,
                .note = "external or fragment target left unchanged",
            });
            continue;
        }

        // Resolve relative to current page path
        const resolved_path = resolveRelativePath(retain, page_export_path, decoded) catch decoded;

        // Prefer page, then media
        const page_res = index.resolvePage(resolved_path);
        if (page_res == .page) {
            const pt = page_res.page;
            if (!entityIdIsWikiSafe(pt.entity_id)) {
                try out.appendSlice(retain, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try page_links.append(retain, .{
                    .source_path = page_export_path,
                    .raw = try retain.dupe(u8, raw_full),
                    .status = .unresolved,
                    .note = "mapped entity id not wiki-safe; left raw",
                });
                continue;
            }
            // rewrite to wiki link
            try out.appendSlice(retain, "[[");
            try out.appendSlice(retain, pt.entity_id);
            if (hit.text.len > 0 and !std.mem.eql(u8, hit.text, pt.entity_id) and
                !std.mem.eql(u8, hit.text, pt.title_basename))
            {
                try out.append(retain, '|');
                try out.appendSlice(retain, hit.text);
            }
            try out.appendSlice(retain, "]]");
            class = ConversionClass.worse(class, .transformed);
            try page_links.append(retain, .{
                .source_path = page_export_path,
                .raw = try retain.dupe(u8, raw_full),
                .status = .resolved,
                .resolved_to = try retain.dupe(u8, pt.entity_id),
                .note = "page link rewritten to entity id",
            });
            continue;
        }

        // Ambiguous pages?
        {
            var matches: [64]*const PageEntry = undefined;
            const n = index.collectAmbiguousPages(resolved_path, &matches);
            // Also try basename-only target
            const n2 = if (n <= 1) index.collectAmbiguousPages(decoded, &matches) else n;
            const nn = if (n > 1) n else n2;
            if (nn > 1) {
                try out.appendSlice(retain, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try page_links.append(retain, .{
                    .source_path = page_export_path,
                    .raw = try retain.dupe(u8, raw_full),
                    .status = .ambiguous,
                    .note = "multiple matching page targets; left raw",
                });
                continue;
            }
        }

        const media_res = index.resolveMedia(resolved_path);
        if (media_res == .media) {
            const mt = media_res.media;
            try referenced.append(retain, mt.export_path);
            const rel = try relativeLink(retain, page.output_path, mt.output_path);
            if (hit.is_image) {
                try out.appendSlice(retain, "![");
                try out.appendSlice(retain, hit.text);
                try out.appendSlice(retain, "](");
                try out.appendSlice(retain, rel);
                try out.append(retain, ')');
            } else {
                try out.appendSlice(retain, "[");
                try out.appendSlice(retain, hit.text);
                try out.appendSlice(retain, "](");
                try out.appendSlice(retain, rel);
                try out.append(retain, ')');
            }
            class = ConversionClass.worse(class, .transformed);
            try page_links.append(retain, .{
                .source_path = page_export_path,
                .raw = try retain.dupe(u8, raw_full),
                .status = .resolved,
                .resolved_to = try retain.dupe(u8, mt.output_path),
                .note = "attachment path rewritten",
            });
            continue;
        }

        {
            var matches: [64]*const MediaEntry = undefined;
            const n = index.collectAmbiguousMedia(resolved_path, &matches);
            if (n > 1) {
                try out.appendSlice(retain, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try page_links.append(retain, .{
                    .source_path = page_export_path,
                    .raw = try retain.dupe(u8, raw_full),
                    .status = .ambiguous,
                    .note = "multiple matching media targets; left raw",
                });
                continue;
            }
        }

        // Unresolved
        try out.appendSlice(retain, raw_full);
        class = ConversionClass.worse(class, .human_review);
        try page_links.append(retain, .{
            .source_path = page_export_path,
            .raw = try retain.dupe(u8, raw_full),
            .status = .unresolved,
            .note = "local target not found in export",
        });
    }
    try out.appendSlice(retain, body[cursor..]);
    return .{ try out.toOwnedSlice(retain), class };
}

// ---------------------------------------------------------------------------
// Report model + emit
// ---------------------------------------------------------------------------

pub const PageRecord = struct {
    source_path: []const u8,
    entity_id: []const u8,
    output_path: []const u8,
    title: []const u8,
    conversion: ConversionClass,
    notes: []const []const u8,
};

pub const MediaManifestEntry = struct {
    source_path: []const u8,
    output_path: []const u8,
    referenced: bool,
    copied: bool,
};

pub const UnsupportedItem = struct {
    source_path: []const u8,
    kind: []const u8,
    detail: []const u8,
};

pub const HumanReview = struct {
    source_path: []const u8,
    reason: []const u8,
    detail: []const u8,
};

pub const Report = struct {
    source_export: []const u8,
    pages: []PageRecord,
    links: []LinkFinding,
    hazards: []Hazard,
    media: []MediaManifestEntry,
    unsupported_items: []UnsupportedItem,
    human_review: []HumanReview,
    summary_pages: usize,
    summary_media: usize,
    summary_links_resolved: usize,
    summary_links_unresolved: usize,
    summary_links_ambiguous: usize,
    summary_databases: usize,
};

fn jsonEscapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [8]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(gpa, hex);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

fn appendUsizeField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, value: usize, trailing_comma: bool) !void {
    try buf.appendSlice(gpa, "    \"");
    try buf.appendSlice(gpa, name);
    try buf.appendSlice(gpa, "\": ");
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{value});
    try buf.appendSlice(gpa, s);
    if (trailing_comma) try buf.append(gpa, ',');
    try buf.append(gpa, '\n');
}

fn emitReportJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"format\": \"");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "\",\n  \"schema_version\": ");
    var tmp: [16]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{schema_version}));
    try buf.appendSlice(gpa, ",\n  \"tool_version\": \"");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "\",\n  \"source_export\": ");
    try jsonEscapeAppend(&buf, gpa, report.source_export);
    try buf.appendSlice(gpa, ",\n  \"summary\": {\n");
    try appendUsizeField(&buf, gpa, "pages", report.summary_pages, true);
    try appendUsizeField(&buf, gpa, "media", report.summary_media, true);
    try appendUsizeField(&buf, gpa, "links_resolved", report.summary_links_resolved, true);
    try appendUsizeField(&buf, gpa, "links_unresolved", report.summary_links_unresolved, true);
    try appendUsizeField(&buf, gpa, "links_ambiguous", report.summary_links_ambiguous, true);
    try appendUsizeField(&buf, gpa, "databases", report.summary_databases, false);
    try buf.appendSlice(gpa, "  },\n");

    try buf.appendSlice(gpa, "  \"pages\": [\n");
    for (report.pages, 0..) |p, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ",\n      \"entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.entity_id);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.output_path);
        try buf.appendSlice(gpa, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n      \"conversion\": \"");
        try buf.appendSlice(gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, "\",\n      \"notes\": [");
        for (p.notes, 0..) |n, ni| {
            if (ni > 0) try buf.appendSlice(gpa, ", ");
            try jsonEscapeAppend(&buf, gpa, n);
        }
        try buf.appendSlice(gpa, "]\n    }");
        if (i + 1 < report.pages.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"links\": [\n");
    for (report.links, 0..) |l, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, l.source_path);
        try buf.appendSlice(gpa, ",\n      \"raw\": ");
        try jsonEscapeAppend(&buf, gpa, l.raw);
        try buf.appendSlice(gpa, ",\n      \"status\": \"");
        try buf.appendSlice(gpa, l.status.jsonName());
        try buf.appendSlice(gpa, "\",\n      \"resolved_to\": ");
        if (l.resolved_to) |r| {
            try jsonEscapeAppend(&buf, gpa, r);
        } else {
            try buf.appendSlice(gpa, "null");
        }
        try buf.appendSlice(gpa, ",\n      \"note\": ");
        try jsonEscapeAppend(&buf, gpa, l.note);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.links.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"hazards\": [\n");
    for (report.hazards, 0..) |h, i| {
        try buf.appendSlice(gpa, "    {\n      \"kind\": \"");
        try buf.appendSlice(gpa, h.kind.jsonName());
        try buf.appendSlice(gpa, "\",\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, h.source_path);
        try buf.appendSlice(gpa, ",\n      \"detail\": ");
        try jsonEscapeAppend(&buf, gpa, h.detail);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.hazards.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"media\": [\n");
    for (report.media, 0..) |a, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.source_path);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.output_path);
        try buf.appendSlice(gpa, ",\n      \"referenced\": ");
        try buf.appendSlice(gpa, if (a.referenced) "true" else "false");
        try buf.appendSlice(gpa, ",\n      \"copied\": ");
        try buf.appendSlice(gpa, if (a.copied) "true" else "false");
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.media.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"unsupported_items\": [\n");
    for (report.unsupported_items, 0..) |u, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, u.source_path);
        try buf.appendSlice(gpa, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, u.kind);
        try buf.appendSlice(gpa, ",\n      \"detail\": ");
        try jsonEscapeAppend(&buf, gpa, u.detail);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.unsupported_items.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"human_review\": [\n");
    for (report.human_review, 0..) |hr, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, hr.source_path);
        try buf.appendSlice(gpa, ",\n      \"reason\": ");
        try jsonEscapeAppend(&buf, gpa, hr.reason);
        try buf.appendSlice(gpa, ",\n      \"detail\": ");
        try jsonEscapeAppend(&buf, gpa, hr.detail);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.human_review.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn appendMdCount(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, label: []const u8, n: usize) !void {
    try buf.appendSlice(gpa, "| ");
    try buf.appendSlice(gpa, label);
    try buf.appendSlice(gpa, " | ");
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
    try buf.appendSlice(gpa, " |\n");
}

fn emitReportMd(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "# Notion → Boris migration laboratory\n\n");
    try buf.appendSlice(gpa, "Format: `");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "` · schema ");
    var tmp: [16]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{schema_version}));
    try buf.appendSlice(gpa, " · tool ");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "\n\n");
    try buf.appendSlice(gpa, "Source export: `");
    try buf.appendSlice(gpa, report.source_export);
    try buf.appendSlice(gpa, "`\n\n");

    try buf.appendSlice(gpa, "## Summary\n\n");
    try buf.appendSlice(gpa, "| Metric | Count |\n|---|---:|\n");
    try appendMdCount(&buf, gpa, "Pages", report.summary_pages);
    try appendMdCount(&buf, gpa, "Media inventoried", report.summary_media);
    try appendMdCount(&buf, gpa, "Links resolved", report.summary_links_resolved);
    try appendMdCount(&buf, gpa, "Links unresolved", report.summary_links_unresolved);
    try appendMdCount(&buf, gpa, "Links ambiguous", report.summary_links_ambiguous);
    try appendMdCount(&buf, gpa, "Databases (CSV)", report.summary_databases);
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Pages\n\n");
    for (report.pages) |p| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, p.source_path);
        try buf.appendSlice(gpa, "` → `");
        try buf.appendSlice(gpa, p.entity_id);
        try buf.appendSlice(gpa, "` (");
        try buf.appendSlice(gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, ")\n");
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Links\n\n");
    for (report.links) |l| {
        if (l.status == .skipped_fence or l.status == .external_skipped) continue;
        try buf.appendSlice(gpa, "- [");
        try buf.appendSlice(gpa, l.status.jsonName());
        try buf.appendSlice(gpa, "] `");
        try buf.appendSlice(gpa, l.source_path);
        try buf.appendSlice(gpa, "`: `");
        try buf.appendSlice(gpa, l.raw);
        try buf.appendSlice(gpa, "`");
        if (l.resolved_to) |r| {
            try buf.appendSlice(gpa, " → `");
            try buf.appendSlice(gpa, r);
            try buf.appendSlice(gpa, "`");
        }
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Hazards\n\n");
    if (report.hazards.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.hazards) |h| {
            try buf.appendSlice(gpa, "- **");
            try buf.appendSlice(gpa, h.kind.jsonName());
            try buf.appendSlice(gpa, "** in `");
            try buf.appendSlice(gpa, h.source_path);
            try buf.appendSlice(gpa, "`: ");
            try buf.appendSlice(gpa, h.detail);
            try buf.append(gpa, '\n');
        }
        try buf.append(gpa, '\n');
    }

    try buf.appendSlice(gpa, "## Unsupported items\n\n");
    for (report.unsupported_items) |u| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, u.source_path);
        try buf.appendSlice(gpa, "` (");
        try buf.appendSlice(gpa, u.kind);
        try buf.appendSlice(gpa, "): ");
        try buf.appendSlice(gpa, u.detail);
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Human review queue\n\n");
    for (report.human_review) |hr| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, hr.source_path);
        try buf.appendSlice(gpa, "` — ");
        try buf.appendSlice(gpa, hr.reason);
        try buf.appendSlice(gpa, ": ");
        try buf.appendSlice(gpa, hr.detail);
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Media\n\n");
    for (report.media) |a| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, a.source_path);
        try buf.appendSlice(gpa, "` → `");
        try buf.appendSlice(gpa, a.output_path);
        try buf.appendSlice(gpa, "`");
        if (a.copied) try buf.appendSlice(gpa, " (copied)");
        if (a.referenced) try buf.appendSlice(gpa, " (referenced)");
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "---\n\nPhase-1 boundaries: official Markdown & CSV export only; ");
    try buf.appendSlice(gpa, "no Notion API/OAuth/network; databases/CSV, relation/rollup, ");
    try buf.appendSlice(gpa, "synced blocks, embeds, and ambiguous/unresolved links are flagged ");
    try buf.appendSlice(gpa, "for human review — never silently discarded. Export tree never modified.\n");
    return try buf.toOwnedSlice(gpa);
}

fn emitMediaManifest(gpa: std.mem.Allocator, entries: []const MediaManifestEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"format\": \"boris-notion-media-manifest\",\n  \"schema_version\": 1,\n  \"entries\": [\n");
    for (entries, 0..) |a, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.source_path);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.output_path);
        try buf.appendSlice(gpa, ",\n      \"referenced\": ");
        try buf.appendSlice(gpa, if (a.referenced) "true" else "false");
        try buf.appendSlice(gpa, ",\n      \"copied\": ");
        try buf.appendSlice(gpa, if (a.copied) "true" else "false");
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < entries.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

fn copyFileRel(io: Io, src_root: Io.Dir, src_rel: []const u8, dst_root: Io.Dir, dst_rel: []const u8) !void {
    const data = try readFileAlloc(io, src_root, src_rel, std.heap.page_allocator);
    defer std.heap.page_allocator.free(data);
    try writeBytes(io, dst_root, dst_rel, data);
}

fn buildProvenanceComment(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    entity_id: []const u8,
    page_id: ?[]const u8,
) ![]u8 {
    const pid = page_id orelse "";
    return try std.fmt.allocPrint(allocator,
        \\<!-- boris-migration-provenance
        \\  format: {s}
        \\  source_path: {s}
        \\  entity_id: {s}
        \\  notion_page_id: {s}
        \\  tool_version: {s}
        \\-->
        \\
    , .{ format_id, source_path, entity_id, pid, tool_version });
}

fn mediaOutputPath(allocator: std.mem.Allocator, export_path: []const u8) ![]u8 {
    // Keep structure; strip Notion ids from path segments; preserve file extension.
    const base = basenameOf(export_path);
    const dir = dirNameOf(export_path);
    const ext = blk: {
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            break :blk base[dot..];
        }
        break :blk "";
    };
    const stem = if (ext.len > 0) base[0 .. base.len - ext.len] else base;
    const stripped = stripNotionPageId(stem);
    var path_stem: []const u8 = undefined;
    var path_owned: ?[]u8 = null;
    defer if (path_owned) |p| allocator.free(p);
    if (dir.len > 0) {
        // Reuse pathToEntityId on a fake .md path for the directory segments + stem
        const fake = try std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ dir, stripped.title });
        defer allocator.free(fake);
        path_owned = try pathToEntityId(allocator, fake);
        path_stem = path_owned.?;
    } else {
        path_owned = try sanitizeEntityId(allocator, stripped.title);
        path_stem = path_owned.?;
    }
    return try std.fmt.allocPrint(allocator, "media/{s}{s}", .{ path_stem, ext });
}

fn disambiguateEntityIdCollisions(
    retain: std.mem.Allocator,
    pages: []PageEntry,
    unsupported: *std.ArrayList(UnsupportedItem),
) !void {
    if (pages.len < 2) return;

    const order = try retain.alloc(usize, pages.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, pages, struct {
        fn less(ps: []PageEntry, a: usize, b: usize) bool {
            const c = std.mem.order(u8, ps[a].entity_id, ps[b].entity_id);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, ps[a].export_path, ps[b].export_path) == .lt;
        }
    }.less);

    var i: usize = 0;
    while (i < order.len) {
        const base_id = pages[order[i]].entity_id;
        var j = i + 1;
        while (j < order.len and std.mem.eql(u8, pages[order[j]].entity_id, base_id)) : (j += 1) {}
        if (j - i > 1) {
            var suffix: usize = 2;
            var k: usize = i + 1;
            while (k < j) : (k += 1) {
                const idx = order[k];
                const original = pages[idx].entity_id;
                const new_id = try allocUniqueEntityId(retain, pages, original, &suffix);
                try unsupported.append(retain, .{
                    .source_path = pages[idx].export_path,
                    .kind = "entity_id_collision",
                    .detail = try std.fmt.allocPrint(retain, "collides with {s} → {s}; remapped to {s}", .{
                        pages[order[i]].export_path,
                        original,
                        new_id,
                    }),
                });
                pages[idx].entity_id = new_id;
                pages[idx].output_path = try std.fmt.allocPrint(retain, "content/{s}.md", .{new_id});
            }
        }
        i = j;
    }
}

fn entityIdTaken(pages: []const PageEntry, id: []const u8) bool {
    for (pages) |p| {
        if (std.mem.eql(u8, p.entity_id, id)) return true;
    }
    return false;
}

fn allocUniqueEntityId(
    retain: std.mem.Allocator,
    pages: []const PageEntry,
    base: []const u8,
    suffix: *usize,
) ![]u8 {
    while (suffix.* < 10_000) : (suffix.* += 1) {
        const candidate = try std.fmt.allocPrint(retain, "{s}-{d}", .{ base, suffix.* });
        if (!entityIdTaken(pages, candidate)) {
            suffix.* += 1;
            return candidate;
        }
    }
    return error.IdTooLong;
}

fn countPathDepth(entity_id: []const u8) usize {
    var n: usize = 0;
    for (entity_id) |c| {
        if (c == '/') n += 1;
    }
    return n;
}

/// Infer parent entity id from export folder nesting: child lives in
/// `<parent-stem>/…` where `<parent-stem>.md` is a sibling of that folder.
fn inferParentEntity(
    retain: std.mem.Allocator,
    pages: []const PageEntry,
    page: *const PageEntry,
) !?[]const u8 {
    const parent_dir = dirNameOf(page.export_path);
    if (parent_dir.len == 0) return null;
    // Parent page path is parent_dir + ".md" (Notion sibling folder naming)
    const candidate_md = try std.fmt.allocPrint(retain, "{s}.md", .{parent_dir});
    for (pages) |*p| {
        if (std.mem.eql(u8, p.export_path, candidate_md)) return p.entity_id;
        // also .mdx
    }
    const candidate_mdx = try std.fmt.allocPrint(retain, "{s}.mdx", .{parent_dir});
    for (pages) |*p| {
        if (std.mem.eql(u8, p.export_path, candidate_mdx)) return p.entity_id;
    }
    // Fallback: parent entity = pathToEntityId of parent_dir as if it were a page
    return try pathToEntityId(retain, try std.fmt.allocPrint(retain, "{s}.md", .{parent_dir}));
}

// ---------------------------------------------------------------------------
// Public run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const retain = arena_state.allocator();

    var export_root = try Io.Dir.cwd().openDir(io, opts.export_dir, .{ .iterate = true });
    defer export_root.close(io);

    var files: std.ArrayList(ExportFile) = .empty;
    defer files.deinit(gpa);
    try collectFiles(io, gpa, retain, export_root, "", &files);

    std.mem.sort(ExportFile, files.items, {}, struct {
        fn less(_: void, a: ExportFile, b: ExportFile) bool {
            return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
        }
    }.less);

    var pages_list: std.ArrayList(PageEntry) = .empty;
    var media_list: std.ArrayList(MediaEntry) = .empty;
    var unsupported: std.ArrayList(UnsupportedItem) = .empty;
    var n_databases: usize = 0;

    for (files.items) |f| {
        switch (f.kind) {
            .page => {
                const entity_id = try pathToEntityId(retain, f.rel_path);
                const export_stem = if (endsWithIgnoreCase(f.rel_path, ".mdx"))
                    f.rel_path[0 .. f.rel_path.len - 4]
                else if (endsWithIgnoreCase(f.rel_path, ".md"))
                    f.rel_path[0 .. f.rel_path.len - 3]
                else
                    f.rel_path;
                const bn = basenameStem(f.rel_path);
                const stripped = stripNotionPageId(bn);
                const output_path = try std.fmt.allocPrint(retain, "content/{s}.md", .{entity_id});
                const depth = countPathDepth(entity_id);
                try pages_list.append(retain, .{
                    .export_path = f.rel_path,
                    .export_stem = try retain.dupe(u8, export_stem),
                    .entity_id = entity_id,
                    .output_path = output_path,
                    .basename = try retain.dupe(u8, bn),
                    .title_basename = try retain.dupe(u8, stripped.title),
                    .page_id = if (stripped.page_id) |id| try retain.dupe(u8, id) else null,
                    .parent_entity = null,
                    .depth = depth,
                });
            },
            .media => {
                const outp = try mediaOutputPath(retain, f.rel_path);
                try media_list.append(retain, .{
                    .export_path = f.rel_path,
                    .output_path = outp,
                });
            },
            .database_csv => {
                n_databases += 1;
                try unsupported.append(retain, .{
                    .source_path = f.rel_path,
                    .kind = "database_csv",
                    .detail = "Notion database CSV view is not converted to Boris pages; inventoried for human review",
                });
            },
            .other => {
                try unsupported.append(retain, .{
                    .source_path = f.rel_path,
                    .kind = "other",
                    .detail = "non-page file not classified as media",
                });
            },
        }
    }

    try disambiguateEntityIdCollisions(retain, pages_list.items, &unsupported);

    // Assign parents from folder nesting (after collision remap so entity ids are final)
    for (pages_list.items) |*page| {
        page.parent_entity = try inferParentEntity(retain, pages_list.items, page);
    }

    std.mem.sort(PageEntry, pages_list.items, {}, struct {
        fn less(_: void, a: PageEntry, b: PageEntry) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);
    std.mem.sort(MediaEntry, media_list.items, {}, struct {
        fn less(_: void, a: MediaEntry, b: MediaEntry) bool {
            return std.mem.order(u8, a.export_path, b.export_path) == .lt;
        }
    }.less);

    const index = Index{
        .pages = pages_list.items,
        .media = media_list.items,
    };

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out_root = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out_root.close(io);

    var page_records: std.ArrayList(PageRecord) = .empty;
    var all_links: std.ArrayList(LinkFinding) = .empty;
    var all_hazards: std.ArrayList(Hazard) = .empty;
    var human_review: std.ArrayList(HumanReview) = .empty;
    var referenced: std.ArrayList([]const u8) = .empty;

    for (index.pages) |*page| {
        const raw = try readFileAlloc(io, export_root, page.export_path, gpa);
        defer gpa.free(raw);

        const fm = try parseFrontmatterLite(retain, raw);
        const body_src = if (fm.present and fm.body_offset <= raw.len) raw[fm.body_offset..] else raw;

        var notes: std.ArrayList([]const u8) = .empty;
        var class: ConversionClass = .exact;

        for (fm.unknown_keys) |uk| {
            class = ConversionClass.worse(class, .human_review);
            try notes.append(retain, try std.fmt.allocPrint(retain, "dropped unknown frontmatter key: {s}", .{uk}));
            try all_hazards.append(retain, .{
                .kind = .unknown_frontmatter_key,
                .source_path = page.export_path,
                .detail = try std.fmt.allocPrint(retain, "key `{s}` not in Boris closed grammar", .{uk}),
            });
            try human_review.append(retain, .{
                .source_path = page.export_path,
                .reason = "unknown_frontmatter_key",
                .detail = uk,
            });
        }
        if (fm.incompatible) {
            class = ConversionClass.worse(class, .human_review);
            try notes.append(retain, "incompatible frontmatter forms stripped or reported");
            try all_hazards.append(retain, .{
                .kind = .incompatible_frontmatter,
                .source_path = page.export_path,
                .detail = "nested or non-closed frontmatter constructs",
            });
        }
        for (fm.notes) |n| try notes.append(retain, n);

        // Database row pages (parent folder coexists with a CSV)
        if (page.export_path.len > 0) {
            const pdir = dirNameOf(page.export_path);
            if (pdir.len > 0) {
                const csv_path = try std.fmt.allocPrint(retain, "{s}.csv", .{pdir});
                for (unsupported.items) |u| {
                    if (std.mem.eql(u8, u.kind, "database_csv") and std.mem.eql(u8, u.source_path, csv_path)) {
                        class = ConversionClass.worse(class, .human_review);
                        try notes.append(retain, "page lives under a Notion database CSV export folder");
                        try human_review.append(retain, .{
                            .source_path = page.export_path,
                            .reason = "database_row_page",
                            .detail = csv_path,
                        });
                        break;
                    }
                }
            }
        }

        if (page.depth > 1) {
            class = ConversionClass.worse(class, .human_review);
            try notes.append(retain, "export nesting deeper than one hop; Boris graph is Trunk←Satellite only");
            try all_hazards.append(retain, .{
                .kind = .deep_hierarchy,
                .source_path = page.export_path,
                .detail = try std.fmt.allocPrint(retain, "entity depth {d}; review parent attachment", .{page.depth}),
            });
            try human_review.append(retain, .{
                .source_path = page.export_path,
                .reason = "deep_hierarchy",
                .detail = page.entity_id,
            });
        }

        const body_hazards = try detectBodyHazards(retain, page.export_path, body_src);
        for (body_hazards) |h| {
            class = ConversionClass.worse(class, .unsupported);
            try all_hazards.append(retain, h);
            try human_review.append(retain, .{
                .source_path = page.export_path,
                .reason = h.kind.jsonName(),
                .detail = h.detail,
            });
            try notes.append(retain, try std.fmt.allocPrint(retain, "hazard: {s}", .{h.kind.jsonName()}));
        }

        var page_links: std.ArrayList(LinkFinding) = .empty;
        const rewritten = try rewriteBody(retain, page.export_path, body_src, page, &index, &page_links, &all_hazards, &referenced);
        class = ConversionClass.worse(class, rewritten[1]);
        const new_body = rewritten[0];

        for (page_links.items) |lf| {
            try all_links.append(retain, lf);
            if (lf.status == .unresolved or lf.status == .ambiguous or lf.status == .unsupported_embed) {
                try human_review.append(retain, .{
                    .source_path = page.export_path,
                    .reason = lf.status.jsonName(),
                    .detail = lf.raw,
                });
            }
        }

        // Parent: prefer authored FM when resolvable; else hierarchy parent.
        var parent_out: ?[]const u8 = null;
        if (fm.parent) |par| {
            var resolved: ?[]const u8 = null;
            for (index.pages) |*p| {
                if (std.mem.eql(u8, p.entity_id, par) or std.mem.eql(u8, p.export_stem, par) or
                    std.mem.eql(u8, p.title_basename, par) or std.mem.eql(u8, p.basename, par))
                {
                    if (resolved != null and !std.mem.eql(u8, resolved.?, p.entity_id)) {
                        resolved = null;
                        class = ConversionClass.worse(class, .human_review);
                        try notes.append(retain, try std.fmt.allocPrint(retain, "ambiguous parent `{s}`; omitted", .{par}));
                        try human_review.append(retain, .{
                            .source_path = page.export_path,
                            .reason = "ambiguous_parent",
                            .detail = par,
                        });
                        break;
                    }
                    resolved = p.entity_id;
                }
            }
            if (resolved) |r| {
                parent_out = r;
                if (!std.mem.eql(u8, r, par)) {
                    class = ConversionClass.worse(class, .transformed);
                    try notes.append(retain, try std.fmt.allocPrint(retain, "parent `{s}` → `{s}`", .{ par, r }));
                }
            } else if (entityIdIsWikiSafe(par)) {
                parent_out = par;
            } else {
                class = ConversionClass.worse(class, .human_review);
                try notes.append(retain, try std.fmt.allocPrint(retain, "unresolved parent `{s}`; omitted", .{par}));
                try human_review.append(retain, .{
                    .source_path = page.export_path,
                    .reason = "unresolved_parent",
                    .detail = par,
                });
            }
        } else if (page.parent_entity) |pe| {
            parent_out = pe;
            class = ConversionClass.worse(class, .transformed);
            try notes.append(retain, try std.fmt.allocPrint(retain, "parent inferred from export folder: {s}", .{pe}));
        }

        const title = fm.title orelse page.title_basename;
        // Emit id only when override present; otherwise path-derived entity id is the file path.
        const id_field: ?[]const u8 = if (fm.id_override) |ov| ov else null;
        const fm_out = try buildFrontmatter(retain, id_field, title, parent_out, fm.status, fm.tags_raw);
        const prov = try buildProvenanceComment(retain, page.export_path, page.entity_id, page.page_id);

        var md: std.ArrayList(u8) = .empty;
        try md.appendSlice(retain, fm_out);
        try md.appendSlice(retain, prov);
        try md.appendSlice(retain, new_body);
        if (md.items.len == 0 or md.items[md.items.len - 1] != '\n') try md.append(retain, '\n');

        try writeBytes(io, out_root, page.output_path, md.items);

        try page_records.append(retain, .{
            .source_path = page.export_path,
            .entity_id = page.entity_id,
            .output_path = page.output_path,
            .title = title,
            .conversion = class,
            .notes = try notes.toOwnedSlice(retain),
        });
    }

    std.mem.sort(PageRecord, page_records.items, {}, struct {
        fn less(_: void, a: PageRecord, b: PageRecord) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);
    std.mem.sort(LinkFinding, all_links.items, {}, struct {
        fn less(_: void, a: LinkFinding, b: LinkFinding) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.raw, b.raw) == .lt;
        }
    }.less);
    std.mem.sort(Hazard, all_hazards.items, {}, struct {
        fn less(_: void, a: Hazard, b: Hazard) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const k = std.mem.order(u8, a.kind.jsonName(), b.kind.jsonName());
            if (k != .eq) return k == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
    std.mem.sort(HumanReview, human_review.items, {}, struct {
        fn less(_: void, a: HumanReview, b: HumanReview) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const r = std.mem.order(u8, a.reason, b.reason);
            if (r != .eq) return r == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
    std.mem.sort(UnsupportedItem, unsupported.items, {}, struct {
        fn less(_: void, a: UnsupportedItem, b: UnsupportedItem) bool {
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    // CSV → hazards + human_review
    for (unsupported.items) |u| {
        if (std.mem.eql(u8, u.kind, "database_csv")) {
            try all_hazards.append(retain, .{
                .kind = .database_csv,
                .source_path = u.source_path,
                .detail = u.detail,
            });
            try human_review.append(retain, .{
                .source_path = u.source_path,
                .reason = "database_csv",
                .detail = u.detail,
            });
        }
        if (std.mem.eql(u8, u.kind, "entity_id_collision")) {
            try human_review.append(retain, .{
                .source_path = u.source_path,
                .reason = "entity_id_collision",
                .detail = u.detail,
            });
        }
    }
    std.mem.sort(Hazard, all_hazards.items, {}, struct {
        fn less(_: void, a: Hazard, b: Hazard) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const k = std.mem.order(u8, a.kind.jsonName(), b.kind.jsonName());
            if (k != .eq) return k == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
    std.mem.sort(HumanReview, human_review.items, {}, struct {
        fn less(_: void, a: HumanReview, b: HumanReview) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const r = std.mem.order(u8, a.reason, b.reason);
            if (r != .eq) return r == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);

    var media_manifest: std.ArrayList(MediaManifestEntry) = .empty;
    for (index.media) |m| {
        var is_ref = false;
        for (referenced.items) |r| {
            if (std.mem.eql(u8, r, m.export_path)) {
                is_ref = true;
                break;
            }
        }
        const copy_ok = blk: {
            copyFileRel(io, export_root, m.export_path, out_root, m.output_path) catch break :blk false;
            break :blk true;
        };
        if (!copy_ok) {
            try human_review.append(retain, .{
                .source_path = m.export_path,
                .reason = "media_copy_failed",
                .detail = m.output_path,
            });
        }
        try media_manifest.append(retain, .{
            .source_path = m.export_path,
            .output_path = m.output_path,
            .referenced = is_ref,
            .copied = copy_ok,
        });
    }

    var n_resolved: usize = 0;
    var n_unresolved: usize = 0;
    var n_ambiguous: usize = 0;
    for (all_links.items) |l| {
        switch (l.status) {
            .resolved => n_resolved += 1,
            .unresolved => n_unresolved += 1,
            .ambiguous => n_ambiguous += 1,
            else => {},
        }
    }

    const report = Report{
        .source_export = opts.export_dir,
        .pages = page_records.items,
        .links = all_links.items,
        .hazards = all_hazards.items,
        .media = media_manifest.items,
        .unsupported_items = unsupported.items,
        .human_review = human_review.items,
        .summary_pages = page_records.items.len,
        .summary_media = media_manifest.items.len,
        .summary_links_resolved = n_resolved,
        .summary_links_unresolved = n_unresolved,
        .summary_links_ambiguous = n_ambiguous,
        .summary_databases = n_databases,
    };

    const json = try emitReportJson(gpa, report);
    defer gpa.free(json);
    try writeBytes(io, out_root, "report.json", json);

    const mdrep = try emitReportMd(gpa, report);
    defer gpa.free(mdrep);
    try writeBytes(io, out_root, "REPORT.md", mdrep);

    const man = try emitMediaManifest(gpa, media_manifest.items);
    defer gpa.free(man);
    try writeBytes(io, out_root, "media_manifest.json", man);

    if (!opts.quiet) {
        std.debug.print(
            "notion-migration-lab: wrote {s}/content/, {s}/media/, {s}/report.json, {s}/REPORT.md, {s}/media_manifest.json\n",
            .{ opts.out_dir, opts.out_dir, opts.out_dir, opts.out_dir, opts.out_dir },
        );
    }
}

// ---------------------------------------------------------------------------
// Unit + fixture tests
// ---------------------------------------------------------------------------

test "stripNotionPageId: title and 32-hex id" {
    const r = stripNotionPageId("Nested Guide bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try std.testing.expectEqualStrings("Nested Guide", r.title);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", r.page_id.?);

    const r2 = stripNotionPageId("NoIdHere");
    try std.testing.expectEqualStrings("NoIdHere", r2.title);
    try std.testing.expect(r2.page_id == null);
}

test "pathToEntityId: strips ids and sanitizes nested path" {
    const gpa = std.testing.allocator;
    const id = try pathToEntityId(gpa, "Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Nested Guide bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("Home/Nested-Guide", id);
}

test "percentDecodeAlloc: spaces and hex" {
    const gpa = std.testing.allocator;
    const d = try percentDecodeAlloc(gpa, "Home%20aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Nested%20Guide.md");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Nested Guide.md", d);
}

test "sanitizeEntityId: spaces to dashes" {
    const gpa = std.testing.allocator;
    const s = try sanitizeEntityId(gpa, "Q1 Plan");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("Q1-Plan", s);
}

test "isSkippedDirName: hidden and tooling" {
    try std.testing.expect(isSkippedDirName(".git"));
    try std.testing.expect(isSkippedDirName("node_modules"));
    try std.testing.expect(isSkippedDirName(".hidden-tool"));
    try std.testing.expect(!isSkippedDirName("Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "relativeLink: nested page to media" {
    const gpa = std.testing.allocator;
    const rel = try relativeLink(gpa, "content/Home/Nested-Guide.md", "media/Home/Nested-Guide/diagram.png");
    defer gpa.free(rel);
    try std.testing.expectEqualStrings("../../media/Home/Nested-Guide/diagram.png", rel);
}

test "detectBodyHazards: relation rollup synced embed" {
    const gpa = std.testing.allocator;
    const body =
        \\Relation: Related Page
        \\Rollup: Count
        \\<!-- synced block -->
        \\<iframe src="https://www.youtube.com/embed/xyz"></iframe>
        \\<!-- unsupported block: columns -->
    ;
    const hs = try detectBodyHazards(gpa, "x.md", body);
    defer {
        for (hs) |h| gpa.free(h.detail);
        gpa.free(hs);
    }
    try std.testing.expect(hs.len >= 3);
}

test "scanMarkdownLinks: image and link" {
    const gpa = std.testing.allocator;
    const body =
        \\See [Nested](Home%20aa/Nested.md) and ![d](img.png).
        \\
        \\```md
        \\[fence](x.md)
        \\```
    ;
    const hits = try scanMarkdownLinks(gpa, body);
    defer gpa.free(hits);
    try std.testing.expect(hits.len >= 2);
    try std.testing.expect(!hits[0].is_image);
    try std.testing.expect(hits[1].is_image);
}

test "fixture: notion end-to-end determinism + immutability + nested links + review" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var export_dir = try Io.Dir.cwd().openDir(io, "fixtures/mini-notion", .{});
    defer export_dir.close(io);
    const before = try readFileAlloc(io, export_dir, "Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", gpa);
    defer gpa.free(before);
    const before_png = try readFileAlloc(
        io,
        export_dir,
        "Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Nested Guide bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/diagram.png",
        gpa,
    );
    defer gpa.free(before_png);

    const out_a = "fixtures/.test-notion-out-a";
    const out_b = "fixtures/.test-notion-out-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    try run(io, gpa, .{ .export_dir = "fixtures/mini-notion", .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .export_dir = "fixtures/mini-notion", .out_dir = out_b, .quiet = true });

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);

    const ja = try readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try readFileAlloc(io, a, "REPORT.md", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, b, "REPORT.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    const mana = try readFileAlloc(io, a, "media_manifest.json", gpa);
    defer gpa.free(mana);
    const manb = try readFileAlloc(io, b, "media_manifest.json", gpa);
    defer gpa.free(manb);
    try std.testing.expectEqualStrings(mana, manb);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-notion-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"pages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"hazards\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"media\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"human_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unsupported_items\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"resolved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"ambiguous\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unresolved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "database_csv") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "relation_or_rollup") != null or std.mem.indexOf(u8, ja, "synced_block") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "node_modules") == null);

    // Nested page content + parent inference
    const nested = try readFileAlloc(io, a, "content/Home/Nested-Guide.md", gpa);
    defer gpa.free(nested);
    try std.testing.expect(std.mem.indexOf(u8, nested, "boris-migration-provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested, "parent:") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested, "Home") != null);

    const home = try readFileAlloc(io, a, "content/Home.md", gpa);
    defer gpa.free(home);
    try std.testing.expect(std.mem.indexOf(u8, home, "[[Home/Nested-Guide") != null or std.mem.indexOf(u8, home, "Nested-Guide") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "media/") != null or std.mem.indexOf(u8, home, "diagram.png") != null);
    // unresolved / ambiguous retained raw
    try std.testing.expect(std.mem.indexOf(u8, home, "Missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "Shared Name") != null);

    // Content-byte determinism
    const home_b = try readFileAlloc(io, b, "content/Home.md", gpa);
    defer gpa.free(home_b);
    try std.testing.expectEqualStrings(home, home_b);

    // Deep page flagged for hierarchy
    const deep = try readFileAlloc(io, a, "content/Home/Nested-Guide/Deep-Page.md", gpa);
    defer gpa.free(deep);
    try std.testing.expect(std.mem.indexOf(u8, deep, "parent:") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "deep_hierarchy") != null);

    // Media copied
    const png = try readFileAlloc(io, a, "media/Home/Nested-Guide/diagram.png", gpa);
    defer gpa.free(png);
    try std.testing.expectEqualStrings(before_png, png);

    // Source immutability
    const after = try readFileAlloc(io, export_dir, "Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    const after_png = try readFileAlloc(
        io,
        export_dir,
        "Home aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Nested Guide bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/diagram.png",
        gpa,
    );
    defer gpa.free(after_png);
    try std.testing.expectEqualStrings(before_png, after_png);

    try std.testing.expect(std.mem.indexOf(u8, ma, "# Notion → Boris migration laboratory") != null);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}
