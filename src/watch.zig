//! Watch mode coordinator, interface, and backends for Boris HTML site builds.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const compile = @import("compile.zig");
const cli = @import("cli.zig");

pub const EventKind = enum {
    create,
    modify,
    delete,
    rename,
};

pub const Event = struct {
    path: []const u8,
    kind: EventKind,
};

/// Watcher interface wrapping platform-specific or simulated backends.
pub const Watcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        poll: *const fn (ptr: *anyopaque, events: *std.ArrayList(Event)) anyerror!void,
    };

    pub fn deinit(self: Watcher) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn poll(self: Watcher, events: *std.ArrayList(Event)) anyerror!void {
        try self.vtable.poll(self.ptr, events);
    }
};

/// In-memory mock watcher for deterministic, non-timing-dependent unit/integration tests.
pub const FakeWatcher = struct {
    allocator: std.mem.Allocator,
    queued_events: std.ArrayList(Event) = .empty,

    pub fn init(allocator: std.mem.Allocator) FakeWatcher {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FakeWatcher) void {
        for (self.queued_events.items) |e| {
            self.allocator.free(e.path);
        }
        self.queued_events.deinit(self.allocator);
    }

    pub fn pushEvent(self: *FakeWatcher, path: []const u8, kind: EventKind) !void {
        const dup = try self.allocator.dupe(u8, path);
        try self.queued_events.append(self.allocator, .{ .path = dup, .kind = kind });
    }

    pub fn watcher(self: *FakeWatcher) Watcher {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = Watcher.VTable{
        .deinit = struct {
            fn deinit(ptr: *anyopaque) void {
                const self: *FakeWatcher = @alignCast(@ptrCast(ptr));
                self.deinit();
            }
        }.deinit,
        .poll = struct {
            fn poll(ptr: *anyopaque, events: *std.ArrayList(Event)) anyerror!void {
                const self: *FakeWatcher = @alignCast(@ptrCast(ptr));
                for (self.queued_events.items) |e| {
                    const dup = try self.allocator.dupe(u8, e.path);
                    try events.append(self.allocator, .{ .path = dup, .kind = e.kind });
                }
                for (self.queued_events.items) |e| {
                    self.allocator.free(e.path);
                }
                self.queued_events.clearRetainingCapacity();
            }
        }.poll,
    };
};

/// Portable Polling-based file watcher backend comparing filesystem mtime.
pub const PollingWatcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    roots: std.ArrayList([]const u8) = .empty,
    file_map: std.StringHashMap(i128),

    pub fn init(allocator: std.mem.Allocator, io: Io) PollingWatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .file_map = std.StringHashMap(i128).init(allocator),
        };
    }

    pub fn deinit(self: *PollingWatcher) void {
        for (self.roots.items) |r| {
            self.allocator.free(r);
        }
        self.roots.deinit(self.allocator);

        var it = self.file_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_map.deinit();
    }

    pub fn addRoot(self: *PollingWatcher, root_path: []const u8) !void {
        const dup = try self.allocator.dupe(u8, root_path);
        try self.roots.append(self.allocator, dup);
        try scanFiles(self.io, self.allocator, dup, &self.file_map);
    }

    pub fn watcher(self: *PollingWatcher) Watcher {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = Watcher.VTable{
        .deinit = struct {
            fn deinit(ptr: *anyopaque) void {
                const self: *PollingWatcher = @alignCast(@ptrCast(ptr));
                self.deinit();
            }
        }.deinit,
        .poll = struct {
            fn poll(ptr: *anyopaque, events: *std.ArrayList(Event)) anyerror!void {
                const self: *PollingWatcher = @alignCast(@ptrCast(ptr));

                var new_map = std.StringHashMap(i128).init(self.allocator);
                errdefer {
                    var it = new_map.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                    }
                    new_map.deinit();
                }

                for (self.roots.items) |r| {
                    try scanFiles(self.io, self.allocator, r, &new_map);
                }

                // creations & modifications
                var new_it = new_map.iterator();
                while (new_it.next()) |entry| {
                    const path = entry.key_ptr.*;
                    const mtime = entry.value_ptr.*;
                    if (self.file_map.get(path)) |old_mtime| {
                        if (old_mtime != mtime) {
                            const dup = try self.allocator.dupe(u8, path);
                            try events.append(self.allocator, .{ .path = dup, .kind = .modify });
                        }
                    } else {
                        const dup = try self.allocator.dupe(u8, path);
                        try events.append(self.allocator, .{ .path = dup, .kind = .create });
                    }
                }

                // deletions
                var old_it = self.file_map.iterator();
                while (old_it.next()) |entry| {
                    const path = entry.key_ptr.*;
                    if (!new_map.contains(path)) {
                        const dup = try self.allocator.dupe(u8, path);
                        try events.append(self.allocator, .{ .path = dup, .kind = .delete });
                    }
                }

                // clean up old map keys
                var old_it_clean = self.file_map.iterator();
                while (old_it_clean.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                }
                self.file_map.deinit();
                self.file_map = new_map;
            }
        }.poll,
    };
};

/// Recursively scan files under root using Io.Dir.walkSelectively and populate file_map.
pub fn scanFiles(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    file_map: *std.StringHashMap(i128),
) !void {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;

        const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        errdefer allocator.free(full_path);

        try file_map.put(full_path, @intCast(stat.mtime.nanoseconds));
    }
}

/// Normalize path to use forward slashes and trim leading ./ or trailing /
pub fn normalizePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    var path = try allocator.dupe(u8, raw_path);
    for (path) |*c| {
        if (c.* == '\\') {
            c.* = '/';
        }
    }
    var start: usize = 0;
    while (start < path.len) {
        if (std.mem.startsWith(u8, path[start..], "./")) {
            start += 2;
        } else {
            break;
        }
    }
    var end = path.len;
    while (end > start and path[end - 1] == '/') {
        end -= 1;
    }
    const final_path = try allocator.dupe(u8, path[start..end]);
    allocator.free(path);
    return final_path;
}

/// Ignore output, temp, staging, or cache directory files to prevent loops.
pub fn isIgnored(path: []const u8, html_dir: []const u8) bool {
    if (std.mem.startsWith(u8, path, html_dir)) return true;
    if (std.mem.endsWith(u8, path, ".tmp") or std.mem.containsAtLeast(u8, path, 1, ".tmp.")) return true;
    if (std.mem.containsAtLeast(u8, path, 1, ".boris-cache")) return true;
    if (std.mem.containsAtLeast(u8, path, 1, ".boris")) return true;
    return false;
}

/// Translate raw relative/absolute path to the dependency-index/PageDb key.
pub fn translateToKey(allocator: std.mem.Allocator, path: []const u8, content_root: []const u8) ![]const u8 {
    const normalized_root = try normalizePath(allocator, content_root);
    defer allocator.free(normalized_root);

    if (std.mem.startsWith(u8, path, normalized_root)) {
        var sub = path[normalized_root.len..];
        if (sub.len > 0 and sub[0] == '/') {
            sub = sub[1..];
        }
        return try allocator.dupe(u8, sub);
    }
    return try allocator.dupe(u8, path);
}

/// Global volatile flag for POSIX shutdown.
pub var should_shutdown_global: bool = false;

fn handleSigInt(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    should_shutdown_global = true;
}

/// Native helper using std.Io Clock.Duration to sleep portably.
fn sleepMs(io: Io, ms: i64) !void {
    const d = std.Io.Clock.Duration{
        .raw = std.Io.Duration.fromMilliseconds(ms),
        .clock = .real,
    };
    _ = try d.sleep(io);
}

/// Coordinator running the debounced watch and serialized rebuild cycles.
pub const WatchCoordinator = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: cli.Options,
    watcher: Watcher,

    // Loop State
    should_shutdown: bool = false,
    rebuild_pending: bool = false,
    rebuild_in_progress: bool = false,
    pending_changes: std.StringHashMap(void),

    pub fn init(gpa: std.mem.Allocator, io: Io, options: cli.Options, watcher: Watcher) WatchCoordinator {
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .watcher = watcher,
            .pending_changes = std.StringHashMap(void).init(gpa),
        };
    }

    pub fn deinit(self: *WatchCoordinator) void {
        var it = self.pending_changes.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.pending_changes.deinit();
    }

    /// Read, normalize, filter, and deduplicate events into pending_changes.
    pub fn processEvents(self: *WatchCoordinator) !void {
        var events: std.ArrayList(Event) = .empty;
        defer {
            for (events.items) |e| {
                self.gpa.free(e.path);
            }
            events.deinit(self.gpa);
        }

        try self.watcher.poll(&events);

        for (events.items) |event| {
            const normalized = try normalizePath(self.gpa, event.path);
            defer self.gpa.free(normalized);

            if (isIgnored(normalized, self.options.html_dir orelse "dist")) {
                continue;
            }

            const key = try translateToKey(self.gpa, normalized, self.options.input_dir);
            errdefer self.gpa.free(key);

            if (!self.pending_changes.contains(key)) {
                try self.pending_changes.put(key, {});
            } else {
                self.gpa.free(key);
            }
        }
    }

    /// Triggers compileHtmlSite, recovery, and serialization follow-ups.
    pub fn triggerRebuild(self: *WatchCoordinator) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| self.gpa.free(p);
            paths.deinit(self.gpa);
        }

        var it = self.pending_changes.iterator();
        while (it.next()) |entry| {
            try paths.append(self.gpa, try self.gpa.dupe(u8, entry.key_ptr.*));
        }

        // Alphabetical sort of paths for absolute determinism
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        if (!self.options.quiet) {
            std.debug.print("watch: changed paths detected:\n", .{});
            for (paths.items) |p| {
                std.debug.print("  - {s}\n", .{p});
            }
            std.debug.print("watch: triggering incremental rebuild...\n", .{});
        }

        // Free pending changes before rebuild so we capture new events during render
        var it_clean = self.pending_changes.iterator();
        while (it_clean.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.pending_changes.clearRetainingCapacity();

        self.rebuild_in_progress = true;
        defer { self.rebuild_in_progress = false; }

        _ = compile.compileHtmlSite(self.io, self.gpa, .{
            .content_root = self.options.input_dir,
            .dist_dir = self.options.html_dir orelse "dist",
            .layout_path = "layouts/main.html",
            .incremental = self.options.incremental,
            .quiet = self.options.quiet,
            .jobs = self.options.jobs,
        }) catch |err| {
            if (!self.options.quiet) {
                std.debug.print("error: rebuild failed: {s}. Waiting for correction...\n", .{@errorName(err)});
            }
            return;
        };

        if (!self.options.quiet) {
            std.debug.print("watch: rebuild succeeded.\n", .{});
        }
    }

    /// Perform initial build, set up signal handlers, and execute the watch poll loop.
    pub fn run(self: *WatchCoordinator) !void {
        // Initial build
        if (!self.options.quiet) {
            std.debug.print("watch: performing initial build...\n", .{});
        }

        var initial_success = true;
        var stats: compile.CompileStats = .{ .pages_written = 0, .peak_whiteboard_capacity = 0 };
        if (compile.compileHtmlSite(self.io, self.gpa, .{
            .content_root = self.options.input_dir,
            .dist_dir = self.options.html_dir orelse "dist",
            .layout_path = "layouts/main.html",
            .incremental = self.options.incremental,
            .quiet = self.options.quiet,
            .jobs = self.options.jobs,
        })) |st| {
            stats = st;
        } else |err| {
            initial_success = false;
            switch (err) {
                error.ParseFailed,
                error.ComponentFailed,
                error.LayoutMissingMarker,
                error.LayoutDuplicateMarker,
                => {
                    if (!self.options.quiet) {
                        std.debug.print("error: initial build failed: {s}. Continuing to watch...\n", .{@errorName(err)});
                    }
                },
                else => {
                    if (!self.options.quiet) {
                        std.debug.print("error: initial build failed with unrecoverable I/O error: {s}\n", .{@errorName(err)});
                    }
                    return err;
                }
            }
        }

        if (initial_success and !self.options.quiet) {
            std.debug.print("watch: initial build succeeded ({d} pages written). Starting watcher...\n", .{stats.pages_written});
        }

        // Register POSIX signal handlers
        if (comptime builtin.os.tag != .windows) {
            const act = std.posix.Sigaction{
                .handler = .{ .handler = handleSigInt },
                .mask = std.mem.zeroes(std.posix.sigset_t),
                .flags = 0,
            };
            std.posix.sigaction(std.posix.SIG.INT, &act, null);
            std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        }

        should_shutdown_global = false;

        while (!self.should_shutdown and !should_shutdown_global) {
            try self.processEvents();

            if (self.pending_changes.count() > 0) {
                // Debounce window sleep
                try sleepMs(self.io, 100);

                // Fetch any additional trailing events
                try self.processEvents();

                // Trigger serialized rebuild
                try self.triggerRebuild();
            }

            try sleepMs(self.io, 50);
        }

        if (!self.options.quiet) {
            std.debug.print("watch: received shutdown signal, cleaning resources...\n", .{});
        }
    }
};

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "normalizePath helper" {
    const gpa = std.testing.allocator;

    const p1 = try normalizePath(gpa, "content\\guides\\intro.md");
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("content/guides/intro.md", p1);

    const p2 = try normalizePath(gpa, "./content/guides/");
    defer gpa.free(p2);
    try std.testing.expectEqualStrings("content/guides", p2);

    const p3 = try normalizePath(gpa, "content");
    defer gpa.free(p3);
    try std.testing.expectEqualStrings("content", p3);
}

test "isIgnored helper" {
    try std.testing.expect(isIgnored("dist/index.html", "dist"));
    try std.testing.expect(isIgnored("dist/guides/intro.html.tmp", "dist"));
    try std.testing.expect(isIgnored(".boris-cache/manifest.json", "dist"));
    try std.testing.expect(!isIgnored("content/guides/intro.md", "dist"));
    try std.testing.expect(!isIgnored("layouts/main.html", "dist"));
}

test "translateToKey helper" {
    const gpa = std.testing.allocator;

    const k1 = try translateToKey(gpa, "content/guides/intro.md", "content");
    defer gpa.free(k1);
    try std.testing.expectEqualStrings("guides/intro.md", k1);

    const k2 = try translateToKey(gpa, "layouts/main.html", "content");
    defer gpa.free(k2);
    try std.testing.expectEqualStrings("layouts/main.html", k2);
}

test "FakeWatcher and Coordinator Event Coalescing & Stable Sort" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var coord = WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "content",
        .html_dir = "dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    // Push chaotic events
    try fake.pushEvent("content/guides/intro.md", .modify);
    try fake.pushEvent("content/index.md", .create);
    try fake.pushEvent("content/guides/intro.md", .modify); // duplicate

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 2), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("guides/intro.md"));
    try std.testing.expect(coord.pending_changes.contains("index.md"));
}
