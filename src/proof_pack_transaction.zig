const std = @import("std");
const Io = std.Io;
const artifact_inventory = @import("artifact_inventory.zig");

pub const Error = std.mem.Allocator.Error || error{
    JsonTmpWriteFailed,
    HtmlTmpWriteFailed,
    PreservePriorFailed,
    PreserveHtmlFailed,
    PreserveJsonFailed,
    PreserveAfterFailed,
    InstallHtmlFailed,
    InstallJsonFailed,
    RestoreHtmlFailed,
    RestoreJsonFailed,
    RemoveHtmlFailed,
    RemoveJsonFailed,
};

pub const Options = struct {
    test_fail_json_tmp_write: bool = false,
    test_fail_html_tmp_write: bool = false,
    test_fail_preserve_prior: bool = false,
    test_fail_preserve_json: bool = false,
    test_fail_preserve_after: bool = false,
    test_fail_install_html: bool = false,
    test_fail_install_json: bool = false,
    test_fail_restore_html: bool = false,
    test_fail_restore_json: bool = false,
    test_fail_remove_html: bool = false,
    test_fail_remove_json: bool = false,
};

pub const PairState = struct {
    json_original_existed: bool,
    html_original_existed: bool,
    json_preserved: bool,
    html_preserved: bool,
    html_installed: bool,
    json_installed: bool,
};

pub fn pathExists(io: Io, root: Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

pub fn writeTmpFile(
    io: Io,
    root: Io.Dir,
    path: []const u8,
    bytes: []const u8,
    fail_error: Error,
) Error!void {
    var atomic = root.createFileAtomic(io, path, .{ .replace = true, .make_path = true }) catch {
        return fail_error;
    };
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return fail_error;
    writer.interface.flush() catch return fail_error;
    atomic.replace(io) catch return fail_error;
}

pub fn verifyTmpBytes(
    io: Io,
    root: Io.Dir,
    path: []const u8,
    expected: []const u8,
    fail_error: Error,
) Error!void {
    var file = root.openFile(io, path, .{}) catch return fail_error;
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    var index: usize = 0;
    var chunk: [64 * 1024]u8 = undefined;
    while (index < expected.len) {
        const remaining = expected.len - index;
        const want = chunk[0..@min(chunk.len, remaining)];
        const n = reader.interface.readSliceShort(want) catch return fail_error;
        if (n == 0) return fail_error;
        if (!std.mem.eql(u8, chunk[0..n], expected[index .. index + n])) return fail_error;
        index += n;
    }
    var probe: [1]u8 = undefined;
    const extra = reader.interface.readSliceShort(&probe) catch return fail_error;
    if (extra != 0) return fail_error;
}

pub fn installPair(
    io: Io,
    root: Io.Dir,
    json_bytes: []const u8,
    html_bytes: []const u8,
    options: Options,
) Error!void {
    try writeTmpFile(io, root, artifact_inventory.proof_pack_tmp_path, json_bytes, error.JsonTmpWriteFailed);
    if (options.test_fail_json_tmp_write) return error.JsonTmpWriteFailed;
    try verifyTmpBytes(io, root, artifact_inventory.proof_pack_tmp_path, json_bytes, error.JsonTmpWriteFailed);
    try writeTmpFile(io, root, artifact_inventory.proof_index_tmp_path, html_bytes, error.HtmlTmpWriteFailed);
    if (options.test_fail_html_tmp_write) return error.HtmlTmpWriteFailed;
    try verifyTmpBytes(io, root, artifact_inventory.proof_index_tmp_path, html_bytes, error.HtmlTmpWriteFailed);
    var state = PairState{
        .json_original_existed = pathExists(io, root, artifact_inventory.proof_pack_output_path),
        .html_original_existed = pathExists(io, root, artifact_inventory.proof_index_output_path),
        .json_preserved = false,
        .html_preserved = false,
        .html_installed = false,
        .json_installed = false,
    };
    if (options.test_fail_preserve_prior) return error.PreservePriorFailed;
    if (state.html_original_existed) {
        root.rename(artifact_inventory.proof_index_output_path, root, artifact_inventory.proof_index_prev_path, io) catch return error.PreserveHtmlFailed;
        state.html_preserved = true;
    }
    if (options.test_fail_preserve_json) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.PreserveJsonFailed;
    }
    if (state.json_original_existed) {
        root.rename(artifact_inventory.proof_pack_output_path, root, artifact_inventory.proof_pack_prev_path, io) catch {
            rollbackPair(io, root, &state, options) catch |err| return err;
            return error.PreserveJsonFailed;
        };
        state.json_preserved = true;
    }
    if (options.test_fail_preserve_after) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.PreserveAfterFailed;
    }
    root.rename(artifact_inventory.proof_index_tmp_path, root, artifact_inventory.proof_index_output_path, io) catch {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallHtmlFailed;
    };
    state.html_installed = true;
    if (options.test_fail_install_html) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallHtmlFailed;
    }
    root.rename(artifact_inventory.proof_pack_tmp_path, root, artifact_inventory.proof_pack_output_path, io) catch {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallJsonFailed;
    };
    state.json_installed = true;
    if (options.test_fail_install_json) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallJsonFailed;
    }
    root.deleteFile(io, artifact_inventory.proof_index_prev_path) catch {};
    root.deleteFile(io, artifact_inventory.proof_pack_prev_path) catch {};
}

pub fn rollbackPair(
    io: Io,
    root: Io.Dir,
    state: *const PairState,
    options: Options,
) Error!void {
    if (state.html_preserved) {
        if (options.test_fail_restore_html) return error.RestoreHtmlFailed;
        root.rename(artifact_inventory.proof_index_prev_path, root, artifact_inventory.proof_index_output_path, io) catch return error.RestoreHtmlFailed;
    } else if (state.html_installed) {
        if (options.test_fail_remove_html) return error.RemoveHtmlFailed;
        root.deleteFile(io, artifact_inventory.proof_index_output_path) catch return error.RemoveHtmlFailed;
    }
    if (state.json_preserved) {
        if (options.test_fail_restore_json) return error.RestoreJsonFailed;
        root.rename(artifact_inventory.proof_pack_prev_path, root, artifact_inventory.proof_pack_output_path, io) catch return error.RestoreJsonFailed;
    } else if (state.json_installed) {
        if (options.test_fail_remove_json) return error.RemoveJsonFailed;
        root.deleteFile(io, artifact_inventory.proof_pack_output_path) catch return error.RemoveJsonFailed;
    }
}
