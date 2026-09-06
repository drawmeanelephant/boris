//! Managed `boris watch --watch-json` supervisor (editor watch-admin slice).
//!
//! The host runs **one explicitly started watch daemon per project** that owns
//! the `dist/` writer seat for as long as it is managed. The invocation is
//! fixed by the host from project discovery — the UI never supplies argv or a
//! working directory:
//!
//! ```text
//! boris watch --input content --html-dir dist --watch-json [--cooklang]
//! ```
//!
//! Under `--watch-json` (docs/contracts/watch-mode.md §8) the daemon streams
//! **exclusively NDJSON build events on stderr** — `hello`, `build-started`,
//! `build-succeeded`, `build-failed`, `watcher-started`, `watch-error`, and
//! `watch-stopped` — with prose progress and diagnostics suppressed (they
//! travel inside `build-failed` instead). `--serve` is deliberately not part
//! of this slice's invocation.
//!
//! Event capture follows the same file-watch philosophy as the validation
//! daemon's report file: the child's stderr is redirected to a spool file
//! under the editor state root, and request handlers parse appended lines on
//! demand. There is no thread and nothing in the single-request accept loop
//! ever blocks on daemon output — `start` returns right after the spawn and
//! events surface through polling (`GET /api/watch/state`,
//! `GET /api/watch/events?after=<seq>`).
//!
//! Lifecycle mirrors `validation_daemon.zig`: non-blocking reap (wait4 with
//! NOHANG), bounded exponential backoff (1s → 30s, reset on a completed
//! build cycle) after an unexpected death, SIGTERM + reap on `stop` and on
//! host shutdown so no orphan compiler process survives, and a Windows
//! unsupported probe that keeps every one-shot path unchanged.
//!
//! Everything happens synchronously inside the single-threaded request loop;
//! the daemon process does the watching, the host only reads its spool file
//! when a request arrives.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const project = @import("project.zig");
const validation_daemon = @import("validation_daemon.zig");

pub const State = enum { idle, running, success, failed, stale };

pub const Config = struct {
    project_root: []const u8,
    boris_path: []const u8,
    state_root: []const u8,
    input_mode: project.InputMode,
};

/// Version of the compiler's NDJSON event contract this host understands
/// (docs/contracts/watch-mode.md §8, `watch_events_schema` on `hello`).
pub const expected_schema: u64 = 1;

pub const spool_name = "watch-events.ndjson";

const max_line_bytes = 1024 * 1024;
const max_drain_bytes = 1024 * 1024;

/// One buffered compiler event: the raw NDJSON line plus its host-assigned
/// sequence number and classification. `seq` values are strictly increasing
/// across daemon restarts for the lifetime of the host session.
pub const EventKind = enum {
    hello,
    build_started,
    build_succeeded,
    build_failed,
    watcher_started,
    serve_started,
    watch_error,
    watch_stopped,
    unknown,

    pub fn isBuildBoundary(self: EventKind) bool {
        return self == .build_succeeded or self == .build_failed;
    }
};

pub const Event = struct {
    seq: u64,
    kind: EventKind,
    raw: []u8,
    phase: ?[]u8 = null,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        gpa.free(self.raw);
        if (self.phase) |phase| gpa.free(phase);
    }
};

/// Result of ingesting one complete NDJSON line; the daemon maps it onto its
/// own state transitions.
pub const Ingest = struct {
    kind: EventKind = .unknown,
    schema: ?u64 = null,
    schema_mismatch: bool = false,
};

/// Bounded ring of the newest compiler events. Overflow evicts the oldest
/// event (never blocks, never grows without bound); consumers detect the gap
/// through `oldestSeq()` versus the sequence they last observed.
pub const EventLog = struct {
    gpa: std.mem.Allocator,
    slots: [max_event_slots]?Event = @splat(null),
    head: usize = 0,
    len: usize = 0,
    bytes: usize = 0,
    seq: u64 = 0,
    cycle: u64 = 0,
    dropped_lines: u64 = 0,
    hello_schema: ?u64 = null,
    compiler_id: ?[]u8 = null,
    last_seq: u64 = 0,
    last_name: ?[]u8 = null,
    last_phase: ?[]u8 = null,

    pub const max_event_slots = 100;
    pub const max_buffer_bytes = 4 * 1024 * 1024;

    pub fn init(gpa: std.mem.Allocator) EventLog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EventLog) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const slot = (self.head + i) % max_event_slots;
            if (self.slots[slot]) |*event| event.deinit(self.gpa);
            self.slots[slot] = null;
        }
        self.head = 0;
        self.len = 0;
        self.bytes = 0;
        if (self.compiler_id) |id| self.gpa.free(id);
        self.compiler_id = null;
        if (self.last_name) |name| self.gpa.free(name);
        self.last_name = null;
        if (self.last_phase) |phase| self.gpa.free(phase);
        self.last_phase = null;
    }

    pub fn oldestSeq(self: *const EventLog) ?u64 {
        if (self.len == 0) return null;
        const slot = self.head % max_event_slots;
        return self.slots[slot].?.seq;
    }

    /// Pointers into the ring (valid until the next ingest; the
    /// single-threaded request loop never ingests mid-request) for every
    /// buffered event with `seq > after`, oldest first. The returned slice is
    /// owned by `allocator`; the events themselves stay in the log.
    pub fn collect(self: *const EventLog, allocator: std.mem.Allocator, after: u64) ![]*const Event {
        var out: std.ArrayList(*const Event) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const slot = (self.head + i) % max_event_slots;
            const event = &self.slots[slot].?;
            if (event.seq > after) try out.append(allocator, event);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Parse and buffer one complete NDJSON line. Best-effort: an
    /// unparseable or unbufferable line increments `dropped_lines` (and
    /// consumes no sequence number, so `after=<seq>` consumers never see a
    /// hole that was not an eviction).
    pub fn ingestLine(self: *EventLog, raw_line: []const u8) Ingest {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) return .{};
        var parsed = std.json.parseFromSlice(MinimalEvent, self.gpa, line, .{ .ignore_unknown_fields = true }) catch {
            self.dropped_lines += 1;
            return .{};
        };
        defer parsed.deinit();

        self.seq += 1;
        const kind = kindOf(parsed.value.event);
        var result: Ingest = .{ .kind = kind };
        if (kind == .hello) {
            self.hello_schema = parsed.value.watch_events_schema;
            result.schema = parsed.value.watch_events_schema;
            if (parsed.value.watch_events_schema) |schema| result.schema_mismatch = schema != expected_schema;
            if (parsed.value.compiler) |compiler| {
                if (self.compiler_id) |old| self.gpa.free(old);
                self.compiler_id = self.gpa.dupe(u8, compiler) catch null;
            }
        }
        if (kind.isBuildBoundary()) self.cycle += 1;

        // Newest-event summary survives eviction of the event itself.
        if (self.last_name) |old| self.gpa.free(old);
        self.last_name = self.gpa.dupe(u8, parsed.value.event) catch null;
        if (self.last_phase) |old| self.gpa.free(old);
        self.last_phase = if (parsed.value.phase) |phase| self.gpa.dupe(u8, phase) catch null else null;
        self.last_seq = self.seq;

        self.insert(self.seq, kind, line, parsed.value.phase);
        return result;
    }

    fn insert(self: *EventLog, seq: u64, kind: EventKind, raw_line: []const u8, phase: ?[]const u8) void {
        const raw = self.gpa.dupe(u8, raw_line) catch {
            self.dropped_lines += 1;
            return;
        };
        const phase_copy: ?[]u8 = if (phase) |value| self.gpa.dupe(u8, value) catch null else null;
        while (self.len > 0 and (self.len == max_event_slots or self.bytes + raw.len > max_buffer_bytes)) {
            self.evictOldest();
        }
        if (self.bytes + raw.len > max_buffer_bytes) {
            // A single event larger than the whole buffer cannot be pinned.
            self.gpa.free(raw);
            if (phase_copy) |value| self.gpa.free(value);
            self.dropped_lines += 1;
            return;
        }
        const slot = (self.head + self.len) % max_event_slots;
        self.slots[slot] = .{ .seq = seq, .kind = kind, .raw = raw, .phase = phase_copy };
        self.len += 1;
        self.bytes += raw.len;
    }

    fn evictOldest(self: *EventLog) void {
        if (self.len == 0) return;
        const slot = self.head % max_event_slots;
        if (self.slots[slot]) |*event| {
            self.bytes -= event.raw.len;
            event.deinit(self.gpa);
            self.slots[slot] = null;
        }
        self.head = (self.head + 1) % max_event_slots;
        self.len -= 1;
    }
};

const MinimalEvent = struct {
    event: []const u8,
    phase: ?[]const u8 = null,
    watch_events_schema: ?u64 = null,
    compiler: ?[]const u8 = null,
};

fn kindOf(name: []const u8) EventKind {
    const pairs = [_]struct { []const u8, EventKind }{
        .{ "hello", .hello },
        .{ "build-started", .build_started },
        .{ "build-succeeded", .build_succeeded },
        .{ "build-failed", .build_failed },
        .{ "watcher-started", .watcher_started },
        .{ "serve-started", .serve_started },
        .{ "watch-error", .watch_error },
        .{ "watch-stopped", .watch_stopped },
    };
    for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return .unknown;
}

pub const StartOutcome = enum { started, already_running, backing_off, refused, unsupported };

const LastEventView = struct {
    seq: u64,
    event: []const u8,
    phase: ?[]const u8,
};

const EventView = struct {
    seq: u64,
    event: std.json.Value,
};

pub const Daemon = struct {
    io: Io,
    gpa: std.mem.Allocator,
    config: Config,
    watch_supported: ?bool = null,
    child: ?std.process.Child = null,
    state: State = .idle,
    /// Set by an explicit `stop` (or the daemon's own graceful
    /// `watch-stopped`): supervision must not resurrect the daemon until the
    /// next explicit start.
    explicitly_stopped: bool = false,
    /// Set when `hello` advertises an unsupported `watch_events_schema`: the
    /// daemon is stopped and never respawned for the rest of the session.
    refused: bool = false,
    /// Set once an explicit start has succeeded; watch is never lazy-started.
    activated: bool = false,
    last_error: ?[]u8 = null,
    last_term: ?std.process.Child.Term = null,
    failures: u32 = 0,
    next_spawn_allowed: i96 = 0,
    log: EventLog,
    spool_path: ?[]u8 = null,
    read_offset: u64 = 0,
    pending: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, config: Config) Daemon {
        return .{
            .io = io,
            .gpa = gpa,
            .config = config,
            .log = EventLog.init(gpa),
        };
    }

    /// SIGTERM-reap the daemon (no orphans) and release all allocations.
    pub fn deinit(self: *Daemon) void {
        self.stop();
        self.log.deinit();
        self.pending.deinit(self.gpa);
        if (self.last_error) |value| self.gpa.free(value);
        self.last_error = null;
        if (self.spool_path) |path| self.gpa.free(path);
        self.spool_path = null;
    }

    /// The graceful shutdown contract: `boris watch` exits 0 on
    /// SIGINT/SIGTERM (docs/contracts/watch-mode.md §6), so `Child.kill`
    /// (SIGTERM then block-until-exit on POSIX) is the correct reaper and
    /// leaves no orphan behind. The daemon's final `watch-stopped` event is
    /// drained into the log before returning.
    pub fn stop(self: *Daemon) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
        self.explicitly_stopped = true;
        self.state = .idle;
        self.drain();
    }

    /// Whether the installed compiler is a `--watch-json`-capable watch
    /// daemon host (probed once via `boris watch --help`). Windows always
    /// reports unsupported and never spawns.
    pub fn watchSupported(self: *Daemon) bool {
        if (self.watch_supported) |supported| return supported;
        self.watch_supported = self.probeSupportsWatchJson();
        return self.watch_supported.?;
    }

    fn probeSupportsWatchJson(self: *Daemon) bool {
        if (comptime builtin.os.tag == .windows) return false;
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.config.boris_path, "watch", "--help" },
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
        return std.mem.indexOf(u8, result.stdout, "--watch-json") != null or
            std.mem.indexOf(u8, result.stderr, "--watch-json") != null;
    }

    /// The fixed daemon command, derived only from project discovery — same
    /// mode parity as every other fixed runner command (`--cooklang` for
    /// `.cook`-only trees). `--watch-json` is legal only with watch mode and
    /// switches stderr to the exclusive NDJSON event stream (§8); the
    /// `watch` command itself implies `--incremental`.
    fn daemonArgv(self: *Daemon) ![]const []const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        errdefer args.deinit(self.gpa);
        try args.append(self.gpa, self.config.boris_path);
        try args.appendSlice(self.gpa, &.{
            "watch",
            "--input",
            "content",
            "--html-dir",
            "dist",
            "--watch-json",
        });
        if (self.config.input_mode == .cooklang) try args.append(self.gpa, "--cooklang");
        return args.toOwnedSlice(self.gpa);
    }

    fn nowNs(self: *Daemon) i96 {
        return Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn setLastError(self: *Daemon, message: []const u8) void {
        if (self.last_error) |old| self.gpa.free(old);
        self.last_error = null;
        if (message.len == 0) return;
        self.last_error = self.gpa.dupe(u8, message) catch null;
    }

    fn spawnOnce(self: *Daemon) !void {
        const argv = try self.daemonArgv();
        defer self.gpa.free(argv);
        try Io.Dir.cwd().createDirPath(self.io, self.config.state_root);
        var root = try Io.Dir.cwd().openDir(self.io, self.config.state_root, .{ .follow_symlinks = false });
        defer root.close(self.io);
        // Truncate on every (re)start: the spool belongs to exactly one
        // daemon generation, and the read offset restarts with it.
        const spool = try root.createFile(self.io, spool_name, .{});
        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.config.project_root },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = spool },
        }) catch |err| {
            spool.close(self.io);
            return err;
        };
        // The child holds its own descriptor; the parent's copy is not
        // needed once the spawn has completed.
        spool.close(self.io);
        self.child = child;
        self.last_term = null;
        self.read_offset = 0;
        self.pending.clearRetainingCapacity();
        self.state = .running;
    }

    /// Explicit, idempotent start of the one-per-project daemon.
    pub fn start(self: *Daemon) StartOutcome {
        if (!self.watchSupported()) return .unsupported;
        if (self.refused) return .refused;
        self.drain();
        self.poll();
        if (self.child != null) return .already_running;
        if (self.nowNs() < self.next_spawn_allowed) return .backing_off;
        self.explicitly_stopped = false;
        self.spawnOnce() catch {
            self.failures += 1;
            self.next_spawn_allowed = self.nowNs() + validation_daemon.backoffDelay(self.failures);
            self.state = .stale;
            self.setLastError("The Boris watch daemon could not be started.");
            return .backing_off;
        };
        self.failures = 0;
        self.next_spawn_allowed = 0;
        self.activated = true;
        self.setLastError("");
        return .started;
    }

    /// Non-blocking reap. An unexpected death is recovered with bounded
    /// backoff; a graceful exit 0 (the daemon's own signal shutdown) is
    /// treated as a stop, not a crash.
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
                self.noteUnexpectedDeath(null);
                return;
            },
            else => return,
        }
        if (raw_rc == 0) return; // still running (WNOHANG idle)
        self.child = null;
        const term = validation_daemon.termFromStatus(@bitCast(status));
        self.last_term = term;
        switch (term) {
            .exited => |code| if (code == 0) {
                // Graceful self-shutdown (its `watch-stopped` event already
                // drained): a stop, not a crash.
                self.explicitly_stopped = true;
                self.state = .idle;
            } else {
                self.noteUnexpectedDeath(term);
            },
            else => self.noteUnexpectedDeath(term),
        }
    }

    fn noteUnexpectedDeath(self: *Daemon, term: ?std.process.Child.Term) void {
        _ = term;
        self.failures += 1;
        self.next_spawn_allowed = self.nowNs() + validation_daemon.backoffDelay(self.failures);
        self.state = .stale;
        self.setLastError("The Boris watch daemon stopped unexpectedly and is restarting with backoff.");
    }

    /// Spawn the daemon if it is managed, not stopped/refused, and the
    /// bounded backoff window has elapsed. Returns true when a process is
    /// (or was just) running.
    fn ensureRunning(self: *Daemon) bool {
        if (!self.activated or self.explicitly_stopped or self.refused) return false;
        if (self.child != null) return true;
        if (self.nowNs() < self.next_spawn_allowed) return false;
        self.spawnOnce() catch {
            self.failures += 1;
            self.next_spawn_allowed = self.nowNs() + validation_daemon.backoffDelay(self.failures);
            self.state = .stale;
            return false;
        };
        self.setLastError("");
        return true;
    }

    /// Read newly appended spool bytes and ingest each complete line. A torn
    /// trailing line stays in `pending` for the next drain. Called from
    /// request handlers only — never blocks on daemon output.
    fn drain(self: *Daemon) void {
        var root = Io.Dir.cwd().openDir(self.io, self.config.state_root, .{ .follow_symlinks = false }) catch return;
        defer root.close(self.io);
        var file = root.openFile(self.io, spool_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch return;
        defer file.close(self.io);
        const length = file.length(self.io) catch return;
        if (length < self.read_offset) {
            // The spool was replaced underneath us; restart the stream.
            self.read_offset = 0;
            self.pending.clearRetainingCapacity();
        }
        if (length == self.read_offset) return;
        const want: u64 = @min(length - self.read_offset, max_drain_bytes);
        const buffer = self.gpa.alloc(u8, @intCast(want)) catch return;
        defer self.gpa.free(buffer);
        const got = file.readPositionalAll(self.io, buffer, self.read_offset) catch return;
        self.read_offset += got;
        self.pending.appendSlice(self.gpa, buffer[0..got]) catch return;

        var scan_start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending.items, scan_start, '\n')) |index| {
            self.ingestLine(self.pending.items[scan_start..index]);
            scan_start = index + 1;
        }
        const rest = self.pending.items[scan_start..];
        if (rest.len > max_line_bytes) {
            // An unterminated oversized line is process noise, not an event.
            self.log.dropped_lines += 1;
            self.pending.clearRetainingCapacity();
        } else if (scan_start > 0) {
            std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
            self.pending.shrinkRetainingCapacity(rest.len);
        }
    }

    fn ingestLine(self: *Daemon, raw_line: []const u8) void {
        const ingest = self.log.ingestLine(raw_line);
        switch (ingest.kind) {
            .hello => {
                if (ingest.schema_mismatch) {
                    // Refuse to proceed against an unknown schema (§8): stop
                    // the daemon and never respawn it this session.
                    if (std.fmt.allocPrint(self.gpa, "The compiler's watch event schema ({d}) is not supported (expected {d}).", .{ ingest.schema orelse 0, expected_schema })) |allocated| {
                        self.setLastError(allocated);
                        self.gpa.free(allocated);
                    } else |_| {
                        self.setLastError("The compiler's watch event schema is not supported.");
                    }
                    if (self.child) |*child| child.kill(self.io);
                    self.child = null;
                    self.refused = true;
                    self.state = .idle;
                }
            },
            .build_started => self.state = .running,
            .build_succeeded => {
                self.state = .success;
                self.failures = 0;
                self.setLastError("");
            },
            .build_failed => {
                self.state = .failed;
                self.failures = 0;
            },
            .watch_stopped => {
                // The daemon announced its own graceful stop; do not
                // resurrect it without an explicit start.
                self.explicitly_stopped = true;
                self.state = .idle;
            },
            else => {},
        }
    }

    /// Supervision tick for read endpoints: ingest new events, reap a dead
    /// daemon, and recover it after the backoff window. Read endpoints
    /// provide the heartbeat; nothing spawns before the first explicit
    /// start.
    fn tick(self: *Daemon) void {
        self.drain();
        self.poll();
        _ = self.ensureRunning();
    }

    /// Honest read state, named exactly like `/api/validate-state`. The
    /// state is derived only from the daemon's own process liveness and the
    /// events it emitted — never fabricated into a mid-cycle state.
    pub fn stateJson(self: *Daemon, allocator: std.mem.Allocator) ![]u8 {
        if (!self.watchSupported()) {
            return std.json.Stringify.valueAlloc(allocator, .{
                .supported = false,
                .state = "idle",
                .seq = 0,
                .cycle = 0,
                .events_count = 0,
                .oldest_seq = null,
                .dropped_lines = 0,
                .last_event = null,
                .compiler_id = null,
                .hello_schema = null,
                .last_error = null,
            }, .{});
        }
        self.tick();
        return std.json.Stringify.valueAlloc(allocator, .{
            .supported = true,
            .state = @tagName(self.state),
            .seq = self.log.seq,
            .cycle = self.log.cycle,
            .events_count = self.log.len,
            .oldest_seq = self.log.oldestSeq(),
            .dropped_lines = self.log.dropped_lines,
            .last_event = self.lastEventView(),
            .compiler_id = self.log.compiler_id,
            .hello_schema = self.log.hello_schema,
            .last_error = self.last_error,
        }, .{});
    }

    fn lastEventView(self: *const Daemon) ?LastEventView {
        const name = self.log.last_name orelse return null;
        return .{ .seq = self.log.last_seq, .event = name, .phase = self.log.last_phase };
    }

    /// Idempotent start response: the same state object as
    /// `/api/watch/state` wrapped with an honest start outcome.
    pub fn startJson(self: *Daemon, allocator: std.mem.Allocator) ![]u8 {
        const outcome = self.start();
        const status: []const u8 = switch (outcome) {
            .started => "started",
            .already_running => "already-running",
            .backing_off => "backing-off",
            .refused => "refused",
            .unsupported => "unsupported",
        };
        return self.wrappedJson(allocator, status);
    }

    /// Graceful stop + reap response. Mirrors the validation daemon's
    /// shutdown contract: SIGTERM, block until exit, no orphan.
    pub fn stopJson(self: *Daemon, allocator: std.mem.Allocator) ![]u8 {
        const was_running = self.child != null;
        self.stop();
        const status: []const u8 = if (was_running) "stopped" else "not-running";
        return self.wrappedJson(allocator, status);
    }

    fn wrappedJson(self: *Daemon, allocator: std.mem.Allocator, status: []const u8) ![]u8 {
        const inner = try self.stateJson(allocator);
        defer allocator.free(inner);
        return std.fmt.allocPrint(allocator, "{{\"status\":\"{s}\",\"state\":{s}}}", .{ status, inner });
    }

    /// Bounded buffered events with `seq > after` for UI polling. `gap`
    /// marks eviction: events the consumer has not seen were dropped from
    /// the head of the ring, so it must resync from `oldest_seq` instead of
    /// assuming a contiguous history.
    pub fn eventsJson(self: *Daemon, allocator: std.mem.Allocator, after: u64) ![]u8 {
        if (!self.watchSupported()) {
            return std.json.Stringify.valueAlloc(allocator, .{
                .supported = false,
                .seq = 0,
                .oldest_seq = null,
                .gap = false,
                .events = [0]EventView{},
            }, .{});
        }
        self.tick();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var views: std.ArrayList(EventView) = .empty;
        const buffered = try self.log.collect(arena.allocator(), after);
        for (buffered) |event| {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), event.raw, .{}) catch continue;
            try views.append(arena.allocator(), .{ .seq = event.seq, .event = value });
        }
        const oldest = self.log.oldestSeq();
        const gap = self.log.seq > after and (oldest == null or oldest.? > after +| 1);
        return std.json.Stringify.valueAlloc(allocator, .{
            .supported = true,
            .seq = self.log.seq,
            .oldest_seq = oldest,
            .gap = gap,
            .events = views.items,
        }, .{});
    }

    /// Dist-writer ownership: once a watch daemon has been started, the host
    /// treats `dist/` as owned by the daemon until the watch daemon is
    /// explicitly stopped or refused — including while it is in a
    /// backoff-restart window, because a respawn may begin writing `dist/`
    /// at any moment. `/api/preview/rebuild` refuses with a distinct state
    /// while this is true.
    pub fn distOwned(self: *const Daemon) bool {
        return self.activated and !self.explicitly_stopped and !self.refused;
    }

    /// The reason an explicit start must be refused outright, if any:
    /// `watch_unsupported` (old compiler or Windows) or
    /// `watch_schema_unsupported` (a previous session's `hello` advertised a
    /// `watch_events_schema` this host does not understand).
    pub fn startRefusal(self: *Daemon) ?[]const u8 {
        if (!self.watchSupported()) return "watch_unsupported";
        if (self.refused) return "watch_schema_unsupported";
        return null;
    }
};

test "daemon argv matches the contracted watch command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var daemon: Daemon = .init(gpa, io, .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .state_root = "/cache/state",
        .input_mode = .markdown,
    });
    defer daemon.deinit();

    const argv = try daemon.daemonArgv();
    defer gpa.free(argv);
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("boris", argv[0]);
    try std.testing.expectEqualStrings("watch", argv[1]);
    try std.testing.expectEqualStrings("--input", argv[2]);
    try std.testing.expectEqualStrings("content", argv[3]);
    try std.testing.expectEqualStrings("--html-dir", argv[4]);
    try std.testing.expectEqualStrings("dist", argv[5]);
    try std.testing.expectEqualStrings("--watch-json", argv[6]);
}

test "cooklang projects append the compiler selector" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var daemon: Daemon = .init(gpa, io, .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .state_root = "/cache/state",
        .input_mode = .cooklang,
    });
    defer daemon.deinit();

    const argv = try daemon.daemonArgv();
    defer gpa.free(argv);
    try std.testing.expectEqualStrings("--cooklang", argv[argv.len - 1]);
}

test "event log classifies compiler events and counts build cycles" {
    var log: EventLog = .init(std.testing.allocator);
    defer log.deinit();

    const hello = log.ingestLine("{\"event\":\"hello\",\"watch_events_schema\":1,\"compiler\":\"boris/0.8.2\"}\n");
    try std.testing.expectEqual(EventKind.hello, hello.kind);
    try std.testing.expect(!hello.schema_mismatch);
    try std.testing.expectEqual(@as(u64, 1), log.seq);
    try std.testing.expectEqualStrings("boris/0.8.2", log.compiler_id.?);

    const started = log.ingestLine("{\"event\":\"build-started\",\"phase\":\"initial\",\"mode\":\"html\",\"targets\":[\"default\"]}");
    try std.testing.expectEqual(EventKind.build_started, started.kind);

    const succeeded = log.ingestLine("{\"event\":\"build-succeeded\",\"phase\":\"initial\",\"mode\":\"html\",\"targets\":[\"default\"],\"pages_written\":3,\"duration_ms\":42}");
    try std.testing.expectEqual(EventKind.build_succeeded, succeeded.kind);
    try std.testing.expectEqual(@as(u64, 1), log.cycle);

    const failed = log.ingestLine("{\"event\":\"build-failed\",\"phase\":\"rebuild\",\"mode\":\"html\",\"targets\":[\"default\"],\"changed\":[\"a.md\"],\"errors\":1,\"diagnostics\":[],\"recoverable\":true,\"duration_ms\":5}");
    try std.testing.expectEqual(EventKind.build_failed, failed.kind);
    try std.testing.expectEqual(@as(u64, 2), log.cycle);
    try std.testing.expectEqual(@as(u64, 4), log.seq);
    try std.testing.expectEqualStrings("build-failed", log.last_name.?);
    try std.testing.expectEqualStrings("rebuild", log.last_phase.?);

    const stopped = log.ingestLine("{\"event\":\"watch-stopped\",\"reason\":\"signal\"}");
    try std.testing.expectEqual(EventKind.watch_stopped, stopped.kind);
    try std.testing.expectEqualStrings("watch-stopped", log.last_name.?);

    try std.testing.expectEqual(@as(u64, 5), log.seq);
    try std.testing.expectEqual(@as(u64, 0), log.dropped_lines);
}

test "event log refuses unknown hello schemas and keeps known ones" {
    var log: EventLog = .init(std.testing.allocator);
    defer log.deinit();

    const future = log.ingestLine("{\"event\":\"hello\",\"watch_events_schema\":99,\"compiler\":\"boris/9.0.0\"}");
    try std.testing.expect(future.schema_mismatch);
    try std.testing.expectEqual(@as(u64, 99), future.schema.?);

    var again: EventLog = .init(std.testing.allocator);
    defer again.deinit();
    const current = again.ingestLine("{\"event\":\"hello\",\"watch_events_schema\":1}");
    try std.testing.expect(!current.schema_mismatch);
}

test "event log drops unparseable lines without consuming a sequence number" {
    var log: EventLog = .init(std.testing.allocator);
    defer log.deinit();

    _ = log.ingestLine("{\"event\":\"hello\",\"watch_events_schema\":1}");
    _ = log.ingestLine("this is not json");
    _ = log.ingestLine("{\"event\":\"build-started\",\"phase\":\"initial\",\"mode\":\"html\",\"targets\":[\"default\"]}");
    try std.testing.expectEqual(@as(u64, 2), log.seq);
    try std.testing.expectEqual(@as(u64, 1), log.dropped_lines);

    // Valid JSON without the `event` discriminator is also dropped.
    _ = log.ingestLine("{\"something\":\"else\"}");
    try std.testing.expectEqual(@as(u64, 2), log.seq);
    try std.testing.expectEqual(@as(u64, 2), log.dropped_lines);
}

test "event buffer is bounded by count with monotonically increasing seqs" {
    var log: EventLog = .init(std.testing.allocator);
    defer log.deinit();

    var line_buffer: [128]u8 = undefined;
    var i: u64 = 0;
    while (i < EventLog.max_event_slots + 20) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"watch-error\",\"message\":\"cycle {d}\",\"recoverable\":true}}", .{i});
        _ = log.ingestLine(line);
    }
    try std.testing.expectEqual(@as(usize, EventLog.max_event_slots), log.len);
    try std.testing.expectEqual(@as(u64, EventLog.max_event_slots + 20), log.seq);

    // The oldest retained seq proves eviction of the first 20 events.
    try std.testing.expectEqual(@as(u64, 21), log.oldestSeq().?);

    const buffered = try log.collect(std.testing.allocator, 0);
    defer std.testing.allocator.free(buffered);
    try std.testing.expectEqual(@as(usize, EventLog.max_event_slots), buffered.len);
    try std.testing.expectEqual(@as(u64, 21), buffered[0].seq);
    try std.testing.expectEqual(@as(u64, EventLog.max_event_slots + 20), buffered[buffered.len - 1].seq);

    const after_30 = try log.collect(std.testing.allocator, 30);
    defer std.testing.allocator.free(after_30);
    try std.testing.expectEqual(@as(usize, EventLog.max_event_slots + 20 - 30), after_30.len);
}

test "collect from a seq beyond the newest returns nothing" {
    var log: EventLog = .init(std.testing.allocator);
    defer log.deinit();
    _ = log.ingestLine("{\"event\":\"hello\",\"watch_events_schema\":1}");
    const none = try log.collect(std.testing.allocator, log.seq);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "unknown compiler events are buffered verbatim for honest surfacing" {
    var log: EventLog = .init(std.testing.allocator);
    defer log.deinit();

    _ = log.ingestLine("{\"event\":\"hello\",\"watch_events_schema\":1}");
    _ = log.ingestLine("{\"event\":\"future-event\",\"detail\":{}}");
    try std.testing.expectEqual(@as(u64, 2), log.seq);
    const buffered = try log.collect(std.testing.allocator, 0);
    defer std.testing.allocator.free(buffered);
    try std.testing.expectEqual(@as(usize, 2), buffered.len);
    try std.testing.expectEqual(EventKind.unknown, buffered[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, buffered[1].raw, "future-event") != null);
}
