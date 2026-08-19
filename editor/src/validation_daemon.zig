//! Long-lived `boris validate --watch --report` supervisor (#652).
//!
//! The host previously spawned a fresh `boris validate` subprocess per
//! request. When the installed compiler supports `--watch`, this module owns
//! one zero-write validation daemon per project: it re-runs the preflight on
//! every debounced change and rewrites `.boris/html-build-report.json` each
//! cycle (replacement, never append), staying alive across recoverable
//! content failures. The host watches that file (mtime + size) and adapts the
//! newest report through the same structured-diagnostic path as the one-shot
//! runner, so the report file remains the single authority and existing API
//! payloads stay byte-compatible.
//!
//! Process management is POSIX-only by design: the editor needs the daemon's
//! graceful SIGTERM shutdown contract plus non-blocking reaping so an
//! unexpected death can be recovered with bounded backoff. On Windows the
//! compiler probe reports unsupported and the host never consults the daemon
//! (the one-shot validate path is used unchanged).
//!
//! Everything happens synchronously inside the single-threaded request loop:
//! there is no background thread. The daemon process does the watching; the
//! host only polls it and the report file when a request arrives.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const project = @import("project.zig");
const runner = @import("runner.zig");

pub const State = enum { idle, running, success, failed, stale };

pub const Config = struct {
    project_root: []const u8,
    boris_path: []const u8,
    editor_id: []const u8,
    input_mode: project.InputMode,
};

pub const Signature = struct {
    mtime: Io.Timestamp,
    size: u64,
};

const max_report_bytes = 32 * 1024 * 1024;
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;
const initial_cycle_timeout_ns: u64 = 120 * std.time.ns_per_s;
const max_backoff_ns: u64 = 30 * std.time.ns_per_s;
const activity_window_ns: u64 = 3 * std.time.ns_per_s;
const pending_cycle_wait_ns: u64 = 3 * std.time.ns_per_s;

pub const Daemon = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: Config,
    watch_supported: ?bool = null,
    child: ?std.process.Child = null,
    state: State = .idle,
    cycle: u64 = 0,
    last_signature: ?Signature = null,
    latest: ?*const runner.Result = null,
    compiler_id: ?[]const u8 = null,
    last_term: ?std.process.Child.Term = null,
    failures: u32 = 0,
    next_spawn_allowed: i96 = 0,
    activity_at: ?i96 = null,
    activity_signature: ?Signature = null,
    result_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, io: Io, config: Config) Daemon {
        return .{
            .io = io,
            .gpa = gpa,
            .config = config,
            .result_arena = .init(gpa),
        };
    }

    /// SIGTERM-reap the daemon (no orphans) and release all allocations.
    pub fn deinit(self: *Daemon) void {
        self.stop();
        if (self.compiler_id) |id| self.gpa.free(id);
        self.result_arena.deinit();
    }

    /// The graceful shutdown contract: `boris validate --watch` exits 0 on
    /// SIGINT/SIGTERM, so `Child.kill` (SIGTERM then block-until-exit on
    /// POSIX) is the correct reaper and leaves no orphan behind.
    pub fn stop(self: *Daemon) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
    }

    /// Whether the installed compiler is a daemon-capable `validate --watch`
    /// (probed once via `boris validate --help`). Windows always falls back.
    pub fn watchSupported(self: *Daemon) bool {
        if (self.watch_supported) |supported| return supported;
        self.watch_supported = self.probeSupportsWatch();
        return self.watch_supported.?;
    }

    fn probeSupportsWatch(self: *Daemon) bool {
        if (comptime builtin.os.tag == .windows) return false;
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.config.boris_path, "validate", "--help" },
            .cwd = .{ .path = self.config.project_root },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
        }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const code: u8 = switch (result.term) {
            .exited => |value| value,
            else => return false,
        };
        if (code != 0) return false;
        return std.mem.indexOf(u8, result.stdout, "--watch") != null or
            std.mem.indexOf(u8, result.stderr, "--watch") != null;
    }

    /// The fixed daemon command. `--cooklang` projects get the same compiler
    /// selector as the one-shot path (mode parity).
    fn daemonArgv(self: *Daemon) ![]const []const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        errdefer args.deinit(self.gpa);
        try args.append(self.gpa, self.config.boris_path);
        try args.appendSlice(self.gpa, &.{
            "validate",
            "--input",
            "content",
            "--report",
            ".boris/" ++ runner.html_report_name,
            "--watch",
        });
        if (self.config.input_mode == .cooklang) try args.append(self.gpa, "--cooklang");
        return args.toOwnedSlice(self.gpa);
    }

    fn ensureArtifactDir(self: *Daemon) !void {
        var root = try Io.Dir.cwd().openDir(self.io, self.config.project_root, .{ .follow_symlinks = false });
        defer root.close(self.io);
        _ = root.openDir(self.io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => try root.createDir(self.io, ".boris", .default_dir),
            else => return err,
        };
    }

    fn spawn(self: *Daemon) !void {
        const argv = try self.daemonArgv();
        defer self.gpa.free(argv);
        try self.ensureArtifactDir();
        const child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.config.project_root },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        self.child = child;
        self.last_term = null;
        self.state = .running;
    }

    fn readCompilerId(self: *Daemon) ![]const u8 {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.config.boris_path, "--version" },
            .cwd = .{ .path = self.config.project_root },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
        }) catch return error.BorisUnavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const code: u8 = switch (result.term) {
            .exited => |value| value,
            else => return error.BorisUnavailable,
        };
        const compiler_id = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (code != 0 or compiler_id.len == 0 or !std.mem.startsWith(u8, compiler_id, "boris/")) {
            return error.InvalidBorisVersion;
        }
        return self.gpa.dupe(u8, compiler_id);
    }

    /// Non-blocking reap. When the daemon has exited (an unexpected death —
    /// recoverable content failures keep it alive), the exit term is recorded
    /// for classification and the child slot is cleared for a bounded-backoff
    /// restart. The `Child` is discarded without `wait`: with `.ignore` stdio
    /// there are no descriptors to clean up, and the exit status is already
    /// captured here.
    pub fn poll(self: *Daemon) void {
        const child = self.child orelse return;
        if (child.id == null) {
            self.child = null;
            return;
        }
        if (comptime builtin.os.tag == .windows) return;
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        const raw_rc = std.posix.system.wait4(child.id.?, &status, std.posix.W.NOHANG, null);
        switch (std.posix.errno(raw_rc)) {
            .SUCCESS => {},
            .INTR => return, // interrupted; retry next poll
            // ECHILD means something else reaped the child first; treat it as
            // gone without a term rather than leaking the zombie.
            .CHILD => {
                self.child = null;
                self.failures += 1;
                self.next_spawn_allowed = self.nowNs() + backoffDelay(self.failures);
                self.state = .stale;
                return;
            },
            else => return,
        }
        if (raw_rc == 0) return; // still running (WNOHANG idle)
        self.child = null;
        self.last_term = termFromStatus(@bitCast(status));
        self.failures += 1;
        self.next_spawn_allowed = self.nowNs() + backoffDelay(self.failures);
        self.state = .stale;
    }

    /// Spawn the daemon if it is not running and the bounded backoff window
    /// has elapsed. Returns true when a process is (or was just) running.
    fn ensureRunning(self: *Daemon) bool {
        if (self.child != null) return true;
        if (self.compiler_id == null) {
            self.compiler_id = self.readCompilerId() catch null;
            if (self.compiler_id == null) {
                self.failures += 1;
                self.next_spawn_allowed = self.nowNs() + backoffDelay(self.failures);
                self.state = .stale;
                return false;
            }
        }
        if (self.nowNs() < self.next_spawn_allowed) return false;
        self.spawn() catch {
            self.failures += 1;
            self.next_spawn_allowed = self.nowNs() + backoffDelay(self.failures);
            self.state = .stale;
            return false;
        };
        return true;
    }

    fn nowNs(self: *Daemon) i96 {
        return Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn reportSignature(self: *Daemon) !Signature {
        var root = try Io.Dir.cwd().openDir(self.io, self.config.project_root, .{ .follow_symlinks = false });
        defer root.close(self.io);
        var artifact = root.openDir(self.io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer artifact.close(self.io);
        const stat = try artifact.statFile(self.io, runner.html_report_name, .{});
        if (stat.kind != .file) return error.UnsafeArtifact;
        return .{ .mtime = stat.mtime, .size = stat.size };
    }

    fn readReport(self: *Daemon, allocator: std.mem.Allocator) ![]u8 {
        var root = try Io.Dir.cwd().openDir(self.io, self.config.project_root, .{ .follow_symlinks = false });
        defer root.close(self.io);
        var artifact = root.openDir(self.io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer artifact.close(self.io);
        var file = artifact.openFile(self.io, runner.html_report_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.UnsafeArtifact;
        var reader = file.reader(self.io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(max_report_bytes));
    }

    /// Re-read the report when its signature (mtime + size) changed and
    /// re-parse it into the latest result. A torn in-place write from a
    /// mid-cycle daemon simply fails the parse and is retried on the next
    /// poll, so `last_signature` only advances on a fully parsed report.
    fn refresh(self: *Daemon) void {
        const signature = self.reportSignature() catch return;
        if (self.last_signature) |last| {
            if (last.mtime.nanoseconds == signature.mtime.nanoseconds and last.size == signature.size) return;
        }
        const compiler_id = self.compiler_id orelse return;
        const bytes = self.readReport(self.gpa) catch return;
        defer self.gpa.free(bytes);
        _ = self.result_arena.reset(.retain_capacity);
        const stored = self.result_arena.allocator().create(runner.Result) catch return;
        stored.* = runner.resultFromReport(
            self.result_arena.allocator(),
            .{
                .project_root = self.config.project_root,
                .boris_path = self.config.boris_path,
                .editor_id = self.config.editor_id,
            },
            compiler_id,
            bytes,
        ) catch return;
        self.latest = stored;
        self.last_signature = signature;
        self.cycle += 1;
        self.failures = 0;
        self.state = if (stored.failure_class == .success) .success else .failed;
    }

    /// Serve a validate demand. Returns the newest daemon result (waiting for
    /// the initial cycle on first demand), or a process-failure result when
    /// the daemon died or could not be kept running.
    ///
    /// Result memory belongs either to the daemon's own arena (safe: the
    /// single-threaded request loop cannot refresh mid-request) or, for
    /// synthesized failures, to `allocator`.
    pub fn runValidate(self: *Daemon, allocator: std.mem.Allocator) !runner.Result {
        self.poll();
        if (!self.ensureRunning()) {
            // Backoff-blocked or unstartable: surface the failure now instead
            // of serving a stale success.
            return self.failureResult(allocator);
        }
        if (self.latest == null) {
            const deadline = self.nowNs() + initial_cycle_timeout_ns;
            while (self.nowNs() < deadline) {
                self.poll();
                if (self.child == null) {
                    // The daemon died while starting (crash loop): report the
                    // reaped term instead of respawning mid-request.
                    return self.failureResult(allocator);
                }
                self.refresh();
                if (self.latest != null) break;
                Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch {};
            }
        } else if (self.hasPendingCycle()) {
            // A save / create / rename / delete landed recently and the daemon
            // has not yet rewritten the report past it: wait (bounded) for that
            // cycle so the demand answers from after the change, never before.
            const deadline = self.nowNs() + pending_cycle_wait_ns;
            while (self.nowNs() < deadline) {
                self.poll();
                if (self.child == null) return self.failureResult(allocator);
                self.refresh();
                if (!self.hasPendingCycle()) break;
                Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch {};
            }
        } else {
            self.refresh();
        }
        if (self.latest) |result| return result.*;
        return self.failureResult(allocator);
    }

    /// Record that the host just changed the tree (save/create/rename/delete).
    /// The timestamp and the report signature at this moment let a later
    /// validate demand distinguish "a cycle from this change is still pending"
    /// (wait for it) from "the cycle already finished" (answer immediately).
    pub fn noteSave(self: *Daemon) void {
        self.activity_at = self.nowNs();
        self.activity_signature = self.reportSignature() catch null;
    }

    fn hasPendingCycle(self: *Daemon) bool {
        const activity = self.activity_at orelse return false;
        if (self.nowNs() - activity > activity_window_ns) return false;
        const current = self.reportSignature() catch null;
        const at = self.activity_signature;
        if (at == null) return current == null;
        if (current == null) return true;
        return current.?.mtime.nanoseconds == at.?.mtime.nanoseconds and current.?.size == at.?.size;
    }

    /// Read-only validation state for the shell. Polls liveness and refreshes
    /// the report so the state is current, but never spawns the daemon — the
    /// first validate demand (via `runValidate`) is what starts it.
    pub fn stateJson(self: *Daemon, allocator: std.mem.Allocator) ![]u8 {
        if (!self.watchSupported()) {
            return std.json.Stringify.valueAlloc(allocator, .{
                .supported = false,
                .state = "idle",
                .cycle = self.cycle,
                .failure_class = null,
                .problems_count = 0,
                .report_age_ms = null,
            }, .{});
        }
        self.poll();
        self.refresh();
        const failure_class: ?[]const u8 = if (self.latest) |result| @tagName(result.failure_class) else null;
        const problems_count: usize = if (self.latest) |result| result.problems.len else 0;
        const report_age_ms: ?u64 = if (self.last_signature) |signature|
            reportAgeMs(self.nowNs(), signature.mtime.nanoseconds)
        else
            null;
        return std.json.Stringify.valueAlloc(allocator, .{
            .supported = true,
            .state = @tagName(self.state),
            .cycle = self.cycle,
            .failure_class = failure_class,
            .problems_count = problems_count,
            .report_age_ms = report_age_ms,
        }, .{});
    }

    /// Synthesized process-failure result for a daemon that is not running.
    /// The reaped exit term, when present, preserves the compiler's contracted
    /// exit-code convention (so a daemon that died of unrecoverable I/O still
    /// reports exit 3 / failure class io).
    fn failureResult(self: *Daemon, allocator: std.mem.Allocator) !runner.Result {
        const compiler_id = self.compiler_id orelse "boris";
        const term = self.last_term;
        const class: runner.FailureClass = if (term) |value| switch (value) {
            .exited => |code| switch (code) {
                0 => .success,
                1 => .content,
                2 => .usage,
                3 => .io,
                else => .terminated,
            },
            else => .terminated,
        } else .terminated;
        const exit_code: ?u8 = if (term) |value| switch (value) {
            .exited => |code| code,
            else => null,
        } else null;
        const message = if (term != null)
            "Boris validation daemon stopped and is restarting with backoff."
        else
            "Boris validation daemon could not be started; the one-shot validate fallback is unavailable.";
        return runner.processFailureResult(
            allocator,
            .{
                .project_root = self.config.project_root,
                .boris_path = self.config.boris_path,
                .editor_id = self.config.editor_id,
            },
            .validate,
            compiler_id,
            class,
            exit_code,
            message,
        );
    }
};

/// Bounded exponential backoff: 1s, 2s, 4s, … capped at 30s. The counter is
/// reset on a fully parsed report cycle, so a healthy daemon never delays a
/// restart.
fn backoffDelay(failures: u32) i96 {
    if (failures == 0) return 0;
    var delay_ns: i96 = std.time.ns_per_s;
    var i: u32 = 1;
    while (i < failures and delay_ns < max_backoff_ns) : (i += 1) {
        delay_ns *= 2;
    }
    return @min(delay_ns, max_backoff_ns);
}

fn reportAgeMs(now: i96, report_mtime: i96) u64 {
    if (now <= report_mtime) return 0;
    return @intCast(@divTrunc(now - report_mtime, std.time.ns_per_ms));
}

fn termFromStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = @intCast(std.posix.W.EXITSTATUS(status)) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else
        .{ .unknown = status };
}

test "daemon argv matches the one-shot validate command plus --watch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var daemon: Daemon = .init(gpa, io, .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
        .input_mode = .markdown,
    });
    defer daemon.deinit();

    const argv = try daemon.daemonArgv();
    defer gpa.free(argv);
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("boris", argv[0]);
    try std.testing.expectEqualStrings("validate", argv[1]);
    try std.testing.expectEqualStrings("--report", argv[4]);
    try std.testing.expectEqualStrings(".boris/html-build-report.json", argv[5]);
    try std.testing.expectEqualStrings("--watch", argv[6]);
}

test "cooklang projects append the compiler selector" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var daemon: Daemon = .init(gpa, io, .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
        .input_mode = .cooklang,
    });
    defer daemon.deinit();

    const argv = try daemon.daemonArgv();
    defer gpa.free(argv);
    try std.testing.expectEqualStrings("--cooklang", argv[argv.len - 1]);
}

test "report signatures advance on rewrite and not on identical reads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root_path = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_path);

    var daemon: Daemon = .init(gpa, io, .{
        .project_root = root_path,
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
        .input_mode = .markdown,
    });
    defer daemon.deinit();

    try temp.dir.createDir(io, ".boris", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = ".boris/html-build-report.json", .data = "{\"ok\":true}" });
    const first = try daemon.reportSignature();
    const first_again = try daemon.reportSignature();
    try std.testing.expectEqual(first.mtime, first_again.mtime);
    try std.testing.expectEqual(first.size, first_again.size);
    Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch {};
    try temp.dir.writeFile(io, .{ .sub_path = ".boris/html-build-report.json", .data = "{\"ok\":false,\"extra\":1}" });
    const second = try daemon.reportSignature();
    try std.testing.expect(second.mtime.nanoseconds != first.mtime.nanoseconds or second.size != first.size);
}

test "noteSave marks a pending cycle until the report advances past it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root_path = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root_path);

    var daemon: Daemon = .init(gpa, io, .{
        .project_root = root_path,
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
        .input_mode = .markdown,
    });
    defer daemon.deinit();

    // No report yet: a note keeps the cycle pending until a report appears.
    daemon.noteSave();
    try std.testing.expect(daemon.hasPendingCycle());

    try temp.dir.createDir(io, ".boris", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = ".boris/html-build-report.json", .data = "{\"ok\":true}" });
    daemon.noteSave();

    // Same report content read back is not a new cycle: still pending.
    try std.testing.expect(daemon.hasPendingCycle());

    // A rewrite past the note clears the pending state.
    Io.sleep(io, .{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch {};
    try temp.dir.writeFile(io, .{ .sub_path = ".boris/html-build-report.json", .data = "{\"ok\":false,\"extra\":1}" });
    try std.testing.expect(!daemon.hasPendingCycle());

    // A change older than the activity window is never pending.
    daemon.activity_at = daemon.nowNs() - activity_window_ns - 1;
    try std.testing.expect(!daemon.hasPendingCycle());
}

test "backoff grows geometrically and caps at 30 seconds" {
    try std.testing.expectEqual(@as(i96, 0), backoffDelay(0));
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), backoffDelay(1));
    try std.testing.expectEqual(@as(i96, 2 * std.time.ns_per_s), backoffDelay(2));
    try std.testing.expectEqual(@as(i96, 4 * std.time.ns_per_s), backoffDelay(3));
    try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), backoffDelay(20));
}

test "report age is clamped at zero and expressed in milliseconds" {
    try std.testing.expectEqual(@as(u64, 0), reportAgeMs(10, 20));
    try std.testing.expectEqual(@as(u64, 0), reportAgeMs(20, 20));
    try std.testing.expectEqual(@as(u64, 1), reportAgeMs(20 + std.time.ns_per_ms, 20));
    try std.testing.expectEqual(@as(u64, 1250), reportAgeMs(20 + 1250 * std.time.ns_per_ms, 20));
}

test "reaped statuses convert to the contracted term shape" {
    const exited = termFromStatus(3 << 8);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, exited);
    const signaled = termFromStatus(9);
    try std.testing.expect(signaled == .signal);
}
