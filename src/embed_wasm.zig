//! Freestanding Wasm ABI around `compileBundle` (#301 M5).
//!
//! Request metadata is JSON; source and artifact bytes stay in linear memory.
//! Memory adapters do not use cwd. `Io` is a single-threaded stub required by
//! the shared pipeline type.

const std = @import("std");
const embed = @import("embed.zig");
const pipeline = @import("pipeline.zig");
const diag = @import("diag.zig");

const allocator = std.heap.wasm_allocator;

/// Satisfies `std.Io.Dir` PATH_MAX/NAME_MAX lookups when this file is root.
pub const os = struct {
    pub const PATH_MAX: usize = 4096;
    pub const NAME_MAX: usize = 255;
};

const version_text = pipeline.compiler_id ++ ";ir=" ++ pipeline.schema_version ++ ";profile=embed-ir+html+evidence";

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    @trap();
}

/// Memory adapters never invoke I/O. The value is only a pipeline parameter.
fn unusedIo() std.Io {
    return undefined;
}

const FileRef = struct {
    path: []const u8,
    ptr: u32,
    len: u32,
};

const Request = struct {
    html: bool = false,
    evidence: bool = false,
    layout_path: []const u8 = "layouts/main.html",
    files: []const FileRef = &.{},
};

const OwnedArtifact = struct {
    path: []u8,
    media_type: []u8,
    bytes: []u8,
};

const Slot = struct {
    used: bool = false,
    ok: bool = false,
    manifest: []u8 = &.{},
    artifacts: []OwnedArtifact = &.{},
};

var slot: Slot = .{};
var last_abi_status: i32 = 0;

export fn boris_version() u32 {
    return @intCast(@intFromPtr(version_text.ptr));
}

export fn boris_version_len() u32 {
    return version_text.len;
}

export fn boris_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const s = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(s.ptr));
}

export fn boris_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    allocator.free(p[0..len]);
}

export fn boris_last_status() i32 {
    return last_abi_status;
}

/// Parse request JSON at `req_ptr`/`req_len` and compile. Returns handle 1
/// on a completed compile (including validation failure). Returns 0 on ABI
/// failure; `boris_last_status` then holds the negative code.
export fn boris_compile(req_ptr: u32, req_len: u32) u32 {
    last_abi_status = 0;
    freeSlot();
    if (req_ptr == 0 or req_len == 0) {
        last_abi_status = -2;
        return 0;
    }
    const req_bytes: []const u8 = @as([*]const u8, @ptrFromInt(req_ptr))[0..req_len];

    var parsed = std.json.parseFromSlice(Request, allocator, req_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        last_abi_status = -2;
        return 0;
    };
    defer parsed.deinit();

    const files = allocator.alloc(embed.SourceFile, parsed.value.files.len) catch {
        last_abi_status = -1;
        return 0;
    };
    defer allocator.free(files);
    for (parsed.value.files, files) |ref, *out| {
        if (ref.len != 0 and ref.ptr == 0) {
            last_abi_status = -3;
            return 0;
        }
        out.* = .{
            .path = ref.path,
            .bytes = if (ref.len == 0) &.{} else @as([*]const u8, @ptrFromInt(ref.ptr))[0..ref.len],
        };
    }

    var compilation = embed.compileBundle(unusedIo(), allocator, files, .{
        .html = parsed.value.html,
        .evidence = parsed.value.evidence,
        .layout_path = parsed.value.layout_path,
    }) catch |err| {
        last_abi_status = switch (err) {
            error.OutOfMemory => -1,
            else => -4,
        };
        return 0;
    };
    defer compilation.deinit();

    const arts = compilation.artifacts.items();
    const owned = allocator.alloc(OwnedArtifact, arts.len) catch {
        last_abi_status = -1;
        return 0;
    };
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            allocator.free(owned[i].path);
            allocator.free(owned[i].media_type);
            allocator.free(owned[i].bytes);
        }
        allocator.free(owned);
    }
    for (arts, 0..) |rec, i| {
        owned[i] = .{
            .path = allocator.dupe(u8, rec.path) catch {
                last_abi_status = -1;
                return 0;
            },
            .media_type = allocator.dupe(u8, rec.media_type) catch {
                last_abi_status = -1;
                return 0;
            },
            .bytes = allocator.dupe(u8, rec.bytes) catch {
                last_abi_status = -1;
                return 0;
            },
        };
        filled = i + 1;
    }

    const manifest = writeManifest(compilation.ok(), compilation.diagnostics(), owned) catch {
        last_abi_status = -1;
        return 0;
    };

    slot = .{
        .used = true,
        .ok = compilation.ok(),
        .manifest = manifest,
        .artifacts = owned,
    };
    last_abi_status = if (compilation.ok()) 0 else 1;
    return 1;
}

export fn boris_result_status(handle: u32) i32 {
    if (handle != 1 or !slot.used) return -5;
    return if (slot.ok) 0 else 1;
}

export fn boris_result_manifest_ptr(handle: u32) u32 {
    if (handle != 1 or !slot.used) return 0;
    return @intCast(@intFromPtr(slot.manifest.ptr));
}

export fn boris_result_manifest_len(handle: u32) u32 {
    if (handle != 1 or !slot.used) return 0;
    return @intCast(slot.manifest.len);
}

export fn boris_result_artifact_count(handle: u32) u32 {
    if (handle != 1 or !slot.used) return 0;
    return @intCast(slot.artifacts.len);
}

export fn boris_result_artifact_ptr(handle: u32, index: u32) u32 {
    if (handle != 1 or !slot.used) return 0;
    if (index >= slot.artifacts.len) return 0;
    return @intCast(@intFromPtr(slot.artifacts[index].bytes.ptr));
}

export fn boris_result_artifact_len(handle: u32, index: u32) u32 {
    if (handle != 1 or !slot.used) return 0;
    if (index >= slot.artifacts.len) return 0;
    return @intCast(slot.artifacts[index].bytes.len);
}

export fn boris_result_free(handle: u32) void {
    if (handle != 1) return;
    freeSlot();
}

fn freeSlot() void {
    if (!slot.used) return;
    if (slot.manifest.len > 0) allocator.free(slot.manifest);
    for (slot.artifacts) |a| {
        allocator.free(a.path);
        allocator.free(a.media_type);
        allocator.free(a.bytes);
    }
    if (slot.artifacts.len > 0) allocator.free(slot.artifacts);
    slot = .{};
}

fn writeManifest(ok: bool, diagnostics: []const diag.Diagnostic, arts: []const OwnedArtifact) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (ok) "true" else "false");
    try w.writeAll(",\"compiler_id\":\"");
    try w.writeAll(pipeline.compiler_id);
    try w.writeAll("\",\"schema_version\":\"");
    try w.writeAll(pipeline.schema_version);
    try w.writeAll("\",\"profile\":\"embed-ir+html+evidence\",\"features\":[\"markdown\",\"closed-frontmatter\",\"graph\",\"includes\",\"wiki\",\"html\",\"ir\",\"evidence\"],\"unsupported\":[\"threads\",\"watch\",\"jobs\",\"live-deploy\",\"textile\",\"cooklang\",\"untrusted-multi-tenant\",\"proof-pack\",\"wasi-filesystem\"],\"limits\":{\"isolate_memory_mib\":128,\"release_small_max_mib\":8,\"release_safe_max_mib\":16},\"diagnostics\":[");
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"severity\":\"");
        try w.writeAll(d.severity.jsonName());
        try w.writeAll("\",\"code\":\"");
        try w.writeAll(@tagName(d.code));
        try w.writeAll("\",\"message\":");
        try writeJsonString(w, d.message);
        try w.writeAll(",\"remediation\":");
        try writeJsonString(w, d.remediation);
        try w.writeAll(",\"sourcePath\":");
        if (d.source_path.len == 0) try w.writeAll("null") else try writeJsonString(w, d.source_path);
        try w.writeAll(",\"line\":");
        if (d.line) |line| try w.print("{d}", .{line}) else try w.writeAll("null");
        try w.writeAll(",\"column\":");
        if (d.column) |col| try w.print("{d}", .{col}) else try w.writeAll("null");
        try w.writeAll(",\"id\":");
        if (d.id.len == 0) try w.writeAll("null") else try writeJsonString(w, d.id);
        try w.writeAll("}");
    }
    try w.writeAll("],\"artifacts\":[");
    for (arts, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"path\":");
        try writeJsonString(w, a.path);
        try w.writeAll(",\"media_type\":");
        try writeJsonString(w, a.media_type);
        try w.print(",\"index\":{d}}}", .{i});
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            // RFC 8259 forbids raw C0 controls inside a JSON string. Hosts
            // supply file names over the ABI, so arbitrary bytes can reach
            // this writer even though content sources reject them earlier.
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
