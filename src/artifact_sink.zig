//! Compiler-host write seam (#301 M2).
//!
//! One operation: emit a named artifact. Not a VFS. The filesystem adapter
//! keeps the existing IR stage+rename policy; the memory adapter collects
//! bytes with no host output directory.

const std = @import("std");
const Io = std.Io;
const target_mod = @import("target.zig");

pub const json_media_type = "application/json";

pub const Record = struct {
    path: []const u8,
    media_type: []const u8,
    bytes: []const u8,
};

pub const EmitError = error{
    InvalidPath,
    DuplicatePath,
    WriteFailed,
    OutOfMemory,
};

pub const Sink = union(enum) {
    dir: *Dir,
    memory: *Memory,

    pub fn emit(self: Sink, path: []const u8, media_type: []const u8, bytes: []const u8) EmitError!void {
        return switch (self) {
            .dir => |d| d.emit(path, media_type, bytes),
            .memory => |m| m.emit(path, media_type, bytes),
        };
    }

    pub fn items(self: Sink) []const Record {
        return switch (self) {
            .dir => |d| d.inner.items(),
            .memory => |m| m.items(),
        };
    }

    pub fn commit(self: Sink, ok: bool) !void {
        switch (self) {
            .dir => |d| try d.commit(ok),
            .memory => {},
        }
    }
};

/// In-memory collection. No host directory.
pub const Memory = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,

    pub fn init(gpa: std.mem.Allocator) Memory {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Memory) void {
        for (self.records.items) |rec| {
            self.gpa.free(rec.path);
            self.gpa.free(rec.media_type);
            self.gpa.free(rec.bytes);
        }
        self.records.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn emit(self: *Memory, path: []const u8, media_type: []const u8, bytes: []const u8) EmitError!void {
        try validateArtifactPath(path);
        for (self.records.items) |rec| {
            if (std.mem.eql(u8, rec.path, path)) return error.DuplicatePath;
        }
        const rec = Record{
            .path = try self.gpa.dupe(u8, path),
            .media_type = try self.gpa.dupe(u8, media_type),
            .bytes = try self.gpa.dupe(u8, bytes),
        };
        errdefer {
            self.gpa.free(rec.path);
            self.gpa.free(rec.media_type);
            self.gpa.free(rec.bytes);
        }
        try self.records.append(self.gpa, rec);
    }

    pub fn items(self: *const Memory) []const Record {
        return self.records.items;
    }

    pub fn get(self: *const Memory, path: []const u8) ?[]const u8 {
        for (self.records.items) |rec| {
            if (std.mem.eql(u8, rec.path, path)) return rec.bytes;
        }
        return null;
    }
};

/// Filesystem adapter. Native CLI default: stage next to `out_dir`, then rename.
pub const Dir = struct {
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: []const u8,
    content_root: []const u8,
    inner: Memory,

    pub fn init(io: Io, gpa: std.mem.Allocator, out_dir: []const u8, content_root: []const u8) Dir {
        return .{
            .io = io,
            .gpa = gpa,
            .out_dir = out_dir,
            .content_root = content_root,
            .inner = Memory.init(gpa),
        };
    }

    pub fn deinit(self: *Dir) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn emit(self: *Dir, path: []const u8, media_type: []const u8, bytes: []const u8) EmitError!void {
        return self.inner.emit(path, media_type, bytes);
    }

    pub fn commit(self: *Dir, ok: bool) !void {
        if (self.out_dir.len > 0 and self.content_root.len > 0) {
            try target_mod.validateExportPath(self.io, self.gpa, self.content_root, self.out_dir);
        }
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.out_dir);

        if (!ok) {
            var out = try cwd.openDir(self.io, self.out_dir, .{});
            defer out.close(self.io);
            out.deleteFile(self.io, "manifest.json") catch {};
            out.deleteFile(self.io, "graph.json") catch {};
            out.deleteFile(self.io, "completion.json") catch {};
            if (self.inner.get("build-report.json")) |report| {
                try out.writeFile(self.io, .{ .sub_path = "build-report.json", .data = report });
            }
            return;
        }

        const stage_rel = try std.fmt.allocPrint(self.gpa, "{s}.boris-stage", .{self.out_dir});
        defer self.gpa.free(stage_rel);
        cwd.deleteTree(self.io, stage_rel) catch {};
        try cwd.createDirPath(self.io, stage_rel);

        {
            var stage = try cwd.openDir(self.io, stage_rel, .{});
            defer stage.close(self.io);
            for (self.inner.items()) |rec| {
                if (std.mem.lastIndexOfScalar(u8, rec.path, '/')) |slash| {
                    try stage.createDirPath(self.io, rec.path[0..slash]);
                }
                try stage.writeFile(self.io, .{ .sub_path = rec.path, .data = rec.bytes });
            }
        }

        var stage_dir = try cwd.openDir(self.io, stage_rel, .{});
        defer stage_dir.close(self.io);
        var out_dir = try cwd.openDir(self.io, self.out_dir, .{});
        defer out_dir.close(self.io);

        for (self.inner.items()) |rec| {
            stage_dir.rename(rec.path, out_dir, rec.path, self.io) catch |err| switch (err) {
                error.CrossDevice => {
                    try stage_dir.copyFile(rec.path, out_dir, rec.path, self.io, .{ .replace = true });
                    stage_dir.deleteFile(self.io, rec.path) catch {};
                },
                else => return err,
            };
        }
        cwd.deleteTree(self.io, stage_rel) catch {};
    }
};

pub fn validateArtifactPath(path: []const u8) error{InvalidPath}!void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) return error.InvalidPath;
    var i: usize = 0;
    while (i < path.len) {
        const start = i;
        while (i < path.len and path[i] != '/' and path[i] != '\\') : (i += 1) {}
        const seg = path[start..i];
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, ".."))
            return error.InvalidPath;
        if (i < path.len) {
            if (path[i] != '/') return error.InvalidPath;
            i += 1;
            if (i >= path.len) return error.InvalidPath;
        }
    }
}

const testing = std.testing;

test "memory sink rejects traversal, empty, and duplicate paths" {
    var sink = Memory.init(testing.allocator);
    defer sink.deinit();
    try testing.expectError(error.InvalidPath, sink.emit("../x.json", json_media_type, "{}"));
    try testing.expectError(error.InvalidPath, sink.emit("/abs.json", json_media_type, "{}"));
    try testing.expectError(error.InvalidPath, sink.emit("", json_media_type, "{}"));
    try sink.emit("build-report.json", json_media_type, "{\"ok\":false}\n");
    try testing.expectError(error.DuplicatePath, sink.emit("build-report.json", json_media_type, "{}"));
    try testing.expectEqualStrings("{\"ok\":false}\n", sink.get("build-report.json").?);
}

test "memory sink keeps emit order and bytes" {
    var sink = Memory.init(testing.allocator);
    defer sink.deinit();
    try sink.emit("manifest.json", json_media_type, "{\"a\":1}\n");
    try sink.emit("graph.json", json_media_type, "{\"b\":2}\n");
    try testing.expectEqual(@as(usize, 2), sink.items().len);
    try testing.expectEqualStrings("manifest.json", sink.items()[0].path);
    try testing.expectEqualStrings("graph.json", sink.items()[1].path);
}
