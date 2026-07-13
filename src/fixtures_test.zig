//! Fixture inventory tests (milestone 2).
//!
//! Verifies that the fixture corpus and manifest are present and consistent.
//! Does **not** run a content compiler against the fixtures — that pipeline
//! is not implemented on the default CLI yet.

const std = @import("std");
const Io = std.Io;

/// Known content-error categories that must be documented in the fixture
/// manifest. Matches docs/contracts/diagnostics.md (content subset).
const required_categories = [_][]const u8{
    "EDUPLICATEID",
    "EPARENTMISSING",
    "EPARENTSELF",
    "EPARENTNOTTRUNK",
    "EPARENTCYCLE",
    "EFRONTMATTER",
    "EINVALIDUTF8",
    "EINVALIDPATH",
};

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn pathExists(io: Io, dir: Io.Dir, rel: []const u8) bool {
    dir.access(io, rel, .{}) catch return false;
    return true;
}

fn openFixtures(io: Io) !Io.Dir {
    return Io.Dir.cwd().openDir(io, "fixtures", .{}) catch |err| {
        std.log.err("open fixtures/: {s} (run tests with cwd at package root)", .{@errorName(err)});
        return err;
    };
}

test "fixtures: root directory is openable" {
    const io = std.testing.io;
    var fixtures = try openFixtures(io);
    defer fixtures.close(io);
    try std.testing.expect(pathExists(io, fixtures, "manifest.json"));
    try std.testing.expect(pathExists(io, fixtures, "README.md"));
    try std.testing.expect(pathExists(io, fixtures, "expected/invalid-categories.txt"));
}

test "fixtures: valid content files listed in manifest exist" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var fixtures = try openFixtures(io);
    defer fixtures.close(io);

    const raw = try readFileAlloc(io, fixtures, "manifest.json", allocator);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const valid = root.get("valid").?.array;

    try std.testing.expect(valid.items.len >= 4);

    for (valid.items) |item| {
        const path = item.object.get("path").?.string;
        try std.testing.expect(pathExists(io, fixtures, path));
    }
}

test "fixtures: invalid suite files exist and categories are documented" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var fixtures = try openFixtures(io);
    defer fixtures.close(io);

    const raw = try readFileAlloc(io, fixtures, "manifest.json", allocator);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const invalid = root.get("invalid").?.array;
    const required = root.get("requiredInvalidCategories").?.array;

    try std.testing.expect(invalid.items.len >= required_categories.len);

    var seen_categories: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_categories.deinit(allocator);

    for (invalid.items) |item| {
        const obj = item.object;
        const category = obj.get("expectedCategory").?.string;
        try seen_categories.put(allocator, category, {});

        const paths = obj.get("paths").?.array;
        try std.testing.expect(paths.items.len >= 1);
        for (paths.items) |p| {
            try std.testing.expect(pathExists(io, fixtures, p.string));
        }
    }

    for (required.items) |item| {
        try std.testing.expect(seen_categories.contains(item.string));
    }

    for (required_categories) |code| {
        try std.testing.expect(seen_categories.contains(code));
    }
}

test "fixtures: expected/invalid-categories.txt matches required set" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var fixtures = try openFixtures(io);
    defer fixtures.close(io);

    const raw = try readFileAlloc(io, fixtures, "expected/invalid-categories.txt", allocator);
    defer allocator.free(raw);

    var found: std.StringHashMapUnmanaged(void) = .empty;
    defer found.deinit(allocator);

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try found.put(allocator, line, {});
    }

    for (required_categories) |code| {
        try std.testing.expect(found.contains(code));
    }
    try std.testing.expectEqual(@as(usize, required_categories.len), found.count());
}

test "fixtures: invalid-utf8 fixture is not valid UTF-8" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var fixtures = try openFixtures(io);
    defer fixtures.close(io);

    const raw = try readFileAlloc(io, fixtures, "content/invalid/invalid-utf8.md", allocator);
    defer allocator.free(raw);

    try std.testing.expect(raw.len > 0);
    try std.testing.expect(!std.unicode.utf8ValidateSlice(raw));
}

test "fixtures: empty-no-fm is empty and has no frontmatter fence" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var fixtures = try openFixtures(io);
    defer fixtures.close(io);

    const raw = try readFileAlloc(io, fixtures, "content/valid/empty-no-fm.md", allocator);
    defer allocator.free(raw);

    // Contract: empty page with no frontmatter is allowed.
    try std.testing.expectEqual(@as(usize, 0), raw.len);
}
