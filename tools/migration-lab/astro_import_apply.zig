//! Initial-create apply for reviewed Astro import plans.
//!
//! This intentionally consumes only the canonical Slice A evidence beside the
//! reviewed plan.  It has no re-import, merge, move, asset, MDX, or route
//! observation behavior.

const std = @import("std");
const Io = std.Io;
const plan = @import("astro_import_plan.zig");

pub const RunOptions = struct {
    root_dir: []const u8,
    content_root: []const u8,
    project_id: []const u8,
    plan_path: []const u8,
    destination: []const u8,
    quiet: bool = false,
};

const marker_name = ".boris-astro-import-owner";
const state_dir = ".boris-astro-import";
const marker_prefix = "format=boris-astro-import-apply\nschema_version=1\n";

fn sha256Hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const out = try a.alloc(u8, 64);
    const chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = chars[byte >> 4];
        out[i * 2 + 1] = chars[byte & 15];
    }
    return out;
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(a, .unlimited);
}

fn appendJson(b: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try b.append(a, '"');
    for (value) |c| switch (c) {
        '"' => try b.appendSlice(a, "\\\""),
        '\\' => try b.appendSlice(a, "\\\\"),
        '\n' => try b.appendSlice(a, "\\n"),
        '\r' => try b.appendSlice(a, "\\r"),
        '\t' => try b.appendSlice(a, "\\t"),
        else => if (c < 0x20) return error.InvalidPlan else try b.append(a, c),
    };
    try b.append(a, '"');
}

fn validRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return std.unicode.utf8ValidateSlice(path);
}

fn validEntity(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or !validRelative(id)) return false;
    for (id) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '#' or c == '?' or c == '%') return false;
    return true;
}

fn validHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn getString(object: anytype, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidPlan;
    if (value != .string) return error.InvalidPlan;
    return value.string;
}

fn getNullableString(object: anytype, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return error.InvalidPlan;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidPlan,
    };
}

fn requireNoDestination(io: Io, path: []const u8) !void {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
    return error.DestinationExists;
}

fn write(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn ownedStage(io: Io, a: std.mem.Allocator, stage_path: []const u8, marker: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, stage_path, .{}) catch return false;
    defer dir.close(io);
    const found = readFileAlloc(io, dir, marker_name, a) catch return false;
    defer a.free(found);
    return std.mem.eql(u8, found, marker);
}

fn stripSourceEnvelope(source: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, source, "---")) return source;
    const first_end = std.mem.indexOfScalar(u8, source, '\n') orelse return error.InvalidPlan;
    if (!std.mem.eql(u8, std.mem.trim(u8, source[0..first_end], "\r"), "---")) return source;
    var at = first_end + 1;
    while (at < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
        if (std.mem.eql(u8, std.mem.trim(u8, source[at..end], "\r"), "---")) return if (end < source.len) source[end + 1 ..] else source[end..];
        if (end == source.len) break;
        at = end + 1;
    }
    return error.InvalidPlan;
}

fn render(a: std.mem.Allocator, action: std.json.Value, source: []const u8) ![]u8 {
    const object = if (action == .object) action.object else return error.InvalidPlan;
    const frontmatter = object.get("proposed_closed_frontmatter") orelse return error.InvalidPlan;
    const fm = if (frontmatter == .object) frontmatter.object else return error.InvalidPlan;
    if (fm.count() > 4) return error.InvalidPlan;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "---\n");
    if (fm.get("id")) |value| {
        if (value != .string or !validEntity(value.string)) return error.InvalidPlan;
        try out.appendSlice(a, "id: ");
        try appendJson(&out, a, value.string);
        try out.append(a, '\n');
    }
    if (fm.get("title")) |value| {
        if (value != .string or value.string.len == 0 or value.string.len > 512) return error.InvalidPlan;
        try out.appendSlice(a, "title: ");
        try appendJson(&out, a, value.string);
        try out.append(a, '\n');
    }
    if (fm.get("status")) |value| {
        if (value != .string or !(std.mem.eql(u8, value.string, "draft") or std.mem.eql(u8, value.string, "published") or std.mem.eql(u8, value.string, "archived"))) return error.InvalidPlan;
        try out.appendSlice(a, "status: ");
        try out.appendSlice(a, value.string);
        try out.append(a, '\n');
    }
    if (fm.get("tags")) |value| {
        if (value != .array or value.array.items.len > 32) return error.InvalidPlan;
        try out.appendSlice(a, "tags: [");
        for (value.array.items, 0..) |tag, i| {
            if (tag != .string or tag.string.len == 0 or tag.string.len > 64) return error.InvalidPlan;
            if (i != 0) try out.appendSlice(a, ", ");
            try appendJson(&out, a, tag.string);
        }
        try out.appendSlice(a, "]\n");
    }
    try out.appendSlice(a, "---\n");
    try out.appendSlice(a, try stripSourceEnvelope(source));
    return out.toOwnedSlice(a);
}

fn snapshotRecordMatches(snapshot: std.json.Value, source_path: []const u8, source_hash: []const u8) bool {
    const root = if (snapshot == .object) snapshot.object else return false;
    const records = root.get("records") orelse return false;
    if (records != .array) return false;
    for (records.array.items) |record| {
        const object = if (record == .object) record.object else return false;
        const path = getString(object, "source_path") catch return false;
        const hash = getNullableString(object, "exact_byte_hash") catch return false;
        if (std.mem.eql(u8, path, source_path)) return hash != null and std.mem.eql(u8, hash.?, source_hash);
    }
    return false;
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!validRelative(opts.content_root) or !validRelative(opts.project_id) or !validRelative(opts.destination)) return error.InvalidApplyInput;
    try requireNoDestination(io, opts.destination);

    const plan_bytes = try readFileAlloc(io, Io.Dir.cwd(), opts.plan_path, a);
    const plan_dir = std.fs.path.dirname(opts.plan_path) orelse return error.InvalidPlan;
    const snapshot_path = try std.fs.path.join(a, &.{ plan_dir, "source_snapshot.json" });
    const snapshot_bytes = try readFileAlloc(io, Io.Dir.cwd(), snapshot_path, a);
    var parsed_plan = std.json.parseFromSlice(std.json.Value, a, plan_bytes, .{}) catch return error.InvalidPlan;
    defer parsed_plan.deinit();
    var parsed_snapshot = std.json.parseFromSlice(std.json.Value, a, snapshot_bytes, .{}) catch return error.InvalidPlan;
    defer parsed_snapshot.deinit();
    const root = if (parsed_plan.value == .object) parsed_plan.value.object else return error.InvalidPlan;
    if (root.count() != 2) return error.InvalidPlan;
    const digest = try getString(root, "plan_digest");
    const digest_input = root.get("digest_input") orelse return error.InvalidPlan;
    if (digest_input != .object or !validHash(digest)) return error.InvalidPlan;
    const digest_marker = std.mem.indexOf(u8, plan_bytes, ",\"digest_input\":") orelse return error.InvalidPlan;
    if (plan_bytes.len < digest_marker + 18 or plan_bytes[plan_bytes.len - 1] != '}') return error.InvalidPlan;
    const calculated = try sha256Hex(a, plan_bytes[digest_marker + ",\"digest_input\":".len .. plan_bytes.len - 1]);
    if (!std.mem.eql(u8, digest, calculated)) return error.InvalidPlan;
    const input = digest_input.object;
    if (input.count() != 9 or !std.mem.eql(u8, try getString(input, "format"), "boris-astro-import-plan") or
        input.get("schema_version") == null or input.get("schema_version").? != .integer or input.get("schema_version").?.integer != 1 or
        !std.mem.eql(u8, try getString(input, "digest_algorithm"), "sha256-lowercase-hex")) return error.InvalidPlan;
    const policy = try sha256Hex(a, plan.policy_bytes);
    if (!std.mem.eql(u8, try getString(input, "importer_policy_digest"), policy)) return error.InvalidPlan;
    const snapshot_digest = try sha256Hex(a, snapshot_bytes);
    if (!std.mem.eql(u8, try getString(input, "source_snapshot_digest"), snapshot_digest)) return error.InvalidPlan;
    const previous = input.get("previous_manifest_digest") orelse return error.InvalidPlan;
    if (previous != .null) return error.NotInitialImport;
    const snapshot_root = if (parsed_snapshot.value == .object) parsed_snapshot.value.object else return error.InvalidPlan;
    if (!std.mem.eql(u8, try getString(snapshot_root, "project_id"), opts.project_id) or !std.mem.eql(u8, try getString(snapshot_root, "selected_content_root"), opts.content_root) or !std.mem.eql(u8, try getString(snapshot_root, "policy_hash"), policy)) return error.InvalidPlan;
    try plan.verifyReviewedSnapshot(io, gpa, opts.root_dir, opts.content_root, opts.project_id, snapshot_bytes);

    const actions = input.get("proposed_actions") orelse return error.InvalidPlan;
    if (actions != .array) return error.InvalidPlan;
    var writable: std.ArrayList([]const u8) = .empty;
    var identities: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    for (actions.array.items) |action| {
        const object = if (action == .object) action.object else return error.InvalidPlan;
        const class = try getString(object, "class");
        if (std.mem.eql(u8, class, "quarantine") or std.mem.eql(u8, class, "unsupported")) continue;
        if (!std.mem.eql(u8, class, "create")) return error.UnsupportedPlanAction;
        const source_path = try getString(object, "source_path");
        const source_hash = try getString(object, "source_hash");
        const destination = try getString(object, "proposed_boris_source_path");
        const entity = try getString(object, "proposed_entity_id");
        const record_id = try getString(object, "import_record_id");
        if (!validRelative(source_path) or !validHash(source_hash) or !std.mem.startsWith(u8, destination, "content/") or !std.mem.endsWith(u8, destination, ".md") or !validRelative(destination) or !validEntity(entity) or !std.mem.startsWith(u8, record_id, "air_") or !validHash(record_id[4..]) or !snapshotRecordMatches(parsed_snapshot.value, source_path, source_hash)) return error.InvalidPlan;
        for (writable.items) |prior| if (std.mem.eql(u8, prior, destination)) return error.DuplicateDestination;
        for (identities.items) |prior| if (std.mem.eql(u8, prior, entity)) return error.DuplicateIdentity;
        for (sources.items) |prior| if (std.mem.eql(u8, prior, source_path)) return error.InvalidPlan;
        try writable.append(a, destination);
        try identities.append(a, entity);
        try sources.append(a, source_path);
    }

    const marker = try std.fmt.allocPrint(a, "{s}project_id={s}\nplan_digest={s}\n", .{ marker_prefix, opts.project_id, digest });
    const stage_path = try std.fmt.allocPrint(a, "{s}.boris-astro-import-stage", .{opts.destination});
    if (Io.Dir.cwd().statFile(io, stage_path, .{ .follow_symlinks = false })) |_| {
        if (!ownedStage(io, a, stage_path, marker)) return error.UnrecognizedStage;
        try Io.Dir.cwd().deleteTree(io, stage_path);
    } else |_| {}
    try Io.Dir.cwd().createDirPath(io, stage_path);
    var stage = try Io.Dir.cwd().openDir(io, stage_path, .{});
    defer stage.close(io);
    errdefer Io.Dir.cwd().deleteTree(io, stage_path) catch {};
    try write(io, stage, marker_name, marker);
    var source_root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false });
    defer source_root.close(io);
    var content = try source_root.openDir(io, opts.content_root, .{ .iterate = true, .follow_symlinks = false });
    defer content.close(io);
    var manifest: std.ArrayList(u8) = .empty;
    try manifest.appendSlice(a, "{\"format\":\"boris-astro-import-apply-manifest\",\"schema_version\":1,\"project_id\":");
    try appendJson(&manifest, a, opts.project_id);
    try manifest.appendSlice(a, ",\"plan_digest\":");
    try appendJson(&manifest, a, digest);
    try manifest.appendSlice(a, ",\"records\":[");
    var first = true;
    for (actions.array.items) |action| {
        const object = if (action == .object) action.object else return error.InvalidPlan;
        if (!std.mem.eql(u8, try getString(object, "class"), "create")) continue;
        const source_path = try getString(object, "source_path");
        const destination = try getString(object, "proposed_boris_source_path");
        const entity = try getString(object, "proposed_entity_id");
        const record_id = try getString(object, "import_record_id");
        const source_hash = try getString(object, "source_hash");
        const source = try readFileAlloc(io, content, source_path, a);
        if (!std.mem.eql(u8, try sha256Hex(a, source), source_hash)) return error.SourceChanged;
        const generated = try render(a, action, source);
        const generated_hash = try sha256Hex(a, generated);
        try write(io, stage, destination, generated);
        const blob = try std.fmt.allocPrint(a, "{s}/base/{s}.md", .{ state_dir, generated_hash });
        if (stage.statFile(io, blob, .{ .follow_symlinks = false })) |_| {} else |_| try write(io, stage, blob, generated);
        if (!first) try manifest.append(a, ',');
        first = false;
        try manifest.appendSlice(a, "{\"source_path\":");
        try appendJson(&manifest, a, source_path);
        try manifest.appendSlice(a, ",\"import_record_id\":");
        try appendJson(&manifest, a, record_id);
        try manifest.appendSlice(a, ",\"boris_destination_path\":");
        try appendJson(&manifest, a, destination);
        try manifest.appendSlice(a, ",\"entity_id\":");
        try appendJson(&manifest, a, entity);
        try manifest.appendSlice(a, ",\"source_byte_hash\":");
        try appendJson(&manifest, a, source_hash);
        try manifest.appendSlice(a, ",\"generated_byte_hash\":");
        try appendJson(&manifest, a, generated_hash);
        try manifest.appendSlice(a, ",\"base_blob_hash\":");
        try appendJson(&manifest, a, generated_hash);
        try manifest.append(a, '}');
    }
    try manifest.appendSlice(a, "]}");
    const manifest_digest = try sha256Hex(a, manifest.items);
    var manifest_outer: std.ArrayList(u8) = .empty;
    try manifest_outer.appendSlice(a, "{\"manifest_digest\":");
    try appendJson(&manifest_outer, a, manifest_digest);
    try manifest_outer.appendSlice(a, ",\"digest_input\":");
    try manifest_outer.appendSlice(a, manifest.items);
    try manifest_outer.append(a, '}');
    try write(io, stage, state_dir ++ "/manifest.json", manifest_outer.items);
    try requireNoDestination(io, opts.destination);
    try Io.Dir.cwd().rename(stage_path, Io.Dir.cwd(), opts.destination, io);
    if (!opts.quiet) std.debug.print("migration-lab: applied reviewed Astro plan to {s}\n", .{opts.destination});
}

test "renderer uses planned closed frontmatter and preserves body bytes" {
    const source = "---\r\ntitle: Source\r\n---\r\n[unchanged](./guide.md)\r\n`{literal}`\r\n";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"proposed_closed_frontmatter\":{\"id\":\"planned/page\",\"title\":\"Planned\",\"status\":\"published\",\"tags\":[\"one\",\"two\"]}}", .{});
    defer parsed.deinit();
    const got = try render(std.testing.allocator, parsed.value, source);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("---\nid: \"planned/page\"\ntitle: \"Planned\"\nstatus: published\ntags: [\"one\", \"two\"]\n---\n[unchanged](./guide.md)\r\n`{literal}`\r\n", got);
}
