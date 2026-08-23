//! Incremental publication-evidence reuse state (#728).
//!
//! When an incremental build commits a target whose committed artifact set is
//! byte-identical to the set the evidence chain last derived from, the four
//! deterministic evidence reports already on disk are exactly what a fresh
//! derivation would produce. This module records and re-verifies that fact:
//!
//! - `artifacts_sha256` pins the exact committed inventory the reports describe;
//! - each report's recorded digest must still match the file on disk.
//!
//! Any mismatch, missing file, unknown format, or unusable target name falls
//! back to full derivation — reuse is an optimization, never an authority.

const std = @import("std");
const artifact_inventory = @import("artifact_inventory.zig");
const cache = @import("cache.zig");

const Io = std.Io;

pub const state_format = "boris-evidence-state-v1";
pub const state_dir_sub_path = ".boris-cache/evidence-state";
/// Evidence files are metadata-scale reports, not page payloads; refuse to
/// buffer anything larger so a hostile tree cannot balloon memory here.
const max_state_bytes: usize = 64 * 1024 * 1024;

/// The five derived evidence reports, in derivation order.
pub const report_paths = [_][]const u8{
    artifact_inventory.checks_output_path,
    artifact_inventory.claims_output_path,
    artifact_inventory.touches_output_path,
    artifact_inventory.proof_pack_output_path,
    artifact_inventory.proof_index_output_path,
};

pub const artifacts_path = artifact_inventory.output_path;

fn stateSubPath(gpa: std.mem.Allocator, target_name: []const u8) ?[]u8 {
    // Per-target state files; refuse names that could escape the directory.
    if (target_name.len == 0) return null;
    for (target_name) |c| {
        if (c == '/' or c == '\\' or c == 0) return null;
    }
    if (std.mem.eql(u8, target_name, ".") or std.mem.eql(u8, target_name, "..")) return null;
    return std.fmt.allocPrint(gpa, state_dir_sub_path ++ "/{s}.json", .{target_name}) catch null;
}

fn sha256HexOfFile(io: Io, root: Io.Dir, gpa: std.mem.Allocator, sub_path: []const u8) ?[64]u8 {
    const bytes = readFileBounded(io, root, sub_path, gpa) orelse return null;
    defer gpa.free(bytes);
    return cache.hexDigest(cache.hashBytes(bytes));
}

fn readFileBounded(io: Io, root: Io.Dir, sub_path: []const u8, gpa: std.mem.Allocator) ?[]u8 {
    const file = root.openFile(io, sub_path, .{}) catch return null;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(max_state_bytes)) catch return null;
}

const ParsedState = struct {
    artifacts_hex: [64]u8,
    report_hex: [report_paths.len][64]u8,
};

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Parse the recorded state for `target_name`; null when anything is off
/// (missing, corrupt, wrong format/target/report list).
fn loadState(io: Io, dist_dir: Io.Dir, gpa: std.mem.Allocator, target_name: []const u8) ?ParsedState {
    const sub = stateSubPath(gpa, target_name) orelse return null;
    defer gpa.free(sub);
    const bytes = readFileBounded(io, dist_dir, sub, gpa) orelse return null;
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = 4096,
    }) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const format = jsonStr(obj, "format") orelse return null;
    if (!std.mem.eql(u8, format, state_format)) return null;
    const target = jsonStr(obj, "target") orelse return null;
    if (!std.mem.eql(u8, target, target_name)) return null;

    var out: ParsedState = undefined;
    const artifacts = jsonStr(obj, "artifacts_sha256") orelse return null;
    if (artifacts.len != 64) return null;
    out.artifacts_hex = artifacts[0..64].*;

    const reports = switch (obj.get("reports") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };
    if (reports.len != report_paths.len) return null;
    for (reports, 0..) |item, i| {
        const ro = switch (item) {
            .object => |o| o,
            else => return null,
        };
        const path = jsonStr(ro, "path") orelse return null;
        if (!std.mem.eql(u8, path, report_paths[i])) return null;
        const hex = jsonStr(ro, "sha256") orelse return null;
        if (hex.len != 64) return null;
        out.report_hex[i] = hex[0..64].*;
    }
    return out;
}

/// Decide whether the committed evidence on disk may be reused unchanged:
/// recorded state parses, the current artifacts.json digest matches the one
/// the reports were derived from, and every report file still hashes to its
/// recorded digest. Transient allocations come from `gpa`.
pub fn reuseValid(
    io: Io,
    dist_dir: Io.Dir,
    gpa: std.mem.Allocator,
    target_name: []const u8,
) bool {
    const state = loadState(io, dist_dir, gpa, target_name) orelse return false;

    const current_artifacts = sha256HexOfFile(io, dist_dir, gpa, artifacts_path) orelse return false;
    if (!std.mem.eql(u8, &current_artifacts, &state.artifacts_hex)) return false;

    for (report_paths, 0..) |path, i| {
        const hex = sha256HexOfFile(io, dist_dir, gpa, path) orelse return false;
        if (!std.mem.eql(u8, &hex, &state.report_hex[i])) return false;
    }
    return true;
}

/// Record fresh state after a successful full derivation under an incremental
/// build. Best-effort: any failure leaves no usable state file, so the next
/// build simply re-derives.
pub fn record(
    io: Io,
    dist_dir: Io.Dir,
    gpa: std.mem.Allocator,
    target_name: []const u8,
) void {
    const sub = stateSubPath(gpa, target_name) orelse return;
    defer gpa.free(sub);

    const artifacts_hex = sha256HexOfFile(io, dist_dir, gpa, artifacts_path) orelse return;
    var report_hex: [report_paths.len][64]u8 = undefined;
    for (report_paths, 0..) |path, i| {
        report_hex[i] = sha256HexOfFile(io, dist_dir, gpa, path) orelse return;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"format\":") catch return;
    appendJsonString(gpa, &buf, state_format) catch return;
    buf.appendSlice(gpa, ",\"target\":") catch return;
    appendJsonString(gpa, &buf, target_name) catch return;
    buf.appendSlice(gpa, ",\"artifacts_sha256\":") catch return;
    appendJsonString(gpa, &buf, &artifacts_hex) catch return;
    buf.appendSlice(gpa, ",\"reports\":[") catch return;
    for (report_paths, 0..) |path, i| {
        if (i > 0) buf.appendSlice(gpa, ",") catch return;
        buf.appendSlice(gpa, "{\"path\":") catch return;
        appendJsonString(gpa, &buf, path) catch return;
        buf.appendSlice(gpa, ",\"sha256\":") catch return;
        appendJsonString(gpa, &buf, &report_hex[i]) catch return;
        buf.appendSlice(gpa, "}") catch return;
    }
    buf.appendSlice(gpa, "]}\n") catch return;

    var atomic = dist_dir.createFileAtomic(io, sub, .{
        .replace = true,
        .make_path = true,
    }) catch return;
    defer atomic.deinit(io);
    var w_buf: [2048]u8 = undefined;
    var file_writer = atomic.file.writer(io, &w_buf);
    file_writer.interface.writeAll(buf.items) catch return;
    file_writer.flush() catch return;
    atomic.replace(io) catch {};
}

fn appendJsonString(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    var esc: [6]u8 = undefined;
                    const text = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(gpa, text);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

test "state sub-path rejects traversal and unusable targets" {
    const gpa = std.testing.allocator;
    const ok = stateSubPath(gpa, "default");
    try std.testing.expect(ok != null);
    if (ok) |p| gpa.free(p);
    try std.testing.expect(stateSubPath(gpa, "") == null);
    try std.testing.expect(stateSubPath(gpa, ".") == null);
    try std.testing.expect(stateSubPath(gpa, "..") == null);
    try std.testing.expect(stateSubPath(gpa, "a/b") == null);
    try std.testing.expect(stateSubPath(gpa, "a\\b") == null);
}
