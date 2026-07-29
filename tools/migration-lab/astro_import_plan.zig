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
pub const policy_bytes = "{\"format\":\"boris-astro-import-policy\",\"schema_version\":1,\"source_system\":\"astro\",\"supported_frontmatter\":[\"id\",\"title\",\"status\",\"tags\"],\"supported_source\":\"explicit .md beneath --content-root with ordinary Markdown only\",\"non_goals\":[\"apply\",\"asset-copy\",\"mdx\",\"route-observation\",\"parent-inference\"]}\n";

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
    action: RecordClass,
    reason: []const u8,
    title: ?[]const u8 = null,
    authored_id: ?[]const u8 = null,
    links: []const Reference = &.{},
};

const ReferenceKind = enum { markdown_link, markdown_image, root_relative, source_relative, remote, fragment, data_url, review };

const Reference = struct { kind: ReferenceKind, target: []const u8 };

const Previous = struct { source_path: []const u8, import_id: []const u8 };

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

fn recordId(a: std.mem.Allocator, project_id: []const u8, source_path: []const u8) ![]const u8 {
    const input = try std.fmt.allocPrint(a, "boris-astro-import-record-v1\n{s}\n{s}", .{ project_id, source_path });
    defer a.free(input);
    const digest = try sha256Hex(a, input);
    defer a.free(digest);
    return std.fmt.allocPrint(a, "air_{s}", .{digest});
}

fn parseFrontmatter(bytes: []const u8, a: std.mem.Allocator) !struct { fm: []const u8, body: []const u8, title: ?[]const u8, id: ?[]const u8, ok: bool, reason: []const u8 } {
    if (!std.mem.startsWith(u8, bytes, "---\n") and !std.mem.startsWith(u8, bytes, "---\r\n")) return .{ .fm = "", .body = bytes, .title = null, .id = null, .ok = true, .reason = "" };
    const open_end: usize = if (std.mem.startsWith(u8, bytes, "---\r\n")) 5 else 4;
    const closing = std.mem.indexOfPos(u8, bytes, open_end, "\n---\n") orelse std.mem.indexOfPos(u8, bytes, open_end, "\n---\r\n") orelse return .{ .fm = bytes, .body = "", .title = null, .id = null, .ok = false, .reason = "unclosed_frontmatter" };
    const fm = bytes[open_end..closing];
    const body_start = if (std.mem.startsWith(u8, bytes[closing..], "\n---\r\n")) closing + 6 else closing + 5;
    var title: ?[]const u8 = null;
    var authored_id: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t' or std.mem.startsWith(u8, line, "- ")) return .{ .fm = fm, .body = bytes[body_start..], .title = title, .id = authored_id, .ok = false, .reason = "nested_or_sequence_frontmatter" };
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .{ .fm = fm, .body = bytes[body_start..], .title = title, .id = authored_id, .ok = false, .reason = "malformed_frontmatter" };
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!(std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "status") or std.mem.eql(u8, key, "tags"))) return .{ .fm = fm, .body = bytes[body_start..], .title = title, .id = authored_id, .ok = false, .reason = "unsupported_frontmatter_key" };
        if (value.len == 0 or std.mem.startsWith(u8, value, "{") or std.mem.startsWith(u8, value, "|") or std.mem.startsWith(u8, value, ">")) return .{ .fm = fm, .body = bytes[body_start..], .title = title, .id = authored_id, .ok = false, .reason = "unsupported_frontmatter_value" };
        if (std.mem.eql(u8, key, "title")) title = try a.dupe(u8, value);
        if (std.mem.eql(u8, key, "id")) authored_id = try a.dupe(u8, value);
    }
    return .{ .fm = fm, .body = bytes[body_start..], .title = title, .id = authored_id, .ok = true, .reason = "" };
}

/// Recognises only high-confidence MDX/ESM signals outside fenced and inline
/// code.  This is deliberately not an MDX parser: ambiguous material is
/// quarantined for human review instead of being interpreted or executed.
fn hasJsxComponent(s: []const u8) bool {
    const start = std.mem.indexOfScalar(u8, s, '<') orelse return false;
    return std.mem.indexOf(u8, s, "/>") != null or (start + 1 < s.len and std.ascii.isUpper(s[start + 1]));
}

fn hasMdxExpression(s: []const u8) bool {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return false;
    if (start + 1 >= s.len) return true;
    const next = s[start + 1];
    return std.ascii.isAlphabetic(next) or next == '_' or next == '$' or next == '[' or next == '.';
}

fn ordinaryMarkdown(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var fenced = false;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) continue;
        if (std.mem.startsWith(u8, t, "import ") or std.mem.startsWith(u8, t, "export ")) return "esm_syntax";
        if (std.mem.indexOf(u8, t, "client:") != null or std.mem.indexOf(u8, t, "server:") != null) return "framework_directive";
        var rest = t;
        while (rest.len > 0) {
            const tick = std.mem.indexOfScalar(u8, rest, '`') orelse break;
            const before = rest[0..tick];
            if (hasMdxExpression(before)) return "mdx_expression";
            if (hasJsxComponent(before)) return "jsx_component";
            const end = std.mem.indexOfScalar(u8, rest[tick + 1 ..], '`') orelse return "ambiguous_unclosed_inline_code";
            rest = rest[tick + 2 + end ..];
        }
        if (hasMdxExpression(rest)) return "mdx_expression";
        if (hasJsxComponent(rest)) return "jsx_component";
    }
    return null;
}

fn referenceInventory(a: std.mem.Allocator, body: []const u8) ![]const Reference {
    var found: std.ArrayList(Reference) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var fenced = false;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) { fenced = !fenced; continue; }
        if (fenced) continue;
        var rest = t;
        while (std.mem.indexOf(u8, rest, "](")) |start| {
            const bracket = std.mem.lastIndexOfScalar(u8, rest[0..start], '[');
            const image = if (bracket) |open| open > 0 and rest[open - 1] == '!' else false;
            rest = rest[start + 2 ..];
            const end = std.mem.indexOfScalar(u8, rest, ')') orelse {
                try found.append(a, .{ .kind = .review, .target = try a.dupe(u8, rest) });
                break;
            };
            const target = std.mem.trim(u8, rest[0..end], " \t");
            if (target.len > 0) {
                try found.append(a, .{ .kind = if (image) .markdown_image else .markdown_link, .target = try a.dupe(u8, target) });
                const kind: ReferenceKind = if (std.mem.startsWith(u8, target, "data:")) .data_url else if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) .remote else if (target[0] == '#') .fragment else if (target[0] == '/') .root_relative else .source_relative;
                try found.append(a, .{ .kind = kind, .target = try a.dupe(u8, target) });
            }
            rest = rest[end + 1 ..];
        }
    }
    std.mem.sort(Reference, found.items, {}, struct {
        fn less(_: void, x: Reference, y: Reference) bool {
            const k = std.mem.order(u8, @tagName(x.kind), @tagName(y.kind));
            return k == .lt or (k == .eq and std.mem.order(u8, x.target, y.target) == .lt);
        }
    }.less);
    return found.toOwnedSlice(a);
}

/// Scan every entry under the selected root.  There is intentionally no
/// catch-and-continue path here: a failed iterator, stat, read, or link read
/// aborts before Publication.begin is reached, so partial evidence is never
/// published.
fn scan(io: Io, a: std.mem.Allocator, root: Io.Dir, rel: []const u8, content_base: []const u8, project: []const u8, out: *std.ArrayList(Record)) !void {
    var dir = try root.openDir(io, if (rel.len == 0) "." else rel, .{ .iterate = true });
    defer dir.close(io);
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
        const stat = try root.statFile(io, path, .{ .follow_symlinks = false });
        const source_path = if (std.mem.eql(u8, path, content_base)) "" else path[content_base.len + 1 ..];
        if (stat.kind == .directory) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "directory", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .import_id = null, .action = .unsupported, .reason = "directory_inventory_only" });
            try scan(io, a, root, path, content_base, project, out);
            continue;
        }
        const is_mdx = std.mem.endsWith(u8, name, ".mdx");
        const is_md = std.mem.endsWith(u8, name, ".md");
        const is_astro = std.mem.endsWith(u8, name, ".astro");
        const id: ?[]const u8 = if (stat.kind == .file) try recordId(a, project, source_path) else null;
        if (stat.kind == .sym_link) {
            var target_buf: [4096]u8 = undefined;
            const target_len = try root.readLink(io, path, &target_buf);
            try out.append(a, .{ .source_path = source_path, .source_kind = "symlink", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .symlink_target = try a.dupe(u8, target_buf[0..target_len]), .import_id = null, .action = .quarantine, .reason = "symlink_rejected" });
            continue;
        }
        if (stat.kind != .file) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "unsupported_filesystem_object", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .import_id = null, .action = .unsupported, .reason = "unsupported_filesystem_object" });
            continue;
        }
        const data = try readFileAlloc(io, root, path, a);
        const byte_hash = try sha256Hex(a, data);
        if (is_mdx) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "mdx", .byte_hash = byte_hash, .frontmatter_hash = null, .body_hash = null, .import_id = id, .action = .quarantine, .reason = "mdx_not_parsed" });
            continue;
        }
        if (is_astro) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "astro", .byte_hash = byte_hash, .frontmatter_hash = null, .body_hash = null, .import_id = id, .action = .unsupported, .reason = "astro_not_parsed" });
            continue;
        }
        if (!is_md) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "regular_file", .byte_hash = byte_hash, .frontmatter_hash = null, .body_hash = null, .import_id = id, .action = .unsupported, .reason = "regular_file_not_supported" });
            continue;
        }
        const parsed = try parseFrontmatter(data, a);
        const fm_hash = try sha256Hex(a, parsed.fm);
        const body_hash = try sha256Hex(a, parsed.body);
        const syntax_reason = ordinaryMarkdown(parsed.body);
        const class: RecordClass = if (!parsed.ok or syntax_reason != null) .quarantine else .create;
        try out.append(a, .{ .source_path = source_path, .source_kind = "markdown", .byte_hash = byte_hash, .frontmatter_hash = fm_hash, .body_hash = body_hash, .import_id = id, .action = class, .reason = if (!parsed.ok) parsed.reason else if (syntax_reason) |reason| reason else "supported_plain_markdown", .title = parsed.title, .authored_id = parsed.id, .links = try referenceInventory(a, parsed.body) });
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

fn emitReferences(b: *std.ArrayList(u8), a: std.mem.Allocator, refs: []const Reference, wanted: ReferenceKind) !void {
    var first = true;
    for (refs) |reference| if (reference.kind == wanted) {
        if (!first) try b.append(a, ',');
        first = false;
        try appendJson(b, a, reference.target);
    };
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
        const route = if (std.mem.endsWith(u8, r.source_path, ".md")) r.source_path[0 .. r.source_path.len - 3] else r.source_path;
        try appendJson(&b, a, route);
        try b.appendSlice(a, ",\"route_evidence\":\"inferred_not_observed\",\"markdown_links\":[");
        try emitReferences(&b, a, r.links, .markdown_link);
        try b.appendSlice(a, "],\"markdown_image_references\":[");
        try emitReferences(&b, a, r.links, .markdown_image);
        try b.appendSlice(a, "],\"root_relative_references\":[");
        try emitReferences(&b, a, r.links, .root_relative);
        try b.appendSlice(a, "],\"source_relative_references\":[");
        try emitReferences(&b, a, r.links, .source_relative);
        try b.appendSlice(a, "],\"remote_references\":[");
        try emitReferences(&b, a, r.links, .remote);
        try b.appendSlice(a, "],\"fragment_references\":[");
        try emitReferences(&b, a, r.links, .fragment);
        try b.appendSlice(a, "],\"data_url_references\":[");
        try emitReferences(&b, a, r.links, .data_url);
        try b.appendSlice(a, "],\"references_requiring_review\":[");
        try emitReferences(&b, a, r.links, .review);
        try b.appendSlice(a, "],\"classification\":");
        try appendJson(&b, a, className(r.action));
        try b.appendSlice(a, ",\"evidence\":");
        try appendJson(&b, a, r.reason);
        try b.append(a, '}');
    }
    try b.appendSlice(a, "]}");
    return b.toOwnedSlice(a);
}

fn emitPlan(a: std.mem.Allocator, snapshot_digest: []const u8, policy: []const u8, previous_digest: ?[]const u8, records: []const Record) ![]u8 {
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
        const target: ?[]const u8 = if (r.action == .create or r.action == .keep) try std.fmt.allocPrint(a, "content/{s}", .{r.source_path}) else null;
        try appendJsonOrNull(&payload, a, target);
        if (target) |owned_target| a.free(owned_target);
        try payload.appendSlice(a, ",\"proposed_entity_id\":");
        const entity: ?[]const u8 = if (r.authored_id) |id| id else if (r.action == .create or r.action == .keep) r.source_path[0 .. r.source_path.len - 3] else null;
        try appendJsonOrNull(&payload, a, entity);
        try payload.appendSlice(a, ",\"authored_frontmatter_evidence\":");
        if (r.title) |title| try appendJson(&payload, a, title) else try payload.appendSlice(a, "null");
        try payload.appendSlice(a, ",\"proposed_closed_frontmatter\":");
        if (r.title) |title| {
            try payload.appendSlice(a, "{\"title\":");
            try appendJson(&payload, a, title);
            try payload.append(a, '}');
        } else try payload.appendSlice(a, "{}");
        try payload.appendSlice(a, ",\"inferred_source_route_candidate\":");
        const route = if (std.mem.endsWith(u8, r.source_path, ".md")) r.source_path[0 .. r.source_path.len - 3] else r.source_path;
        try appendJson(&payload, a, route);
        try payload.appendSlice(a, ",\"proposed_boris_route\":");
        try appendJson(&payload, a, route);
        try payload.appendSlice(a, ",\"route_compatibility\":\"inferred_not_observed\",\"preconditions\":[\"source hash remains unchanged\",\"future apply owns destination\"],\"loss_classification\":");
        try appendJson(&payload, a, if (r.action == .create or r.action == .keep) "review_required_not_applied" else "not_convertible");
        try payload.appendSlice(a, ",\"reason\":");
        try appendJson(&payload, a, r.reason);
        try payload.append(a, '}');
    }
    try payload.appendSlice(a, "],\"findings\":[]}");
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

fn emitReport(a: std.mem.Allocator, records: []const Record) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "# Astro import plan\n\nThis is a developer-only, plan-only report. It does not apply an import, modify sources, copy assets, execute Astro/Node/MDX, or observe routes. Complete machine-readable evidence is in `source_snapshot.json` and `import_plan.json`.\n\n## Aggregate counts\n\n");
    for (std.enums.values(RecordClass)) |class| {
        var count: usize = 0;
        for (records) |record| {
            if (record.action == class) count += 1;
        }
        const line = try std.fmt.allocPrint(a, "- `{s}`: {d}\n", .{ className(class), count });
        defer a.free(line);
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

/// A planner never selects a winner.  Any duplicate authored ID, generated
/// identity, proposed target/entity, or inferred route becomes an explicit
/// conflict row with the colliding source paths retained in the snapshot.
fn markConflicts(records: []Record) void {
    for (records, 0..) |*left, i| for (records[i + 1 ..]) |*right| {
        const same_authored = left.authored_id != null and right.authored_id != null and std.mem.eql(u8, left.authored_id.?, right.authored_id.?);
        const same_import = left.import_id != null and right.import_id != null and std.mem.eql(u8, left.import_id.?, right.import_id.?);
        const left_route = if (std.mem.endsWith(u8, left.source_path, ".md")) left.source_path[0 .. left.source_path.len - 3] else left.source_path;
        const right_route = if (std.mem.endsWith(u8, right.source_path, ".md")) right.source_path[0 .. right.source_path.len - 3] else right.source_path;
        const same_route = std.mem.eql(u8, left_route, right_route);
        if (same_authored or same_import or same_route) {
            left.action = .conflict;
            right.action = .conflict;
            left.reason = if (same_authored) "duplicate_source_authored_id" else if (same_import) "duplicate_generated_import_record_id" else "duplicate_inferred_route_candidate";
            right.reason = left.reason;
        }
    };
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
    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true });
    defer root.close(io);
    var records: std.ArrayList(Record) = .empty;
    try scan(io, a, root, opts.content_root, opts.content_root, opts.project_id, &records);
    sortRecords(records.items);
    markConflicts(records.items);
    for (records.items) |*r| {
        if (previousFor(previous, r.source_path)) |id| {
            if (r.import_id != null) {
                r.import_id = id;
                if (r.action == .create) r.action = .keep;
            }
        }
    }
    const tree = try sourceTreeFingerprint(a, records.items);
    const snapshot = try emitSnapshot(a, opts.project_id, opts.content_root, policy, tree, records.items);
    const snapshot_digest = try sha256Hex(a, snapshot);
    const plan = try emitPlan(a, snapshot_digest, policy, previous_digest, records.items);
    const report = try emitReport(a, records.items);
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
    try std.testing.expect(ordinaryMarkdown("```json\n{\"x\": 1}\n<Component />\n```\nInline `<Widget />` and `{json}`.") == null);
    try std.testing.expectEqualStrings("esm_syntax", ordinaryMarkdown("import Widget from './widget';").?);
    try std.testing.expectEqualStrings("mdx_expression", ordinaryMarkdown("Hello {name}.").?);
    try std.testing.expectEqualStrings("framework_directive", ordinaryMarkdown("<Card client:load />").?);
    try std.testing.expect(ordinaryMarkdown("<span>ordinary HTML</span>") == null);
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
        if (reference.kind == .markdown_link) links += 1;
        if (reference.kind == .markdown_image) images += 1;
        if (reference.kind == .source_relative) relative += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), links);
    try std.testing.expectEqual(@as(usize, 1), images);
    try std.testing.expectEqual(@as(usize, 1), relative);
}

test "tree fingerprint covers hidden paths, kinds, targets, and hashes" {
    const records = [_]Record{
        .{ .source_path = ".hidden", .source_kind = "regular_file", .byte_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .frontmatter_hash = null, .body_hash = null, .import_id = null, .action = .unsupported, .reason = "test" },
        .{ .source_path = "link", .source_kind = "symlink", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .symlink_target = "../target", .import_id = null, .action = .quarantine, .reason = "test" },
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
    const changed = [_]Record{records[0], .{ .source_path = "link", .source_kind = "symlink", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .symlink_target = "../other", .import_id = null, .action = .quarantine, .reason = "test" }};
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
    var records = [_]Record{
        .{ .source_path = "a.md", .source_kind = "markdown", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .import_id = "air_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .action = .create, .reason = "ok", .authored_id = "shared" },
        .{ .source_path = "b.md", .source_kind = "markdown", .byte_hash = null, .frontmatter_hash = null, .body_hash = null, .import_id = "air_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .action = .create, .reason = "ok", .authored_id = "shared" },
    };
    markConflicts(&records);
    try std.testing.expectEqual(RecordClass.conflict, records[0].action);
    try std.testing.expectEqual(RecordClass.conflict, records[1].action);
}

test "emitted snapshot and plan are structurally valid compact JSON" {
    const a = std.testing.allocator;
    const records = [_]Record{.{ .source_path = "page.md", .source_kind = "markdown", .byte_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .frontmatter_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .body_hash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .import_id = "air_dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .action = .create, .reason = "supported_plain_markdown" }};
    const snapshot = try emitSnapshot(a, "p", "content", "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", &records);
    defer a.free(snapshot);
    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
    defer parsed_snapshot.deinit();
    const digest = try sha256Hex(a, snapshot);
    defer a.free(digest);
    const plan = try emitPlan(a, digest, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", null, &records);
    defer a.free(plan);
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
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var records: std.ArrayList(Record) = .empty;
    try scan(io, scan_a, root, "content", "content", "fixture", &records);
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
