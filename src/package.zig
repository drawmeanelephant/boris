//! Review package: stage IR (+ optional RAG) into a deterministic tar.
//!
//! Produces a single archive under `packages/` (default) containing:
//!   MACHINE-READABLE-VERSION.json
//!   SHA256SUMS
//!   ir/{manifest,graph,build-report}.json
//!   rag/**  (when include_rag)
//!
//! Does **not** change compiler semantics, schemaVersion, or the HTML path.
//! Reuses `pipeline.run` and `rag.run`. No new dependencies.
//!
//! Determinism: fixed archive basename, mtime=0 tar headers, sorted file
//! order, no host timestamps in paths. On failure: no final archive when none
//! existed; a prior archive is preserved (move-aside install, not
//! delete-before-write). Stage cleaned up on both success and content failure.

const std = @import("std");
const Io = std.Io;
const pipeline = @import("pipeline.zig");
const rag = @import("rag.zig");
const json_out = @import("json_out.zig");

/// Machine format id written into MACHINE-READABLE-VERSION.json.
pub const package_format = "boris-package";

/// Integer schema version for the package machine interface.
pub const package_schema_version: u32 = 1;

/// Default packages output directory (relative to process cwd).
pub const default_packages_dir = "packages";

/// Fixed archive basename (no timestamps).
pub const default_archive_name = "boris-package.tar";

/// Tar root prefix for every entry (stable when extracted).
pub const archive_root = "boris-package";

pub const version_filename = "MACHINE-READABLE-VERSION.json";
pub const checksums_filename = "SHA256SUMS";

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Options = struct {
    /// Content root for IR / optional RAG (same as product `--input`).
    content_root: []const u8 = "docs/contracts/fixtures/valid/content",
    /// Directory that receives the final archive.
    packages_dir: []const u8 = default_packages_dir,
    /// Archive basename only (no directories). Fixed default for determinism.
    archive_name: []const u8 = default_archive_name,
    /// When true, also run product RAG export into `rag/` inside the package.
    include_rag: bool = true,
    /// System seeds for RAG (same default as product RAG).
    system_docs_dir: []const u8 = "docs/rag/system",
    quiet: bool = false,
    /// Test-only: after the temp archive is fully written and closed, fail
    /// before installing it under the final name. Proves a prior archive
    /// survives a failed publish (no delete-before-install).
    test_fail_before_archive_install: bool = false,
};

pub const FailureKind = pipeline.FailureKind;

pub const Result = struct {
    ok: bool,
    failure: FailureKind = .none,
    /// Relative path of the final archive when `ok` (borrowed from stage arena).
    archive_path: []const u8 = "",
    /// Page count from the successful IR compile.
    page_count: usize = 0,
    include_rag: bool = false,
};

fn log(opts: Options, comptime fmt: []const u8, args: anytype) void {
    if (!opts.quiet) std.debug.print(fmt, args);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn normalizeRelPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len and (raw[i] == '/' or raw[i] == '\\')) : (i += 1) {}
    var need_slash = false;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '/' or c == '\\') {
            need_slash = true;
            i += 1;
            while (i < raw.len and (raw[i] == '/' or raw[i] == '\\')) : (i += 1) {}
            continue;
        }
        if (need_slash) {
            try out.append(allocator, '/');
            need_slash = false;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Compact MACHINE-READABLE-VERSION.json (fixed key order, trailing LF).
pub fn renderVersionJson(gpa: std.mem.Allocator, include_rag: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"format\": ");
    try json_out.writeString(&buf, gpa, package_format);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"package_schema_version\": ");
    try json_out.writeUsize(&buf, gpa, package_schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"product_version\": ");
    try json_out.writeString(&buf, gpa, pipeline.boris_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"compiler_id\": ");
    try json_out.writeString(&buf, gpa, pipeline.compiler_id);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"ir_schema_version\": ");
    try json_out.writeString(&buf, gpa, pipeline.schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"rag_format\": ");
    try json_out.writeString(&buf, gpa, rag.catalog_format);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"rag_schema_version\": ");
    try json_out.writeUsize(&buf, gpa, rag.catalog_schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"include_rag\": ");
    try json_out.writeBool(&buf, gpa, include_rag);
    try buf.appendSlice(gpa, "\n}\n");

    return try buf.toOwnedSlice(gpa);
}

fn collectFilePaths(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }

    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try normalizeRelPath(gpa, entry.path);
        try list.append(gpa, rel);
    }

    std.mem.sort([]const u8, list.items, {}, pathLess);
    return try list.toOwnedSlice(gpa);
}

fn renderSha256Sums(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    paths: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    for (paths) |rel| {
        // SHA256SUMS must not list itself (written after hashing payload files).
        if (std.mem.eql(u8, rel, checksums_filename)) continue;
        const data = try readFileAlloc(io, root, rel, gpa);
        defer gpa.free(data);
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try buf.appendSlice(gpa, &hex);
        try buf.appendSlice(gpa, "  ");
        try buf.appendSlice(gpa, rel);
        try buf.append(gpa, '\n');
    }
    return try buf.toOwnedSlice(gpa);
}

/// Write a complete temp archive, then install it under `archive_name`.
///
/// **Never deletes the live archive before the replacement is ready.** Order:
/// 1. Write `.{archive}.tmp` fully and close it (prior `archive_name` untouched).
/// 2. If a prior archive exists, move it aside to `.{archive}.prev`.
/// 3. Rename the temp into `archive_name`; on failure restore `.prev` when present.
/// 4. Drop `.prev` only after a successful install.
///
/// Same-directory rename replaces the final name without a torn partial file.
/// Cross-device **atomic** replace is not claimed (stage temp and final share
/// one `packages_dir` handle / parent). Concurrent readers may briefly observe
/// the previous archive under the `.prev` name during the swap window.
fn writeTarFromStage(
    io: Io,
    gpa: std.mem.Allocator,
    stage: Io.Dir,
    paths: []const []const u8,
    out_dir: Io.Dir,
    archive_name: []const u8,
    test_fail_before_install: bool,
) !void {
    const tmp_name = try std.fmt.allocPrint(gpa, ".{s}.tmp", .{archive_name});
    defer gpa.free(tmp_name);
    const prev_name = try std.fmt.allocPrint(gpa, ".{s}.prev", .{archive_name});
    defer gpa.free(prev_name);

    // Drop leftovers from an interrupted prior install only — not the live archive.
    out_dir.deleteFile(io, tmp_name) catch {};
    out_dir.deleteFile(io, prev_name) catch {};

    {
        var tar_file = try out_dir.createFile(io, tmp_name, .{});
        errdefer {
            tar_file.close(io);
            out_dir.deleteFile(io, tmp_name) catch {};
        }

        var write_buf: [64 * 1024]u8 = undefined;
        var file_writer = tar_file.writer(io, &write_buf);
        const w = &file_writer.interface;

        var tar_w: std.tar.Writer = .{ .underlying_writer = w };
        try tar_w.setRoot(archive_root);

        // Fixed mode/mtime for reproducibility (mtime=0; mode 0o644).
        const file_opts: std.tar.Writer.Options = .{ .mode = 0o644, .mtime = 0 };

        for (paths) |rel| {
            const data = try readFileAlloc(io, stage, rel, gpa);
            defer gpa.free(data);
            try tar_w.writeFileBytes(rel, data, file_opts);
        }
        // Two zero blocks — optional per std docs; keep for common tar tools.
        try tar_w.finishPedantically();
        try w.flush();
        tar_file.close(io);
    }

    // Failure after a complete temp write must still leave any prior archive.
    if (test_fail_before_install) {
        out_dir.deleteFile(io, tmp_name) catch {};
        return error.TestInjectedArchiveInstallFailure;
    }

    // Move existing archive aside only after the replacement temp is complete.
    const had_prev = blk: {
        out_dir.rename(archive_name, out_dir, prev_name, io) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => {
                // Destination may already be free under another name, or the
                // platform may refuse rename-over-self; try direct install and
                // surface the original error if that also fails.
                out_dir.rename(tmp_name, out_dir, archive_name, io) catch {
                    out_dir.deleteFile(io, tmp_name) catch {};
                    return err;
                };
                break :blk false;
            },
        };
        break :blk true;
    };

    out_dir.rename(tmp_name, out_dir, archive_name, io) catch |err| {
        if (had_prev) {
            // Put the previous archive back under the public name.
            out_dir.rename(prev_name, out_dir, archive_name, io) catch {};
        }
        out_dir.deleteFile(io, tmp_name) catch {};
        return err;
    };

    if (had_prev) out_dir.deleteFile(io, prev_name) catch {};
}

/// Build a review package from a known content root.
///
/// On content validation failure: does not write a final archive; cleans stage.
/// On I/O error: cleans stage and any temp archive; returns error.
pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !Result {
    const cwd = Io.Dir.cwd();

    // Stage lives under packages_dir so a crash leaves only gitignored noise.
    const stage_rel = try std.fmt.allocPrint(gpa, "{s}/.boris-package-stage", .{opts.packages_dir});
    defer gpa.free(stage_rel);

    const archive_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.packages_dir, opts.archive_name });
    defer gpa.free(archive_rel);

    cwd.deleteTree(io, stage_rel) catch {};
    // Do not leave a half-written final archive from a prior failed rename.
    if (std.fs.path.dirname(archive_rel)) |parent| {
        if (parent.len > 0) try cwd.createDirPath(io, parent);
    } else {
        try cwd.createDirPath(io, opts.packages_dir);
    }

    errdefer cwd.deleteTree(io, stage_rel) catch {};

    try cwd.createDirPath(io, stage_rel);
    const ir_rel = try std.fmt.allocPrint(gpa, "{s}/ir", .{stage_rel});
    defer gpa.free(ir_rel);
    try cwd.createDirPath(io, ir_rel);

    log(opts, "boris-package: IR → {s}\n", .{ir_rel});
    var ir_result = try pipeline.run(io, gpa, .{
        .content_root = opts.content_root,
        .out_dir = ir_rel,
        .quiet = opts.quiet,
    });
    defer ir_result.deinit();

    if (!ir_result.ok) {
        cwd.deleteTree(io, stage_rel) catch {};
        return .{
            .ok = false,
            .failure = ir_result.failure,
            .page_count = ir_result.pages.items.len,
            .include_rag = opts.include_rag,
        };
    }

    if (opts.include_rag) {
        const rag_rel = try std.fmt.allocPrint(gpa, "{s}/rag", .{stage_rel});
        defer gpa.free(rag_rel);
        log(opts, "boris-package: RAG → {s}\n", .{rag_rel});
        var rag_result = try rag.run(io, gpa, .{
            .content_root = opts.content_root,
            .out_dir = rag_rel,
            .system_docs_dir = opts.system_docs_dir,
            .quiet = opts.quiet,
        });
        defer rag_result.deinit();
        if (!rag_result.ok()) {
            cwd.deleteTree(io, stage_rel) catch {};
            return .{
                .ok = false,
                .failure = rag_result.compile.failure,
                .page_count = ir_result.pages.items.len,
                .include_rag = true,
            };
        }
    }

    // Version sidecar (before checksums so it is hashed).
    {
        const version_json = try renderVersionJson(gpa, opts.include_rag);
        defer gpa.free(version_json);
        var stage = try cwd.openDir(io, stage_rel, .{});
        defer stage.close(io);
        try stage.writeFile(io, .{ .sub_path = version_filename, .data = version_json });
    }

    var stage = try cwd.openDir(io, stage_rel, .{ .iterate = true });
    defer stage.close(io);

    const payload_paths = try collectFilePaths(io, gpa, stage);
    defer {
        for (payload_paths) |p| gpa.free(p);
        gpa.free(payload_paths);
    }

    {
        const sums = try renderSha256Sums(io, gpa, stage, payload_paths);
        defer gpa.free(sums);
        try stage.writeFile(io, .{ .sub_path = checksums_filename, .data = sums });
    }

    // Re-collect so SHA256SUMS is included in the tar (sorted).
    const all_paths = try collectFilePaths(io, gpa, stage);
    defer {
        for (all_paths) |p| gpa.free(p);
        gpa.free(all_paths);
    }

    var packages = try cwd.openDir(io, opts.packages_dir, .{});
    defer packages.close(io);

    log(opts, "boris-package: tar → {s}\n", .{archive_rel});
    try writeTarFromStage(
        io,
        gpa,
        stage,
        all_paths,
        packages,
        opts.archive_name,
        opts.test_fail_before_archive_install,
    );

    // Success: drop stage; keep only the archive.
    cwd.deleteTree(io, stage_rel) catch {};

    // archive_path needs to outlive this function for the Result — dupe into a
    // static-ish buffer owned by caller isn't available; return a stack copy
    // via gpa-owned string the caller must free… Keep it simple: store the
    // relative path on the Result as a dupe the caller frees via freeArchivePath.
    const path_owned = try gpa.dupe(u8, archive_rel);

    return .{
        .ok = true,
        .failure = .none,
        .archive_path = path_owned,
        .page_count = ir_result.pages.items.len,
        .include_rag = opts.include_rag,
    };
}

/// Free `Result.archive_path` when non-empty (call after inspecting).
pub fn freeResult(gpa: std.mem.Allocator, result: *Result) void {
    if (result.archive_path.len > 0) {
        gpa.free(result.archive_path);
        result.archive_path = "";
    }
}

// ---------------------------------------------------------------------------
// CLI (boris-package)
// ---------------------------------------------------------------------------

pub const ExitCode = enum(u8) {
    success = 0,
    content_error = 1,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
    DuplicateFlag,
};

fn printUsage() void {
    std.debug.print(
        \\boris-package — deterministic IR (+ optional RAG) review archive
        \\
        \\Usage:
        \\  boris-package [options]
        \\
        \\Options:
        \\  --input <DIR>         Content root (default: docs/contracts/fixtures/valid/content)
        \\  --packages-dir <DIR>  Output directory for the archive (default: packages)
        \\  --archive <NAME>      Archive basename only (default: boris-package.tar)
        \\  --with-rag            Include product RAG export (default)
        \\  --no-rag              IR artifacts only
        \\  --quiet               Suppress progress logging
        \\  -h, --help            Show this help
        \\
        \\Produces packages/<archive> containing ir/, optional rag/, 
        \\MACHINE-READABLE-VERSION.json, and SHA256SUMS. HTML is never included.
        \\
    , .{});
}

fn takeValueSimple(args: []const []const u8, i: *usize, flag: []const u8) ParseError![]const u8 {
    const a = args[i.*];
    if (std.mem.startsWith(u8, a, flag) and a.len > flag.len and a[flag.len] == '=') {
        const v = a[flag.len + 1 ..];
        if (v.len == 0) return error.MissingValue;
        return v;
    }
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    if (args[i.*].len == 0) return error.MissingValue;
    return args[i.*];
}

fn parseCli(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var saw_input = false;
    var saw_packages = false;
    var saw_archive = false;
    var saw_rag = false;

    // Skip argv[0]
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--quiet")) {
            opts.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--with-rag")) {
            if (saw_rag) return error.DuplicateFlag;
            opts.include_rag = true;
            saw_rag = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-rag")) {
            if (saw_rag) return error.DuplicateFlag;
            opts.include_rag = false;
            saw_rag = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--input") or std.mem.startsWith(u8, a, "--input=")) {
            if (saw_input) return error.DuplicateFlag;
            const v = try takeValueSimple(args, &i, "--input");
            if (v.len == 0) return error.MissingValue;
            opts.content_root = v;
            saw_input = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--packages-dir") or std.mem.startsWith(u8, a, "--packages-dir=")) {
            if (saw_packages) return error.DuplicateFlag;
            const v = try takeValueSimple(args, &i, "--packages-dir");
            if (v.len == 0) return error.MissingValue;
            opts.packages_dir = v;
            saw_packages = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--archive") or std.mem.startsWith(u8, a, "--archive=")) {
            if (saw_archive) return error.DuplicateFlag;
            const v = try takeValueSimple(args, &i, "--archive");
            if (v.len == 0) return error.MissingValue;
            if (std.mem.indexOfScalar(u8, v, '/') != null or std.mem.indexOfScalar(u8, v, '\\') != null) {
                return error.InvalidValue;
            }
            opts.archive_name = v;
            saw_archive = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) return error.UnknownFlag;
        return error.UnknownFlag;
    }
    return opts;
}

const CliParse = union(enum) {
    help,
    opts: Options,
    err: ParseError,
};

fn parseArgs(args: []const []const u8) CliParse {
    // Help short-circuit
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return .help;
    }
    const opts = parseCli(args) catch |e| return .{ .err = e };
    return .{ .opts = opts };
}

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("error: failed to read process arguments\n", .{});
        return ExitCode.io_error.int();
    };
    var args_list: std.ArrayList([]const u8) = .empty;
    args_list.ensureTotalCapacity(cold, args_z.len) catch {
        return ExitCode.io_error.int();
    };
    for (args_z) |a| args_list.appendAssumeCapacity(a);

    switch (parseArgs(args_list.items)) {
        .help => {
            printUsage();
            return ExitCode.success.int();
        },
        .err => |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            printUsage();
            return ExitCode.usage.int();
        },
        .opts => |opts| {
            var result = run(init.io, init.gpa, opts) catch |err| {
                std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
            defer freeResult(init.gpa, &result);
            if (!result.ok) {
                std.debug.print("error: content validation failed; no package written\n", .{});
                return ExitCode.content_error.int();
            }
            if (!opts.quiet) {
                std.debug.print("ok: wrote package {s} ({d} page(s), rag={any})\n", .{
                    result.archive_path,
                    result.page_count,
                    result.include_rag,
                });
            }
            return ExitCode.success.int();
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "renderVersionJson: fixed keys and product constants" {
    const gpa = std.testing.allocator;
    const bytes = try renderVersionJson(gpa, true);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"format\": \"boris-package\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"package_schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, pipeline.boris_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, pipeline.compiler_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, pipeline.schema_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"include_rag\": true") != null);

    // Key order: format before package_schema_version before product_version.
    const i_fmt = std.mem.indexOf(u8, bytes, "\"format\"").?;
    const i_psv = std.mem.indexOf(u8, bytes, "\"package_schema_version\"").?;
    const i_prod = std.mem.indexOf(u8, bytes, "\"product_version\"").?;
    const i_comp = std.mem.indexOf(u8, bytes, "\"compiler_id\"").?;
    const i_ir = std.mem.indexOf(u8, bytes, "\"ir_schema_version\"").?;
    try std.testing.expect(i_fmt < i_psv and i_psv < i_prod and i_prod < i_comp and i_comp < i_ir);
}

test "package: valid fixture IR-only produces archive with expected members" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Unique packages dir under test-output so parallel tests do not clash.
    const packages_dir = "test-output/package-ir-only";
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, packages_dir) catch {};
    defer cwd.deleteTree(io, packages_dir) catch {};

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .archive_name = "boris-package.tar",
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &result);

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(FailureKind.none, result.failure);
    try std.testing.expect(result.page_count > 0);
    try std.testing.expect(!result.include_rag);

    // Stage must be gone; final archive present.
    if (cwd.openDir(io, packages_dir ++ "/.boris-package-stage", .{})) |*d| {
        d.close(io);
        try std.testing.expect(false); // stage should not remain
    } else |_| {}

    var pkg = try cwd.openDir(io, packages_dir, .{});
    defer pkg.close(io);
    var tar_file = try pkg.openFile(io, "boris-package.tar", .{});
    defer tar_file.close(io);

    // Read entire tar into memory (fixture is small).
    var reader = tar_file.reader(io, &.{});
    const tar_bytes = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(tar_bytes);
    try std.testing.expect(tar_bytes.len > 0);

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fbs = std.Io.Reader.fixed(tar_bytes);
    var it = std.tar.Iterator.init(&fbs, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var saw_version = false;
    var saw_sums = false;
    var saw_manifest = false;
    var saw_graph = false;
    var saw_report = false;
    var saw_rag = false;

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const n = entry.name;
        if (std.mem.eql(u8, n, archive_root ++ "/" ++ version_filename)) saw_version = true;
        if (std.mem.eql(u8, n, archive_root ++ "/" ++ checksums_filename)) saw_sums = true;
        if (std.mem.eql(u8, n, archive_root ++ "/ir/manifest.json")) saw_manifest = true;
        if (std.mem.eql(u8, n, archive_root ++ "/ir/graph.json")) saw_graph = true;
        if (std.mem.eql(u8, n, archive_root ++ "/ir/build-report.json")) saw_report = true;
        if (std.mem.indexOf(u8, n, "/rag/") != null) saw_rag = true;
    }

    try std.testing.expect(saw_version);
    try std.testing.expect(saw_sums);
    try std.testing.expect(saw_manifest);
    try std.testing.expect(saw_graph);
    try std.testing.expect(saw_report);
    try std.testing.expect(!saw_rag);
}

test "package: dual-run same host produces identical tar bytes (IR-only)" {
    // Same packages_dir twice: build-report embeds outDir (stage path), so
    // different packages_dir values intentionally diverge. Same-path dual run
    // is the determinism claim.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    const packages_dir = "test-output/package-det";
    cwd.deleteTree(io, packages_dir) catch {};
    defer cwd.deleteTree(io, packages_dir) catch {};

    var ra = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &ra);
    try std.testing.expect(ra.ok);

    var pkg = try cwd.openDir(io, packages_dir, .{});
    defer pkg.close(io);
    const a = try readFileAlloc(io, pkg, default_archive_name, gpa);
    defer gpa.free(a);

    var rb = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &rb);
    try std.testing.expect(rb.ok);

    const b = try readFileAlloc(io, pkg, default_archive_name, gpa);
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "package: content failure leaves no archive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const packages_dir = "test-output/package-bad";
    cwd.deleteTree(io, packages_dir) catch {};
    defer cwd.deleteTree(io, packages_dir) catch {};

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/missing-parent/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &result);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(FailureKind.content, result.failure);

    // No final archive.
    var pkg = cwd.openDir(io, packages_dir, .{}) catch {
        // packages_dir may not exist — also fine
        return;
    };
    defer pkg.close(io);
    if (pkg.openFile(io, default_archive_name, .{})) |*f| {
        f.close(io);
        try std.testing.expect(false);
    } else |_| {}

    // No leftover stage.
    if (cwd.openDir(io, packages_dir ++ "/.boris-package-stage", .{})) |*d| {
        d.close(io);
        try std.testing.expect(false);
    } else |_| {}
}

test "package: failed install preserves previous archive" {
    // Confirmed defect class: delete-before-install destroyed the live archive
    // when a later write/install step failed. Injection fails only after the
    // replacement temp is complete; the prior archive must remain byte-identical.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const packages_dir = "test-output/package-preserve-prev";
    cwd.deleteTree(io, packages_dir) catch {};
    defer cwd.deleteTree(io, packages_dir) catch {};

    var first = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &first);
    try std.testing.expect(first.ok);

    var pkg = try cwd.openDir(io, packages_dir, .{});
    defer pkg.close(io);
    const prior = try readFileAlloc(io, pkg, default_archive_name, gpa);
    defer gpa.free(prior);
    try std.testing.expect(prior.len > 0);

    const failed = run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
        .test_fail_before_archive_install = true,
    });
    try std.testing.expectError(error.TestInjectedArchiveInstallFailure, failed);

    const after = try readFileAlloc(io, pkg, default_archive_name, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, prior, after);

    // No install leftovers after a failed install.
    if (pkg.openFile(io, "." ++ default_archive_name ++ ".tmp", .{})) |*f| {
        f.close(io);
        try std.testing.expect(false);
    } else |_| {}
    if (pkg.openFile(io, "." ++ default_archive_name ++ ".prev", .{})) |*f| {
        f.close(io);
        try std.testing.expect(false);
    } else |_| {}
}

test "package: second success replaces via move-aside without leftover prev" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const packages_dir = "test-output/package-replace-ok";
    cwd.deleteTree(io, packages_dir) catch {};
    defer cwd.deleteTree(io, packages_dir) catch {};

    var first = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &first);
    try std.testing.expect(first.ok);

    var second = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .packages_dir = packages_dir,
        .include_rag = false,
        .quiet = true,
    });
    defer freeResult(gpa, &second);
    try std.testing.expect(second.ok);

    var pkg = try cwd.openDir(io, packages_dir, .{});
    defer pkg.close(io);
    var tar_file = try pkg.openFile(io, default_archive_name, .{});
    defer tar_file.close(io);
    // Leftover move-aside / temp names must not linger after success.
    if (pkg.openFile(io, "." ++ default_archive_name ++ ".tmp", .{})) |*f| {
        f.close(io);
        try std.testing.expect(false);
    } else |_| {}
    if (pkg.openFile(io, "." ++ default_archive_name ++ ".prev", .{})) |*f| {
        f.close(io);
        try std.testing.expect(false);
    } else |_| {}
}
