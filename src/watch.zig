//! Watch mode coordinator, interface, and backends for Boris HTML site builds.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const compile = @import("compile.zig");
const cli = @import("cli.zig");
const target_mod = @import("target.zig");

/// Debounce window after the first change is observed (ms).
pub const debounce_ms: i64 = 100;
/// Maximum time spent coalescing a continuous change burst before forcing a rebuild (ms).
pub const max_debounce_burst_ms: i64 = 2000;
/// Idle poll interval when no changes are pending (ms). Longer than the
/// debounce window to keep full-tree polling cheap on large content roots.
pub const idle_poll_ms: i64 = 500;

/// File identity used for change detection (mtime alone is insufficient on
/// coarse-granularity FS and mtime-preserving writes).
pub const FileStamp = struct {
    mtime_ns: i128,
    size: u64,
};

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

/// Portable polling file watcher comparing recursive filesystem mtime+size.
pub const PollingWatcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    roots: std.ArrayList([]const u8) = .empty,
    file_map: std.StringHashMap(FileStamp),

    pub fn init(allocator: std.mem.Allocator, io: Io) PollingWatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .file_map = std.StringHashMap(FileStamp).init(allocator),
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

                var new_map = std.StringHashMap(FileStamp).init(self.allocator);
                errdefer {
                    var it = new_map.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                    }
                    new_map.deinit();
                }

                for (self.roots.items) |r| {
                    scanFiles(self.io, self.allocator, r, &new_map) catch |err| switch (err) {
                        // Transient FS errors: keep the previous snapshot; do not kill watch.
                        error.AccessDenied,
                        error.SystemFdQuotaExceeded,
                        error.ProcessFdQuotaExceeded,
                        error.NameTooLong,
                        error.Unexpected,
                        => continue,
                        else => return err,
                    };
                }

                // creations & modifications
                var new_it = new_map.iterator();
                while (new_it.next()) |entry| {
                    const path = entry.key_ptr.*;
                    const stamp = entry.value_ptr.*;
                    if (self.file_map.get(path)) |old| {
                        if (old.mtime_ns != stamp.mtime_ns or old.size != stamp.size) {
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

/// True when a directory component should not be walked during poll scans.
/// Staging trees are filtered by path-prefix ignore roots in `processEvents`,
/// not by basename suffix — so a legitimate content dir whose name contains
/// `.boris-stage` is still scanned.
fn shouldSkipScanDir(name: []const u8) bool {
    if (std.mem.eql(u8, name, ".git")) return true;
    if (std.mem.eql(u8, name, "node_modules")) return true;
    if (std.mem.eql(u8, name, ".zig-cache")) return true;
    if (std.mem.eql(u8, name, "zig-cache")) return true;
    if (std.mem.eql(u8, name, "zig-out")) return true;
    if (std.mem.eql(u8, name, ".boris-cache")) return true;
    if (std.mem.eql(u8, name, ".boris")) return true;
    return false;
}

/// Recursively scan files under root using Io.Dir.walkSelectively and populate file_map.
/// Keys are allocator-owned; callers free them. Duplicate paths free the new key and
/// keep the existing map entry (update stamp only).
pub fn scanFiles(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    file_map: *std.StringHashMap(FileStamp),
) !void {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (true) {
        const next_entry = walker.next(io) catch continue; // skip transient walk errors
        const entry = next_entry orelse break;
        if (entry.kind == .sym_link) continue;
        if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.basename)) continue;
            walker.enter(io, entry) catch continue;
            continue;
        }
        if (entry.kind != .file) continue;

        const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        errdefer allocator.free(full_path);

        const stamp = FileStamp{
            .mtime_ns = @intCast(stat.mtime.nanoseconds),
            .size = stat.size,
        };
        const gop = try file_map.getOrPut(full_path);
        if (gop.found_existing) {
            allocator.free(full_path);
            gop.value_ptr.* = stamp;
        } else {
            gop.value_ptr.* = stamp;
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

/// Normalize path for watch comparisons: forward slashes, strip redundant
/// leading `./`, trailing `/`, empty segments, and `.` components. `..`
/// components pop the previous segment when possible so equivalent layout
/// spellings (`./layouts/main.html`, `layouts/./main.html`) compare equal.
pub fn normalizePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]const u8 {
    var scratch = try allocator.alloc(u8, raw_path.len);
    errdefer allocator.free(scratch);
    for (raw_path, 0..) |c, i| {
        scratch[i] = if (c == '\\') '/' else c;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= scratch.len) : (i += 1) {
        if (i != scratch.len and scratch[i] != '/') continue;
        const seg = scratch[start..i];
        start = i + 1;
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // Pop previous segment when present; otherwise keep leading "..".
            if (result.items.len == 0) {
                try result.appendSlice(allocator, "..");
                continue;
            }
            if (std.mem.eql(u8, result.items, "..") or
                std.mem.endsWith(u8, result.items, "/.."))
            {
                try result.append(allocator, '/');
                try result.appendSlice(allocator, "..");
                continue;
            }
            if (std.mem.lastIndexOfScalar(u8, result.items, '/')) |slash| {
                result.shrinkRetainingCapacity(slash);
            } else {
                result.clearRetainingCapacity();
            }
            continue;
        }
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, seg);
    }

    allocator.free(scratch);
    return try result.toOwnedSlice(allocator);
}

/// True when `path` is the sibling staging tree of `html_dir`
/// (`{html_dir}.boris-stage` or a path under it). Path-boundary only — not a
/// substring search — so content paths containing the text `.boris-stage` stay live.
pub fn isSiblingStagePath(path: []const u8, html_dir: []const u8) bool {
    if (html_dir.len == 0) return false;
    if (!std.mem.startsWith(u8, path, html_dir)) return false;
    const rest = path[html_dir.len..];
    const stage_suffix = ".boris-stage";
    if (!std.mem.startsWith(u8, rest, stage_suffix)) return false;
    const after = rest[stage_suffix.len..];
    return after.len == 0 or after[0] == '/';
}

/// Ignore output, temp, staging, or cache directory files to prevent loops.
/// `path` and `html_dir` must already use forward slashes (normalized).
/// Staging is matched only as the sibling tree of this `html_dir`, not by
/// arbitrary `.boris-stage` substrings in author paths.
pub fn isIgnored(path: []const u8, html_dir: []const u8) bool {
    if (hasPathPrefix(path, html_dir)) return true;
    // Sibling staging tree for this output root: `{html_dir}.boris-stage`
    if (isSiblingStagePath(path, html_dir)) return true;
    if (std.mem.endsWith(u8, path, ".tmp") or std.mem.containsAtLeast(u8, path, 1, ".tmp.")) return true;
    // Component-aware so content names like `about-boris.md` are not dropped.
    if (hasPathComponent(path, ".boris-cache")) return true;
    if (hasPathComponent(path, ".boris")) return true;
    return false;
}

/// Select which targets must rebuild for a batch of changed keys (watch fan-out).
///
/// - Content/include/unknown paths → all targets
/// - Paths that equal a target's effective layout file (after path normalization)
///   → only those targets
///
/// Returns a GPA-owned slice of TargetSpec copies (string fields still borrow argv).
/// Caller frees the slice only.
pub fn selectTargetsForRebuild(
    gpa: std.mem.Allocator,
    changed_keys: []const []const u8,
    all_targets: []const target_mod.TargetSpec,
    default_layout: []const u8,
) ![]const target_mod.TargetSpec {
    if (all_targets.len == 0 or changed_keys.len == 0) {
        return try gpa.dupe(target_mod.TargetSpec, all_targets);
    }

    // Normalize fallback + rule layout paths so `./layouts/main.html` and
    // `layouts/./main.html` match event keys the same way. A layout edit fans
    // out only to targets that declare that path (fallback or rule).
    var layout_lists = try gpa.alloc([]const []const u8, all_targets.len);
    defer {
        for (layout_lists) |list| {
            for (list) |p| gpa.free(p);
            gpa.free(list);
        }
        gpa.free(layout_lists);
    }
    for (all_targets, 0..) |t, i| {
        const declared = try target_mod.declaredLayoutPaths(gpa, t, default_layout);
        defer gpa.free(declared);
        var norms = try gpa.alloc([]const u8, declared.len);
        for (declared, 0..) |lp, j| {
            norms[j] = try normalizePath(gpa, lp);
        }
        layout_lists[i] = norms;
    }

    var rebuild_all = false;
    var need = try gpa.alloc(bool, all_targets.len);
    defer gpa.free(need);
    @memset(need, false);

    for (changed_keys) |key| {
        const norm_key = try normalizePath(gpa, key);
        defer gpa.free(norm_key);

        var matched_any_layout = false;
        for (layout_lists, 0..) |norms, i| {
            for (norms) |norm_lp| {
                if (std.mem.eql(u8, norm_key, norm_lp)) {
                    need[i] = true;
                    matched_any_layout = true;
                    break;
                }
            }
        }
        if (!matched_any_layout) {
            rebuild_all = true;
            break;
        }
    }

    if (rebuild_all) {
        return try gpa.dupe(target_mod.TargetSpec, all_targets);
    }

    var count: usize = 0;
    for (need) |n| {
        if (n) count += 1;
    }
    if (count == 0) {
        return try gpa.dupe(target_mod.TargetSpec, all_targets);
    }

    var out = try gpa.alloc(target_mod.TargetSpec, count);
    var o: usize = 0;
    for (all_targets, 0..) |t, i| {
        if (need[i]) {
            out[o] = t;
            o += 1;
        }
    }
    return out;
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

/// Default layout path used by watch rebuilds (shared global layout for this slice).
pub const default_watch_layout: []const u8 = "layouts/main.html";

/// Coordinator running the debounced watch and serialized rebuild cycles.
pub const WatchCoordinator = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: cli.Options,
    watcher: Watcher,
    pending_changes: std.StringHashMap(void),
    /// Normalized forward-slash output roots, computed once at init.
    ignored_output_roots: []const []const u8,

    /// Build the ignore-root list once for the coordinator lifetime
    /// (final outs + sibling `.boris-stage` trees).
    fn buildIgnoredOutputRoots(gpa: std.mem.Allocator, options: cli.Options) ![]const []const u8 {
        var roots: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (roots.items) |r| gpa.free(r);
            roots.deinit(gpa);
        }

        if (options.targets.items.len > 0) {
            try roots.ensureTotalCapacity(gpa, options.targets.items.len * 2);
            for (options.targets.items) |tgt| {
                const out = try normalizePath(gpa, tgt.output_dir);
                try roots.append(gpa, out);
                const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{out});
                try roots.append(gpa, stage);
            }
        } else {
            const html_raw = options.html_dir orelse "dist";
            const out = try normalizePath(gpa, html_raw);
            try roots.append(gpa, out);
            const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{out});
            try roots.append(gpa, stage);
        }
        return try roots.toOwnedSlice(gpa);
    }

    pub fn init(gpa: std.mem.Allocator, io: Io, options: cli.Options, watcher: Watcher) !WatchCoordinator {
        const ignored = try buildIgnoredOutputRoots(gpa, options);
        errdefer {
            for (ignored) |r| gpa.free(r);
            gpa.free(ignored);
        }
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .watcher = watcher,
            .pending_changes = std.StringHashMap(void).init(gpa),
            .ignored_output_roots = ignored,
        };
    }

    pub fn deinit(self: *WatchCoordinator) void {
        var it = self.pending_changes.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.pending_changes.deinit();
        for (self.ignored_output_roots) |r| {
            self.gpa.free(r);
        }
        self.gpa.free(self.ignored_output_roots);
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
            for (self.ignored_output_roots) |root| {
                if (isIgnored(normalized, root)) {
                    ignored = true;
                    break;
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
        // Layout-only changes fan out to affected targets only.
        const layout_default = self.options.html_layout;
        if (self.options.targets.items.len > 0) {
            const subset = try selectTargetsForRebuild(
                self.gpa,
                paths.items,
                self.options.targets.items,
                layout_default,
            );
            defer self.gpa.free(subset);

            if (!self.options.quiet and subset.len < self.options.targets.items.len) {
                std.debug.print("watch: selective rebuild of {d}/{d} target(s)\n", .{
                    subset.len,
                    self.options.targets.items.len,
                });
            }

            compile.compileHtmlSiteMulti(self.io, self.gpa, subset, .{
                .content_root = self.options.input_dir,
                .layout_path = layout_default,
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
                .layout_path = layout_default,
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
        const layout_default = self.options.html_layout;
        if (self.options.targets.items.len > 0) {
            compile.compileHtmlSiteMulti(self.io, self.gpa, self.options.targets.items, .{
                .content_root = self.options.input_dir,
                .layout_path = layout_default,
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
                .layout_path = layout_default,
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
            self.processEvents() catch |err| {
                // Transient poll failures must not kill the session (#15).
                if (!self.options.quiet) {
                    std.debug.print("watch: poll error ({s}); retrying...\n", .{@errorName(err)});
                }
                try sleepMs(self.io, idle_poll_ms);
                continue;
            };

            if (self.pending_changes.count() > 0) {
                // Coalesce trailing events up to a hard burst cap so a file that
                // keeps changing faster than a rebuild cannot loop forever (#17).
                var coalesced: i64 = 0;
                while (coalesced < max_debounce_burst_ms) {
                    try sleepMs(self.io, debounce_ms);
                    coalesced += debounce_ms;
                    const before = self.pending_changes.count();
                    self.processEvents() catch break;
                    if (self.pending_changes.count() == before) break;
                }

                // FS changes during rebuild are observed on the next poll (follow-up).
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

    // Equivalent layout spellings collapse to the same key
    const p5 = try normalizePath(gpa, "./layouts/main.html");
    defer gpa.free(p5);
    const p6 = try normalizePath(gpa, "layouts/./main.html");
    defer gpa.free(p6);
    const p7 = try normalizePath(gpa, "layouts/main.html");
    defer gpa.free(p7);
    try std.testing.expectEqualStrings("layouts/main.html", p5);
    try std.testing.expectEqualStrings("layouts/main.html", p6);
    try std.testing.expectEqualStrings(p5, p6);
    try std.testing.expectEqualStrings(p5, p7);

    const p8 = try normalizePath(gpa, "layouts/foo/../main.html");
    defer gpa.free(p8);
    try std.testing.expectEqualStrings("layouts/main.html", p8);
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
    // Sibling stage of this output root is ignored (path-boundary, not substring)
    try std.testing.expect(isIgnored("dist.boris-stage", "dist"));
    try std.testing.expect(isIgnored("dist.boris-stage/x.html", "dist"));
    try std.testing.expect(isSiblingStagePath("dist.boris-stage/x.html", "dist"));
    // Legitimate source paths that merely contain the text `.boris-stage` stay live
    try std.testing.expect(!isIgnored("content/notes.boris-stage/readme.md", "dist"));
    try std.testing.expect(!isIgnored("content/about.boris-stage.md", "dist"));
    try std.testing.expect(!isIgnored("content/foo.boris-stage", "dist"));
    try std.testing.expect(!isSiblingStagePath("content/notes.boris-stage/readme.md", "dist"));
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

    var coord = try WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "content",
        .html_dir = "dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    try std.testing.expectEqual(@as(usize, 2), coord.ignored_output_roots.len);
    try std.testing.expectEqualStrings("dist", coord.ignored_output_roots[0]);
    try std.testing.expectEqualStrings("dist.boris-stage", coord.ignored_output_roots[1]);

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

    var coord = try WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "content",
        .html_dir = "./dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    try std.testing.expectEqualStrings("dist", coord.ignored_output_roots[0]);
    try std.testing.expectEqualStrings("dist.boris-stage", coord.ignored_output_roots[1]);

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

    var coord = try WatchCoordinator.init(gpa, io, .{
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

    var coord = try WatchCoordinator.init(gpa, io, options, fake.watcher());
    defer coord.deinit();

    try std.testing.expectEqual(@as(usize, 4), coord.ignored_output_roots.len);

    try fake.pushEvent("dist_a/index.html", .modify);
    try fake.pushEvent("dist_b/page.html", .create);
    try fake.pushEvent("dist_a.boris-stage/x.html", .create);
    try fake.pushEvent("content/real.md", .modify);

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 1), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("real.md"));
}

test "selectTargetsForRebuild layout vs content fan-out" {
    const gpa = std.testing.allocator;
    const targets = [_]target_mod.TargetSpec{
        .{ .name = "prod", .output_dir = "dist/prod", .layout_path = null },
        .{ .name = "stage", .output_dir = "dist/stage", .layout_path = "layouts/stage.html" },
    };

    // Content change → all targets
    {
        const keys = [_][]const u8{"guides/intro.md"};
        const subset = try selectTargetsForRebuild(gpa, &keys, &targets, "layouts/main.html");
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 2), subset.len);
    }

    // Shared default layout → only targets using that layout (prod)
    {
        const keys = [_][]const u8{"layouts/main.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, &targets, "layouts/main.html");
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("prod", subset[0].name);
    }

    // Stage-only layout → only stage
    {
        const keys = [_][]const u8{"layouts/stage.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, &targets, "layouts/main.html");
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("stage", subset[0].name);
    }
}

test "selectTargetsForRebuild normalizes layout path spellings" {
    const gpa = std.testing.allocator;
    const targets = [_]target_mod.TargetSpec{
        .{ .name = "prod", .output_dir = "dist/prod", .layout_path = null },
        .{ .name = "stage", .output_dir = "dist/stage", .layout_path = "./layouts/stage.html" },
    };

    // Event key and default layout use different but equivalent spellings
    {
        const keys = [_][]const u8{"./layouts/main.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, &targets, "layouts/./main.html");
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("prod", subset[0].name);
    }
    {
        const keys = [_][]const u8{"layouts/./stage.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, &targets, "layouts/main.html");
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("stage", subset[0].name);
    }
    {
        const keys = [_][]const u8{"layouts/foo/../main.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, &targets, "./layouts/main.html");
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("prod", subset[0].name);
    }
}

test "processEvents does not ignore legitimate .boris-stage source paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var coord = try WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "content",
        .html_dir = "dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    // Real staging tree is ignored
    try fake.pushEvent("dist.boris-stage/page.html", .create);
    // Author paths that contain the text must still queue
    try fake.pushEvent("content/notes.boris-stage/readme.md", .modify);
    try fake.pushEvent("content/about.boris-stage.md", .modify);
    try fake.pushEvent("content/foo.boris-stage", .create);

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 3), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("notes.boris-stage/readme.md"));
    try std.testing.expect(coord.pending_changes.contains("about.boris-stage.md"));
    try std.testing.expect(coord.pending_changes.contains("foo.boris-stage"));
}

test "processEvents custom input root maps relative keys" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var coord = try WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "./docs/src",
        .html_dir = "dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    try fake.pushEvent("docs/src/guides/intro.md", .modify);
    try fake.pushEvent("./docs/src/index.md", .create);
    try fake.pushEvent("docs/src/./nested.md", .modify);
    try fake.pushEvent("layouts/main.html", .modify);
    try fake.pushEvent("dist/index.html", .modify); // ignored

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 4), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("guides/intro.md"));
    try std.testing.expect(coord.pending_changes.contains("index.md"));
    try std.testing.expect(coord.pending_changes.contains("nested.md"));
    try std.testing.expect(coord.pending_changes.contains("layouts/main.html"));
}

test "processEvents target-specific layout keys stay outside content strip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var options = cli.Options{
        .mode = .html,
        .input_dir = "content",
        .html_layout = "./layouts/main.html",
        .quiet = true,
        .watch = true,
    };
    try options.targets.append(gpa, .{ .name = "prod", .output_dir = "dist/prod", .layout_path = null });
    try options.targets.append(gpa, .{
        .name = "stage",
        .output_dir = "dist/stage",
        .layout_path = "layouts/./stage.html",
    });
    defer options.targets.deinit(gpa);

    var coord = try WatchCoordinator.init(gpa, io, options, fake.watcher());
    defer coord.deinit();

    try fake.pushEvent("content/shared.md", .modify);
    try fake.pushEvent("./layouts/main.html", .modify);
    try fake.pushEvent("layouts/./stage.html", .modify);
    try fake.pushEvent("dist/prod/index.html", .modify);
    try fake.pushEvent("dist/stage.boris-stage/x.html", .create);

    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 3), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("shared.md"));
    try std.testing.expect(coord.pending_changes.contains("layouts/main.html"));
    try std.testing.expect(coord.pending_changes.contains("layouts/stage.html"));

    // Shared content → all targets; each layout → only matching target
    {
        const keys = [_][]const u8{"shared.md"};
        const subset = try selectTargetsForRebuild(gpa, &keys, options.targets.items, options.html_layout);
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 2), subset.len);
    }
    {
        const keys = [_][]const u8{"layouts/main.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, options.targets.items, options.html_layout);
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("prod", subset[0].name);
    }
    {
        const keys = [_][]const u8{"layouts/stage.html"};
        const subset = try selectTargetsForRebuild(gpa, &keys, options.targets.items, options.html_layout);
        defer gpa.free(subset);
        try std.testing.expectEqual(@as(usize, 1), subset.len);
        try std.testing.expectEqualStrings("stage", subset[0].name);
    }
}

test "watch recovery: pending drains and follow-up events still queue" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();

    var coord = try WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = "content",
        .html_dir = "dist",
        .quiet = true,
        .watch = true,
    }, fake.watcher());
    defer coord.deinit();

    // First burst (e.g. content failure path still clears pending at rebuild start)
    try fake.pushEvent("content/bad.md", .modify);
    try coord.processEvents();
    try std.testing.expectEqual(@as(usize, 1), coord.pending_changes.count());

    var it = coord.pending_changes.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
    }
    coord.pending_changes.clearRetainingCapacity();

    // Author corrects file; watcher must accept the next event without restart
    try fake.pushEvent("content/bad.md", .modify);
    try fake.pushEvent("content/ok.md", .create);
    try coord.processEvents();

    try std.testing.expectEqual(@as(usize, 2), coord.pending_changes.count());
    try std.testing.expect(coord.pending_changes.contains("bad.md"));
    try std.testing.expect(coord.pending_changes.contains("ok.md"));
}

test "isRecoverableBuildError classification stays content-only" {
    // Mirrors WatchCoordinator recovery policy: content/layout errors continue;
    // hard I/O does not. Keep this aligned with isRecoverableBuildError.
    try std.testing.expect(isRecoverableBuildError(error.ParseFailed));
    try std.testing.expect(isRecoverableBuildError(error.ComponentFailed));
    try std.testing.expect(isRecoverableBuildError(error.LayoutMissingMarker));
    try std.testing.expect(isRecoverableBuildError(error.LayoutDuplicateMarker));
    try std.testing.expect(!isRecoverableBuildError(error.FileNotFound));
    try std.testing.expect(!isRecoverableBuildError(error.AccessDenied));
}
