//! NDJSON event renderers for `boris watch --watch-json`
//! (docs/contracts/watch-mode.md §8).
//!
//! Each renderer produces exactly one JSON object with stable key order and a
//! trailing newline; the watch coordinator emits one per line on stderr. The
//! event contract is versioned by `watch_events_schema` on the `hello`
//! handshake so consumers can refuse unknown versions (mirroring how IR
//! artifacts gate on `schemaVersion`). Key order is written explicitly through
//! `structured_out.Sink`, so a consumer can pin the exact byte shape.

const std = @import("std");
const diag = @import("diag.zig");
const Sink = @import("structured_out.zig").Sink;

/// Version of this event contract (docs/contracts/watch-mode.md §8).
pub const schema_version: u32 = 1;

fn appendStringList(sink: *Sink, values: []const []const u8) !void {
    try sink.lit("[");
    for (values, 0..) |v, i| {
        if (i > 0) try sink.lit(",");
        try sink.jsonString(v);
    }
    try sink.lit("]");
}

fn appendOptionalStringList(sink: *Sink, values: ?[]const []const u8) !void {
    if (values) |list| {
        try appendStringList(sink, list);
    } else {
        try sink.lit("null");
    }
}

fn appendOptionalUsize(sink: *Sink, value: ?usize) !void {
    if (value) |v| {
        try sink.jsonNumber(v);
    } else {
        try sink.lit("null");
    }
}

fn appendU64(sink: *Sink, value: u64) !void {
    try sink.num(@intCast(value));
}

fn appendOptionalU32(sink: *Sink, value: ?u32) !void {
    if (value) |v| {
        try sink.num(@intCast(v));
    } else {
        try sink.lit("null");
    }
}

/// One diagnostic object, byte-identical in shape and field order to the
/// `build-report.json` / `html-build-report-0.2.0` diagnostic object
/// (severity, code, message, remediation, sourcePath, line, column, id).
fn appendDiagnostic(sink: *Sink, d: diag.Diagnostic) !void {
    try sink.lit("{\"severity\":");
    try sink.jsonString(d.severity.jsonName());
    try sink.lit(",\"code\":");
    try sink.jsonString(d.code.name());
    try sink.lit(",\"message\":");
    try sink.jsonString(d.message);
    try sink.lit(",\"remediation\":");
    try sink.jsonString(d.remediation);
    try sink.lit(",\"sourcePath\":");
    if (d.source_path.len == 0) try sink.lit("null") else try sink.jsonString(d.source_path);
    try sink.lit(",\"line\":");
    try appendOptionalU32(sink, d.line);
    try sink.lit(",\"column\":");
    try appendOptionalU32(sink, d.column);
    try sink.lit(",\"id\":");
    if (d.id.len == 0) try sink.lit("null") else try sink.jsonString(d.id);
    try sink.lit("}");
}

fn appendDiagnostics(sink: *Sink, diagnostics: []const diag.Diagnostic) !void {
    try sink.lit("[");
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try sink.lit(",");
        try appendDiagnostic(sink, d);
    }
    try sink.lit("]");
}

fn finish(sink: *Sink) ![]u8 {
    try sink.lit("\n");
    return sink.toOwnedSlice();
}

/// `{"event":"hello","watch_events_schema":1,"compiler":"boris/0.8.1"}`
/// First line of the stream; consumers gate on `watch_events_schema`.
pub fn renderHello(gpa: std.mem.Allocator, compiler_id: []const u8) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("hello");
    try sink.lit(",\"watch_events_schema\":");
    try sink.jsonNumber(schema_version);
    try sink.lit(",\"compiler\":");
    try sink.jsonString(compiler_id);
    try sink.lit("}");
    return finish(&sink);
}

pub fn renderBuildStarted(
    gpa: std.mem.Allocator,
    phase: []const u8,
    mode: []const u8,
    targets: []const []const u8,
    changed: ?[]const []const u8,
) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("build-started");
    try sink.lit(",\"phase\":");
    try sink.jsonString(phase);
    try sink.lit(",\"mode\":");
    try sink.jsonString(mode);
    try sink.lit(",\"targets\":");
    try appendStringList(&sink, targets);
    if (changed) |list| {
        try sink.lit(",\"changed\":");
        try appendStringList(&sink, list);
    }
    try sink.lit("}");
    return finish(&sink);
}

pub fn renderBuildSucceeded(
    gpa: std.mem.Allocator,
    phase: []const u8,
    mode: []const u8,
    targets: []const []const u8,
    changed: ?[]const []const u8,
    pages_written: ?usize,
    duration_ms: u64,
) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("build-succeeded");
    try sink.lit(",\"phase\":");
    try sink.jsonString(phase);
    try sink.lit(",\"mode\":");
    try sink.jsonString(mode);
    try sink.lit(",\"targets\":");
    try appendStringList(&sink, targets);
    if (changed) |list| {
        try sink.lit(",\"changed\":");
        try appendStringList(&sink, list);
    }
    try sink.lit(",\"pages_written\":");
    try appendOptionalUsize(&sink, pages_written);
    try sink.lit(",\"duration_ms\":");
    try appendU64(&sink, duration_ms);
    try sink.lit("}");
    return finish(&sink);
}

pub fn renderBuildFailed(
    gpa: std.mem.Allocator,
    phase: []const u8,
    mode: []const u8,
    targets: []const []const u8,
    changed: ?[]const []const u8,
    errors: usize,
    diagnostics: []const diag.Diagnostic,
    recoverable: bool,
    duration_ms: u64,
) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("build-failed");
    try sink.lit(",\"phase\":");
    try sink.jsonString(phase);
    try sink.lit(",\"mode\":");
    try sink.jsonString(mode);
    try sink.lit(",\"targets\":");
    try appendStringList(&sink, targets);
    if (changed) |list| {
        try sink.lit(",\"changed\":");
        try appendStringList(&sink, list);
    }
    try sink.lit(",\"errors\":");
    try sink.jsonNumber(errors);
    try sink.lit(",\"diagnostics\":");
    try appendDiagnostics(&sink, diagnostics);
    try sink.lit(",\"recoverable\":");
    try sink.jsonBool(recoverable);
    try sink.lit(",\"duration_ms\":");
    try appendU64(&sink, duration_ms);
    try sink.lit("}");
    return finish(&sink);
}

pub fn renderWatcherStarted(
    gpa: std.mem.Allocator,
    mode: []const u8,
    targets: []const []const u8,
) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("watcher-started");
    try sink.lit(",\"mode\":");
    try sink.jsonString(mode);
    try sink.lit(",\"targets\":");
    try appendStringList(&sink, targets);
    try sink.lit("}");
    return finish(&sink);
}

/// `{"event":"serve-started","url":"http://127.0.0.1:53202/","helper":"http://127.0.0.1:53202/__boris/","port":53202}`
/// Emitted whenever `--serve` is on, even under `--quiet` — it is the only
/// port discovery the `--serve` consumer has.
pub fn renderServeStarted(
    gpa: std.mem.Allocator,
    url: []const u8,
    helper: []const u8,
    port: u16,
) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("serve-started");
    try sink.lit(",\"url\":");
    try sink.jsonString(url);
    try sink.lit(",\"helper\":");
    try sink.jsonString(helper);
    try sink.lit(",\"port\":");
    try sink.num(@intCast(port));
    try sink.lit("}");
    return finish(&sink);
}

pub fn renderWatchError(
    gpa: std.mem.Allocator,
    message: []const u8,
    recoverable: bool,
) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("watch-error");
    try sink.lit(",\"message\":");
    try sink.jsonString(message);
    try sink.lit(",\"recoverable\":");
    try sink.jsonBool(recoverable);
    try sink.lit("}");
    return finish(&sink);
}

pub fn renderWatchStopped(gpa: std.mem.Allocator, reason: []const u8) ![]u8 {
    var sink = Sink.init(gpa);
    errdefer sink.deinit();
    try sink.lit("{\"event\":");
    try sink.jsonString("watch-stopped");
    try sink.lit(",\"reason\":");
    try sink.jsonString(reason);
    try sink.lit("}");
    return finish(&sink);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hello event pins schema and compiler" {
    const gpa = std.testing.allocator;
    const line = try renderHello(gpa, "boris/0.8.1");
    defer gpa.free(line);
    try std.testing.expectEqualStrings("{\"event\":\"hello\",\"watch_events_schema\":1,\"compiler\":\"boris/0.8.1\"}\n", line);
}

test "build-started rebuild carries sorted changed set" {
    const gpa = std.testing.allocator;
    const line = try renderBuildStarted(gpa, "rebuild", "html", &.{"default"}, &.{ "guides/overview.md", "index.md" });
    defer gpa.free(line);
    try std.testing.expectEqualStrings(
        "{\"event\":\"build-started\",\"phase\":\"rebuild\",\"mode\":\"html\",\"targets\":[\"default\"],\"changed\":[\"guides/overview.md\",\"index.md\"]}\n",
        line,
    );
}

test "build-succeeded initial omits changed, carries pages and duration" {
    const gpa = std.testing.allocator;
    const line = try renderBuildSucceeded(gpa, "initial", "html", &.{"default"}, null, 25, 312);
    defer gpa.free(line);
    try std.testing.expectEqualStrings(
        "{\"event\":\"build-succeeded\",\"phase\":\"initial\",\"mode\":\"html\",\"targets\":[\"default\"],\"pages_written\":25,\"duration_ms\":312}\n",
        line,
    );
}

test "build-failed carries diagnostics in report shape" {
    const gpa = std.testing.allocator;
    const diags = [_]diag.Diagnostic{
        .{
            .severity = .error_,
            .code = .EFRONTMATTER,
            .message = "unknown key \"category\"",
            .remediation = "",
            .source_path = "guides/overview.md",
            .line = 2,
            .column = 1,
        },
    };
    const line = try renderBuildFailed(gpa, "rebuild", "html", &.{"default"}, &.{"guides/overview.md"}, 1, &diags, true, 14);
    defer gpa.free(line);
    try std.testing.expectEqualStrings(
        "{\"event\":\"build-failed\",\"phase\":\"rebuild\",\"mode\":\"html\",\"targets\":[\"default\"],\"changed\":[\"guides/overview.md\"],\"errors\":1,\"diagnostics\":[{\"severity\":\"error\",\"code\":\"EFRONTMATTER\",\"message\":\"unknown key \\\"category\\\"\",\"remediation\":\"\",\"sourcePath\":\"guides/overview.md\",\"line\":2,\"column\":1,\"id\":null}],\"recoverable\":true,\"duration_ms\":14}\n",
        line,
    );
}

test "build-failed pins multiple diagnostics, ordering, and null optionals" {
    const gpa = std.testing.allocator;
    // Three diagnostics in one event: a fully-populated error, a warning with
    // a line but no column/source/id, and a bare info with every optional
    // field absent. The renderer must preserve this order and emit the
    // report-shape keys for each object, with absent optionals as `null`.
    const diags = [_]diag.Diagnostic{
        .{
            .severity = .error_,
            .code = .EREFERENCEMISSING,
            .message = "wiki-link target \"does-not-exist\" not found in the page graph",
            .remediation = "Point the wiki-link at an existing page entity id",
            .source_path = "guides/overview.md",
            .line = 7,
            .column = 9,
            .id = "does-not-exist",
        },
        .{
            .severity = .warning,
            .code = .EUNICODE,
            .message = "invisible Unicode character",
            .line = 4,
        },
        .{
            .severity = .info,
            .code = .EVERIFICATIONHEAD,
            .message = "layout omits {{head}} slot",
        },
    };
    const line = try renderBuildFailed(gpa, "rebuild", "html", &.{"default"}, &.{"index.md"}, 1, &diags, true, 14);
    defer gpa.free(line);
    try std.testing.expectEqualStrings(
        "{\"event\":\"build-failed\",\"phase\":\"rebuild\",\"mode\":\"html\",\"targets\":[\"default\"],\"changed\":[\"index.md\"],\"errors\":1,\"diagnostics\":[{\"severity\":\"error\",\"code\":\"EREFERENCEMISSING\",\"message\":\"wiki-link target \\\"does-not-exist\\\" not found in the page graph\",\"remediation\":\"Point the wiki-link at an existing page entity id\",\"sourcePath\":\"guides/overview.md\",\"line\":7,\"column\":9,\"id\":\"does-not-exist\"},{\"severity\":\"warning\",\"code\":\"EUNICODE\",\"message\":\"invisible Unicode character\",\"remediation\":\"\",\"sourcePath\":null,\"line\":4,\"column\":null,\"id\":null},{\"severity\":\"info\",\"code\":\"EVERIFICATIONHEAD\",\"message\":\"layout omits {{head}} slot\",\"remediation\":\"\",\"sourcePath\":null,\"line\":null,\"column\":null,\"id\":null}],\"recoverable\":true,\"duration_ms\":14}\n",
        line,
    );
}

test "validate-mode events carry mode validate and null pages_written (#647)" {
    const gpa = std.testing.allocator;
    const started = try renderBuildStarted(gpa, "initial", "validate", &.{"default"}, null);
    defer gpa.free(started);
    try std.testing.expectEqualStrings(
        "{\"event\":\"build-started\",\"phase\":\"initial\",\"mode\":\"validate\",\"targets\":[\"default\"]}\n",
        started,
    );

    const done = try renderBuildSucceeded(gpa, "initial", "validate", &.{"default"}, null, null, 7);
    defer gpa.free(done);
    try std.testing.expectEqualStrings(
        "{\"event\":\"build-succeeded\",\"phase\":\"initial\",\"mode\":\"validate\",\"targets\":[\"default\"],\"pages_written\":null,\"duration_ms\":7}\n",
        done,
    );

    const watcher = try renderWatcherStarted(gpa, "validate", &.{"default"});
    defer gpa.free(watcher);
    try std.testing.expectEqualStrings(
        "{\"event\":\"watcher-started\",\"mode\":\"validate\",\"targets\":[\"default\"]}\n",
        watcher,
    );
}

test "serve-started carries bound port url and helper" {
    const gpa = std.testing.allocator;
    const line = try renderServeStarted(gpa, "http://127.0.0.1:53202/", "http://127.0.0.1:53202/__boris/", 53202);
    defer gpa.free(line);
    try std.testing.expectEqualStrings(
        "{\"event\":\"serve-started\",\"url\":\"http://127.0.0.1:53202/\",\"helper\":\"http://127.0.0.1:53202/__boris/\",\"port\":53202}\n",
        line,
    );
}

test "watch events render with stable key order" {
    const gpa = std.testing.allocator;

    const watcher = try renderWatcherStarted(gpa, "html", &.{"default"});
    defer gpa.free(watcher);
    try std.testing.expectEqualStrings("{\"event\":\"watcher-started\",\"mode\":\"html\",\"targets\":[\"default\"]}\n", watcher);

    const err_line = try renderWatchError(gpa, "poll error (BrokenPipe)", true);
    defer gpa.free(err_line);
    try std.testing.expectEqualStrings("{\"event\":\"watch-error\",\"message\":\"poll error (BrokenPipe)\",\"recoverable\":true}\n", err_line);

    const stopped = try renderWatchStopped(gpa, "signal");
    defer gpa.free(stopped);
    try std.testing.expectEqualStrings("{\"event\":\"watch-stopped\",\"reason\":\"signal\"}\n", stopped);
}
