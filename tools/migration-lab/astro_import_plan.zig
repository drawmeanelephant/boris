//! Deliberately narrow, plan-only Astro plain-Markdown import surface.
//!
//! This module never executes project code and never writes an imported Boris
//! tree.  Its only output is a staged, deterministic review plan.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");

pub const format_id = "boris-astro-import-plan";
pub const schema_version: u32 = 1;
pub const snapshot_format = "boris-astro-source-snapshot";
pub const policy_format = "boris-astro-import-policy";
pub const tool_version = "0.8.1";

/// This byte sequence is also committed as the policy artifact named in the
/// plan contract.  It is intentionally compact: its SHA-256 is policy identity.
pub const policy_bytes = "{\"format\":\"boris-astro-import-policy\",\"schema_version\":1,\"source_system\":\"astro\",\"supported_frontmatter\":[\"id\",\"title\",\"status\",\"tags\"],\"frontmatter_grammar\":\"Boris closed scalar grammar; blank lines allowed; comments are ordinary value text, not syntax\",\"supported_source\":\"explicit .md beneath a no-follow --content-root with ordinary Markdown outside literal code\",\"reference_inventory\":\"typed, code-aware, exact-deduplicated; no resolution or copying\",\"non_goals\":[\"apply\",\"asset-copy\",\"mdx\",\"route-observation\",\"parent-inference\"]}\n";

pub const RunOptions = struct {
    root_dir: []const u8,
    content_root: []const u8,
    out_dir: []const u8,
    project_id: []const u8,
    previous_manifest: ?[]const u8 = null,
    quiet: bool = false,
};

const RecordClass = enum { create, keep, quarantine, unsupported, review, conflict };

const Record = struct {
    source_path: []const u8,
    source_kind: []const u8,
    byte_hash: ?[]const u8,
    frontmatter_hash: ?[]const u8,
    body_hash: ?[]const u8,
    symlink_target: ?[]const u8 = null,
    import_id: ?[]const u8,
    generated_import_id: ?[]const u8 = null,
    base_action: RecordClass,
    action: RecordClass,
    reason: []const u8,
    has_frontmatter: bool = false,
    frontmatter_valid: bool = true,
    frontmatter: ?[]const u8 = null,
    title: ?[]const u8 = null,
    authored_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    proposed_boris_source_path: ?[]const u8 = null,
    proposed_entity_id: ?[]const u8 = null,
    inferred_route_candidate: ?[]const u8 = null,
    proposed_boris_route: ?[]const u8 = null,
    proposal_valid: bool = false,
    links: []const Reference = &.{},
};

const ReferenceSyntax = enum {
    inline_link,
    inline_image,
    reference_link_use,
    reference_image_use,
    reference_definition,
    autolink,
};

const ReferenceClass = enum {
    reference_label,
    fragment,
    root_relative,
    source_relative,
    protocol_relative,
    http,
    https,
    mailto,
    ftp,
    other_scheme,
    data_url,
    review,
};

const Reference = struct {
    syntax: ReferenceSyntax,
    classification: ReferenceClass,
    target: []const u8,
};

const Previous = struct { source_path: []const u8, import_id: []const u8 };

const Finding = struct {
    class: RecordClass,
    reason: []const u8,
    source_paths: []const []const u8,
};

fn appendJson(b: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try b.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try b.appendSlice(a, "\\\""),
        '\\' => try b.appendSlice(a, "\\\\"),
        '\n' => try b.appendSlice(a, "\\n"),
        '\r' => try b.appendSlice(a, "\\r"),
        '\t' => try b.appendSlice(a, "\\t"),
        else => if (c < 0x20) {
            var buf: [6]u8 = undefined;
            try b.appendSlice(a, try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}));
        } else try b.append(a, c),
    };
    try b.append(a, '"');
}

fn sha256Hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const result = try a.alloc(u8, 64);
    const chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        result[i * 2] = chars[byte >> 4];
        result[i * 2 + 1] = chars[byte & 15];
    }
    return result;
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn join(a: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    return if (left.len == 0) a.dupe(u8, right) else std.fmt.allocPrint(a, "{s}/{s}", .{ left, right });
}

fn ensureParent(io: Io, dir: Io.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try dir.createDirPath(io, parent);
}

fn write(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    try ensureParent(io, dir, path);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn validProjectId(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

fn validRelative(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/' or std.mem.indexOfScalar(u8, s, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn validSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c) or (c >= 'A' and c <= 'F')) return false;
    return true;
}

fn validRecordId(s: []const u8) bool {
    return s.len == 68 and std.mem.startsWith(u8, s, "air_") and validSha256(s[4..]);
}

fn validEntityId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or id[0] == '/' or id[id.len - 1] == '/' or id[id.len - 1] == '\\') return false;
    var segments = std.mem.splitScalar(u8, id, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| {
            if (c == '\\' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '#' or c == '?' or c == '%') return false;
        }
    }
    return true;
}

fn validRoute(route: []const u8) bool {
    return validEntityId(route);
}

fn recordId(a: std.mem.Allocator, project_id: []const u8, source_path: []const u8) ![]const u8 {
    const input = try std.fmt.allocPrint(a, "boris-astro-import-record-v1\n{s}\n{s}", .{ project_id, source_path });
    defer a.free(input);
    const digest = try sha256Hex(a, input);
    defer a.free(digest);
    return std.fmt.allocPrint(a, "air_{s}", .{digest});
}

const ParsedFrontmatter = struct {
    has_frontmatter: bool,
    fm: []const u8,
    body: []const u8,
    title: ?[]const u8,
    id: ?[]const u8,
    status: ?[]const u8,
    tags: []const []const u8,
    ok: bool,
    reason: []const u8,
};

fn frontmatterFailure(
    fm: []const u8,
    body: []const u8,
    title: ?[]const u8,
    id: ?[]const u8,
    status: ?[]const u8,
    tags: []const []const u8,
    reason: []const u8,
) ParsedFrontmatter {
    return .{
        .has_frontmatter = true,
        .fm = fm,
        .body = body,
        .title = title,
        .id = id,
        .status = status,
        .tags = tags,
        .ok = false,
        .reason = reason,
    };
}

fn readPhysicalLine(source: []const u8, start: usize) struct { line: []const u8, after: usize, had_newline: bool } {
    const newline = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse {
        return .{ .line = source[start..], .after = source.len, .had_newline = false };
    };
    var line = source[start..newline];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return .{ .line = line, .after = newline + 1, .had_newline = true };
}

fn parseScalarValue(raw: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return error.EmptyValue;
    if (value[0] == '\'') return error.SingleQuotedValue;
    if (value[0] == '|' or value[0] == '>') return error.MultilineScalar;
    if (value[0] == '[' or value[0] == '{' or value[0] == '&' or value[0] == '*') return error.UnsupportedStructuredValue;
    if (value[0] == '"') {
        if (value.len < 3 or value[value.len - 1] != '"') return error.MalformedDoubleQuote;
        const inner = value[1 .. value.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '"') != null) return error.MalformedDoubleQuote;
        return inner;
    }
    return value;
}

fn parseTags(raw: []const u8, a: std.mem.Allocator) ![]const []const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.MalformedTags;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return &.{};
    var result: std.ArrayList([]const u8) = .empty;
    var cursor: usize = 0;
    while (cursor < inner.len) {
        while (cursor < inner.len and (inner[cursor] == ' ' or inner[cursor] == '\t')) : (cursor += 1) {}
        if (cursor >= inner.len) return error.MalformedTags;
        const start = cursor;
        if (inner[cursor] == '\'') return error.MalformedTags;
        if (inner[cursor] == '"') {
            cursor += 1;
            while (cursor < inner.len and inner[cursor] != '"') : (cursor += 1) {}
            if (cursor >= inner.len) return error.MalformedTags;
            cursor += 1;
        } else {
            while (cursor < inner.len and inner[cursor] != ',' and inner[cursor] != ' ' and inner[cursor] != '\t') : (cursor += 1) {}
        }
        const parsed = parseScalarValue(inner[start..cursor]) catch return error.MalformedTags;
        if (parsed.len == 0 or parsed.len > 64 or result.items.len >= 32) return error.MalformedTags;
        try result.append(a, try a.dupe(u8, parsed));
        while (cursor < inner.len and (inner[cursor] == ' ' or inner[cursor] == '\t')) : (cursor += 1) {}
        if (cursor == inner.len) break;
        if (inner[cursor] != ',') return error.MalformedTags;
        cursor += 1;
        while (cursor < inner.len and (inner[cursor] == ' ' or inner[cursor] == '\t')) : (cursor += 1) {}
        if (cursor == inner.len) return error.MalformedTags;
    }
    return result.toOwnedSlice(a);
}

fn parseFrontmatter(bytes: []const u8, a: std.mem.Allocator) !ParsedFrontmatter {
    if (bytes.len == 0) return .{ .has_frontmatter = false, .fm = "", .body = bytes, .title = null, .id = null, .status = null, .tags = &.{}, .ok = true, .reason = "" };
    const first = readPhysicalLine(bytes, 0);
    if (!std.mem.eql(u8, first.line, "---")) return .{ .has_frontmatter = false, .fm = "", .body = bytes, .title = null, .id = null, .status = null, .tags = &.{}, .ok = true, .reason = "" };
    if (!first.had_newline) return frontmatterFailure(bytes, "", null, null, null, &.{}, "unclosed_frontmatter");

    var close_start: ?usize = null;
    var close_after: usize = 0;
    var fm_cursor = first.after;
    while (fm_cursor < bytes.len) {
        const line = readPhysicalLine(bytes, fm_cursor);
        if (std.mem.eql(u8, line.line, "---")) {
            close_start = fm_cursor;
            close_after = line.after;
            break;
        }
        if (!line.had_newline) break;
        fm_cursor = line.after;
    }
    if (close_start == null) return frontmatterFailure(bytes[first.after..], "", null, null, null, &.{}, "unclosed_frontmatter");

    const fm = bytes[first.after..close_start.?];
    const body = bytes[close_after..];
    var title: ?[]const u8 = null;
    var authored_id: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var tags: []const []const u8 = &.{};
    var saw_id = false;
    var saw_title = false;
    var saw_status = false;
    var saw_tags = false;
    var line_start: usize = 0;
    while (line_start < fm.len) {
        const physical = readPhysicalLine(fm, line_start);
        const line = physical.line;
        if (std.mem.trim(u8, line, " \t").len != 0) {
            if (line[0] == ' ' or line[0] == '\t' or (line.len >= 2 and line[0] == '-' and (line[1] == ' ' or line[1] == '\t'))) {
                return frontmatterFailure(fm, body, title, authored_id, status, tags, "nested_or_sequence_frontmatter");
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return frontmatterFailure(fm, body, title, authored_id, status, tags, "malformed_frontmatter_line");
            const key = std.mem.trim(u8, line[0..colon], " \t");
            if (key.len == 0) return frontmatterFailure(fm, body, title, authored_id, status, tags, "empty_frontmatter_key");
            const raw_value = line[colon + 1 ..];
            if (std.mem.eql(u8, key, "tags")) {
                if (saw_tags) return frontmatterFailure(fm, body, title, authored_id, status, tags, "duplicate_frontmatter_tags");
                saw_tags = true;
                tags = parseTags(raw_value, a) catch return frontmatterFailure(fm, body, title, authored_id, status, tags, "malformed_frontmatter_tags");
            } else if (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "status")) {
                const value = parseScalarValue(raw_value) catch |err| return frontmatterFailure(fm, body, title, authored_id, status, tags, switch (err) {
                    error.EmptyValue => "empty_frontmatter_value",
                    error.SingleQuotedValue => "single_quoted_frontmatter_value",
                    error.MalformedDoubleQuote => "malformed_double_quoted_frontmatter_value",
                    error.MultilineScalar => "multiline_frontmatter_value",
                    error.UnsupportedStructuredValue => "unsupported_frontmatter_value",
                });
                if (std.mem.eql(u8, key, "id")) {
                    if (saw_id) return frontmatterFailure(fm, body, title, authored_id, status, tags, "duplicate_frontmatter_id");
                    saw_id = true;
                    if (!validEntityId(value)) return frontmatterFailure(fm, body, title, authored_id, status, tags, "invalid_frontmatter_id");
                    authored_id = try a.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "title")) {
                    if (saw_title) return frontmatterFailure(fm, body, title, authored_id, status, tags, "duplicate_frontmatter_title");
                    saw_title = true;
                    if (value.len > 512) return frontmatterFailure(fm, body, title, authored_id, status, tags, "frontmatter_title_too_long");
                    title = try a.dupe(u8, value);
                } else {
                    if (saw_status) return frontmatterFailure(fm, body, title, authored_id, status, tags, "duplicate_frontmatter_status");
                    saw_status = true;
                    if (!(std.mem.eql(u8, value, "draft") or std.mem.eql(u8, value, "published") or std.mem.eql(u8, value, "archived"))) {
                        return frontmatterFailure(fm, body, title, authored_id, status, tags, "invalid_frontmatter_status");
                    }
                    status = try a.dupe(u8, value);
                }
            } else {
                return frontmatterFailure(fm, body, title, authored_id, status, tags, "unsupported_frontmatter_key");
            }
        }
        if (!physical.had_newline) break;
        line_start = physical.after;
    }
    return .{ .has_frontmatter = true, .fm = fm, .body = body, .title = title, .id = authored_id, .status = status, .tags = tags, .ok = true, .reason = "" };
}

const MarkdownMask = struct {
    bytes: []const u8,
    issue: ?[]const u8,
};

fn markerRun(line: []const u8, marker: u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == marker) : (count += 1) {}
    return count;
}

fn exactBacktickClose(line: []const u8, start: usize, tick_run: usize) ?usize {
    var cursor = start;
    while (cursor < line.len) {
        if (line[cursor] != '`') {
            cursor += 1;
            continue;
        }
        const count = markerRun(line[cursor..], '`');
        if (count == tick_run) return cursor;
        cursor += count;
    }
    return null;
}

/// Replaces literal Markdown code and escaped punctuation with spaces while
/// preserving byte positions and newlines. This is a bounded lexical shield,
/// not a renderer or MDX parser.
fn maskMarkdownLiterals(a: std.mem.Allocator, body: []const u8) !MarkdownMask {
    const masked = try a.dupe(u8, body);
    var fenced_marker: ?u8 = null;
    var fenced_len: usize = 0;
    var issue: ?[]const u8 = null;
    var line_start: usize = 0;
    while (line_start < body.len) {
        const physical = readPhysicalLine(body, line_start);
        const raw = physical.line;
        var indent: usize = 0;
        while (indent < raw.len and indent < 4 and raw[indent] == ' ') : (indent += 1) {}
        const candidate = raw[indent..];
        if (fenced_marker) |marker| {
            const fence_run = markerRun(candidate, marker);
            const trailing = if (fence_run <= candidate.len) std.mem.trim(u8, candidate[fence_run..], " \t") else "";
            @memset(masked[line_start .. line_start + raw.len], ' ');
            if (indent <= 3 and fence_run >= fenced_len and trailing.len == 0) {
                fenced_marker = null;
                fenced_len = 0;
            }
        } else {
            const marker: ?u8 = if (candidate.len > 0 and (candidate[0] == '`' or candidate[0] == '~')) candidate[0] else null;
            if (marker) |m| {
                const fence_run = markerRun(candidate, m);
                if (indent <= 3 and fence_run >= 3) {
                    fenced_marker = m;
                    fenced_len = fence_run;
                    @memset(masked[line_start .. line_start + raw.len], ' ');
                }
            }
            if (fenced_marker == null) {
                if ((raw.len >= 4 and std.mem.eql(u8, raw[0..4], "    ")) or (raw.len > 0 and raw[0] == '\t')) {
                    @memset(masked[line_start .. line_start + raw.len], ' ');
                } else {
                    var cursor: usize = 0;
                    while (cursor < raw.len) {
                        if (raw[cursor] == '\\' and cursor + 1 < raw.len) {
                            masked[line_start + cursor] = ' ';
                            masked[line_start + cursor + 1] = ' ';
                            cursor += 2;
                            continue;
                        }
                        if (raw[cursor] == '`') {
                            const tick_run = markerRun(raw[cursor..], '`');
                            const close = exactBacktickClose(raw, cursor + tick_run, tick_run) orelse {
                                @memset(masked[line_start + cursor .. line_start + raw.len], ' ');
                                issue = "ambiguous_unclosed_inline_code";
                                break;
                            };
                            @memset(masked[line_start + cursor .. line_start + close + tick_run], ' ');
                            cursor = close + tick_run;
                            continue;
                        }
                        cursor += 1;
                    }
                }
            }
        }
        if (!physical.had_newline) break;
        line_start = physical.after;
    }
    if (fenced_marker != null) issue = "ambiguous_unclosed_fence";
    return .{ .bytes = masked, .issue = issue };
}

fn withoutBlockComments(a: std.mem.Allocator, line: []const u8) !struct { bytes: []const u8, ok: bool } {
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (cursor < line.len) {
        if (cursor + 1 < line.len and line[cursor] == '/' and line[cursor + 1] == '*') {
            const end = std.mem.indexOfPos(u8, line, cursor + 2, "*/") orelse return .{ .bytes = try out.toOwnedSlice(a), .ok = false };
            try out.append(a, ' ');
            cursor = end + 2;
            continue;
        }
        try out.append(a, line[cursor]);
        cursor += 1;
    }
    return .{ .bytes = try out.toOwnedSlice(a), .ok = true };
}

fn esmReason(a: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const cleaned = try withoutBlockComments(a, line);
    defer a.free(cleaned.bytes);
    if (!cleaned.ok) return "ambiguous_executable_syntax";
    const t = std.mem.trim(u8, cleaned.bytes, " \t\r");
    if (std.mem.startsWith(u8, t, "import")) {
        const rest = t["import".len..];
        if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t' or rest[0] == '"' or rest[0] == '\'' or rest[0] == '{' or rest[0] == '*')) {
            if (std.mem.indexOf(u8, rest, " from ") != null or rest[0] == '"' or rest[0] == '\'' or rest[0] == '{' or rest[0] == '*') return "esm_import_syntax";
        }
    }
    if (std.mem.startsWith(u8, t, "export")) {
        const rest = std.mem.trim(u8, t["export".len..], " \t");
        const tokens = [_][]const u8{ "default", "const", "let", "var", "function", "class", "{", "*" };
        for (tokens) |token| if (std.mem.startsWith(u8, rest, token)) return "esm_export_syntax";
    }
    return null;
}

fn visibleHasJsx(line: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, cursor, '<')) |open| {
        if (open + 1 >= line.len) return "ambiguous_executable_syntax";
        if (line[open + 1] == '>') return "jsx_fragment";
        if (line[open + 1] == '/' and open + 2 < line.len and line[open + 2] == '>') return "jsx_fragment";
        const name_at = if (line[open + 1] == '/') open + 2 else open + 1;
        if (name_at < line.len and std.ascii.isUpper(line[name_at])) return "jsx_component";
        cursor = open + 1;
    }
    return null;
}

fn ordinaryMarkdown(a: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const mask = try maskMarkdownLiterals(a, body);
    defer a.free(mask.bytes);
    if (mask.issue) |reason| return reason;
    var lines = std.mem.splitScalar(u8, mask.bytes, '\n');
    while (lines.next()) |line| {
        if (try esmReason(a, line)) |reason| return reason;
        if (std.mem.indexOf(u8, line, "client:") != null or std.mem.indexOf(u8, line, "server:") != null or
            std.mem.indexOf(u8, line, "set:html") != null or std.mem.indexOf(u8, line, "define:vars") != null or
            std.mem.indexOf(u8, line, "is:raw") != null)
            return "framework_directive";
        if (std.mem.indexOfScalar(u8, line, '{') != null or std.mem.indexOfScalar(u8, line, '}') != null) return "mdx_expression";
        if (visibleHasJsx(line)) |reason| return reason;
    }
    return null;
}

fn classifyReference(target: []const u8) ReferenceClass {
    if (target.len == 0 or std.mem.indexOfScalar(u8, target, ' ') != null or std.mem.indexOfScalar(u8, target, '\t') != null) return .review;
    if (target[0] == '#') return .fragment;
    if (std.mem.startsWith(u8, target, "//")) return .protocol_relative;
    if (target[0] == '/') return .root_relative;
    if (std.mem.startsWith(u8, target, "http://")) return .http;
    if (std.mem.startsWith(u8, target, "https://")) return .https;
    if (std.mem.startsWith(u8, target, "mailto:")) return .mailto;
    if (std.mem.startsWith(u8, target, "ftp:")) return .ftp;
    if (std.mem.startsWith(u8, target, "data:")) return .data_url;
    const colon = std.mem.indexOfScalar(u8, target, ':');
    if (colon) |at| {
        if (at > 0 and std.ascii.isAlphabetic(target[0])) {
            for (target[1..at]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return .source_relative;
            return .other_scheme;
        }
    }
    return .source_relative;
}

fn appendReference(found: *std.ArrayList(Reference), a: std.mem.Allocator, syntax: ReferenceSyntax, classification: ReferenceClass, target: []const u8) !void {
    if (target.len == 0) return;
    for (found.items) |existing| {
        if (existing.syntax == syntax and existing.classification == classification and std.mem.eql(u8, existing.target, target)) return;
    }
    try found.append(a, .{ .syntax = syntax, .classification = classification, .target = try a.dupe(u8, target) });
}

fn findUnescaped(line: []const u8, start: usize, needle: u8) ?usize {
    var cursor = start;
    while (cursor < line.len) : (cursor += 1) {
        if (line[cursor] == needle and (cursor == 0 or line[cursor - 1] != '\\')) return cursor;
    }
    return null;
}

fn inlineDestination(line: []const u8, start: usize) struct { target: []const u8, after: usize, ok: bool } {
    var cursor = start;
    while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= line.len) return .{ .target = "", .after = line.len, .ok = false };
    if (line[cursor] == '<') {
        const end = findUnescaped(line, cursor + 1, '>') orelse return .{ .target = line[cursor..], .after = line.len, .ok = false };
        var after = end + 1;
        while (after < line.len and (line[after] == ' ' or line[after] == '\t')) : (after += 1) {}
        if (after < line.len and line[after] != ')') {
            if (line[after] != '"' and line[after] != '\'') return .{ .target = line[cursor + 1 .. end], .after = after, .ok = false };
            const quote = line[after];
            const title_end = findUnescaped(line, after + 1, quote) orelse return .{ .target = line[cursor + 1 .. end], .after = line.len, .ok = false };
            after = title_end + 1;
            while (after < line.len and (line[after] == ' ' or line[after] == '\t')) : (after += 1) {}
        }
        if (after >= line.len or line[after] != ')') return .{ .target = line[cursor + 1 .. end], .after = after, .ok = false };
        return .{ .target = line[cursor + 1 .. end], .after = after + 1, .ok = true };
    }
    const target_start = cursor;
    var depth: usize = 0;
    while (cursor < line.len) : (cursor += 1) {
        const c = line[cursor];
        if (c == '\\' and cursor + 1 < line.len) {
            cursor += 1;
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth == 0) return .{ .target = line[target_start..cursor], .after = cursor + 1, .ok = cursor > target_start };
            depth -= 1;
        }
        if ((c == ' ' or c == '\t') and depth == 0) {
            const target = line[target_start..cursor];
            while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
            if (cursor < line.len and (line[cursor] == '"' or line[cursor] == '\'')) {
                const quote = line[cursor];
                const title_end = findUnescaped(line, cursor + 1, quote) orelse return .{ .target = target, .after = line.len, .ok = false };
                cursor = title_end + 1;
                while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
                if (cursor < line.len and line[cursor] == ')') return .{ .target = target, .after = cursor + 1, .ok = target.len > 0 };
            }
            return .{ .target = target, .after = cursor, .ok = false };
        }
    }
    return .{ .target = line[target_start..], .after = line.len, .ok = false };
}

fn referenceInventory(a: std.mem.Allocator, body: []const u8) ![]const Reference {
    var found: std.ArrayList(Reference) = .empty;
    const mask = try maskMarkdownLiterals(a, body);
    defer a.free(mask.bytes);
    var line_start: usize = 0;
    while (line_start < mask.bytes.len) {
        const physical = readPhysicalLine(mask.bytes, line_start);
        const line = physical.line;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 1 and trimmed[0] == '[') {
            if (findUnescaped(trimmed, 1, ']')) |close| {
                var after = close + 1;
                while (after < trimmed.len and (trimmed[after] == ' ' or trimmed[after] == '\t')) : (after += 1) {}
                if (after < trimmed.len and trimmed[after] == ':') {
                    const destination = std.mem.trim(u8, trimmed[after + 1 ..], " \t");
                    const parsed = if (destination.len > 0 and destination[0] == '<')
                        if (findUnescaped(destination, 1, '>')) |end| destination[1..end] else destination
                    else blk: {
                        const space = std.mem.indexOfAny(u8, destination, " \t") orelse destination.len;
                        break :blk destination[0..space];
                    };
                    try appendReference(&found, a, .reference_definition, classifyReference(parsed), parsed);
                }
            }
        }

        var cursor: usize = 0;
        while (cursor < line.len) {
            if (line[cursor] == '<') {
                if (findUnescaped(line, cursor + 1, '>')) |end| {
                    const target = line[cursor + 1 .. end];
                    const class = classifyReference(target);
                    if (class != .source_relative or std.mem.indexOfScalar(u8, target, '@') != null) {
                        try appendReference(&found, a, .autolink, class, target);
                    }
                    cursor = end + 1;
                    continue;
                }
            }
            const image = line[cursor] == '!' and cursor + 1 < line.len and line[cursor + 1] == '[';
            const open = if (image) cursor + 1 else cursor;
            if (line[open] != '[') {
                cursor += 1;
                continue;
            }
            const close = findUnescaped(line, open + 1, ']') orelse {
                try appendReference(&found, a, if (image) .inline_image else .inline_link, .review, line[open..]);
                break;
            };
            const after_label = close + 1;
            if (after_label < line.len and line[after_label] == '(') {
                const destination = inlineDestination(line, after_label + 1);
                try appendReference(&found, a, if (image) .inline_image else .inline_link, if (destination.ok) classifyReference(destination.target) else .review, destination.target);
                cursor = destination.after;
                continue;
            }
            if (after_label < line.len and line[after_label] == '[') {
                const ref_close = findUnescaped(line, after_label + 1, ']') orelse {
                    try appendReference(&found, a, if (image) .reference_image_use else .reference_link_use, .review, line[open..]);
                    break;
                };
                const label = if (ref_close == after_label + 1) line[open + 1 .. close] else line[after_label + 1 .. ref_close];
                try appendReference(&found, a, if (image) .reference_image_use else .reference_link_use, .reference_label, std.mem.trim(u8, label, " \t"));
                cursor = ref_close + 1;
                continue;
            }
            cursor = close + 1;
        }
        if (!physical.had_newline) break;
        line_start = physical.after;
    }
    std.mem.sort(Reference, found.items, {}, struct {
        fn less(_: void, x: Reference, y: Reference) bool {
            const s = std.mem.order(u8, @tagName(x.syntax), @tagName(y.syntax));
            if (s != .eq) return s == .lt;
            const c = std.mem.order(u8, @tagName(x.classification), @tagName(y.classification));
            return c == .lt or (c == .eq and std.mem.order(u8, x.target, y.target) == .lt);
        }
    }.less);
    return found.toOwnedSlice(a);
}

/// Scan every entry under the selected root.  There is intentionally no
/// catch-and-continue path here: a failed iterator, stat, read, or link read
/// aborts before Publication.begin is reached, so partial evidence is never
/// published.
fn openSelectedContentRoot(io: Io, root: Io.Dir, content_root: []const u8) !Io.Dir {
    var current = root;
    var owned: ?Io.Dir = null;
    errdefer if (owned) |dir| dir.close(io);
    var components = std.mem.splitScalar(u8, content_root, '/');
    while (components.next()) |component| {
        const stat = try current.statFile(io, component, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SelectedContentRootSymlink;
        if (stat.kind != .directory) return error.InvalidSelectedContentRoot;
        const next = try current.openDir(io, component, .{ .iterate = true, .follow_symlinks = false });
        if (owned) |dir| dir.close(io);
        owned = next;
        current = next;
    }
    const result = owned orelse return error.InvalidSelectedContentRoot;
    owned = null;
    return result;
}

fn scan(io: Io, a: std.mem.Allocator, dir: Io.Dir, rel: []const u8, project: []const u8, out: *std.ArrayList(Record)) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    for (names.items) |name| {
        const path = try join(a, rel, name);
        const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
        const source_path = path;
        if (stat.kind == .directory) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "directory", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .import_id = null, .base_action = .unsupported, .action = .unsupported, .reason = "directory_inventory_only" });
            var child = try dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            try scan(io, a, child, path, project, out);
            continue;
        }
        const is_mdx = std.mem.endsWith(u8, name, ".mdx");
        const is_md = std.mem.endsWith(u8, name, ".md");
        const is_astro = std.mem.endsWith(u8, name, ".astro");
        const id: ?[]const u8 = if (stat.kind == .file) try recordId(a, project, source_path) else null;
        if (stat.kind == .sym_link) {
            var target_buf: [4096]u8 = undefined;
            const target_len = try dir.readLink(io, name, &target_buf);
            try out.append(a, .{ .source_path = source_path, .source_kind = "symlink", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .symlink_target = try a.dupe(u8, target_buf[0..target_len]), .import_id = null, .base_action = .quarantine, .action = .quarantine, .reason = "symlink_rejected" });
            continue;
        }
        if (stat.kind != .file) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "unsupported_filesystem_object", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .import_id = null, .base_action = .unsupported, .action = .unsupported, .reason = "unsupported_filesystem_object" });
            continue;
        }
        const data = try readFileAlloc(io, dir, name, a);
        const byte_hash = try sha256Hex(a, data);
        if (is_mdx) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "mdx", .byte_hash = byte_hash, .frontmatter_hash = null, .body_hash = null, .import_id = id, .generated_import_id = id, .base_action = .quarantine, .action = .quarantine, .reason = "mdx_not_parsed" });
            continue;
        }
        if (is_astro) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "astro", .byte_hash = byte_hash, .frontmatter_hash = null, .body_hash = null, .import_id = id, .generated_import_id = id, .base_action = .unsupported, .action = .unsupported, .reason = "astro_not_parsed" });
            continue;
        }
        if (!is_md) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "regular_file", .byte_hash = byte_hash, .frontmatter_hash = null, .body_hash = null, .import_id = id, .generated_import_id = id, .base_action = .unsupported, .action = .unsupported, .reason = "regular_file_not_supported" });
            continue;
        }
        const parsed = try parseFrontmatter(data, a);
        const fm_hash = try sha256Hex(a, parsed.fm);
        const body_hash = try sha256Hex(a, parsed.body);
        const syntax_reason = try ordinaryMarkdown(a, parsed.body);
        const class: RecordClass = if (!parsed.ok or syntax_reason != null) .quarantine else .create;
        try out.append(a, .{
            .source_path = source_path,
            .source_kind = "markdown",
            .byte_hash = byte_hash,
            .frontmatter_hash = fm_hash,
            .body_hash = body_hash,
            .import_id = id,
            .generated_import_id = id,
            .base_action = class,
            .action = class,
            .reason = if (!parsed.ok) parsed.reason else if (syntax_reason) |reason| reason else "supported_plain_markdown",
            .has_frontmatter = parsed.has_frontmatter,
            .frontmatter_valid = parsed.ok,
            .frontmatter = if (parsed.has_frontmatter) parsed.fm else null,
            .title = parsed.title,
            .authored_id = parsed.id,
            .status = parsed.status,
            .tags = parsed.tags,
            .links = try referenceInventory(a, parsed.body),
        });
    }
}

fn parsePrevious(a: std.mem.Allocator, bytes: []const u8, project: []const u8, policy: []const u8) ![]Previous {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidPreviousManifest;
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else return error.InvalidPreviousManifest;
    if (obj.count() != 5) return error.InvalidPreviousManifest;
    const fmt = obj.get("format") orelse return error.InvalidPreviousManifest;
    const version = obj.get("schema_version") orelse return error.InvalidPreviousManifest;
    const pid = obj.get("project_id") orelse return error.InvalidPreviousManifest;
    const p_hash = obj.get("policy_digest") orelse return error.InvalidPreviousManifest;
    if (fmt != .string or version != .integer or pid != .string or p_hash != .string or !std.mem.eql(u8, fmt.string, "boris-astro-import-manifest") or version.integer != 1 or !std.mem.eql(u8, pid.string, project) or !std.mem.eql(u8, p_hash.string, policy) or !validSha256(p_hash.string)) return error.InvalidPreviousManifest;
    const entries = obj.get("records") orelse return error.InvalidPreviousManifest;
    if (entries != .array) return error.InvalidPreviousManifest;
    var result: std.ArrayList(Previous) = .empty;
    errdefer {
        for (result.items) |prior| { a.free(prior.source_path); a.free(prior.import_id); }
        result.deinit(a);
    }
    for (entries.array.items) |entry| {
        const e = if (entry == .object) entry.object else return error.InvalidPreviousManifest;
        if (e.count() != 2) return error.InvalidPreviousManifest;
        const path = e.get("source_path") orelse return error.InvalidPreviousManifest;
        const rid = e.get("import_record_id") orelse return error.InvalidPreviousManifest;
        if (path != .string or rid != .string or !validRelative(path.string) or !validRecordId(rid.string)) return error.InvalidPreviousManifest;
        for (result.items) |prior| {
            if (std.mem.eql(u8, prior.source_path, path.string) or std.mem.eql(u8, prior.import_id, rid.string)) return error.InvalidPreviousManifest;
        }
        try result.append(a, .{ .source_path = try a.dupe(u8, path.string), .import_id = try a.dupe(u8, rid.string) });
    }
    return result.toOwnedSlice(a);
}

fn previousFor(previous: []const Previous, source_path: []const u8) ?[]const u8 {
    for (previous) |p| if (std.mem.eql(u8, p.source_path, source_path)) return p.import_id;
    return null;
}

fn className(c: RecordClass) []const u8 {
    return @tagName(c);
}

fn appendJsonOrNull(b: *std.ArrayList(u8), a: std.mem.Allocator, value: ?[]const u8) !void {
    if (value) |v| try appendJson(b, a, v) else try b.appendSlice(a, "null");
}

fn emitReferenceRecords(b: *std.ArrayList(u8), a: std.mem.Allocator, refs: []const Reference) !void {
    for (refs, 0..) |reference, i| {
        if (i != 0) try b.append(a, ',');
        try b.appendSlice(a, "{\"syntax\":");
        try appendJson(b, a, @tagName(reference.syntax));
        try b.appendSlice(a, ",\"target\":");
        try appendJson(b, a, reference.target);
        try b.appendSlice(a, ",\"classification\":");
        try appendJson(b, a, @tagName(reference.classification));
        try b.append(a, '}');
    }
}

fn emitAssetRecords(b: *std.ArrayList(u8), a: std.mem.Allocator, refs: []const Reference) !void {
    var first = true;
    for (refs) |reference| {
        if (reference.syntax != .inline_image and reference.syntax != .reference_image_use) continue;
        if (!first) try b.append(a, ',');
        first = false;
        try b.appendSlice(a, "{\"source_syntax\":");
        try appendJson(b, a, @tagName(reference.syntax));
        try b.appendSlice(a, ",\"target\":");
        try appendJson(b, a, reference.target);
        try b.appendSlice(a, ",\"classification\":");
        try appendJson(b, a, @tagName(reference.classification));
        try b.append(a, '}');
    }
}

fn emitSnapshot(a: std.mem.Allocator, project: []const u8, content_root: []const u8, policy: []const u8, tree: []const u8, records: []const Record) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\"format\":");
    try appendJson(&b, a, snapshot_format);
    try b.appendSlice(a, ",\"schema_version\":1,\"tool_version\":");
    try appendJson(&b, a, tool_version);
    try b.appendSlice(a, ",\"source_system\":\"astro\",\"project_id\":");
    try appendJson(&b, a, project);
    try b.appendSlice(a, ",\"selected_content_root\":");
    try appendJson(&b, a, content_root);
    try b.appendSlice(a, ",\"policy_hash\":");
    try appendJson(&b, a, policy);
    try b.appendSlice(a, ",\"source_tree_fingerprint\":");
    try appendJson(&b, a, tree);
    try b.appendSlice(a, ",\"records\":[");
    for (records, 0..) |r, i| {
        if (i != 0) try b.append(a, ',');
        try b.appendSlice(a, "{\"source_path\":");
        try appendJson(&b, a, r.source_path);
        try b.appendSlice(a, ",\"source_kind\":");
        try appendJson(&b, a, r.source_kind);
        try b.appendSlice(a, ",\"exact_byte_hash\":");
        try appendJsonOrNull(&b, a, r.byte_hash);
        try b.appendSlice(a, ",\"frontmatter_hash\":");
        try appendJsonOrNull(&b, a, r.frontmatter_hash);
        try b.appendSlice(a, ",\"body_hash\":");
        try appendJsonOrNull(&b, a, r.body_hash);
        try b.appendSlice(a, ",\"symlink_target\":");
        try appendJsonOrNull(&b, a, r.symlink_target);
        try b.appendSlice(a, ",\"source_authored_identity\":");
        if (r.authored_id) |v| try appendJson(&b, a, v) else try b.appendSlice(a, "null");
        try b.appendSlice(a, ",\"inferred_route_candidate\":");
        try appendJsonOrNull(&b, a, r.inferred_route_candidate);
        try b.appendSlice(a, ",\"route_evidence\":\"inferred_not_observed\",\"references\":[");
        try emitReferenceRecords(&b, a, r.links);
        try b.appendSlice(a, "],\"potential_asset_references\":[");
        try emitAssetRecords(&b, a, r.links);
        try b.appendSlice(a, "],\"classification\":");
        try appendJson(&b, a, className(r.action));
        try b.appendSlice(a, ",\"evidence\":");
        try appendJson(&b, a, r.reason);
        try b.append(a, '}');
    }
    try b.appendSlice(a, "]}");
    return b.toOwnedSlice(a);
}

fn emitProposedFrontmatter(b: *std.ArrayList(u8), a: std.mem.Allocator, r: Record) !void {
    try b.append(a, '{');
    if (r.frontmatter_valid) {
        var first = true;
        if (r.authored_id) |id| {
            try b.appendSlice(a, "\"id\":");
            try appendJson(b, a, id);
            first = false;
        }
        if (r.title) |title| {
            if (!first) try b.append(a, ',');
            try b.appendSlice(a, "\"title\":");
            try appendJson(b, a, title);
            first = false;
        }
        if (r.status) |status| {
            if (!first) try b.append(a, ',');
            try b.appendSlice(a, "\"status\":");
            try appendJson(b, a, status);
            first = false;
        }
        if (r.has_frontmatter and r.tags.len > 0) {
            if (!first) try b.append(a, ',');
            try b.appendSlice(a, "\"tags\":[");
            for (r.tags, 0..) |tag, i| {
                if (i != 0) try b.append(a, ',');
                try appendJson(b, a, tag);
            }
            try b.append(a, ']');
        } else if (r.has_frontmatter and r.tags.len == 0) {
            if (r.frontmatter) |fm| {
                if (frontmatterContainsKey(fm, "tags")) {
                    if (!first) try b.append(a, ',');
                    try b.appendSlice(a, "\"tags\":[]");
                }
            }
        }
    }
    try b.append(a, '}');
}

fn frontmatterContainsKey(fm: []const u8, wanted: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < fm.len) {
        const physical = readPhysicalLine(fm, line_start);
        if (std.mem.indexOfScalar(u8, physical.line, ':')) |colon| {
            const key = std.mem.trim(u8, physical.line[0..colon], " \t");
            if (std.mem.eql(u8, key, wanted)) return true;
        }
        if (!physical.had_newline) break;
        line_start = physical.after;
    }
    return false;
}

fn emitPlan(a: std.mem.Allocator, snapshot_digest: []const u8, policy: []const u8, previous_digest: ?[]const u8, records: []const Record, findings: []const Finding) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    try payload.appendSlice(a, "{\"format\":\"boris-astro-import-plan\",\"schema_version\":1,\"canonical_json\":\"UTF-8, compact, fixed emitted key order, sorted source-path arrays\",\"digest_algorithm\":\"sha256-lowercase-hex\",\"source_snapshot_digest\":");
    try appendJson(&payload, a, snapshot_digest);
    try payload.appendSlice(a, ",\"importer_policy_digest\":");
    try appendJson(&payload, a, policy);
    try payload.appendSlice(a, ",\"previous_manifest_digest\":");
    if (previous_digest) |d| try appendJson(&payload, a, d) else try payload.appendSlice(a, "null");
    try payload.appendSlice(a, ",\"proposed_actions\":[");
    for (records, 0..) |r, i| {
        if (i != 0) try payload.append(a, ',');
        try payload.appendSlice(a, "{\"class\":");
        try appendJson(&payload, a, className(r.action));
        try payload.appendSlice(a, ",\"import_record_id\":");
        try appendJsonOrNull(&payload, a, r.import_id);
        try payload.appendSlice(a, ",\"source_path\":");
        try appendJson(&payload, a, r.source_path);
        try payload.appendSlice(a, ",\"source_hash\":");
        try appendJsonOrNull(&payload, a, r.byte_hash);
        try payload.appendSlice(a, ",\"proposed_boris_source_path\":");
        try appendJsonOrNull(&payload, a, if (r.proposal_valid) r.proposed_boris_source_path else null);
        try payload.appendSlice(a, ",\"proposed_entity_id\":");
        try appendJsonOrNull(&payload, a, if (r.proposal_valid) r.proposed_entity_id else null);
        try payload.appendSlice(a, ",\"authored_frontmatter_evidence\":");
        try appendJsonOrNull(&payload, a, r.frontmatter);
        try payload.appendSlice(a, ",\"proposed_closed_frontmatter\":");
        try emitProposedFrontmatter(&payload, a, r);
        try payload.appendSlice(a, ",\"inferred_source_route_candidate\":");
        try appendJsonOrNull(&payload, a, if (r.proposal_valid) r.inferred_route_candidate else null);
        try payload.appendSlice(a, ",\"proposed_boris_route\":");
        try appendJsonOrNull(&payload, a, if (r.proposal_valid) r.proposed_boris_route else null);
        try payload.appendSlice(a, ",\"route_compatibility\":\"inferred_not_observed\",\"preconditions\":[");
        if (r.action == .create or r.action == .keep) {
            try payload.appendSlice(a, "\"source hash remains unchanged\",\"future apply owns destination\"");
        }
        try payload.appendSlice(a, "],\"loss_classification\":");
        try appendJson(&payload, a, if (r.action == .create or r.action == .keep) "review_required_not_applied" else "not_convertible");
        try payload.appendSlice(a, ",\"reason\":");
        try appendJson(&payload, a, r.reason);
        try payload.append(a, '}');
    }
    try payload.appendSlice(a, "],\"findings\":[");
    for (findings, 0..) |finding, i| {
        if (i != 0) try payload.append(a, ',');
        try payload.appendSlice(a, "{\"class\":");
        try appendJson(&payload, a, className(finding.class));
        try payload.appendSlice(a, ",\"reason\":");
        try appendJson(&payload, a, finding.reason);
        try payload.appendSlice(a, ",\"source_paths\":[");
        for (finding.source_paths, 0..) |path, path_i| {
            if (path_i != 0) try payload.append(a, ',');
            try appendJson(&payload, a, path);
        }
        try payload.appendSlice(a, "]}");
    }
    try payload.appendSlice(a, "]}");
    const digest = try sha256Hex(a, payload.items);
    defer a.free(digest);
    var final: std.ArrayList(u8) = .empty;
    try final.appendSlice(a, "{\"plan_digest\":");
    try appendJson(&final, a, digest);
    try final.appendSlice(a, ",\"digest_input\":");
    try final.appendSlice(a, payload.items);
    try final.append(a, '}');
    return final.toOwnedSlice(a);
}

fn emitReport(a: std.mem.Allocator, records: []const Record, findings: []const Finding) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "# Astro import plan\n\nThis is a developer-only, plan-only report. It does not apply an import, modify sources, copy assets, execute Astro/Node/MDX, or observe routes. Complete machine-readable evidence is in `source_snapshot.json` and `import_plan.json`.\n\n## Aggregate counts\n\n");
    const total_line = try std.fmt.allocPrint(a, "- `records`: {d}\n", .{records.len});
    try b.appendSlice(a, total_line);
    for (std.enums.values(RecordClass)) |class| {
        var count: usize = 0;
        for (records) |record| {
            if (record.action == class) count += 1;
        }
        const line = try std.fmt.allocPrint(a, "- `{s}`: {d}\n", .{ className(class), count });
        defer a.free(line);
        try b.appendSlice(a, line);
    }
    try b.appendSlice(a, "\n## Reason counts\n\n");
    var reason_rows: std.ArrayList(struct { reason: []const u8, count: usize }) = .empty;
    for (records) |record| {
        var found = false;
        for (reason_rows.items) |*row| {
            if (std.mem.eql(u8, row.reason, record.reason)) {
                row.count += 1;
                found = true;
                break;
            }
        }
        if (!found) try reason_rows.append(a, .{ .reason = record.reason, .count = 1 });
    }
    std.mem.sort(@TypeOf(reason_rows.items[0]), reason_rows.items, {}, struct {
        fn less(_: void, left: @TypeOf(reason_rows.items[0]), right: @TypeOf(reason_rows.items[0])) bool {
            return std.mem.order(u8, left.reason, right.reason) == .lt;
        }
    }.less);
    for (reason_rows.items) |row| {
        const line = try std.fmt.allocPrint(a, "- `{s}`: {d}\n", .{ row.reason, row.count });
        try b.appendSlice(a, line);
    }
    try b.appendSlice(a, "\n## Collision counts\n\n");
    if (findings.len == 0) {
        try b.appendSlice(a, "- none\n");
    } else {
        for (findings) |finding| {
            const line = try std.fmt.allocPrint(a, "- `{s}`: {d} involved records\n", .{ finding.reason, finding.source_paths.len });
            try b.appendSlice(a, line);
        }
    }
    try b.appendSlice(a, "\n## Reference counts by class\n\n");
    for (std.enums.values(ReferenceClass)) |class| {
        var count: usize = 0;
        for (records) |record| for (record.links) |reference| {
            if (reference.classification == class) count += 1;
        };
        const line = try std.fmt.allocPrint(a, "- `{s}`: {d}\n", .{ @tagName(class), count });
        try b.appendSlice(a, line);
    }
    try b.appendSlice(a, "\n## Representative rows (first 100 sorted entries)\n\n| Source | Action | Evidence |\n|---|---|---|\n");
    for (records[0..@min(records.len, 100)]) |r| {
        const row = try std.fmt.allocPrint(a, "| `{s}` | `{s}` | {s} |\n", .{ r.source_path, className(r.action), r.reason });
        defer a.free(row);
        try b.appendSlice(a, row);
    }
    return b.toOwnedSlice(a);
}

/// Versioned, delimiter-safe canonical stream for the complete selected tree:
/// `boris-astro-source-tree-v1\n`, then sorted entries as
/// `path:<decimal byte length>:<raw path>\nkind:<decimal byte length>:<raw kind>\nsha256:<hash-or-null>\nsymlink_target:<decimal length>:<raw target>|null\n`.
/// Regular files always carry their exact SHA-256; directories and special
/// objects have null hashes; symlinks carry their un-followed link target.
fn sourceTreeFingerprint(a: std.mem.Allocator, records: []const Record) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a, "boris-astro-source-tree-v1\n");
    for (records) |r| {
        const header = try std.fmt.allocPrint(a, "path:{d}:{s}\nkind:{d}:{s}\nsha256:", .{ r.source_path.len, r.source_path, r.source_kind.len, r.source_kind });
        defer a.free(header);
        try input.appendSlice(a, header);
        if (r.byte_hash) |hash| try input.appendSlice(a, hash) else try input.appendSlice(a, "null");
        try input.appendSlice(a, "\nsymlink_target:");
        if (r.symlink_target) |target| {
            const link = try std.fmt.allocPrint(a, "{d}:{s}\n", .{ target.len, target });
            defer a.free(link);
            try input.appendSlice(a, link);
        } else try input.appendSlice(a, "null\n");
    }
    return sha256Hex(a, input.items);
}

fn sortRecords(records: []Record) void {
    std.mem.sort(Record, records, {}, struct {
        fn less(_: void, x: Record, y: Record) bool { return std.mem.order(u8, x.source_path, y.source_path) == .lt; }
    }.less);
}

fn computeProposal(a: std.mem.Allocator, record: *Record) !void {
    if (!std.mem.eql(u8, record.source_kind, "markdown") or !record.frontmatter_valid) return;
    if (!validRelative(record.source_path) or !std.unicode.utf8ValidateSlice(record.source_path)) {
        if (record.action == .create or record.action == .keep) record.action = .quarantine;
        record.reason = "invalid_normalized_source_path";
        return;
    }
    if (!std.mem.endsWith(u8, record.source_path, ".md")) {
        if (record.action == .create or record.action == .keep) record.action = .quarantine;
        record.reason = "invalid_markdown_extension";
        return;
    }
    const stem = record.source_path[0 .. record.source_path.len - 3];
    if (stem.len == 0) {
        if (record.action == .create or record.action == .keep) record.action = .unsupported;
        record.reason = "invalid_source_filename_empty_stem";
        return;
    }
    const entity = record.authored_id orelse stem;
    const proposed_source = try std.fmt.allocPrint(a, "content/{s}", .{record.source_path});
    if (!validRelative(proposed_source) or !validEntityId(entity) or !validRoute(stem) or !validRecordId(record.import_id orelse "")) {
        if (record.action == .create or record.action == .keep) record.action = .quarantine;
        record.reason = if (!validEntityId(entity)) "invalid_proposed_entity_id" else if (!validRoute(stem)) "invalid_inferred_route_candidate" else if (!validRelative(proposed_source)) "invalid_proposed_boris_source_path" else "invalid_import_record_id";
        return;
    }
    record.proposed_boris_source_path = proposed_source;
    record.proposed_entity_id = entity;
    record.inferred_route_candidate = stem;
    record.proposed_boris_route = stem;
    record.proposal_valid = true;
}

const CollisionKey = enum {
    normalized_source_path,
    source_authored_id,
    generated_import_id,
    final_import_id,
    proposed_entity_id,
    proposed_boris_source_path,
    inferred_route_candidate,
    proposed_boris_route,
};

fn collisionValue(record: Record, key: CollisionKey) ?[]const u8 {
    return switch (key) {
        .normalized_source_path => record.source_path,
        .source_authored_id => record.authored_id,
        .generated_import_id => record.generated_import_id,
        .final_import_id => record.import_id,
        .proposed_entity_id => if (record.proposal_valid) record.proposed_entity_id else null,
        .proposed_boris_source_path => if (record.proposal_valid) record.proposed_boris_source_path else null,
        .inferred_route_candidate => if (record.proposal_valid) record.inferred_route_candidate else null,
        .proposed_boris_route => if (record.proposal_valid) record.proposed_boris_route else null,
    };
}

fn collisionReason(key: CollisionKey) []const u8 {
    return switch (key) {
        .normalized_source_path => "duplicate_normalized_source_path",
        .source_authored_id => "duplicate_source_authored_id",
        .generated_import_id => "duplicate_generated_import_record_id",
        .final_import_id => "duplicate_final_import_record_id",
        .proposed_entity_id => "duplicate_proposed_entity_id",
        .proposed_boris_source_path => "duplicate_proposed_boris_source_path",
        .inferred_route_candidate => "duplicate_inferred_route_candidate",
        .proposed_boris_route => "duplicate_proposed_boris_route",
    };
}

fn collisionEqual(key: CollisionKey, left: []const u8, right: []const u8) bool {
    return if (key == .normalized_source_path) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
}

fn appendCollisionFindings(a: std.mem.Allocator, records: []Record, key: CollisionKey, findings: *std.ArrayList(Finding)) !void {
    for (records, 0..) |*left, i| {
        const value = collisionValue(left.*, key) orelse continue;
        var already_grouped = false;
        for (records[0..i]) |prior| {
            if (collisionValue(prior, key)) |prior_value| {
                if (collisionEqual(key, value, prior_value)) {
                    already_grouped = true;
                    break;
                }
            }
        }
        if (already_grouped) continue;
        var paths: std.ArrayList([]const u8) = .empty;
        for (records) |*candidate| {
            const other = collisionValue(candidate.*, key) orelse continue;
            if (!collisionEqual(key, value, other)) continue;
            try paths.append(a, candidate.source_path);
        }
        if (paths.items.len < 2) continue;
        const reason = collisionReason(key);
        for (records) |*candidate| {
            const other = collisionValue(candidate.*, key) orelse continue;
            if (!collisionEqual(key, value, other)) continue;
            if (candidate.action != .conflict) candidate.reason = reason;
            candidate.action = .conflict;
        }
        try findings.append(a, .{ .class = .conflict, .reason = reason, .source_paths = try paths.toOwnedSlice(a) });
    }
}

fn finalizeRecords(a: std.mem.Allocator, records: []Record, previous: []const Previous) ![]const Finding {
    for (records) |*record| {
        record.action = record.base_action;
        if (previousFor(previous, record.source_path)) |restored| {
            if (record.import_id != null) {
                record.import_id = restored;
                if (record.action == .create) record.action = .keep;
            }
        }
        try computeProposal(a, record);
        if ((record.action == .create or record.action == .keep) and
            (!record.proposal_valid or record.byte_hash == null or !validSha256(record.byte_hash.?)))
        {
            record.action = .quarantine;
            record.reason = "invalid_required_proposal_field";
        }
    }

    var findings: std.ArrayList(Finding) = .empty;
    const keys = [_]CollisionKey{
        .normalized_source_path,
        .source_authored_id,
        .generated_import_id,
        .final_import_id,
        .proposed_entity_id,
        .proposed_boris_source_path,
        .inferred_route_candidate,
        .proposed_boris_route,
    };
    for (keys) |key| try appendCollisionFindings(a, records, key, &findings);
    return findings.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    if (!validProjectId(opts.project_id) or !validRelative(opts.content_root)) return error.InvalidImportPlanInput;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const policy = try sha256Hex(a, policy_bytes);
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.append(a, opts.root_dir);
    if (opts.previous_manifest) |p| try inputs.append(a, p);
    try publication.validateRoots(io, a, opts.out_dir, inputs.items);
    var previous: []Previous = &.{};
    var previous_digest: ?[]const u8 = null;
    if (opts.previous_manifest) |p| {
        const bytes = try readFileAlloc(io, Io.Dir.cwd(), p, a);
        previous_digest = try sha256Hex(a, bytes);
        previous = try parsePrevious(a, bytes, opts.project_id, policy);
    }
    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    var content = try openSelectedContentRoot(io, root, opts.content_root);
    defer content.close(io);
    var records: std.ArrayList(Record) = .empty;
    try scan(io, a, content, "", opts.project_id, &records);
    sortRecords(records.items);
    const findings = try finalizeRecords(a, records.items, previous);
    const tree = try sourceTreeFingerprint(a, records.items);
    const snapshot = try emitSnapshot(a, opts.project_id, opts.content_root, policy, tree, records.items);
    const snapshot_digest = try sha256Hex(a, snapshot);
    const plan = try emitPlan(a, snapshot_digest, policy, previous_digest, records.items, findings);
    const report = try emitReport(a, records.items, findings);
    var output_publication = try publication.Publication.begin(io, a, opts.out_dir, inputs.items, format_id);
    defer {
        output_publication.abandon(io, a);
        output_publication.deinit(a);
    }
    var stage = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    defer stage.close(io);
    try write(io, stage, "source_snapshot.json", snapshot);
    try write(io, stage, "import_plan.json", plan);
    try write(io, stage, "REPORT.md", report);
    try output_publication.commit(io, a);
    if (!opts.quiet) std.debug.print("migration-lab: wrote {s}/source_snapshot.json, import_plan.json, REPORT.md\n", .{opts.out_dir});
}

test "record ids and policy hashes are deterministic" {
    const a = std.testing.allocator;
    const one = try recordId(a, "fixture", "docs/a.md");
    defer a.free(one);
    const two = try recordId(a, "fixture", "docs/a.md");
    defer a.free(two);
    try std.testing.expectEqualStrings(one, two);
    const hash = try sha256Hex(a, policy_bytes);
    defer a.free(hash);
    try std.testing.expectEqual(@as(usize, 64), hash.len);
}

test "plain markdown syntax ignores fenced and inline code but quarantines executable syntax" {
    const a = std.testing.allocator;
    try std.testing.expect(try ordinaryMarkdown(a, "````json\n{\"x\": 1}\n<Component />\n````\nInline ``<Widget /> {json}`` and \\{name\\}.") == null);
    try std.testing.expectEqualStrings("esm_import_syntax", (try ordinaryMarkdown(a, "import/**/Widget from './widget';")).?);
    try std.testing.expectEqualStrings("mdx_expression", (try ordinaryMarkdown(a, "Hello {name}.")).?);
    try std.testing.expectEqualStrings("framework_directive", (try ordinaryMarkdown(a, "<Card client:load />")).?);
    try std.testing.expect(try ordinaryMarkdown(a, "<span>ordinary HTML</span>") == null);
}

test "reference inventory keeps links separate from images and classifications" {
    const refs = try referenceInventory(std.testing.allocator, "[Guide](../guide.md) ![Logo](/logo.svg) [Remote](https://example.test) [Part](#part) [Data](data:image/png;base64,x)");
    defer {
        for (refs) |reference| std.testing.allocator.free(reference.target);
        std.testing.allocator.free(refs);
    }
    var links: usize = 0;
    var images: usize = 0;
    var relative: usize = 0;
    for (refs) |reference| {
        if (reference.syntax == .inline_link) links += 1;
        if (reference.syntax == .inline_image) images += 1;
        if (reference.classification == .source_relative) relative += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), links);
    try std.testing.expectEqual(@as(usize, 1), images);
    try std.testing.expectEqual(@as(usize, 1), relative);
}

test "tree fingerprint covers hidden paths, kinds, targets, and hashes" {
    const records = [_]Record{
        .{ .source_path = ".hidden", .source_kind = "regular_file", .byte_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .frontmatter_hash = null, .body_hash = null, .import_id = null, .base_action = .unsupported, .action = .unsupported, .reason = "test" },
        .{ .source_path = "link", .source_kind = "symlink", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .symlink_target = "../target", .import_id = null, .base_action = .quarantine, .action = .quarantine, .reason = "test" },
    };
    const got = try sourceTreeFingerprint(std.testing.allocator, &records);
    defer std.testing.allocator.free(got);
    // Deliberate independent reconstruction of the documented stream.
    const stream = "boris-astro-source-tree-v1\npath:7:.hidden\nkind:12:regular_file\nsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nsymlink_target:null\npath:4:link\nkind:7:symlink\nsha256:null\nsymlink_target:9:../target\n";
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(stream, &raw, .{});
    var expected: [64]u8 = undefined;
    const chars = "0123456789abcdef";
    for (raw, 0..) |byte, i| { expected[i * 2] = chars[byte >> 4]; expected[i * 2 + 1] = chars[byte & 15]; }
    try std.testing.expectEqualStrings(&expected, got);
    const changed = [_]Record{records[0], .{ .source_path = "link", .source_kind = "symlink", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .symlink_target = "../other", .import_id = null, .base_action = .quarantine, .action = .quarantine, .reason = "test" }};
    const tampered = try sourceTreeFingerprint(std.testing.allocator, &changed);
    defer std.testing.allocator.free(tampered);
    try std.testing.expect(!std.mem.eql(u8, got, tampered));
}

test "previous manifests reject malformed ids duplicate paths ids and unknown shapes" {
    const a = std.testing.allocator;
    const policy = try sha256Hex(a, policy_bytes);
    defer a.free(policy);
    const good_id = "air_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const cases = [_][]const u8{
        "{\"format\":\"boris-astro-import-manifest\",\"schema_version\":1,\"project_id\":\"p\",\"policy_digest\":\"bad\",\"records\":[]}",
        "{\"format\":\"boris-astro-import-manifest\",\"schema_version\":1,\"project_id\":\"p\",\"policy_digest\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"records\":[{\"source_path\":\"a.md\",\"import_record_id\":\"air_bad\"}]}",
        "{\"format\":\"boris-astro-import-manifest\",\"schema_version\":1,\"project_id\":\"p\",\"policy_digest\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"records\":[],\"extra\":true}",
    };
    for (cases) |bytes| try std.testing.expectError(error.InvalidPreviousManifest, parsePrevious(a, bytes, "p", policy));
    const duplicate = try std.fmt.allocPrint(a, "{{\"format\":\"boris-astro-import-manifest\",\"schema_version\":1,\"project_id\":\"p\",\"policy_digest\":\"{s}\",\"records\":[{{\"source_path\":\"a.md\",\"import_record_id\":\"{s}\"}},{{\"source_path\":\"a.md\",\"import_record_id\":\"{s}\"}}]}}", .{ policy, good_id, good_id });
    defer a.free(duplicate);
    try std.testing.expectError(error.InvalidPreviousManifest, parsePrevious(a, duplicate, "p", policy));
}

test "collision planning produces conflict rather than choosing a record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var records = [_]Record{
        .{ .source_path = "a.md", .source_kind = "markdown", .byte_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .frontmatter_hash = null, .body_hash = null, .import_id = "air_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .generated_import_id = "air_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .base_action = .create, .action = .create, .reason = "ok", .authored_id = "shared" },
        .{ .source_path = "b.md", .source_kind = "markdown", .byte_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .frontmatter_hash = null, .body_hash = null, .import_id = "air_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .generated_import_id = "air_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .base_action = .create, .action = .create, .reason = "ok", .authored_id = "shared" },
    };
    _ = try finalizeRecords(a, &records, &.{});
    try std.testing.expectEqual(RecordClass.conflict, records[0].action);
    try std.testing.expectEqual(RecordClass.conflict, records[1].action);
}

test "emitted snapshot and plan are structurally valid compact JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var records = [_]Record{.{ .source_path = "page.md", .source_kind = "markdown", .byte_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .frontmatter_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .body_hash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .import_id = "air_dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .generated_import_id = "air_dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .base_action = .create, .action = .create, .reason = "supported_plain_markdown" }};
    const findings = try finalizeRecords(a, &records, &.{});
    const snapshot = try emitSnapshot(a, "p", "content", "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", &records);
    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
    defer parsed_snapshot.deinit();
    const digest = try sha256Hex(a, snapshot);
    const plan = try emitPlan(a, digest, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", null, &records, findings);
    var parsed_plan = try std.json.parseFromSlice(std.json.Value, a, plan, .{});
    defer parsed_plan.deinit();
}

test "scan inventories hidden and unsupported regular files rather than skipping them" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scan_a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-plan-scan", .{tmp.sub_path});
    defer a.free(root_path);
    const content_path = try std.fmt.allocPrint(a, "{s}/content", .{root_path});
    defer a.free(content_path);
    try Io.Dir.cwd().createDirPath(io, content_path);
    const hidden = try std.fmt.allocPrint(a, "{s}/.hidden.txt", .{content_path});
    defer a.free(hidden);
    const normal = try std.fmt.allocPrint(a, "{s}/normal.md", .{content_path});
    defer a.free(normal);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = hidden, .data = "private but inventoried\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = normal, .data = "# Normal\n" });
    var root = try Io.Dir.cwd().openDir(io, content_path, .{ .iterate = true });
    defer root.close(io);
    var records: std.ArrayList(Record) = .empty;
    try scan(io, scan_a, root, "", "fixture", &records);
    var found_hidden = false;
    for (records.items) |record| {
        if (std.mem.eql(u8, record.source_path, ".hidden.txt")) {
            found_hidden = true;
            try std.testing.expectEqualStrings("regular_file", record.source_kind);
            try std.testing.expect(record.byte_hash != null);
            try std.testing.expectEqual(RecordClass.unsupported, record.action);
        }
    }
    try std.testing.expect(found_hidden);
}

const TestArtifacts = struct {
    snapshot: []const u8,
    plan: []const u8,
    report: []const u8,
};

fn runSingleSourcePlan(a: std.mem.Allocator, source_name: []const u8, source: []const u8) !TestArtifacts {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-plan-public", .{tmp.sub_path});
    const root_path = try std.fmt.allocPrint(a, "{s}/root", .{base});
    const content_path = try std.fmt.allocPrint(a, "{s}/content", .{root_path});
    const source_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ content_path, source_name });
    const out_path = try std.fmt.allocPrint(a, "{s}/out", .{base});
    try Io.Dir.cwd().createDirPath(io, content_path);
    try ensureParent(io, Io.Dir.cwd(), source_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = source });
    const options: RunOptions = .{
        .root_dir = root_path,
        .content_root = "content",
        .out_dir = out_path,
        .project_id = "public-test",
        .quiet = true,
    };
    try run(io, a, options);
    const first_snapshot = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/source_snapshot.json", .{out_path}), a);
    const first_plan = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a);
    const first_report = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/REPORT.md", .{out_path}), a);
    try run(io, a, options);
    const second_snapshot = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/source_snapshot.json", .{out_path}), a);
    const second_plan = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a);
    const second_report = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/REPORT.md", .{out_path}), a);
    try std.testing.expectEqualStrings(first_snapshot, second_snapshot);
    try std.testing.expectEqualStrings(first_plan, second_plan);
    try std.testing.expectEqualStrings(first_report, second_report);
    return .{ .snapshot = first_snapshot, .plan = first_plan, .report = first_report };
}

fn expectFirstAction(a: std.mem.Allocator, plan: []const u8, expected_class: []const u8, expected_reason: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, plan, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("digest_input").?.object;
    const action = input.get("proposed_actions").?.array.items[0].object;
    try std.testing.expectEqualStrings(expected_class, action.get("class").?.string);
    try std.testing.expectEqualStrings(expected_reason, action.get("reason").?.string);
}

fn expectSourceAction(a: std.mem.Allocator, plan: []const u8, source_path: []const u8, expected_class: []const u8, expected_reason: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, plan, .{});
    defer parsed.deinit();
    const actions = parsed.value.object.get("digest_input").?.object.get("proposed_actions").?.array.items;
    for (actions) |action_value| {
        const action = action_value.object;
        if (!std.mem.eql(u8, action.get("source_path").?.string, source_path)) continue;
        try std.testing.expectEqualStrings(expected_class, action.get("class").?.string);
        try std.testing.expectEqualStrings(expected_reason, action.get("reason").?.string);
        return;
    }
    return error.ExpectedSourceActionMissing;
}

test "public planning path classifies executable syntax conservatively and preserves literal examples" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        class: []const u8,
        reason: []const u8,
    }{
        .{ .name = "import.md", .source = "import/**/Widget from \"./Widget.astro\";\n", .class = "quarantine", .reason = "esm_import_syntax" },
        .{ .name = "export.md", .source = "export const answer = 42;\n", .class = "quarantine", .reason = "esm_export_syntax" },
        .{ .name = "expression.md", .source = "{ dangerousCall() }\n", .class = "quarantine", .reason = "mdx_expression" },
        .{ .name = "json-expression.md", .source = "{\"danger\"}\n", .class = "quarantine", .reason = "mdx_expression" },
        .{ .name = "component.md", .source = "<Widget />\n", .class = "quarantine", .reason = "jsx_component" },
        .{ .name = "fragment.md", .source = "<>hello</>\n", .class = "quarantine", .reason = "jsx_fragment" },
        .{ .name = "directive.md", .source = "<Card client:load />\n", .class = "quarantine", .reason = "framework_directive" },
        .{ .name = "unclosed.md", .source = "~~~~astro\n<Component />\n", .class = "quarantine", .reason = "ambiguous_unclosed_fence" },
        .{ .name = "fenced.md", .source = "````jsx\n<Component />\n{\"x\": 1}\n````\n", .class = "create", .reason = "supported_plain_markdown" },
        .{ .name = "tilde.md", .source = "~~~astro\nimport Widget from './Widget.astro';\n~~~\n", .class = "create", .reason = "supported_plain_markdown" },
        .{ .name = "inline.md", .source = "Use ``{name} <Widget /> import X from 'x'`` as an example.\n", .class = "create", .reason = "supported_plain_markdown" },
        .{ .name = "escaped.md", .source = "Literal \\{name\\} and words import or export in prose.\n", .class = "create", .reason = "supported_plain_markdown" },
        .{ .name = "indented.md", .source = "    {\"set\": \"notation\"}\n\nOrdinary prose.\n", .class = "create", .reason = "supported_plain_markdown" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const artifacts = try runSingleSourcePlan(a, case.name, case.source);
        try expectFirstAction(a, artifacts.plan, case.class, case.reason);
    }
}

test "public planning path implements the bounded frontmatter grammar" {
    const invalid = [_]struct { source: []const u8, reason: []const u8 }{
        .{ .source = "---\nid: one\nid: two\n---\n", .reason = "duplicate_frontmatter_id" },
        .{ .source = "---\ntitle: one\ntitle: two\n---\n", .reason = "duplicate_frontmatter_title" },
        .{ .source = "---\nstatus: draft\nstatus: published\n---\n", .reason = "duplicate_frontmatter_status" },
        .{ .source = "---\ntags: [one]\ntags: [two]\n---\n", .reason = "duplicate_frontmatter_tags" },
        .{ .source = "---\ntitle: 'single'\n---\n", .reason = "single_quoted_frontmatter_value" },
        .{ .source = "---\ntitle: \"broken\n---\n", .reason = "malformed_double_quoted_frontmatter_value" },
        .{ .source = "---\nstatus: public\n---\n", .reason = "invalid_frontmatter_status" },
        .{ .source = "---\ntags: [one,,two]\n---\n", .reason = "malformed_frontmatter_tags" },
        .{ .source = "---\n  nested: value\n---\n", .reason = "nested_or_sequence_frontmatter" },
        .{ .source = "---\ntitle: |\n  many\n---\n", .reason = "multiline_frontmatter_value" },
        .{ .source = "---\nsidebar: hidden\n---\n", .reason = "unsupported_frontmatter_key" },
        .{ .source = "---\n# comment-looking lines are not syntax\n---\n", .reason = "malformed_frontmatter_line" },
        .{ .source = "---\n: value\n---\n", .reason = "empty_frontmatter_key" },
        .{ .source = "---\ntitle:\n---\n", .reason = "empty_frontmatter_value" },
    };
    for (invalid, 0..) |case, i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const name = try std.fmt.allocPrint(a, "invalid-{d}.md", .{i});
        const artifacts = try runSingleSourcePlan(a, name, case.source);
        try expectFirstAction(a, artifacts.plan, "quarantine", case.reason);
        var snapshot = try std.json.parseFromSlice(std.json.Value, a, artifacts.snapshot, .{});
        defer snapshot.deinit();
        const record = snapshot.value.object.get("records").?.array.items[0].object;
        try std.testing.expect(record.get("exact_byte_hash").? == .string);
        try std.testing.expect(record.get("frontmatter_hash").? == .string);
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid =
        "---\n" ++
        "id: guides/intro\n" ++
        "title: \"Quoted # title\"\n" ++
        "status: published\n" ++
        "tags: [guide, \"intro\"]\n" ++
        "---\n\n# Intro\n";
    const artifacts = try runSingleSourcePlan(a, "valid.md", valid);
    try expectFirstAction(a, artifacts.plan, "create", "supported_plain_markdown");
    var plan = try std.json.parseFromSlice(std.json.Value, a, artifacts.plan, .{});
    defer plan.deinit();
    const action = plan.value.object.get("digest_input").?.object.get("proposed_actions").?.array.items[0].object;
    const fm = action.get("proposed_closed_frontmatter").?.object;
    try std.testing.expectEqualStrings("guides/intro", fm.get("id").?.string);
    try std.testing.expectEqualStrings("Quoted # title", fm.get("title").?.string);
    try std.testing.expectEqualStrings("published", fm.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 2), fm.get("tags").?.array.items.len);
}

test "dot-only markdown filename cannot receive create or empty proposals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const artifacts = try runSingleSourcePlan(a, ".md", "# Empty stem\n");
    try expectSourceAction(a, artifacts.plan, ".md", "unsupported", "invalid_source_filename_empty_stem");
    var plan = try std.json.parseFromSlice(std.json.Value, a, artifacts.plan, .{});
    defer plan.deinit();
    const action = plan.value.object.get("digest_input").?.object.get("proposed_actions").?.array.items[0].object;
    try std.testing.expect(!std.mem.eql(u8, action.get("class").?.string, "create"));
    try std.testing.expect(!std.mem.eql(u8, action.get("class").?.string, "keep"));
    try std.testing.expect(action.get("proposed_boris_source_path").? == .null);
    try std.testing.expect(action.get("proposed_entity_id").? == .null);
    try std.testing.expect(action.get("inferred_source_route_candidate").? == .null);
    try std.testing.expect(action.get("proposed_boris_route").? == .null);
}

test "special markdown filenames are validated without invented fallback identities" {
    const cases = [_]struct { name: []const u8, class: []const u8, reason: []const u8 }{
        .{ .name = ".md", .class = "unsupported", .reason = "invalid_source_filename_empty_stem" },
        .{ .name = "..md", .class = "quarantine", .reason = "invalid_proposed_entity_id" },
        .{ .name = "nested/..md", .class = "quarantine", .reason = "invalid_proposed_entity_id" },
        .{ .name = "bad name.md", .class = "quarantine", .reason = "invalid_proposed_entity_id" },
        .{ .name = "bad#name.md", .class = "quarantine", .reason = "invalid_proposed_entity_id" },
        .{ .name = "index.md", .class = "create", .reason = "supported_plain_markdown" },
        .{ .name = "nested/index.md", .class = "create", .reason = "supported_plain_markdown" },
        .{ .name = "café.md", .class = "create", .reason = "supported_plain_markdown" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const artifacts = try runSingleSourcePlan(a, case.name, "# Filename\n");
        try expectSourceAction(a, artifacts.plan, case.name, case.class, case.reason);
    }
}

fn contentRootSymlinkCase(a: std.mem.Allocator, content_root: []const u8, link_path_from_root: []const u8, link_target: []const u8, valid_content_path: []const u8) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-plan-symlink", .{tmp.sub_path});
    const root_path = try std.fmt.allocPrint(a, "{s}/root", .{base});
    const out_path = try std.fmt.allocPrint(a, "{s}/out", .{base});
    const valid_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, valid_content_path });
    const valid_file = try std.fmt.allocPrint(a, "{s}/valid.md", .{valid_path});
    try Io.Dir.cwd().createDirPath(io, valid_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = valid_file, .data = "# Valid\n" });
    const options: RunOptions = .{ .root_dir = root_path, .content_root = content_root, .out_dir = out_path, .project_id = "symlink-test", .quiet = true };
    try run(io, a, options);
    const snapshot_path = try std.fmt.allocPrint(a, "{s}/source_snapshot.json", .{out_path});
    const plan_path = try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path});
    const report_path = try std.fmt.allocPrint(a, "{s}/REPORT.md", .{out_path});
    const before_snapshot = try readFileAlloc(io, Io.Dir.cwd(), snapshot_path, a);
    const before_plan = try readFileAlloc(io, Io.Dir.cwd(), plan_path, a);
    const before_report = try readFileAlloc(io, Io.Dir.cwd(), report_path, a);

    const replace_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, link_path_from_root });
    try Io.Dir.cwd().deleteTree(io, replace_path);
    const external_docs = try std.fmt.allocPrint(a, "{s}/external/docs", .{base});
    try Io.Dir.cwd().createDirPath(io, external_docs);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/escaped.md", .{external_docs}), .data = "# Must not be inventoried\n" });
    Io.Dir.cwd().symLink(io, link_target, replace_path, .{ .is_directory = true }) catch return;

    try std.testing.expectError(error.SelectedContentRootSymlink, run(io, a, options));
    try std.testing.expectEqualStrings(before_snapshot, try readFileAlloc(io, Io.Dir.cwd(), snapshot_path, a));
    try std.testing.expectEqualStrings(before_plan, try readFileAlloc(io, Io.Dir.cwd(), plan_path, a));
    try std.testing.expectEqualStrings(before_report, try readFileAlloc(io, Io.Dir.cwd(), report_path, a));
    const stage_path = try std.fmt.allocPrint(a, "{s}.boris-migration-lab-stage", .{out_path});
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, stage_path, .{ .follow_symlinks = false }));
}

test "selected content root symlink outside root is rejected before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try contentRootSymlinkCase(arena.allocator(), "content", "content", "../external/docs", "content");
}

test "selected content root symlink elsewhere beneath root is rejected" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-plan-internal-link", .{tmp.sub_path});
    const root_path = try std.fmt.allocPrint(a, "{s}/root", .{base});
    const content_path = try std.fmt.allocPrint(a, "{s}/content", .{root_path});
    const other_path = try std.fmt.allocPrint(a, "{s}/other", .{root_path});
    const out_path = try std.fmt.allocPrint(a, "{s}/out", .{base});
    try Io.Dir.cwd().createDirPath(io, content_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/valid.md", .{content_path}), .data = "# Valid\n" });
    const options: RunOptions = .{ .root_dir = root_path, .content_root = "content", .out_dir = out_path, .project_id = "internal-link", .quiet = true };
    try run(io, a, options);
    const before = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a);
    try Io.Dir.cwd().deleteTree(io, content_path);
    try Io.Dir.cwd().createDirPath(io, other_path);
    Io.Dir.cwd().symLink(io, "other", content_path, .{ .is_directory = true }) catch return;
    try std.testing.expectError(error.SelectedContentRootSymlink, run(io, a, options));
    try std.testing.expectEqualStrings(before, try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a));
}

test "intermediate selected content root symlink is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try contentRootSymlinkCase(arena.allocator(), "linked/docs", "linked", "../external", "linked/docs");
}

test "authored entity id colliding with a derived final id conflicts every record" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-plan-entity-collision", .{tmp.sub_path});
    const root_path = try std.fmt.allocPrint(a, "{s}/root", .{base});
    const content_path = try std.fmt.allocPrint(a, "{s}/content", .{root_path});
    const out_path = try std.fmt.allocPrint(a, "{s}/out", .{base});
    try Io.Dir.cwd().createDirPath(io, content_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/entity-a.md", .{content_path}), .data = "---\nid: entity-b\n---\n# A\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/entity-b.md", .{content_path}), .data = "# B\n" });
    try run(io, a, .{ .root_dir = root_path, .content_root = "content", .out_dir = out_path, .project_id = "entity-collision", .quiet = true });
    const plan_bytes = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, plan_bytes, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("digest_input").?.object;
    for (input.get("proposed_actions").?.array.items) |action| {
        try std.testing.expectEqualStrings("conflict", action.object.get("class").?.string);
        try std.testing.expectEqualStrings("duplicate_proposed_entity_id", action.object.get("reason").?.string);
    }
    const finding = input.get("findings").?.array.items[0].object;
    try std.testing.expectEqualStrings("duplicate_proposed_entity_id", finding.get("reason").?.string);
    try std.testing.expectEqual(@as(usize, 2), finding.get("source_paths").?.array.items.len);
}

test "restored import id colliding with another generated id conflicts every record" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-plan-restored-collision", .{tmp.sub_path});
    const root_path = try std.fmt.allocPrint(a, "{s}/root", .{base});
    const content_path = try std.fmt.allocPrint(a, "{s}/content", .{root_path});
    const out_path = try std.fmt.allocPrint(a, "{s}/out", .{base});
    const manifest_path = try std.fmt.allocPrint(a, "{s}/manifest.json", .{base});
    try Io.Dir.cwd().createDirPath(io, content_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.md", .{content_path}), .data = "# A\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/b.md", .{content_path}), .data = "# B\n" });
    const b_id = try recordId(a, "restored-collision", "b.md");
    const policy = try sha256Hex(a, policy_bytes);
    const manifest = try std.fmt.allocPrint(a, "{{\"format\":\"boris-astro-import-manifest\",\"schema_version\":1,\"project_id\":\"restored-collision\",\"policy_digest\":\"{s}\",\"records\":[{{\"source_path\":\"a.md\",\"import_record_id\":\"{s}\"}}]}}", .{ policy, b_id });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    try run(io, a, .{ .root_dir = root_path, .content_root = "content", .out_dir = out_path, .project_id = "restored-collision", .previous_manifest = manifest_path, .quiet = true });
    const plan_bytes = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, plan_bytes, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("digest_input").?.object;
    const expected_manifest_digest = try sha256Hex(a, manifest);
    try std.testing.expectEqualStrings(expected_manifest_digest, input.get("previous_manifest_digest").?.string);
    for (input.get("proposed_actions").?.array.items) |action| {
        try std.testing.expectEqualStrings("conflict", action.object.get("class").?.string);
        try std.testing.expectEqualStrings("duplicate_final_import_record_id", action.object.get("reason").?.string);
    }
}

test "every final identity collision category emits deterministic conflict evidence" {
    const keys = [_]CollisionKey{
        .normalized_source_path,
        .source_authored_id,
        .generated_import_id,
        .final_import_id,
        .proposed_entity_id,
        .proposed_boris_source_path,
        .inferred_route_candidate,
        .proposed_boris_route,
    };
    for (keys) |key| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var records = [_]Record{
            .{ .source_path = if (key == .normalized_source_path) "Page.md" else "a.md", .source_kind = "markdown", .byte_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .frontmatter_hash = null, .body_hash = null, .import_id = "air_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .generated_import_id = "air_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .base_action = .create, .action = .create, .reason = "ok", .authored_id = "entity-a", .proposed_boris_source_path = "content/a.md", .proposed_entity_id = "entity-a", .inferred_route_candidate = "a", .proposed_boris_route = "a", .proposal_valid = true },
            .{ .source_path = if (key == .normalized_source_path) "page.md" else "b.md", .source_kind = "markdown", .byte_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .frontmatter_hash = null, .body_hash = null, .import_id = "air_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .generated_import_id = "air_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .base_action = .create, .action = .create, .reason = "ok", .authored_id = "entity-b", .proposed_boris_source_path = "content/b.md", .proposed_entity_id = "entity-b", .inferred_route_candidate = "b", .proposed_boris_route = "b", .proposal_valid = true },
        };
        switch (key) {
            .normalized_source_path => {},
            .source_authored_id => records[1].authored_id = records[0].authored_id,
            .generated_import_id => records[1].generated_import_id = records[0].generated_import_id,
            .final_import_id => records[1].import_id = records[0].import_id,
            .proposed_entity_id => records[1].proposed_entity_id = records[0].proposed_entity_id,
            .proposed_boris_source_path => records[1].proposed_boris_source_path = records[0].proposed_boris_source_path,
            .inferred_route_candidate => records[1].inferred_route_candidate = records[0].inferred_route_candidate,
            .proposed_boris_route => records[1].proposed_boris_route = records[0].proposed_boris_route,
        }
        var findings: std.ArrayList(Finding) = .empty;
        try appendCollisionFindings(a, &records, key, &findings);
        try std.testing.expectEqual(@as(usize, 1), findings.items.len);
        try std.testing.expectEqualStrings(collisionReason(key), findings.items[0].reason);
        try std.testing.expectEqual(RecordClass.conflict, records[0].action);
        try std.testing.expectEqual(RecordClass.conflict, records[1].action);
    }
}

test "committed reference fixture emits exact typed deduplicated arrays and excludes code examples" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-reference-fixture-out", .{tmp.sub_path});
    const options: RunOptions = .{
        .root_dir = "fixtures/astro-import-plan",
        .content_root = "src/content/docs",
        .out_dir = out_path,
        .project_id = "reference-fixture",
        .quiet = true,
    };
    try run(io, a, options);
    const snapshot_path = try std.fmt.allocPrint(a, "{s}/source_snapshot.json", .{out_path});
    const first = try readFileAlloc(io, Io.Dir.cwd(), snapshot_path, a);
    try run(io, a, options);
    const second = try readFileAlloc(io, Io.Dir.cwd(), snapshot_path, a);
    try std.testing.expectEqualStrings(first, second);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer parsed.deinit();
    var target: ?std.json.ObjectMap = null;
    for (parsed.value.object.get("records").?.array.items) |record| {
        if (std.mem.eql(u8, record.object.get("source_path").?.string, "references.md")) {
            target = record.object;
            break;
        }
    }
    const record = target.?;
    const expected = [_]Reference{
        .{ .syntax = .autolink, .target = "https://example.test/autolink", .classification = .https },
        .{ .syntax = .autolink, .target = "mailto:help@example.test", .classification = .mailto },
        .{ .syntax = .inline_image, .target = "/images/logo.svg", .classification = .root_relative },
        .{ .syntax = .inline_link, .target = "data:image/png;base64,AAAA", .classification = .data_url },
        .{ .syntax = .inline_link, .target = "#part", .classification = .fragment },
        .{ .syntax = .inline_link, .target = "ftp://example.test/file", .classification = .ftp },
        .{ .syntax = .inline_link, .target = "http://example.test/a", .classification = .http },
        .{ .syntax = .inline_link, .target = "https://example.test/b", .classification = .https },
        .{ .syntax = .inline_link, .target = "mailto:docs@example.test", .classification = .mailto },
        .{ .syntax = .inline_link, .target = "tel:+15551212", .classification = .other_scheme },
        .{ .syntax = .inline_link, .target = "//cdn.example.test/x", .classification = .protocol_relative },
        .{ .syntax = .inline_link, .target = "with", .classification = .review },
        .{ .syntax = .inline_link, .target = "./guide.md", .classification = .source_relative },
        .{ .syntax = .inline_link, .target = "./guide_(old).md", .classification = .source_relative },
        .{ .syntax = .inline_link, .target = "./with%20space.md", .classification = .source_relative },
        .{ .syntax = .reference_definition, .target = "https://cdn.example.test/logo.svg", .classification = .https },
        .{ .syntax = .reference_definition, .target = "../guide.md", .classification = .source_relative },
        .{ .syntax = .reference_image_use, .target = "logo-ref", .classification = .reference_label },
        .{ .syntax = .reference_link_use, .target = "guide-ref", .classification = .reference_label },
    };
    const references = record.get("references").?.array.items;
    try std.testing.expectEqual(expected.len, references.len);
    for (expected, references) |want, got| {
        try std.testing.expectEqualStrings(@tagName(want.syntax), got.object.get("syntax").?.string);
        try std.testing.expectEqualStrings(want.target, got.object.get("target").?.string);
        try std.testing.expectEqualStrings(@tagName(want.classification), got.object.get("classification").?.string);
        try std.testing.expect(std.mem.indexOf(u8, got.object.get("target").?.string, "not-real") == null);
    }
    const assets = record.get("potential_asset_references").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), assets.len);
    try std.testing.expectEqualStrings("/images/logo.svg", assets[0].object.get("target").?.string);
    try std.testing.expectEqualStrings("logo-ref", assets[1].object.get("target").?.string);
}

test "committed valid schema artifact payloads match current runtime emissions" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const out_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-schema-runtime", .{tmp.sub_path});
    try run(io, a, .{
        .root_dir = "fixtures/astro-import-plan-schema",
        .content_root = "src/content/docs",
        .out_dir = out_path,
        .project_id = "schema-fixture",
        .quiet = true,
    });
    const emitted_snapshot = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/source_snapshot.json", .{out_path}), a);
    const emitted_plan = try readFileAlloc(io, Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/import_plan.json", .{out_path}), a);
    const committed_snapshot = try readFileAlloc(io, Io.Dir.cwd(), "schema-validation/fixtures/valid/source_snapshot.json", a);
    const committed_plan = try readFileAlloc(io, Io.Dir.cwd(), "schema-validation/fixtures/valid/import_plan.json", a);
    try std.testing.expectEqualStrings(std.mem.trim(u8, committed_snapshot, "\r\n"), emitted_snapshot);
    try std.testing.expectEqualStrings(std.mem.trim(u8, committed_plan, "\r\n"), emitted_plan);
}
