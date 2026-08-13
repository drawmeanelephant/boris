//! Native, read-only Filed.fyi full-corpus scan.
//! This mode inventories source state only; it never rewrites or converts inputs.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const publication = @import("publication.zig");
const semantics = @import("migration_semantics.zig");

pub const format_id = "boris-filed-native-scan";
pub const schema_version: u32 = 1;
pub const migration_lab_version = "0.1.0";
pub const ruleset_version = "filed-scan-v1";

pub const Options = struct { root_dir: []const u8, out_dir: []const u8, quiet: bool = false };

const Pair = struct { key: []const u8, value: []const u8 };
const OutputFile = struct { name: []const u8, data: []const u8 };
const Disposition = enum { scanned, blocked_malformed_frontmatter, blocked_invalid_utf8, blocked_duplicate_identity, queued_manual_review, excluded_by_explicit_policy };
const Candidate = struct { source: []const u8, field: []const u8, value: []const u8, identity: []const u8, kind: []const u8, strength: u8, selected: bool = false };
const Source = struct { path: []const u8, ext: []const u8, collection: []const u8, sha: []const u8, body_sha: []const u8, field_count: usize, identity: []const u8, parse_status: []const u8, disposition: Disposition };
const ParentRef = struct { source: []const u8, field: []const u8, target: []const u8, raw_target: []const u8 };
const RelationRef = struct { source: []const u8, field: []const u8, target: []const u8, raw_target: []const u8 };

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn scalarValue(s: []const u8) []const u8 {
    const value = trim(s);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}
fn lineNumber(bytes: []const u8, pos: usize) usize {
    return 1 + std.mem.count(u8, bytes[0..@min(pos, bytes.len)], "\n");
}

fn indentation(s: []const u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (c == ' ') count += 1 else if (c == '\t') count += 2 else break;
    }
    return count;
}

fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => if (c < 0x20) try out.appendSlice(a, "?") else try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

fn jsonLine(a: std.mem.Allocator, out: *std.ArrayList(u8), pairs: []const Pair) !void {
    try out.append(a, '{');
    for (pairs, 0..) |pair, i| {
        if (i != 0) try out.append(a, ',');
        const key = try escape(a, pair.key);
        defer a.free(key);
        const value = try escape(a, pair.value);
        defer a.free(value);
        try out.appendSlice(a, "\"");
        try out.appendSlice(a, key);
        try out.appendSlice(a, "\":\"");
        try out.appendSlice(a, value);
        try out.append(a, '"');
    }
    try out.append(a, '}');
    try out.append(a, '\n');
}

fn number(a: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(a, "{}", .{value});
}

fn hashBytes(bytes: []const u8) [32]u8 {
    var digest_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest_bytes, .{});
    return digest_bytes;
}

fn hexEncode(a: std.mem.Allocator, digest_bytes: *const [32]u8) ![]u8 {
    const out = try a.alloc(u8, 64);
    const alphabet = "0123456789abcdef";
    for (digest_bytes.*, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 15];
    }
    return out;
}

fn sha256(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest_bytes = hashBytes(bytes);
    return hexEncode(a, &digest_bytes);
}

fn readFile(io: Io, a: std.mem.Allocator, root: Io.Dir, path: []const u8) ![]u8 {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(a, .unlimited);
}

fn extension(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".mdx")) return "mdx";
    if (std.mem.endsWith(u8, base, ".md")) return "md";
    return "";
}

fn collection(path: []const u8) []const u8 {
    const marker = if (std.mem.indexOf(u8, path, "src/content/docs/")) |p| p + "src/content/docs/".len else if (std.mem.indexOf(u8, path, "content/")) |p| p + "content/".len else return "unknown";
    const rest = path[marker..];
    return if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest[0..slash] else "root";
}

fn valueShape(value: []const u8) []const u8 {
    const v = trim(value);
    if (v.len == 0) return "empty";
    if (v[0] == '[' and v[v.len - 1] == ']') return "flow_list";
    if (v[0] == '{' and v[v.len - 1] == '}') return "flow_mapping";
    if (v[0] == '"' and v.len >= 2 and v[v.len - 1] == '"') return "quoted";
    if (v[0] == '\'' and v.len >= 2 and v[v.len - 1] == '\'') return "single_quoted";
    if (v[0] == '|' or v[0] == '>') return "block_scalar";
    return "plain";
}

fn fieldDisposition(key: []const u8) semantics.FieldDisposition {
    // Filed-only legacy keys retain their review role; canonical Boris
    // vocabulary and dispositions come from the shared migration module.
    if (std.mem.eql(u8, key, "parentEntry") or std.mem.eql(u8, key, "parent_entry")) return .parent_candidate;
    return semantics.dispositionForKey(key);
}

fn fieldName(value: semantics.FieldDisposition) []const u8 {
    return value.name();
}
fn dispositionName(value: Disposition) []const u8 {
    return @tagName(value);
}

fn identityKind(field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "id")) return "explicit_id";
    if (std.mem.eql(u8, field, "caseNumber")) return "caseNumber";
    if (std.mem.eql(u8, field, "artifactId")) return "artifactId";
    if (std.mem.eql(u8, field, "mascotId")) return "mascotId";
    if (std.mem.eql(u8, field, "slug")) return "slug";
    return "source_path";
}

fn identityStrength(field: []const u8) u8 {
    if (std.mem.eql(u8, field, "id")) return 1;
    if (std.mem.eql(u8, field, "caseNumber") or std.mem.eql(u8, field, "artifactId") or std.mem.eql(u8, field, "mascotId") or std.mem.eql(u8, field, "slug")) return 2;
    return 3;
}

fn pathStem(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return a.dupe(u8, base[0..dot]);
}

fn identityFieldRank(field: []const u8) u8 {
    if (std.mem.eql(u8, field, "id")) return 0;
    if (std.mem.eql(u8, field, "caseNumber")) return 1;
    if (std.mem.eql(u8, field, "artifactId")) return 2;
    if (std.mem.eql(u8, field, "mascotId")) return 3;
    if (std.mem.eql(u8, field, "slug")) return 4;
    return 5;
}

fn selectIdentity(candidates: []Candidate) ?usize {
    if (candidates.len == 0) return null;
    var best: u8 = 255;
    for (candidates) |candidate| {
        if (candidate.identity.len != 0 and candidate.strength < best) best = candidate.strength;
    }
    if (best == 255) return null;

    var selected: ?usize = null;
    for (candidates, 0..) |candidate, index| {
        if (candidate.identity.len == 0 or candidate.strength != best) continue;
        if (selected) |existing| {
            if (!std.mem.eql(u8, candidates[existing].identity, candidate.identity)) return null;
            continue;
        }
        selected = index;
    }
    if (selected) |index| candidates[index].selected = true;
    return selected;
}

fn chooseIdentity(a: std.mem.Allocator, path: []const u8, candidates: []Candidate) ![]u8 {
    _ = path;
    const selected = selectIdentity(candidates) orelse return a.dupe(u8, "");
    return a.dupe(u8, candidates[selected].identity);
}

fn relationField(key: []const u8) bool {
    for ([_][]const u8{ "parent", "relatedEntries", "mascotRef", "relatedMascot", "relatedMascots", "relatedLorelog", "relatedHaiku", "relatedLimerick", "haikuLog", "limerickLog", "parentEntry", "parent_entry", "relations" }) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

fn isUrl(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "http://") or
        std.mem.startsWith(u8, target, "https://") or
        std.mem.startsWith(u8, target, "mailto:") or
        std.mem.startsWith(u8, target, "tel:") or
        std.mem.startsWith(u8, target, "//") or
        std.mem.indexOf(u8, target, "://") != null;
}

fn stripRelationPrefix(value: []const u8) []const u8 {
    var target = scalarValue(value);
    if (!isUrl(target)) {
        if (std.mem.indexOfAny(u8, target, "=:")) |sep| {
            target = scalarValue(target[sep + 1 ..]);
        }
    }
    return target;
}

fn appendRelationTargets(a: std.mem.Allocator, source: []const u8, field: []const u8, value: []const u8, parents: *std.ArrayList(ParentRef), relations: *std.ArrayList(RelationRef)) !void {
    const trimmed = trim(value);
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        var items = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
        while (items.next()) |item| {
            const raw_target = trim(item);
            const target = stripRelationPrefix(raw_target);
            if (target.len == 0) continue;
            if (std.mem.eql(u8, field, "parent")) {
                try parents.append(a, .{ .source = source, .field = field, .target = target, .raw_target = raw_target });
            } else {
                try relations.append(a, .{ .source = source, .field = field, .target = target, .raw_target = raw_target });
                if (std.mem.eql(u8, field, "parentEntry") or std.mem.eql(u8, field, "parent_entry")) {
                    try parents.append(a, .{ .source = source, .field = field, .target = target, .raw_target = raw_target });
                }
            }
        }
        return;
    }
    const target = stripRelationPrefix(trimmed);
    if (target.len == 0) return;
    if (std.mem.eql(u8, field, "parent")) {
        try parents.append(a, .{ .source = source, .field = field, .target = target, .raw_target = trimmed });
    } else {
        try relations.append(a, .{ .source = source, .field = field, .target = target, .raw_target = trimmed });
        if (std.mem.eql(u8, field, "parentEntry") or std.mem.eql(u8, field, "parent_entry")) {
            try parents.append(a, .{ .source = source, .field = field, .target = target, .raw_target = trimmed });
        }
    }
}

fn sourceIdentity(sources: []const Source, source_path: []const u8) []const u8 {
    for (sources) |source| {
        if (std.mem.eql(u8, source.path, source_path)) return if (source.identity.len != 0) source.identity else source.path;
    }
    return source_path;
}

fn identityResolution(sources: []const Source, candidates: []const Candidate, target: []const u8) struct { status: []const u8, resolved: []const u8, entity_type: []const u8 } {
    var first_path: []const u8 = "";
    var matched_count: usize = 0;
    for (candidates, 0..) |candidate, index| {
        if (candidate.identity.len == 0 or !std.mem.eql(u8, candidate.identity, target)) continue;
        var duplicate_path = false;
        for (candidates[0..index]) |other| {
            if (std.mem.eql(u8, other.source, candidate.source) and std.mem.eql(u8, other.identity, target)) {
                duplicate_path = true;
                break;
            }
        }
        if (duplicate_path) continue;
        if (matched_count == 0) first_path = candidate.source;
        matched_count += 1;
    }
    if (matched_count == 1) {
        for (sources) |source| {
            if (std.mem.eql(u8, source.path, first_path)) return .{ .status = "resolved", .resolved = source.identity, .entity_type = "source_record" };
        }
    }
    if (matched_count > 1) return .{ .status = "ambiguous", .resolved = "", .entity_type = "source_record" };
    return .{ .status = "unresolved", .resolved = "", .entity_type = "unknown" };
}

fn targetStatus(paths: []const []const u8, source: []const u8, target: []const u8) []const u8 {
    const raw = trim(target);
    if (raw.len == 0) return "missing";
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://") or std.mem.startsWith(u8, raw, "mailto:") or std.mem.startsWith(u8, raw, "tel:") or std.mem.startsWith(u8, raw, "data:") or std.mem.startsWith(u8, raw, "//")) return "external";
    if (raw[0] == '#') return "fragment_unverified";
    var clean = raw;
    var dir = std.fs.path.dirname(source) orelse "";
    if (std.mem.startsWith(u8, clean, "/")) {
        clean = clean[1..];
        dir = "";
    }
    if (std.mem.indexOfScalar(u8, clean, '#')) |at| clean = clean[0..at];
    if (std.mem.indexOfScalar(u8, clean, '?')) |at| clean = clean[0..at];
    while (std.mem.startsWith(u8, clean, "../")) {
        dir = std.fs.path.dirname(dir) orelse "";
        clean = clean[3..];
    }
    while (std.mem.startsWith(u8, clean, "./")) clean = clean[2..];
    var joined_storage: [4096]u8 = undefined;
    const joined = if (dir.len == 0)
        std.fmt.bufPrint(&joined_storage, "{s}", .{clean}) catch return "missing"
    else
        std.fmt.bufPrint(&joined_storage, "{s}/{s}", .{ dir, clean }) catch return "missing";
    for (paths) |path| {
        if (std.mem.eql(u8, path, joined)) return "found";
        if (std.mem.endsWith(u8, joined, ".md")) {
            var alt: [4096]u8 = undefined;
            const value = std.fmt.bufPrint(&alt, "{s}.mdx", .{joined[0 .. joined.len - 3]}) catch continue;
            if (std.mem.eql(u8, path, value)) return "found";
        } else if (std.mem.endsWith(u8, joined, ".mdx")) {
            var alt: [4096]u8 = undefined;
            const value = std.fmt.bufPrint(&alt, "{s}.md", .{joined[0 .. joined.len - 4]}) catch continue;
            if (std.mem.eql(u8, path, value)) return "found";
        }
    }
    return "missing";
}

fn emitReference(a: std.mem.Allocator, source: []const u8, full: []const u8, position: usize, paths: []const []const u8, target: []const u8, kind: []const u8, links: *std.ArrayList(u8), assets: *std.ArrayList(u8), link_count: *usize, asset_count: *usize) !void {
    const status = targetStatus(paths, source, target);
    const source_line = try number(a, lineNumber(full, position));
    const is_asset = std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "asset");
    try jsonLine(a, links, &.{ .{ .key = "source_path", .value = source }, .{ .key = "source_line", .value = source_line }, .{ .key = "original_target", .value = target }, .{ .key = "reference_type", .value = kind }, .{ .key = "exact_target_status", .value = status }, .{ .key = "proposed_disposition", .value = if (std.mem.eql(u8, status, "found") or std.mem.eql(u8, status, "external")) "preserve" else "manual_review" } });
    link_count.* += 1;
    if (is_asset) {
        try jsonLine(a, assets, &.{ .{ .key = "source_path", .value = source }, .{ .key = "source_line", .value = source_line }, .{ .key = "original_target", .value = target }, .{ .key = "reference_type", .value = kind }, .{ .key = "exact_target_status", .value = status }, .{ .key = "proposed_disposition", .value = if (std.mem.eql(u8, status, "found")) "preserve" else "manual_review" } });
        asset_count.* += 1;
    }
}

fn scanReferences(a: std.mem.Allocator, source: []const u8, full: []const u8, body: []const u8, body_offset: usize, paths: []const []const u8, links: *std.ArrayList(u8), assets: *std.ArrayList(u8), link_count: *usize, asset_count: *usize) !void {
    var offset: usize = 0;
    var fence = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const text = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        const trimmed = trim(text);
        const line_start = offset;
        offset += raw.len + 1;
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            fence = !fence;
            continue;
        }
        if (fence) continue;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const image = text[i] == '!' and i + 1 < text.len and text[i + 1] == '[';
            if (!image and text[i] != '[') continue;
            const close = std.mem.indexOfScalarPos(u8, text, i, ']') orelse continue;
            if (close + 1 >= text.len or text[close + 1] != '(') continue;
            const end = std.mem.indexOfScalarPos(u8, text, close + 2, ')') orelse continue;
            const target_with_title = trim(text[close + 2 .. end]);
            const target = if (std.mem.indexOfAny(u8, target_with_title, " \t")) |space| trim(target_with_title[0..space]) else target_with_title;
            try emitReference(a, source, full, body_offset + line_start + i, paths, target, if (image) "image" else "link", links, assets, link_count, asset_count);
            i = end;
        }
        const attr_names = [_][]const u8{ "data-srcset=", "data-src=", "srcset=", "poster=", "href=", "src=" };
        for (attr_names) |attr| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, text, at, attr)) |start| {
                if (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or text[start - 1] == '-' or text[start - 1] == '_')) {
                    at = start + attr.len;
                    continue;
                }
                const value_start = start + attr.len;
                if (value_start >= text.len or (text[value_start] != '"' and text[value_start] != '\'')) {
                    at = value_start;
                    continue;
                }
                const quote = text[value_start];
                const end = std.mem.indexOfScalarPos(u8, text, value_start + 1, quote) orelse break;
                const raw_target = text[value_start + 1 .. end];
                var targets = std.mem.splitScalar(u8, raw_target, ',');
                while (targets.next()) |candidate| {
                    const target = trim(candidate);
                    const url = if (std.mem.indexOfAny(u8, target, " \t")) |space| target[0..space] else target;
                    if (url.len == 0) continue;
                    const kind = if (std.mem.eql(u8, attr, "href=")) "link" else "asset";
                    try emitReference(a, source, full, body_offset + line_start + start, paths, url, kind, links, assets, link_count, asset_count);
                }
                at = end + 1;
            }
        }
    }
}

fn componentKnown(name: []const u8) bool {
    return std.mem.eql(u8, name, "Limerick") or std.mem.eql(u8, name, "LimerickStyle") or std.mem.eql(u8, name, "Broside") or std.mem.eql(u8, name, "CollectionRegister") or std.mem.eql(u8, name, "StarlightPage") or std.mem.eql(u8, name, "Icon");
}

fn inInlineCode(text: []const u8, position: usize) bool {
    var ticks: usize = 0;
    for (text[0..@min(position, text.len)]) |character| {
        if (character == '`') ticks += 1;
    }
    return ticks % 2 == 1;
}

fn matchingComponentClose(body: []const u8, after_open: usize, name: []const u8) bool {
    var stack: [128][]const u8 = undefined;
    var depth: usize = 1;
    stack[0] = name;
    var position = after_open;
    while (std.mem.indexOfScalarPos(u8, body, position, '<')) |start| {
        if (inFenceAt(body, start)) {
            position = (std.mem.indexOfScalarPos(u8, body, start, '\n') orelse body.len);
            continue;
        }
        const closing = start + 1 < body.len and body[start + 1] == '/';
        const name_start = start + 1 + @as(usize, if (closing) 1 else 0);
        if (name_start >= body.len or body[name_start] < 'A' or body[name_start] > 'Z') {
            position = start + 1;
            continue;
        }
        var name_end = name_start + 1;
        while (name_end < body.len and ((body[name_end] >= 'A' and body[name_end] <= 'Z') or (body[name_end] >= 'a' and body[name_end] <= 'z') or (body[name_end] >= '0' and body[name_end] <= '9') or body[name_end] == '_' or body[name_end] == '-')) : (name_end += 1) {}
        const tag_name = body[name_start..name_end];
        const after_name = std.mem.indexOfScalarPos(u8, body, name_end, '>') orelse return false;
        if (closing) {
            if (depth == 0 or !std.mem.eql(u8, stack[depth - 1], tag_name)) return false;
            depth -= 1;
            if (depth == 0) return true;
        } else if (depth < stack.len and after_name > name_end and body[after_name - 1] != '/') {
            stack[depth] = tag_name;
            depth += 1;
        }
        position = after_name + 1;
    }
    return false;
}

fn inFenceAt(body: []const u8, position: usize) bool {
    var fenced = false;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (position < offset + line.len + 1) return fenced;
        const trimmed = trim(line);
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) fenced = !fenced;
        offset += line.len + 1;
    }
    return fenced;
}

fn scanComponents(a: std.mem.Allocator, source: []const u8, full: []const u8, body: []const u8, body_offset: usize, components: *std.ArrayList(u8), count: *usize) !void {
    var offset: usize = 0;
    var fence = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const text = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        const line_start = offset;
        offset += raw.len + 1;
        const trimmed = trim(text);
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            fence = !fence;
            continue;
        }
        if (fence) continue;
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |start| {
            if (start + 1 >= text.len or text[start + 1] == '/' or text[start + 1] < 'A' or text[start + 1] > 'Z') {
                pos = start + 1;
                continue;
            }
            var end_name = start + 1;
            while (end_name < text.len and ((text[end_name] >= 'A' and text[end_name] <= 'Z') or (text[end_name] >= 'a' and text[end_name] <= 'z') or (text[end_name] >= '0' and text[end_name] <= '9') or text[end_name] == '_' or text[end_name] == '-')) : (end_name += 1) {}
            const name = text[start + 1 .. end_name];
            const tag_end = std.mem.indexOfScalarPos(u8, text, end_name, '>') orelse break;
            const self_closing = tag_end > end_name and text[tag_end - 1] == '/';
            const close = std.fmt.allocPrint(a, "</{s}>", .{name}) catch "";
            defer if (close.len != 0) a.free(close);
            const paired = !self_closing and close.len != 0 and !inInlineCode(text, start) and matchingComponentClose(body, line_start + tag_end + 1, name);
            const source_line = try number(a, lineNumber(full, body_offset + line_start + start));
            try jsonLine(a, components, &.{ .{ .key = "source_path", .value = source }, .{ .key = "component", .value = name }, .{ .key = "line", .value = source_line }, .{ .key = "attributes_encountered", .value = trim(text[end_name..tag_end]) }, .{ .key = "self_closing", .value = if (self_closing) "true" else "false" }, .{ .key = "paired", .value = if (paired) "true" else "false" }, .{ .key = "nested_content_shape", .value = if (self_closing) "none" else if (paired) "paired" else "unresolved" }, .{ .key = "proposed_transformer", .value = if (std.mem.eql(u8, name, "CollectionRegister")) "dynamic_query_manual_review" else if (componentKnown(name)) "presentational_wrapper_manual_review" else "unknown_component_manual_review" }, .{ .key = "review_status", .value = if (componentKnown(name)) "classified" else "manual_review" } });
            count.* += 1;
            pos = tag_end + 1;
        }
    }
}

fn ledgerRows(data: []const u8) usize {
    return if (data.len == 0) 0 else std.mem.count(u8, data, "\n");
}

fn validateJsonl(a: std.mem.Allocator, data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        parsed.deinit();
    }
}

fn sortJsonl(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |row| if (row.len != 0) try rows.append(a, row);
    std.mem.sort([]const u8, rows.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (rows.items) |row| {
        try out.appendSlice(a, row);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn validateLedgers(sources: []const Source, all_paths: []const []const u8, files: []const OutputFile, content_count: usize, frontmatter_count: usize, candidate_count: usize, collision_count: usize, parent_count: usize, relation_count: usize, link_count: usize, component_count: usize, asset_count: usize) !void {
    if (sources.len != content_count) return error.LedgerReconciliationFailed;
    for (all_paths) |path| {
        if (extension(path).len == 0) continue;
        var occurrences: usize = 0;
        for (sources) |source| {
            if (std.mem.eql(u8, source.path, path)) occurrences += 1;
        }
        if (occurrences != 1) return error.LedgerReconciliationFailed;
    }
    const expected = [_]struct { name: []const u8, count: usize }{
        .{ .name = "source-disposition.jsonl", .count = content_count },
        .{ .name = "frontmatter-ledger.jsonl", .count = frontmatter_count },
        .{ .name = "identity-candidates.jsonl", .count = candidate_count },
        .{ .name = "identity-collisions.jsonl", .count = collision_count },
        .{ .name = "parent-candidates.jsonl", .count = parent_count },
        .{ .name = "relation-candidates.jsonl", .count = relation_count },
        .{ .name = "link-ledger.jsonl", .count = link_count },
        .{ .name = "component-ledger.jsonl", .count = component_count },
        .{ .name = "asset-ledger.jsonl", .count = asset_count },
    };
    for (expected) |item| {
        var found = false;
        for (files) |file| {
            if (!std.mem.eql(u8, file.name, item.name)) continue;
            found = true;
            if (ledgerRows(file.data) != item.count) return error.LedgerReconciliationFailed;
            try validateJsonl(std.heap.page_allocator, file.data);
        }
        if (!found) return error.LedgerReconciliationFailed;
    }
    for (files) |file| {
        if (std.mem.endsWith(u8, file.name, ".jsonl") and
            (!std.mem.eql(u8, file.name, "REPORT.md"))) try validateJsonl(std.heap.page_allocator, file.data);
    }
}

fn digest(a: std.mem.Allocator, files: []const OutputFile) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (files) |file| {
        hasher.update(file.name);
        hasher.update(&.{0});
        hasher.update(file.data);
    }
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return hexEncode(a, &bytes);
}

fn writeManifest(a: std.mem.Allocator, output: *std.ArrayList(u8), opts: Options, tree: []const u8, out_digest: []const u8, sources: usize, fields: usize, candidates: usize, collisions: usize, parents: usize, relations: usize, links: usize, components: usize, assets: usize, blocked: usize) !void {
    const root = try escape(a, opts.root_dir);
    defer a.free(root);
    const tree_value = try escape(a, tree);
    defer a.free(tree_value);
    const output_value = try escape(a, out_digest);
    defer a.free(output_value);
    try output.appendSlice(a, "{\"format\":\"boris-filed-native-scan\",\"schema_version\":1,\"boris_version\":\"boris/0.8.1\",\"migration_lab_version\":\"");
    const lab = try escape(a, migration_lab_version);
    defer a.free(lab);
    try output.appendSlice(a, lab);
    try output.appendSlice(a, "\",\"ruleset_version\":\"");
    const rules = try escape(a, ruleset_version);
    defer a.free(rules);
    try output.appendSlice(a, rules);
    try output.appendSlice(a, "\",\"source_root\":\"");
    try output.appendSlice(a, root);
    try output.appendSlice(a, "\",\"source_tree_digest\":\"");
    try output.appendSlice(a, tree_value);
    try output.append(a, '"');
    const fields_text = [_]struct { name: []const u8, value: usize }{ .{ .name = "source_file_count", .value = sources }, .{ .name = "content_record_count", .value = sources }, .{ .name = "frontmatter_occurrence_count", .value = fields }, .{ .name = "identity_candidate_count", .value = candidates }, .{ .name = "collision_count", .value = collisions }, .{ .name = "parent_candidate_count", .value = parents }, .{ .name = "relation_candidate_count", .value = relations }, .{ .name = "link_count", .value = links }, .{ .name = "component_count", .value = components }, .{ .name = "asset_count", .value = assets }, .{ .name = "blocked_record_count", .value = blocked } };
    for (fields_text) |field| {
        try output.appendSlice(a, ",\"");
        try output.appendSlice(a, field.name);
        try output.appendSlice(a, "\":");
        try output.appendSlice(a, try number(a, field.value));
    }
    try output.appendSlice(a, ",\"output_digest\":\"");
    try output.appendSlice(a, output_value);
    try output.appendSlice(a, "\"}\n");
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true }) catch return error.SourceNotFound;
    defer root.close(io);
    const paths = try archaeology.collectFiles(io, gpa, a, root);
    defer gpa.free(paths);

    var sources: std.ArrayList(Source) = .empty;
    var candidates: std.ArrayList(Candidate) = .empty;
    var parents_ref: std.ArrayList(ParentRef) = .empty;
    var relations_ref: std.ArrayList(RelationRef) = .empty;
    var fm: std.ArrayList(u8) = .empty;
    var identity: std.ArrayList(u8) = .empty;
    var collisions: std.ArrayList(u8) = .empty;
    var parents: std.ArrayList(u8) = .empty;
    var relations: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(u8) = .empty;
    var components: std.ArrayList(u8) = .empty;
    var assets: std.ArrayList(u8) = .empty;
    var malformed: std.ArrayList(u8) = .empty;
    var tree_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var counts = std.StringHashMap(usize).init(a);
    var content_count: usize = 0;
    var frontmatter_count: usize = 0;
    var link_count: usize = 0;
    var asset_count: usize = 0;
    var component_count: usize = 0;
    var blocked_count: usize = 0;

    for (paths) |path| {
        const ext = extension(path);
        if (ext.len == 0) continue;
        content_count += 1;
        const bytes = try readFile(io, a, root, path);
        tree_hasher.update(path);
        tree_hasher.update(&.{0});
        tree_hasher.update(bytes);
        const source_sha = try sha256(a, bytes);
        var body = bytes;
        var body_offset: usize = 0;
        var field_count: usize = 0;
        var parse_status: []const u8 = "no_frontmatter";
        var disposition: Disposition = .scanned;
        var malformed_record = false;
        var review_needed = false;
        var local: std.ArrayList(Candidate) = .empty;
        const invalid = !std.unicode.utf8ValidateSlice(bytes);
        const bom = bytes.len >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and bytes[2] == 0xbf;
        if (invalid or bom) {
            parse_status = if (bom) "invalid_utf8_bom" else "invalid_utf8";
            disposition = .blocked_invalid_utf8;
            malformed_record = true;
            blocked_count += 1;
            try jsonLine(a, &malformed, &.{ .{ .key = "source_path", .value = path }, .{ .key = "reason", .value = if (bom) "leading_utf8_bom_rejected" else "invalid_utf8" }, .{ .key = "parse_status", .value = parse_status } });
        } else if (std.mem.startsWith(u8, bytes, "---\n") or std.mem.startsWith(u8, bytes, "---\r\n")) {
            const open_end: usize = if (bytes[3] == '\r') 5 else 4;
            var cursor = open_end;
            var closing_fence_start: ?usize = null;
            var close_end: ?usize = null;
            while (cursor < bytes.len) {
                const nl = std.mem.indexOfScalarPos(u8, bytes, cursor, '\n') orelse break;
                const current = if (nl > cursor and bytes[nl - 1] == '\r') bytes[cursor .. nl - 1] else bytes[cursor..nl];
                if (std.mem.eql(u8, current, "---")) {
                    closing_fence_start = cursor;
                    close_end = nl + 1;
                    break;
                }
                cursor = nl + 1;
            }
            if (close_end == null) {
                parse_status = "malformed_frontmatter_unclosed";
                disposition = .blocked_malformed_frontmatter;
                malformed_record = true;
                blocked_count += 1;
                try jsonLine(a, &malformed, &.{ .{ .key = "source_path", .value = path }, .{ .key = "reason", .value = "unclosed_frontmatter" }, .{ .key = "parse_status", .value = parse_status } });
            } else {
                parse_status = "parsed";
                body_offset = close_end.?;
                body = bytes[body_offset..];
                var seen = std.StringHashMap(void).init(a);
                var active_relation_field: []const u8 = "";
                var block_scalar = false;
                var p = open_end;
                const frontmatter_end = closing_fence_start.?;
                while (p < frontmatter_end) {
                    const nl = std.mem.indexOfScalarPos(u8, bytes, p, '\n') orelse close_end.? - 1;
                    const raw_line = bytes[p..nl];
                    const clean = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
                    const visible = trim(clean);
                    const indent = indentation(clean);
                    const is_comment_or_blank = visible.len == 0 or visible[0] == '#';
                    const list_line = visible.len > 0 and visible[0] == '-';
                    const top_level = indent == 0 and !list_line;

                    // Only column-zero mapping keys are top-level fields. YAML
                    // list items, nested mappings, and scalar continuations stay
                    // attached to the active field and cannot become duplicate
                    // or malformed top-level keys.
                    if (!is_comment_or_blank and !top_level) {
                        if (!block_scalar and active_relation_field.len == 0 and std.mem.indexOfScalar(u8, visible, ':') != null) {
                            field_count += 1;
                            frontmatter_count += 1;
                            const nested_colon = std.mem.indexOfScalar(u8, visible, ':').?;
                            const nested_key = trim(visible[0..nested_colon]);
                            try jsonLine(a, &fm, &.{ .{ .key = "source_path", .value = path }, .{ .key = "field_name", .value = nested_key }, .{ .key = "source_line", .value = try number(a, lineNumber(bytes, p)) }, .{ .key = "value_shape", .value = valueShape(visible[nested_colon + 1 ..]) }, .{ .key = "raw_value_hash", .value = try sha256(a, visible) }, .{ .key = "proposed_disposition", .value = fieldName(.manual_review) }, .{ .key = "reason", .value = "nested mapping retained for manual review" }, .{ .key = "frontmatter_byte_start", .value = try number(a, p) }, .{ .key = "frontmatter_byte_end", .value = try number(a, nl) } });
                            review_needed = true;
                        }
                        if (!block_scalar and active_relation_field.len != 0) {
                            var nested = visible;
                            if (nested.len > 0 and nested[0] == '-') nested = trim(nested[1..]);
                            if (nested.len > 0) {
                                if (std.mem.indexOfScalar(u8, nested, ':')) |nested_colon| {
                                    const nested_key = trim(nested[0..nested_colon]);
                                    const nested_raw_value = trim(nested[nested_colon + 1 ..]);
                                    const nested_value = scalarValue(nested_raw_value);
                                    field_count += 1;
                                    frontmatter_count += 1;
                                    try jsonLine(a, &fm, &.{ .{ .key = "source_path", .value = path }, .{ .key = "field_name", .value = nested_key }, .{ .key = "source_line", .value = try number(a, lineNumber(bytes, p)) }, .{ .key = "value_shape", .value = valueShape(nested_raw_value) }, .{ .key = "raw_value_hash", .value = try sha256(a, nested_raw_value) }, .{ .key = "proposed_disposition", .value = fieldName(.relation_candidate) }, .{ .key = "reason", .value = "nested relationship mapping field" }, .{ .key = "frontmatter_byte_start", .value = try number(a, p) }, .{ .key = "frontmatter_byte_end", .value = try number(a, nl) } });
                                    if ((std.mem.eql(u8, nested_key, "id") or std.mem.eql(u8, nested_key, "slug") or std.mem.eql(u8, nested_key, "target") or std.mem.eql(u8, nested_key, "ref")) and nested_value.len != 0) {
                                        try appendRelationTargets(a, path, active_relation_field, nested_value, &parents_ref, &relations_ref);
                                    }
                                } else if (list_line) {
                                    try appendRelationTargets(a, path, active_relation_field, nested, &parents_ref, &relations_ref);
                                }
                            }
                        }
                        p = nl + 1;
                        continue;
                    }
                    if (is_comment_or_blank) {
                        p = nl + 1;
                        continue;
                    }
                    if (list_line and active_relation_field.len == 0) {
                        field_count += 1;
                        frontmatter_count += 1;
                        try jsonLine(a, &fm, &.{ .{ .key = "source_path", .value = path }, .{ .key = "field_name", .value = "" }, .{ .key = "source_line", .value = try number(a, lineNumber(bytes, p)) }, .{ .key = "value_shape", .value = "list_item" }, .{ .key = "raw_value_hash", .value = try sha256(a, visible) }, .{ .key = "proposed_disposition", .value = fieldName(.manual_review) }, .{ .key = "reason", .value = "top-level list item without an active mapping field" }, .{ .key = "frontmatter_byte_start", .value = try number(a, p) }, .{ .key = "frontmatter_byte_end", .value = try number(a, nl) } });
                        review_needed = true;
                        p = nl + 1;
                        continue;
                    }

                    // A new top-level key closes the prior list/scalar context.
                    block_scalar = false;
                    active_relation_field = "";
                    const colon = std.mem.indexOfScalar(u8, clean, ':');
                    const key = if (colon) |at| trim(clean[0..at]) else "";
                    const value = if (colon) |at| trim(clean[at + 1 ..]) else "";
                    const malformed_field = colon == null or key.len == 0;
                    const duplicate = key.len != 0 and seen.contains(key);
                    const fd: semantics.FieldDisposition = if (malformed_field) .manual_review else fieldDisposition(key);
                    field_count += 1;
                    frontmatter_count += 1;
                    if (fd == .manual_review or fd == .platform_residue or fd == .sidecar_only) review_needed = true;
                    const reason = if (malformed_field) "malformed top-level field line" else if (duplicate) "duplicate top-level field key" else if (semantics.isBorisKey(key)) "Boris grammar field" else "foreign field retained for review";
                    if (malformed_field or duplicate) {
                        disposition = .blocked_malformed_frontmatter;
                        malformed_record = true;
                        parse_status = if (duplicate) "malformed_frontmatter_duplicate_key" else "malformed_frontmatter_field";
                        try jsonLine(a, &malformed, &.{ .{ .key = "source_path", .value = path }, .{ .key = "source_line", .value = try number(a, lineNumber(bytes, p)) }, .{ .key = "reason", .value = if (duplicate) "duplicate_top_level_key" else "malformed_top_level_field_line" }, .{ .key = "raw_line_hash", .value = try sha256(a, clean) } });
                    }
                    if (key.len != 0) try seen.put(key, {});
                    const raw_value = if (colon) |at| clean[at + 1 ..] else clean;
                    try jsonLine(a, &fm, &.{ .{ .key = "source_path", .value = path }, .{ .key = "field_name", .value = key }, .{ .key = "source_line", .value = try number(a, lineNumber(bytes, p)) }, .{ .key = "value_shape", .value = valueShape(value) }, .{ .key = "raw_value_hash", .value = try sha256(a, raw_value) }, .{ .key = "proposed_disposition", .value = fieldName(fd) }, .{ .key = "reason", .value = reason }, .{ .key = "frontmatter_byte_start", .value = try number(a, p) }, .{ .key = "frontmatter_byte_end", .value = try number(a, nl) } });
                    if (fd == .identity_source and value.len != 0) {
                        const identity_value = scalarValue(value);
                        try local.append(a, .{ .source = path, .field = key, .value = identity_value, .identity = identity_value, .kind = identityKind(key), .strength = identityStrength(key) });
                    }
                    if (relationField(key)) {
                        if (value.len != 0) {
                            try appendRelationTargets(a, path, key, value, &parents_ref, &relations_ref);
                        } else {
                            active_relation_field = key;
                        }
                    }
                    if (value.len > 0 and (value[0] == '|' or value[0] == '>')) block_scalar = true;
                    p = nl + 1;
                }
            }
        }
        const path_identity = try pathStem(a, path);
        try local.append(a, .{ .source = path, .field = "source_path", .value = path, .identity = path_identity, .kind = "source_path", .strength = 3 });

        const proposed = try chooseIdentity(a, path, local.items);
        for (local.items) |candidate| try candidates.append(a, .{ .source = candidate.source, .field = candidate.field, .value = candidate.value, .identity = candidate.identity, .kind = candidate.kind, .strength = candidate.strength, .selected = candidate.selected });
        if (!malformed_record and proposed.len == 0) {
            disposition = .queued_manual_review;
            parse_status = "identity_conflict";
        } else if (!malformed_record and review_needed and disposition == .scanned) {
            disposition = .queued_manual_review;
            if (std.mem.eql(u8, parse_status, "parsed")) parse_status = "parsed_with_review";
        }
        if (malformed_record and disposition == .scanned) disposition = .blocked_malformed_frontmatter;
        const body_sha = try sha256(a, body);
        try scanReferences(a, path, bytes, body, body_offset, paths, &links, &assets, &link_count, &asset_count);
        try scanComponents(a, path, bytes, body, body_offset, &components, &component_count);
        try sources.append(a, .{ .path = path, .ext = ext, .collection = collection(path), .sha = source_sha, .body_sha = body_sha, .field_count = field_count, .identity = proposed, .parse_status = parse_status, .disposition = disposition });
        if (proposed.len != 0) {
            const entry = try counts.getOrPut(proposed);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }

    var collision_count: usize = 0;
    for (sources.items) |*source| {
        const count = counts.get(source.identity) orelse 0;
        if (source.identity.len != 0 and count > 1 and source.disposition != .blocked_invalid_utf8 and source.disposition != .blocked_malformed_frontmatter) source.disposition = .blocked_duplicate_identity;
    }
    var collision_ids: std.ArrayList([]const u8) = .empty;
    for (sources.items) |source| {
        if (source.identity.len == 0 or (counts.get(source.identity) orelse 0) <= 1) continue;
        var seen = false;
        for (collision_ids.items) |id| {
            if (std.mem.eql(u8, id, source.identity)) seen = true;
        }
        if (!seen) {
            try collision_ids.append(a, source.identity);
            collision_count += 1;
            var source_list: std.ArrayList(u8) = .empty;
            for (sources.items) |other| {
                if (!std.mem.eql(u8, other.identity, source.identity)) continue;
                if (source_list.items.len != 0) try source_list.append(a, ',');
                try source_list.appendSlice(a, other.path);
            }
            try jsonLine(a, &collisions, &.{ .{ .key = "identity", .value = source.identity }, .{ .key = "source_paths", .value = source_list.items }, .{ .key = "occurrence_count", .value = try number(a, counts.get(source.identity) orelse 0) }, .{ .key = "status", .value = "blocked_duplicate_identity" } });
        }
    }
    for (candidates.items) |candidate| {
        try jsonLine(a, &identity, &.{ .{ .key = "source_path", .value = candidate.source }, .{ .key = "source_field", .value = candidate.field }, .{ .key = "candidate", .value = candidate.value }, .{ .key = "candidate_identity", .value = candidate.identity }, .{ .key = "candidate_kind", .value = candidate.kind }, .{ .key = "strength", .value = try number(a, candidate.strength) }, .{ .key = "alias", .value = if (candidate.selected) "false" else "true" }, .{ .key = "selected", .value = if (candidate.selected) "true" else "false" } });
    }
    for (parents_ref.items) |ref| {
        const resolved = identityResolution(sources.items, candidates.items, ref.target);
        const decision = if (std.mem.eql(u8, ref.field, "parent") and std.mem.eql(u8, resolved.status, "resolved")) "parent" else if (std.mem.eql(u8, ref.field, "parent")) "review" else if (std.mem.eql(u8, resolved.status, "resolved")) "relation" else "review";
        try jsonLine(a, &parents, &.{ .{ .key = "source_id", .value = sourceIdentity(sources.items, ref.source) }, .{ .key = "source_field", .value = ref.field }, .{ .key = "raw_target", .value = ref.raw_target }, .{ .key = "resolved_target_candidate", .value = resolved.resolved }, .{ .key = "target_entity_type", .value = resolved.entity_type }, .{ .key = "decision", .value = decision }, .{ .key = "confidence", .value = if (std.mem.eql(u8, resolved.status, "resolved")) "high" else "low" }, .{ .key = "resolution_status", .value = resolved.status }, .{ .key = "EPARENTNOTTRUNK_risk", .value = if (std.mem.eql(u8, ref.field, "parent")) "true" else "false" } });
    }
    for (relations_ref.items) |ref| {
        const resolved = identityResolution(sources.items, candidates.items, ref.target);
        var same_source_count: usize = 0;
        for (relations_ref.items) |other| {
            if (std.mem.eql(u8, other.source, ref.source)) same_source_count += 1;
        }
        const status = if (same_source_count > 16) "overflow" else resolved.status;
        try jsonLine(a, &relations, &.{ .{ .key = "source_path", .value = ref.source }, .{ .key = "source_field", .value = ref.field }, .{ .key = "raw_target", .value = ref.raw_target }, .{ .key = "resolved_target", .value = resolved.resolved }, .{ .key = "status", .value = status }, .{ .key = "canonical", .value = "false" }, .{ .key = "reason", .value = if (std.mem.eql(u8, status, "resolved")) "exact target evidence only; scan does not emit relations" else if (std.mem.eql(u8, status, "overflow")) "exceeds Boris relation bound" else "unresolved or ambiguous target" } });
    }

    var source_rows: std.ArrayList(u8) = .empty;
    for (sources.items) |source| try jsonLine(a, &source_rows, &.{ .{ .key = "source_path", .value = source.path }, .{ .key = "source_sha256", .value = source.sha }, .{ .key = "collection", .value = source.collection }, .{ .key = "extension", .value = source.ext }, .{ .key = "parse_status", .value = source.parse_status }, .{ .key = "frontmatter_field_count", .value = try number(a, source.field_count) }, .{ .key = "body_sha256", .value = source.body_sha }, .{ .key = "proposed_identity", .value = source.identity }, .{ .key = "disposition", .value = dispositionName(source.disposition) } });
    var report: std.ArrayList(u8) = .empty;
    try report.appendSlice(a, "# Filed.fyi native scan\n\nThis is a deterministic, scan-only report. Source bytes were not rewritten and no converted pages were emitted.\n\nAll uncertain identity, hierarchy, relation, link, asset, and component decisions remain explicit in the ledgers for human review.\n");
    const source_rows_sorted = try sortJsonl(a, source_rows.items);
    const fm_sorted = try sortJsonl(a, fm.items);
    const identity_sorted = try sortJsonl(a, identity.items);
    const collisions_sorted = try sortJsonl(a, collisions.items);
    const parents_sorted = try sortJsonl(a, parents.items);
    const relations_sorted = try sortJsonl(a, relations.items);
    const links_sorted = try sortJsonl(a, links.items);
    const components_sorted = try sortJsonl(a, components.items);
    const assets_sorted = try sortJsonl(a, assets.items);
    const malformed_sorted = try sortJsonl(a, malformed.items);
    const ledger_files = [_]OutputFile{ .{ .name = "source-disposition.jsonl", .data = source_rows_sorted }, .{ .name = "frontmatter-ledger.jsonl", .data = fm_sorted }, .{ .name = "identity-candidates.jsonl", .data = identity_sorted }, .{ .name = "identity-collisions.jsonl", .data = collisions_sorted }, .{ .name = "parent-candidates.jsonl", .data = parents_sorted }, .{ .name = "relation-candidates.jsonl", .data = relations_sorted }, .{ .name = "link-ledger.jsonl", .data = links_sorted }, .{ .name = "component-ledger.jsonl", .data = components_sorted }, .{ .name = "asset-ledger.jsonl", .data = assets_sorted }, .{ .name = "malformed-records.jsonl", .data = malformed_sorted }, .{ .name = "REPORT.md", .data = report.items } };
    try validateLedgers(sources.items, paths, &ledger_files, content_count, frontmatter_count, candidates.items.len, collision_count, parents_ref.items.len, relations_ref.items.len, link_count, component_count, asset_count);
    const output_digest = try digest(a, &ledger_files);
    var tree_bytes: [32]u8 = undefined;
    tree_hasher.final(&tree_bytes);
    const tree_digest = try hexEncode(a, &tree_bytes);
    var manifest: std.ArrayList(u8) = .empty;
    var final_blocked: usize = 0;
    for (sources.items) |source| {
        if (source.disposition == .blocked_invalid_utf8 or source.disposition == .blocked_malformed_frontmatter or source.disposition == .blocked_duplicate_identity) final_blocked += 1;
    }
    try writeManifest(a, &manifest, opts, tree_digest, output_digest, content_count, frontmatter_count, candidates.items.len, collision_count, parents_ref.items.len, relations_ref.items.len, link_count, component_count, asset_count, final_blocked);
    var parsed_manifest = try std.json.parseFromSlice(std.json.Value, a, manifest.items, .{});
    parsed_manifest.deinit();

    var publication_state = try publication.Publication.begin(io, a, opts.out_dir, &.{opts.root_dir}, format_id);
    defer publication_state.deinit(a);
    errdefer publication_state.abandon(io, a);
    var stage = try Io.Dir.cwd().openDir(io, publication_state.stage_path, .{});
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "migration-manifest.json", .data = manifest.items });
    for (ledger_files) |file| try stage.writeFile(io, .{ .sub_path = file.name, .data = file.data });
    try publication_state.commit(io, a);
    if (!opts.quiet) std.debug.print("filed-scan: {d} content records -> {s}\n", .{ content_count, opts.out_dir });
}

test "sha256 hex uses known vectors without hashing digest bytes twice" {
    const empty = try sha256(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", empty);

    const abc = try sha256(std.testing.allocator, "abc");
    defer std.testing.allocator.free(abc);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", abc);
}

test "fixture: multiline YAML remains valid and retains every relationship target" {
    const io = std.testing.io;
    const out_a = "fixtures/.test-filed-scan-multiline-a";
    const out_b = "fixtures/.test-filed-scan-multiline-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_a) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_b) catch {};

    const source_paths = [_][]const u8{ "tags.md", "description.md", "related-mappings.mdx", "related-ids.mdx", "legacy-parent.mdx" };
    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/filed-scan-multiline", .{});
    defer fixture.close(io);
    var before: [source_paths.len][]u8 = undefined;
    for (source_paths, 0..) |path, i| before[i] = try readFile(io, std.testing.allocator, fixture, path);
    defer for (&before) |bytes| std.testing.allocator.free(bytes);

    try run(io, std.testing.allocator, .{ .root_dir = "fixtures/filed-scan-multiline", .out_dir = out_a, .quiet = true });
    try run(io, std.testing.allocator, .{ .root_dir = "fixtures/filed-scan-multiline", .out_dir = out_b, .quiet = true });

    const output_names = [_][]const u8{ "migration-manifest.json", "source-disposition.jsonl", "frontmatter-ledger.jsonl", "identity-candidates.jsonl", "identity-collisions.jsonl", "parent-candidates.jsonl", "relation-candidates.jsonl", "link-ledger.jsonl", "component-ledger.jsonl", "asset-ledger.jsonl", "malformed-records.jsonl", "REPORT.md" };
    var first_output = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer first_output.close(io);
    var second_output = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer second_output.close(io);
    for (output_names) |name| {
        const left = try readFile(io, std.testing.allocator, first_output, name);
        defer std.testing.allocator.free(left);
        const right = try readFile(io, std.testing.allocator, second_output, name);
        defer std.testing.allocator.free(right);
        try std.testing.expectEqualStrings(left, right);
    }
    for (source_paths, 0..) |path, i| {
        const after = try readFile(io, std.testing.allocator, fixture, path);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(before[i], after);
    }

    const source_rows = try readFile(io, std.testing.allocator, first_output, "source-disposition.jsonl");
    defer std.testing.allocator.free(source_rows);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, source_rows, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, source_rows, "blocked_malformed_frontmatter") == null);

    const malformed_rows = try readFile(io, std.testing.allocator, first_output, "malformed-records.jsonl");
    defer std.testing.allocator.free(malformed_rows);
    try std.testing.expectEqual(@as(usize, 0), malformed_rows.len);

    const relation_rows = try readFile(io, std.testing.allocator, first_output, "relation-candidates.jsonl");
    defer std.testing.allocator.free(relation_rows);
    var relation_count: usize = 0;
    var mapping_one = false;
    var mapping_two = false;
    var list_one = false;
    var list_two = false;
    var legacy_relation = false;
    var relation_lines = std.mem.splitScalar(u8, relation_rows, '\n');
    while (relation_lines.next()) |line| {
        if (line.len == 0) continue;
        relation_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const source_field = object.get("source_field").?.string;
        const raw_target = object.get("raw_target").?.string;
        const source_path = object.get("source_path").?.string;
        if (std.mem.eql(u8, source_field, "relatedEntries") and std.mem.eql(u8, source_path, "related-mappings.mdx") and std.mem.eql(u8, raw_target, "LLG-ONE")) mapping_one = true;
        if (std.mem.eql(u8, source_field, "relatedEntries") and std.mem.eql(u8, source_path, "related-mappings.mdx") and std.mem.eql(u8, raw_target, "MASCOT-TWO")) mapping_two = true;
        if (std.mem.eql(u8, source_field, "relatedEntries") and std.mem.eql(u8, source_path, "related-ids.mdx") and std.mem.eql(u8, raw_target, "LLG-TWO")) list_one = true;
        if (std.mem.eql(u8, source_field, "relatedEntries") and std.mem.eql(u8, source_path, "related-ids.mdx") and std.mem.eql(u8, raw_target, "LLG-ONE")) list_two = true;
        if (std.mem.eql(u8, source_field, "parentEntry") and std.mem.eql(u8, raw_target, "legacy-target")) legacy_relation = true;
    }
    try std.testing.expectEqual(@as(usize, 5), relation_count);
    try std.testing.expect(mapping_one);
    try std.testing.expect(mapping_two);
    try std.testing.expect(list_one);
    try std.testing.expect(list_two);
    try std.testing.expect(legacy_relation);

    const parent_rows = try readFile(io, std.testing.allocator, first_output, "parent-candidates.jsonl");
    defer std.testing.allocator.free(parent_rows);
    var parent_review = false;
    var parent_promoted = false;
    var parent_lines = std.mem.splitScalar(u8, parent_rows, '\n');
    while (parent_lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        if (std.mem.eql(u8, object.get("source_id").?.string, "LEGACY-PARENT") and
            std.mem.eql(u8, object.get("source_field").?.string, "parentEntry") and
            std.mem.eql(u8, object.get("raw_target").?.string, "legacy-target"))
        {
            parent_review = std.mem.eql(u8, object.get("decision").?.string, "review");
            parent_promoted = std.mem.eql(u8, object.get("decision").?.string, "parent");
        }
    }
    try std.testing.expect(parent_review);
    try std.testing.expect(!parent_promoted);

    const fm_rows = try readFile(io, std.testing.allocator, first_output, "frontmatter-ledger.jsonl");
    defer std.testing.allocator.free(fm_rows);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "continuing on another line") == null);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "nested relationship mapping field") != null);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "field_name\\\":\\\"id\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "value_shape\\\":\\\"block_scalar\\\"") != null);
}

test "fixture: parse statuses and LF/CRLF fences are explicit and lossless" {
    const io = std.testing.io;
    const out_a = "fixtures/.test-filed-scan-status-a";
    const out_b = "fixtures/.test-filed-scan-status-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_a) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_b) catch {};

    const source_paths = [_][]const u8{
        "no-frontmatter.md",
        "parsed.md",
        "parsed-review.md",
        "duplicate.md",
        "unclosed.md",
        "malformed-field.md",
        "lf.md",
        "crlf.md",
        "canonical-relations.md",
    };
    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/filed-scan-status", .{});
    defer fixture.close(io);
    var before: [source_paths.len][]u8 = undefined;
    for (source_paths, 0..) |path, i| before[i] = try readFile(io, std.testing.allocator, fixture, path);
    defer for (&before) |bytes| std.testing.allocator.free(bytes);

    try run(io, std.testing.allocator, .{ .root_dir = "fixtures/filed-scan-status", .out_dir = out_a, .quiet = true });
    try run(io, std.testing.allocator, .{ .root_dir = "fixtures/filed-scan-status", .out_dir = out_b, .quiet = true });

    const output_names = [_][]const u8{
        "migration-manifest.json",
        "source-disposition.jsonl",
        "frontmatter-ledger.jsonl",
        "identity-candidates.jsonl",
        "identity-collisions.jsonl",
        "parent-candidates.jsonl",
        "relation-candidates.jsonl",
        "link-ledger.jsonl",
        "component-ledger.jsonl",
        "asset-ledger.jsonl",
        "malformed-records.jsonl",
        "REPORT.md",
    };
    var first_output = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer first_output.close(io);
    var second_output = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer second_output.close(io);
    for (output_names) |name| {
        const left = try readFile(io, std.testing.allocator, first_output, name);
        defer std.testing.allocator.free(left);
        const right = try readFile(io, std.testing.allocator, second_output, name);
        defer std.testing.allocator.free(right);
        try std.testing.expectEqualStrings(left, right);
    }
    for (source_paths, 0..) |path, i| {
        const after = try readFile(io, std.testing.allocator, fixture, path);
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(before[i], after);
    }

    const expected = [_]struct { path: []const u8, status: []const u8, disposition: []const u8, fields: usize }{
        .{ .path = "no-frontmatter.md", .status = "no_frontmatter", .disposition = "scanned", .fields = 0 },
        .{ .path = "parsed.md", .status = "parsed", .disposition = "scanned", .fields = 2 },
        .{ .path = "parsed-review.md", .status = "parsed_with_review", .disposition = "queued_manual_review", .fields = 3 },
        .{ .path = "duplicate.md", .status = "malformed_frontmatter_duplicate_key", .disposition = "blocked_malformed_frontmatter", .fields = 3 },
        .{ .path = "unclosed.md", .status = "malformed_frontmatter_unclosed", .disposition = "blocked_malformed_frontmatter", .fields = 0 },
        .{ .path = "malformed-field.md", .status = "malformed_frontmatter_field", .disposition = "blocked_malformed_frontmatter", .fields = 2 },
        .{ .path = "lf.md", .status = "parsed", .disposition = "scanned", .fields = 1 },
        .{ .path = "crlf.md", .status = "parsed", .disposition = "scanned", .fields = 1 },
        .{ .path = "canonical-relations.md", .status = "parsed", .disposition = "scanned", .fields = 2 },
    };
    const source_rows = try readFile(io, std.testing.allocator, first_output, "source-disposition.jsonl");
    defer std.testing.allocator.free(source_rows);
    var found = [_]bool{false} ** expected.len;
    var source_lines = std.mem.splitScalar(u8, source_rows, '\n');
    while (source_lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const path = object.get("source_path").?.string;
        for (expected, 0..) |want, i| {
            if (!std.mem.eql(u8, path, want.path)) continue;
            found[i] = true;
            try std.testing.expectEqualStrings(want.status, object.get("parse_status").?.string);
            try std.testing.expectEqualStrings(want.disposition, object.get("disposition").?.string);
            try std.testing.expectEqual(@as(i64, @intCast(want.fields)), object.get("frontmatter_field_count").?.integer);
        }
    }
    for (found) |was_found| try std.testing.expect(was_found);

    const fm_rows = try readFile(io, std.testing.allocator, first_output, "frontmatter-ledger.jsonl");
    defer std.testing.allocator.free(fm_rows);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "field_name\\\":\\\"---\\\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "source_path\\\":\\\"lf.md\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fm_rows, "source_path\\\":\\\"crlf.md\\\"") != null);

    const malformed_rows = try readFile(io, std.testing.allocator, first_output, "malformed-records.jsonl");
    defer std.testing.allocator.free(malformed_rows);
    try std.testing.expect(std.mem.indexOf(u8, malformed_rows, "malformed_frontmatter_duplicate_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, malformed_rows, "malformed_frontmatter_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, malformed_rows, "malformed_frontmatter_unclosed") != null);

    const relation_rows = try readFile(io, std.testing.allocator, first_output, "relation-candidates.jsonl");
    defer std.testing.allocator.free(relation_rows);
    try std.testing.expect(std.mem.indexOf(u8, relation_rows, "canonical-relations.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, relation_rows, "\"raw_target\":\"relates_to:PARSED-ONE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relation_rows, "\"resolved_target\":\"PARSED-ONE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relation_rows, "\"status\":\"resolved\"") != null);
}
