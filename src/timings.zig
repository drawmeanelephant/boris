//! Opt-in `--timings` phase/counter instrumentation (PERF-027).
//!
//! Reports wall-clock durations for named compile phases plus useful counters
//! in a machine-readable form on stderr. It is deliberately **not** a
//! correctness dependency and never becomes a source of truth:
//!
//! - Default stdout/stderr, diagnostics, exit codes, publication outputs, and
//!   `--quiet` semantics are unchanged when timings are not requested.
//! - All state lives in `Timings`, which callers pass as `?*Timings` (null in
//!   the default path) so there is no global and no allocation when idle.
//! - Emission is best-effort: a failure to print never changes the build
//!   outcome.
//!
//! Phase names use stable snake_case identifiers so scripts can parse the JSON
//! line (`boris-timings {...}`) without depending on human output.

const std = @import("std");
const Io = std.Io;

/// Machine-parseable marker line prefix on stderr. The rest of the line is a
/// single JSON object:
///
///   boris-timings {"format":"boris-timings","schemaVersion":1,"phases":{...},"counters":{...}}
///
pub const json_marker = "boris-timings ";

pub const PhaseEntry = struct {
    name: []const u8,
    elapsed_ns: u64,
};

/// Stable phase names (kept in the issue's audit vocabulary where the phase
/// exists on this revision).
pub const phase_layout = "layout";
pub const phase_scan = "scan";
pub const phase_parse = "parse";
pub const phase_graph_validate = "graph_validate";
pub const phase_dependency_resolve = "dependency_resolve";
pub const phase_heading_harvest = "heading_harvest";
pub const phase_fingerprint = "fingerprint";
pub const phase_render = "render";
pub const phase_publish = "publish";
pub const phase_ir_emit = "ir_emit";

/// Stable counter names.
pub const counter_page_reads = "page_reads";
pub const counter_include_reads = "include_reads";
pub const counter_hash_bytes = "hash_bytes";
pub const counter_link_resolutions = "link_resolutions";
pub const counter_fast_path_hits = "fast_path_hits";

pub const Timings = struct {
    gpa: std.mem.Allocator,
    io: Io,
    phases: std.ArrayListUnmanaged(PhaseEntry) = .empty,
    counters: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io) Timings {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Timings) void {
        self.phases.deinit(self.gpa);
        self.counters.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start a scoped phase. Call `.end()` (or `.endErr()`) exactly once.
    pub fn start(self: *Timings, comptime name: []const u8) Phase {
        return .{
            .timings = self,
            .name = name,
            .io = self.io,
            .started = Io.Clock.awake.now(self.io),
        };
    }

    fn record(self: *Timings, name: []const u8, elapsed_ns: u64) void {
        self.phases.append(self.gpa, .{ .name = name, .elapsed_ns = elapsed_ns }) catch {};
    }

    /// Add `delta` to a counter (keys are static comptime strings).
    pub fn addCounter(self: *Timings, comptime name: []const u8, delta: u64) void {
        const gop = self.counters.getOrPut(self.gpa, name) catch return;
        if (gop.found_existing) {
            gop.value_ptr.* += delta;
        } else {
            gop.value_ptr.* = delta;
        }
    }

    /// Overwrite a counter with an absolute value.
    pub fn setCounter(self: *Timings, comptime name: []const u8, value: u64) void {
        const gop = self.counters.getOrPut(self.gpa, name) catch return;
        gop.value_ptr.* = value;
    }

    /// Best-effort stderr report: human table then the machine JSON line.
    /// Never fails the build; JSON emission failure is swallowed.
    /// Phases are sorted by name so deferred (scope-exit) recording cannot
    /// reorder output — the JSON line is deterministic for a given code path.
    pub fn emit(self: *const Timings) void {
        const sorted = self.gpa.alloc(PhaseEntry, self.phases.items.len) catch return;
        defer self.gpa.free(sorted);
        @memcpy(sorted, self.phases.items);
        std.mem.sort(PhaseEntry, sorted, {}, struct {
            fn less(_: void, a: PhaseEntry, b: PhaseEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.less);

        emitHuman(sorted);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        writeJson(self, sorted, &buf) catch return;
        std.debug.print("{s}{s}\n", .{ json_marker, buf.items });
    }

    fn writeJson(self: *const Timings, sorted: []const PhaseEntry, buf: *std.ArrayList(u8)) !void {
        try buf.appendSlice(self.gpa, "{\"format\":\"boris-timings\",\"schemaVersion\":1,\"phases\":{");
        for (sorted, 0..) |phase, i| {
            if (i > 0) try buf.append(self.gpa, ',');
            try jsonString(buf, self.gpa, phase.name);
            try buf.append(self.gpa, ':');
            const rendered = try std.fmt.allocPrint(self.gpa, "{d}", .{phase.elapsed_ns});
            defer self.gpa.free(rendered);
            try buf.appendSlice(self.gpa, rendered);
        }
        try buf.appendSlice(self.gpa, "},\"counters\":{");
        var it = self.counters.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try buf.append(self.gpa, ',');
            first = false;
            try jsonString(buf, self.gpa, entry.key_ptr.*);
            try buf.append(self.gpa, ':');
            const rendered = try std.fmt.allocPrint(self.gpa, "{d}", .{entry.value_ptr.*});
            defer self.gpa.free(rendered);
            try buf.appendSlice(self.gpa, rendered);
        }
        try buf.appendSlice(self.gpa, "}}");
    }

    fn jsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
        try buf.append(gpa, '"');
        for (s) |c| {
            switch (c) {
                '"' => try buf.appendSlice(gpa, "\\\""),
                '\\' => try buf.appendSlice(gpa, "\\\\"),
                else => try buf.append(gpa, c),
            }
        }
        try buf.append(gpa, '"');
    }
};

/// Scoped phase: created by `Timings.start`, ends via `end()` / `endErr()`.
pub const Phase = struct {
    timings: *Timings,
    name: []const u8,
    io: Io,
    started: Io.Timestamp,

    /// End the phase on a success path.
    pub fn end(self: Phase) void {
        self.timings.record(self.name, elapsedNs(self));
    }

    /// End the phase on an error path (durations still recorded; the error
    /// propagates after the call site uses `catch |err| { p.endErr(); return err; }`).
    pub fn endErr(self: Phase) void {
        self.timings.record(self.name, elapsedNs(self));
    }
};

fn elapsedNs(phase: Phase) u64 {
    const diff = phase.started.untilNow(phase.io, .awake).nanoseconds;
    return if (diff < 0) 0 else @intCast(diff);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn emitHuman(sorted: []const PhaseEntry) void {
    std.debug.print("timings (phase, ms):\n", .{});
    for (sorted) |phase| {
        std.debug.print("  {s:<24} {d:.3}\n", .{ phase.name, nsToMs(phase.elapsed_ns) });
    }
}

// --- tests -----------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "scoped phases record positive durations and stable names" {
    var t = Timings.init(std.testing.allocator, std.testing.io);
    defer t.deinit();

    var p = t.start(phase_scan);
    p.end();
    var q = t.start(phase_parse);
    q.end();

    try expectEqual(@as(usize, 2), t.phases.items.len);
    try expectEqualStrings(phase_scan, t.phases.items[0].name);
    try expectEqualStrings(phase_parse, t.phases.items[1].name);
    try expect(t.phases.items[0].elapsed_ns > 0);
    try expect(t.phases.items[1].elapsed_ns > 0);
}

test "emission sorts phases by name (defer-order independent)" {
    var t = Timings.init(std.testing.allocator, std.testing.io);
    defer t.deinit();

    var parse = t.start(phase_parse);
    var scan = t.start(phase_scan);
    scan.end();
    parse.end();

    const sorted = try std.testing.allocator.alloc(PhaseEntry, t.phases.items.len);
    defer std.testing.allocator.free(sorted);
    @memcpy(sorted, t.phases.items);
    std.mem.sort(PhaseEntry, sorted, {}, struct {
        fn less(_: void, a: PhaseEntry, b: PhaseEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    try expectEqualStrings(phase_parse, sorted[0].name);
    try expectEqualStrings(phase_scan, sorted[1].name);
}

test "counters accumulate and overwrite" {
    var t = Timings.init(std.testing.allocator, std.testing.io);
    defer t.deinit();

    t.addCounter(counter_page_reads, 10);
    t.addCounter(counter_page_reads, 5);
    t.setCounter(counter_fast_path_hits, 3);
    t.addCounter(counter_fast_path_hits, 2);

    try expectEqual(@as(u64, 15), t.counters.get(counter_page_reads).?);
    try expectEqual(@as(u64, 5), t.counters.get(counter_fast_path_hits).?);
    try expect(t.counters.get("absent") == null);
}

test "json emission is a single machine-readable line" {
    var t = Timings.init(std.testing.allocator, std.testing.io);
    defer t.deinit();

    var p = t.start(phase_scan);
    p.end();
    t.addCounter(counter_page_reads, 3);

    const sorted = try std.testing.allocator.alloc(PhaseEntry, t.phases.items.len);
    defer std.testing.allocator.free(sorted);
    @memcpy(sorted, t.phases.items);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try t.writeJson(sorted, &buf);

    try expect(std.mem.startsWith(u8, buf.items, "{\"format\":\"boris-timings\",\"schemaVersion\":1,\"phases\":{\"scan\":"));
    try expect(std.mem.indexOf(u8, buf.items, "\"counters\":{\"page_reads\":3}") != null);
}
