//! Native gates for the compileBundle wasm ABI (#301 M5).

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const wasm_image = @import("wasm_image.zig");
const embed = @import("embed.zig");

const required_exports = [_][]const u8{
    "memory",
    "boris_version",
    "boris_version_len",
    "boris_alloc",
    "boris_free",
    "boris_compile",
    "boris_last_status",
    "boris_result_status",
    "boris_result_manifest_ptr",
    "boris_result_manifest_len",
    "boris_result_artifact_count",
    "boris_result_artifact_ptr",
    "boris_result_artifact_len",
    "boris_result_free",
};

test "ReleaseSmall embed wasm has no host imports and exports the compile ABI" {
    try expectFreestandingImage(build_options.wasm_small_path);
}

test "ReleaseSafe embed wasm has no host imports and exports the compile ABI" {
    try expectFreestandingImage(build_options.wasm_path);
}

test "embed wasm module sizes stay under a documented uncompressed bound" {
    const io = std.testing.io;
    const safe = try Io.Dir.cwd().statFile(io, build_options.wasm_path, .{});
    const small = try Io.Dir.cwd().statFile(io, build_options.wasm_small_path, .{});
    try std.testing.expect(small.size > 0);
    try std.testing.expect(safe.size > 0);
    try std.testing.expect(small.size <= safe.size);
    try std.testing.expect(small.size < 8 * 1024 * 1024);
    try std.testing.expect(safe.size < 16 * 1024 * 1024);
}

test "wasm compileBundle matches native IR bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const files = [_]embed.SourceFile{
        .{ .path = "index.md", .bytes = "---\ntitle: Home\nstatus: published\n---\n# Home\n" },
    };
    var native = try embed.compileBundle(io, gpa, &files, .{});
    defer native.deinit();
    try std.testing.expect(native.ok());
    const native_graph = native.artifacts.get("graph.json") orelse return error.MissingNativeGraph;

    const wasm_graph = try invokeCompile(gpa, build_options.wasm_small_path, files[0].bytes);
    defer gpa.free(wasm_graph);
    try std.testing.expectEqualStrings(native_graph, wasm_graph);
}

fn expectFreestandingImage(path: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(20 * 1024 * 1024));
    defer gpa.free(bytes);
    const image = try wasm_image.parse(gpa, bytes);
    defer image.deinit(gpa);
    for (image.imports) |im| {
        if (!std.mem.eql(u8, im.module, "wasi_snapshot_preview1")) {
            std.debug.print("  unexpected import {s}.{s}\n", .{ im.module, im.name });
            return error.UnexpectedWasmImports;
        }
    }
    for (required_exports) |need| {
        var found = false;
        for (image.exports) |ex| {
            if (std.mem.eql(u8, ex.name, need)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing export {s}\n", .{need});
            return error.MissingWasmExport;
        }
    }
}

fn invokeCompile(gpa: std.mem.Allocator, wasm_path: []const u8, markdown: []const u8) ![]u8 {
    const result = std.process.run(gpa, std.testing.io, .{
        .argv = &.{ "node", "scripts/embed-wasm-invoke.mjs", wasm_path, markdown },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(1 << 16),
    }) catch return error.NodeRequiredForWasmInvoke;
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("embed-wasm-invoke exited {d}: {s}\n", .{ code, result.stderr });
            gpa.free(result.stdout);
            return error.WasmInvokeFailed;
        },
        else => {
            std.debug.print("embed-wasm-invoke terminated {any}: {s}\n", .{ result.term, result.stderr });
            gpa.free(result.stdout);
            return error.WasmInvokeFailed;
        },
    }
    return result.stdout;
}
