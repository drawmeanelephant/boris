//! Adapter-backed graph inspector payload. The host forwards Boris graph.json
//! after contract validation and does not invent nodes, edges, or backlinks.

const std = @import("std");
const Io = std.Io;
const contracts = @import("contracts.zig");

const max_graph_bytes = 32 * 1024 * 1024;

pub fn render(allocator: std.mem.Allocator, io: Io, project_root: []const u8) ![]u8 {
    return renderPayload(allocator, try readGraph(allocator, io, project_root));
}

fn renderPayload(allocator: std.mem.Allocator, graph_bytes: ?[]const u8) ![]u8 {
    var graph: ?contracts.Document = null;
    if (graph_bytes) |bytes| graph = contracts.readGraph(allocator, bytes) catch return error.UnsupportedArtifact;
    defer if (graph) |*document| document.deinit();
    return std.json.Stringify.valueAlloc(allocator, .{
        .graph = if (graph) |document| document.parsed.value else null,
        .graph_status = if (graph != null) "ready" else "build_required",
    }, .{});
}

fn readGraph(allocator: std.mem.Allocator, io: Io, project_root: []const u8) !?[]u8 {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    var artifact_dir = root.openDir(io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer artifact_dir.close(io);
    var file = artifact_dir.openFile(io, "graph.json", .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .limited(max_graph_bytes));
}

test "payload is the validated Boris graph.json" {
    const bytes = try renderPayload(std.testing.allocator, @embedFile("graph_fixture"));
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ready", parsed.value.object.get("graph_status").?.string);
    const graph = parsed.value.object.get("graph").?.object;
    try std.testing.expectEqualStrings("0.2.0", graph.get("schemaVersion").?.string);
    try std.testing.expect(graph.get("frozen").?.bool);
    try std.testing.expect(graph.get("nodes").?.array.items.len == 3);
    try std.testing.expect(graph.get("edges").?.array.items.len == 1);
    try std.testing.expect(graph.get("reverseIndex").?.array.items.len == 1);
    try std.testing.expect(graph.get("nav").?.array.items.len == 3);
}

test "graph remains optional until Boris publishes graph.json" {
    const bytes = try renderPayload(std.testing.allocator, null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"graph_status\":\"build_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"graph\":null") != null);
}

test "unsupported graph.json is not rewritten" {
    try std.testing.expectError(error.UnsupportedArtifact, renderPayload(std.testing.allocator, "{\"schemaVersion\":\"9.9.9\"}"));
}
