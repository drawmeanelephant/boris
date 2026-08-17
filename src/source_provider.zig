//! Compiler-host read seam (#301 M1).
//!
//! Two operations only: enumerate pages and read a named source. Not a VFS.
//! The filesystem adapter keeps native CLI behavior; the memory adapter
//! compiles a canonical file list without a host directory.

const std = @import("std");
const Io = std.Io;
const identity = @import("identity.zig");
const page_mod = @import("page.zig");
const scanner = @import("scanner.zig");
const source_io = @import("source_io.zig");
const include_mod = @import("include.zig");

pub const File = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const ReadError = error{
    SourceMissing,
    SourceTooLarge,
    InvalidPath,
    DuplicatePath,
    ReadFailed,
    OutOfMemory,
};

pub const InitError = error{
    InvalidPath,
    DuplicatePath,
    OutOfMemory,
};

pub const Provider = union(enum) {
    dir: *Dir,
    memory: *Memory,

    pub fn scan(self: Provider, out: *page_mod.PageList) scanner.ScanError!void {
        return switch (self) {
            .dir => |d| d.scan(out),
            .memory => |m| m.scan(out),
        };
    }

    pub fn readPage(self: Provider, path: []const u8, allocator: std.mem.Allocator) ReadError![]u8 {
        return switch (self) {
            .dir => |d| d.readPage(path, allocator),
            .memory => |m| m.readPage(path, allocator),
        };
    }

    pub fn readInclude(self: Provider, path: []const u8, allocator: std.mem.Allocator) include_mod.IncludeError![]u8 {
        return switch (self) {
            .dir => |d| d.readInclude(path, allocator),
            .memory => |m| m.readInclude(path, allocator),
        };
    }
};

/// Filesystem adapter. Native CLI default.
pub const Dir = struct {
    io: Io,
    dir: Io.Dir,
    input_format: identity.InputFormat,
    owns_dir: bool = true,

    pub fn open(io: Io, content_root: []const u8, input_format: identity.InputFormat) scanner.ScanError!Dir {
        const opened = Io.Dir.cwd().openDir(io, content_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.ContentDirMissing,
            else => return err,
        };
        return .{ .io = io, .dir = opened, .input_format = input_format, .owns_dir = true };
    }

    pub fn close(self: *Dir) void {
        if (self.owns_dir) self.dir.close(self.io);
        self.owns_dir = false;
    }

    pub fn scan(self: *Dir, out: *page_mod.PageList) scanner.ScanError!void {
        return scanner.scanDirFormat(self.io, self.dir, self.input_format, out);
    }

    pub fn readPage(self: *Dir, path: []const u8, allocator: std.mem.Allocator) ReadError![]u8 {
        return source_io.readPageAlloc(self.io, self.dir, path, allocator) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SourceTooLarge => error.SourceTooLarge,
            error.FileNotFound, error.NotDir => error.SourceMissing,
            else => error.ReadFailed,
        };
    }

    pub fn readInclude(self: *Dir, path: []const u8, allocator: std.mem.Allocator) include_mod.IncludeError![]u8 {
        return include_mod.readSourceAlloc(self.io, self.dir, path, allocator);
    }
};

/// In-memory adapter. No host directory.
pub const Memory = struct {
    gpa: std.mem.Allocator,
    input_format: identity.InputFormat,
    paths: [][]const u8,
    bytes: [][]const u8,
    index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(gpa: std.mem.Allocator, files: []const File, input_format: identity.InputFormat) InitError!Memory {
        var paths = try gpa.alloc([]const u8, files.len);
        errdefer gpa.free(paths);
        var bytes = try gpa.alloc([]const u8, files.len);
        errdefer gpa.free(bytes);
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer index.deinit(gpa);

        var i: usize = 0;
        errdefer {
            for (paths[0..i]) |p| gpa.free(p);
        }

        for (files, 0..) |file, n| {
            const canon = identity.canonicalize(gpa, file.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidPath,
            };
            if (index.contains(canon)) {
                gpa.free(canon);
                return error.DuplicatePath;
            }
            try index.put(gpa, canon, n);
            paths[n] = canon;
            bytes[n] = file.bytes;
            i = n + 1;
        }

        return .{
            .gpa = gpa,
            .input_format = input_format,
            .paths = paths,
            .bytes = bytes,
            .index = index,
        };
    }

    pub fn deinit(self: *Memory) void {
        for (self.paths) |p| self.gpa.free(p);
        self.gpa.free(self.paths);
        self.gpa.free(self.bytes);
        self.index.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn scan(self: *Memory, out: *page_mod.PageList) scanner.ScanError!void {
        for (self.paths) |path| {
            if (isReservedIncludePath(path) or isUnderAssetsTree(path)) continue;
            const basename = basenameOf(path);
            if (!identity.isPageFile(basename)) continue;
            const kind = identity.contentKind(basename) catch continue;
            if (!self.input_format.accepts(kind)) return error.InputFormatMismatch;
            try scanner.registerDiscoveredPage(out.retain, out, path);
        }
        page_mod.sortPages(out.pages.items);
    }

    pub fn readPage(self: *Memory, path: []const u8, allocator: std.mem.Allocator) ReadError![]u8 {
        const bytes = try self.lookup(path);
        if (bytes.len <= page_mod.max_source_bytes) return allocator.dupe(u8, bytes);
        const prefix = try allocator.alloc(u8, page_mod.max_source_bytes + 1);
        @memcpy(prefix, bytes[0..prefix.len]);
        return prefix;
    }

    pub fn readInclude(self: *Memory, path: []const u8, allocator: std.mem.Allocator) include_mod.IncludeError![]u8 {
        const bytes = self.lookup(path) catch |err| return switch (err) {
            error.SourceMissing => error.IncludeMissing,
            error.InvalidPath => error.InvalidPath,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
        if (bytes.len > include_mod.max_expanded_bytes) return error.ExpansionBudgetExceeded;
        return allocator.dupe(u8, bytes);
    }

    fn lookup(self: *Memory, path: []const u8) ReadError![]const u8 {
        const key = identity.canonicalize(self.gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPath,
        };
        defer self.gpa.free(key);
        const idx = self.index.get(key) orelse return error.SourceMissing;
        return self.bytes[idx];
    }
};

pub fn isReservedIncludePath(path: []const u8) bool {
    return std.mem.eql(u8, path, "includes") or std.mem.startsWith(u8, path, "includes/");
}

pub fn isUnderAssetsTree(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.endsWith(u8, seg, ".assets")) return true;
    }
    return false;
}

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

const testing = std.testing;

test "memory scan discovers pages and skips includes and assets" {
    const gpa = testing.allocator;
    const files = [_]File{
        .{ .path = "index.md", .bytes = "---\ntitle: Home\n---\n# Home\n" },
        .{ .path = "guides/intro.md", .bytes = "---\ntitle: Intro\nparent: index\n---\n# Intro\n" },
        .{ .path = "includes/tip.md", .bytes = "tip\n" },
        .{ .path = "index.assets/logo.svg", .bytes = "<svg/>\n" },
        .{ .path = "notes.txt", .bytes = "ignore\n" },
    };
    var mem = try Memory.init(gpa, &files, .markdown);
    defer mem.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = page_mod.PageList.init(gpa, arena.allocator());
    defer list.deinit();
    try mem.scan(&list);

    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("guides/intro", list.pages.items[0].entity_id);
    try testing.expectEqualStrings("index", list.pages.items[1].entity_id);

    const tip = try mem.readInclude("includes/tip.md", gpa);
    defer gpa.free(tip);
    try testing.expectEqualStrings("tip\n", tip);

    try testing.expectError(error.SourceMissing, mem.readPage("missing.md", gpa));
}

test "memory init rejects traversal and duplicate canonical paths" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidPath, Memory.init(gpa, &.{
        .{ .path = "../escape.md", .bytes = "x" },
    }, .markdown));
    try testing.expectError(error.InvalidPath, Memory.init(gpa, &.{
        .{ .path = "/abs.md", .bytes = "x" },
    }, .markdown));
    try testing.expectError(error.DuplicatePath, Memory.init(gpa, &.{
        .{ .path = "index.md", .bytes = "a" },
        .{ .path = "index.md", .bytes = "b" },
    }, .markdown));
}

test "memory readPage bounds oversized source like source_io" {
    const gpa = testing.allocator;
    const oversized = try gpa.alloc(u8, page_mod.max_source_bytes + 8);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    var mem = try Memory.init(gpa, &.{
        .{ .path = "big.md", .bytes = oversized },
    }, .markdown);
    defer mem.deinit();
    const got = try mem.readPage("big.md", gpa);
    defer gpa.free(got);
    try testing.expectEqual(page_mod.max_source_bytes + 1, got.len);
}

test "memory mixed page family is InputFormatMismatch" {
    const gpa = testing.allocator;
    var mem = try Memory.init(gpa, &.{
        .{ .path = "index.md", .bytes = "# Home\n" },
        .{ .path = "extra.textile", .bytes = "h1. Extra\n" },
    }, .markdown);
    defer mem.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = page_mod.PageList.init(gpa, arena.allocator());
    defer list.deinit();
    try testing.expectError(error.InputFormatMismatch, mem.scan(&list));
}
