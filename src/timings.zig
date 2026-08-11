//! Opt-in phase timing and counter instrumentation (`--timings`).
//!
//! The default product path never constructs a `Recorder`, so default
//! stdout/stderr behavior, diagnostics, exit codes, published artifacts, and
//! `--quiet` semantics are untouched when `--timings` is not requested.
//!
//! When a `Recorder` is present it only observes: it cannot influence
//! compilation, publication, or failure behavior, and it is never a source of
//! truth for correctness. Durations come from the monotonic `awake` clock
//! (nanoseconds, integer), so the JSON report is deterministic in shape and
//! key order even though wall times obviously vary between runs.
//!
//! Phase semantics:
//! - `scan` / `parse` / `graph_validate` / `dependency_resolve` are the shared
//!   compiler-core phases (IR, RAG, context, llms, RSS, validate, and the HTML
//!   path's load/freeze/dependency work).
//! - `heading_harvest` through `proof_pack` are the HTML publication pipeline
//!   phases. Non-HTML modes never record them.
//!
//! Counter semantics:
//! - `page_reads`: number of page source file reads (load, shared state,
//!   heading harvest, render).
//! - `include_reads`: number of transitive include file reads.
//! - `hash_bytes`: payload bytes fed into page fingerprints.
//! - `link_resolutions`: local references resolved by the output link audit.
//! - `fast_path_hits`: heading-harvest cache-key hits and incremental
//!   cached-page skips.

const std = @import("std");
const Io = std.Io;
const json_out = @import("json_out.zig");

pub const Phase = enum {
    scan,
    parse,
    graph_validate,
    dependency_resolve,
    fingerprint,
    render,
    heading_harvest,
    search,
    link_audit,
    inventory,
    checks,
    claims,
    touches,
    proof_pack,
};

pub const Counter = enum {
    page_reads,
    include_reads,
    hash_bytes,
    link_resolutions,
    fast_path_hits,
};

const PhaseCount = @typeInfo(Phase).@"enum".fields.len;
const CounterCount = @typeInfo(Counter).@"enum".fields.len;

pub const Recorder = struct {
    /// I/O handle used to read the monotonic clock. Plain value copy; the
    /// recorder never performs file or stream I/O.
    io: Io,
    /// Accumulated nanoseconds per phase.
    phase_ns: [PhaseCount]u64 = [_]u64{0} ** PhaseCount,
    /// Monotonic start timestamp per phase (null when not currently running).
    active: [PhaseCount]?Io.Timestamp = [_]?Io.Timestamp{null} ** PhaseCount,
    /// True once a phase has been started; only these appear in the report.
    ever_started: [PhaseCount]bool = [_]bool{false} ** PhaseCount,
    counters: [CounterCount]u64 = [_]u64{0} ** CounterCount,
    /// Monotonic start of the recorded run (report `totalNs` baseline).
    run_start: Io.Timestamp = Io.Timestamp.zero,

    pub fn init(io: Io) Recorder {
        var recorder: Recorder = .{ .io = io };
        recorder.run_start = Io.Timestamp.now(io, .awake);
        return recorder;
    }

    pub fn start(self: *Recorder, phase: Phase) void {
        const idx = @intFromEnum(phase);
        if (self.active[idx] == null) {
            self.active[idx] = Io.Timestamp.now(self.io, .awake);
            self.ever_started[idx] = true;
        }
    }

    pub fn stop(self: *Recorder, phase: Phase) void {
        const idx = @intFromEnum(phase);
        const started = self.active[idx] orelse return;
        const elapsed = Io.Timestamp.durationTo(started, Io.Timestamp.now(self.io, .awake));
        if (elapsed.nanoseconds > 0) {
            self.phase_ns[idx] += @intCast(elapsed.nanoseconds);
        }
        self.active[idx] = null;
    }

    /// Stop every still-active phase so an error path that returns mid-phase
    /// still contributes its elapsed tail to the report.
    pub fn stopAll(self: *Recorder) void {
        inline for (@typeInfo(Phase).@"enum".fields, 0..) |_, i| self.stop(@enumFromInt(i));
    }

    pub fn bump(self: *Recorder, counter: Counter, amount: u64) void {
        self.counters[@intFromEnum(counter)] += amount;
    }

    /// Direct pointer to a counter, for callees that increment without holding
    /// a `Recorder` (e.g. the link audit's per-reference hot path).
    pub fn counterPtr(self: *Recorder, counter: Counter) *u64 {
        return &self.counters[@intFromEnum(counter)];
    }

    pub fn totalNs(self: *const Recorder) u64 {
        const elapsed = Io.Timestamp.durationTo(self.run_start, Io.Timestamp.now(self.io, .awake));
        if (elapsed.nanoseconds <= 0) return 0;
        return @intCast(elapsed.nanoseconds);
    }

    /// Deterministic pretty JSON report. Phases appear in canonical enum order
    /// and only when they were started at least once; counters always appear.
    /// Durations and totals are integer nanoseconds.
    pub fn renderJson(self: *const Recorder, gpa: std.mem.Allocator, mode: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);

        try buf.appendSlice(gpa, "{\n");
        try writeStringField(&buf, gpa, "format", "boris-timings");
        try writeStringField(&buf, gpa, "schemaVersion", "1");
        try writeStringField(&buf, gpa, "mode", mode);

        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"phases\": {\n");
        var first_phase = true;
        inline for (@typeInfo(Phase).@"enum".fields, 0..) |field, i| {
            if (self.ever_started[i]) {
                if (!first_phase) try buf.appendSlice(gpa, ",\n");
                first_phase = false;
                try json_out.indent(&buf, gpa, 2);
                try json_out.writeString(&buf, gpa, field.name);
                try buf.appendSlice(gpa, ": ");
                try appendU64(&buf, gpa, self.phase_ns[i]);
            }
        }
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "},\n");

        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"counters\": {\n");
        var first_counter = true;
        inline for (@typeInfo(Counter).@"enum".fields, 0..) |field, i| {
            if (!first_counter) try buf.appendSlice(gpa, ",\n");
            first_counter = false;
            try json_out.indent(&buf, gpa, 2);
            try json_out.writeString(&buf, gpa, field.name);
            try buf.appendSlice(gpa, ": ");
            try appendU64(&buf, gpa, self.counters[i]);
        }
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "},\n");

        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"totalNs\": ");
        try appendU64(&buf, gpa, self.totalNs());
        try buf.appendSlice(gpa, "\n}\n");
        return buf.toOwnedSlice(gpa);
    }
};

fn writeStringField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try json_out.indent(buf, gpa, 1);
    try json_out.writeString(buf, gpa, name);
    try buf.appendSlice(gpa, ": ");
    try json_out.writeString(buf, gpa, value);
    try buf.appendSlice(gpa, ",\n");
}

fn appendU64(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var tmp: [32]u8 = undefined;
    const piece = try std.fmt.bufPrint(&tmp, "{d}", .{v});
    try buf.appendSlice(gpa, piece);
}

// --- tests ------------------------------------------------------------------

/// Real sleep so two back-to-back monotonic clock reads (macOS ticks are
/// ~41ns) cannot land on the same tick and legitimately record 0 elapsed.
fn sleepOneMs() !void {
    const d = std.Io.Clock.Duration{
        .raw = std.Io.Duration.fromMilliseconds(1),
        .clock = .real,
    };
    _ = try d.sleep(std.testing.io);
}

test "recorder accumulates elapsed time and counters" {
    var recorder = Recorder.init(std.testing.io);
    recorder.start(.scan);
    try sleepOneMs();
    recorder.stop(.scan);
    recorder.bump(.page_reads, 3);
    recorder.bump(.page_reads, 2);
    try std.testing.expect(recorder.phase_ns[@intFromEnum(Phase.scan)] > 0);
    try std.testing.expectEqual(@as(u64, 5), recorder.counters[@intFromEnum(Counter.page_reads)]);
    try std.testing.expect(recorder.totalNs() > 0);
}

test "double start is idempotent and stop without start is a no-op" {
    var recorder = Recorder.init(std.testing.io);
    recorder.stop(.parse); // no-op
    recorder.start(.parse);
    recorder.start(.parse);
    try sleepOneMs();
    recorder.stop(.parse);
    recorder.stop(.parse); // no-op
    try std.testing.expect(recorder.phase_ns[@intFromEnum(Phase.parse)] > 0);
}

test "counterPtr points into the recorder" {
    var recorder = Recorder.init(std.testing.io);
    recorder.counterPtr(.link_resolutions).* += 7;
    try std.testing.expectEqual(@as(u64, 7), recorder.counters[@intFromEnum(Counter.link_resolutions)]);
}

test "stopAll closes phases left active by an error path" {
    var recorder = Recorder.init(std.testing.io);
    recorder.start(.render);
    try sleepOneMs();
    recorder.stopAll();
    try std.testing.expect(recorder.phase_ns[@intFromEnum(Phase.render)] > 0);
    try std.testing.expect(recorder.active[@intFromEnum(Phase.render)] == null);
}

test "renderJson reports only started phases in canonical order" {
    const gpa = std.testing.allocator;
    var recorder = Recorder.init(std.testing.io);
    recorder.start(.scan);
    recorder.stop(.scan);
    recorder.start(.parse);
    recorder.stop(.parse);
    recorder.bump(.fast_path_hits, 1);

    const bytes = try recorder.renderJson(gpa, "ir");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("boris-timings", try jsonFieldString(bytes, "format"));
    try std.testing.expectEqualStrings("ir", try jsonFieldString(bytes, "mode"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"scan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"render\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"page_reads\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"fast_path_hits\"") != null);

    // Canonical phase order: scan precedes parse.
    const scan_pos = std.mem.indexOf(u8, bytes, "\"scan\"").?;
    const parse_pos = std.mem.indexOf(u8, bytes, "\"parse\"").?;
    try std.testing.expect(scan_pos < parse_pos);
}

fn jsonFieldString(json: []const u8, field: []const u8) ![]const u8 {
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "\"{s}\": \"", .{field});
    const start = std.mem.indexOf(u8, json, key) orelse return error.MissingField;
    const rest = json[start + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.MissingQuote;
    return rest[0..end];
}
