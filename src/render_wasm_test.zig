//! Native gates for the Oliver wasm32-freestanding render spike (#301 M0).

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const render = @import("render.zig");
const wasm_image = @import("wasm_image.zig");

const golden_md = "# Alpha\n";
const golden_html = "<h1 id=\"alpha\">Alpha</h1>\n";

const required_exports = [_][]const u8{
    "memory",
    "boris_alloc",
    "boris_free",
    "boris_render",
    "boris_result_ptr",
    "boris_result_len",
    "boris_result_free",
};

test "wasm image parser rejects non-wasm" {
    try std.testing.expectError(error.NotWasm, wasm_image.parse(std.testing.allocator, "not wasm"));
}

test "native golden still matches the compile pin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try render.render(golden_md, &arena);
    try std.testing.expectEqualStrings(golden_html, html.bytes);
}

test "ReleaseSafe wasm has no host imports and exports the render ABI" {
    try expectFreestandingImage(build_options.wasm_path);
}

test "ReleaseSmall wasm has no host imports and exports the render ABI" {
    try expectFreestandingImage(build_options.wasm_small_path);
}

test "wasm module sizes stay under the Worker uncompressed budget" {
    const io = std.testing.io;
    const safe = try Io.Dir.cwd().statFile(io, build_options.wasm_path, .{});
    const small = try Io.Dir.cwd().statFile(io, build_options.wasm_small_path, .{});
    // Workers allow 64 MiB uncompressed; the paid gzip budget is 10 MiB.
    // The spike must stay far below both so a later product module has room.
    try std.testing.expect(safe.size > 0);
    try std.testing.expect(small.size > 0);
    try std.testing.expect(small.size <= safe.size);
    try std.testing.expect(small.size < 2 * 1024 * 1024);
    try std.testing.expect(safe.size < 4 * 1024 * 1024);
}

test "wasm ReleaseSafe render matches native Oliver bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const native = try render.render(golden_md, &arena);
    const wasm_html = try invokeWasm(std.testing.allocator, build_options.wasm_path, golden_md);
    defer std.testing.allocator.free(wasm_html);
    try std.testing.expectEqualStrings(native.bytes, wasm_html);
    try std.testing.expectEqualStrings(golden_html, wasm_html);
}

test "wasm ReleaseSmall render matches native Oliver bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const native = try render.render(golden_md, &arena);
    const wasm_html = try invokeWasm(std.testing.allocator, build_options.wasm_small_path, golden_md);
    defer std.testing.allocator.free(wasm_html);
    try std.testing.expectEqualStrings(native.bytes, wasm_html);
}

fn expectFreestandingImage(path: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
    defer gpa.free(bytes);
    const image = try wasm_image.parse(gpa, bytes);
    defer image.deinit(gpa);

    if (image.imports.len != 0) {
        std.debug.print("freestanding render wasm imported host symbols:\n", .{});
        for (image.imports) |im| {
            std.debug.print("  {s}.{s} kind={d}\n", .{ im.module, im.name, im.kind });
        }
        return error.UnexpectedWasmImports;
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
            std.debug.print("missing wasm export {s}\n", .{need});
            return error.MissingWasmExport;
        }
    }
}

fn invokeWasm(gpa: std.mem.Allocator, wasm_path: []const u8, markdown: []const u8) ![]u8 {
    const io = std.testing.io;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "node", "scripts/render-wasm-invoke.mjs", wasm_path, markdown },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
    }) catch |err| {
        std.debug.print("failed to spawn node for wasm invoke: {s}\n", .{@errorName(err)});
        return error.NodeRequiredForWasmInvoke;
    };
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("render-wasm-invoke exited {d}: {s}\n", .{ code, result.stderr });
            gpa.free(result.stdout);
            return error.WasmInvokeFailed;
        },
        else => {
            std.debug.print("render-wasm-invoke terminated {any}: {s}\n", .{ result.term, result.stderr });
            gpa.free(result.stdout);
            return error.WasmInvokeFailed;
        },
    }
    return result.stdout;
}
