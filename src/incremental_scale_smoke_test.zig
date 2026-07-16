//! Opt-in deterministic incremental HTML scale smoke.
//!
//! Built only by `zig build test-scale-smoke`; fixture notes live at
//! `test/scale-smoke/README.md`.

const std = @import("std");
const Io = std.Io;
const compile = @import("compile.zig");

const trunk_count = 20;
const satellites_per_trunk = 9;
const page_count = trunk_count * (1 + satellites_per_trunk);
// The reverse parent walk conservatively expands through the edited page's
// Trunk, then to that Trunk's Satellite cohort.
const edited_cohort_count = 1 + satellites_per_trunk;
const changed_trunk = 7;
const changed_satellite = 3;

const WorkDir = struct {
    gpa: std.mem.Allocator,
    io: Io,
    rel: []u8,

    fn create(gpa: std.mem.Allocator, io: Io) !WorkDir {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, "test-output");
        var random: [4]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(&random, .lower);
        const rel = try std.fmt.allocPrint(gpa, "test-output/incremental-scale-smoke-{s}", .{suffix});
        errdefer gpa.free(rel);
        try cwd.createDirPath(io, rel);
        return .{ .gpa = gpa, .io = io, .rel = rel };
    }

    fn cleanup(self: *WorkDir) void {
        Io.Dir.cwd().deleteTree(self.io, self.rel) catch {};
        self.gpa.free(self.rel);
    }

    fn join(self: *const WorkDir, child: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.rel, child });
    }

    fn writeFile(self: *const WorkDir, rel_path: []const u8, data: []const u8) !void {
        const full = try self.join(rel_path);
        defer self.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            try Io.Dir.cwd().createDirPath(self.io, parent);
        }
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = data });
    }

    fn readFile(self: *const WorkDir, rel_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const full = try self.join(rel_path);
        defer self.gpa.free(full);
        var file = try Io.Dir.cwd().openFile(self.io, full, .{});
        defer file.close(self.io);
        var reader = file.reader(self.io, &.{});
        return try reader.interface.allocRemaining(allocator, .unlimited);
    }
};

fn writeSite(work: *const WorkDir, root: []const u8) !void {
    const layout_path = try std.fmt.allocPrint(work.gpa, "{s}/layouts/main.html", .{root});
    defer work.gpa.free(layout_path);
    try work.writeFile(layout_path, "<html><body>{{content}}</body></html>\n");

    for (0..trunk_count) |trunk| {
        const linked_satellite: usize = if (trunk == changed_trunk) changed_satellite else 0;
        const trunk_source = try std.fmt.allocPrint(
            work.gpa,
            "{s}/content/trunks/trunk-{d:0>2}.md",
            .{ root, trunk },
        );
        defer work.gpa.free(trunk_source);
        const trunk_text = try std.fmt.allocPrint(work.gpa,
            \\---
            \\title: Trunk {d:0>2}
            \\---
            \\
            \\# Trunk {d:0>2}
            \\
            \\Satellite index: [[satellites/trunk-{d:0>2}/page-{d:0>2}]]
            \\
        , .{ trunk, trunk, trunk, linked_satellite });
        defer work.gpa.free(trunk_text);
        try work.writeFile(trunk_source, trunk_text);

        for (0..satellites_per_trunk) |satellite| {
            const satellite_source = try std.fmt.allocPrint(
                work.gpa,
                "{s}/content/satellites/trunk-{d:0>2}/page-{d:0>2}.md",
                .{ root, trunk, satellite },
            );
            defer work.gpa.free(satellite_source);
            const satellite_text = try std.fmt.allocPrint(work.gpa,
                \\---
                \\title: Satellite {d:0>2}-{d:0>2}
                \\parent: trunks/trunk-{d:0>2}
                \\---
                \\
                \\# Satellite {d:0>2}-{d:0>2}
                \\
                \\Original scale-smoke body {d:0>2}-{d:0>2}.
                \\
            , .{ trunk, satellite, trunk, trunk, satellite, trunk, satellite });
            defer work.gpa.free(satellite_text);
            try work.writeFile(satellite_source, satellite_text);
        }
    }
}

fn reviseSatellite(work: *const WorkDir, root: []const u8) !void {
    const path = try std.fmt.allocPrint(
        work.gpa,
        "{s}/content/satellites/trunk-{d:0>2}/page-{d:0>2}.md",
        .{ root, changed_trunk, changed_satellite },
    );
    defer work.gpa.free(path);
    const text = try std.fmt.allocPrint(work.gpa,
        \\---
        \\title: Satellite {d:0>2}-{d:0>2} revised
        \\parent: trunks/trunk-{d:0>2}
        \\---
        \\
        \\# Satellite {d:0>2}-{d:0>2} revised
        \\
        \\Revised scale-smoke body {d:0>2}-{d:0>2}.
        \\
    , .{ changed_trunk, changed_satellite, changed_trunk, changed_trunk, changed_satellite, changed_trunk, changed_satellite });
    defer work.gpa.free(text);
    try work.writeFile(path, text);
}

fn compileSite(io: Io, gpa: std.mem.Allocator, content: []const u8, dist: []const u8, layout: []const u8, jobs: usize) !compile.CompileStats {
    return compile.compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .jobs = jobs,
        .quiet = true,
    });
}

fn publishedTreesByteIdentical(io: Io, gpa: std.mem.Allocator, a_root: []const u8, b_root: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var a_paths: std.ArrayList([]const u8) = .empty;
    defer a_paths.deinit(gpa);
    var b_paths: std.ArrayList([]const u8) = .empty;
    defer b_paths.deinit(gpa);
    try collectPublishedPaths(io, gpa, arena.allocator(), a_root, &a_paths);
    try collectPublishedPaths(io, gpa, arena.allocator(), b_root, &b_paths);

    const less = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f;
    std.mem.sort([]const u8, a_paths.items, {}, less);
    std.mem.sort([]const u8, b_paths.items, {}, less);
    try std.testing.expectEqual(a_paths.items.len, b_paths.items.len);

    var a_dir = try Io.Dir.cwd().openDir(io, a_root, .{});
    defer a_dir.close(io);
    var b_dir = try Io.Dir.cwd().openDir(io, b_root, .{});
    defer b_dir.close(io);
    for (a_paths.items, b_paths.items) |a_path, b_path| {
        try std.testing.expectEqualStrings(a_path, b_path);
        const a_bytes = try readFromDir(io, gpa, a_dir, a_path);
        defer gpa.free(a_bytes);
        const b_bytes = try readFromDir(io, gpa, b_dir, b_path);
        defer gpa.free(b_bytes);
        try std.testing.expectEqualSlices(u8, a_bytes, b_bytes);
    }
}

fn collectPublishedPaths(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, root_path: []const u8, paths: *std.ArrayList([]const u8)) !void {
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.mem.startsWith(u8, entry.path, ".boris-cache/")) continue;
        try paths.append(gpa, try arena.dupe(u8, entry.path));
    }
}

fn readFromDir(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

test "scale smoke: 200-page incremental edit is bounded and parallel-deterministic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io);
    defer work.cleanup();

    try writeSite(&work, "sequential");
    const sequential_content = try work.join("sequential/content");
    defer gpa.free(sequential_content);
    const sequential_dist = try work.join("sequential/dist");
    defer gpa.free(sequential_dist);
    const sequential_layout = try work.join("sequential/layouts/main.html");
    defer gpa.free(sequential_layout);

    const cold = try compileSite(io, gpa, sequential_content, sequential_dist, sequential_layout, 1);
    try std.testing.expectEqual(@as(usize, page_count), cold.pages_written);
    const unchanged = try compileSite(io, gpa, sequential_content, sequential_dist, sequential_layout, 1);
    try std.testing.expectEqual(@as(usize, 0), unchanged.pages_written);

    const parent_path = "sequential/dist/trunks/trunk-07.html";
    const changed_path = "sequential/dist/satellites/trunk-07/page-03.html";
    const unrelated_path = "sequential/dist/trunks/trunk-08.html";
    const parent_before = try work.readFile(parent_path, gpa);
    defer gpa.free(parent_before);
    const changed_before = try work.readFile(changed_path, gpa);
    defer gpa.free(changed_before);
    const unrelated_before = try work.readFile(unrelated_path, gpa);
    defer gpa.free(unrelated_before);

    try reviseSatellite(&work, "sequential");
    const revised = try compileSite(io, gpa, sequential_content, sequential_dist, sequential_layout, 1);
    try std.testing.expectEqual(@as(usize, edited_cohort_count), revised.pages_written);
    const parent_after = try work.readFile(parent_path, gpa);
    defer gpa.free(parent_after);
    const changed_after = try work.readFile(changed_path, gpa);
    defer gpa.free(changed_after);
    const unrelated_after = try work.readFile(unrelated_path, gpa);
    defer gpa.free(unrelated_after);
    try std.testing.expect(!std.mem.eql(u8, parent_before, parent_after));
    try std.testing.expect(!std.mem.eql(u8, changed_before, changed_after));
    try std.testing.expectEqualSlices(u8, unrelated_before, unrelated_after);
    try std.testing.expect(std.mem.indexOf(u8, parent_after, "Satellite 07-03 revised") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed_after, "Revised scale-smoke body 07-03.") != null);

    try writeSite(&work, "parallel");
    const parallel_content = try work.join("parallel/content");
    defer gpa.free(parallel_content);
    const parallel_dist = try work.join("parallel/dist");
    defer gpa.free(parallel_dist);
    const parallel_layout = try work.join("parallel/layouts/main.html");
    defer gpa.free(parallel_layout);

    const parallel_cold = try compileSite(io, gpa, parallel_content, parallel_dist, parallel_layout, 4);
    try std.testing.expectEqual(@as(usize, page_count), parallel_cold.pages_written);
    const parallel_unchanged = try compileSite(io, gpa, parallel_content, parallel_dist, parallel_layout, 4);
    try std.testing.expectEqual(@as(usize, 0), parallel_unchanged.pages_written);
    try reviseSatellite(&work, "parallel");
    const parallel_revised = try compileSite(io, gpa, parallel_content, parallel_dist, parallel_layout, 4);
    try std.testing.expectEqual(@as(usize, edited_cohort_count), parallel_revised.pages_written);
    const parallel_repeat = try compileSite(io, gpa, parallel_content, parallel_dist, parallel_layout, 4);
    try std.testing.expectEqual(@as(usize, 0), parallel_repeat.pages_written);

    try publishedTreesByteIdentical(io, gpa, sequential_dist, parallel_dist);
}
