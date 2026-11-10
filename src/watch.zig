//! Watch mode coordinator, interface, and backends for Boris HTML site builds.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const compile = @import("compile.zig");
const cli = @import("cli.zig");
const diag = @import("diag.zig");
const pipeline = @import("pipeline.zig");
const target_mod = @import("target.zig");
const preview_server = @import("preview_server.zig");
const html_report = @import("html_report.zig");
const watch_json = @import("watch_json.zig");
const timings = @import("timings.zig");
const publication_touches_mod = @import("publication_touches.zig");
const nostr_emit = @import("nostr_emit.zig");

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
                const self: *FakeWatcher = @ptrCast(@alignCast(ptr));
                self.deinit();
            }
        }.deinit,
        .poll = struct {
            fn poll(ptr: *anyopaque, events: *std.ArrayList(Event)) anyerror!void {
                const self: *FakeWatcher = @ptrCast(@alignCast(ptr));
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
///
/// Retains the tracked path map and traversal buffers across poll cycles so an
/// unchanged tree performs zero heap allocations after warm-up, and uses
/// Darwin's `getattrlistbulk(2)` bulk directory+attribute syscall when
/// available to avoid per-file `fstatat` churn on large trees.
pub const PollingWatcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    roots: std.ArrayList([]const u8) = .empty,
    file_map: std.StringHashMap(TrackedFile),
    generation: u64 = 0,
    scan_scratch: ScanScratch = .{},
    pending_events: std.ArrayList(Event) = .empty,
    rollback_log: std.ArrayList(RollbackEntry) = .empty,
    deleted_keys: std.ArrayList([]const u8) = .empty,

    const TrackedFile = struct {
        stamp: FileStamp,
        seen_gen: u64,
    };

    const RollbackEntry = union(enum) {
        inserted: []const u8,
        modified: struct {
            key: []const u8,
            old_stamp: FileStamp,
        },
    };

    pub fn init(allocator: std.mem.Allocator, io: Io) PollingWatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .file_map = std.StringHashMap(TrackedFile).init(allocator),
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

        for (self.pending_events.items) |ev| {
            self.allocator.free(ev.path);
        }
        self.pending_events.deinit(self.allocator);
        self.rollback_log.deinit(self.allocator);
        self.deleted_keys.deinit(self.allocator);
        self.scan_scratch.deinit(self.allocator);
    }

    pub fn addRoot(self: *PollingWatcher, root_path: []const u8) !void {
        const dup = try self.allocator.dupe(u8, root_path);
        errdefer self.allocator.free(dup);
        try self.roots.append(self.allocator, dup);
        errdefer _ = self.roots.pop();
        try scanRootWithScratch(
            false,
            *PollingWatcher,
            self.io,
            self.allocator,
            dup,
            &self.scan_scratch,
            self,
            self.generation,
            recordInitialFile,
        );
    }

    pub fn watcher(self: *PollingWatcher) Watcher {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn recordInitialFile(self: *PollingWatcher, full_path: []const u8, stamp: FileStamp, gen: u64) !void {
        if (self.file_map.getPtr(full_path)) |tracked| {
            tracked.stamp = stamp;
            tracked.seen_gen = gen;
            return;
        }
        try self.file_map.ensureUnusedCapacity(1);
        const owned_key = try self.allocator.dupe(u8, full_path);
        self.file_map.putAssumeCapacityNoClobber(owned_key, .{
            .stamp = stamp,
            .seen_gen = gen,
        });
    }

    fn recordPollFile(self: *PollingWatcher, full_path: []const u8, stamp: FileStamp, gen: u64) !void {
        if (self.file_map.getEntry(full_path)) |entry| {
            const tracked = entry.value_ptr;
            if (tracked.seen_gen != gen) {
                if (tracked.stamp.mtime_ns == stamp.mtime_ns and tracked.stamp.size == stamp.size) {
                    tracked.seen_gen = gen;
                    return;
                }
                try self.rollback_log.ensureUnusedCapacity(self.allocator, 1);
                try self.pending_events.ensureUnusedCapacity(self.allocator, 1);
                const event_path = try self.allocator.dupe(u8, entry.key_ptr.*);
                self.rollback_log.appendAssumeCapacity(.{
                    .modified = .{
                        .key = entry.key_ptr.*,
                        .old_stamp = tracked.stamp,
                    },
                });
                tracked.stamp = stamp;
                tracked.seen_gen = gen;
                self.pending_events.appendAssumeCapacity(.{ .path = event_path, .kind = .modify });
            } else {
                tracked.stamp = stamp;
            }
            return;
        }

        try self.file_map.ensureUnusedCapacity(1);
        try self.rollback_log.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_events.ensureUnusedCapacity(self.allocator, 1);
        const owned_key = try self.allocator.dupe(u8, full_path);
        errdefer self.allocator.free(owned_key);
        const event_path = try self.allocator.dupe(u8, owned_key);
        self.file_map.putAssumeCapacityNoClobber(owned_key, .{
            .stamp = stamp,
            .seen_gen = gen,
        });
        self.rollback_log.appendAssumeCapacity(.{ .inserted = owned_key });
        self.pending_events.appendAssumeCapacity(.{ .path = event_path, .kind = .create });
    }

    fn rollbackPoll(self: *PollingWatcher) void {
        var i = self.rollback_log.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.rollback_log.items[i]) {
                .inserted => |owned_key| {
                    _ = self.file_map.remove(owned_key);
                    self.allocator.free(owned_key);
                },
                .modified => |m| {
                    if (self.file_map.getPtr(m.key)) |tracked| {
                        tracked.stamp = m.old_stamp;
                    }
                },
            }
        }
        self.rollback_log.clearRetainingCapacity();

        for (self.pending_events.items) |ev| {
            self.allocator.free(ev.path);
        }
        self.pending_events.clearRetainingCapacity();
        self.deleted_keys.clearRetainingCapacity();
    }

    const VTABLE = Watcher.VTable{
        .deinit = struct {
            fn deinit(ptr: *anyopaque) void {
                const self: *PollingWatcher = @ptrCast(@alignCast(ptr));
                self.deinit();
            }
        }.deinit,
        .poll = struct {
            fn poll(ptr: *anyopaque, events: *std.ArrayList(Event)) anyerror!void {
                const self: *PollingWatcher = @ptrCast(@alignCast(ptr));

                self.generation +%= 1;
                const gen = self.generation;
                errdefer self.rollbackPoll();

                var scan_failed = false;
                for (self.roots.items) |r| {
                    scanRootWithScratch(
                        false,
                        *PollingWatcher,
                        self.io,
                        self.allocator,
                        r,
                        &self.scan_scratch,
                        self,
                        gen,
                        recordPollFile,
                    ) catch |err| switch (err) {
                        // Transient FS errors: keep the previous snapshot; do not kill watch.
                        error.AccessDenied,
                        error.PermissionDenied,
                        error.SystemFdQuotaExceeded,
                        error.ProcessFdQuotaExceeded,
                        error.NameTooLong,
                        error.Unexpected,
                        => {
                            scan_failed = true;
                            break;
                        },
                        else => return err,
                    };
                }

                if (scan_failed) {
                    // A root failed transiently: a partial scan would emit mass
                    // delete events and poison the next poll. Revert any staged
                    // mutations, keep the previous snapshot, and emit nothing.
                    self.rollbackPoll();
                    return;
                }

                // Stage deletions before mutating `file_map` so allocation failure
                // rolls back cleanly without losing tracked state.
                self.deleted_keys.clearRetainingCapacity();
                var old_it = self.file_map.iterator();
                while (old_it.next()) |entry| {
                    if (entry.value_ptr.seen_gen != gen) {
                        try self.deleted_keys.ensureUnusedCapacity(self.allocator, 1);
                        try self.pending_events.ensureUnusedCapacity(self.allocator, 1);
                        const dup = try self.allocator.dupe(u8, entry.key_ptr.*);
                        self.deleted_keys.appendAssumeCapacity(entry.key_ptr.*);
                        self.pending_events.appendAssumeCapacity(.{ .path = dup, .kind = .delete });
                    }
                }

                if (self.pending_events.items.len > 0) {
                    try events.ensureUnusedCapacity(self.allocator, self.pending_events.items.len);
                }

                // Commit point: no operations below can fail.
                for (self.deleted_keys.items) |key| {
                    _ = self.file_map.remove(key);
                    self.allocator.free(key);
                }
                self.deleted_keys.clearRetainingCapacity();
                self.rollback_log.clearRetainingCapacity();

                if (self.pending_events.items.len > 0) {
                    events.appendSliceAssumeCapacity(self.pending_events.items);
                    self.pending_events.clearRetainingCapacity();
                }
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

const scan_io_buf_len: usize = 32 * 1024;
const scan_io_buf_align: std.mem.Alignment = .fromByteUnits(@max(@alignOf(usize), 8));
const use_darwin_bulk_attr = builtin.os.tag.isDarwin() and builtin.link_libc;

comptime {
    std.debug.assert(scan_io_buf_len >= Io.Dir.Reader.min_buffer_len);
}

const ChildSpan = struct {
    offset: usize,
    len: usize,
};

const DirFrame = struct {
    dir: Io.Dir,
    path_len: usize,
    names_base: usize,
    children_start: usize,
    children_end: usize,
    next_child: usize,
};

const ScanScratch = struct {
    path_buf: std.ArrayList(u8) = .empty,
    child_names: std.ArrayList(u8) = .empty,
    child_spans: std.ArrayList(ChildSpan) = .empty,
    dir_stack: std.ArrayList(DirFrame) = .empty,
    io_buf: ?[]align(scan_io_buf_align.toByteUnits()) u8 = null,

    fn deinit(self: *ScanScratch, allocator: std.mem.Allocator) void {
        if (self.io_buf) |buf| allocator.free(buf);
        self.dir_stack.deinit(allocator);
        self.child_spans.deinit(allocator);
        self.child_names.deinit(allocator);
        self.path_buf.deinit(allocator);
    }

    fn ensureIoBuf(
        self: *ScanScratch,
        allocator: std.mem.Allocator,
    ) ![]align(scan_io_buf_align.toByteUnits()) u8 {
        if (self.io_buf) |buf| return buf;
        const buf = try allocator.alignedAlloc(u8, scan_io_buf_align, scan_io_buf_len);
        self.io_buf = buf;
        return buf;
    }

    fn pushChildDir(self: *ScanScratch, allocator: std.mem.Allocator, name: []const u8) !void {
        const offset = self.child_names.items.len;
        try self.child_names.appendSlice(allocator, name);
        errdefer self.child_names.shrinkRetainingCapacity(offset);
        try self.child_spans.append(allocator, .{ .offset = offset, .len = name.len });
    }

    fn buildChildPath(
        self: *ScanScratch,
        allocator: std.mem.Allocator,
        parent_len: usize,
        child_name: []const u8,
    ) ![]const u8 {
        self.path_buf.shrinkRetainingCapacity(parent_len);
        const need_sep = parent_len > 0 and !std.fs.path.isSep(self.path_buf.items[parent_len - 1]);
        try self.path_buf.ensureUnusedCapacity(allocator, @intFromBool(need_sep) + child_name.len);
        if (need_sep) {
            self.path_buf.appendAssumeCapacity(std.fs.path.sep);
        }
        self.path_buf.appendSliceAssumeCapacity(child_name);
        return self.path_buf.items;
    }

    fn resetTransient(self: *ScanScratch, io: Io) void {
        while (self.dir_stack.pop()) |frame| {
            frame.dir.close(io);
        }
        self.child_spans.clearRetainingCapacity();
        self.child_names.clearRetainingCapacity();
        self.path_buf.clearRetainingCapacity();
    }
};

const darwin_bulk = struct {
    const ATTR_BIT_MAP_COUNT: u16 = 5;
    const FSOPT_NOFOLLOW: u64 = 0x00000001;

    const ATTR_CMN_NAME: u32 = 0x00000001;
    const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
    const ATTR_CMN_MODTIME: u32 = 0x00000400;
    const ATTR_CMN_ERROR: u32 = 0x20000000;
    const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;

    const ATTR_FILE_DATALENGTH: u32 = 0x00000200;

    const VREG: u32 = 1;
    const VDIR: u32 = 2;

    const AttrList = extern struct {
        bitmapcount: u16 = ATTR_BIT_MAP_COUNT,
        reserved: u16 = 0,
        commonattr: u32 = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME,
        volattr: u32 = 0,
        dirattr: u32 = 0,
        fileattr: u32 = ATTR_FILE_DATALENGTH,
        forkattr: u32 = 0,
    };

    const Outcome = enum {
        completed,
        unsupported_fallback,
    };

    extern "c" fn getattrlistbulk(
        dirfd: c_int,
        attr_list: *const AttrList,
        attr_buf: *anyopaque,
        attr_buf_size: usize,
        options: u64,
    ) c_int;
};

fn scanSingleDirDarwin(
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    parent_path_len: usize,
    scratch: *ScanScratch,
    io_buf: []align(scan_io_buf_align.toByteUnits()) u8,
    ctx: Ctx,
    gen: u64,
    comptime onFile: fn (Ctx, []const u8, FileStamp, u64) anyerror!void,
) !darwin_bulk.Outcome {
    const attr_list: darwin_bulk.AttrList = .{};
    var calls_made: usize = 0;

    while (true) {
        const rc = darwin_bulk.getattrlistbulk(
            dir.handle,
            &attr_list,
            io_buf.ptr,
            io_buf.len,
            darwin_bulk.FSOPT_NOFOLLOW,
        );
        if (rc == 0) return .completed;
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            if (calls_made == 0) {
                switch (err) {
                    .NOSYS, .OPNOTSUPP, .INVAL, .BADF, .RANGE => return .unsupported_fallback,
                    else => {},
                }
            }
            return switch (err) {
                .ACCES => error.AccessDenied,
                .PERM => error.PermissionDenied,
                else => error.Unexpected,
            };
        }
        calls_made += 1;

        const entry_count: usize = @intCast(rc);
        var buf_offset: usize = 0;
        var idx: usize = 0;
        while (idx < entry_count) : (idx += 1) {
            if (buf_offset + 4 > io_buf.len) break;
            const rec_len: usize = std.mem.readInt(u32, io_buf[buf_offset..][0..4], .native);
            if (rec_len < 24 or buf_offset + rec_len > io_buf.len) break;
            const record = io_buf[buf_offset .. buf_offset + rec_len];
            buf_offset += rec_len;

            const ret_common = std.mem.readInt(u32, record[4..8], .native);
            const ret_file = std.mem.readInt(u32, record[16..20], .native);
            var cursor: usize = 24; // 4-byte length + 20-byte attribute_set_t

            var entry_err: u32 = 0;
            if ((ret_common & darwin_bulk.ATTR_CMN_ERROR) != 0) {
                if (cursor + 4 > record.len) continue;
                entry_err = std.mem.readInt(u32, record[cursor..][0..4], .native);
                cursor += 4;
            }

            var maybe_name: ?[]const u8 = null;
            if ((ret_common & darwin_bulk.ATTR_CMN_NAME) != 0) {
                if (cursor + 8 > record.len) continue;
                const name_ref_pos = cursor;
                const data_offset = std.mem.readInt(i32, record[cursor..][0..4], .native);
                const data_len: usize = std.mem.readInt(u32, record[cursor + 4 ..][0..4], .native);
                cursor += 8;
                if (data_offset >= 0 and data_len > 0) {
                    const start = std.math.add(usize, name_ref_pos, @intCast(data_offset)) catch continue;
                    const end = std.math.add(usize, start, data_len) catch continue;
                    if (end <= record.len) {
                        maybe_name = std.mem.sliceTo(record[start..end], 0);
                    }
                }
            }

            if (entry_err != 0) continue;
            const entry_name = maybe_name orelse continue;
            if (entry_name.len == 0 or std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) {
                continue;
            }

            if ((ret_common & darwin_bulk.ATTR_CMN_OBJTYPE) == 0) {
                try statAndVisitEntry(Ctx, io, allocator, dir, parent_path_len, entry_name, scratch, ctx, gen, onFile);
                continue;
            }
            if (cursor + 4 > record.len) continue;
            const obj_type = std.mem.readInt(u32, record[cursor..][0..4], .native);
            cursor += 4;

            switch (obj_type) {
                darwin_bulk.VDIR => {
                    if (!shouldSkipScanDir(entry_name)) {
                        try scratch.pushChildDir(allocator, entry_name);
                    }
                },
                darwin_bulk.VREG => {
                    const tv_bytes = 2 * @sizeOf(isize);
                    if ((ret_common & darwin_bulk.ATTR_CMN_MODTIME) != 0 and
                        (ret_file & darwin_bulk.ATTR_FILE_DATALENGTH) != 0 and
                        cursor + tv_bytes + 8 <= record.len)
                    {
                        const tv_sec = std.mem.readInt(isize, record[cursor..][0..@sizeOf(isize)], .native);
                        const tv_nsec = std.mem.readInt(isize, record[cursor + @sizeOf(isize) ..][0..@sizeOf(isize)], .native);
                        const data_len = std.mem.readInt(i64, record[cursor + tv_bytes ..][0..8], .native);
                        if (data_len >= 0) {
                            const full_path = try scratch.buildChildPath(allocator, parent_path_len, entry_name);
                            try onFile(ctx, full_path, .{
                                .mtime_ns = @as(i128, tv_sec) * std.time.ns_per_s + tv_nsec,
                                .size = @intCast(data_len),
                            }, gen);
                            continue;
                        }
                    }
                    try statAndVisitFile(Ctx, io, allocator, dir, parent_path_len, entry_name, scratch, ctx, gen, onFile);
                },
                else => continue, // symlinks (VLNK) and special nodes are ignored
            }
        }
    }
}

fn statAndVisitFile(
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    parent_path_len: usize,
    entry_name: []const u8,
    scratch: *ScanScratch,
    ctx: Ctx,
    gen: u64,
    comptime onFile: fn (Ctx, []const u8, FileStamp, u64) anyerror!void,
) !void {
    const stat = dir.statFile(io, entry_name, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file) return;
    const full_path = try scratch.buildChildPath(allocator, parent_path_len, entry_name);
    try onFile(ctx, full_path, .{
        .mtime_ns = @intCast(stat.mtime.nanoseconds),
        .size = stat.size,
    }, gen);
}

fn statAndVisitEntry(
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    parent_path_len: usize,
    entry_name: []const u8,
    scratch: *ScanScratch,
    ctx: Ctx,
    gen: u64,
    comptime onFile: fn (Ctx, []const u8, FileStamp, u64) anyerror!void,
) !void {
    const stat = dir.statFile(io, entry_name, .{ .follow_symlinks = false }) catch return;
    switch (stat.kind) {
        .directory => {
            if (!shouldSkipScanDir(entry_name)) {
                try scratch.pushChildDir(allocator, entry_name);
            }
        },
        .file => {
            const full_path = try scratch.buildChildPath(allocator, parent_path_len, entry_name);
            try onFile(ctx, full_path, .{
                .mtime_ns = @intCast(stat.mtime.nanoseconds),
                .size = stat.size,
            }, gen);
        },
        else => {},
    }
}

fn scanSingleDirPortable(
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    parent_path_len: usize,
    scratch: *ScanScratch,
    io_buf: []align(scan_io_buf_align.toByteUnits()) u8,
    reader_state: Io.Dir.Reader.State,
    ctx: Ctx,
    gen: u64,
    comptime onFile: fn (Ctx, []const u8, FileStamp, u64) anyerror!void,
) !void {
    var reader: Io.Dir.Reader = .{
        .dir = dir,
        .state = reader_state,
        .index = 0,
        .end = 0,
        .buffer = io_buf,
    };
    var batch: [64]Io.Dir.Entry = undefined;
    while (reader.state != .finished) {
        const count = try reader.read(io, &batch);
        for (batch[0..count]) |entry| {
            switch (entry.kind) {
                .sym_link => continue,
                .directory => {
                    if (!shouldSkipScanDir(entry.name)) {
                        try scratch.pushChildDir(allocator, entry.name);
                    }
                },
                .file => {
                    try statAndVisitFile(Ctx, io, allocator, dir, parent_path_len, entry.name, scratch, ctx, gen, onFile);
                },
                .unknown => {
                    try statAndVisitEntry(Ctx, io, allocator, dir, parent_path_len, entry.name, scratch, ctx, gen, onFile);
                },
                else => continue,
            }
        }
    }
}

fn scanSingleDir(
    comptime force_portable: bool,
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    parent_path_len: usize,
    scratch: *ScanScratch,
    io_buf: []align(scan_io_buf_align.toByteUnits()) u8,
    ctx: Ctx,
    gen: u64,
    comptime onFile: fn (Ctx, []const u8, FileStamp, u64) anyerror!void,
) !void {
    if (comptime (!force_portable and use_darwin_bulk_attr)) {
        const outcome = try scanSingleDirDarwin(Ctx, io, allocator, dir, parent_path_len, scratch, io_buf, ctx, gen, onFile);
        if (outcome == .completed) return;
        return scanSingleDirPortable(Ctx, io, allocator, dir, parent_path_len, scratch, io_buf, .reset, ctx, gen, onFile);
    }
    return scanSingleDirPortable(Ctx, io, allocator, dir, parent_path_len, scratch, io_buf, .reading, ctx, gen, onFile);
}

fn scanRootWithScratch(
    comptime force_portable: bool,
    comptime Ctx: type,
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    scratch: *ScanScratch,
    ctx: Ctx,
    gen: u64,
    comptime onFile: fn (Ctx, []const u8, FileStamp, u64) anyerror!void,
) !void {
    const cwd = Io.Dir.cwd();
    var root_dir = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    errdefer scratch.resetTransient(io);

    const io_buf = try scratch.ensureIoBuf(allocator);
    scratch.child_spans.clearRetainingCapacity();
    scratch.child_names.clearRetainingCapacity();
    scratch.path_buf.clearRetainingCapacity();
    try scratch.path_buf.appendSlice(allocator, root_path);
    const root_len = root_path.len;

    scanSingleDir(force_portable, Ctx, io, allocator, root_dir, root_len, scratch, io_buf, ctx, gen, onFile) catch |err| {
        root_dir.close(io);
        return err;
    };

    if (scratch.child_spans.items.len == 0) {
        root_dir.close(io);
        return;
    }

    try scratch.dir_stack.append(allocator, .{
        .dir = root_dir,
        .path_len = root_len,
        .names_base = 0,
        .children_start = 0,
        .children_end = scratch.child_spans.items.len,
        .next_child = 0,
    });

    while (scratch.dir_stack.items.len > 0) {
        const top_idx = scratch.dir_stack.items.len - 1;
        if (scratch.dir_stack.items[top_idx].next_child == scratch.dir_stack.items[top_idx].children_end) {
            const done = scratch.dir_stack.pop().?;
            done.dir.close(io);
            scratch.child_spans.shrinkRetainingCapacity(done.children_start);
            scratch.child_names.shrinkRetainingCapacity(done.names_base);
            continue;
        }

        const span = scratch.dir_stack.items[top_idx].next_child;
        scratch.dir_stack.items[top_idx].next_child += 1;
        const child_span = scratch.child_spans.items[span];
        const parent_dir = scratch.dir_stack.items[top_idx].dir;
        const parent_path_len = scratch.dir_stack.items[top_idx].path_len;
        const child_name = scratch.child_names.items[child_span.offset .. child_span.offset + child_span.len];

        var child_dir = parent_dir.openDir(io, child_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch continue;

        const child_path = scratch.buildChildPath(allocator, parent_path_len, child_name) catch |err| {
            child_dir.close(io);
            return err;
        };
        const child_path_len = child_path.len;
        const sub_names_base = scratch.child_names.items.len;
        const sub_children_start = scratch.child_spans.items.len;

        scanSingleDir(force_portable, Ctx, io, allocator, child_dir, child_path_len, scratch, io_buf, ctx, gen, onFile) catch |err| switch (err) {
            error.OutOfMemory => {
                child_dir.close(io);
                return err;
            },
            else => {
                // Skip transient subdirectory walk errors, matching SelectiveWalker.
                child_dir.close(io);
                scratch.child_spans.shrinkRetainingCapacity(sub_children_start);
                scratch.child_names.shrinkRetainingCapacity(sub_names_base);
                continue;
            },
        };

        if (scratch.child_spans.items.len == sub_children_start) {
            child_dir.close(io);
            scratch.child_names.shrinkRetainingCapacity(sub_names_base);
            continue;
        }

        scratch.dir_stack.append(allocator, .{
            .dir = child_dir,
            .path_len = child_path_len,
            .names_base = sub_names_base,
            .children_start = sub_children_start,
            .children_end = scratch.child_spans.items.len,
            .next_child = sub_children_start,
        }) catch |err| {
            child_dir.close(io);
            return err;
        };
    }
}

/// Recursively scan files under root and populate file_map.
/// Keys are allocator-owned; callers free them. Duplicate paths keep the
/// existing map key and update its stamp.
pub fn scanFiles(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    file_map: *std.StringHashMap(FileStamp),
) !void {
    return scanFilesMode(false, io, allocator, root_path, file_map);
}

fn scanFilesMode(
    comptime force_portable: bool,
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    file_map: *std.StringHashMap(FileStamp),
) !void {
    const ScanMapCtx = struct {
        allocator: std.mem.Allocator,
        map: *std.StringHashMap(FileStamp),

        fn record(ctx: @This(), full_path: []const u8, stamp: FileStamp, _: u64) !void {
            if (ctx.map.getPtr(full_path)) |existing| {
                existing.* = stamp;
                return;
            }
            try ctx.map.ensureUnusedCapacity(1);
            const owned = try ctx.allocator.dupe(u8, full_path);
            ctx.map.putAssumeCapacityNoClobber(owned, stamp);
        }
    };

    var scratch: ScanScratch = .{};
    defer scratch.deinit(allocator);
    try scanRootWithScratch(
        force_portable,
        ScanMapCtx,
        io,
        allocator,
        root_path,
        &scratch,
        .{ .allocator = allocator, .map = file_map },
        0,
        ScanMapCtx.record,
    );
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
/// The set is the compile path's canonical content-failure classifier, so the
/// single-target watch path (`compileHtmlSite`) recovers from exactly the same
/// author-correctable failures the multi-target path folds into
/// `MultiTargetCompilationFailed` (docs/contracts/watch-mode.md §5). Hard
/// filesystem/system failures (missing content roots, access errors, watcher
/// backend errors) are deliberately excluded and terminate the process, as are
/// usage-class layout-rule failures (exit 2).
fn isRecoverableBuildError(err: anyerror) bool {
    return compile.isContentCompileFailure(err);
}

/// Prose suffix for a non-recoverable failure. Genuine filesystem/system
/// failures keep the "unrecoverable I/O error" label; usage-class and
/// already-diagnosed failures (the publication-location/static-dir gates)
/// already named their real cause, so calling them I/O would mislabel them
/// (#1035).
fn unrecoverableLabel(err: anyerror) []const u8 {
    if (compile.isUsageTargetFailure(err) or err == error.PublicationLocationMismatch) return "failed";
    return "failed with unrecoverable I/O error";
}

/// Prose label for a failed watch cycle: `"rebuild"` (HTML publish) or
/// `"validation rebuild"` (`validate --watch`).
fn rebuildLabel(action: Action) []const u8 {
    return if (action == .validate) "validation rebuild" else "rebuild";
}

/// Prose label for the initial cycle: `"build"` (HTML publish) or
/// `"validation"` (`validate --watch`).
fn initialLabel(action: Action) []const u8 {
    return if (action == .validate) "validation" else "build";
}

/// Prose label for a succeeded rebuild: `"rebuild succeeded"` or
/// `"validation rebuild succeeded"`.
fn rebuildSucceededLabel(action: Action) []const u8 {
    return if (action == .validate) "validation rebuild succeeded" else "rebuild succeeded";
}

/// Append one EIO diagnostic for a bare compile error that escaped the
/// collector, so the report still explains a failed cycle. Mirrors the
/// one-shot `validate` behavior in main.zig (content failures already carry
/// their own structured diagnostics in the collector); skipped when the
/// collector already holds an error diagnostic so a structured failure is
/// never shadowed or duplicated by the generic fallback (#829).
fn appendValidateEscapedDiagnostic(collector: ?*diag.Collector, err: anyerror) void {
    if (collector) |c| {
        if (diag.countErrors(c.list.items) > 0) return;
        c.append(.{
            .severity = .error_,
            .code = .EIO,
            .message = @errorName(err),
            .remediation = "Check that the input and output paths exist and are accessible",
        });
    }
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
pub const default_watch_layout: []const u8 = "themes/boris/layouts/main.html";

/// What one watch cycle does: publish HTML (the historical `watch` command) or
/// run the zero-write HTML-source/config preflight (`validate --watch`, #647).
pub const Action = enum { html, validate };

fn actionOf(options: cli.Options) Action {
    return if (options.command == .validate) .validate else .html;
}

/// Coordinator running the debounced watch and serialized rebuild cycles.
pub const WatchCoordinator = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: cli.Options,
    /// #781: baked vcs revision forwarded into each rebuild's compile options
    /// so watch-refreshed Proof Packs attribute to the same build.
    vcs_revision: []const u8 = "",
    action: Action,
    watcher: Watcher,
    pending_changes: std.StringHashMap(void),
    /// Normalized forward-slash output roots, computed once at init.
    ignored_output_roots: []const []const u8,
    /// Loopback preview server (`watch --serve`); bound at init so port
    /// errors fail fast, started after the initial build in `run`.
    serve: ?preview_server.Server = null,
    /// Opt-in phase timing/counter recorder (`--timings`); threaded into
    /// every initial + rebuild compile so the shutdown report carries data.
    recorder: ?*timings.Recorder = null,
    /// Startup profile snapshot, owned by the caller for the watch lifetime.
    nostr_head: ?*const nostr_emit.HeadConfig = null,

    /// Build the ignore-root list once for the coordinator lifetime
    /// (final outs + sibling `.boris-stage` trees).
    fn buildIgnoredOutputRoots(gpa: std.mem.Allocator, options: cli.Options) ![]const []const u8 {
        // `validate --watch` writes nothing, so there are no output roots to
        // exclude: self-trigger protection is trivially satisfied (#647).
        if (actionOf(options) == .validate) return try gpa.alloc([]const u8, 0);
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

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        options: cli.Options,
        watcher: Watcher,
        /// #781: baked vcs revision forwarded to compile → Proof Pack.
        vcs_revision: []const u8,
    ) !WatchCoordinator {
        const ignored = try buildIgnoredOutputRoots(gpa, options);
        errdefer {
            for (ignored) |r| gpa.free(r);
            gpa.free(ignored);
        }
        var serve: ?preview_server.Server = null;
        if (options.serve) {
            // HTML mode always synthesizes at least the "default" target, so
            // targets.items[0] is the served root (canonical order).
            // The errdefer above owns `ignored`; a bind error just propagates.
            const root = options.targets.items[0].output_dir;
            serve = try preview_server.Server.init(
                gpa,
                io,
                root,
                options.serve_port orelse preview_server.default_port,
            );
        }
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .vcs_revision = vcs_revision,
            .action = actionOf(options),
            .watcher = watcher,
            .pending_changes = std.StringHashMap(void).init(gpa),
            .ignored_output_roots = ignored,
            .serve = serve,
        };
    }

    pub fn deinit(self: *WatchCoordinator) void {
        if (self.serve) |*s| s.deinit();
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

    /// True when `err` keeps the watch loop alive: author-correctable content/
    /// layout failures and the multi-target aggregate wrap of them.
    fn isRecoverableFailure(err: anyerror) bool {
        return isRecoverableBuildError(err) or err == error.MultiTargetCompilationFailed;
    }

    /// Wall time of one compile in milliseconds (monotonic `awake` clock).
    fn elapsedMs(io: Io, start: Io.Timestamp) u64 {
        const elapsed = Io.Timestamp.durationTo(start, Io.Timestamp.now(io, .awake));
        if (elapsed.nanoseconds <= 0) return 0;
        return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
    }

    const BuildOutcome = struct {
        ok: bool = false,
        stats: compile.CompileStats = .{ .pages_written = 0, .peak_whiteboard_capacity = 0 },
        err: ?anyerror = null,
        duration_ms: u64 = 0,
    };

    /// Run one HTML compile (initial or rebuild) and capture stats, error, and
    /// wall duration. `subset` selects the rebuilt targets: null runs the raw
    /// single-target path (`compileHtmlSite`); non-null runs the multi-target
    /// path over exactly that subset. Structured diagnostics flow into
    /// `collector` (set by the `--watch-json` mode) and the prose form is
    /// suppressed while the compile runs.
    fn runCompile(self: *WatchCoordinator, subset: ?[]const target_mod.TargetSpec, collector: ?*diag.Collector) BuildOutcome {
        const start = Io.Timestamp.now(self.io, .awake);
        var outcome: BuildOutcome = .{ .duration_ms = 0 };
        const layout_default = self.options.html_layout;
        if (self.action == .validate) {
            // `validate --watch` runs exactly the one-shot validate preflight
            // (validateHtmlSiteMulti) and writes nothing. Output flags are
            // rejected at parse, so the single synthesized "default" target is
            // always selected and `subset` (HTML fan-out) is ignored.
            if (compile.validateHtmlSiteMulti(self.io, self.gpa, self.options.targets.items, .{
                .content_root = self.options.input_dir,
                .layout_path = layout_default,
                .quiet = self.options.quiet or self.options.watch_json,
                .input_format = self.options.input_format,
                .sitemap_path = self.options.sitemap_path,
                .static_dir = self.options.static_dir,
                .site_url = self.options.site_url,
                .publication_location = if (self.options.publication_location) |*location| location else null,
                .allow_markdown_literals = self.options.allow_markdown_links,
                .diagnostics = collector,
                .timings = self.recorder,
            })) {
                outcome.ok = true;
            } else |err| {
                outcome.err = err;
            }
            outcome.duration_ms = elapsedMs(self.io, start);
            return outcome;
        }
        if (subset) |targets| {
            if (compile.compileHtmlSiteMulti(self.io, self.gpa, targets, .{
                .workspace_root = self.options.profile_workspace_root,
                .nostr_head = self.nostr_head,
                .content_root = self.options.input_dir,
                .layout_path = layout_default,
                .incremental = self.options.incremental,
                .refresh_evidence = self.options.refresh_evidence,
                // `--watch-json` implies quiet: the stderr stream is the
                // machine-readable event channel, not prose progress.
                .quiet = self.options.quiet or self.options.watch_json,
                .jobs = self.options.jobs,
                .input_format = self.options.input_format,
                .sitemap_path = self.options.sitemap_path,
                .static_dir = self.options.static_dir,
                .site_url = self.options.site_url,
                .publication_location = if (self.options.publication_location) |*location| location else null,
                .vcs_revision = self.vcs_revision,
                .diagnostics = collector,
                .timings = self.recorder,
            })) |stats| {
                outcome.ok = true;
                outcome.stats = stats;
            } else |err| {
                outcome.err = err;
            }
        } else {
            if (compile.compileHtmlSite(self.io, self.gpa, .{
                .content_root = self.options.input_dir,
                .dist_dir = self.options.html_dir orelse "dist",
                .layout_path = layout_default,
                .incremental = self.options.incremental,
                .refresh_evidence = self.options.refresh_evidence,
                // `--watch-json` implies quiet: the stderr stream is the
                // machine-readable event channel, not prose progress.
                .quiet = self.options.quiet or self.options.watch_json,
                .jobs = self.options.jobs,
                .input_format = self.options.input_format,
                .sitemap_path = self.options.sitemap_path,
                .static_dir = self.options.static_dir,
                .site_url = self.options.site_url,
                .publication_location = if (self.options.publication_location) |*location| location else null,
                .vcs_revision = self.vcs_revision,
                .diagnostics = collector,
                .timings = self.recorder,
            })) |stats| {
                outcome.ok = true;
                outcome.stats = stats;
            } else |err| {
                outcome.err = err;
            }
        }
        outcome.duration_ms = elapsedMs(self.io, start);
        return outcome;
    }

    /// Target names for NDJSON events: the subset actually rebuilt (for
    /// selective rebuilds), never the full configured set. The empty-targets
    /// single-target path reports the synthetic `default` target, matching the
    /// CLI's canonical HTML configuration.
    fn targetNamesOf(gpa: std.mem.Allocator, targets: []const target_mod.TargetSpec) ![][]const u8 {
        if (targets.len == 0) return gpa.dupe([]const u8, &.{"default"});
        var names = try gpa.alloc([]const u8, targets.len);
        for (targets, 0..) |t, i| {
            names[i] = t.name;
        }
        return names;
    }

    fn emitLine(self: *WatchCoordinator, line: []const u8) void {
        _ = self;
        std.debug.print("{s}", .{line});
    }

    /// NDJSON `mode` field: `"html"` for the publish daemon, `"validate"` for
    /// the zero-write validation daemon (#647).
    fn modeName(self: *WatchCoordinator) []const u8 {
        return if (self.action == .validate) "validate" else "html";
    }

    fn emitHello(self: *WatchCoordinator) void {
        const line = watch_json.renderHello(self.gpa, pipeline.compiler_id) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    fn emitBuildStarted(self: *WatchCoordinator, phase: []const u8, targets: []const []const u8, changed: ?[]const []const u8) void {
        const line = watch_json.renderBuildStarted(self.gpa, phase, self.modeName(), targets, changed) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    /// Best-effort publication-check verdict line after a successful build
    /// (#840): committed evidence read back as chrome; never fails the loop.
    fn printChecksVerdict(self: *WatchCoordinator) void {
        if (self.options.targets.items.len > 0) {
            for (self.options.targets.items) |spec| {
                if (publication_touches_mod.checksVerdictLine(self.gpa, self.io, spec.name, spec.output_dir)) |line| {
                    defer self.gpa.free(line);
                    std.debug.print("  {s}\n", .{line});
                }
            }
            return;
        }
        // Raw single-target path: the default target against --html-dir.
        if (publication_touches_mod.checksVerdictLine(self.gpa, self.io, "default", self.options.html_dir orelse "dist")) |line| {
            defer self.gpa.free(line);
            std.debug.print("  {s}\n", .{line});
        }
    }

    fn emitBuildSucceeded(self: *WatchCoordinator, phase: []const u8, targets: []const []const u8, changed: ?[]const []const u8, outcome: BuildOutcome) void {
        // Validate writes nothing, so it never reports pages_written (#647).
        const pages: ?usize = if (self.action == .validate) null else outcome.stats.pages_written;
        const line = watch_json.renderBuildSucceeded(self.gpa, phase, self.modeName(), targets, changed, pages, outcome.duration_ms) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    /// One-line failure summary for the `--serve` status endpoint and stale
    /// banner (#1114): the first error diagnostic in prose form (matching
    /// the suppressed/printed stderr line), or the bare error name when no
    /// diagnostic was collected. gpa-owned; null on allocation failure.
    fn failureSummary(self: *WatchCoordinator, collector: ?*diag.Collector, err: ?anyerror) ?[]u8 {
        if (collector) |c| {
            diag.sortDiagnostics(c.list.items);
            for (c.list.items) |d| {
                if (d.isError()) return diag.formatText(d, self.gpa) catch null;
            }
            if (c.list.items.len > 0) return diag.formatText(c.list.items[0], self.gpa) catch null;
        }
        if (err) |e| return std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(e)}) catch null;
        return null;
    }

    /// Push a completed cycle's outcome to the `--serve` preview server so
    /// `GET /__boris/status`, the SSE `stale` event, and the injected banner
    /// reflect it (#1114).
    fn notifyServe(self: *WatchCoordinator, outcome: BuildOutcome, collector: ?*diag.Collector) void {
        if (self.serve) |*s| {
            if (outcome.ok) {
                s.notifyRebuild(outcome.duration_ms);
            } else {
                const summary = self.failureSummary(collector, outcome.err);
                defer if (summary) |sm| self.gpa.free(sm);
                s.notifyBuildFailed(summary orelse "", outcome.duration_ms);
            }
        }
    }

    fn emitBuildFailed(self: *WatchCoordinator, phase: []const u8, targets: []const []const u8, changed: ?[]const []const u8, outcome: BuildOutcome, collector: ?*diag.Collector) void {
        var diagnostics: []diag.Diagnostic = &.{};
        if (collector) |c| {
            diag.sortDiagnostics(c.list.items);
            diagnostics = c.list.items;
        }
        const errors = diag.countErrors(diagnostics);
        const recoverable = isRecoverableFailure(outcome.err orelse error.Unknown);
        const line = watch_json.renderBuildFailed(self.gpa, phase, self.modeName(), targets, changed, errors, diagnostics, recoverable, outcome.duration_ms) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    fn emitWatcherStarted(self: *WatchCoordinator, targets: []const []const u8) void {
        const line = watch_json.renderWatcherStarted(self.gpa, self.modeName(), targets) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    fn emitServeStarted(self: *WatchCoordinator, port: u16) void {
        const url = std.fmt.allocPrint(self.gpa, "http://127.0.0.1:{d}/", .{port}) catch return;
        defer self.gpa.free(url);
        const helper = std.fmt.allocPrint(self.gpa, "http://127.0.0.1:{d}/__boris/", .{port}) catch return;
        defer self.gpa.free(helper);
        const line = watch_json.renderServeStarted(self.gpa, url, helper, port) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    fn emitWatchError(self: *WatchCoordinator, message: []const u8) void {
        const line = watch_json.renderWatchError(self.gpa, message, true) catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    fn emitWatchStopped(self: *WatchCoordinator) void {
        const line = watch_json.renderWatchStopped(self.gpa, "signal") catch return;
        defer self.gpa.free(line);
        self.emitLine(line);
    }

    /// `validate --watch --report PATH` rewrites the report file on every
    /// cycle (replacement, never append), so a consumer reading the file sees
    /// the current cycle and stale failure state cannot linger (#647).
    fn maybeWriteValidateReport(self: *WatchCoordinator, collector: ?*diag.Collector, ok: bool) void {
        if (self.action != .validate) return;
        const path = self.options.report_path orelse return;
        const c = collector orelse return;
        diag.sortDiagnostics(c.list.items);
        const rendered = html_report.renderHtmlReport(self.gpa, pipeline.compiler_id, .{
            .ok = ok,
            .content_root = self.options.input_dir,
            .out_dir = self.options.html_dir orelse "dist",
            .diagnostics = c.list.items,
        }) catch return;
        defer self.gpa.free(rendered);
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = rendered }) catch |err| {
            std.debug.print("error: failed to write report {s}: {s}\n", .{ path, @errorName(err) });
        };
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

        const json = self.options.watch_json;
        // Layout-only changes fan out to affected targets only. The subset is
        // computed before any event so NDJSON `targets` names the subset
        // actually rebuilt, not the full configured set.
        const layout_default = self.options.html_layout;
        var subset: ?[]const target_mod.TargetSpec = null;
        var owned_subset: ?[]const target_mod.TargetSpec = null;
        // Validate mode has no target fan-out: the single synthesized
        // "default" target is always rebuilt, so no layout subsetting.
        if (self.action == .html and self.options.targets.items.len > 0) {
            // Profile layout names are workspace-relative while watcher
            // events are absolute. Strip only that workspace prefix before
            // comparing; content and unknown events still rebuild all targets.
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.gpa);
            for (paths.items) |path| {
                const key = if (self.options.profile_workspace_root) |root|
                    if (target_mod.hasAbsPathPrefix(path, root, builtin.os.tag == .macos or builtin.os.tag == .windows) and path.len > root.len)
                        path[root.len + 1 ..]
                    else
                        path
                else
                    path;
                try keys.append(self.gpa, key);
            }
            owned_subset = try selectTargetsForRebuild(self.gpa, keys.items, self.options.targets.items, layout_default);
            subset = owned_subset;
        }
        defer if (owned_subset) |s| self.gpa.free(s);

        if (json) {
            const targets = try targetNamesOf(self.gpa, subset orelse self.options.targets.items);
            defer self.gpa.free(targets);
            self.emitBuildStarted("rebuild", targets, paths.items);
        } else if (!self.options.quiet) {
            std.debug.print("watch: changed paths detected:\n", .{});
            for (paths.items) |p| {
                std.debug.print("  - {s}\n", .{p});
            }
            std.debug.print("watch: triggering incremental {s}...\n", .{if (self.action == .validate) "validation" else "rebuild"});
            if (subset) |s| {
                if (s.len < self.options.targets.items.len) {
                    std.debug.print("watch: selective rebuild of {d}/{d} target(s)\n", .{
                        s.len,
                        self.options.targets.items.len,
                    });
                }
            }
        }

        // Under `--watch-json` the prose diagnostic form is suppressed for the
        // duration of the compile; the same data flows into the collector and
        // then into the build-failed NDJSON event. Validate mode also collects
        // when `--report` is set so the report file is rewritten every cycle,
        // and `--serve` collects so `/__boris/status` can name the failure.
        const prior_text_suppressed = diag.text_suppressed.load(.unordered);
        if (json) diag.text_suppressed.store(true, .unordered);
        defer if (json) diag.text_suppressed.store(prior_text_suppressed, .unordered);

        const need_collector = json or self.serve != null or (self.action == .validate and self.options.report_path != null);
        var collector: ?diag.Collector = null;
        if (need_collector) collector = diag.Collector.init(self.gpa, self.io);
        defer if (collector) |*c| c.deinit();
        const collector_ptr: ?*diag.Collector = if (collector) |*c| c else null;

        // Full rediscovery + content-addressed incremental render (event paths
        // trigger the rebuild; dirty-set comes from fingerprints inside compile).
        const outcome = self.runCompile(subset, collector_ptr);
        if (!outcome.ok) {
            const err = outcome.err.?;
            if (self.action == .validate and !isRecoverableFailure(err)) {
                appendValidateEscapedDiagnostic(collector_ptr, err);
            }
            self.notifyServe(outcome, collector_ptr);
            if (json) {
                const targets = try targetNamesOf(self.gpa, subset orelse self.options.targets.items);
                defer self.gpa.free(targets);
                self.emitBuildFailed("rebuild", targets, paths.items, outcome, collector_ptr);
            } else if (isRecoverableFailure(err)) {
                if (!diag.text_suppressed.load(.unordered)) {
                    std.debug.print("error: {s} failed: {s}. Waiting for correction...\n", .{ rebuildLabel(self.action), @errorName(err) });
                }
            } else if (!diag.text_suppressed.load(.unordered)) {
                std.debug.print("error: {s} {s}: {s}\n", .{ rebuildLabel(self.action), unrecoverableLabel(err), @errorName(err) });
            }
            if (self.action == .validate) self.maybeWriteValidateReport(collector_ptr, false);
            if (isRecoverableFailure(err)) return;
            return err;
        }

        if (json) {
            const targets = try targetNamesOf(self.gpa, subset orelse self.options.targets.items);
            defer self.gpa.free(targets);
            self.emitBuildSucceeded("rebuild", targets, paths.items, outcome);
        } else if (!self.options.quiet) {
            std.debug.print("watch: {s}.\n", .{rebuildSucceededLabel(self.action)});
            self.printChecksVerdict();
        }
        if (self.action == .validate) self.maybeWriteValidateReport(collector_ptr, true);
        self.notifyServe(outcome, collector_ptr);
    }

    /// Perform initial build, set up signal handlers, and execute the watch poll loop.
    pub fn run(self: *WatchCoordinator) !void {
        const json = self.options.watch_json;
        if (json) {
            self.emitHello();
            const targets = try targetNamesOf(self.gpa, self.options.targets.items);
            defer self.gpa.free(targets);
            self.emitBuildStarted("initial", targets, null);
        } else if (!self.options.quiet) {
            std.debug.print("watch: performing initial {s}...\n", .{if (self.action == .validate) "validation" else "build"});
        }

        // Under `--watch-json` the prose diagnostic form is suppressed for the
        // duration of the compile; the same data flows into the collector and
        // then into the build-failed NDJSON event. Validate mode also collects
        // when `--report` is set so the report file is rewritten every cycle,
        // and `--serve` collects so `/__boris/status` can name the failure.
        const prior_text_suppressed = diag.text_suppressed.load(.unordered);
        if (json) diag.text_suppressed.store(true, .unordered);
        defer if (json) diag.text_suppressed.store(prior_text_suppressed, .unordered);

        const need_collector = json or self.serve != null or (self.action == .validate and self.options.report_path != null);
        var collector: ?diag.Collector = null;
        if (need_collector) collector = diag.Collector.init(self.gpa, self.io);
        defer if (collector) |*c| c.deinit();
        const collector_ptr: ?*diag.Collector = if (collector) |*c| c else null;

        // Initial build: every configured target (multi) or the single default
        // (raw single-target path).
        const subset: ?[]const target_mod.TargetSpec = if (self.options.targets.items.len > 0) self.options.targets.items else null;
        const outcome = self.runCompile(subset, collector_ptr);
        const initial_success = outcome.ok;

        var targets: []const []const u8 = &.{};
        if (json) {
            targets = try targetNamesOf(self.gpa, self.options.targets.items);
        }
        // The defer must live in run()'s scope, not the `if` block: freeing
        // inside the block would run before the emit calls below read it.
        defer if (json) self.gpa.free(targets);

        if (initial_success) {
            if (json) {
                self.emitBuildSucceeded("initial", targets, null, outcome);
            } else if (!self.options.quiet) {
                if (self.action == .validate) {
                    std.debug.print("watch: initial validation succeeded. Starting watcher...\n", .{});
                } else {
                    std.debug.print("watch: initial build succeeded ({d} pages written). Starting watcher...\n", .{outcome.stats.pages_written});
                    self.printChecksVerdict();
                }
            }
            if (self.action == .validate) self.maybeWriteValidateReport(collector_ptr, true);
        } else {
            const err = outcome.err.?;
            if (self.action == .validate and !isRecoverableFailure(err)) {
                appendValidateEscapedDiagnostic(collector_ptr, err);
            }
            if (isRecoverableFailure(err)) {
                if (json) {
                    self.emitBuildFailed("initial", targets, null, outcome, collector_ptr);
                } else if (!self.options.quiet) {
                    std.debug.print("error: initial {s} failed: {s}. Continuing to watch...\n", .{ initialLabel(self.action), @errorName(err) });
                }
            } else {
                if (json) {
                    self.emitBuildFailed("initial", targets, null, outcome, collector_ptr);
                } else if (!self.options.quiet) {
                    std.debug.print("error: initial {s} {s}: {s}\n", .{ initialLabel(self.action), unrecoverableLabel(err), @errorName(err) });
                }
                if (self.action == .validate) self.maybeWriteValidateReport(collector_ptr, false);
                return err;
            }
            if (self.action == .validate) self.maybeWriteValidateReport(collector_ptr, false);
        }

        // Record the initial build's outcome for `/__boris/status` and the
        // stale banner before the server starts accepting (#1114).
        self.notifyServe(outcome, collector_ptr);

        if (json) self.emitWatcherStarted(targets);

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

        // Start the loopback preview server after the initial build so the
        // first served tree is the freshest complete output (or the partial
        // tree after a recoverable failure, which the author can still view).
        if (self.serve) |*s| {
            try s.start();
            const port = s.boundPort();
            if (json) {
                self.emitServeStarted(port);
            } else if (!self.options.quiet) {
                std.debug.print("preview: http://127.0.0.1:{d}/  (auto-reload helper: http://127.0.0.1:{d}/__boris/, status: http://127.0.0.1:{d}/__boris/status)\n", .{ port, port, port });
            }
        }

        while (!should_shutdown_global.load(.unordered)) {
            self.processEvents() catch |err| {
                // Transient poll failures must not kill the session (#15).
                if (json) {
                    self.emitWatchError(@errorName(err));
                } else if (!self.options.quiet) {
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

        if (json) {
            self.emitWatchStopped();
        } else if (!self.options.quiet) {
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
    }, fake.watcher(), "");
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

test "poll keeps snapshot on transient root scan failure" {
    // The transient root-loss moment is simulated with chmod-style mode bits;
    // Windows has no setFilePermissions (std panics TODO) and ACLs do not map.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/watch-flap/root", .{tmp.sub_path});
    defer gpa.free(root);
    try cwd.createDirPath(io, root);
    const a_path = try std.fmt.allocPrint(gpa, "{s}/a.md", .{root});
    defer gpa.free(a_path);
    const b_path = try std.fmt.allocPrint(gpa, "{s}/b.md", .{root});
    defer gpa.free(b_path);
    try cwd.writeFile(io, .{ .sub_path = a_path, .data = "a" });
    try cwd.writeFile(io, .{ .sub_path = b_path, .data = "b" });

    var pw = PollingWatcher.init(gpa, io);
    defer pw.deinit();
    try pw.addRoot(root);
    const w = pw.watcher();

    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |e| gpa.free(e.path);
        events.deinit(gpa);
    }
    // No changes since addRoot scanned: quiet.
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // Transient unreadable-root moment: no mass delete events.
    try cwd.setFilePermissions(io, root, @fromBackingInt(@intCast(0)), .{});
    defer cwd.setFilePermissions(io, root, restorePermissions(), .{}) catch {};
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // After recovery the preserved snapshot diffs clean: no create storm
    // from a poisoned intermediate map either.
    try cwd.setFilePermissions(io, root, restorePermissions(), .{});
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "watch rebuild records timings phases and counters (#877)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/watch-timings", .{tmp.sub_path});
    defer gpa.free(work);

    try writeWatchTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\Hello.
        \\
    );
    try writeWatchTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const options = cli.Options{
        .command = .build,
        .mode = .html,
        .input_dir = content,
        .html_dir = dist,
        .html_layout = layout,
        .quiet = true,
        .watch = true,
    };
    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();
    var coord = try WatchCoordinator.init(gpa, io, options, fake.watcher(), "");
    defer coord.deinit();

    var recorder = timings.Recorder.init(io);
    coord.recorder = &recorder;
    try coord.triggerRebuild();

    // Without the recorder threading this stays an all-zero report (#877).
    try std.testing.expect(recorder.ever_started[@backingInt(timings.Phase.render)]);
    try std.testing.expect(recorder.counters[@backingInt(timings.Counter.page_reads)] > 0);
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
    }, fake.watcher(), "");
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
    }, fake.watcher(), "");
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

    var coord = try WatchCoordinator.init(gpa, io, options, fake.watcher(), "");
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
    }, fake.watcher(), "");
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
    }, fake.watcher(), "");
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

    var coord = try WatchCoordinator.init(gpa, io, options, fake.watcher(), "");
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
    }, fake.watcher(), "");
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
    // hard I/O does not. Keep this aligned with compile.isContentCompileFailure.
    try std.testing.expect(isRecoverableBuildError(error.ParseFailed));
    try std.testing.expect(isRecoverableBuildError(error.ComponentFailed));
    try std.testing.expect(isRecoverableBuildError(error.LayoutMissingMarker));
    try std.testing.expect(isRecoverableBuildError(error.LayoutDuplicateMarker));
    try std.testing.expect(isRecoverableBuildError(error.SitemapUrlLimitExceeded));
    // Missing include is an author-correctable content failure: recoverable.
    try std.testing.expect(isRecoverableBuildError(error.IncludeFailed));
    // Unsafe SVG is an author-correctable content-validation failure: recoverable
    // in both single-target and multi-target watch paths (same session, no restart).
    try std.testing.expect(isRecoverableBuildError(error.AssetUnsafeSvg));
    // Reference and link-audit failures are author-correctable content, not I/O:
    // a bad wiki-link or markdown href must keep the watcher alive (single-target
    // path surfaces these raw, unlike the multi-target wrapper).
    try std.testing.expect(isRecoverableBuildError(error.ReferenceFailed));
    try std.testing.expect(isRecoverableBuildError(error.LinkAuditFailed));
    try std.testing.expect(isRecoverableBuildError(error.GraphValidationFailed));
    // Usage-class layout-rule failures are exit 2, not recoverable watch errors.
    try std.testing.expect(!isRecoverableBuildError(error.LayoutSelectionFailed));
    try std.testing.expect(!isRecoverableBuildError(error.MixedThemeRoots));
    // Hard filesystem/system failures must still terminate the watcher.
    try std.testing.expect(!isRecoverableBuildError(error.FileNotFound));
    try std.testing.expect(!isRecoverableBuildError(error.AccessDenied));
}

test "validate --watch cycles run the zero-write preflight and write nothing (#647)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/watch-validate", .{tmp.sub_path});
    defer gpa.free(work);

    try writeWatchTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\Hello.
        \\
    );
    try writeWatchTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var options = cli.Options{
        .command = .validate,
        .mode = .html,
        .input_dir = content,
        .html_layout = layout,
        .quiet = true,
        .watch = true,
    };
    try options.targets.append(gpa, .{ .name = "default", .output_dir = dist });
    defer options.targets.deinit(gpa);

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();
    var coord = try WatchCoordinator.init(gpa, io, options, fake.watcher(), "");
    defer coord.deinit();

    // Validate mode has no output roots to ignore: nothing is written, so
    // self-trigger protection is trivially satisfied.
    try std.testing.expectEqual(@as(usize, 0), coord.ignored_output_roots.len);

    // A valid tree validates; no output tree is published.
    try coord.triggerRebuild();
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, dist, .{}));

    // An author-correctable failure keeps the same session alive (recoverable).
    try writeWatchTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\See [[missing-page]].
        \\
    );
    try coord.triggerRebuild();
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, dist, .{}));

    // The author's correction validates again in the same session, still
    // writing nothing.
    try writeWatchTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\Hello again.
        \\
    );
    try coord.triggerRebuild();
    try std.testing.expectError(error.FileNotFound, cwd.openFile(io, dist, .{}));
}

test "single-target watch: unsafe SVG rebuild recovers in-session without restart" {
    // Drives the raw single-target watch rebuild path (empty targets →
    // compileHtmlSite): an author replacing an inert SVG with an active
    // construct must fail recoverably (EASSET content class, not I/O), keep
    // this coordinator session alive, preserve the prior published HTML and
    // SVG byte-for-byte, and publish the corrected asset after the author
    // restores a different inert SVG — all without restarting the watcher.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/watch-svg-recover", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeWatchTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\![logo](index.assets/logo.svg)
        \\
    );
    try writeWatchTreeFile(io, work, "content/index.assets/logo.svg", "<svg id=\"v1\"/>");
    try writeWatchTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var fake = FakeWatcher.init(gpa);
    defer fake.deinit();
    var coord = try WatchCoordinator.init(gpa, io, .{
        .mode = .html,
        .input_dir = content,
        .html_dir = dist,
        .html_layout = layout,
        .quiet = true,
        .watch = true,
        // targets left empty: raw single-target rebuild path (compileHtmlSite)
    }, fake.watcher(), "");
    defer coord.deinit();

    // Initial build with the valid inert SVG publishes the page and asset.
    try coord.triggerRebuild();
    const html_v1 = try readWatchTreeFile(io, gpa, dist, "index.html");
    defer gpa.free(html_v1);
    const svg_v1 = try readWatchTreeFile(io, gpa, dist, "index.assets/logo.svg");
    defer gpa.free(svg_v1);

    // Author replaces the inert SVG with an active construct. The rebuild must
    // fail recoverably: triggerRebuild must not propagate the error, the prior
    // valid output must stay byte-identical, and the same coordinator session
    // must publish the corrected asset after the author restores a different
    // inert SVG (no restart).
    try writeWatchTreeFile(io, work, "content/index.assets/logo.svg", "<svg><script>alert(1)</script></svg>");
    try coord.triggerRebuild();

    const html_v2 = try readWatchTreeFile(io, gpa, dist, "index.html");
    defer gpa.free(html_v2);
    try std.testing.expectEqualStrings(html_v1, html_v2);
    const svg_v2 = try readWatchTreeFile(io, gpa, dist, "index.assets/logo.svg");
    defer gpa.free(svg_v2);
    try std.testing.expectEqualStrings(svg_v1, svg_v2);

    // Restore a different inert SVG; the same session publishes it.
    try writeWatchTreeFile(io, work, "content/index.assets/logo.svg", "<svg id=\"v2\"/>");
    try coord.triggerRebuild();
    const svg_v3 = try readWatchTreeFile(io, gpa, dist, "index.assets/logo.svg");
    defer gpa.free(svg_v3);
    try std.testing.expectEqualStrings("<svg id=\"v2\"/>", svg_v3);
}

test "PollingWatcher.poll performs zero heap allocations on unchanged trees (#1144)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/poll-zero-alloc", .{tmp.sub_path});
    defer gpa.free(root);

    try writeWatchTreeFile(io, root, "index.md", "# Home\n");
    try writeWatchTreeFile(io, root, "guides/intro.md", "# Intro\n");
    try writeWatchTreeFile(io, root, "guides/deep/nested/page.md", "# Page\n");
    try writeWatchTreeFile(io, root, ".git/HEAD", "ref: refs/heads/main\n");
    try writeWatchTreeFile(io, root, "node_modules/pkg/index.js", "export {};\n");

    var counting = std.testing.FailingAllocator.init(gpa, .{});
    var pw = PollingWatcher.init(counting.allocator(), io);
    defer pw.deinit();
    try pw.addRoot(root);
    const w = pw.watcher();

    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |e| counting.allocator().free(e.path);
        events.deinit(counting.allocator());
    }

    const baseline_allocs = counting.allocations;
    const baseline_deallocs = counting.deallocations;
    const baseline_resizes = counting.resize_index;
    const baseline_bytes = counting.allocated_bytes;

    // Three consecutive unchanged polls must neither allocate, resize, nor free.
    for (0..3) |_| {
        try w.poll(&events);
        try std.testing.expectEqual(@as(usize, 0), events.items.len);
    }

    try std.testing.expectEqual(baseline_allocs, counting.allocations);
    try std.testing.expectEqual(baseline_deallocs, counting.deallocations);
    try std.testing.expectEqual(baseline_resizes, counting.resize_index);
    try std.testing.expectEqual(baseline_bytes, counting.allocated_bytes);
}

test "PollingWatcher detects in-place edits, creations, deletions, and skips symlinks (#1144)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/poll-events", .{tmp.sub_path});
    defer gpa.free(work);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const optional_root = try std.fmt.allocPrint(gpa, "{s}/optional-theme", .{work});
    defer gpa.free(optional_root);

    try writeWatchTreeFile(io, content, "index.md", "hello-v1");
    try writeWatchTreeFile(io, content, "sub/child.md", "child-v1");
    try writeWatchTreeFile(io, work, "outside/target.md", "outside");
    try writeWatchTreeFile(io, work, "outside-dir/hidden.md", "outside-dir");

    // Symlinks to files and directories must be ignored across addRoot and poll.
    var symlinks_supported = true;
    {
        var content_dir = try cwd.openDir(io, content, .{});
        defer content_dir.close(io);
        content_dir.symLink(io, "../outside/target.md", "alias.md", .{}) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied, error.Unexpected => symlinks_supported = false,
            else => return err,
        };
        if (symlinks_supported) {
            try content_dir.symLink(io, "../outside-dir", "linked-dir", .{ .is_directory = true });
        }
    }

    var pw = PollingWatcher.init(gpa, io);
    defer pw.deinit();
    try pw.addRoot(content);
    try pw.addRoot(optional_root); // missing root at startup must succeed cleanly
    const w = pw.watcher();

    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |e| gpa.free(e.path);
        events.deinit(gpa);
    }

    const clearEvents = struct {
        fn go(alloc: std.mem.Allocator, list: *std.ArrayList(Event)) void {
            for (list.items) |e| alloc.free(e.path);
            list.clearRetainingCapacity();
        }
    }.go;

    // 1. Unchanged poll is quiet even when symlinks' targets change outside watched root.
    try writeWatchTreeFile(io, work, "outside/target.md", "outside-changed-longer");
    try writeWatchTreeFile(io, work, "outside-dir/hidden.md", "outside-dir-changed");
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // 2. Same-size in-place overwrite inside nested subdir updates mtime only (parent dir untouched).
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    try writeWatchTreeFile(io, content, "sub/child.md", "child-v2"); // exact same 8-byte size
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(EventKind.modify, events.items[0].kind);
    const expected_child = try std.fs.path.join(gpa, &.{ content, "sub", "child.md" });
    defer gpa.free(expected_child);
    try std.testing.expectEqualStrings(expected_child, events.items[0].path);
    clearEvents(gpa, &events);

    // 3. Size-changing in-place overwrite at root emits modify.
    try writeWatchTreeFile(io, content, "index.md", "hello-v2-longer-payload");
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(EventKind.modify, events.items[0].kind);
    clearEvents(gpa, &events);

    // 4. Creating files in new subdirs, optional root appearing, and skipped dirs remaining ignored.
    try writeWatchTreeFile(io, content, "brand-new/topic.md", "topic");
    try writeWatchTreeFile(io, optional_root, "layouts/page.html", "<html>{{content}}</html>");
    try writeWatchTreeFile(io, content, ".boris-cache/ignored.json", "{}");
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    for (events.items) |ev| {
        try std.testing.expectEqual(EventKind.create, ev.kind);
    }
    clearEvents(gpa, &events);

    // 5. Deleting a file and removing the optional root emit delete events.
    try cwd.deleteFile(io, expected_child);
    try cwd.deleteTree(io, optional_root);
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    for (events.items) |ev| {
        try std.testing.expectEqual(EventKind.delete, ev.kind);
    }
    clearEvents(gpa, &events);

    // Subsequent poll after deletions settles to zero events.
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "PollingWatcher rolls back earlier-root mutations when a later root fails transiently (#876, #1144)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/multi-flap/a", .{tmp.sub_path});
    defer gpa.free(root_a);
    const root_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/multi-flap/b", .{tmp.sub_path});
    defer gpa.free(root_b);

    try writeWatchTreeFile(io, root_a, "doc.md", "v1");
    try writeWatchTreeFile(io, root_b, "layout.html", "<html>{{content}}</html>");

    var pw = PollingWatcher.init(gpa, io);
    defer pw.deinit();
    try pw.addRoot(root_a);
    try pw.addRoot(root_b);
    const w = pw.watcher();

    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |e| gpa.free(e.path);
        events.deinit(gpa);
    }

    // Mutate and create under root_a while root_b is unreadable in the same poll.
    try writeWatchTreeFile(io, root_a, "doc.md", "v2-updated");
    try writeWatchTreeFile(io, root_a, "added.md", "fresh");
    try cwd.setFilePermissions(io, root_b, @fromBackingInt(@intCast(0)), .{});
    defer cwd.setFilePermissions(io, root_b, restorePermissions(), .{}) catch {};

    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);

    // Once root_b recovers, root_a's modification and creation must NOT have
    // been swallowed by an un-rolled-back partial snapshot.
    try cwd.setFilePermissions(io, root_b, restorePermissions(), .{});
    try w.poll(&events);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);

    var saw_modify = false;
    var saw_create = false;
    for (events.items) |ev| {
        if (ev.kind == .modify) saw_modify = true;
        if (ev.kind == .create) saw_create = true;
    }
    try std.testing.expect(saw_modify);
    try std.testing.expect(saw_create);
}

test "scanFiles matches portable statFile stamps across files, UTF-8 names, and skipped dirs (#1144)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/scan-equiv", .{tmp.sub_path});
    defer gpa.free(root);

    try writeWatchTreeFile(io, root, "empty.md", "");
    const big = try gpa.alloc(u8, 4097);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeWatchTreeFile(io, root, "nested/café-notes.md", big);
    try writeWatchTreeFile(io, root, ".git/config", "[core]\n");
    try writeWatchTreeFile(io, root, ".boris/state.json", "{}");

    {
        var root_dir = try cwd.openDir(io, root, .{});
        defer root_dir.close(io);
        root_dir.symLink(io, "empty.md", "symlink.md", .{}) catch {};
    }

    var actual = std.StringHashMap(FileStamp).init(gpa);
    defer {
        var it = actual.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        actual.deinit();
    }
    try scanFiles(io, gpa, root, &actual);

    var portable = std.StringHashMap(FileStamp).init(gpa);
    defer {
        var it = portable.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        portable.deinit();
    }
    try scanFilesMode(true, io, gpa, root, &portable);

    // Independently walk using `walkSelectively` + `statFile` as ground truth.
    var expected = std.StringHashMap(FileStamp).init(gpa);
    defer {
        var it = expected.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        expected.deinit();
    }
    {
        var dir = try cwd.openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .sym_link) continue;
            if (entry.kind == .directory) {
                if (shouldSkipScanDir(entry.basename)) continue;
                try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            const st = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
            const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
            try expected.put(joined, .{
                .mtime_ns = @intCast(st.mtime.nanoseconds),
                .size = st.size,
            });
        }
    }

    try std.testing.expectEqual(@as(usize, 2), expected.count());
    try std.testing.expectEqual(expected.count(), actual.count());
    try std.testing.expectEqual(expected.count(), portable.count());
    var exp_it = expected.iterator();
    while (exp_it.next()) |entry| {
        const got_actual = actual.get(entry.key_ptr.*) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(entry.value_ptr.mtime_ns, got_actual.mtime_ns);
        try std.testing.expectEqual(entry.value_ptr.size, got_actual.size);

        const got_portable = portable.get(entry.key_ptr.*) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(entry.value_ptr.mtime_ns, got_portable.mtime_ns);
        try std.testing.expectEqual(entry.value_ptr.size, got_portable.size);
    }
}

/// Permissions to restore after the unreadable-root flap test. POSIX mode
/// bits do not exist on Windows, where the attributes default is the honest
/// equivalent.
fn restorePermissions() std.Io.File.Permissions {
    return if (comptime builtin.os.tag == .windows) .default_dir else std.Io.File.Permissions.fromMode(0o755);
}

fn writeWatchTreeFile(io: Io, root_rel: []const u8, rel: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const full = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root_rel, rel });
    defer std.testing.allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| {
        try cwd.createDirPath(io, parent);
    }
    try cwd.writeFile(io, .{ .sub_path = full, .data = data });
}

fn readWatchTreeFile(io: Io, gpa: std.mem.Allocator, root_rel: []const u8, rel: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_rel, rel });
    defer gpa.free(full);
    var file = try cwd.openFile(io, full, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}
