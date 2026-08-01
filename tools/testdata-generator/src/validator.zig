//! Structural fixture validation and compact inspection summaries.

const std = @import("std");
const barbs = @import("barbs.zig");
const manifest = @import("manifest.zig");

const Io = std.Io;

pub const Report = struct {
    fixture: []const u8,
    schema_version: []u8 = &.{},
    profile: []u8 = &.{},
    page_count: usize = 0,
    listed_files: usize = 0,
    checked_files: usize = 0,
    total_bytes: u64 = 0,
    expected_exit_code: u8 = 0,
    barb_count: usize = 0,
    surface_errors: usize = 0,
    graph_errors: usize = 0,
    ok: bool = true,
    error_message: []const u8 = "",

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        if (self.schema_version.len > 0) allocator.free(self.schema_version);
        if (self.profile.len > 0) allocator.free(self.profile);
        self.* = undefined;
    }
};

pub fn validate(io: Io, allocator: std.mem.Allocator, fixture_path: []const u8) !Report {
    const fixture_abs = try resolvePath(io, allocator, fixture_path);
    defer allocator.free(fixture_abs);
    var fixture = try Io.Dir.openDirAbsolute(io, fixture_abs, .{});
    defer fixture.close(io);

    var report = Report{ .fixture = fixture_path };
    const manifest_bytes = readFile(io, allocator, fixture, "manifest.json", 1024 * 1024) catch return invalidReport(report, "manifest.json is missing or unreadable");
    defer allocator.free(manifest_bytes);
    const expected_bytes = readFile(io, allocator, fixture, "expected.json", 1024 * 1024) catch return invalidReport(report, "expected.json is missing or unreadable");
    defer allocator.free(expected_bytes);
    const files_bytes = readFile(io, allocator, fixture, "files.jsonl", 512 * 1024 * 1024) catch return invalidReport(report, "files.jsonl is missing or unreadable");
    defer allocator.free(files_bytes);

    const parsed_manifest = std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{}) catch return invalidReport(report, "manifest.json is not valid JSON");
    defer parsed_manifest.deinit();
    const parsed_expected = std.json.parseFromSlice(std.json.Value, allocator, expected_bytes, .{}) catch return invalidReport(report, "expected.json is not valid JSON");
    defer parsed_expected.deinit();

    const manifest_object = switch (parsed_manifest.value) {
        .object => |object| object,
        else => return invalidReport(report, "manifest.json must be an object"),
    };
    const expected_object = switch (parsed_expected.value) {
        .object => |object| object,
        else => return invalidReport(report, "expected.json must be an object"),
    };
    const expected_schema = stringField(expected_object, "schemaVersion") orelse return invalidReport(report, "expected schemaVersion is missing");
    if (!std.mem.eql(u8, expected_schema, "boris-testdata-expected/2")) return invalidReport(report, "expected schemaVersion is unsupported");
    if (!expectedBarbsValid(expected_object)) return invalidReport(report, "expected barb oracle is inconsistent");
    const schema_version = stringField(manifest_object, "schemaVersion") orelse return invalidReport(report, "manifest schemaVersion is missing");
    const profile = stringField(manifest_object, "profile") orelse return invalidReport(report, "manifest profile is missing");
    report.schema_version = try allocator.dupe(u8, schema_version);
    report.profile = try allocator.dupe(u8, profile);
    if (!std.mem.eql(u8, report.schema_version, manifest.schema_version)) return invalidReport(report, "manifest schemaVersion is unsupported");
    report.page_count = intField(manifest_object, "pageCount") orelse return invalidReport(report, "manifest pageCount is missing");

    const expected_hash = manifest.sha256Hex(expected_bytes);
    const expected_meta = objectField(manifest_object, "expected") orelse return invalidReport(report, "manifest expected metadata is missing");
    const expected_hash_text = stringField(expected_meta, "sha256") orelse return invalidReport(report, "manifest expected hash is missing");
    if (!std.mem.eql(u8, expected_hash_text, &expected_hash)) return invalidReport(report, "expected.json hash does not match manifest");

    report.expected_exit_code = expectedExitCode(expected_object) orelse return invalidReport(report, "expected run exit code is missing");
    report.barb_count = arrayLen(expected_object, "barbs") orelse return invalidReport(report, "expected barbs array is missing");

    const file_meta = objectField(manifest_object, "files") orelse return invalidReport(report, "manifest files metadata is missing");
    const declared_count = intField(file_meta, "count") orelse return invalidReport(report, "manifest file count is missing");
    const declared_bytes = intField(file_meta, "bytes") orelse return invalidReport(report, "manifest file byte count is missing");
    const declared_hash = stringField(file_meta, "sha256") orelse return invalidReport(report, "manifest files hash is missing");
    const files_hash = manifest.sha256Hex(files_bytes);
    if (!std.mem.eql(u8, declared_hash, &files_hash)) return invalidReport(report, "files.jsonl hash does not match manifest");

    const graph_expected = expectedHasGraphBarb(expected_object);
    var pages: std.ArrayList(PageMeta) = .empty;
    defer pages.deinit(allocator);
    defer {
        for (pages.items) |page| {
            allocator.free(page.id);
            if (page.parent) |parent| allocator.free(parent);
        }
    }
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, files_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_number += 1;
        const parsed_line = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return invalidReport(report, "files.jsonl contains invalid JSON");
        defer parsed_line.deinit();
        const object = switch (parsed_line.value) {
            .object => |value| value,
            else => return invalidReport(report, "files.jsonl line is not an object"),
        };
        const path = stringField(object, "path") orelse return invalidReport(report, "files.jsonl path is missing");
        if (!safeRelativePath(path)) return invalidReport(report, "files.jsonl contains an unsafe path");
        const bytes = readFile(io, allocator, fixture, path, 64 * 1024 * 1024) catch return invalidReport(report, "files.jsonl names a missing file");
        defer allocator.free(bytes);
        const declared_file_bytes = intField(object, "bytes") orelse return invalidReport(report, "files.jsonl byte count is missing");
        const declared_file_hash = stringField(object, "sha256") orelse return invalidReport(report, "files.jsonl hash is missing");
        const actual_hash = manifest.sha256Hex(bytes);
        if (declared_file_bytes != bytes.len or !std.mem.eql(u8, declared_file_hash, &actual_hash)) return invalidReport(report, "files.jsonl file metadata does not match bytes");
        if (std.mem.eql(u8, stringField(object, "kind") orelse "", "page")) {
            const id = stringField(object, "id") orelse return invalidReport(report, "page inventory row has no id");
            const owned_id = try allocator.dupe(u8, id);
            errdefer allocator.free(owned_id);
            const parent = if (stringField(object, "parent")) |value| try allocator.dupe(u8, value) else null;
            errdefer if (parent) |value| allocator.free(value);
            const surface = inspectPage(bytes, id, parent);
            if (!surface.valid) report.surface_errors += 1;
            if (surface.valid and surface.semantic_errors > 0) report.surface_errors += surface.semantic_errors;
            try pages.append(allocator, .{ .id = owned_id, .parent = parent });
        }
        report.checked_files += 1;
        report.total_bytes += bytes.len;
    }
    report.listed_files = line_number;

    if (report.listed_files != declared_count) return invalidReport(report, "manifest file count does not match files.jsonl");
    if (report.total_bytes != declared_bytes) return invalidReport(report, "manifest file byte count does not match files.jsonl");

    if (pages.items.len != report.page_count) return invalidReport(report, "page count does not match files.jsonl");

    const graph_errors = try validateGraph(allocator, pages.items);
    report.graph_errors = graph_errors;
    if ((graph_errors > 0) != graph_expected) return invalidReport(report, "graph barb expectation does not match page metadata");
    if (report.expected_exit_code == 0 and report.surface_errors != 0) return invalidReport(report, "successful fixture contains malformed page bytes");

    return report;
}

pub fn inspect(io: Io, allocator: std.mem.Allocator, fixture_path: []const u8) !Report {
    // Inspection intentionally shares the validator's control-file parsing so
    // An inspection summary cannot describe a fixture whose hashes are stale.
    return validate(io, allocator, fixture_path);
}

fn invalidReport(report: Report, message: []const u8) Report {
    var invalid = report;
    invalid.ok = false;
    invalid.error_message = message;
    return invalid;
}

fn resolvePath(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn readFile(io: Io, allocator: std.mem.Allocator, directory: Io.Dir, path: []const u8, limit: usize) ![]u8 {
    var file = try directory.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8) ?usize {
    return switch (object.get(key) orelse return null) {
        .integer => |value| if (value >= 0) @intCast(value) else null,
        else => null,
    };
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (object.get(key) orelse return null) {
        .object => |value| value,
        else => null,
    };
}

fn arrayLen(object: std.json.ObjectMap, key: []const u8) ?usize {
    return switch (object.get(key) orelse return null) {
        .array => |value| value.items.len,
        else => null,
    };
}

fn expectedExitCode(object: std.json.ObjectMap) ?u8 {
    const run = objectField(object, "run") orelse return null;
    const value = intField(run, "expectedExitCode") orelse return null;
    if (value > 255) return null;
    return @intCast(value);
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

const PageMeta = struct {
    id: []const u8,
    parent: ?[]const u8,
};

const SurfaceReport = struct {
    valid: bool,
    semantic_errors: usize = 0,
};

fn inspectPage(bytes: []const u8, expected_id: []const u8, expected_parent: ?[]const u8) SurfaceReport {
    if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .valid = false };
    if (!std.mem.startsWith(u8, bytes, "---\n")) return .{ .valid = false };
    const close = std.mem.indexOfPos(u8, bytes, 4, "\n---\n") orelse return .{ .valid = false };
    var id: ?[]const u8 = null;
    var parent: ?[]const u8 = null;
    var semantic_errors: usize = 0;
    var seen_id = false;
    var seen_parent = false;
    var lines = std.mem.splitScalar(u8, bytes[4..close], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            semantic_errors += 1;
            continue;
        };
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (!isKnownFrontmatterKey(key) or value.len == 0) {
            semantic_errors += 1;
            continue;
        }
        if (std.mem.eql(u8, key, "id")) {
            if (seen_id) semantic_errors += 1;
            seen_id = true;
            id = value;
        } else if (std.mem.eql(u8, key, "parent")) {
            if (seen_parent) semantic_errors += 1;
            seen_parent = true;
            parent = value;
        }
    }
    if (id == null or !std.mem.eql(u8, id.?, expected_id)) semantic_errors += 1;
    if (!optionalEqual(parent, expected_parent)) semantic_errors += 1;
    return .{ .valid = true, .semantic_errors = semantic_errors };
}

fn isKnownFrontmatterKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "id") or
        std.mem.eql(u8, key, "title") or
        std.mem.eql(u8, key, "parent") or
        std.mem.eql(u8, key, "status") or
        std.mem.eql(u8, key, "tags") or
        std.mem.eql(u8, key, "relations") or
        std.mem.eql(u8, key, "published_at") or
        std.mem.eql(u8, key, "summary");
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn validateGraph(allocator: std.mem.Allocator, pages: []const PageMeta) !usize {
    var ids = std.StringHashMap(usize).init(allocator);
    defer ids.deinit();
    var errors: usize = 0;
    for (pages, 0..) |page, index| {
        if (ids.contains(page.id)) {
            errors += 1;
        } else {
            try ids.put(page.id, index);
        }
    }
    for (pages) |page| {
        if (page.parent) |parent| {
            if (std.mem.eql(u8, parent, page.id)) errors += 1;
            if (!ids.contains(parent)) errors += 1;
        }
    }

    var state = try allocator.alloc(u8, pages.len);
    defer allocator.free(state);
    @memset(state, 0);
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);
    for (pages, 0..) |_, start| {
        if (state[start] != 0) continue;
        var current = start;
        while (true) {
            if (state[current] == 2) break;
            if (state[current] == 1) {
                errors += 1;
                break;
            }
            state[current] = 1;
            try path.append(allocator, current);
            const parent = pages[current].parent orelse break;
            current = ids.get(parent) orelse break;
        }
        for (path.items) |node| {
            state[node] = 2;
        }
        path.clearRetainingCapacity();
    }
    return errors;
}

fn expectedHasGraphBarb(object: std.json.ObjectMap) bool {
    const values = switch (object.get("barbs") orelse return false) {
        .array => |value| value.items,
        else => return false,
    };
    for (values) |value| {
        const barb_object = switch (value) {
            .object => |object_value| object_value,
            else => continue,
        };
        const name = stringField(barb_object, "name") orelse continue;
        if (std.mem.eql(u8, name, barbs.name(.duplicate_id)) or
            std.mem.eql(u8, name, barbs.name(.self_parent)) or
            std.mem.eql(u8, name, barbs.name(.missing_parent)) or
            std.mem.eql(u8, name, barbs.name(.parent_cycle))) return true;
    }
    return false;
}

fn expectedBarbsValid(object: std.json.ObjectMap) bool {
    const values = switch (object.get("barbs") orelse return false) {
        .array => |value| value.items,
        else => return false,
    };
    for (values) |value| {
        const barb_object = switch (value) {
            .object => |object_value| object_value,
            else => return false,
        };
        const name_value = stringField(barb_object, "name") orelse return false;
        const kind = barbs.parse(name_value) catch return false;
        const behavior_value = stringField(barb_object, "behavior") orelse return false;
        if (!std.mem.eql(u8, behavior_value, barbs.expectedLabel(kind))) return false;
        const phase_value = stringField(barb_object, "phase") orelse return false;
        if (!std.mem.eql(u8, phase_value, @tagName(barbs.phase(kind)))) return false;
        const coverage_value = stringField(barb_object, "expectedCoverage") orelse return false;
        if (!std.mem.eql(u8, coverage_value, barbs.expectedCoverage(kind))) return false;
        const repair_value = stringField(barb_object, "repair") orelse return false;
        if (!std.mem.eql(u8, repair_value, barbs.repair(kind))) return false;
        const actual_finding = barb_object.get("findingCode") orelse return false;
        if (barbs.expectedFindingCode(kind)) |expected_finding| {
            const actual_text = switch (actual_finding) {
                .string => |text| text,
                else => return false,
            };
            if (!std.mem.eql(u8, actual_text, expected_finding)) return false;
        } else switch (actual_finding) {
            .null => {},
            else => return false,
        }
    }
    return true;
}

test "validator accepts a generated control-file shape after generation" {
    // Full generation is exercised by the CLI integration commands; this test
    // locks the path policy independently of filesystem behavior.
    try std.testing.expect(safeRelativePath("content/guides/guide-0000.md"));
    try std.testing.expect(!safeRelativePath("../escape"));
    try std.testing.expect(!safeRelativePath("content\\escape"));
}
