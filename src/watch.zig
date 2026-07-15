//! Watch mode coordinator, interface, and backends for Boris HTML site builds.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const compile = @import("compile.zig");
const cli = @import("cli.zig");

/// Debounce window after the first change is observed (ms).
pub const debounce_ms: i64 = 100;
/// Idle poll interval when no changes are pending (ms). Longer than the
/// debounce window to keep full-tree polling cheap on large content roots.
pub const idle_poll_ms: i64 = 500;

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

/// In-memory mock watcher for deterministic, non-timing-dependent unit tests.
/// Single-threaded; not safe for concurrent push/poll from multiple threads.
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

/// Portable polling file watcher comparing recursive filesystem mtimes.
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
        errdefer self.allocator.free(dup);
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
                            errdefer self.allocator.free(dup);
                            try events.append(self.allocator, .{ .path = dup, .kind = .modify });
                        }
                    } else {
                        const dup = try self.allocator.dupe(u8, path);
                        errdefer self.allocator.free(dup);
                        try events.append(self.allocator, .{ .path = dup, .kind = .create });
                    }
                }

                // deletions
                var old_it = self.file_map.iterator();
                while (old_it.next()) |entry| {
                    const path = entry.key_ptr.*;
                    if (!new_map.contains(path)) {
                        const dup = try self.allocator.dupe(u8, path);
                        errdefer self.allocator.free(dup);
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
/// Keys are allocator-owned; callers free them. Duplicate paths free the new key and
/// keep the existing map entry (update mtime only).
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

        const gop = try file_map.getOrPut(full_path);
        if (gop.found_existing) {
            allocator.free(full_path);
            gop.value_ptr.* = @intCast(stat.mtime.nanoseconds);
        } else {
            gop.value_ptr.* = @intCast(stat.mtime.nanoseconds);
        }
    }
}

/// True when `path` equals `prefix` or is `prefix/` + more (forward-slash paths).
pub fn hasPathPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// True when `needle` appears as a full path component of a forward-slash path.
pub fn hasPathComponent(path: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (std.mem.eql(u8, path, needle)) return true;
    if (std.mem.startsWith(u8, path, needle) and path.len > needle.len and path[needle.len] == '/') {
        return true;
    }
    var start: usize = 0;
    while (start < path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const component = path[start..slash];
        if (std.mem.eql(u8, component, needle)) return true;
        if (slash >= path.len) break;
        start = slash + 1;
    }
    return false;
}

/// Normalize path to use forward slashes and trim leading ./ or trailing /
pub fn normalizePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    var path = try allocator.dupe(u8, raw_path);
    errdefer allocator.free(path);

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
    if (start == 0 and end == path.len) {
        return path;
    }
    const final_path = try allocator.dupe(u8, path[start..end]);
    allocator.free(path);
    return final_path;
}

/// Ignore output, temp, staging, or cache directory files to prevent loops.
/// `path` and `html_dir` must already use forward slashes (normalized).
pub fn isIgnored(path: []const u8, html_dir: []const u8) bool {
    if (hasPathPrefix(path, html_dir)) return true;
    if (std.mem.endsWith(u8, path, ".tmp") or std.mem.containsAtLeast(u8, path, 1, ".tmp.")) return true;
    // Component-aware so content names like `about-boris.md` are not dropped.
    if (hasPathComponent(path, ".boris-cache")) return true;
    if (hasPathComponent(path, ".boris")) return true;
    return false;
}

/// Translate raw relative/absolute path to the dependency-index/PageDb key.
/// Strips `content_root` only on a true path-prefix boundary (`content` ≠ `content2`).
pub fn translateToKey(allocator: std.mem.Allocator, path: []const u8, content_root: []const u8) ![]const u8 {
    const normalized_root = try normalizePath(allocator, content_root);
    defer allocator.free(normalized_root);

    if (hasPathPrefix(path, normalized_root)) {
        var sub = path[normalized_root.len..];
        if (sub.len > 0 and sub[0] == '/') {
            sub = sub[1..];
        }
        return try allocator.dupe(u8, sub);
    }
    return try allocator.dupe(u8, path);
}

/// Async-signal-visible shutdown latch for SIGINT/SIGTERM.
pub var should_shutdown_global: std.atomic.Value(bool) = .init(false);

fn handleSigInt(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    should_shutdown_global.store(true, .unordered);
}

/// Content/layout failures that keep the watcher running for author recovery.
fn isRecoverableBuildError(err: anyerror) bool {
    return switch (err) {
        error.ParseFailed,
        error.ComponentFailed,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        => true,
        else => false,
    };
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

            var ignored = false;
            if (self.options.targets.items.len > 0) {
                for (self.options.targets.items) |tgt| {
                    const norm_tgt = try normalizePath(self.gpa, tgt.output_dir);
                    defer self.gpa.free(norm_tgt);
                    if (isIgnored(normalized, norm_tgt)) {
                        ignored = true;
                        break;
                    }
                }
            } else {
                const html_raw = self.options.html_dir orelse "dist";
                const html_norm = try normalizePath(self.gpa, html_raw);
                defer self.gpa.free(html_norm);
                if (isIgnored(normalized, html_norm)) {
                    ignored = true;
                }
            }

            if (ignored) {
                continue;
            }

            const key = try translateToKey(self.gpa, normalized, self.options.input_dir);
            errdefer self.gpa.free(key);

            const gop = try self.pending_changes.getOrPut(key);
            if (gop.found_existing) {
                self.gpa.free(key);
            } else {
                gop.key_ptr.* = key;
            }
        }
    }

    /// Drain pending paths (sorted for deterministic logging), then rebuild.
    /// Recoverable content/layout errors keep the watch loop alive; other errors propagate.
    pub fn triggerRebuild(self: *WatchCoordinator) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| self.gpa.free(p);
            paths.deinit(self.gpa);
        }

        // Move ownership of pending keys into `paths` (no second copy of the set).
        var it = self.pending_changes.iterator();
        while (it.next()) |entry| {
            try paths.append(self.gpa, entry.key_ptr.*);
        }
        self.pending_changes.clearRetainingCapacity();

        // Alphabetical sort of paths for deterministic log ordering
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

        // Full rediscovery + content-addressed incremental render (event paths
        // trigger the rebuild; dirty-set comes from fingerprints inside compile).
        if (self.options.targets.items.len > 0) {
            compile.compileHtmlSiteMulti(self.io, self.gpa, self.options.targets.items, .{
                .content_root = self.options.input_dir,
                .layout_path = "layouts/main.html",
                .incremental = self.options.incremental,
                .quiet = self.options.quiet,
                .jobs = self.options.jobs,
            }) catch |err| {
                if (isRecoverableBuildError(err) or err == error.MultiTargetCompilationFailed) {
                    if (!self.options.quiet) {
                        std.debug.print("error: rebuild failed: {s}. Waiting for correction...\n", .{@errorName(err)});
                    }
                    return;
                }
                if (!self.options.quiet) {
                    std.debug.print("error: rebuild failed with unrecoverable I/O error: {s}\n", .{@errorName(err)});
                }
                return err;
            };
        } else {
            _ = compile.compileHtmlSite(self.io, self.gpa, .{
                .content_root = self.options.input_dir,
                .dist_dir = self.options.html_dir orelse "dist",
                .layout_path = "layouts/main.html",
                .incremental = self.options.incremental,
                .quiet = self.options.quiet,
                .jobs = self.options.jobs,
            }) catch |err| {
                if (isRecoverableBuildError(err)) {
                    if (!self.options.quiet) {
                        std.debug.print("error: rebuild failed: {s}. Waiting for correction...\n", .{@errorName(err)});
                    }
                    return;
                }
                if (!self.options.quiet) {
                    std.debug.print("error: rebuild failed with unrecoverable I/O error: {s}\n", .{@errorName(err)});
                }
                return err;
            };
        }

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
        if (self.options.targets.items.len > 0) {
            compile.compileHtmlSiteMulti(self.io, self.gpa, self.options.targets.items, .{
                .content_root = self.options.input_dir,
                .layout_path = "layouts/main.html",
                .incremental = self.options.incremental,
                .quiet = self.options.quiet,
                .jobs = self.options.jobs,
            }) catch |err| {
                initial_success = false;
                if (isRecoverableBuildError(err) or err == error.MultiTargetCompilationFailed) {
                    if (!self.options.quiet) {
                        std.debug.print("error: initial build failed: {s}. Continuing to watch...\n", .{@errorName(err)});
                    }
                } else {
                    if (!self.options.quiet) {
                        std.debug.print("error: initial build failed with unrecoverable I/O error: {s}\n", .{@errorName(err)});
                    }
                    return err;
                }
            };
        } else {
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
                if (isRecoverableBuildError(err)) {
                    if (!self.options.quiet) {
                        std.debug.print("error: initial build failed: {s}. Continuing to watch...\n", .{@errorName(err)});
                    }
                } else {
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

        should_shutdown_global.store(false, .unordered);

        while (!should_shutdown_global.load(.unordered)) {
            try self.processEvents();

            if (self.pending_changes.count() > 0) {
                // Debounce window: coalesce trailing events in the burst
                try sleepMs(self.io, debounce_ms);

                // Fetch any additional trailing events, then one serialized rebuild.
                // FS changes during rebuild are observed on the next poll (follow-up).
                try self.processEvents();
                try self.triggerRebuild();
            } else {
                try sleepMs(self.io, idle_poll_ms);
            }
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

    const p4 = try normalizePath(gpa, "./dist");
    defer gpa.free(p4);
    try std.testing.expectEqualStrings("dist", p4);
}

test "hasPathPrefix boundary" {
    try std.testing.expect(hasPathPrefix("dist", "dist"));
    try std.testing.expect(hasPathPrefix("dist/index.html", "dist"));
    try std.testing.expect(!hasPathPrefix("distribution/x.md", "dist"));
    try std.testing.expect(!hasPathPrefix("content/x.md", "dist"));
    try std.testing.expect(hasPathPrefix("content/out/x.html", "content/out"));
    try std.testing.expect(!hasPathPrefix("content/out2/x.html", "content/out"));
}

test "hasPathComponent" {
    try std.testing.expect(hasPathComponent(".boris-cache/manifest.json", ".boris-cache"));
    try std.testing.expect(hasPathComponent("dist/.boris-cache/manifest.json", ".boris-cache"));
    try std.testing.expect(hasPathComponent(".boris/manifest.json", ".boris"));
    try std.testing.expect(!hasPathComponent("content/about-boris.md", ".boris"));
    try std.testing.expect(!hasPathComponent("content/foo.boris.md", ".boris"));
}

test "isIgnored helper" {
    try std.testing.expect(isIgnored("dist/index.html", "dist"));
    try std.testing.expect(isIgnored("dist", "dist"));
    try std.testing.expect(isIgnored("dist/guides/intro.html.tmp", "dist"));
    try std.testing.expect(isIgnored("dist/.boris-cache/manifest.json", "dist"));
    try std.testing.expect(isIgnored(".boris-cache/manifest.json", "dist"));
    try std.testing.expect(!isIgnored("content/guides/intro.md", "dist"));
    try std.testing.expect(!isIgnored("layouts/main.html", "dist"));
    // Prefix false positives must not ignore sibling trees
    try std.testing.expect(!isIgnored("distribution/x.md", "dist"));
    try std.testing.expect(!isIgnored("output/x.html", "out"));
    // Content names containing "boris" must not be ignored
    try std.testing.expect(!isIgnored("content/about-boris.md", "dist"));
    try std.testing.expect(!isIgnored("content/foo.boris.md", "dist"));
}

test "translateToKey helper" {
    const gpa = std.testing.allocator;

    const k1 = try translateToKey(gpa, "content/guides/intro.md", "content");
    defer gpa.free(k1);
    try std.testing.expectEqualStrings("guides/intro.md", k1);

    const k2 = try translateToKey(gpa, "layouts/main.html", "content");
    defer gpa.free(k2);
    try std.testing.expectEqualStrings("layouts/main.html", k2);

    // Sibling prefix must not strip
    const k3 = try translateToKey(gpa, "content2/a.md", "content");
    defer gpa.free(k3);
    try std.testing.expectEqualStrings("content2/a.md", k3);

    // Trailing slash on root is normalized
    const k4 = try translateToKey(gpa, "content/index.md", "content/");
    defer gpa.free(k4);
    try std.testing.expectEqualStrings("index.md", k4);
}

test "FakeWatcher and Coordinator Event Coalescing" {
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

test "processEvents ignores output and staging paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var coord = WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "content",
        .html_dir = "./dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    try fake.pushEvent("dist/index.html", .modify);
    try fake.pushEvent("./dist/page.html", .create);
    try fake.pushEvent("dist/index.html.tmp", .create);
    try fake.pushEvent("content/real.md", .modify);
    try fake.pushEvent("distribution/not-output.md", .modify);

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 2), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("real.md"));
    try std.testing.expect(coord.pending_changes.contains("distribution/not-output.md"));
}

test "processEvents follow-up coalescing after drain" {
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

    try fake.pushEvent("content/a.md", .modify);
    try coord.processEvents();
    try std.testing.expectEqual(@as(usize, 1), coord.pending_changes.count());

    // Simulate drain before rebuild (ownership move)
    var it = coord.pending_changes.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
    }
    coord.pending_changes.clearRetainingCapacity();

    // Events that would land after a rebuild starts / during debounce tail
    try fake.pushEvent("content/b.md", .modify);
    try fake.pushEvent("content/a.md", .modify);
    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 2), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("a.md"));
    try std.testing.expect(coord.pending_changes.contains("b.md"));
}

test "processEvents ignores multi-target output paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var options = cli.Options{
        .mode = .html,
        .input_dir = "content",
        .quiet = true,
        .watch = true,
    };
    try options.targets.append(gpa, .{ .name = "target_a", .output_dir = "dist_a" });
    try options.targets.append(gpa, .{ .name = "target_b", .output_dir = "dist_b" });
    defer options.targets.deinit(gpa);

    var coord = WatchCoordinator.init(gpa, io, options, fake.watcher());
    defer coord.deinit();

    try fake.pushEvent("dist_a/index.html", .modify);
    try fake.pushEvent("dist_b/page.html", .create);
    try fake.pushEvent("content/real.md", .modify);

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 1), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("real.md"));
}

