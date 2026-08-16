//! Hosted job runner: unpack a trusted source archive, exec native `boris`
//! once, collect diagnostics and artifacts, delete the workspace.
//!
//! This is not a publication target and is not linked into the `boris`
//! binary. Cloudflare Containers is one host (`--listen`); `--once` is
//! the local and CI path. See docs/contracts/cloudflare-container-runner.md.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const json_out = @import("json_out.zig");

pub const schema_version = "boris-job-1";
pub const format = "boris-job";
/// Keep in lockstep with `pipeline.boris_version`. `scripts/test-version-pin.sh`
/// checks the suffix.
pub const runner_version = "0.8.1";
pub const runner_id = "boris-job-runner/" ++ runner_version;
pub const boris_version = runner_version;

pub const default_source_bytes: u64 = 16 * 1024 * 1024;
pub const default_expanded_bytes: u64 = 32 * 1024 * 1024;
pub const default_artifact_bytes: u64 = 64 * 1024 * 1024;
pub const default_file_count: u32 = 10_000;
pub const default_timeout_ms: u32 = 120_000;
pub const default_port: u16 = 8080;
pub const max_job_id_len: usize = 64;
pub const max_path_len: usize = 1024;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Command = enum {
    build,
    validate,

    pub fn name(self: Command) []const u8 {
        return switch (self) {
            .build => "build",
            .validate => "validate",
        };
    }
};

pub const RunnerClass = enum {
    ok,
    content,
    usage,
    io,
    archive,
    limit,
    timeout,
    auth,
    process,

    pub fn name(self: RunnerClass) []const u8 {
        return switch (self) {
            .ok => "ok",
            .content => "content",
            .usage => "usage",
            .io => "io",
            .archive => "archive",
            .limit => "limit",
            .timeout => "timeout",
            .auth => "auth",
            .process => "process",
        };
    }

    pub fn processExit(self: RunnerClass) u8 {
        return switch (self) {
            .ok => 0,
            .content => 1,
            .usage, .archive, .limit, .auth => 2,
            .io, .process => 3,
            .timeout => 5,
        };
    }
};

pub const Limits = struct {
    source_bytes: u64 = default_source_bytes,
    expanded_bytes: u64 = default_expanded_bytes,
    artifact_bytes: u64 = default_artifact_bytes,
    file_count: u32 = default_file_count,
    timeout_ms: u32 = default_timeout_ms,
};

pub const Diagnostic = struct {
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    remediation: []const u8,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
    id: ?[]const u8,
};

pub const Artifact = struct {
    path: []const u8,
    size: u64,
    sha256_hex: [64]u8,
    /// File bytes, owned. Present so a result package can be built after the
    /// workspace is deleted. Freed by `JobResult.deinit`.
    bytes: []u8,
};

pub const JobResult = struct {
    ok: bool,
    runner_class: RunnerClass,
    exit_code: ?u8,
    compiler_id: ?[]const u8,
    image_digest: ?[]const u8,
    job_id: []const u8,
    command: Command,
    diagnostics: []Diagnostic,
    artifacts: []Artifact,
    limits: Limits,
    wall_ms: u64,
    unpack_ms: u64,
    compile_ms: u64,
    workspace_removed: bool,

    pub fn deinit(self: *JobResult, gpa: std.mem.Allocator) void {
        if (self.compiler_id) |s| gpa.free(s);
        if (self.image_digest) |s| gpa.free(s);
        gpa.free(self.job_id);
        for (self.diagnostics) |d| {
            gpa.free(d.severity);
            gpa.free(d.code);
            gpa.free(d.message);
            gpa.free(d.remediation);
            if (d.source_path) |s| gpa.free(s);
            if (d.id) |s| gpa.free(s);
        }
        gpa.free(self.diagnostics);
        for (self.artifacts) |a| {
            gpa.free(a.path);
            gpa.free(a.bytes);
        }
        gpa.free(self.artifacts);
        self.* = undefined;
    }
};

pub const RunOpts = struct {
    boris_path: []const u8,
    archive: []const u8,
    command: Command = .build,
    job_id: ?[]const u8 = null,
    work_root: []const u8,
    limits: Limits = .{},
    image_digest: ?[]const u8 = null,
};

const ExtractError = error{
    PathTraversal,
    SymlinkRejected,
    UnsupportedType,
    MissingContent,
    SourceTooLarge,
    ExpandedTooLarge,
    TooManyFiles,
    EmptyArchive,
};

/// Reject archive member names that could escape the workspace.
pub fn validateArchivePath(name: []const u8) ExtractError![]const u8 {
    var n = name;
    if (std.mem.startsWith(u8, n, "./")) n = n[2..];
    if (n.len == 0 or n.len > max_path_len) return error.PathTraversal;
    if (n[0] == '/' or n[0] == '\\') return error.PathTraversal;
    if (std.mem.indexOfScalar(u8, n, 0) != null) return error.PathTraversal;
    if (std.mem.indexOfScalar(u8, n, '\\') != null) return error.PathTraversal;
    if (std.mem.indexOf(u8, n, "//") != null) return error.PathTraversal;

    var it = std.mem.splitScalar(u8, n, '/');
    var parts: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0) return error.PathTraversal;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.PathTraversal;
        parts += 1;
    }
    if (parts == 0) return error.PathTraversal;
    return n;
}

pub fn validateJobId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_job_id_len) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn jobIdFromArchive(archive: []const u8) [16]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(archive, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    return hex;
}

fn classFromExit(code: u8) RunnerClass {
    return switch (code) {
        0 => .ok,
        1 => .content,
        2 => .usage,
        3 => .io,
        else => .process,
    };
}

fn failedResult(
    gpa: std.mem.Allocator,
    class: RunnerClass,
    command: Command,
    job_id: []const u8,
    limits: Limits,
    image_digest: ?[]const u8,
    wall_ms: u64,
    unpack_ms: u64,
    compile_ms: u64,
    workspace_removed: bool,
) !JobResult {
    return .{
        .ok = false,
        .runner_class = class,
        .exit_code = null,
        .compiler_id = null,
        .image_digest = if (image_digest) |d| try gpa.dupe(u8, d) else null,
        .job_id = try gpa.dupe(u8, job_id),
        .command = command,
        .diagnostics = try gpa.alloc(Diagnostic, 0),
        .artifacts = try gpa.alloc(Artifact, 0),
        .limits = limits,
        .wall_ms = wall_ms,
        .unpack_ms = unpack_ms,
        .compile_ms = compile_ms,
        .workspace_removed = workspace_removed,
    };
}

fn extractTar(
    io: Io,
    dest: Io.Dir,
    archive: []const u8,
    limits: Limits,
) ExtractError!void {
    if (archive.len > limits.source_bytes) return error.SourceTooLarge;
    if (archive.len == 0) return error.EmptyArchive;

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fbs = std.Io.Reader.fixed(archive);
    var it = std.tar.Iterator.init(&fbs, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var expanded: u64 = 0;
    var files: u32 = 0;
    var saw_member = false;

    while (it.next() catch return error.UnsupportedType) |entry| {
        saw_member = true;
        const rel = try validateArchivePath(entry.name);
        switch (entry.kind) {
            .directory => {
                dest.createDirPath(io, rel) catch return error.PathTraversal;
            },
            .sym_link => return error.SymlinkRejected,
            .file => {
                files += 1;
                if (files > limits.file_count) return error.TooManyFiles;
                expanded = std.math.add(u64, expanded, entry.size) catch
                    return error.ExpandedTooLarge;
                if (expanded > limits.expanded_bytes) return error.ExpandedTooLarge;

                if (std.fs.path.dirname(rel)) |parent| {
                    if (parent.len > 0)
                        dest.createDirPath(io, parent) catch return error.PathTraversal;
                }

                var out_file = dest.createFile(io, rel, .{}) catch return error.PathTraversal;
                defer out_file.close(io);
                var write_buf: [16 * 1024]u8 = undefined;
                var fw = out_file.writer(io, &write_buf);
                it.streamRemaining(entry, &fw.interface) catch return error.UnsupportedType;
                fw.interface.flush() catch return error.UnsupportedType;
            },
        }
    }
    if (!saw_member) return error.EmptyArchive;

    if (dest.openDir(io, "content", .{})) |*d| {
        d.close(io);
    } else |_| return error.MissingContent;
}

const ArtifactList = struct { items: []Artifact, oversize: bool };

fn listArtifacts(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    limits: Limits,
) !ArtifactList {
    var list: std.ArrayList(Artifact) = .empty;
    errdefer {
        for (list.items) |a| gpa.free(a.path);
        list.deinit(gpa);
    }

    var total: u64 = 0;
    var walker = try out_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try normalizeRel(gpa, entry.path);
        errdefer gpa.free(rel);
        const data = readFileAlloc(io, out_dir, rel, gpa) catch {
            gpa.free(rel);
            continue;
        };
        errdefer gpa.free(data);
        total = std.math.add(u64, total, data.len) catch {
            gpa.free(data);
            return .{ .items = try list.toOwnedSlice(gpa), .oversize = true };
        };
        if (total > limits.artifact_bytes) {
            gpa.free(data);
            return .{ .items = try list.toOwnedSlice(gpa), .oversize = true };
        }

        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try list.append(gpa, .{
            .path = rel,
            .size = data.len,
            .sha256_hex = hex,
            .bytes = data,
        });
    }

    std.mem.sort(Artifact, list.items, {}, artifactLess);
    return .{ .items = try list.toOwnedSlice(gpa), .oversize = false };
}

fn artifactLess(_: void, a: Artifact, b: Artifact) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn normalizeRel(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (path) |c| {
        try out.append(gpa, if (c == '\\') '/' else c);
    }
    return try out.toOwnedSlice(gpa);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

const ParsedReport = struct {
    compiler_id: ?[]const u8,
    diagnostics: []Diagnostic,
};

fn parseReport(gpa: std.mem.Allocator, bytes: []const u8) !ParsedReport {
    const ReportDiag = struct {
        severity: []const u8 = "",
        code: []const u8 = "",
        message: []const u8 = "",
        remediation: []const u8 = "",
        sourcePath: ?[]const u8 = null,
        line: ?u32 = null,
        column: ?u32 = null,
        id: ?[]const u8 = null,
    };
    const Report = struct {
        compilerId: []const u8 = "",
        diagnostics: []ReportDiag = &.{},
    };

    const parsed = std.json.parseFromSlice(Report, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return .{
        .compiler_id = null,
        .diagnostics = try gpa.alloc(Diagnostic, 0),
    };
    defer parsed.deinit();

    var diags: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (diags.items) |d| {
            gpa.free(d.severity);
            gpa.free(d.code);
            gpa.free(d.message);
            gpa.free(d.remediation);
            if (d.source_path) |s| gpa.free(s);
            if (d.id) |s| gpa.free(s);
        }
        diags.deinit(gpa);
    }

    for (parsed.value.diagnostics) |d| {
        try diags.append(gpa, .{
            .severity = try gpa.dupe(u8, d.severity),
            .code = try gpa.dupe(u8, d.code),
            .message = try gpa.dupe(u8, d.message),
            .remediation = try gpa.dupe(u8, d.remediation),
            .source_path = if (d.sourcePath) |s| try gpa.dupe(u8, s) else null,
            .line = d.line,
            .column = d.column,
            .id = if (d.id) |s| try gpa.dupe(u8, s) else null,
        });
    }

    return .{
        .compiler_id = if (parsed.value.compilerId.len > 0)
            try gpa.dupe(u8, parsed.value.compilerId)
        else
            null,
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

fn nowMs(io: Io) i128 {
    const ts = Io.Timestamp.now(io, .awake);
    return @divTrunc(ts.nanoseconds, std.time.ns_per_ms);
}

fn elapsedMs(io: Io, start: i128) u64 {
    const now = nowMs(io);
    if (now < start) return 0;
    return @intCast(now - start);
}

/// Unpack, exec `boris` once, collect the result, delete the workspace.
pub fn runJob(io: Io, gpa: std.mem.Allocator, opts: RunOpts) !JobResult {
    const wall_start = nowMs(io);
    const generated = jobIdFromArchive(opts.archive);
    const job_id = opts.job_id orelse generated[0..];
    if (!validateJobId(job_id)) {
        return failedResult(gpa, .archive, opts.command, "invalid", opts.limits, opts.image_digest, 0, 0, 0, true);
    }

    if (opts.archive.len > opts.limits.source_bytes) {
        return failedResult(gpa, .limit, opts.command, job_id, opts.limits, opts.image_digest, elapsedMs(io, wall_start), 0, 0, true);
    }

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, opts.work_root) catch {};
    const ws_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.work_root, job_id });
    defer gpa.free(ws_rel);
    cwd.deleteTree(io, ws_rel) catch {};
    cwd.createDirPath(io, ws_rel) catch {
        return failedResult(gpa, .process, opts.command, job_id, opts.limits, opts.image_digest, elapsedMs(io, wall_start), 0, 0, true);
    };

    var removed = false;
    defer if (!removed) cwd.deleteTree(io, ws_rel) catch {};

    const unpack_start = nowMs(io);
    var ws = cwd.openDir(io, ws_rel, .{ .iterate = true }) catch {
        return failedResult(gpa, .process, opts.command, job_id, opts.limits, opts.image_digest, elapsedMs(io, wall_start), 0, 0, true);
    };
    defer ws.close(io);

    extractTar(io, ws, opts.archive, opts.limits) catch |err| {
        cwd.deleteTree(io, ws_rel) catch {};
        removed = true;
        const class: RunnerClass = switch (err) {
            error.SourceTooLarge, error.ExpandedTooLarge, error.TooManyFiles => .limit,
            else => .archive,
        };
        return failedResult(gpa, class, opts.command, job_id, opts.limits, opts.image_digest, elapsedMs(io, wall_start), elapsedMs(io, unpack_start), 0, true);
    };
    const unpack_ms = elapsedMs(io, unpack_start);

    const report_rel = try std.fmt.allocPrint(gpa, "{s}/report.json", .{ws_rel});
    defer gpa.free(report_rel);
    const content_rel = try std.fmt.allocPrint(gpa, "{s}/content", .{ws_rel});
    defer gpa.free(content_rel);
    const out_rel = try std.fmt.allocPrint(gpa, "{s}/out", .{ws_rel});
    defer gpa.free(out_rel);

    var argv_buf: [8][]const u8 = undefined;
    var argv_len: usize = 0;
    argv_buf[argv_len] = opts.boris_path;
    argv_len += 1;
    if (opts.command == .validate) {
        argv_buf[argv_len] = "validate";
        argv_len += 1;
    }
    argv_buf[argv_len] = "--quiet";
    argv_len += 1;
    argv_buf[argv_len] = "--input";
    argv_len += 1;
    argv_buf[argv_len] = content_rel;
    argv_len += 1;
    if (opts.command == .build) {
        argv_buf[argv_len] = "--html-dir";
        argv_len += 1;
        argv_buf[argv_len] = out_rel;
        argv_len += 1;
    }
    argv_buf[argv_len] = "--report";
    argv_len += 1;
    argv_buf[argv_len] = report_rel;
    argv_len += 1;

    if (opts.command == .build) cwd.createDirPath(io, out_rel) catch {};

    const compile_start = nowMs(io);
    const run_res = std.process.run(gpa, io, .{
        .argv = argv_buf[0..argv_len],
        .stdout_limit = .limited(1 * 1024 * 1024),
        .stderr_limit = .limited(1 * 1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(opts.limits.timeout_ms)),
            .clock = .awake,
        } },
    }) catch |err| {
        cwd.deleteTree(io, ws_rel) catch {};
        removed = true;
        const class: RunnerClass = if (err == error.Timeout) .timeout else .process;
        return failedResult(gpa, class, opts.command, job_id, opts.limits, opts.image_digest, elapsedMs(io, wall_start), unpack_ms, elapsedMs(io, compile_start), true);
    };
    defer gpa.free(run_res.stdout);
    defer gpa.free(run_res.stderr);
    const compile_ms = elapsedMs(io, compile_start);

    const exit_code: ?u8 = switch (run_res.term) {
        .exited => |c| c,
        else => null,
    };
    var class: RunnerClass = if (exit_code) |c| classFromExit(c) else .process;

    const report_bytes = readFileAlloc(io, cwd, report_rel, gpa) catch null;
    defer if (report_bytes) |b| gpa.free(b);
    const parsed = parseReport(gpa, report_bytes orelse "") catch
        ParsedReport{ .compiler_id = null, .diagnostics = try gpa.alloc(Diagnostic, 0) };

    var artifacts: []Artifact = try gpa.alloc(Artifact, 0);
    var oversize = false;
    if (opts.command == .build and class == .ok) {
        if (cwd.openDir(io, out_rel, .{ .iterate = true })) |*out_dir| {
            defer out_dir.close(io);
            const listed = listArtifacts(io, gpa, out_dir.*, opts.limits) catch ArtifactList{
                .items = try gpa.alloc(Artifact, 0),
                .oversize = true,
            };
            gpa.free(artifacts);
            artifacts = listed.items;
            oversize = listed.oversize;
        } else |_| {}
    }
    if (oversize) class = .limit;

    cwd.deleteTree(io, ws_rel) catch {};
    removed = true;

    const ok = class == .ok and exit_code == 0 and !oversize;
    if (!ok) {
        for (artifacts) |a| {
            gpa.free(a.path);
            gpa.free(a.bytes);
        }
        gpa.free(artifacts);
        artifacts = try gpa.alloc(Artifact, 0);
    }

    return .{
        .ok = ok,
        .runner_class = if (ok) .ok else class,
        .exit_code = exit_code,
        .compiler_id = parsed.compiler_id,
        .image_digest = if (opts.image_digest) |d| try gpa.dupe(u8, d) else null,
        .job_id = try gpa.dupe(u8, job_id),
        .command = opts.command,
        .diagnostics = parsed.diagnostics,
        .artifacts = artifacts,
        .limits = opts.limits,
        .wall_ms = elapsedMs(io, wall_start),
        .unpack_ms = unpack_ms,
        .compile_ms = compile_ms,
        .workspace_removed = true,
    };
}

pub fn renderResultJson(gpa: std.mem.Allocator, result: JobResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try writeKey(&buf, gpa, 1, "schemaVersion");
    try json_out.writeString(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "format");
    try json_out.writeString(&buf, gpa, format);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "ok");
    try json_out.writeBool(&buf, gpa, result.ok);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "status");
    try json_out.writeString(&buf, gpa, if (result.ok) "success" else "failed");
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "runnerClass");
    try json_out.writeString(&buf, gpa, result.runner_class.name());
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "exitCode");
    if (result.exit_code) |c|
        try json_out.writeUsize(&buf, gpa, c)
    else
        try json_out.writeNull(&buf, gpa);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "compilerId");
    if (result.compiler_id) |s|
        try json_out.writeString(&buf, gpa, s)
    else
        try json_out.writeNull(&buf, gpa);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "borisVersion");
    try json_out.writeString(&buf, gpa, boris_version);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "runnerId");
    try json_out.writeString(&buf, gpa, runner_id);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "imageDigest");
    if (result.image_digest) |s|
        try json_out.writeString(&buf, gpa, s)
    else
        try json_out.writeNull(&buf, gpa);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "jobId");
    try json_out.writeString(&buf, gpa, result.job_id);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "command");
    try json_out.writeString(&buf, gpa, result.command.name());
    try buf.appendSlice(gpa, ",\n");

    try writeKey(&buf, gpa, 1, "diagnostics");
    try buf.appendSlice(gpa, "[\n");
    for (result.diagnostics, 0..) |d, i| {
        try writeDiagnostic(&buf, gpa, d);
        if (i + 1 < result.diagnostics.len) try buf.appendSlice(gpa, ",\n") else try buf.appendSlice(gpa, "\n");
    }
    try buf.appendSlice(gpa, "  ],\n");

    try writeKey(&buf, gpa, 1, "artifacts");
    try buf.appendSlice(gpa, "[\n");
    for (result.artifacts, 0..) |a, i| {
        try writeArtifact(&buf, gpa, a);
        if (i + 1 < result.artifacts.len) try buf.appendSlice(gpa, ",\n") else try buf.appendSlice(gpa, "\n");
    }
    try buf.appendSlice(gpa, "  ],\n");

    try writeKey(&buf, gpa, 1, "limits");
    try buf.appendSlice(gpa, "{\n");
    try writeKey(&buf, gpa, 2, "sourceBytes");
    try json_out.writeUsize(&buf, gpa, @intCast(result.limits.source_bytes));
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 2, "expandedBytes");
    try json_out.writeUsize(&buf, gpa, @intCast(result.limits.expanded_bytes));
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 2, "artifactBytes");
    try json_out.writeUsize(&buf, gpa, @intCast(result.limits.artifact_bytes));
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 2, "fileCount");
    try json_out.writeUsize(&buf, gpa, result.limits.file_count);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 2, "timeoutMs");
    try json_out.writeUsize(&buf, gpa, result.limits.timeout_ms);
    try buf.appendSlice(gpa, "\n  },\n");

    try writeKey(&buf, gpa, 1, "timings");
    try buf.appendSlice(gpa, "{\n");
    try writeKey(&buf, gpa, 2, "wallMs");
    try json_out.writeUsize(&buf, gpa, @intCast(result.wall_ms));
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 2, "unpackMs");
    try json_out.writeUsize(&buf, gpa, @intCast(result.unpack_ms));
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 2, "compileMs");
    try json_out.writeUsize(&buf, gpa, @intCast(result.compile_ms));
    try buf.appendSlice(gpa, "\n  },\n");

    try writeKey(&buf, gpa, 1, "workspaceRemoved");
    try json_out.writeBool(&buf, gpa, result.workspace_removed);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(&buf, gpa, 1, "retried");
    try json_out.writeBool(&buf, gpa, false);
    try buf.appendSlice(gpa, "\n}\n");

    return try buf.toOwnedSlice(gpa);
}

fn writeKey(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, key: []const u8) !void {
    try json_out.indent(buf, gpa, level);
    try json_out.writeString(buf, gpa, key);
    try buf.appendSlice(gpa, ": ");
}

fn writeDiagnostic(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, d: Diagnostic) !void {
    try json_out.indent(buf, gpa, 2);
    try buf.appendSlice(gpa, "{\n");
    try writeKey(buf, gpa, 3, "severity");
    try json_out.writeString(buf, gpa, d.severity);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "code");
    try json_out.writeString(buf, gpa, d.code);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "message");
    try json_out.writeString(buf, gpa, d.message);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "remediation");
    try json_out.writeString(buf, gpa, d.remediation);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "sourcePath");
    if (d.source_path) |s| try json_out.writeString(buf, gpa, s) else try json_out.writeNull(buf, gpa);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "line");
    if (d.line) |n| try json_out.writeUsize(buf, gpa, n) else try json_out.writeNull(buf, gpa);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "column");
    if (d.column) |n| try json_out.writeUsize(buf, gpa, n) else try json_out.writeNull(buf, gpa);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "id");
    if (d.id) |s| try json_out.writeString(buf, gpa, s) else try json_out.writeNull(buf, gpa);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(buf, gpa, 2);
    try buf.append(gpa, '}');
}

fn writeArtifact(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, a: Artifact) !void {
    try json_out.indent(buf, gpa, 2);
    try buf.appendSlice(gpa, "{\n");
    try writeKey(buf, gpa, 3, "path");
    try json_out.writeString(buf, gpa, a.path);
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "size");
    try json_out.writeUsize(buf, gpa, @intCast(a.size));
    try buf.appendSlice(gpa, ",\n");
    try writeKey(buf, gpa, 3, "sha256");
    try json_out.writeString(buf, gpa, &a.sha256_hex);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(buf, gpa, 2);
    try buf.append(gpa, '}');
}

fn takeAllocating(w: *std.Io.Writer.Allocating, gpa: std.mem.Allocator) ![]u8 {
    var list = w.toArrayList();
    return try list.toOwnedSlice(gpa);
}

pub fn writeResultTar(gpa: std.mem.Allocator, result_json: []const u8, result: JobResult) ![]u8 {
    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    var tar_w: std.tar.Writer = .{ .underlying_writer = &w.writer };
    const file_opts: std.tar.Writer.Options = .{ .mode = 0o644, .mtime = 0 };
    try tar_w.writeFileBytes("result.json", result_json, file_opts);
    for (result.artifacts) |item| {
        const name = try std.fmt.allocPrint(gpa, "artifacts/{s}", .{item.path});
        defer gpa.free(name);
        try tar_w.writeFileBytes(name, item.bytes, file_opts);
    }
    try tar_w.finishPedantically();
    return try takeAllocating(&w, gpa);
}

fn packContentTree(io: Io, gpa: std.mem.Allocator, content_rel: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    var root = try cwd.openDir(io, content_rel, .{ .iterate = true });
    defer root.close(io);

    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    var tar_w: std.tar.Writer = .{ .underlying_writer = &w.writer };
    const file_opts: std.tar.Writer.Options = .{ .mode = 0o644, .mtime = 0 };

    var walker = try root.walk(gpa);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(gpa, try normalizeRel(gpa, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    for (paths.items) |rel| {
        const data = try readFileAlloc(io, root, rel, gpa);
        defer gpa.free(data);
        const name = try std.fmt.allocPrint(gpa, "content/{s}", .{rel});
        defer gpa.free(name);
        try tar_w.writeFileBytes(name, data, file_opts);
    }
    try tar_w.finishPedantically();
    var list = w.toArrayList();
    return try list.toOwnedSlice(gpa);
}

fn findBoris(gpa: std.mem.Allocator) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const io = std.testing.io;
    cwd.access(io, "zig-out/bin/boris", .{}) catch return error.BorisBinaryMissing;
    return try gpa.dupe(u8, "zig-out/bin/boris");
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const Cli = struct {
    once: bool = false,
    listen: ?[]const u8 = null,
    archive_path: ?[]const u8 = null,
    result_json_path: ?[]const u8 = null,
    result_tar_path: ?[]const u8 = null,
    boris_path: []const u8 = "boris",
    command: Command = .build,
    work_root: []const u8 = "/tmp/boris-jobs",
    allow_unauthenticated: bool = false,
    job_id: ?[]const u8 = null,
};

fn printUsage() void {
    std.debug.print(
        \\boris-job-runner — unpack a source archive and exec native boris once
        \\
        \\Usage:
        \\  boris-job-runner --once --archive IN.tar [--result-json OUT.json] [--result-tar OUT.tar]
        \\  boris-job-runner --listen ADDR [--allow-unauthenticated]
        \\
        \\Options:
        \\  --once                 Run one job from --archive and exit
        \\  --listen ADDR          Bind HTTP (e.g. 0.0.0.0:8080)
        \\  --archive PATH         Source ustar (required with --once)
        \\  --result-json PATH     Write result.json
        \\  --result-tar PATH      Write result package (result.json + artifacts/)
        \\  --boris PATH           Native boris binary (default: $BORIS_BIN or boris)
        \\  --command build|validate
        \\  --work-root PATH       Workspace parent (default: $BORIS_WORK_ROOT or /tmp/boris-jobs)
        \\  --job-id ID            Override job id
        \\  --allow-unauthenticated  Listen without a bearer token (local only)
        \\  -h, --help
        \\
        \\See docs/contracts/cloudflare-container-runner.md.
        \\
    , .{});
}

fn parseCli(args: []const []const u8) !Cli {
    var cli: Cli = .{};
    // Some hosts (docker --entrypoint) put the first flag in argv[0].
    var i: usize = if (args.len > 0 and std.mem.startsWith(u8, args[0], "-")) 0 else 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return error.Help;
        if (std.mem.eql(u8, a, "--once")) {
            cli.once = true;
        } else if (std.mem.eql(u8, a, "--allow-unauthenticated")) {
            cli.allow_unauthenticated = true;
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.listen = args[i];
        } else if (std.mem.eql(u8, a, "--archive")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.archive_path = args[i];
        } else if (std.mem.eql(u8, a, "--result-json")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.result_json_path = args[i];
        } else if (std.mem.eql(u8, a, "--result-tar")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.result_tar_path = args[i];
        } else if (std.mem.eql(u8, a, "--boris")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.boris_path = args[i];
        } else if (std.mem.eql(u8, a, "--command")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (std.mem.eql(u8, args[i], "build")) cli.command = .build else if (std.mem.eql(u8, args[i], "validate")) cli.command = .validate else return error.BadCommand;
        } else if (std.mem.eql(u8, a, "--work-root")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.work_root = args[i];
        } else if (std.mem.eql(u8, a, "--job-id")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.job_id = args[i];
        } else return error.UnknownFlag;
    }
    return cli;
}

fn getenv(map: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    return map.get(name);
}

fn resolveBoris(cli: Cli, env: *const std.process.Environ.Map) []const u8 {
    if (!std.mem.eql(u8, cli.boris_path, "boris")) return cli.boris_path;
    if (getenv(env, "BORIS_BIN")) |p| return p;
    return cli.boris_path;
}

fn resolveWorkRoot(cli: Cli, env: *const std.process.Environ.Map) []const u8 {
    if (!std.mem.eql(u8, cli.work_root, "/tmp/boris-jobs")) return cli.work_root;
    if (getenv(env, "BORIS_WORK_ROOT")) |p| return p;
    return cli.work_root;
}

fn httpStatus(class: RunnerClass) http.Status {
    return switch (class) {
        .ok, .content, .usage, .io => .ok,
        .archive => .bad_request,
        .limit => .payload_too_large,
        .timeout => .gateway_timeout,
        .auth => .unauthorized,
        .process => .internal_server_error,
    };
}

fn headerLine(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        var v = line[colon + 1 ..];
        while (v.len > 0 and (v[0] == ' ' or v[0] == '\t')) v = v[1..];
        return v;
    }
    return null;
}

fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, target, "?#")) |idx| return target[0..idx];
    return target;
}

fn parseListen(spec: []const u8) !struct { ip: [4]u8, port: u16 } {
    if (std.mem.indexOfScalar(u8, spec, ':')) |idx| {
        const host = spec[0..idx];
        const port = try std.fmt.parseInt(u16, spec[idx + 1 ..], 10);
        if (std.mem.eql(u8, host, "0.0.0.0")) return .{ .ip = .{ 0, 0, 0, 0 }, .port = port };
        if (std.mem.eql(u8, host, "127.0.0.1")) return .{ .ip = .{ 127, 0, 0, 1 }, .port = port };
        return error.BadListen;
    }
    const port = try std.fmt.parseInt(u16, spec, 10);
    return .{ .ip = .{ 0, 0, 0, 0 }, .port = port };
}

fn serve(init: std.process.Init, cli: Cli) u8 {
    const io = init.io;
    const spec = parseListen(cli.listen.?) catch {
        std.debug.print("error: invalid --listen (use HOST:PORT)\n", .{});
        return 2;
    };
    const token = getenv(init.environ_map, "BORIS_JOB_TOKEN");
    if (token == null and !cli.allow_unauthenticated) {
        std.debug.print("error: set BORIS_JOB_TOKEN or pass --allow-unauthenticated\n", .{});
        return 2;
    }

    const host = if (std.mem.eql(u8, &spec.ip, &.{ 127, 0, 0, 1 }))
        "127.0.0.1"
    else
        "0.0.0.0";
    var addr = Io.net.IpAddress.parseIp4(host, spec.port) catch {
        std.debug.print("error: invalid listen address\n", .{});
        return 2;
    };
    var listener = Io.net.IpAddress.listen(&addr, io, .{
        .reuse_address = true,
        .kernel_backlog = 16,
    }) catch |err| {
        std.debug.print("error: listen failed: {s}\n", .{@errorName(err)});
        return 3;
    };
    defer listener.socket.close(io);

    const bound = Io.net.IpAddress.getPort(listener.socket.address);
    std.debug.print("boris-job-runner listening on {d}.{d}.{d}.{d}:{d}\n", .{
        spec.ip[0], spec.ip[1], spec.ip[2], spec.ip[3], bound,
    });

    while (true) {
        const stream = listener.accept(io) catch continue;
        handleHttp(init, cli, token, stream);
    }
}

fn handleHttp(init: std.process.Init, cli: Cli, token: ?[]const u8, stream: Io.net.Stream) void {
    const io = init.io;
    const gpa = init.gpa;
    defer stream.close(io);

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var io_reader = stream.reader(io, &read_buf);
    var io_writer = stream.writer(io, &write_buf);
    var server = http.Server.init(&io_reader.interface, &io_writer.interface);
    var request = server.receiveHead() catch return;

    const target = request.head.target;
    const path = pathOnly(target);

    if (request.head.method == .GET and std.mem.eql(u8, path, "/health")) {
        const body = "{\"ok\":true,\"runnerId\":\"" ++ runner_id ++ "\",\"schemaVersion\":\"" ++ schema_version ++ "\"}\n";
        request.respond(body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
        return;
    }

    const want_package = std.mem.eql(u8, path, "/v1/jobs/package");
    const want_job = std.mem.eql(u8, path, "/v1/jobs") or want_package;
    if (!want_job or request.head.method != .POST) {
        request.respond("not found\n", .{
            .status = .not_found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        }) catch {};
        return;
    }

    if (token) |expected| {
        const auth = headerLine(request.head_buffer, "authorization");
        const ok = if (auth) |a|
            std.mem.startsWith(u8, a, "Bearer ") and std.mem.eql(u8, a["Bearer ".len..], expected)
        else
            false;
        if (!ok) {
            request.respond("{\"ok\":false,\"runnerClass\":\"auth\"}\n", .{
                .status = .unauthorized,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch {};
            return;
        }
    }

    const limits = Limits{};
    const body_reader = request.readerExpectContinue(&.{}) catch {
        request.respond("bad request\n", .{
            .status = .bad_request,
            .keep_alive = false,
        }) catch {};
        return;
    };
    const archive = body_reader.allocRemaining(gpa, .limited(limits.source_bytes + 1)) catch {
        request.respond("{\"ok\":false,\"runnerClass\":\"limit\"}\n", .{
            .status = .payload_too_large,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
        return;
    };
    defer gpa.free(archive);

    var command: Command = .build;
    if (queryParam(target, "command")) |c| {
        if (std.mem.eql(u8, c, "validate")) command = .validate;
    }
    const job_id_q = queryParam(target, "jobId");

    var result = runJob(io, gpa, .{
        .boris_path = resolveBoris(cli, init.environ_map),
        .archive = archive,
        .command = command,
        .job_id = job_id_q,
        .work_root = resolveWorkRoot(cli, init.environ_map),
        .limits = limits,
        .image_digest = getenv(init.environ_map, "BORIS_IMAGE_DIGEST"),
    }) catch {
        request.respond("{\"ok\":false,\"runnerClass\":\"process\"}\n", .{
            .status = .internal_server_error,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
        return;
    };
    defer result.deinit(gpa);

    const json = renderResultJson(gpa, result) catch return;
    defer gpa.free(json);

    if (want_package) {
        const tar_bytes = writeResultTar(gpa, json, result) catch {
            request.respond(json, .{
                .status = httpStatus(result.runner_class),
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch {};
            return;
        };
        defer gpa.free(tar_bytes);
        request.respond(tar_bytes, .{
            .status = httpStatus(result.runner_class),
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/x-tar" }},
        }) catch {};
        return;
    }

    request.respond(json, .{
        .status = httpStatus(result.runner_class),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
}

fn runOnce(init: std.process.Init, cli: Cli) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const archive_path = cli.archive_path orelse {
        std.debug.print("error: --once requires --archive\n", .{});
        return 2;
    };
    const cwd = Io.Dir.cwd();
    const archive = readFileAlloc(io, cwd, archive_path, gpa) catch |err| {
        std.debug.print("error: read archive: {s}\n", .{@errorName(err)});
        return 3;
    };
    defer gpa.free(archive);

    var result = runJob(io, gpa, .{
        .boris_path = resolveBoris(cli, init.environ_map),
        .archive = archive,
        .command = cli.command,
        .job_id = cli.job_id,
        .work_root = resolveWorkRoot(cli, init.environ_map),
        .image_digest = getenv(init.environ_map, "BORIS_IMAGE_DIGEST"),
    }) catch |err| {
        std.debug.print("error: job failed: {s}\n", .{@errorName(err)});
        return 3;
    };
    defer result.deinit(gpa);

    const json = renderResultJson(gpa, result) catch return 3;
    defer gpa.free(json);

    if (cli.result_json_path) |path| {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) cwd.createDirPath(io, parent) catch {};
        }
        cwd.writeFile(io, .{ .sub_path = path, .data = json }) catch |err| {
            std.debug.print("error: write result json: {s}\n", .{@errorName(err)});
            return 3;
        };
    } else {
        std.debug.print("{s}", .{json});
    }

    if (cli.result_tar_path) |path| {
        const tar_bytes = writeResultTar(gpa, json, result) catch return 3;
        defer gpa.free(tar_bytes);
        cwd.writeFile(io, .{ .sub_path = path, .data = tar_bytes }) catch return 3;
    }

    return result.runner_class.processExit();
}

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("error: failed to read process arguments\n", .{});
        return 3;
    };
    var args_list: std.ArrayList([]const u8) = .empty;
    args_list.ensureTotalCapacity(cold, args_z.len) catch return 3;
    for (args_z) |a| args_list.appendAssumeCapacity(a);

    const cli = parseCli(args_list.items) catch |err| {
        if (err == error.Help) {
            printUsage();
            return 0;
        }
        std.debug.print("error: {s}\n", .{@errorName(err)});
        printUsage();
        return 2;
    };

    if (cli.listen != null and cli.once) {
        std.debug.print("error: --listen and --once conflict\n", .{});
        return 2;
    }
    if (cli.listen) |_| return serve(init, cli);
    if (cli.once) return runOnce(init, cli);
    printUsage();
    return 2;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validateArchivePath rejects traversal and accepts fixture paths" {
    try std.testing.expectError(error.PathTraversal, validateArchivePath("../etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validateArchivePath("/abs"));
    try std.testing.expectError(error.PathTraversal, validateArchivePath("a\\b"));
    try std.testing.expectError(error.PathTraversal, validateArchivePath("foo/./bar"));
    try std.testing.expectError(error.PathTraversal, validateArchivePath("foo/../../x"));
    try std.testing.expectError(error.PathTraversal, validateArchivePath(""));
    try std.testing.expectError(error.PathTraversal, validateArchivePath("a//b"));
    try std.testing.expectEqualStrings("content/index.md", try validateArchivePath("content/index.md"));
    try std.testing.expectEqualStrings("content/guides/intro.md", try validateArchivePath("./content/guides/intro.md"));
}

test "parseCli treats argv0 as a flag when it starts with a dash" {
    const cli = try parseCli(&.{ "--once", "--archive", "in.tar", "--command", "validate" });
    try std.testing.expect(cli.once);
    try std.testing.expectEqual(Command.validate, cli.command);
    try std.testing.expectEqualStrings("in.tar", cli.archive_path.?);
}

test "validateJobId" {
    try std.testing.expect(validateJobId("abc-123"));
    try std.testing.expect(validateJobId("deadbeefcafebabe"));
    try std.testing.expect(!validateJobId(""));
    try std.testing.expect(!validateJobId("has/slash"));
    try std.testing.expect(!validateJobId("has space"));
}

test "extractTar rejects symlink members" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    var tar_w: std.tar.Writer = .{ .underlying_writer = &w.writer };
    // A regular file plus we cannot easily emit a symlink via writeFileBytes.
    // Craft a ustar symlink header by hand: typeflag '2' at offset 156.
    try tar_w.writeFileBytes("content/index.md", "# hi\n", .{ .mode = 0o644, .mtime = 0 });
    try tar_w.finishPedantically();
    const regular = try takeAllocating(&w, gpa);
    defer gpa.free(regular);

    // Mutate a copy into a symlink entry by rewriting typeflag of the first header.
    const mutated = try gpa.dupe(u8, regular);
    defer gpa.free(mutated);
    if (mutated.len > 156) mutated[156] = '2';

    var dest = try tmp.dir.createDirPathOpen(io, "ws", .{ .open_options = .{ .iterate = true } });
    defer dest.close(io);
    // Rewriting typeflag without fixing the checksum is rejected as an
    // unsupported/corrupt header. A well-formed symlink member is
    // `.sym_link` and extractTar returns SymlinkRejected for that kind.
    try std.testing.expectError(error.UnsupportedType, extractTar(io, dest, mutated, .{}));
}

test "runJob: valid fixture succeeds and removes workspace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const boris = findBoris(gpa) catch return error.SkipZigTest;
    defer gpa.free(boris);

    const archive = try packContentTree(io, gpa, "docs/contracts/fixtures/valid/content");
    defer gpa.free(archive);

    const work_root = "test-output/job-runner/valid";
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work_root) catch {};
    defer cwd.deleteTree(io, work_root) catch {};

    var result = try runJob(io, gpa, .{
        .boris_path = boris,
        .archive = archive,
        .command = .build,
        .job_id = "valid-fixture",
        .work_root = work_root,
    });
    defer result.deinit(gpa);

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(RunnerClass.ok, result.runner_class);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    try std.testing.expect(result.workspace_removed);
    try std.testing.expect(result.artifacts.len > 0);
    var saw_index = false;
    for (result.artifacts) |a| {
        if (std.mem.eql(u8, a.path, "index.html")) saw_index = true;
    }
    try std.testing.expect(saw_index);

    if (cwd.openDir(io, work_root ++ "/valid-fixture", .{})) |*d| {
        d.close(io);
        try std.testing.expect(false);
    } else |_| {}
}

test "runJob: poisoned fixture returns content class and no artifacts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const boris = findBoris(gpa) catch return error.SkipZigTest;
    defer gpa.free(boris);

    const archive = try packContentTree(io, gpa, "docs/contracts/fixtures/missing-parent/content");
    defer gpa.free(archive);

    const work_root = "test-output/job-runner/poisoned";
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work_root) catch {};
    defer cwd.deleteTree(io, work_root) catch {};

    var result = try runJob(io, gpa, .{
        .boris_path = boris,
        .archive = archive,
        .command = .build,
        .job_id = "poisoned-fixture",
        .work_root = work_root,
    });
    defer result.deinit(gpa);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(RunnerClass.content, result.runner_class);
    try std.testing.expectEqual(@as(?u8, 1), result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), result.artifacts.len);
    var saw_parent = false;
    for (result.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "EPARENTMISSING")) saw_parent = true;
    }
    try std.testing.expect(saw_parent);
}

test "runJob: traversal archive never starts boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const boris = findBoris(gpa) catch return error.SkipZigTest;
    defer gpa.free(boris);

    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    var tar_w: std.tar.Writer = .{ .underlying_writer = &w.writer };
    try tar_w.writeFileBytes("content/../escape.md", "nope\n", .{ .mode = 0o644, .mtime = 0 });
    try tar_w.finishPedantically();
    const archive = try takeAllocating(&w, gpa);
    defer gpa.free(archive);

    const work_root = "test-output/job-runner/traversal";
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work_root) catch {};
    defer cwd.deleteTree(io, work_root) catch {};

    var result = try runJob(io, gpa, .{
        .boris_path = boris,
        .archive = archive,
        .job_id = "traversal",
        .work_root = work_root,
    });
    defer result.deinit(gpa);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(RunnerClass.archive, result.runner_class);
    try std.testing.expectEqual(@as(?u8, null), result.exit_code);
}

test "renderResultJson: fixed key order and no-retry" {
    const gpa = std.testing.allocator;
    var result = JobResult{
        .ok = false,
        .runner_class = .content,
        .exit_code = 1,
        .compiler_id = try gpa.dupe(u8, "boris/0.8.1"),
        .image_digest = null,
        .job_id = try gpa.dupe(u8, "k"),
        .command = .build,
        .diagnostics = try gpa.alloc(Diagnostic, 0),
        .artifacts = try gpa.alloc(Artifact, 0),
        .limits = .{},
        .wall_ms = 1,
        .unpack_ms = 1,
        .compile_ms = 1,
        .workspace_removed = true,
    };
    defer result.deinit(gpa);

    const bytes = try renderResultJson(gpa, result);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schemaVersion\": \"boris-job-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"retried\": false") != null);
    const i_schema = std.mem.indexOf(u8, bytes, "\"schemaVersion\"").?;
    const i_format = std.mem.indexOf(u8, bytes, "\"format\"").?;
    const i_ok = std.mem.indexOf(u8, bytes, "\"ok\"").?;
    try std.testing.expect(i_schema < i_format);
    try std.testing.expect(i_format < i_ok);
}
