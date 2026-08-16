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

const embed_layout =
    \\<!DOCTYPE html><html><head><title>{{title}}</title></head><body>{{content}}</body></html>
;

test "wasm compileBundle evidence matches native evidence bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const files = [_]embed.SourceFile{
        .{ .path = "index.md", .bytes = "---\ntitle: Home\nstatus: published\n---\n# Home\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
        .{ .path = "index.assets/logo.svg", .bytes = "<svg/>\n" },
    };
    var native = try embed.compileBundle(io, gpa, &files, .{ .html = true, .evidence = true });
    defer native.deinit();
    try std.testing.expect(native.ok());
    const native_artifacts = native.artifacts.get("_boris/proof/artifacts.json") orelse return error.MissingNativeArtifacts;
    const native_claims = native.artifacts.get("_boris/proof/claims.json") orelse return error.MissingNativeClaims;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.md", .data = files[0].bytes });
    try tmp.dir.createDirPath(io, "layouts");
    try tmp.dir.writeFile(io, .{ .sub_path = "layouts/main.html", .data = files[1].bytes });
    try tmp.dir.createDirPath(io, "index.assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "index.assets/logo.svg", .data = files[2].bytes });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.md", .{root});
    defer gpa.free(index_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{root});
    defer gpa.free(layout_path);
    const logo_path = try std.fmt.allocPrint(gpa, "{s}/index.assets/logo.svg", .{root});
    defer gpa.free(logo_path);

    const wasm_artifacts = try invokeArgs(gpa, build_options.wasm_small_path, &.{
        "--html",
        "--evidence",
        "--file",
        "index.md",
        index_path,
        "--file",
        "layouts/main.html",
        layout_path,
        "--file",
        "index.assets/logo.svg",
        logo_path,
        "--print",
        "_boris/proof/artifacts.json",
    });
    defer gpa.free(wasm_artifacts);
    try std.testing.expectEqualStrings(native_artifacts, wasm_artifacts);

    const wasm_claims = try invokeArgs(gpa, build_options.wasm_small_path, &.{
        "--html",
        "--evidence",
        "--file",
        "index.md",
        index_path,
        "--file",
        "layouts/main.html",
        layout_path,
        "--file",
        "index.assets/logo.svg",
        logo_path,
        "--print",
        "_boris/proof/claims.json",
    });
    defer gpa.free(wasm_claims);
    try std.testing.expectEqualStrings(native_claims, wasm_claims);
}

test "wasm compileBundle poisoned parent matches native diagnostics and emits no claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const files = [_]embed.SourceFile{
        .{ .path = "orphan.md", .bytes = "---\ntitle: Orphan\nparent: missing\n---\n# Orphan\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    var native = try embed.compileBundle(io, gpa, &files, .{ .html = true, .evidence = true });
    defer native.deinit();
    try std.testing.expect(!native.ok());
    try std.testing.expect(native.artifacts.get("_boris/proof/claims.json") == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "orphan.md", .data = files[0].bytes });
    try tmp.dir.createDirPath(io, "layouts");
    try tmp.dir.writeFile(io, .{ .sub_path = "layouts/main.html", .data = files[1].bytes });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const orphan_path = try std.fmt.allocPrint(gpa, "{s}/orphan.md", .{root});
    defer gpa.free(orphan_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{root});
    defer gpa.free(layout_path);

    const wasm_manifest = try invokeArgs(gpa, build_options.wasm_small_path, &.{
        "--html",
        "--evidence",
        "--file",
        "orphan.md",
        orphan_path,
        "--file",
        "layouts/main.html",
        layout_path,
        "--manifest",
    });
    defer gpa.free(wasm_manifest);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, wasm_manifest, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool == false);
    const diags = parsed.value.object.get("diagnostics").?.array.items;
    var found = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.object.get("code").?.string, "EPARENTMISSING")) {
            found = true;
            try std.testing.expectEqualStrings("error", d.object.get("severity").?.string);
            try std.testing.expectEqualStrings("orphan.md", d.object.get("sourcePath").?.string);
            try std.testing.expect(d.object.get("line").?.integer > 0);
            try std.testing.expect(d.object.get("remediation").?.string.len > 0);
        }
    }
    try std.testing.expect(found);
    for (parsed.value.object.get("artifacts").?.array.items) |art| {
        try std.testing.expect(std.mem.indexOf(u8, art.object.get("path").?.string, "_boris/proof/") == null);
    }
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
    return invokeArgs(gpa, wasm_path, &.{markdown});
}

fn invokeArgs(gpa: std.mem.Allocator, wasm_path: []const u8, extra: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "node", "scripts/embed-wasm-invoke.mjs", wasm_path });
    try argv.appendSlice(gpa, extra);
    const result = std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
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
