//! Instagram data-download (Takeout) → Boris migration laboratory core.
//!
//! Reads an unpacked Instagram export directory (JSON and/or HTML post
//! records + local media), emits deterministic Boris-ready Markdown under
//! `--out/content/`, a generated theme with copied media assets, plus
//! report.json / REPORT.md / media_manifest.json. Never mutates the dump.
//! No network, zip extraction, shelling out, or OCR.
//!
//! Not part of the Boris product compiler pipeline.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-instagram-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    /// Unpacked Instagram data-download root (never modified).
    dump_dir: []const u8,
    /// Output root: content/, theme/, reports.
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

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

pub const MediaItem = struct {
    uri: []const u8,
    creation_timestamp: ?i64 = null,
    title: []const u8 = "",
    present: bool = false,
    theme_rel: []const u8 = "", // assets/media/...
};

pub const RecordKind = enum {
    post,
    reel,
    story,
    other,
    unknown,

    pub fn name(self: RecordKind) []const u8 {
        return switch (self) {
            .post => "post",
            .reel => "reel",
            .story => "story",
            .other => "other",
            .unknown => "unknown",
        };
    }
};

pub const IgRecord = struct {
    kind: RecordKind,
    source_json_path: []const u8, // dump-relative path to JSON/HTML source
    source_index: usize, // 0-based index within that file
    title: []const u8, // caption (original bytes preserved as UTF-8 slice)
    creation_timestamp: ?i64,
    media: []MediaItem,
    entity_id: []const u8,
    id_strategy: []const u8, // durable_export_id | fallback_hash
    conversion: ConversionClass,
    notes: []const []const u8,
    output_path: []const u8,
};

pub const MediaManifestEntry = struct {
    entity_id: []const u8,
    source_uri: []const u8,
    theme_asset: []const u8,
    status: []const u8, // present | missing | video | skipped
    kind: []const u8,
    creation_timestamp: ?i64,
};

pub const PageRecord = struct {
    output_path: []const u8,
    entity_id: []const u8,
    kind: []const u8,
    title: []const u8,
    timestamp: ?i64,
    conversion: ConversionClass,
    source_json_path: []const u8,
    media_count: usize,
    id_strategy: []const u8,
    notes: []const []const u8,
};

pub const Report = struct {
    source_dump: []const u8,
    pages: []PageRecord,
    media_manifest: []MediaManifestEntry,
    missing_media: []MediaManifestEntry,
    human_review: []PageRecord,
    unsupported: []PageRecord,
    summary_posts: usize,
    summary_reels: usize,
    summary_stories: usize,
    summary_other: usize,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and std.ascii.isWhitespace(s[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn isSkippedDirName(name: []const u8) bool {
    const skip = [_][]const u8{ ".git", ".DS_Store", "zig-cache", ".zig-cache" };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

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
    try ensureParent(io, dst_root, dst_rel);
    // Read + write (no shell; preserves source bytes).
    const bytes = try readFileAlloc(io, src_root, src_rel, std.heap.page_allocator);
    defer std.heap.page_allocator.free(bytes);
    try writeBytes(io, dst_root, dst_rel, bytes);
}

fn pathExists(io: Io, root: Io.Dir, rel: []const u8) bool {
    _ = root.statFile(io, rel, .{}) catch return false;
    return true;
}

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
                    try buf.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

pub fn escapeFmValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var needs_quote = false;
    for (value) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '[' or c == ']' or c == '\n' or c == ',' or c == '{' or c == '}') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote and value.len > 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) needs_quote = true;
    if (!needs_quote) return try allocator.dupe(u8, value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |c| {
        if (c == '"') try out.appendSlice(allocator, "'") else if (c != '\n' and c != '\r') try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

/// Extract a durable export id from a media URI/filename (longest digit run ≥10).
pub fn extractDurableId(uri: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(uri);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    var best_start: ?usize = null;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < stem.len) {
        if (stem[i] >= '0' and stem[i] <= '9') {
            const start = i;
            while (i < stem.len and stem[i] >= '0' and stem[i] <= '9') : (i += 1) {}
            const len = i - start;
            if (len > best_len) {
                best_len = len;
                best_start = start;
            }
        } else {
            i += 1;
        }
    }
    if (best_start) |s| {
        if (best_len >= 10) return stem[s .. s + best_len];
        if (best_len >= 6) return stem[s .. s + best_len];
    }
    return null;
}

pub fn fallbackHashId(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var h: u64 = 14695981039346656037;
    for (parts) |p| {
        for (p) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        h ^= 0xff;
        h *%= 1099511628211;
    }
    return try std.fmt.allocPrint(allocator, "fb{x:0>16}", .{h});
}

pub fn firstLineTitle(caption: []const u8, max_len: usize) []const u8 {
    var line = caption;
    if (std.mem.indexOfScalar(u8, caption, '\n')) |nl| line = caption[0..nl];
    line = trimSpace(line);
    if (line.len == 0) return "Untitled Instagram post";
    if (line.len <= max_len) return line;
    return line[0..max_len];
}

fn jsonGetString(obj: std.json.Value, key: []const u8) []const u8 {
    if (obj != .object) return "";
    const v = obj.object.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn jsonGetI64(obj: std.json.Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn parseMediaObject(retain: std.mem.Allocator, v: std.json.Value) !MediaItem {
    const uri = try retain.dupe(u8, jsonGetString(v, "uri"));
    const title = try retain.dupe(u8, jsonGetString(v, "title"));
    const ts = jsonGetI64(v, "creation_timestamp");
    return .{
        .uri = uri,
        .creation_timestamp = ts,
        .title = title,
    };
}

fn parseRecordObject(
    retain: std.mem.Allocator,
    v: std.json.Value,
    kind: RecordKind,
    source_path: []const u8,
    index: usize,
) !IgRecord {
    var media_list: std.ArrayList(MediaItem) = .empty;
    errdefer media_list.deinit(retain);

    // title / caption at record level
    var title = jsonGetString(v, "title");
    var ts = jsonGetI64(v, "creation_timestamp");

    if (v == .object) {
        if (v.object.get("media")) |media_v| {
            switch (media_v) {
                .array => |arr| {
                    for (arr.items) |m| {
                        const item = try parseMediaObject(retain, m);
                        try media_list.append(retain, item);
                    }
                },
                .object => {
                    const item = try parseMediaObject(retain, media_v);
                    try media_list.append(retain, item);
                },
                else => {},
            }
        } else if (jsonGetString(v, "uri").len > 0) {
            // flat media object as record
            const item = try parseMediaObject(retain, v);
            try media_list.append(retain, item);
            if (title.len == 0) title = item.title;
            if (ts == null) ts = item.creation_timestamp;
        }
    }

    // caption fallback from first media title
    if (title.len == 0 and media_list.items.len > 0) {
        title = media_list.items[0].title;
    }
    if (ts == null and media_list.items.len > 0) {
        ts = media_list.items[0].creation_timestamp;
    }

    const title_owned = try retain.dupe(u8, title);
    const source_owned = try retain.dupe(u8, source_path);

    return .{
        .kind = kind,
        .source_json_path = source_owned,
        .source_index = index,
        .title = title_owned,
        .creation_timestamp = ts,
        .media = try media_list.toOwnedSlice(retain),
        .entity_id = "",
        .id_strategy = "",
        .conversion = .exact,
        .notes = &.{},
        .output_path = "",
    };
}

fn parseJsonArrayRecords(
    retain: std.mem.Allocator,
    root: std.json.Value,
    kind: RecordKind,
    source_path: []const u8,
    out: *std.ArrayList(IgRecord),
) !void {
    switch (root) {
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                const rec = try parseRecordObject(retain, item, kind, source_path, i);
                try out.append(retain, rec);
            }
        },
        .object => {
            // sometimes wrapped
            if (root.object.get("media")) |_| {
                const rec = try parseRecordObject(retain, root, kind, source_path, 0);
                try out.append(retain, rec);
            } else {
                // try common keys
                const keys = [_][]const u8{ "posts", "items", "data", "reels", "stories" };
                for (keys) |k| {
                    if (root.object.get(k)) |inner| {
                        try parseJsonArrayRecords(retain, inner, kind, source_path, out);
                        return;
                    }
                }
                // single unknown object — still preserve
                const rec = try parseRecordObject(retain, root, kind, source_path, 0);
                try out.append(retain, rec);
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// HTML export fallback (Meta HTML download format)
// ---------------------------------------------------------------------------

const html_post_split = "pam _3-95 _2ph- _a6-g uiBoxWhite noborder";

fn htmlUnescapeBasic(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&#039;") or std.mem.startsWith(u8, input[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += if (input[i + 1] == '#') 6 else 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&#064;")) {
                try out.append(allocator, '@');
                i += 6;
                continue;
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn stripTags(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, html, i, '>')) |gt| {
                i = gt + 1;
                continue;
            }
            break;
        }
        try out.append(allocator, html[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn daysFromCivil(year: i32, month: u32, day: u32) i64 {
    // Howard Hinnant civil_from_days inverse (UTC days since 1970-01-01).
    var y: i32 = year;
    var m: i32 = @intCast(month);
    if (m <= 2) {
        y -= 1;
        m += 9;
    } else {
        m -= 3;
    }
    const era = @divFloor(y, 400);
    const yoe: i32 = y - era * 400;
    const doy = @divFloor(153 * m + 2, 5) + @as(i32, @intCast(day)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @as(i64, era) * 146097 + @as(i64, doe) - 719468;
}

/// Very small date parser: "Nov 19, 2024 7:07 am" → unix (UTC approximation).
pub fn parseIgDateString(raw: []const u8) ?i64 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var mon: u32 = 0;
    var rest = trimSpace(raw);
    for (months, 0..) |m, idx| {
        if (std.mem.startsWith(u8, rest, m)) {
            mon = @intCast(idx + 1);
            rest = trimSpace(rest[m.len..]);
            break;
        }
    }
    if (mon == 0) return null;
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    const day = std.fmt.parseInt(u32, trimSpace(rest[0..comma]), 10) catch return null;
    rest = trimSpace(rest[comma + 1 ..]);
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const year = std.fmt.parseInt(i32, rest[0..sp], 10) catch return null;
    rest = trimSpace(rest[sp + 1 ..]);
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    var hour = std.fmt.parseInt(u32, rest[0..colon], 10) catch return null;
    rest = rest[colon + 1 ..];
    var mi: usize = 0;
    while (mi < rest.len and rest[mi] >= '0' and rest[mi] <= '9') : (mi += 1) {}
    const minute = std.fmt.parseInt(u32, rest[0..mi], 10) catch 0;
    rest = trimSpace(rest[mi..]);
    const is_pm = std.mem.startsWith(u8, rest, "pm") or std.mem.startsWith(u8, rest, "PM");
    const is_am = std.mem.startsWith(u8, rest, "am") or std.mem.startsWith(u8, rest, "AM");
    if (is_pm and hour != 12) hour += 12;
    if (is_am and hour == 12) hour = 0;
    const days = daysFromCivil(year, mon, day);
    return days * 86400 + @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(minute)) * 60;
}

fn parseHtmlPostsFile(
    retain: std.mem.Allocator,
    gpa: std.mem.Allocator,
    html: []const u8,
    source_path: []const u8,
    kind: RecordKind,
    out: *std.ArrayList(IgRecord),
) !void {
    var from: usize = 0;
    var index: usize = 0;
    while (from < html.len) {
        const rel = std.mem.indexOfPos(u8, html, from, html_post_split) orelse break;
        // walk back to start of div
        var start = rel;
        while (start > 0 and html[start] != '<') start -= 1;
        const next = std.mem.indexOfPos(u8, html, rel + html_post_split.len, html_post_split);
        const end = if (next) |n| n else html.len;
        const block = html[start..end];
        from = end;

        // caption
        var caption: []const u8 = "";
        if (std.mem.indexOf(u8, block, "_a6-h _a6-i\">")) |c0| {
            const cs = c0 + "_a6-h _a6-i\">".len;
            if (std.mem.indexOfPos(u8, block, cs, "</div>")) |ce| {
                const raw = block[cs..ce];
                const stripped = try stripTags(gpa, raw);
                defer gpa.free(stripped);
                const unesc = try htmlUnescapeBasic(retain, stripped);
                caption = unesc;
            }
        }
        // date
        var ts: ?i64 = null;
        if (std.mem.indexOf(u8, block, "_a6-o\">")) |d0| {
            const ds = d0 + "_a6-o\">".len;
            if (std.mem.indexOfPos(u8, block, ds, "</div>")) |de| {
                ts = parseIgDateString(block[ds..de]);
            }
        }
        // media srcs
        var media_list: std.ArrayList(MediaItem) = .empty;
        var search: usize = 0;
        while (search < block.len) {
            const key = "src=\"";
            const srel = std.mem.indexOfPos(u8, block, search, key) orelse break;
            const ss = srel + key.len;
            const se = std.mem.indexOfScalarPos(u8, block, ss, '"') orelse break;
            const src = block[ss..se];
            search = se + 1;
            if (!std.mem.startsWith(u8, src, "media/")) continue;
            try media_list.append(retain, .{
                .uri = try retain.dupe(u8, src),
                .creation_timestamp = ts,
                .title = caption,
            });
        }

        // skip chrome-only blocks with no caption and no media
        if (caption.len == 0 and media_list.items.len == 0) {
            media_list.deinit(retain);
            continue;
        }

        try out.append(retain, .{
            .kind = kind,
            .source_json_path = try retain.dupe(u8, source_path),
            .source_index = index,
            .title = if (caption.len > 0) caption else try retain.dupe(u8, ""),
            .creation_timestamp = ts,
            .media = try media_list.toOwnedSlice(retain),
            .entity_id = "",
            .id_strategy = "",
            .conversion = .transformed, // HTML→structured is a transform
            .notes = &.{},
            .output_path = "",
        });
        index += 1;
    }
}

// ---------------------------------------------------------------------------
// Dump discovery
// ---------------------------------------------------------------------------

fn contentDirRel(dump_has_activity: bool) []const u8 {
    return if (dump_has_activity)
        "your_instagram_activity/content"
    else
        "content";
}

fn listJsonAndHtml(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    content_dir: Io.Dir,
    content_prefix: []const u8,
    out_paths: *std.ArrayList([]const u8),
) !void {
    var it = content_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const is_json = std.mem.endsWith(u8, name, ".json");
        const is_html = std.mem.endsWith(u8, name, ".html");
        if (!is_json and !is_html) continue;
        // only content archives we care about
        const interesting =
            std.mem.startsWith(u8, name, "posts") or
            std.mem.startsWith(u8, name, "reels") or
            std.mem.startsWith(u8, name, "stories") or
            std.mem.startsWith(u8, name, "other_content") or
            std.mem.eql(u8, name, "profile_photos.html") or
            std.mem.eql(u8, name, "profile_photos.json");
        if (!interesting) continue;
        const full = try std.fmt.allocPrint(retain, "{s}/{s}", .{ content_prefix, name });
        try out_paths.append(gpa, full);
    }
    std.mem.sort([]const u8, out_paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

fn kindFromSourcePath(path: []const u8) RecordKind {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "posts")) return .post;
    if (std.mem.startsWith(u8, base, "reels")) return .reel;
    if (std.mem.startsWith(u8, base, "stories")) return .story;
    if (std.mem.startsWith(u8, base, "other")) return .other;
    return .unknown;
}

fn assignEntityIds(retain: std.mem.Allocator, records: []IgRecord) !void {
    var used: std.StringHashMapUnmanaged(void) = .{};
    defer used.deinit(retain);

    for (records) |*rec| {
        var notes: std.ArrayList([]const u8) = .empty;
        var strategy: []const u8 = "fallback_hash";
        var id_core: []u8 = undefined;

        // Prefer durable id from first media uri
        if (rec.media.len > 0) {
            if (extractDurableId(rec.media[0].uri)) |did| {
                id_core = try retain.dupe(u8, did);
                strategy = "durable_export_id";
            } else {
                id_core = try fallbackHashId(retain, &.{ rec.source_json_path, rec.media[0].uri, rec.title });
                try notes.append(retain, try retain.dupe(u8, "no durable media id; used fallback_hash"));
            }
        } else {
            const ts_s = if (rec.creation_timestamp) |t|
                try std.fmt.allocPrint(retain, "{d}", .{t})
            else
                try retain.dupe(u8, "nots");
            id_core = try fallbackHashId(retain, &.{ rec.source_json_path, ts_s, rec.title, rec.kind.name() });
            try notes.append(retain, try retain.dupe(u8, "empty media; used fallback_hash"));
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
        }

        // prefix by kind for entity path
        const prefix = switch (rec.kind) {
            .post => "instagram",
            .reel => "instagram",
            .story => "instagram",
            .other => "instagram",
            .unknown => "instagram",
        };
        var entity = try std.fmt.allocPrint(retain, "{s}/{s}-{s}", .{ prefix, rec.kind.name(), id_core });
        // disambiguate collisions
        var n: usize = 2;
        while (used.contains(entity)) {
            const alt = try std.fmt.allocPrint(retain, "{s}/{s}-{s}-{d}", .{ prefix, rec.kind.name(), id_core, n });
            entity = alt;
            n += 1;
            try notes.append(retain, try retain.dupe(u8, "entity id collision; appended counter"));
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
        }
        try used.put(retain, entity, {});

        // classifications
        if (rec.media.len > 1) {
            rec.conversion = ConversionClass.worse(rec.conversion, .transformed);
            try notes.append(retain, try retain.dupe(u8, "carousel: multiple media items"));
        }
        for (rec.media) |m| {
            if (std.mem.endsWith(u8, m.uri, ".mp4") or std.mem.endsWith(u8, m.uri, ".mov")) {
                rec.conversion = ConversionClass.worse(rec.conversion, .transformed);
                try notes.append(retain, try retain.dupe(u8, "video media present (no embed; path preserved)"));
            }
        }
        if (rec.kind == .story or rec.kind == .reel) {
            rec.conversion = ConversionClass.worse(rec.conversion, .transformed);
        }
        if (rec.kind == .other or rec.kind == .unknown) {
            rec.conversion = ConversionClass.worse(rec.conversion, .unsupported);
            try notes.append(retain, try retain.dupe(u8, "non-post archive kind"));
        }
        if (rec.title.len == 0) {
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
            try notes.append(retain, try retain.dupe(u8, "empty caption"));
        }

        rec.entity_id = entity;
        rec.id_strategy = try retain.dupe(u8, strategy);
        rec.notes = try notes.toOwnedSlice(retain);
        rec.output_path = try std.fmt.allocPrint(retain, "content/{s}.md", .{entity});
    }
}

fn classifyMediaPresence(io: Io, dump: Io.Dir, rec: *IgRecord, retain: std.mem.Allocator) !void {
    for (rec.media) |*m| {
        // normalize uri (no leading ./)
        var uri = m.uri;
        if (std.mem.startsWith(u8, uri, "./")) uri = uri[2..];
        m.present = pathExists(io, dump, uri);
        if (!m.present) {
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
            // append note
            var notes: std.ArrayList([]const u8) = .empty;
            try notes.appendSlice(retain, rec.notes);
            try notes.append(retain, try std.fmt.allocPrint(retain, "missing media: {s}", .{uri}));
            rec.notes = try notes.toOwnedSlice(retain);
        }
        // theme destination preserves media/… under assets/
        m.theme_rel = try std.fmt.allocPrint(retain, "assets/{s}", .{uri});
    }
}

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------

fn buildFrontmatter(
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    status: []const u8,
    tags: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "---\n");
    try buf.print(allocator, "id: {s}\n", .{id});
    const title_e = try escapeFmValue(allocator, title);
    defer allocator.free(title_e);
    try buf.print(allocator, "title: {s}\n", .{title_e});
    if (parent) |p| try buf.print(allocator, "parent: {s}\n", .{p});
    try buf.print(allocator, "status: {s}\n", .{status});
    if (tags.len > 0) {
        try buf.appendSlice(allocator, "tags: [");
        for (tags, 0..) |t, idx| {
            if (idx > 0) try buf.appendSlice(allocator, ", ");
            var safe = true;
            for (t) |c| {
                if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) safe = false;
            }
            if (safe) try buf.appendSlice(allocator, t) else try buf.print(allocator, "\"{s}\"", .{t});
        }
        try buf.appendSlice(allocator, "]\n");
    }
    try buf.appendSlice(allocator, "---\n");
    return try buf.toOwnedSlice(allocator);
}

fn formatTimestamp(ts: ?i64, buf: *[32]u8) []const u8 {
    if (ts) |t| {
        return std.fmt.bufPrint(buf, "{d}", .{t}) catch "?";
    }
    return "unknown";
}

fn writeRecordMarkdown(allocator: std.mem.Allocator, rec: IgRecord) ![]u8 {
    var tags_buf: [8][]const u8 = undefined;
    var tag_n: usize = 0;
    tags_buf[tag_n] = "instagram";
    tag_n += 1;
    tags_buf[tag_n] = rec.kind.name();
    tag_n += 1;
    if (rec.conversion == .human_review) {
        tags_buf[tag_n] = "needs-review";
        tag_n += 1;
    }

    const title = firstLineTitle(rec.title, 72);
    const fm = try buildFrontmatter(allocator, rec.entity_id, title, "instagram", "published", tags_buf[0..tag_n]);
    defer allocator.free(fm);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, fm);
    try body.append(allocator, '\n');

    try body.print(allocator, "# {s}\n\n", .{title});

    var tsbuf: [32]u8 = undefined;
    const ts_s = formatTimestamp(rec.creation_timestamp, &tsbuf);
    try body.print(allocator, "- **timestamp:** `{s}`\n", .{ts_s});
    try body.print(allocator, "- **kind:** `{s}`\n", .{rec.kind.name()});
    try body.print(allocator, "- **source:** `{s}` (record index {d})\n", .{ rec.source_json_path, rec.source_index });
    try body.print(allocator, "- **entity id strategy:** `{s}`\n\n", .{rec.id_strategy});

    // caption original bytes as fenced block (preserve)
    try body.appendSlice(allocator, "## Caption\n\n");
    if (rec.title.len > 0) {
        try body.appendSlice(allocator, "```\n");
        try body.appendSlice(allocator, rec.title);
        if (rec.title[rec.title.len - 1] != '\n') try body.append(allocator, '\n');
        try body.appendSlice(allocator, "```\n\n");
    } else {
        try body.appendSlice(allocator, "_Empty caption._\n\n");
    }

    // media
    try body.appendSlice(allocator, "## Media\n\n");
    if (rec.media.len == 0) {
        try body.appendSlice(allocator, "_No media URIs on this record._\n\n");
    } else {
        for (rec.media, 0..) |m, i| {
            try body.print(allocator, "### Item {d}\n\n", .{i + 1});
            try body.print(allocator, "- **source uri:** `{s}`\n", .{m.uri});
            try body.print(allocator, "- **theme asset:** `{s}`\n", .{m.theme_rel});
            try body.print(allocator, "- **status:** `{s}`\n\n", .{if (m.present) "present" else "missing"});
            if (m.present and !std.mem.endsWith(u8, m.uri, ".mp4") and !std.mem.endsWith(u8, m.uri, ".mov")) {
                // page is content/instagram/x.md → HTML instagram/x.html → ../assets/...
                try body.print(allocator, "![media {d}](../{s})\n\n", .{ i + 1, m.theme_rel });
            } else if (m.present) {
                try body.appendSlice(allocator, "_Video file copied into theme assets; not embedded in this pass (no OCR/transcode)._\n\n");
            } else {
                try body.appendSlice(allocator, "_Media file missing from dump; URI preserved for review._\n\n");
            }
        }
    }

    // conversion notes
    try body.appendSlice(allocator, "## Conversion notes\n\n");
    try body.print(allocator, "- **class:** `{s}`\n", .{rec.conversion.jsonName()});
    if (rec.notes.len == 0) {
        try body.appendSlice(allocator, "- _none_\n");
    } else {
        for (rec.notes) |n| {
            try body.print(allocator, "- {s}\n", .{n});
        }
    }
    try body.append(allocator, '\n');

    // provenance HTML comment
    try body.appendSlice(allocator,
        \\<!-- boris-migration-provenance
        \\source_format: instagram-takeout
        \\
    );
    try body.print(allocator, "source_json_path: {s}\n", .{rec.source_json_path});
    try body.print(allocator, "source_index: {d}\n", .{rec.source_index});
    try body.print(allocator, "entity_id: {s}\n", .{rec.entity_id});
    try body.print(allocator, "id_strategy: {s}\n", .{rec.id_strategy});
    try body.print(allocator, "kind: {s}\n", .{rec.kind.name()});
    try body.print(allocator, "creation_timestamp: {s}\n", .{ts_s});
    try body.print(allocator, "conversion: {s}\n", .{rec.conversion.jsonName()});
    try body.appendSlice(allocator, "media:\n");
    for (rec.media) |m| {
        try body.print(allocator, "  - uri: {s}\n", .{m.uri});
        try body.print(allocator, "    theme: {s}\n", .{m.theme_rel});
        try body.print(allocator, "    present: {s}\n", .{if (m.present) "true" else "false"});
    }
    try body.appendSlice(allocator,
        \\-->
        \\
    );

    return try body.toOwnedSlice(allocator);
}

fn writeTrunkMarkdown(allocator: std.mem.Allocator, records: []const IgRecord) ![]u8 {
    const fm = try buildFrontmatter(allocator, "instagram", "Instagram archive", null, "published", &.{ "instagram", "archive" });
    defer allocator.free(fm);
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, fm);
    try body.appendSlice(allocator,
        \\
        \\# Instagram archive
        \\
        \\Migrated from an unpacked Instagram data-download (Takeout). Each child
        \\page is one post, reel, story, or other archive record.
        \\
        \\## Records
        \\
        \\
    );
    // chronological ascending by timestamp (nulls last), then entity_id
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    try order.ensureTotalCapacity(allocator, records.len);
    for (records, 0..) |_, i| try order.append(allocator, i);
    std.mem.sort(usize, order.items, records, struct {
        fn less(recs: []const IgRecord, a: usize, b: usize) bool {
            const ta = recs[a].creation_timestamp;
            const tb = recs[b].creation_timestamp;
            if (ta == null and tb == null) return std.mem.order(u8, recs[a].entity_id, recs[b].entity_id) == .lt;
            if (ta == null) return false;
            if (tb == null) return true;
            if (ta.? != tb.?) return ta.? < tb.?;
            return std.mem.order(u8, recs[a].entity_id, recs[b].entity_id) == .lt;
        }
    }.less);
    for (order.items) |i| {
        const r = records[i];
        const leaf = if (std.mem.lastIndexOfScalar(u8, r.entity_id, '/')) |s| r.entity_id[s + 1 ..] else r.entity_id;
        try body.print(allocator, "- [{s}](instagram/{s}.md) — `{s}` — {s}\n", .{
            firstLineTitle(r.title, 60),
            leaf,
            r.kind.name(),
            r.conversion.jsonName(),
        });
    }
    try body.appendSlice(allocator,
        \\
        \\<!-- boris-migration-provenance
        \\source_format: instagram-takeout
        \\role: trunk
        \\entity_id: instagram
        \\conversion: exact
        \\-->
        \\
    );
    return try body.toOwnedSlice(allocator);
}

fn writeThemeShell(io: Io, out_root: Io.Dir) !void {
    try writeBytes(io, out_root, "theme/layouts/main.html",
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>{{title}} · Instagram migration</title>
        \\  <link rel="stylesheet" href="{{asset-url assets/css/site.css}}">
        \\</head>
        \\<body>
        \\  <header><strong>Instagram migration</strong> {{breadcrumb}}</header>
        \\  <div class="shell">
        \\    <aside>{{nav}}</aside>
        \\    <main>{{metadata}}{{toc}}{{content}}</main>
        \\  </div>
        \\  <footer>{{footer}}</footer>
        \\</body>
        \\</html>
        \\
    );
    try writeBytes(io, out_root, "theme/footer.html",
        \\<p>Generated by boris-instagram-migration-lab · offline Takeout import</p>
        \\
    );
    try writeBytes(io, out_root, "theme/assets/css/site.css",
        \\body{font-family:system-ui,sans-serif;margin:0;padding:1rem;line-height:1.55;color:#1a1528;background:#f6f3fb}
        \\.shell{display:grid;gap:1rem;max-width:72rem;margin:0 auto}
        \\@media(min-width:50rem){.shell{grid-template-columns:14rem 1fr}}
        \\aside{font-size:.9rem}img{max-width:100%;height:auto;border-radius:.5rem}
        \\header,footer{max-width:72rem;margin:0 auto 1rem;color:#5c5470}
        \\
    );
}

fn emitReportJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"format\": ");
    try jsonEscapeAppend(&buf, gpa, format_id);
    try buf.print(gpa, ",\n  \"schema_version\": {d},\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, gpa, tool_version);
    try buf.appendSlice(gpa, ",\n  \"source_dump\": ");
    try jsonEscapeAppend(&buf, gpa, report.source_dump);
    try buf.appendSlice(gpa, ",\n  \"summary\": {\n");
    try buf.print(gpa, "    \"pages\": {d},\n", .{report.pages.len});
    try buf.print(gpa, "    \"posts\": {d},\n", .{report.summary_posts});
    try buf.print(gpa, "    \"reels\": {d},\n", .{report.summary_reels});
    try buf.print(gpa, "    \"stories\": {d},\n", .{report.summary_stories});
    try buf.print(gpa, "    \"other\": {d},\n", .{report.summary_other});
    try buf.print(gpa, "    \"media_manifest\": {d},\n", .{report.media_manifest.len});
    try buf.print(gpa, "    \"missing_media\": {d},\n", .{report.missing_media.len});
    try buf.print(gpa, "    \"human_review\": {d},\n", .{report.human_review.len});
    try buf.print(gpa, "    \"unsupported\": {d}\n", .{report.unsupported.len});
    try buf.appendSlice(gpa, "  },\n  \"pages\": [\n");
    for (report.pages, 0..) |p, idx| {
        try buf.appendSlice(gpa, "    {\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.output_path);
        try buf.appendSlice(gpa, ",\n      \"entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.entity_id);
        try buf.appendSlice(gpa, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, p.kind);
        try buf.appendSlice(gpa, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n      \"timestamp\": ");
        if (p.timestamp) |t| try buf.print(gpa, "{d}", .{t}) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ",\n      \"conversion\": ");
        try jsonEscapeAppend(&buf, gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, ",\n      \"source_json_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.source_json_path);
        try buf.print(gpa, ",\n      \"media_count\": {d},\n      \"id_strategy\": ", .{p.media_count});
        try jsonEscapeAppend(&buf, gpa, p.id_strategy);
        try buf.appendSlice(gpa, ",\n      \"notes\": [");
        for (p.notes, 0..) |n, ni| {
            if (ni > 0) try buf.appendSlice(gpa, ", ");
            try jsonEscapeAppend(&buf, gpa, n);
        }
        try buf.appendSlice(gpa, "]\n    }");
        if (idx + 1 < report.pages.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n  \"media_manifest\": [\n");
    for (report.media_manifest, 0..) |m, idx| {
        try buf.appendSlice(gpa, "    {\"entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, m.entity_id);
        try buf.appendSlice(gpa, ", \"source_uri\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_uri);
        try buf.appendSlice(gpa, ", \"theme_asset\": ");
        try jsonEscapeAppend(&buf, gpa, m.theme_asset);
        try buf.appendSlice(gpa, ", \"status\": ");
        try jsonEscapeAppend(&buf, gpa, m.status);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, m.kind);
        try buf.appendSlice(gpa, ", \"creation_timestamp\": ");
        if (m.creation_timestamp) |t| try buf.print(gpa, "{d}", .{t}) else try buf.appendSlice(gpa, "null");
        try buf.append(gpa, '}');
        if (idx + 1 < report.media_manifest.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n  \"missing_media\": [\n");
    for (report.missing_media, 0..) |m, idx| {
        try buf.appendSlice(gpa, "    {\"entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, m.entity_id);
        try buf.appendSlice(gpa, ", \"source_uri\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_uri);
        try buf.appendSlice(gpa, ", \"status\": ");
        try jsonEscapeAppend(&buf, gpa, m.status);
        try buf.append(gpa, '}');
        if (idx + 1 < report.missing_media.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn emitReportMd(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "# Instagram Takeout → Boris migration report\n\n");
    try buf.print(gpa, "- **format:** `{s}`\n", .{format_id});
    try buf.print(gpa, "- **schema_version:** {d}\n", .{schema_version});
    try buf.print(gpa, "- **source_dump:** `{s}`\n\n", .{report.source_dump});
    try buf.appendSlice(gpa, "## Summary\n\n");
    try buf.print(gpa, "| metric | count |\n|---|---:|\n| pages | {d} |\n| posts | {d} |\n| reels | {d} |\n| stories | {d} |\n| other | {d} |\n| media_manifest | {d} |\n| missing_media | {d} |\n| human_review | {d} |\n| unsupported | {d} |\n\n", .{
        report.pages.len,
        report.summary_posts,
        report.summary_reels,
        report.summary_stories,
        report.summary_other,
        report.media_manifest.len,
        report.missing_media.len,
        report.human_review.len,
        report.unsupported.len,
    });
    try buf.appendSlice(gpa, "## Pages\n\n");
    for (report.pages) |p| {
        try buf.print(gpa, "### `{s}`\n\n", .{p.entity_id});
        try buf.print(gpa, "- output: `{s}`\n- kind: `{s}`\n- conversion: `{s}`\n- source: `{s}`\n- id_strategy: `{s}`\n- media_count: {d}\n", .{
            p.output_path,
            p.kind,
            p.conversion.jsonName(),
            p.source_json_path,
            p.id_strategy,
            p.media_count,
        });
        if (p.notes.len > 0) {
            try buf.appendSlice(gpa, "- notes:\n");
            for (p.notes) |n| try buf.print(gpa, "  - {s}\n", .{n});
        }
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "## Missing media\n\n");
    if (report.missing_media.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.missing_media) |m| {
            try buf.print(gpa, "- `{s}` ← `{s}`\n", .{ m.entity_id, m.source_uri });
        }
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "---\n\nMachine-readable twin: `report.json`.\nMedia enrichment manifest: `media_manifest.json`.\nGenerated Markdown under `content/`; assets under `theme/assets/`.\n");
    return try buf.toOwnedSlice(gpa);
}

fn emitMediaManifestJson(gpa: std.mem.Allocator, entries: []const MediaManifestEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"format\": \"boris-instagram-media-manifest\",\n  \"schema_version\": 1,\n  \"note\": \"Clean provenance for a later enrichment pass (OCR/image analysis not performed).\",\n  \"entries\": [\n");
    for (entries, 0..) |m, idx| {
        try buf.appendSlice(gpa, "    {\"entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, m.entity_id);
        try buf.appendSlice(gpa, ", \"source_uri\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_uri);
        try buf.appendSlice(gpa, ", \"theme_asset\": ");
        try jsonEscapeAppend(&buf, gpa, m.theme_asset);
        try buf.appendSlice(gpa, ", \"status\": ");
        try jsonEscapeAppend(&buf, gpa, m.status);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, m.kind);
        try buf.append(gpa, '}');
        if (idx + 1 < entries.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Public run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const retain = arena_state.allocator();

    if (std.mem.eql(u8, opts.dump_dir, opts.out_dir)) return error.OutEqualsDump;

    var dump = try Io.Dir.cwd().openDir(io, opts.dump_dir, .{ .iterate = true });
    defer dump.close(io);

    const has_activity = pathExists(io, dump, "your_instagram_activity");
    const content_prefix = contentDirRel(has_activity);
    if (!pathExists(io, dump, content_prefix)) return error.MissingContentDir;

    var content = try dump.openDir(io, content_prefix, .{ .iterate = true });
    defer content.close(io);

    var source_files: std.ArrayList([]const u8) = .empty;
    defer source_files.deinit(gpa);
    try listJsonAndHtml(io, gpa, retain, content, content_prefix, &source_files);

    if (source_files.items.len == 0) return error.NoContentFiles;

    var records: std.ArrayList(IgRecord) = .empty;
    // retained in arena

    for (source_files.items) |spath| {
        const kind = kindFromSourcePath(spath);
        const bytes = try readFileAlloc(io, dump, spath, gpa);
        defer gpa.free(bytes);

        if (std.mem.endsWith(u8, spath, ".json")) {
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch {
                // malformed JSON: preserve as unsupported synthetic record
                try records.append(retain, .{
                    .kind = .unknown,
                    .source_json_path = try retain.dupe(u8, spath),
                    .source_index = 0,
                    .title = try retain.dupe(u8, "MALFORMED_JSON"),
                    .creation_timestamp = null,
                    .media = &.{},
                    .entity_id = "",
                    .id_strategy = "",
                    .conversion = .unsupported,
                    .notes = &.{try retain.dupe(u8, "malformed JSON; record placeholder emitted")},
                    .output_path = "",
                });
                continue;
            };
            defer parsed.deinit();
            try parseJsonArrayRecords(retain, parsed.value, kind, spath, &records);
        } else if (std.mem.endsWith(u8, spath, ".html")) {
            try parseHtmlPostsFile(retain, gpa, bytes, spath, kind, &records);
        }
    }

    try assignEntityIds(retain, records.items);
    for (records.items) |*rec| {
        try classifyMediaPresence(io, dump, rec, retain);
    }

    // Sort records for deterministic output: timestamp asc, entity_id
    std.mem.sort(IgRecord, records.items, {}, struct {
        fn less(_: void, a: IgRecord, b: IgRecord) bool {
            if (a.creation_timestamp == null and b.creation_timestamp == null)
                return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
            if (a.creation_timestamp == null) return false;
            if (b.creation_timestamp == null) return true;
            if (a.creation_timestamp.? != b.creation_timestamp.?)
                return a.creation_timestamp.? < b.creation_timestamp.?;
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);

    // Prepare out
    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out_root = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out_root.close(io);

    try writeThemeShell(io, out_root);

    // Copy media into theme (only referenced files that exist)
    var media_manifest: std.ArrayList(MediaManifestEntry) = .empty;
    defer media_manifest.deinit(gpa);
    var missing_media: std.ArrayList(MediaManifestEntry) = .empty;
    defer missing_media.deinit(gpa);

    for (records.items) |rec| {
        for (rec.media) |m| {
            var status: []const u8 = if (m.present) "present" else "missing";
            if (m.present and (std.mem.endsWith(u8, m.uri, ".mp4") or std.mem.endsWith(u8, m.uri, ".mov"))) {
                status = "video";
            }
            if (m.present) {
                // theme path is assets/media/... — strip "assets/" for write under theme/
                const under_theme = m.theme_rel; // assets/...
                copyFileRel(io, dump, m.uri, out_root, try std.fmt.allocPrint(retain, "theme/{s}", .{under_theme})) catch {
                    status = "missing";
                };
            }
            const entry: MediaManifestEntry = .{
                .entity_id = rec.entity_id,
                .source_uri = m.uri,
                .theme_asset = m.theme_rel,
                .status = try retain.dupe(u8, status),
                .kind = rec.kind.name(),
                .creation_timestamp = m.creation_timestamp orelse rec.creation_timestamp,
            };
            try media_manifest.append(gpa, entry);
            if (std.mem.eql(u8, status, "missing")) try missing_media.append(gpa, entry);
        }
    }

    // Write trunk + pages
    const trunk = try writeTrunkMarkdown(gpa, records.items);
    defer gpa.free(trunk);
    try writeBytes(io, out_root, "content/instagram.md", trunk);

    var pages: std.ArrayList(PageRecord) = .empty;
    defer pages.deinit(gpa);
    var human: std.ArrayList(PageRecord) = .empty;
    defer human.deinit(gpa);
    var unsupported: std.ArrayList(PageRecord) = .empty;
    defer unsupported.deinit(gpa);

    var n_posts: usize = 0;
    var n_reels: usize = 0;
    var n_stories: usize = 0;
    var n_other: usize = 0;

    for (records.items) |rec| {
        const md = try writeRecordMarkdown(gpa, rec);
        defer gpa.free(md);
        try writeBytes(io, out_root, rec.output_path, md);

        const pr: PageRecord = .{
            .output_path = rec.output_path,
            .entity_id = rec.entity_id,
            .kind = rec.kind.name(),
            .title = firstLineTitle(rec.title, 120),
            .timestamp = rec.creation_timestamp,
            .conversion = rec.conversion,
            .source_json_path = rec.source_json_path,
            .media_count = rec.media.len,
            .id_strategy = rec.id_strategy,
            .notes = rec.notes,
        };
        try pages.append(gpa, pr);
        if (rec.conversion == .human_review) try human.append(gpa, pr);
        if (rec.conversion == .unsupported) try unsupported.append(gpa, pr);
        switch (rec.kind) {
            .post => n_posts += 1,
            .reel => n_reels += 1,
            .story => n_stories += 1,
            .other, .unknown => n_other += 1,
        }
    }

    // Sort pages by output_path for report determinism
    std.mem.sort(PageRecord, pages.items, {}, struct {
        fn less(_: void, a: PageRecord, b: PageRecord) bool {
            return std.mem.order(u8, a.output_path, b.output_path) == .lt;
        }
    }.less);
    std.mem.sort(MediaManifestEntry, media_manifest.items, {}, struct {
        fn less(_: void, a: MediaManifestEntry, b: MediaManifestEntry) bool {
            const o = std.mem.order(u8, a.entity_id, b.entity_id);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.source_uri, b.source_uri) == .lt;
        }
    }.less);

    const report: Report = .{
        .source_dump = opts.dump_dir,
        .pages = pages.items,
        .media_manifest = media_manifest.items,
        .missing_media = missing_media.items,
        .human_review = human.items,
        .unsupported = unsupported.items,
        .summary_posts = n_posts,
        .summary_reels = n_reels,
        .summary_stories = n_stories,
        .summary_other = n_other,
    };

    const json = try emitReportJson(gpa, report);
    defer gpa.free(json);
    try writeBytes(io, out_root, "report.json", json);

    const mdrep = try emitReportMd(gpa, report);
    defer gpa.free(mdrep);
    try writeBytes(io, out_root, "REPORT.md", mdrep);

    const man = try emitMediaManifestJson(gpa, media_manifest.items);
    defer gpa.free(man);
    try writeBytes(io, out_root, "media_manifest.json", man);

    if (!opts.quiet) {
        std.debug.print("instagram-migration-lab: wrote {s}/content/, {s}/theme/, {s}/report.json, {s}/REPORT.md, {s}/media_manifest.json\n", .{
            opts.out_dir,
            opts.out_dir,
            opts.out_dir,
            opts.out_dir,
            opts.out_dir,
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractDurableId from IG media uri" {
    const id = extractDurableId("media/posts/202401/photo_1111111111111111111.jpg");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("1111111111111111111", id.?);
}

test "fallbackHashId deterministic" {
    const a = try fallbackHashId(std.testing.allocator, &.{"x"});
    defer std.testing.allocator.free(a);
    const b = try fallbackHashId(std.testing.allocator, &.{"x"});
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "firstLineTitle truncates" {
    const t = firstLineTitle("hello world\nmore", 5);
    try std.testing.expectEqualStrings("hello", t);
}

test "escapeFmValue quotes specials" {
    const e = try escapeFmValue(std.testing.allocator, "a: b");
    defer std.testing.allocator.free(e);
    try std.testing.expect(e[0] == '"');
}

test "parseIgDateString basic" {
    const ts = parseIgDateString("Jan 01, 2024 12:00 am");
    try std.testing.expect(ts != null);
}

test "fixture: instagram mode end-to-end + determinism + source immutability" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Snapshot a source file hash before
    const dump = "fixtures/mini-instagram";
    const src_rel = "your_instagram_activity/content/posts_1.json";
    var dump_dir = try Io.Dir.cwd().openDir(io, dump, .{});
    defer dump_dir.close(io);
    const before = try readFileAlloc(io, dump_dir, src_rel, gpa);
    defer gpa.free(before);

    const out_a = "fixtures/.ig-test-out-a";
    const out_b = "fixtures/.ig-test-out-b";
    // clean
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_a) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_b) catch {};

    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out_b, .quiet = true });

    // source unchanged
    const after = try readFileAlloc(io, dump_dir, src_rel, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    // reports exist and match across runs
    var a_root = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a_root.close(io);
    var b_root = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b_root.close(io);

    const ja = try readFileAlloc(io, a_root, "report.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, b_root, "report.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try readFileAlloc(io, a_root, "media_manifest.json", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, b_root, "media_manifest.json", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    // trunk + sample page
    const trunk = try readFileAlloc(io, a_root, "content/instagram.md", gpa);
    defer gpa.free(trunk);
    try std.testing.expect(std.mem.indexOf(u8, trunk, "parent:") == null); // trunk has no parent
    try std.testing.expect(std.mem.indexOf(u8, trunk, "id: instagram") != null);

    // report mentions missing media
    try std.testing.expect(std.mem.indexOf(u8, ja, "missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "boris-instagram-migration-lab") != null);

    // theme css + at least one copied media
    _ = try readFileAlloc(io, a_root, "theme/assets/css/site.css", gpa);
    // photo should be copied
    const photo_path = "theme/assets/media/posts/202401/photo_1111111111111111111.jpg";
    const photo = try readFileAlloc(io, a_root, photo_path, gpa);
    defer gpa.free(photo);
    try std.testing.expect(photo.len > 0);
}
