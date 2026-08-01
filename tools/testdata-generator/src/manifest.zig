//! Deterministic fixture-control files and the streaming file inventory.

const std = @import("std");
const barbs = @import("barbs.zig");
const graph = @import("graph.zig");

pub const schema_version = "boris-testdata/2";
pub const generator_version = "boris-testdata/0.3.0";

pub const HashText = [64]u8;

pub const InventorySummary = struct {
    count: usize,
    total_bytes: u64,
    sha256: HashText,
};

pub fn sha256Hex(bytes: []const u8) HashText {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digestToHex(digest);
}

pub fn digestToHex(digest: [32]u8) HashText {
    var text: HashText = undefined;
    const chars = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        text[index * 2] = chars[byte >> 4];
        text[index * 2 + 1] = chars[byte & 0x0f];
    }
    return text;
}

pub const Inventory = struct {
    io: std.Io,
    file: std.Io.File,
    hasher: std.crypto.hash.sha2.Sha256,
    count: usize = 0,
    total_bytes: u64 = 0,

    pub fn open(io: std.Io, directory: std.Io.Dir) !Inventory {
        return openNamed(io, directory, "files.jsonl");
    }

    pub fn openNamed(io: std.Io, directory: std.Io.Dir, name: []const u8) !Inventory {
        return .{
            .io = io,
            .file = try directory.createFile(io, name, .{}),
            .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
    }

    pub fn close(self: *Inventory) InventorySummary {
        self.file.close(self.io);
        var digest: [32]u8 = undefined;
        self.hasher.final(&digest);
        return .{
            .count = self.count,
            .total_bytes = self.total_bytes,
            .sha256 = digestToHex(digest),
        };
    }

    pub fn add(
        self: *Inventory,
        allocator: std.mem.Allocator,
        path: []const u8,
        kind: []const u8,
        bytes: []const u8,
        id: ?[]const u8,
        role: ?[]const u8,
        parent: ?[]const u8,
    ) !void {
        const next_count = std.math.add(usize, self.count, 1) catch return error.InventoryOverflow;
        const next_total_bytes = std.math.add(u64, self.total_bytes, @intCast(bytes.len)) catch return error.InventoryOverflow;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);

        try line.appendSlice(allocator, "{\"path\":");
        try appendJsonString(&line, allocator, path);
        try line.appendSlice(allocator, ",\"kind\":");
        try appendJsonString(&line, allocator, kind);
        try line.appendSlice(allocator, ",\"bytes\":");
        try appendDecimal(&line, allocator, bytes.len);
        try line.appendSlice(allocator, ",\"sha256\":");
        const digest = sha256Hex(bytes);
        try appendJsonString(&line, allocator, &digest);
        if (id) |value| {
            try line.appendSlice(allocator, ",\"id\":");
            try appendJsonString(&line, allocator, value);
        }
        if (role) |value| {
            try line.appendSlice(allocator, ",\"role\":");
            try appendJsonString(&line, allocator, value);
        }
        if (parent) |value| {
            try line.appendSlice(allocator, ",\"parent\":");
            try appendJsonString(&line, allocator, value);
        }
        try line.appendSlice(allocator, "}\n");

        try self.file.writeStreamingAll(self.io, line.items);
        self.hasher.update(line.items);
        self.count = next_count;
        self.total_bytes = next_total_bytes;
    }
};

pub fn writeOutputSnapshotSummary(
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    output_root: []const u8,
    summary: InventorySummary,
) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, "{\n  \"schemaVersion\":\"boris-testdata-output-snapshot/1\",\n  \"outputRoot\":");
    try appendJsonString(&output, allocator, output_root);
    try output.appendSlice(allocator, ",\n  \"snapshot\":\"results/output-snapshot.jsonl\",\n  \"count\":");
    try appendDecimal(&output, allocator, summary.count);
    try output.appendSlice(allocator, ",\n  \"bytes\":");
    try appendDecimal(&output, allocator, summary.total_bytes);
    try output.appendSlice(allocator, ",\n  \"sha256\":");
    try appendJsonString(&output, allocator, &summary.sha256);
    try output.appendSlice(allocator, ",\n  \"normative\":false\n}\n");
    try directory.writeFile(io, .{ .sub_path = "output-snapshot.json", .data = output.items });
}

pub fn writeExpected(
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    seed: u64,
    page_count: usize,
    assignments: []const barbs.Assignment,
) !HashText {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const compile_failure = hasCompileFailure(assignments);
    try output.appendSlice(allocator, "{\n  \"schemaVersion\":\"boris-testdata-expected/2\",\n  \"profile\":");
    try appendJsonString(&output, allocator, profile_name);
    try output.appendSlice(allocator, ",\n  \"seed\":");
    try appendDecimal(&output, allocator, seed);
    try output.appendSlice(allocator, ",\n  \"pageCount\":");
    try appendDecimal(&output, allocator, page_count);
    try output.appendSlice(allocator, ",\n  \"run\":{\"expectedExitCode\":");
    try appendDecimal(&output, allocator, @as(usize, if (compile_failure) 1 else 0));
    try output.appendSlice(allocator, ",\"classification\":");
    try appendJsonString(&output, allocator, if (compile_failure) "content-validation" else "success");
    try output.appendSlice(allocator, "},\n  \"barbs\":[");

    for (assignments, 0..) |assignment, index| {
        if (index != 0) try output.appendSlice(allocator, ",");
        try output.appendSlice(allocator, "{\"name\":");
        try appendJsonString(&output, allocator, barbs.name(assignment.kind));
        try output.appendSlice(allocator, ",\"targetIndex\":");
        try appendDecimal(&output, allocator, assignment.target);
        try output.appendSlice(allocator, ",\"secondaryIndex\":");
        if (assignment.secondary) |secondary| try appendDecimal(&output, allocator, secondary) else try output.appendSlice(allocator, "null");
        try output.appendSlice(allocator, ",\"behavior\":");
        try appendJsonString(&output, allocator, barbs.expectedLabel(assignment.kind));
        try output.appendSlice(allocator, ",\"phase\":");
        try appendJsonString(&output, allocator, @tagName(barbs.phase(assignment.kind)));
        try output.appendSlice(allocator, ",\"findingCode\":");
        if (barbs.expectedFindingCode(assignment.kind)) |code| {
            try appendJsonString(&output, allocator, code);
        } else {
            try output.appendSlice(allocator, "null");
        }
        try output.appendSlice(allocator, ",\"expectedCoverage\":");
        try appendJsonString(&output, allocator, barbs.expectedCoverage(assignment.kind));
        try output.appendSlice(allocator, ",\"repair\":");
        try appendJsonString(&output, allocator, barbs.repair(assignment.kind));
        try output.appendSlice(allocator, ",\"description\":");
        try appendJsonString(&output, allocator, barbs.description(assignment.kind));
        try output.appendSlice(allocator, "}");
    }
    try output.appendSlice(allocator, "]\n}\n");

    try directory.writeFile(io, .{ .sub_path = "expected.json", .data = output.items });
    return sha256Hex(output.items);
}

pub fn writeManifest(
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    profile_description: []const u8,
    seed: u64,
    page_count: usize,
    graph_plan: graph.GraphPlan,
    inventory: InventorySummary,
    expected_hash: HashText,
    theme_description: []const u8,
    template_description: []const u8,
) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "{\n");
    try output.appendSlice(allocator, "  \"schemaVersion\":");
    try appendJsonString(&output, allocator, schema_version);
    try output.appendSlice(allocator, ",\n  \"generator\":");
    try appendJsonString(&output, allocator, generator_version);
    try output.appendSlice(allocator, ",\n  \"profile\":");
    try appendJsonString(&output, allocator, profile_name);
    try output.appendSlice(allocator, ",\n  \"description\":");
    try appendJsonString(&output, allocator, profile_description);
    try output.appendSlice(allocator, ",\n  \"seed\":");
    try appendDecimal(&output, allocator, seed);
    try output.appendSlice(allocator, ",\n  \"pageCount\":");
    try appendDecimal(&output, allocator, page_count);
    try output.appendSlice(allocator, ",\n  \"roots\":{\"content\":\"content\",\"assets\":\"optional-assets\",\"theme\":\"optional-theme\",\"results\":\"results\"}");
    try output.appendSlice(allocator, ",\n  \"theme\":");
    try appendJsonString(&output, allocator, theme_description);
    try output.appendSlice(allocator, ",\n  \"template\":");
    try appendJsonString(&output, allocator, template_description);
    try output.appendSlice(allocator, ",\n  \"graph\":{\"guideCount\":");
    try appendDecimal(&output, allocator, graph_plan.guide_count);
    try output.appendSlice(allocator, ",\"articlesPerGuide\":");
    try appendDecimal(&output, allocator, graph.articles_per_guide);
    try output.appendSlice(allocator, "},\n  \"files\":{\"path\":\"files.jsonl\",\"count\":");
    try appendDecimal(&output, allocator, inventory.count);
    try output.appendSlice(allocator, ",\"bytes\":");
    try appendDecimal(&output, allocator, inventory.total_bytes);
    try output.appendSlice(allocator, ",\"sha256\":");
    try appendJsonString(&output, allocator, &inventory.sha256);
    try output.appendSlice(allocator, "},\n  \"expected\":{\"path\":\"expected.json\",\"sha256\":");
    try appendJsonString(&output, allocator, &expected_hash);
    try output.appendSlice(allocator, "}\n}\n");

    try directory.writeFile(io, .{ .sub_path = "manifest.json", .data = output.items });
}

fn hasCompileFailure(assignments: []const barbs.Assignment) bool {
    for (assignments) |assignment| {
        if (barbs.behavior(assignment.kind) == .compile_failure) return true;
    }
    return false;
}

pub fn appendJsonString(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try buffer.append(allocator, '"');
    for (value) |byte| switch (byte) {
        '"' => try buffer.appendSlice(allocator, "\\\""),
        '\\' => try buffer.appendSlice(allocator, "\\\\"),
        '\n' => try buffer.appendSlice(allocator, "\\n"),
        '\r' => try buffer.appendSlice(allocator, "\\r"),
        '\t' => try buffer.appendSlice(allocator, "\\t"),
        0...8, 11...12, 14...0x1f => {
            var escaped: [6]u8 = undefined;
            const text = try std.fmt.bufPrint(&escaped, "\\u{d:0>4}", .{byte});
            try buffer.appendSlice(allocator, text);
        },
        else => try buffer.append(allocator, byte),
    };
    try buffer.append(allocator, '"');
}

fn appendDecimal(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try buffer.appendSlice(allocator, text);
}

test "inventory hashes its exact JSONL bytes" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    var inventory = try Inventory.open(io, tmp.dir);
    try inventory.add(a, "content/index.md", "page", "hello\n", "index", "trunk", null);
    const summary = inventory.close();
    try std.testing.expectEqual(@as(usize, 1), summary.count);
    try std.testing.expectEqual(@as(u64, 6), summary.total_bytes);
    const raw = try tmp.dir.readFileAlloc(io, "files.jsonl", a, .unlimited);
    defer a.free(raw);
    try std.testing.expectEqual(summary.sha256, sha256Hex(raw));
}
