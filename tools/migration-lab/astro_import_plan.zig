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
pub const policy_bytes =
    \\{"format":"boris-astro-import-policy","schema_version":1,"source_system":"astro","supported_frontmatter":["id","title","status","tags"],"supported_source":"explicit .md beneath --content-root with ordinary Markdown only","non_goals":["apply","asset-copy","mdx","route-observation","parent-inference"]}
;

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
    byte_hash: []const u8,
    frontmatter_hash: []const u8,
    body_hash: []const u8,
    import_id: []const u8,
    action: RecordClass,
    reason: []const u8,
    title: ?[]const u8 = null,
    authored_id: ?[]const u8 = null,
    assets: []const []const u8 = &.{},
};

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

fn ordinaryMarkdown(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "import ") or std.mem.startsWith(u8, t, "export ") or std.mem.indexOf(u8, t, "client:") != null) return false;
        if (std.mem.indexOf(u8, t, "{") != null or (std.mem.indexOf(u8, t, "<") != null and std.mem.indexOf(u8, t, "/>") != null)) return false;
    }
    return true;
}

fn assets(a: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var rest = body;
    while (std.mem.indexOf(u8, rest, "](")) |start| {
        rest = rest[start + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const target = std.mem.trim(u8, rest[0..end], " \t");
        if (target.len > 0 and !std.mem.startsWith(u8, target, "http://") and !std.mem.startsWith(u8, target, "https://") and !std.mem.startsWith(u8, target, "#")) try found.append(a, try a.dupe(u8, target));
        rest = rest[end + 1 ..];
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return found.toOwnedSlice(a);
}

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
        if (name.len == 0 or name[0] == '.') continue;
        const path = try join(a, rel, name);
        const stat = root.statFile(io, path, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind == .directory) {
            try scan(io, a, root, path, content_base, project, out);
            continue;
        }
        const is_mdx = std.mem.endsWith(u8, name, ".mdx");
        const is_md = std.mem.endsWith(u8, name, ".md");
        const is_astro = std.mem.endsWith(u8, name, ".astro");
        if (!(is_md or is_mdx or is_astro) and stat.kind != .sym_link) continue;
        const source_path = if (std.mem.eql(u8, path, content_base)) "" else path[content_base.len + 1 ..];
        const id = try recordId(a, project, source_path);
        if (stat.kind == .sym_link) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "symlink", .byte_hash = "", .frontmatter_hash = "", .body_hash = "", .import_id = id, .action = .quarantine, .reason = "symlink_rejected" });
            continue;
        }
        const data = try readFileAlloc(io, root, path, a);
        const byte_hash = try sha256Hex(a, data);
        if (is_mdx) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "mdx", .byte_hash = byte_hash, .frontmatter_hash = "", .body_hash = "", .import_id = id, .action = .quarantine, .reason = "mdx_not_supported" });
            continue;
        }
        if (is_astro) {
            try out.append(a, .{ .source_path = source_path, .source_kind = "astro", .byte_hash = byte_hash, .frontmatter_hash = "", .body_hash = "", .import_id = id, .action = .unsupported, .reason = "astro_component_not_supported" });
            continue;
        }
        const parsed = try parseFrontmatter(data, a);
        const fm_hash = try sha256Hex(a, parsed.fm);
        const body_hash = try sha256Hex(a, parsed.body);
        const class: RecordClass = if (!parsed.ok) .quarantine else if (!ordinaryMarkdown(parsed.body)) .quarantine else .create;
        try out.append(a, .{ .source_path = source_path, .source_kind = "markdown", .byte_hash = byte_hash, .frontmatter_hash = fm_hash, .body_hash = body_hash, .import_id = id, .action = class, .reason = if (!parsed.ok) parsed.reason else if (class == .quarantine) "framework_or_executable_syntax" else "supported_plain_markdown", .title = parsed.title, .authored_id = parsed.id, .assets = try assets(a, parsed.body) });
    }
}

fn parsePrevious(a: std.mem.Allocator, bytes: []const u8, project: []const u8, policy: []const u8) ![]Previous {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidPreviousManifest;
    const obj = if (parsed.value == .object) parsed.value.object else return error.InvalidPreviousManifest;
    const fmt = obj.get("format") orelse return error.InvalidPreviousManifest;
    const version = obj.get("schema_version") orelse return error.InvalidPreviousManifest;
    const pid = obj.get("project_id") orelse return error.InvalidPreviousManifest;
    const p_hash = obj.get("policy_digest") orelse return error.InvalidPreviousManifest;
    if (fmt != .string or version != .integer or pid != .string or p_hash != .string or !std.mem.eql(u8, fmt.string, "boris-astro-import-manifest") or version.integer != 1 or !std.mem.eql(u8, pid.string, project) or !std.mem.eql(u8, p_hash.string, policy)) return error.InvalidPreviousManifest;
    const entries = obj.get("records") orelse return error.InvalidPreviousManifest;
    if (entries != .array) return error.InvalidPreviousManifest;
    var result: std.ArrayList(Previous) = .empty;
    for (entries.array.items) |entry| {
        const e = if (entry == .object) entry.object else return error.InvalidPreviousManifest;
        const path = e.get("source_path") orelse return error.InvalidPreviousManifest;
        const rid = e.get("import_record_id") orelse return error.InvalidPreviousManifest;
        if (path != .string or rid != .string or !validRelative(path.string) or rid.string.len != 68 or !std.mem.startsWith(u8, rid.string, "air_")) return error.InvalidPreviousManifest;
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
        try appendJson(&b, a, r.byte_hash);
        try b.appendSlice(a, ",\"frontmatter_hash\":");
        try appendJson(&b, a, r.frontmatter_hash);
        try b.appendSlice(a, ",\"body_hash\":");
        try appendJson(&b, a, r.body_hash);
        try b.appendSlice(a, ",\"source_authored_identity\":");
        if (r.authored_id) |v| try appendJson(&b, a, v) else try b.appendSlice(a, "null");
        try b.appendSlice(a, ",\"inferred_route_candidate\":");
        const route = if (std.mem.endsWith(u8, r.source_path, ".md")) r.source_path[0 .. r.source_path.len - 3] else r.source_path;
        try appendJson(&b, a, route);
        try b.appendSlice(a, ",\"route_evidence\":\"inferred_not_observed\",\"discovered_asset_references\":[");
        for (r.assets, 0..) |asset, j| {
            if (j != 0) try b.append(a, ',');
            try appendJson(&b, a, asset);
        }
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
        try appendJson(&payload, a, r.import_id);
        try payload.appendSlice(a, ",\"source_path\":");
        try appendJson(&payload, a, r.source_path);
        try payload.appendSlice(a, ",\"source_hash\":");
        try appendJson(&payload, a, r.byte_hash);
        try payload.appendSlice(a, ",\"proposed_boris_source_path\":");
        const target = if (r.action == .create or r.action == .keep) try std.fmt.allocPrint(a, "content/{s}", .{r.source_path}) else "";
        try appendJson(&payload, a, target);
        try payload.appendSlice(a, ",\"proposed_entity_id\":");
        const entity = if (r.authored_id) |id| id else if (std.mem.endsWith(u8, r.source_path, ".md")) r.source_path[0 .. r.source_path.len - 3] else "";
        try appendJson(&payload, a, entity);
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
    try b.appendSlice(a, "# Astro import plan\n\nThis is a developer-only, plan-only report. It does not apply an import, modify sources, copy assets, execute Astro/Node/MDX, or observe routes.\n\n| Source | Action | Evidence |\n|---|---|---|\n");
    for (records) |r| {
        const row = try std.fmt.allocPrint(a, "| `{s}` | `{s}` | {s} |\n", .{ r.source_path, className(r.action), r.reason });
        defer a.free(row);
        try b.appendSlice(a, row);
    }
    return b.toOwnedSlice(a);
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
    for (records.items) |*r| {
        if (previousFor(previous, r.source_path)) |id| {
            r.import_id = id;
            if (r.action == .create) r.action = .keep;
        }
    }
    var tree_input: std.ArrayList(u8) = .empty;
    for (records.items) |r| {
        try tree_input.appendSlice(a, r.source_path);
        try tree_input.append(a, '\n');
        try tree_input.appendSlice(a, r.byte_hash);
        try tree_input.append(a, '\n');
    }
    const tree = try sha256Hex(a, tree_input.items);
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
