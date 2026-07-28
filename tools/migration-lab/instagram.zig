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
pub const schema_version: u32 = 2;
pub const tool_version = "0.2.0";

/// Enough for `{entity_id}.html` (product entity ids max 255 bytes + suffix).
const maxEntityIdHrefBytes: usize = 255 + ".html".len;

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
    encoding_repaired: bool = false,
    encoding_suspect: bool = false,
    present: bool = false,
    destination_rejected: bool = false,
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
    title: []const u8, // caption (UTF-8, with auditable Meta repair when needed)
    creation_timestamp: ?i64,
    encoding_repaired: bool,
    encoding_suspect: bool,
    media: []MediaItem,
    /// Durable external identity remains audit evidence; it is never used as
    /// the public route unless a collision counter is insufficient.
    durable_id: []const u8 = "",
    slug: []const u8 = "",
    hashtags: []const []const u8 = &.{},
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
    human_slug: []const u8,
    iso_timestamp: []const u8,
    hashtags: []const []const u8,
    cover_asset: []const u8,
    notes: []const []const u8,
};

const HashtagPage = struct {
    display: []const u8,
    slug: []const u8,
    record_indexes: std.ArrayList(usize) = .empty,
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

const output_owner_marker = ".boris-instagram-migration-owned";

fn dirIsEmpty(io: Io, dir: Io.Dir) bool {
    var it = dir.iterate();
    return (it.next(io) catch return false) == null;
}

fn prepareOwnedStage(io: Io, final_path: []const u8, stage_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.openDir(io, final_path, .{})) |final_dir| {
        defer final_dir.close(io);
        if (!dirIsEmpty(io, final_dir) and !pathExists(io, final_dir, output_owner_marker)) return error.RefuseUnownedOutput;
    } else |_| {}
    if (cwd.openDir(io, stage_path, .{})) |stage_dir| {
        defer stage_dir.close(io);
        if (!dirIsEmpty(io, stage_dir) and !pathExists(io, stage_dir, output_owner_marker)) return error.RefuseUnownedStage;
        cwd.deleteTree(io, stage_path) catch return error.StageCleanupFailed;
    } else |_| {}
    try cwd.createDirPath(io, stage_path);
}

fn publishOwnedStage(io: Io, final_path: []const u8, stage_path: []const u8, backup_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, backup_path) catch {};
    var moved_previous = false;
    if (cwd.openDir(io, final_path, .{})) |final_dir| {
        final_dir.close(io);
        try cwd.rename(final_path, cwd, backup_path, io);
        moved_previous = true;
    } else |_| {}
    cwd.rename(stage_path, cwd, final_path, io) catch |err| {
        if (moved_previous) cwd.rename(backup_path, cwd, final_path, io) catch {};
        return err;
    };
    if (moved_previous) cwd.deleteTree(io, backup_path) catch {};
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

fn hasSymlinkComponent(io: Io, root: Io.Dir, rel: []const u8) bool {
    var checked: std.ArrayList(u8) = .empty;
    defer checked.deinit(std.heap.page_allocator);
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (checked.items.len > 0) checked.append(std.heap.page_allocator, '/') catch return true;
        checked.appendSlice(std.heap.page_allocator, part) catch return true;
        var target: [std.fs.max_path_bytes]u8 = undefined;
        _ = root.readLink(io, checked.items, &target) catch continue;
        return true;
    }
    return false;
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
    // Truncate on a UTF-8 codepoint boundary (byte slice only; no alloc).
    var end = max_len;
    while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
    if (end == 0) end = max_len; // pathological; avoid empty
    return line[0..end];
}

fn firstNonEmptyCaptionLine(caption: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, caption, '\n');
    while (lines.next()) |line| {
        const trimmed = trimSpace(line);
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn kindDirectory(kind: RecordKind) []const u8 {
    return switch (kind) {
        .post => "posts",
        .reel => "reels",
        .story => "stories",
        .other, .unknown => "other",
    };
}

fn kindFallbackSlug(kind: RecordKind) []const u8 {
    return switch (kind) {
        .post => "photo-post",
        .reel => "reel",
        .story => "story",
        .other, .unknown => "archive-record",
    };
}

/// A deliberately boring, ASCII-only route slug. The product permits UTF-8
/// ids, but ASCII routes remain portable between filesystems and static hosts.
pub fn humanSlug(allocator: std.mem.Allocator, text: []const u8, fallback: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var dashed = true;
    for (text) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            try out.append(allocator, c);
            dashed = false;
        } else if (c >= 'A' and c <= 'Z') {
            try out.append(allocator, c + ('a' - 'A'));
            dashed = false;
        } else if (!dashed) {
            try out.append(allocator, '-');
            dashed = true;
        }
        if (out.items.len >= 72) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) {
        try out.appendSlice(allocator, fallback);
    }
    return try out.toOwnedSlice(allocator);
}

fn civilFromDays(days_since_epoch: i64) struct { year: i32, month: u32, day: u32 } {
    // Howard Hinnant's civil_from_days, UTC days since 1970-01-01.
    const z = days_since_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u32 = @intCast(mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9)));
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn timestampParts(ts: i64) struct { civil: @TypeOf(civilFromDays(0)), hour: u32, minute: u32, second: u32 } {
    const days = @divFloor(ts, 86400);
    const seconds: u32 = @intCast(ts - days * 86400);
    return .{ .civil = civilFromDays(days), .hour = seconds / 3600, .minute = (seconds % 3600) / 60, .second = seconds % 60 };
}

pub fn formatIsoTimestamp(allocator: std.mem.Allocator, ts: ?i64) ![]u8 {
    if (ts == null) return try allocator.dupe(u8, "");
    const p = timestampParts(ts.?);
    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(p.civil.year)), p.civil.month, p.civil.day, p.hour, p.minute, p.second });
}

pub fn formatHumanUtc(allocator: std.mem.Allocator, ts: ?i64) ![]u8 {
    if (ts == null) return try allocator.dupe(u8, "Undated");
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const p = timestampParts(ts.?);
    const ampm = if (p.hour < 12) "AM" else "PM";
    const hour12: u32 = if (p.hour % 12 == 0) 12 else p.hour % 12;
    return try std.fmt.allocPrint(allocator, "{s} {d}, {d} · {d}:{d:0>2} {s} UTC", .{ months[p.civil.month - 1], p.civil.day, p.civil.year, hour12, p.minute, ampm });
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

pub const TextRepair = struct {
    text: []const u8,
    repaired: bool,
    /// A mojibake signature survives in `text`. Either the caption mixed escaped
    /// and genuine Unicode (so the repair declined), or it was encoded more than
    /// once (so a single pass was not enough). Provenance must not claim clean
    /// `utf-8` for these — they need a human.
    residue: bool,
};

/// Detect the byte signature of Latin-1 mis-decoded UTF-8: a codepoint in the
/// UTF-8 *lead* range (U+00C2–U+00F4) immediately followed by one in the
/// *continuation* range (U+0080–U+00BF). Genuine prose does not produce this
/// pairing; `Ã©`, `Â£`, and `â€™` all do.
fn hasMojibakeResidue(s: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    var i: usize = 0;
    var prev_lead = false;
    while (i < s.len) {
        const width = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
        const codepoint = std.unicode.utf8Decode(s[i .. i + width]) catch return false;
        if (prev_lead and codepoint >= 0x80 and codepoint <= 0xbf) return true;
        prev_lead = codepoint >= 0xc2 and codepoint <= 0xf4;
        i += width;
    }
    return false;
}

/// Repair Meta's JSON export form where UTF-8 bytes were escaped as individual
/// Latin-1 code points (for example `\\u00c3\\u00a9` for `é`). Only accept the
/// conversion when the resulting bytes are valid UTF-8; ordinary Unicode text
/// therefore remains byte-for-byte unchanged.
pub fn repairMetaEscapedUtf8(allocator: std.mem.Allocator, input: []const u8) !TextRepair {
    if (!std.unicode.utf8ValidateSlice(input)) return .{ .text = input, .repaired = false, .residue = false };

    var candidate: std.ArrayList(u8) = .empty;
    errdefer candidate.deinit(allocator);
    var changed = false;
    var i: usize = 0;
    while (i < input.len) {
        const width = try std.unicode.utf8ByteSequenceLength(input[i]);
        const codepoint = try std.unicode.utf8Decode(input[i .. i + width]);
        if (codepoint > 0xff) {
            // Mixed escaped and genuine Unicode: converting would corrupt the
            // genuine half, so decline — but say so, rather than reporting clean.
            candidate.deinit(allocator);
            return .{ .text = input, .repaired = false, .residue = hasMojibakeResidue(input) };
        }
        const byte: u8 = @intCast(codepoint);
        try candidate.append(allocator, byte);
        if (width != 1 or input[i] != byte) changed = true;
        i += width;
    }

    if (!changed or !std.unicode.utf8ValidateSlice(candidate.items)) {
        candidate.deinit(allocator);
        return .{ .text = input, .repaired = false, .residue = hasMojibakeResidue(input) };
    }
    const repaired = try candidate.toOwnedSlice(allocator);
    // A multiply-encoded caption still looks like mojibake after one pass. Flag
    // it instead of stamping `meta-latin1-repaired` on a half-finished repair.
    return .{ .text = repaired, .repaired = true, .residue = hasMojibakeResidue(repaired) };
}

/// Reject media URIs that would escape the dump on read or the output root on
/// write. Meta exports only ever reference dump-relative media paths, so an
/// absolute path, a `..` component, a Windows separator, or a drive prefix is
/// corruption or a hostile archive — never a convertible record. Mirrors the
/// theme-adversarial trio (escape-dotdot / absolute / backslash).
pub fn isSafeMediaUri(uri: []const u8) bool {
    if (uri.len == 0) return false;
    if (uri[0] == '/') return false; // absolute: openat ignores the dir fd
    if (std.mem.indexOfScalar(u8, uri, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, uri, 0) != null) return false;
    if (uri.len >= 2 and uri[1] == ':') return false; // C:\… / C:foo
    var it = std.mem.splitScalar(u8, uri, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn isTagByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c >= 0x80;
}

fn asciiCaseEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + ('a' - 'A') else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + ('a' - 'A') else bc;
        if (al != bl) return false;
    }
    return true;
}

pub fn extractHashtags(allocator: std.mem.Allocator, caption: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tags.items) |tag| allocator.free(tag);
        tags.deinit(allocator);
    }
    var i: usize = 0;
    while (i < caption.len) : (i += 1) {
        if (caption[i] != '#') continue;
        const start = i + 1;
        var end = start;
        while (end < caption.len and isTagByte(caption[end])) : (end += 1) {}
        if (end == start) continue;
        const tag = caption[start..end];
        var duplicate = false;
        for (tags.items) |old| if (asciiCaseEqual(old, tag)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try tags.append(allocator, try allocator.dupe(u8, tag));
        i = end - 1;
    }
    return try tags.toOwnedSlice(allocator);
}

fn isMentionByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.';
}

fn isMentionBoundary(c: u8) bool {
    return !((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '@');
}

fn mentionEnd(caption: []const u8, at: usize) ?usize {
    if (at > 0 and !isMentionBoundary(caption[at - 1])) return null;
    var end = at + 1;
    while (end < caption.len and isMentionByte(caption[end])) : (end += 1) {}
    // A sentence-ending period is punctuation, not part of the username.
    while (end > at + 1 and caption[end - 1] == '.') end -= 1;
    const user = caption[at + 1 .. end];
    if (user.len == 0 or user.len > 30 or user[0] == '.' or user[user.len - 1] == '.') return null;
    // An email's @ starts after an identifier, rejected above, and a following
    // dot-domain must never be linked as a username.
    return end;
}

fn escapeHtmlAttr(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&#39;"),
        else => try out.append(allocator, c),
    };
    return try out.toOwnedSlice(allocator);
}

fn appendEscapedCaptionByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, c: u8) !void {
    switch (c) {
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '&' => try out.appendSlice(allocator, "&amp;"),
        '\\', '`', '*', '_', '[', ']', '(', ')', '#', '!', '+', '-' => {
            try out.append(allocator, '\\');
            try out.append(allocator, c);
        },
        else => try out.append(allocator, c),
    }
}

fn relativePublishedHref(allocator: std.mem.Allocator, from_entity: []const u8, target: []const u8) ![]u8 {
    const from_dir = std.fs.path.dirname(from_entity) orelse "";
    var from_it = std.mem.splitScalar(u8, from_dir, '/');
    var target_it = std.mem.splitScalar(u8, target, '/');
    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(allocator);
    var target_parts: std.ArrayList([]const u8) = .empty;
    defer target_parts.deinit(allocator);
    while (from_it.next()) |part| if (part.len > 0) try from_parts.append(allocator, part);
    while (target_it.next()) |part| if (part.len > 0) try target_parts.append(allocator, part);
    var common: usize = 0;
    while (common < from_parts.items.len and common < target_parts.items.len and std.mem.eql(u8, from_parts.items[common], target_parts.items[common])) : (common += 1) {}
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (from_parts.items[common..]) |_| try out.appendSlice(allocator, "../");
    for (target_parts.items[common..], 0..) |part, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "./");
    return try out.toOwnedSlice(allocator);
}

fn tagEntity(slug: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "instagram/tags/{s}", .{slug});
}

fn findTagPage(tags: []const HashtagPage, tag: []const u8) ?usize {
    for (tags, 0..) |page, i| if (asciiCaseEqual(page.display, tag)) return i;
    return null;
}

/// Render untrusted text as paragraphs. Markdown punctuation and raw HTML are
/// escaped first; the only Markdown links emitted here are validated mentions
/// and generated local hashtag pages.
fn renderCaption(allocator: std.mem.Allocator, rec: IgRecord, tags: []const HashtagPage) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var i: usize = 0;
    while (i < rec.title.len) : (i += 1) {
        if (rec.title[i] == '\r') {
            if (i + 1 < rec.title.len and rec.title[i + 1] == '\n') i += 1;
            try normalized.append(allocator, '\n');
        } else try normalized.append(allocator, rec.title[i]);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var line_it = std.mem.splitScalar(u8, normalized.items, '\n');
    var first_line = true;
    while (line_it.next()) |raw_line| {
        var line = raw_line;
        while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
        if (!first_line) try out.append(allocator, '\n');
        first_line = false;
        var j: usize = 0;
        while (j < line.len) {
            if (line[j] == '@') if (mentionEnd(line, j)) |end| {
                const username = line[j + 1 .. end];
                try out.print(allocator, "[@{s}](https://www.instagram.com/{s}/)", .{ username, username });
                j = end;
                continue;
            };
            if (line[j] == '#') {
                var end = j + 1;
                while (end < line.len and isTagByte(line[end])) : (end += 1) {}
                if (end > j + 1) {
                    const raw_tag = line[j + 1 .. end];
                    if (findTagPage(tags, raw_tag)) |tag_index| {
                        const entity = try tagEntity(tags[tag_index].slug, allocator);
                        defer allocator.free(entity);
                        const target = try std.fmt.allocPrint(allocator, "{s}.html", .{entity});
                        defer allocator.free(target);
                        const href = try relativePublishedHref(allocator, rec.entity_id, target);
                        defer allocator.free(href);
                        try out.print(allocator, "[#{s}]({s})", .{ raw_tag, href });
                        j = end;
                        continue;
                    }
                }
            }
            try appendEscapedCaptionByte(&out, allocator, line[j]);
            j += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parseMediaObject(retain: std.mem.Allocator, v: std.json.Value) !MediaItem {
    const uri = try retain.dupe(u8, jsonGetString(v, "uri"));
    const title_repair = try repairMetaEscapedUtf8(retain, jsonGetString(v, "title"));
    const title = if (title_repair.repaired) title_repair.text else try retain.dupe(u8, title_repair.text);
    const ts = jsonGetI64(v, "creation_timestamp");
    return .{
        .uri = uri,
        .creation_timestamp = ts,
        .title = title,
        .encoding_repaired = title_repair.repaired,
        .encoding_suspect = title_repair.residue,
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
    const title_repair = try repairMetaEscapedUtf8(retain, jsonGetString(v, "title"));
    var title = title_repair.text;
    var encoding_repaired = title_repair.repaired;
    var encoding_suspect = title_repair.residue;
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
    for (media_list.items) |media| {
        encoding_repaired = encoding_repaired or media.encoding_repaired;
        encoding_suspect = encoding_suspect or media.encoding_suspect;
    }
    const title_owned = try retain.dupe(u8, title);
    const source_owned = try retain.dupe(u8, source_path);

    return .{
        .kind = kind,
        .source_json_path = source_owned,
        .source_index = index,
        .title = title_owned,
        .creation_timestamp = ts,
        .encoding_repaired = encoding_repaired,
        .encoding_suspect = encoding_suspect,
        .media = try media_list.toOwnedSlice(retain),
        .entity_id = "",
        .id_strategy = "",
        .conversion = if (encoding_suspect)
            .human_review
        else if (encoding_repaired)
            .transformed
        else
            .exact,
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
        var encoding_repaired = false;
        var encoding_suspect = false;
        if (std.mem.indexOf(u8, block, "_a6-h _a6-i\">")) |c0| {
            const cs = c0 + "_a6-h _a6-i\">".len;
            if (std.mem.indexOfPos(u8, block, cs, "</div>")) |ce| {
                const raw = block[cs..ce];
                const stripped = try stripTags(gpa, raw);
                defer gpa.free(stripped);
                const unesc = try htmlUnescapeBasic(retain, stripped);
                const repair = try repairMetaEscapedUtf8(retain, unesc);
                caption = repair.text;
                encoding_repaired = repair.repaired;
                encoding_suspect = repair.residue;
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
                .encoding_repaired = encoding_repaired,
                .encoding_suspect = encoding_suspect,
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
            .encoding_repaired = encoding_repaired,
            .encoding_suspect = encoding_suspect,
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
        var durable_id: []const u8 = "";

        // Prefer durable id from first media uri
        if (rec.media.len > 0) {
            if (extractDurableId(rec.media[0].uri)) |did| {
                durable_id = try retain.dupe(u8, did);
                strategy = "durable_export_id";
            } else {
                durable_id = try fallbackHashId(retain, &.{ rec.source_json_path, rec.media[0].uri, rec.title });
                try notes.append(retain, try retain.dupe(u8, "no durable media id; used fallback_hash"));
            }
        } else {
            const ts_s = if (rec.creation_timestamp) |t|
                try std.fmt.allocPrint(retain, "{d}", .{t})
            else
                try retain.dupe(u8, "nots");
            durable_id = try fallbackHashId(retain, &.{ rec.source_json_path, ts_s, rec.title, rec.kind.name() });
            try notes.append(retain, try retain.dupe(u8, "empty media; used fallback_hash"));
        }

        const title_line = firstNonEmptyCaptionLine(rec.title);
        const slug = try humanSlug(retain, title_line, kindFallbackSlug(rec.kind));
        const date_prefix = if (rec.creation_timestamp) |ts| blk: {
            const p = timestampParts(ts).civil;
            break :blk try std.fmt.allocPrint(retain, "{d:0>4}/{d:0>2}", .{ @as(u32, @intCast(p.year)), p.month });
        } else try retain.dupe(u8, "undated");
        const public_stem = if (rec.creation_timestamp) |ts| blk: {
            const p = timestampParts(ts).civil;
            break :blk try std.fmt.allocPrint(retain, "{d:0>4}-{d:0>2}-{d:0>2}-{s}", .{ @as(u32, @intCast(p.year)), p.month, p.day, slug });
        } else slug;
        const base = try std.fmt.allocPrint(retain, "instagram/{s}/{s}/{s}", .{ kindDirectory(rec.kind), date_prefix, public_stem });
        // A readable numeric suffix is deterministic because records reach this
        // function in stable source path/index order.
        var entity = base;
        var n: usize = 2;
        while (used.contains(entity)) {
            const alt = try std.fmt.allocPrint(retain, "{s}-{d}", .{ base, n });
            entity = alt;
            n += 1;
            try notes.append(retain, try retain.dupe(u8, "entity id collision; appended counter"));
        }
        try used.put(retain, entity, {});

        // classifications
        if (rec.media.len > 1) {
            rec.conversion = ConversionClass.worse(rec.conversion, .transformed);
            try notes.append(retain, try retain.dupe(u8, "carousel: multiple media items"));
        }
        for (rec.media) |m| {
            if (isVideoThemeAsset(m.theme_rel) or std.mem.endsWith(u8, m.uri, ".mp4") or std.mem.endsWith(u8, m.uri, ".mov")) {
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
        if (rec.encoding_repaired) {
            try notes.append(retain, try retain.dupe(u8, "repaired Meta Latin-1 escaped UTF-8 text"));
        }
        if (rec.encoding_suspect) {
            try notes.append(retain, try retain.dupe(u8, "mojibake signature remains after repair attempt; caption needs manual review"));
        }

        rec.entity_id = entity;
        rec.durable_id = durable_id;
        rec.slug = slug;
        rec.hashtags = try extractHashtags(retain, rec.title);
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

        // A hostile or corrupt dump can name a path that escapes the dump on
        // read and the output root on write. Refuse before touching the
        // filesystem, and leave `theme_rel` empty so the copy pass skips it.
        if (!isSafeMediaUri(uri)) {
            m.present = false;
            m.theme_rel = "";
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
            var unsafe_notes: std.ArrayList([]const u8) = .empty;
            try unsafe_notes.appendSlice(retain, rec.notes);
            try unsafe_notes.append(retain, try std.fmt.allocPrint(
                retain,
                "unsafe media uri rejected (not read, not copied): {s}",
                .{m.uri},
            ));
            rec.notes = try unsafe_notes.toOwnedSlice(retain);
            continue;
        }

        if (hasSymlinkComponent(io, dump, uri)) {
            m.present = false;
            m.theme_rel = "";
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
            var symlink_notes: std.ArrayList([]const u8) = .empty;
            try symlink_notes.appendSlice(retain, rec.notes);
            try symlink_notes.append(retain, try std.fmt.allocPrint(retain, "symlink media path rejected (not read, not copied): {s}", .{m.uri}));
            rec.notes = try symlink_notes.toOwnedSlice(retain);
            continue;
        }

        m.present = pathExists(io, dump, uri);
        if (!m.present) {
            rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
            // append note
            var notes: std.ArrayList([]const u8) = .empty;
            try notes.appendSlice(retain, rec.notes);
            try notes.append(retain, try std.fmt.allocPrint(retain, "missing media: {s}", .{uri}));
            rec.notes = try notes.toOwnedSlice(retain);
        }
    }
}

/// Extract a public-media extension without trusting the rest of the archive
/// filename. Source URIs are retained as provenance, but never reused as
/// destination names. A query, fragment, control byte, or unsupported suffix
/// is not a media type assertion and therefore cannot become a theme asset.
fn validatedMediaExtension(allocator: std.mem.Allocator, source_uri: []const u8) !?[]u8 {
    if (source_uri.len == 0) return null;
    for (source_uri) |c| {
        if (c < 0x20 or c == 0x7f or c == '?' or c == '#' or c == '\\') return null;
    }
    const basename = if (std.mem.lastIndexOfScalar(u8, source_uri, '/')) |slash|
        source_uri[slash + 1 ..]
    else
        source_uri;
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return null;
    if (dot == 0 or dot + 1 == basename.len) return null;
    const raw = basename[dot + 1 ..];
    if (raw.len > 4) return null;
    const ext = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |c, i| ext[i] = if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
    if (std.mem.eql(u8, ext, "jpg") or
        std.mem.eql(u8, ext, "jpeg") or
        std.mem.eql(u8, ext, "png") or
        std.mem.eql(u8, ext, "gif") or
        std.mem.eql(u8, ext, "webp") or
        std.mem.eql(u8, ext, "mp4") or
        std.mem.eql(u8, ext, "mov")) return ext;
    allocator.free(ext);
    return null;
}

fn isVideoThemeAsset(theme_rel: []const u8) bool {
    return std.mem.endsWith(u8, theme_rel, ".mp4") or std.mem.endsWith(u8, theme_rel, ".mov");
}

/// A destination must never accidentally become a copied Meta basename. This
/// recognizes the long underscore-separated numeric groups common in exports;
/// source URIs may contain these names and remain provenance evidence.
fn hasOpaqueMetaBasename(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;
    var groups: usize = 0;
    var numeric_groups: usize = 0;
    var parts = std.mem.splitScalar(u8, stem, '_');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        groups += 1;
        var all_digits = part.len >= 6;
        for (part) |c| {
            if (c < '0' or c > '9') all_digits = false;
        }
        if (all_digits) numeric_groups += 1;
    }
    return groups >= 3 and numeric_groups >= 3;
}

fn appendMediaReviewNote(retain: std.mem.Allocator, rec: *IgRecord, note: []const u8) !void {
    var notes: std.ArrayList([]const u8) = .empty;
    try notes.appendSlice(retain, rec.notes);
    try notes.append(retain, try retain.dupe(u8, note));
    rec.notes = try notes.toOwnedSlice(retain);
}

/// Theme media paths are derived from the final public entity id, never the
/// source URI. Record order is stable before this function runs, and the media
/// loop intentionally keeps the provider's source-array order for carousels.
fn assignMediaDestinations(retain: std.mem.Allocator, records: []IgRecord) !void {
    var used: std.StringHashMapUnmanaged(void) = .{};
    defer used.deinit(retain);

    for (records) |*rec| {
        for (rec.media, 0..) |*m, media_index| {
            const ext = (try validatedMediaExtension(retain, m.uri)) orelse {
                m.present = false;
                m.destination_rejected = true;
                m.theme_rel = "";
                rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
                try appendMediaReviewNote(retain, rec, "unsupported or unsafe media extension; not copied");
                continue;
            };
            defer retain.free(ext);
            if (std.mem.eql(u8, ext, "mp4") or std.mem.eql(u8, ext, "mov")) {
                rec.conversion = ConversionClass.worse(rec.conversion, .transformed);
            }
            var destination = try std.fmt.allocPrint(
                retain,
                "assets/media/{s}-{d:0>2}.{s}",
                .{ rec.entity_id, media_index + 1, ext },
            );
            var collision: usize = 2;
            while (used.contains(destination)) {
                const previous = destination;
                destination = try std.fmt.allocPrint(
                    retain,
                    "assets/media/{s}-{d:0>2}-{d}.{s}",
                    .{ rec.entity_id, media_index + 1, collision, ext },
                );
                retain.free(previous);
                collision += 1;
            }
            if (hasOpaqueMetaBasename(destination)) {
                m.present = false;
                m.destination_rejected = true;
                m.theme_rel = "";
                rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
                try appendMediaReviewNote(retain, rec, "opaque Meta-style generated media basename rejected");
                continue;
            }
            try used.put(retain, destination, {});
            m.theme_rel = destination;
        }
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

fn writeRecordMarkdown(allocator: std.mem.Allocator, rec: IgRecord, tag_pages: []const HashtagPage) ![]u8 {
    var tags_buf: [64][]const u8 = undefined;
    var tag_n: usize = 0;
    tags_buf[tag_n] = "instagram";
    tag_n += 1;
    tags_buf[tag_n] = rec.kind.name();
    tag_n += 1;
    for (rec.hashtags) |tag| {
        if (tag_n < tags_buf.len) {
            tags_buf[tag_n] = tag;
            tag_n += 1;
        }
    }
    if (rec.conversion == .human_review) {
        tags_buf[tag_n] = "needs-review";
        tag_n += 1;
    }

    const title = firstNonEmptyCaptionLine(rec.title);
    const display_title = if (title.len > 0) title else kindFallbackSlug(rec.kind);
    const fm = try buildFrontmatter(allocator, rec.entity_id, display_title, "instagram", "published", tags_buf[0..tag_n]);
    defer allocator.free(fm);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, fm);
    try body.append(allocator, '\n');

    const safe_heading = try escapeMdLinkLabel(allocator, display_title);
    defer allocator.free(safe_heading);
    try body.print(allocator, "# {s}\n\n", .{safe_heading});
    const human_date = try formatHumanUtc(allocator, rec.creation_timestamp);
    defer allocator.free(human_date);
    try body.print(allocator, "{s}\n\n", .{human_date});

    if (rec.title.len > 0) {
        const caption = try renderCaption(allocator, rec, tag_pages);
        defer allocator.free(caption);
        try body.appendSlice(allocator, caption);
        try body.appendSlice(allocator, "\n\n");
    }

    if (rec.media.len == 0) {
        try body.appendSlice(allocator, "No media was included with this archive record.\n\n");
    } else {
        var present_images: usize = 0;
        for (rec.media) |m| {
            if (m.present and !isVideoThemeAsset(m.theme_rel)) present_images += 1;
        }
        if (present_images > 1) try body.appendSlice(allocator, "<div class=\"instagram-gallery\">\n");
        for (rec.media) |m| {
            if (!m.present) continue;
            const href = try relativePublishedHref(allocator, rec.entity_id, m.theme_rel);
            defer allocator.free(href);
            const alt_source = if (m.title.len > 0) m.title else if (display_title.len > 0) display_title else kindFallbackSlug(rec.kind);
            const alt = try escapeHtmlAttr(allocator, alt_source);
            defer allocator.free(alt);
            if (isVideoThemeAsset(m.theme_rel)) {
                const html_href = try escapeHtmlAttr(allocator, href);
                defer allocator.free(html_href);
                try body.print(allocator, "<video class=\"instagram-video\" controls preload=\"metadata\" src=\"{s}\">\n  <a href=\"{s}\">Download the video</a>\n</video>\n\n", .{ html_href, html_href });
            } else if (present_images > 1) {
                const html_href = try escapeHtmlAttr(allocator, href);
                defer allocator.free(html_href);
                try body.print(allocator, "  <figure class=\"instagram-gallery__item\"><img src=\"{s}\" alt=\"{s}\"></figure>\n", .{ html_href, alt });
            } else {
                // Markdown image destinations are intentionally restricted to
                // a page-local `.assets/` directory by product Boris. Theme
                // assets are public site paths, so use the same escaped raw
                // HTML shape as galleries and video to retain this link.
                const html_href = try escapeHtmlAttr(allocator, href);
                defer allocator.free(html_href);
                try body.print(allocator, "<img src=\"{s}\" alt=\"{s}\">\n\n", .{ html_href, alt });
            }
        }
        if (present_images > 1) try body.appendSlice(allocator, "</div>\n\n");
        for (rec.media) |m| if (!m.present) {
            try body.appendSlice(allocator, "Media asset missing from the Instagram archive export.\n\n");
            break;
        };
    }

    // provenance HTML comment
    try body.appendSlice(allocator,
        \\<!-- boris-migration-provenance
        \\source_format: instagram-takeout
        \\
    );
    try body.print(allocator, "source_json_path: {s}\n", .{rec.source_json_path});
    try body.print(allocator, "source_index: {d}\n", .{rec.source_index});
    try body.print(allocator, "durable_export_id: {s}\n", .{rec.durable_id});
    try body.print(allocator, "generated_slug: {s}\n", .{rec.slug});
    try body.print(allocator, "entity_id: {s}\n", .{rec.entity_id});
    try body.print(allocator, "id_strategy: {s}\n", .{rec.id_strategy});
    try body.print(allocator, "kind: {s}\n", .{rec.kind.name()});
    const iso = try formatIsoTimestamp(allocator, rec.creation_timestamp);
    defer allocator.free(iso);
    try body.print(allocator, "creation_timestamp: {d}\n", .{rec.creation_timestamp orelse -1});
    try body.print(allocator, "iso_timestamp: {s}\n", .{iso});
    try body.print(allocator, "conversion: {s}\n", .{rec.conversion.jsonName()});
    const encoding_label: []const u8 = if (rec.encoding_suspect)
        "suspected-mojibake-unrepaired"
    else if (rec.encoding_repaired)
        "meta-latin1-repaired"
    else
        "utf-8";
    try body.print(allocator, "encoding: {s}\n", .{encoding_label});
    try body.appendSlice(allocator, "media:\n");
    for (rec.media) |m| {
        try body.print(allocator, "  - uri: {s}\n", .{m.uri});
        try body.print(allocator, "    theme: {s}\n", .{m.theme_rel});
        try body.print(allocator, "    present: {s}\n", .{if (m.present) "true" else "false"});
    }
    if (rec.notes.len > 0) {
        try body.appendSlice(allocator, "notes:\n");
        for (rec.notes) |note| try body.print(allocator, "  - {s}\n", .{note});
    }
    try body.appendSlice(allocator,
        \\-->
        \\
    );

    return try body.toOwnedSlice(allocator);
}

/// Site-relative HTML path for a page entity — same mapping as product
/// `identity.htmlOutputPath` / wiki-link rewrite (`{entity_id}.html`).
/// Source stays `content/{entity_id}.md`; do not link the `.md` source path.
fn publishedHtmlHref(entity_id: []const u8, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}.html", .{entity_id});
}

/// Longest run of consecutive backticks in `s` — sizes a code fence that
/// untrusted caption text cannot close early.
fn longestBacktickRun(s: []const u8) usize {
    var best: usize = 0;
    var current: usize = 0;
    for (s) |c| {
        if (c == '`') {
            current += 1;
            if (current > best) best = current;
        } else {
            current = 0;
        }
    }
    return best;
}

/// Escape `]` and `\` so caption text cannot break `[label](href)` links.
fn escapeMdLinkLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, label.len);
    for (label) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '\\', '[', ']', '(', ')', '`' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn buildHashtagPages(allocator: std.mem.Allocator, records: []const IgRecord) ![]HashtagPage {
    var pages: std.ArrayList(HashtagPage) = .empty;
    errdefer {
        for (pages.items) |*page| page.record_indexes.deinit(allocator);
        pages.deinit(allocator);
    }
    for (records, 0..) |record, record_index| for (record.hashtags) |tag| {
        if (findTagPage(pages.items, tag)) |index| {
            try pages.items[index].record_indexes.append(allocator, record_index);
            continue;
        }
        const base_slug = try humanSlug(allocator, tag, "tag");
        var slug = base_slug;
        var n: usize = 2;
        while (true) {
            var occupied = false;
            for (pages.items) |page| if (std.mem.eql(u8, page.slug, slug)) {
                occupied = true;
                break;
            };
            if (!occupied) break;
            slug = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base_slug, n });
            n += 1;
        }
        var indexes: std.ArrayList(usize) = .empty;
        try indexes.append(allocator, record_index);
        try pages.append(allocator, .{ .display = try allocator.dupe(u8, tag), .slug = slug, .record_indexes = indexes });
    };
    std.mem.sort(HashtagPage, pages.items, {}, struct {
        fn less(_: void, a: HashtagPage, b: HashtagPage) bool {
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.less);
    return try pages.toOwnedSlice(allocator);
}

fn writeHashtagMarkdown(allocator: std.mem.Allocator, page: HashtagPage, records: []const IgRecord) ![]u8 {
    const entity = try tagEntity(page.slug, allocator);
    defer allocator.free(entity);
    const title = try std.fmt.allocPrint(allocator, "#{s}", .{page.display});
    defer allocator.free(title);
    const fm = try buildFrontmatter(allocator, entity, title, "instagram", "published", &.{ "instagram", "tag" });
    defer allocator.free(fm);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, fm);
    const safe_title = try escapeMdLinkLabel(allocator, title);
    defer allocator.free(safe_title);
    try out.print(allocator, "\n# {s}\n\n{d} archive record{s}.\n\n", .{ safe_title, page.record_indexes.items.len, if (page.record_indexes.items.len == 1) "" else "s" });
    const order = try allocator.dupe(usize, page.record_indexes.items);
    defer allocator.free(order);
    std.mem.sort(usize, order, records, struct {
        fn less(recs: []const IgRecord, a: usize, b: usize) bool {
            const ta = recs[a].creation_timestamp orelse std.math.minInt(i64);
            const tb = recs[b].creation_timestamp orelse std.math.minInt(i64);
            if (ta != tb) return ta > tb;
            return std.mem.order(u8, recs[a].entity_id, recs[b].entity_id) == .lt;
        }
    }.less);
    for (order) |index| {
        const record = records[index];
        const target = try std.fmt.allocPrint(allocator, "{s}.html", .{record.entity_id});
        defer allocator.free(target);
        const href = try relativePublishedHref(allocator, entity, target);
        defer allocator.free(href);
        const label = try escapeMdLinkLabel(allocator, if (firstNonEmptyCaptionLine(record.title).len > 0) firstNonEmptyCaptionLine(record.title) else kindFallbackSlug(record.kind));
        defer allocator.free(label);
        const date = try formatHumanUtc(allocator, record.creation_timestamp);
        defer allocator.free(date);
        try out.print(allocator, "- [{s}]({s}) — {s} · {s}\n", .{ label, href, date, record.kind.name() });
    }
    try out.appendSlice(allocator, "\n<!-- boris-migration-provenance\nsource_format: instagram-takeout\nrole: hashtag-index\ntag_slug: ");
    try out.appendSlice(allocator, page.slug);
    try out.appendSlice(allocator, "\n-->\n");
    return try out.toOwnedSlice(allocator);
}

fn writeTrunkMarkdown(allocator: std.mem.Allocator, records: []const IgRecord, tags: []const HashtagPage) ![]u8 {
    const fm = try buildFrontmatter(allocator, "instagram", "Instagram archive", null, "published", &.{ "instagram", "archive" });
    defer allocator.free(fm);
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, fm);
    try body.appendSlice(allocator,
        \\
        \\# Instagram archive
        \\
        \\A quiet, offline archive of posts, reels, stories, and other records.
        \\
        \\
    );
    var posts: usize = 0;
    var reels: usize = 0;
    var stories: usize = 0;
    var other: usize = 0;
    var earliest: ?i64 = null;
    var latest: ?i64 = null;
    for (records) |record| {
        switch (record.kind) {
            .post => posts += 1,
            .reel => reels += 1,
            .story => stories += 1,
            .other, .unknown => other += 1,
        }
        if (record.creation_timestamp) |ts| {
            if (earliest == null or ts < earliest.?) earliest = ts;
            if (latest == null or ts > latest.?) latest = ts;
        }
    }
    try body.print(allocator, "{d} records · {d} posts · {d} reels · {d} stories · {d} other\n\n", .{ records.len, posts, reels, stories, other });
    if (earliest) |first| {
        const first_date = try formatHumanUtc(allocator, first);
        defer allocator.free(first_date);
        const last_date = try formatHumanUtc(allocator, latest.?);
        defer allocator.free(last_date);
        try body.print(allocator, "From {s} to {s}.\n\n", .{ first_date, last_date });
    }
    if (tags.len > 0) {
        try body.appendSlice(allocator, "## Hashtags\n\n");
        for (tags) |tag| {
            const entity = try tagEntity(tag.slug, allocator);
            defer allocator.free(entity);
            const target = try std.fmt.allocPrint(allocator, "{s}.html", .{entity});
            defer allocator.free(target);
            const href = try relativePublishedHref(allocator, "instagram", target);
            defer allocator.free(href);
            const display = try escapeMdLinkLabel(allocator, tag.display);
            defer allocator.free(display);
            try body.print(allocator, "[#{s}]({s}) ({d})  ", .{ display, href, tag.record_indexes.items.len });
        }
        try body.appendSlice(allocator, "\n\n");
    }
    try body.appendSlice(allocator, "## Archive\n\n<div class=\"instagram-feed\">\n");
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
            if (ta.? != tb.?) return ta.? > tb.?;
            return std.mem.order(u8, recs[a].entity_id, recs[b].entity_id) == .lt;
        }
    }.less);
    var href_buf: [maxEntityIdHrefBytes]u8 = undefined;
    for (order.items) |i| {
        const r = records[i];
        const href = try publishedHtmlHref(r.entity_id, &href_buf);
        const label = try escapeHtmlAttr(allocator, if (firstNonEmptyCaptionLine(r.title).len > 0) firstNonEmptyCaptionLine(r.title) else kindFallbackSlug(r.kind));
        defer allocator.free(label);
        const date = try formatHumanUtc(allocator, r.creation_timestamp);
        defer allocator.free(date);
        try body.print(allocator, "<article class=\"instagram-feed__item\"><p class=\"instagram-feed__meta\">{s} · {s}</p><h2><a href=\"{s}\">{s}</a></h2>", .{ date, r.kind.name(), href, label });
        for (r.media) |media| if (media.present and !isVideoThemeAsset(media.theme_rel)) {
            const asset = try relativePublishedHref(allocator, "instagram", media.theme_rel);
            defer allocator.free(asset);
            const alt = try escapeHtmlAttr(allocator, if (media.title.len > 0) media.title else label);
            defer allocator.free(alt);
            try body.print(allocator, "<a href=\"{s}\"><img src=\"{s}\" alt=\"{s}\"></a>", .{ href, asset, alt });
            break;
        };
        try body.appendSlice(allocator, "</article>\n");
    }
    try body.appendSlice(allocator, "</div>\n");
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
        \\.instagram-gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(14rem,1fr));gap:1rem;margin:1rem 0}
        \\.instagram-gallery__item{margin:0}.instagram-gallery__item img{display:block;width:100%}
        \\.instagram-video{display:block;width:100%;max-width:56rem;margin:1rem 0;border-radius:.5rem}
        \\.instagram-feed{display:grid;gap:1rem}.instagram-feed__item{padding:1rem;background:#fff;border-radius:.5rem}.instagram-feed__item h2{margin:.2rem 0}.instagram-feed__meta{margin:0;color:#5c5470;font-size:.9rem}
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
        try buf.appendSlice(gpa, ",\n      \"human_entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.entity_id);
        try buf.appendSlice(gpa, ",\n      \"human_slug\": ");
        try jsonEscapeAppend(&buf, gpa, p.human_slug);
        try buf.appendSlice(gpa, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, p.kind);
        try buf.appendSlice(gpa, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n      \"timestamp\": ");
        if (p.timestamp) |t| try buf.print(gpa, "{d}", .{t}) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ",\n      \"iso_timestamp\": ");
        if (p.iso_timestamp.len > 0) try jsonEscapeAppend(&buf, gpa, p.iso_timestamp) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ",\n      \"conversion\": ");
        try jsonEscapeAppend(&buf, gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, ",\n      \"source_json_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.source_json_path);
        try buf.print(gpa, ",\n      \"media_count\": {d},\n      \"id_strategy\": ", .{p.media_count});
        try jsonEscapeAppend(&buf, gpa, p.id_strategy);
        try buf.appendSlice(gpa, ",\n      \"cover_asset\": ");
        if (p.cover_asset.len > 0) try jsonEscapeAppend(&buf, gpa, p.cover_asset) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ",\n      \"hashtags\": [");
        for (p.hashtags, 0..) |tag, ti| {
            if (ti > 0) try buf.appendSlice(gpa, ", ");
            try jsonEscapeAppend(&buf, gpa, tag);
        }
        try buf.appendSlice(gpa, "]");
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
        try buf.print(gpa, "- output: `{s}`\n- human_slug: `{s}`\n- iso_timestamp: `{s}`\n- cover_asset: `{s}`\n- kind: `{s}`\n- conversion: `{s}`\n- source: `{s}`\n- id_strategy: `{s}`\n- media_count: {d}\n", .{
            p.output_path,
            p.human_slug,
            p.iso_timestamp,
            p.cover_asset,
            p.kind,
            p.conversion.jsonName(),
            p.source_json_path,
            p.id_strategy,
            p.media_count,
        });
        if (p.hashtags.len > 0) {
            try buf.appendSlice(gpa, "- hashtags: ");
            for (p.hashtags, 0..) |tag, ti| {
                if (ti > 0) try buf.appendSlice(gpa, ", ");
                try buf.print(gpa, "#{s}", .{tag});
            }
            try buf.append(gpa, '\n');
        }
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
                    .encoding_repaired = false,
                    .encoding_suspect = false,
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
            switch (parsed.value) {
                .array, .object => try parseJsonArrayRecords(retain, parsed.value, kind, spath, &records),
                else => try records.append(retain, .{
                    .kind = .unknown,
                    .source_json_path = try retain.dupe(u8, spath),
                    .source_index = 0,
                    .title = try retain.dupe(u8, "Unsupported Instagram JSON record"),
                    .creation_timestamp = null,
                    .encoding_repaired = false,
                    .encoding_suspect = false,
                    .media = &.{},
                    .entity_id = "",
                    .id_strategy = "",
                    .conversion = .unsupported,
                    .notes = &.{try retain.dupe(u8, "unsupported scalar JSON root; placeholder emitted")},
                    .output_path = "",
                }),
            }
        } else if (std.mem.endsWith(u8, spath, ".html")) {
            try parseHtmlPostsFile(retain, gpa, bytes, spath, kind, &records);
        }
    }

    // Collision suffixes are based on stable export identity, never filesystem
    // iteration or timestamp order.
    std.mem.sort(IgRecord, records.items, {}, struct {
        fn less(_: void, a: IgRecord, b: IgRecord) bool {
            const source_order = std.mem.order(u8, a.source_json_path, b.source_json_path);
            if (source_order != .eq) return source_order == .lt;
            return a.source_index < b.source_index;
        }
    }.less);
    try assignEntityIds(retain, records.items);
    for (records.items) |*rec| {
        try classifyMediaPresence(io, dump, rec, retain);
    }
    try assignMediaDestinations(retain, records.items);

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

    const tag_pages = try buildHashtagPages(retain, records.items);

    // Materialize the complete replacement under a lab-owned staging tree.
    // The previous owned output is only moved aside after generation succeeds.
    const stage_path = try std.fmt.allocPrint(retain, "{s}.instagram-stage", .{opts.out_dir});
    const backup_path = try std.fmt.allocPrint(retain, "{s}.instagram-backup", .{opts.out_dir});
    try prepareOwnedStage(io, opts.out_dir, stage_path);
    var out_root = try Io.Dir.cwd().openDir(io, stage_path, .{});
    defer out_root.close(io);

    try writeThemeShell(io, out_root);

    // Copy media into theme (only referenced files that exist)
    var media_manifest: std.ArrayList(MediaManifestEntry) = .empty;
    defer media_manifest.deinit(gpa);
    var missing_media: std.ArrayList(MediaManifestEntry) = .empty;
    defer missing_media.deinit(gpa);

    for (records.items) |*rec| {
        for (rec.media) |*m| {
            var status: []const u8 = if (m.destination_rejected) "skipped" else if (m.present) "present" else "missing";
            if (m.present and isVideoThemeAsset(m.theme_rel)) {
                status = "video";
            }
            if (m.present and m.theme_rel.len > 0) {
                // theme path is assets/media/... — strip "assets/" for write under theme/
                const under_theme = m.theme_rel; // assets/...
                copyFileRel(io, dump, m.uri, out_root, try std.fmt.allocPrint(retain, "theme/{s}", .{under_theme})) catch {
                    status = "missing";
                    m.present = false;
                    rec.conversion = ConversionClass.worse(rec.conversion, .human_review);
                    var notes: std.ArrayList([]const u8) = .empty;
                    try notes.appendSlice(retain, rec.notes);
                    try notes.append(retain, try std.fmt.allocPrint(retain, "media copy failed: {s}", .{m.uri}));
                    rec.notes = try notes.toOwnedSlice(retain);
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
    const trunk = try writeTrunkMarkdown(gpa, records.items, tag_pages);
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
        const md = try writeRecordMarkdown(gpa, rec, tag_pages);
        defer gpa.free(md);
        try writeBytes(io, out_root, rec.output_path, md);

        const iso = try formatIsoTimestamp(retain, rec.creation_timestamp);
        var cover_asset: []const u8 = "";
        for (rec.media) |media| if (media.present and !isVideoThemeAsset(media.theme_rel)) {
            cover_asset = media.theme_rel;
            break;
        };
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
            .human_slug = rec.slug,
            .iso_timestamp = iso,
            .hashtags = rec.hashtags,
            .cover_asset = cover_asset,
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

    for (tag_pages) |tag| {
        const tag_md = try writeHashtagMarkdown(gpa, tag, records.items);
        defer gpa.free(tag_md);
        try writeBytes(io, out_root, try std.fmt.allocPrint(retain, "content/instagram/tags/{s}.md", .{tag.slug}), tag_md);
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
    try writeBytes(io, out_root, output_owner_marker, "format=boris-instagram-migration-lab\nschema_version=2\n");
    // POSIX allows the directory rename while this descriptor is open; all
    // writes above are complete, so a failed commit leaves the old tree intact.
    try publishOwnedStage(io, opts.out_dir, stage_path, backup_path);

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

test "firstLineTitle does not split utf8" {
    // curly apostrophe U+2019 is e2 80 99 — truncating mid-sequence is invalid UTF-8
    const s = "ab\xe2\x80\x99cd"; // ab'cd
    const t = firstLineTitle(s, 3);
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    try std.testing.expectEqualStrings("ab", t);
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

test "human slug uses caption text and a stable fallback" {
    const slug = try humanSlug(std.testing.allocator, "Hello, World!", "photo-post");
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("hello-world", slug);
    const fallback = try humanSlug(std.testing.allocator, "日本語 🎨", "photo-post");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("photo-post", fallback);
}

test "UTC date and ISO formatting cover boundaries" {
    const midnight = try formatHumanUtc(std.testing.allocator, 1704067200);
    defer std.testing.allocator.free(midnight);
    try std.testing.expectEqualStrings("January 1, 2024 · 12:00 AM UTC", midnight);
    const noon = try formatHumanUtc(std.testing.allocator, 1704110400);
    defer std.testing.allocator.free(noon);
    try std.testing.expectEqualStrings("January 1, 2024 · 12:00 PM UTC", noon);
    const leap = try formatIsoTimestamp(std.testing.allocator, 1709164800);
    defer std.testing.allocator.free(leap);
    try std.testing.expectEqualStrings("2024-02-29T00:00:00Z", leap);
    const undated = try formatIsoTimestamp(std.testing.allocator, null);
    defer std.testing.allocator.free(undated);
    try std.testing.expectEqualStrings("", undated);
}

test "caption hashtag extraction deduplicates and preserves unicode" {
    const tags = try extractHashtags(std.testing.allocator, "#One #one #日本語 #_ok #");
    defer {
        for (tags) |tag| std.testing.allocator.free(tag);
        std.testing.allocator.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("One", tags[0]);
    try std.testing.expectEqualStrings("日本語", tags[1]);
}

test "mentions reject email interiors and caption escaping is harmless" {
    try std.testing.expect(mentionEnd("hi @artist", 3) != null);
    try std.testing.expect(mentionEnd("mail me@example.com", 7) == null);
    const escaped = try escapeHtmlAttr(std.testing.allocator, "\"<img onerror='x'>");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("&quot;&lt;img onerror=&#39;x&#39;&gt;", escaped);
}

test "relative published links work from deep Instagram pages" {
    const page = try relativePublishedHref(std.testing.allocator, "instagram/posts/2024/01/example", "assets/media/posts/photo.jpg");
    defer std.testing.allocator.free(page);
    try std.testing.expectEqualStrings("../../../../assets/media/posts/photo.jpg", page);
    const tag = try relativePublishedHref(std.testing.allocator, "instagram/posts/2024/01/example", "instagram/tags/example.html");
    defer std.testing.allocator.free(tag);
    try std.testing.expectEqualStrings("../../../tags/example.html", tag);
}

test "repairMetaEscapedUtf8 repairs Meta JSON escapes and preserves normal UTF-8" {
    const repaired = try repairMetaEscapedUtf8(std.testing.allocator, "caf\u{c3}\u{a9} \u{f0}\u{9f}\u{98}\u{8a}");
    defer if (repaired.repaired) std.testing.allocator.free(repaired.text);
    try std.testing.expect(repaired.repaired);
    try std.testing.expectEqualStrings("café 😊", repaired.text);

    const ordinary = try repairMetaEscapedUtf8(std.testing.allocator, "café 😊");
    try std.testing.expect(!ordinary.repaired);
    try std.testing.expectEqualStrings("café 😊", ordinary.text);
}

test "isSafeMediaUri rejects dump/output escapes and keeps ordinary media paths" {
    // Ordinary Takeout shapes stay convertible.
    try std.testing.expect(isSafeMediaUri("media/posts/202401/photo_1.jpg"));
    try std.testing.expect(isSafeMediaUri("media/other/a.b..c.jpg")); // dots, not a component
    try std.testing.expect(isSafeMediaUri("media/..hidden/x.jpg"));

    // Escapes.
    try std.testing.expect(!isSafeMediaUri(""));
    try std.testing.expect(!isSafeMediaUri("../../../etc/passwd"));
    try std.testing.expect(!isSafeMediaUri("media/../../escape.jpg"));
    try std.testing.expect(!isSafeMediaUri(".."));
    try std.testing.expect(!isSafeMediaUri("/etc/hosts")); // absolute bypasses the dir fd
    try std.testing.expect(!isSafeMediaUri("..\\..\\escape.jpg")); // Windows separator
    try std.testing.expect(!isSafeMediaUri("media\\posts\\x.jpg"));
    try std.testing.expect(!isSafeMediaUri("C:/Windows/win.ini")); // drive prefix
    try std.testing.expect(!isSafeMediaUri("a\x00b"));
}

test "validated media extensions are allowlisted and lowercase" {
    const gpa = std.testing.allocator;
    const jpg = (try validatedMediaExtension(gpa, "media/posts/photo.JPEG")).?;
    defer gpa.free(jpg);
    try std.testing.expectEqualStrings("jpeg", jpg);
    const mov = (try validatedMediaExtension(gpa, "media/reels/video.MOV")).?;
    defer gpa.free(mov);
    try std.testing.expectEqualStrings("mov", mov);
    try std.testing.expect((try validatedMediaExtension(gpa, "media/posts/no-extension")) == null);
    try std.testing.expect((try validatedMediaExtension(gpa, "media/posts/script.jpg.exe")) == null);
    try std.testing.expect((try validatedMediaExtension(gpa, "media/posts/photo.jpg?download=1")) == null);
    try std.testing.expect((try validatedMediaExtension(gpa, "media/posts/photo.jpg#fragment")) == null);
    try std.testing.expect((try validatedMediaExtension(gpa, "media/posts/photo\\.jpg")) == null);
}

test "human media destinations use record ids, source order, and safe extensions" {
    const gpa = std.testing.allocator;
    var carousel = [_]MediaItem{
        .{ .uri = "media/posts/opaque_1111111111111111111_a.JPG" },
        .{ .uri = "media/posts/opaque_2222222222222222222_b.png" },
        .{ .uri = "media/posts/opaque_3333333333333333333_c.MP4" },
    };
    var captionless = [_]MediaItem{.{ .uri = "media/posts/opaque_4444444444444444444.jpg" }};
    var undated = [_]MediaItem{.{ .uri = "media/posts/opaque_5555555555555555555.mov" }};
    var records = [_]IgRecord{
        .{ .kind = .post, .source_json_path = "posts.json", .source_index = 0, .title = "", .creation_timestamp = 0, .encoding_repaired = false, .encoding_suspect = false, .media = &carousel, .entity_id = "instagram/posts/2024/11/2024-11-19-human-post-slug", .id_strategy = "test", .conversion = .exact, .notes = &.{}, .output_path = "" },
        .{ .kind = .post, .source_json_path = "posts.json", .source_index = 1, .title = "", .creation_timestamp = 0, .encoding_repaired = false, .encoding_suspect = false, .media = &captionless, .entity_id = "instagram/posts/2024/01/2024-01-15-photo-post", .id_strategy = "test", .conversion = .exact, .notes = &.{}, .output_path = "" },
        .{ .kind = .reel, .source_json_path = "reels.json", .source_index = 0, .title = "", .creation_timestamp = null, .encoding_repaired = false, .encoding_suspect = false, .media = &undated, .entity_id = "instagram/reels/undated/reel", .id_strategy = "test", .conversion = .exact, .notes = &.{}, .output_path = "" },
    };
    try assignMediaDestinations(gpa, &records);
    defer {
        for (carousel) |m| gpa.free(m.theme_rel);
        for (captionless) |m| gpa.free(m.theme_rel);
        for (undated) |m| gpa.free(m.theme_rel);
    }
    try std.testing.expectEqualStrings("assets/media/instagram/posts/2024/11/2024-11-19-human-post-slug-01.jpg", carousel[0].theme_rel);
    try std.testing.expectEqualStrings("assets/media/instagram/posts/2024/11/2024-11-19-human-post-slug-02.png", carousel[1].theme_rel);
    try std.testing.expectEqualStrings("assets/media/instagram/posts/2024/11/2024-11-19-human-post-slug-03.mp4", carousel[2].theme_rel);
    try std.testing.expectEqualStrings("assets/media/instagram/posts/2024/01/2024-01-15-photo-post-01.jpg", captionless[0].theme_rel);
    try std.testing.expectEqualStrings("assets/media/instagram/reels/undated/reel-01.mov", undated[0].theme_rel);
    try std.testing.expect(isVideoThemeAsset(carousel[2].theme_rel));
    try std.testing.expect(!hasOpaqueMetaBasename(carousel[0].theme_rel));
    try std.testing.expect(hasOpaqueMetaBasename("assets/media/118274741_241841870327375_6450238268085367473_n_17890506610615222.jpg"));
}

test "media destination collision adds a deterministic counter" {
    const gpa = std.testing.allocator;
    var first_media = [_]MediaItem{.{ .uri = "media/posts/one.jpg" }};
    var second_media = [_]MediaItem{.{ .uri = "media/posts/two.jpg" }};
    var records = [_]IgRecord{
        .{ .kind = .post, .source_json_path = "a.json", .source_index = 0, .title = "", .creation_timestamp = null, .encoding_repaired = false, .encoding_suspect = false, .media = &first_media, .entity_id = "instagram/posts/undated/photo-post", .id_strategy = "test", .conversion = .exact, .notes = &.{}, .output_path = "" },
        .{ .kind = .post, .source_json_path = "b.json", .source_index = 0, .title = "", .creation_timestamp = null, .encoding_repaired = false, .encoding_suspect = false, .media = &second_media, .entity_id = "instagram/posts/undated/photo-post", .id_strategy = "test", .conversion = .exact, .notes = &.{}, .output_path = "" },
    };
    try assignMediaDestinations(gpa, &records);
    defer gpa.free(first_media[0].theme_rel);
    defer gpa.free(second_media[0].theme_rel);
    try std.testing.expectEqualStrings("assets/media/instagram/posts/undated/photo-post-01.jpg", first_media[0].theme_rel);
    try std.testing.expectEqualStrings("assets/media/instagram/posts/undated/photo-post-01-2.jpg", second_media[0].theme_rel);
}

test "repairMetaEscapedUtf8 flags residue instead of claiming clean utf-8" {
    const gpa = std.testing.allocator;

    // Mixed escaped + genuine Unicode: repair must decline AND report residue,
    // otherwise a corrupted caption is stamped `encoding: utf-8`.
    const mixed = try repairMetaEscapedUtf8(gpa, "caf\u{c3}\u{a9} \u{1F60A}");
    defer if (mixed.repaired) gpa.free(mixed.text);
    try std.testing.expect(!mixed.repaired);
    try std.testing.expect(mixed.residue);

    // Doubly encoded: one pass leaves mojibake behind, so it is not "repaired
    // and clean" — the residue flag keeps provenance honest.
    const double = try repairMetaEscapedUtf8(gpa, "caf\u{c3}\u{83}\u{c2}\u{a9}");
    defer if (double.repaired) gpa.free(double.text);
    try std.testing.expect(double.repaired);
    try std.testing.expect(double.residue);

    // Single-pass mojibake repairs cleanly, with no residue.
    const single = try repairMetaEscapedUtf8(gpa, "caf\u{c3}\u{a9}");
    defer if (single.repaired) gpa.free(single.text);
    try std.testing.expect(single.repaired);
    try std.testing.expect(!single.residue);
    try std.testing.expectEqualStrings("café", single.text);

    // Genuine prose is never flagged.
    for ([_][]const u8{ "café 😊", "über", "A\u{f1}o", "plain ascii", "" }) |ok| {
        const r = try repairMetaEscapedUtf8(gpa, ok);
        defer if (r.repaired) gpa.free(r.text);
        try std.testing.expect(!r.repaired);
        try std.testing.expect(!r.residue);
    }
}

test "longestBacktickRun sizes a fence untrusted captions cannot close" {
    try std.testing.expectEqual(@as(usize, 0), longestBacktickRun("no ticks"));
    try std.testing.expectEqual(@as(usize, 3), longestBacktickRun("a\n```\nb"));
    try std.testing.expectEqual(@as(usize, 5), longestBacktickRun("`` ````` ```"));
}

test "fixture: symlinked Instagram media is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const dump = "fixtures/.ig-symlink-dump";
    const out = "fixtures/.ig-symlink-out";
    Io.Dir.cwd().deleteTree(io, dump) catch {};
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, dump) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};
    try Io.Dir.cwd().createDirPath(io, dump ++ "/your_instagram_activity/content");
    try Io.Dir.cwd().createDirPath(io, dump ++ "/media/posts");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/your_instagram_activity/content/posts_1.json", .data =
        \\[{"title":"linked media","creation_timestamp":1704067200,"media":[{"uri":"media/posts/alias.jpg"}]}]
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/outside.jpg", .data = "not-for-copy" });
    var media = try Io.Dir.cwd().openDir(io, dump ++ "/media/posts", .{});
    defer media.close(io);
    media.symLink(io, "../../outside.jpg", "alias.jpg", .{}) catch return;
    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out, .quiet = true });
    var root = try Io.Dir.cwd().openDir(io, out, .{});
    defer root.close(io);
    const report = try readFileAlloc(io, root, "report.json", gpa);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "symlink media path rejected") != null);
    try std.testing.expect(!pathExists(io, root, "theme/assets/media/instagram/posts/2024/01/2024-01-01-linked-media-01.jpg"));
}

test "fixture: hostile instagram dump cannot escape dump or output root" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const dump = "fixtures/hostile-instagram";
    const out = "fixtures/.ig-hostile-out";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};

    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out, .quiet = true });

    var out_root = try Io.Dir.cwd().openDir(io, out, .{});
    defer out_root.close(io);

    const report = try readFileAlloc(io, out_root, "report.json", gpa);
    defer gpa.free(report);

    // Every hostile uri is refused by name, and none is reported as converted.
    for ([_][]const u8{
        "../../../ESCAPED.txt",
        "/etc/hosts",
        "..\\\\..\\\\ESCAPED.txt",
        "C:/Windows/win.ini",
    }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, report, bad) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, report, "unsafe media uri rejected") != null);

    // Nothing hostile was copied into the theme tree.
    try std.testing.expect(!pathExists(io, out_root, "theme/assets/etc/hosts"));
    try std.testing.expect(!pathExists(io, out_root, "theme/assets/../ESCAPED.txt"));
    try std.testing.expect(!pathExists(io, out_root, "ESCAPED.txt"));

    // The benign control record still converts — the guard is not over-broad.
    try std.testing.expect(pathExists(io, out_root, "theme/assets/media/instagram/posts/2024/01/2024-01-10-benign-control-post-01.jpg"));

    // A hostile caption is emitted as escaped text, never a live HTML/script
    // node or a code-fenced compiler receipt.
    const fence_page = try readFileAlloc(io, out_root, "content/instagram/posts/2024/01/2024-01-10-breaks-out-of-the-caption-fence.md", gpa);
    defer gpa.free(fence_page);
    try std.testing.expect(std.mem.indexOf(u8, fence_page, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, fence_page, "## Caption") == null);

    // Mixed and doubly-encoded captions are flagged, never stamped clean.
    try std.testing.expect(std.mem.indexOf(u8, report, "mojibake signature remains") != null);
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

    // theme css + a physically copied, human-named media file. This asserts
    // bytes, not merely a rewritten Markdown reference.
    const css = try readFileAlloc(io, a_root, "theme/assets/css/site.css", gpa);
    defer gpa.free(css);
    const source_photo = try readFileAlloc(io, dump_dir, "media/posts/202401/photo_1111111111111111111.jpg", gpa);
    defer gpa.free(source_photo);
    const photo_path = "theme/assets/media/instagram/posts/2024/01/2024-01-01-simple-photo-post-with-drawmeanelephant-01.jpg";
    const photo = try readFileAlloc(io, a_root, photo_path, gpa);
    defer gpa.free(photo);
    try std.testing.expectEqualSlices(u8, source_photo, photo);
    try std.testing.expect(pathExists(io, b_root, photo_path));
    const photo_b = try readFileAlloc(io, b_root, photo_path, gpa);
    defer gpa.free(photo_b);
    try std.testing.expectEqualSlices(u8, source_photo, photo_b);
    try std.testing.expect(!pathExists(io, a_root, "theme/assets/media/posts/202401/photo_1111111111111111111.jpg"));
    try std.testing.expect(pathExists(io, a_root, "theme/assets/media/instagram/posts/2024/01/2024-01-02-carousel-two-frames-caf-01.jpg"));
    try std.testing.expect(pathExists(io, a_root, "theme/assets/media/instagram/posts/2024/01/2024-01-02-carousel-two-frames-caf-02.jpg"));
    try std.testing.expect(pathExists(io, a_root, "theme/assets/media/instagram/posts/2024/01/2024-01-03-video-post-no-ocr-01.mp4"));

    const simple_page = try readFileAlloc(io, a_root, "content/instagram/posts/2024/01/2024-01-01-simple-photo-post-with-drawmeanelephant.md", gpa);
    defer gpa.free(simple_page);
    try std.testing.expect(std.mem.indexOf(u8, simple_page, "2024-01-01-simple-photo-post-with-drawmeanelephant-01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, simple_page, "uri: media/posts/202401/photo_1111111111111111111.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, simple_page, "theme: assets/media/instagram/posts/2024/01/2024-01-01-simple-photo-post-with-drawmeanelephant-01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, simple_page, "assets/media/posts/202401/photo_1111111111111111111.jpg") == null);

    // The hub is a separate renderer path; its thumbnail must use the copied
    // public theme asset rather than the export tree.
    try std.testing.expect(std.mem.indexOf(u8, trunk, "assets/media/instagram/posts/2024/01/2024-01-01-simple-photo-post-with-drawmeanelephant-01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, trunk, "assets/media/posts/202401/photo_1111111111111111111.jpg") == null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "\"source_uri\": \"media/posts/202401/photo_1111111111111111111.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "\"theme_asset\": \"assets/media/instagram/posts/2024/01/2024-01-01-simple-photo-post-with-drawmeanelephant-01.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "\"theme_asset\": \"assets/media/posts/") == null);

    const video_page = try readFileAlloc(io, a_root, "content/instagram/posts/2024/01/2024-01-03-video-post-no-ocr.md", gpa);
    defer gpa.free(video_page);
    try std.testing.expect(std.mem.indexOf(u8, video_page, "<video") != null);
    try std.testing.expect(std.mem.indexOf(u8, video_page, "2024-01-03-video-post-no-ocr-01.mp4") != null);

    const repaired_page = try readFileAlloc(io, a_root, "content/instagram/posts/2024/01/2024-01-10-meta-escaped-caf.md", gpa);
    defer gpa.free(repaired_page);
    try std.testing.expect(std.mem.indexOf(u8, repaired_page, "café 😊") != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired_page, "cafÃ©") == null);
    try std.testing.expect(std.mem.indexOf(u8, repaired_page, "encoding: meta-latin1-repaired") != null);
}

test "fixture: staged rerun removes obsolete renamed media" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const dump = "fixtures/.ig-shrinking-dump";
    const out = "fixtures/.ig-shrinking-out";
    Io.Dir.cwd().deleteTree(io, dump) catch {};
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, dump) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};
    try Io.Dir.cwd().createDirPath(io, dump ++ "/your_instagram_activity/content");
    try Io.Dir.cwd().createDirPath(io, dump ++ "/media/posts");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/media/posts/first.jpg", .data = "first fixture bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/media/posts/second.jpg", .data = "second fixture bytes" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/your_instagram_activity/content/posts_1.json", .data =
        \\[{"title":"Old carousel title","creation_timestamp":1704067200,"media":[{"uri":"media/posts/first.jpg"},{"uri":"media/posts/second.jpg"}]}]
    });
    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out, .quiet = true });
    const old_first = "theme/assets/media/instagram/posts/2024/01/2024-01-01-old-carousel-title-01.jpg";
    const old_second = "theme/assets/media/instagram/posts/2024/01/2024-01-01-old-carousel-title-02.jpg";
    {
        var root = try Io.Dir.cwd().openDir(io, out, .{});
        defer root.close(io);
        try std.testing.expect(pathExists(io, root, old_first));
        try std.testing.expect(pathExists(io, root, old_second));
    }

    // A changed caption plus a shorter carousel must replace, not accumulate,
    // owned media paths. The removed second source item remains untouched.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/your_instagram_activity/content/posts_1.json", .data =
        \\[{"title":"New single title","creation_timestamp":1704067200,"media":[{"uri":"media/posts/first.jpg"}]}]
    });
    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out, .quiet = true });
    const new_first = "theme/assets/media/instagram/posts/2024/01/2024-01-01-new-single-title-01.jpg";
    {
        var root = try Io.Dir.cwd().openDir(io, out, .{});
        defer root.close(io);
        try std.testing.expect(pathExists(io, root, new_first));
        try std.testing.expect(!pathExists(io, root, old_first));
        try std.testing.expect(!pathExists(io, root, old_second));
    }

    // A disappearing record leaves no stale human media behind on the same
    // owned-output directory.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump ++ "/your_instagram_activity/content/posts_1.json", .data = "[]" });
    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out, .quiet = true });
    var final_root = try Io.Dir.cwd().openDir(io, out, .{});
    defer final_root.close(io);
    try std.testing.expect(!pathExists(io, final_root, new_first));
}

test "publishedHtmlHref matches entity_id.html" {
    var buf: [maxEntityIdHrefBytes]u8 = undefined;
    const href = try publishedHtmlHref("instagram/post-abc", &buf);
    try std.testing.expectEqualStrings("instagram/post-abc.html", href);
}

test "escapeMdLinkLabel escapes brackets and backslashes" {
    const e = try escapeMdLinkLabel(std.testing.allocator, "a]b\\c");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("a\\]b\\\\c", e);
}

// Archive index must link published HTML paths ({entity_id}.html), not source
// Markdown. Every child page must appear as a link target that exists on disk.
test "fixture: archive index links published .html paths that exist as content pages" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const dump = "fixtures/mini-instagram";
    const out = "fixtures/.ig-test-index-links";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};

    try run(io, gpa, .{ .dump_dir = dump, .out_dir = out, .quiet = true });

    var root = try Io.Dir.cwd().openDir(io, out, .{});
    defer root.close(io);

    const trunk = try readFileAlloc(io, root, "content/instagram.md", gpa);
    defer gpa.free(trunk);

    // Must not emit source-tree .md hrefs for child records (those 404 under a
    // static server that only serves Boris HTML publish output).
    try std.testing.expect(std.mem.indexOf(u8, trunk, "](instagram/") != null);
    try std.testing.expect(std.mem.indexOf(u8, trunk, "href=\"instagram/posts/") != null);
    try std.testing.expect(std.mem.indexOf(u8, trunk, ".html") != null);
    try std.testing.expect(std.mem.indexOf(u8, trunk, ".md)") == null);
    const record = try readFileAlloc(io, root, "content/instagram/posts/2024/01/2024-01-01-simple-photo-post-with-drawmeanelephant.md", gpa);
    defer gpa.free(record);
    try std.testing.expect(std.mem.indexOf(u8, record, "id: instagram/posts/2024/01/") != null);
    const tag_page = try readFileAlloc(io, root, "content/instagram/tags/drawmeanelephant.md", gpa);
    defer gpa.free(tag_page);
    try std.testing.expect(std.mem.indexOf(u8, tag_page, "parent: instagram") != null);
}
