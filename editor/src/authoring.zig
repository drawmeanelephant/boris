//! Adapter-backed authoring vocabulary with no editor-owned grammar.

const std = @import("std");
const Io = std.Io;
const contracts = @import("contracts.zig");

const frontmatter_schema = @embedFile("frontmatter_schema");
const max_completion_bytes = 32 * 1024 * 1024;

pub fn render(allocator: std.mem.Allocator, io: Io, project_root: []const u8) ![]u8 {
    return renderPayload(allocator, try readCompletion(allocator, io, project_root));
}

fn renderPayload(allocator: std.mem.Allocator, completion_bytes: ?[]const u8) ![]u8 {
    var schema = contracts.readFrontmatterSchema(allocator, frontmatter_schema) catch return error.UnsupportedArtifact;
    defer schema.deinit();
    var completion: ?contracts.Document = null;
    if (completion_bytes) |bytes| completion = contracts.readCompletion(allocator, bytes) catch return error.UnsupportedArtifact;
    defer if (completion) |*document| document.deinit();
    return std.json.Stringify.valueAlloc(allocator, .{
        .frontmatter_schema = schema.parsed.value,
        .completion = if (completion) |document| document.parsed.value else null,
        .completion_status = if (completion != null) "ready" else "build_required",
    }, .{});
}

fn readCompletion(allocator: std.mem.Allocator, io: Io, project_root: []const u8) !?[]u8 {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    var artifact_dir = root.openDir(io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer artifact_dir.close(io);
    var file = artifact_dir.openFile(io, "completion.json", .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .limited(max_completion_bytes));
}

test "payload is derived from canonical Boris artifacts" {
    const bytes = try renderPayload(std.testing.allocator, @embedFile("completion_fixture"));
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ready", parsed.value.object.get("completion_status").?.string);
    try std.testing.expectEqualStrings("Boris frontmatter grammar (schema v1)", parsed.value.object.get("frontmatter_schema").?.object.get("title").?.string);
    try std.testing.expectEqualStrings("boris-completion-index", parsed.value.object.get("completion").?.object.get("format").?.string);
}

test "schema remains available without completion.json" {
    const bytes = try renderPayload(std.testing.allocator, null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"completion_status\":\"build_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"additionalProperties\":false") != null);
}
