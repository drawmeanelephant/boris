const std = @import("std");
const contracts = @import("contracts.zig");

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 3;
    if (args.len != 5) {
        std.debug.print("usage: boris-editor-contract-probe ARTIFACT_DIR CHECK_JSON PLAN_JSON FRONTMATTER_SCHEMA\n", .{});
        return 2;
    }
    probe(init.io, allocator, args[1], args[2], args[3], args[4]) catch |err| {
        std.debug.print("contract probe failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("contract probe: ok\n", .{});
    return 0;
}

fn probe(io: std.Io, allocator: std.mem.Allocator, artifact_dir: []const u8, check_path: []const u8, plan_path: []const u8, schema_path: []const u8) !void {
    var artifacts = try std.Io.Dir.cwd().openDir(io, artifact_dir, .{});
    defer artifacts.close(io);
    try readAndCheck(allocator, io, artifacts, "completion.json", contracts.readCompletion);
    try readAndCheck(allocator, io, artifacts, "build-report.json", contracts.readBuildReport);
    try readAndCheck(allocator, io, artifacts, "manifest.json", contracts.readManifest);
    try readAndCheck(allocator, io, artifacts, "graph.json", contracts.readGraph);
    try readPathAndCheck(allocator, io, check_path, contracts.readDocumentationIntelligence);
    try readPathAndCheck(allocator, io, plan_path, contracts.readPublicationPlan);
    try readPathAndCheck(allocator, io, schema_path, contracts.readFrontmatterSchema);
}

fn readAndCheck(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, comptime reader: anytype) !void {
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var document = try reader(allocator, bytes);
    defer document.deinit();
}

fn readPathAndCheck(allocator: std.mem.Allocator, io: std.Io, path: []const u8, comptime reader: anytype) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var document = try reader(allocator, bytes);
    defer document.deinit();
}
