//! Initial-create apply for reviewed Astro import plans.
//!
//! This intentionally consumes only the canonical Slice A evidence beside the
//! reviewed plan.  It has no re-import, merge, move, asset, MDX, or route
//! observation behavior.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const plan = @import("astro_import_plan.zig");
const publication = @import("publication.zig");
const boris_parser = @import("boris_parser");

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

const darwin = struct {
    extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: u32) c_int;
    const rename_excl: u32 = 0x00000004;
};

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

fn validWritableRelative(path: []const u8) bool {
    // `:` excludes Windows drive-relative forms such as `C:escape` as well
    // as drive-qualified forms. Slice A source evidence remains unchanged;
    // B1 simply refuses to publish an unsafe writable path on another host.
    return validRelative(path) and std.mem.indexOfScalar(u8, path, ':') == null;
}

fn validEntity(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or !validRelative(id)) return false;
    for (id) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '#' or c == '?' or c == '%') return false;
    return true;
}

fn validProjectId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
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
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.DestinationExists;
}

/// Publishes a directory without ever replacing an existing destination. On
/// Darwin, `renamex_np(RENAME_EXCL)` is the directory-safe atomic primitive;
/// Zig's generic `renamePreserve` is implemented with hard links and cannot
/// move directories there.
fn publishNoReplace(io: Io, a: std.mem.Allocator, stage_path: []const u8, destination: []const u8) !void {
    if (comptime builtin.os.tag == .macos) {
        const stage_z = try a.dupeZ(u8, stage_path);
        const destination_z = try a.dupeZ(u8, destination);
        if (darwin.renamex_np(stage_z.ptr, destination_z.ptr, darwin.rename_excl) != 0) return error.DestinationRace;
        return;
    }
    try Io.Dir.cwd().renamePreserve(stage_path, Io.Dir.cwd(), destination, io);
}

fn write(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn ownedStage(io: Io, a: std.mem.Allocator, stage_path: []const u8, marker: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, stage_path, .{ .follow_symlinks = false }) catch return false;
    defer dir.close(io);
    const found = readFileAlloc(io, dir, marker_name, a) catch return false;
    defer a.free(found);
    return std.mem.eql(u8, found, marker);
}

/// Reads one source record through a component-by-component no-follow walk.
/// The content-root capability and every source path segment are checked again
/// after the reviewed snapshot comparison, so apply never opens a different
/// file through a newly introduced symlink.
fn readVerifiedSourceFile(io: Io, content: Io.Dir, source_path: []const u8, a: std.mem.Allocator) ![]u8 {
    var current = content;
    var owned: ?Io.Dir = null;
    defer if (owned) |dir| dir.close(io);

    var rest = source_path;
    while (true) {
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const name = if (slash) |at| rest[0..at] else rest;
        if (name.len == 0) return error.InvalidPlan;
        if (slash == null) {
            const stat = try current.statFile(io, name, .{ .follow_symlinks = false });
            if (stat.kind == .sym_link) return error.SourceSymlink;
            if (stat.kind != .file) return error.InvalidPlan;
            var file = try current.openFile(io, name, .{ .follow_symlinks = false, .resolve_beneath = true });
            defer file.close(io);
            var reader = file.reader(io, &.{});
            return reader.interface.allocRemaining(a, .unlimited);
        }
        const stat = try current.statFile(io, name, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SourceSymlink;
        if (stat.kind != .directory) return error.InvalidPlan;
        const next = try current.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
        if (owned) |dir| dir.close(io);
        owned = next;
        current = next;
        rest = rest[slash.? + 1 ..];
    }
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

const SnapshotRecord = struct {
    authored_id: ?[]const u8,
};

fn snapshotCreateRecord(snapshot: std.json.Value, source_path: []const u8, source_hash: []const u8) !?SnapshotRecord {
    const root = if (snapshot == .object) snapshot.object else return error.InvalidPlan;
    const records = root.get("records") orelse return error.InvalidPlan;
    if (records != .array) return error.InvalidPlan;
    for (records.array.items) |record| {
        const object = if (record == .object) record.object else return error.InvalidPlan;
        const path = try getString(object, "source_path");
        const hash = try getNullableString(object, "exact_byte_hash");
        if (!std.mem.eql(u8, path, source_path)) continue;
        if (hash == null or !std.mem.eql(u8, hash.?, source_hash) or
            !std.mem.eql(u8, try getString(object, "source_kind"), "markdown") or
            !std.mem.eql(u8, try getString(object, "classification"), "create")) return null;
        return .{ .authored_id = try getNullableString(object, "source_authored_identity") };
    }
    return null;
}

fn validateClosedFrontmatter(action: std.json.ObjectMap) !void {
    const value = action.get("proposed_closed_frontmatter") orelse return error.InvalidPlan;
    const frontmatter = if (value == .object) value.object else return error.InvalidPlan;
    if (frontmatter.count() > 4) return error.InvalidPlan;
    const keys = [_][]const u8{ "id", "title", "status", "tags" };
    var it = frontmatter.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) known = true;
        }
        if (!known) return error.InvalidPlan;
    }
    if (frontmatter.get("id")) |id| if (id != .string or !validEntity(id.string)) return error.InvalidPlan;
    if (frontmatter.get("title")) |title| if (title != .string or title.string.len == 0 or title.string.len > 512) return error.InvalidPlan;
    if (frontmatter.get("status")) |status| if (status != .string or !(std.mem.eql(u8, status.string, "draft") or std.mem.eql(u8, status.string, "published") or std.mem.eql(u8, status.string, "archived"))) return error.InvalidPlan;
    if (frontmatter.get("tags")) |tags| {
        if (tags != .array or tags.array.items.len > 32) return error.InvalidPlan;
        for (tags.array.items) |tag| if (tag != .string or tag.string.len == 0 or tag.string.len > 64) return error.InvalidPlan;
    }
}

fn validateActionShape(action: std.json.Value) !std.json.ObjectMap {
    const object = if (action == .object) action.object else return error.InvalidPlan;
    if (object.count() != 14) return error.InvalidPlan;
    _ = try getString(object, "class");
    const source_path = try getString(object, "source_path");
    if (!validRelative(source_path)) return error.InvalidPlan;
    if (try getNullableString(object, "import_record_id")) |record_id| {
        if (!std.mem.startsWith(u8, record_id, "air_") or !validHash(record_id[4..])) return error.InvalidPlan;
    }
    if (try getNullableString(object, "source_hash")) |source_hash| if (!validHash(source_hash)) return error.InvalidPlan;
    _ = try getNullableString(object, "proposed_boris_source_path");
    _ = try getNullableString(object, "proposed_entity_id");
    _ = try getNullableString(object, "authored_frontmatter_evidence");
    try validateClosedFrontmatter(object);
    _ = try getNullableString(object, "inferred_source_route_candidate");
    _ = try getNullableString(object, "proposed_boris_route");
    if (!std.mem.eql(u8, try getString(object, "route_compatibility"), "inferred_not_observed")) return error.InvalidPlan;
    const preconditions = object.get("preconditions") orelse return error.InvalidPlan;
    if (preconditions != .array) return error.InvalidPlan;
    for (preconditions.array.items) |item| if (item != .string) return error.InvalidPlan;
    _ = try getString(object, "loss_classification");
    const reason = try getString(object, "reason");
    if (reason.len == 0 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidPlan;
    return object;
}

fn expectedRecordId(a: std.mem.Allocator, project_id: []const u8, source_path: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(a, "boris-astro-import-record-v1\n{s}\n{s}", .{ project_id, source_path });
    return sha256Hex(a, input);
}

const Prepared = struct {
    source_path: []const u8,
    source_hash: []const u8,
    destination: []const u8,
    entity: []const u8,
    record_id: []const u8,
    generated: []const u8,
    generated_hash: []const u8,
};

fn prepareCreate(
    io: Io,
    a: std.mem.Allocator,
    snapshot: std.json.Value,
    content: Io.Dir,
    project_id: []const u8,
    action: std.json.Value,
) !Prepared {
    const object = try validateActionShape(action);
    if (!std.mem.eql(u8, try getString(object, "class"), "create")) return error.InvalidPlan;
    const source_path = try getString(object, "source_path");
    const source_hash = (try getNullableString(object, "source_hash")) orelse return error.InvalidPlan;
    const destination = (try getNullableString(object, "proposed_boris_source_path")) orelse return error.InvalidPlan;
    const entity = (try getNullableString(object, "proposed_entity_id")) orelse return error.InvalidPlan;
    const record_id = (try getNullableString(object, "import_record_id")) orelse return error.InvalidPlan;
    const source_record = (try snapshotCreateRecord(snapshot, source_path, source_hash)) orelse return error.InvalidPlan;
    if (!std.mem.startsWith(u8, destination, "content/") or !std.mem.endsWith(u8, destination, ".md") or !validWritableRelative(destination) or
        !validEntity(entity)) return error.InvalidPlan;
    const expected_destination = try std.fmt.allocPrint(a, "content/{s}", .{source_path});
    if (!std.mem.eql(u8, destination, expected_destination)) return error.InvalidPlan;
    if (!std.mem.endsWith(u8, source_path, ".md")) return error.InvalidPlan;
    const route = source_path[0 .. source_path.len - 3];
    if (!validEntity(route) or !std.mem.eql(u8, try getString(object, "inferred_source_route_candidate"), route) or
        !std.mem.eql(u8, try getString(object, "proposed_boris_route"), route)) return error.InvalidPlan;
    const expected_entity = source_record.authored_id orelse route;
    if (!std.mem.eql(u8, entity, expected_entity)) return error.InvalidPlan;
    const expected_hash = try expectedRecordId(a, project_id, source_path);
    const expected_record_id = try std.fmt.allocPrint(a, "air_{s}", .{expected_hash});
    if (!std.mem.eql(u8, record_id, expected_record_id)) return error.InvalidPlan;
    const preconditions = object.get("preconditions").?.array.items;
    if (preconditions.len != 2 or !std.mem.eql(u8, preconditions[0].string, "source hash remains unchanged") or !std.mem.eql(u8, preconditions[1].string, "future apply owns destination") or
        !std.mem.eql(u8, try getString(object, "loss_classification"), "review_required_not_applied")) return error.InvalidPlan;

    const source = try readVerifiedSourceFile(io, content, source_path, a);
    if (!std.mem.eql(u8, try sha256Hex(a, source), source_hash)) return error.SourceChanged;
    const generated = try render(a, action, source);
    if (boris_parser.parse(generated).diagnostic != null) return error.GeneratedBorisValidationFailed;
    return .{
        .source_path = source_path,
        .source_hash = source_hash,
        .destination = destination,
        .entity = entity,
        .record_id = record_id,
        .generated = generated,
        .generated_hash = try sha256Hex(a, generated),
    };
}

fn validateNoWriteAction(action: std.json.Value) ![]const u8 {
    const object = try validateActionShape(action);
    const class = try getString(object, "class");
    if (!(std.mem.eql(u8, class, "quarantine") or std.mem.eql(u8, class, "unsupported"))) return error.UnsupportedPlanAction;
    // Slice A can retain proposed-path evidence on a quarantined row. It is
    // never writable state: apply emits no content, blobs, or manifest row
    // unless the class is exactly `create`.
    if (object.get("preconditions").?.array.items.len != 0 or !std.mem.eql(u8, try getString(object, "loss_classification"), "not_convertible")) return error.InvalidPlan;
    return try getString(object, "source_path");
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (!validRelative(opts.content_root) or !validProjectId(opts.project_id) or !validWritableRelative(opts.destination)) return error.InvalidApplyInput;
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
    const digest_prefix = "{\"plan_digest\":\"";
    const digest_marker = digest_prefix.len + digest.len + 1;
    if (!std.mem.startsWith(u8, plan_bytes, digest_prefix) or
        plan_bytes.len <= digest_marker + ",\"digest_input\":".len or
        !std.mem.startsWith(u8, plan_bytes[digest_marker..], ",\"digest_input\":") or
        plan_bytes[plan_bytes.len - 1] != '}') return error.InvalidPlan;
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

    // The destination must neither overlap reviewed inputs nor traverse a
    // symlink. This check happens before any owned stage can be created.
    try publication.validateRoots(io, a, opts.destination, &.{ opts.root_dir, opts.plan_path, snapshot_path });

    const actions = input.get("proposed_actions") orelse return error.InvalidPlan;
    if (actions != .array) return error.InvalidPlan;
    var writable: std.ArrayList([]const u8) = .empty;
    var identities: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    var prepared: std.ArrayList(Prepared) = .empty;
    var source_root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true, .follow_symlinks = false });
    defer source_root.close(io);
    var content = try plan.openSelectedContentRoot(io, source_root, opts.content_root);
    defer content.close(io);
    var previous_source: ?[]const u8 = null;
    for (actions.array.items) |action| {
        const object = try validateActionShape(action);
        const class = try getString(object, "class");
        const source_path = try getString(object, "source_path");
        if (previous_source) |prior| if (std.mem.order(u8, prior, source_path) != .lt) return error.InvalidPlan;
        previous_source = source_path;
        if (std.mem.eql(u8, class, "create")) {
            const item = try prepareCreate(io, a, parsed_snapshot.value, content, opts.project_id, action);
            for (writable.items) |prior| if (std.mem.eql(u8, prior, item.destination)) return error.DuplicateDestination;
            for (identities.items) |prior| if (std.mem.eql(u8, prior, item.entity)) return error.DuplicateIdentity;
            for (sources.items) |prior| if (std.mem.eql(u8, prior, item.source_path)) return error.InvalidPlan;
            try writable.append(a, item.destination);
            try identities.append(a, item.entity);
            try sources.append(a, item.source_path);
            try prepared.append(a, item);
        } else {
            _ = try validateNoWriteAction(action);
        }
    }

    const marker = try std.fmt.allocPrint(a, "{s}project_id={s}\nplan_digest={s}\n", .{ marker_prefix, opts.project_id, digest });
    const stage_path = try std.fmt.allocPrint(a, "{s}.boris-astro-import-stage", .{opts.destination});
    if (Io.Dir.cwd().statFile(io, stage_path, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .directory) return error.UnrecognizedStage;
        if (!ownedStage(io, a, stage_path, marker)) return error.UnrecognizedStage;
        try Io.Dir.cwd().deleteTree(io, stage_path);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try Io.Dir.cwd().createDirPath(io, stage_path);
    var stage_active = true;
    defer if (stage_active and ownedStage(io, a, stage_path, marker)) Io.Dir.cwd().deleteTree(io, stage_path) catch {};
    {
        var stage = try Io.Dir.cwd().openDir(io, stage_path, .{ .follow_symlinks = false });
        defer stage.close(io);
        try write(io, stage, marker_name, marker);
        var manifest: std.ArrayList(u8) = .empty;
        try manifest.appendSlice(a, "{\"format\":\"boris-astro-import-apply-manifest\",\"schema_version\":1,\"project_id\":");
        try appendJson(&manifest, a, opts.project_id);
        try manifest.appendSlice(a, ",\"plan_digest\":");
        try appendJson(&manifest, a, digest);
        try manifest.appendSlice(a, ",\"records\":[");
        for (prepared.items, 0..) |item, i| {
            try write(io, stage, item.destination, item.generated);
            const written = try readFileAlloc(io, stage, item.destination, a);
            if (!std.mem.eql(u8, written, item.generated) or !std.mem.eql(u8, try sha256Hex(a, written), item.generated_hash)) return error.StageVerificationFailed;
            const blob = try std.fmt.allocPrint(a, "{s}/base/{s}.md", .{ state_dir, item.generated_hash });
            if (stage.statFile(io, blob, .{ .follow_symlinks = false })) |_| {} else |err| switch (err) {
                error.FileNotFound => try write(io, stage, blob, item.generated),
                else => return err,
            }
            const base = try readFileAlloc(io, stage, blob, a);
            if (!std.mem.eql(u8, base, item.generated) or !std.mem.eql(u8, try sha256Hex(a, base), item.generated_hash)) return error.BaseBlobVerificationFailed;
            if (i != 0) try manifest.append(a, ',');
            try manifest.appendSlice(a, "{\"source_path\":");
            try appendJson(&manifest, a, item.source_path);
            try manifest.appendSlice(a, ",\"import_record_id\":");
            try appendJson(&manifest, a, item.record_id);
            try manifest.appendSlice(a, ",\"boris_destination_path\":");
            try appendJson(&manifest, a, item.destination);
            try manifest.appendSlice(a, ",\"entity_id\":");
            try appendJson(&manifest, a, item.entity);
            try manifest.appendSlice(a, ",\"source_byte_hash\":");
            try appendJson(&manifest, a, item.source_hash);
            try manifest.appendSlice(a, ",\"generated_byte_hash\":");
            try appendJson(&manifest, a, item.generated_hash);
            try manifest.appendSlice(a, ",\"base_blob_hash\":");
            try appendJson(&manifest, a, item.generated_hash);
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
        const persisted_manifest = try readFileAlloc(io, stage, state_dir ++ "/manifest.json", a);
        if (!std.mem.eql(u8, persisted_manifest, manifest_outer.items)) return error.StageVerificationFailed;
    }
    try requireNoDestination(io, opts.destination);
    try publishNoReplace(io, a, stage_path, opts.destination);
    stage_active = false;
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

test "writable paths reject cross-platform drive forms" {
    try std.testing.expect(!validWritableRelative("C:escape"));
    try std.testing.expect(!validWritableRelative("content/C:escape.md"));
    try std.testing.expect(!validWritableRelative("//server/share"));
}

fn cleanupTestTmp(io: Io, tmp: *std.testing.TmpDir) void {
    tmp.dir.close(io);
    tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
    tmp.parent_dir.close(io);
}

fn rewritePlanDigest(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const marker = ",\"digest_input\":";
    const at = std.mem.indexOf(u8, bytes, marker) orelse return error.InvalidPlan;
    const digest_input = bytes[at + marker.len .. bytes.len - 1];
    const digest = try sha256Hex(a, digest_input);
    defer a.free(digest);
    return std.fmt.allocPrint(a, "{{\"plan_digest\":\"{s}\"{s}{s}}}", .{ digest, marker, digest_input });
}

test "apply preflights the whole reviewed plan before staging and publishes verified bytes" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer cleanupTestTmp(io, &tmp);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/astro-apply", .{tmp.sub_path});
    defer a.free(base);
    const root = try std.fmt.allocPrint(a, "{s}/source", .{base});
    defer a.free(root);
    const plan_out = try std.fmt.allocPrint(a, "{s}/plan", .{base});
    defer a.free(plan_out);
    const destination = try std.fmt.allocPrint(a, "{s}/destination", .{base});
    defer a.free(destination);
    const source_path = try std.fmt.allocPrint(a, "{s}/src/content/docs/a.md", .{root});
    defer a.free(source_path);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(source_path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "---\ntitle: Planned\ntags: [one]\n---\n[unchanged](./guide.md)\n" });
    try plan.run(io, a, .{ .root_dir = root, .content_root = "src/content", .out_dir = plan_out, .project_id = "fixture", .quiet = true });
    const plan_path = try std.fmt.allocPrint(a, "{s}/import_plan.json", .{plan_out});
    defer a.free(plan_path);

    try run(io, a, .{ .root_dir = root, .content_root = "src/content", .project_id = "fixture", .plan_path = plan_path, .destination = destination, .quiet = true });
    var published = try Io.Dir.cwd().openDir(io, destination, .{});
    defer published.close(io);
    const generated = try readFileAlloc(io, published, "content/docs/a.md", a);
    defer a.free(generated);
    try std.testing.expectEqualStrings("---\ntitle: \"Planned\"\ntags: [\"one\"]\n---\n[unchanged](./guide.md)\n", generated);
    const manifest = try readFileAlloc(io, published, state_dir ++ "/manifest.json", a);
    defer a.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"manifest_digest\":") != null);

    const second_destination = try std.fmt.allocPrint(a, "{s}/second", .{base});
    defer a.free(second_destination);
    try Io.Dir.cwd().createDirPath(io, second_destination);
    var existing = try Io.Dir.cwd().openDir(io, second_destination, .{});
    defer existing.close(io);
    try existing.writeFile(io, .{ .sub_path = "sentinel", .data = "preserve" });
    try std.testing.expectError(error.DestinationExists, run(io, a, .{ .root_dir = root, .content_root = "src/content", .project_id = "fixture", .plan_path = plan_path, .destination = second_destination, .quiet = true }));
    const sentinel = try readFileAlloc(io, existing, "sentinel", a);
    defer a.free(sentinel);
    try std.testing.expectEqualStrings("preserve", sentinel);
    const stage = try std.fmt.allocPrint(a, "{s}.boris-astro-import-stage", .{second_destination});
    defer a.free(stage);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, stage, .{}));

    const original_plan = try readFileAlloc(io, Io.Dir.cwd(), plan_path, a);
    defer a.free(original_plan);
    var mutated = try a.dupe(u8, original_plan);
    defer a.free(mutated);
    const class_at = std.mem.indexOf(u8, mutated, "\"class\":\"create\"") orelse unreachable;
    @memcpy(mutated[class_at + "\"class\":\"".len .. class_at + "\"class\":\"".len + "create".len], "update");
    const tampered = try rewritePlanDigest(a, mutated);
    defer a.free(tampered);
    const tampered_path = try std.fmt.allocPrint(a, "{s}/tampered.json", .{plan_out});
    defer a.free(tampered_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tampered_path, .data = tampered });
    const rejected_destination = try std.fmt.allocPrint(a, "{s}/rejected", .{base});
    defer a.free(rejected_destination);
    try std.testing.expectError(error.UnsupportedPlanAction, run(io, a, .{ .root_dir = root, .content_root = "src/content", .project_id = "fixture", .plan_path = tampered_path, .destination = rejected_destination, .quiet = true }));
    const rejected_stage = try std.fmt.allocPrint(a, "{s}.boris-astro-import-stage", .{rejected_destination});
    defer a.free(rejected_stage);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, rejected_stage, .{}));
}
