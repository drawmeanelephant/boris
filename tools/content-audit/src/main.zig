//! boris-content-audit — standalone deterministic source-content audit tool.
//!
//! Reads a Boris content tree, audits poetry coverage against a policy, and
//! writes an atomically replaced, tool-owned report tree. Never writes to the
//! audited source. Never executes embedded content. No network. No product
//! compiler imports.
//!
//! Exit codes:
//!   0  audit completed and no selected failure class was triggered
//!   1  findings selected by --fail-on were present
//!   2  usage error
//!   3  I/O or output-ownership error
//!   4  malformed source, policy, or previous-report contract

const std = @import("std");
const util = @import("util.zig");
const cli = @import("cli.zig");
const policy_mod = @import("policy.zig");
const audit_mod = @import("audit.zig");
const frontmatter_mod = @import("frontmatter.zig");
const output = @import("output.zig");
const report_json = @import("report_json.zig");
const report_md = @import("report_md.zig");
const report_html = @import("report_html.zig");

const ExitCode = enum(u8) {
    success = 0,
    findings = 1,
    usage = 2,
    io_error = 3,
    contract = 4,
};

/// Diagnostics channel. The Zig 0.16.0 build runner fails the `zig build test`
/// step when the test binary writes to stdout/stderr (listen-mode protocol
/// quirk), so diagnostics are elided in test builds; the real CLI is
/// unaffected and still reports every diagnostic to stderr.
fn diag(comptime fmt: []const u8, args: anytype) void {
    if (!@import("builtin").is_test) std.debug.print(fmt, args);
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const a = init.arena.allocator();

    const args_z = init.minimal.args.toSlice(a) catch {
        diag("boris-content-audit: failed to read process arguments\n", .{});
        return @intFromEnum(ExitCode.usage);
    };
    var args_list: std.ArrayList([]const u8) = .empty;
    for (args_z) |arg| args_list.append(a, arg) catch return @intFromEnum(ExitCode.usage);
    return runTool(io, a, args_list.items);
}

/// Lexical absolute path normalization (no symlink resolution; symlink
/// components are refused separately). Refuses `..` escapes.
fn normalizeAbs(gpa: std.mem.Allocator, cwd_abs: []const u8, path: []const u8) ![]u8 {
    var input = path;
    var base = cwd_abs;
    if (path.len > 0 and path[0] == '/') {
        input = path;
        base = "/";
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, base);
    var parts = std.mem.splitScalar(u8, input, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or util.eql(part, ".")) continue;
        if (util.eql(part, "..")) return error.PathEscapesRoot;
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '/') try buf.append(gpa, '/');
        try buf.appendSlice(gpa, part);
    }
    if (buf.items.len == 0) try buf.appendSlice(gpa, "/");
    return try buf.toOwnedSlice(gpa);
}

fn pathsOverlap(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b) and (a.len == b.len or (a.len > b.len and a[b.len] == '/'));
}

fn getCwdAlloc(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    return try gpa.dupe(u8, buf[0..n]);
}

fn readFileCwd(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return output.readFileAlloc(io, std.Io.Dir.cwd(), path, gpa);
}

fn runTool(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const options = cli.parseOptions(gpa, args) catch |err| {
        diag("boris-content-audit: usage error: {s}\n\n", .{@errorName(err)});
        diag("{s}", .{cli.help_text});
        return @intFromEnum(ExitCode.usage);
    };

    if (options.help) {
        diag("{s}", .{cli.help_text});
        return @intFromEnum(ExitCode.success);
    }

    if (options.out_dir == null) {
        diag("boris-content-audit: --out=DIR is required\n\n{s}", .{cli.help_text});
        return @intFromEnum(ExitCode.usage);
    }
    // Normalize --out by stripping trailing slashes so the sibling stage and
    // backup paths are truly siblings (never nested inside the output dir).
    var out_dir: []const u8 = options.out_dir.?;
    if (out_dir.len > 1) {
        while (out_dir.len > 1 and out_dir[out_dir.len - 1] == '/') out_dir = out_dir[0 .. out_dir.len - 1];
    }
    // content-root must be a relative dir beneath root.
    if (options.content_root.len == 0 or options.content_root[0] == '/') {
        diag("boris-content-audit: --content-root must be a relative directory\n", .{});
        return @intFromEnum(ExitCode.usage);
    }
    if (options.content_root[0] == '.' and (options.content_root.len == 1 or options.content_root[1] == '/')) {
        if (util.eql(options.content_root, ".") or std.mem.startsWith(u8, options.content_root, "./")) {
            diag("boris-content-audit: --content-root must not be '.' or './...' (use a named relative dir)\n", .{});
            return @intFromEnum(ExitCode.usage);
        }
    }

    const cwd_abs = getCwdAlloc(io, gpa) catch |err| {
        diag("boris-content-audit: getcwd failed: {s}\n", .{@errorName(err)});
        return @intFromEnum(ExitCode.io_error);
    };
    const root_abs = normalizeAbs(gpa, cwd_abs, options.root_dir) catch {
        diag("boris-content-audit: invalid --root path\n", .{});
        return @intFromEnum(ExitCode.usage);
    };
    const content_abs = normalizeAbs(gpa, root_abs, options.content_root) catch {
        diag("boris-content-audit: --content-root escapes --root\n", .{});
        return @intFromEnum(ExitCode.usage);
    };
    const out_abs = normalizeAbs(gpa, cwd_abs, out_dir) catch {
        diag("boris-content-audit: invalid --out path\n", .{});
        return @intFromEnum(ExitCode.usage);
    };

    // Safety: refuse source/output overlap (either direction).
    if (pathsOverlap(out_abs, content_abs) or pathsOverlap(content_abs, out_abs)) {
        diag("boris-content-audit: refused: output dir overlaps the content root\n", .{});
        return @intFromEnum(ExitCode.io_error);
    }
    // Safety: refuse symlink traversal on the output path.
    if (util.hasSymlinkComponent(io, std.Io.Dir.cwd(), out_dir)) {
        diag("boris-content-audit: refused: output path contains a symlink component\n", .{});
        return @intFromEnum(ExitCode.io_error);
    }

    // Policy.
    var policy_opt: ?policy_mod.Policy = null;
    var policy_digest: []const u8 = "";
    if (options.policy_path) |p| {
        const bytes = readFileCwd(io, gpa, p) catch {
            diag("boris-content-audit: could not read policy file '{s}'\n", .{p});
            return @intFromEnum(ExitCode.io_error);
        };
        policy_opt = policy_mod.parse(gpa, bytes) catch |err| {
            diag("boris-content-audit: malformed policy '{s}': {s}\n", .{ p, @errorName(err) });
            return @intFromEnum(ExitCode.contract);
        };
        policy_digest = util.sha256Hex(gpa, bytes) catch |err| {
            diag("boris-content-audit: policy digest failed: {s}\n", .{@errorName(err)});
            return @intFromEnum(ExitCode.io_error);
        };
    }

    // Previous report.
    var previous_bytes: ?[]const u8 = null;
    if (options.previous_report_path) |p| {
        previous_bytes = readFileCwd(io, gpa, p) catch {
            diag("boris-content-audit: could not read previous report '{s}'\n", .{p});
            return @intFromEnum(ExitCode.io_error);
        };
    }

    var root_dir = std.Io.Dir.cwd().openDir(io, options.root_dir, .{}) catch {
        diag("boris-content-audit: cannot open --root '{s}'\n", .{options.root_dir});
        return @intFromEnum(ExitCode.io_error);
    };
    defer root_dir.close(io);

    var audit = audit_mod.run(io, gpa, root_dir, .{
        .root_dir = options.root_dir,
        .content_root = options.content_root,
        .out_dir = out_dir,
        .content_root_abs = content_abs,
        .out_abs = out_abs,
        .policy = policy_opt,
        .policy_digest = policy_digest,
        .source_revision = options.source_revision,
        .quiet = options.quiet,
    }) catch |err| {
        diag("boris-content-audit: audit failed: {s}\n", .{@errorName(err)});
        return switch (err) {
            error.ContentRootMissing, error.ContentRootSymlink, error.OutputPathSymlink, error.OutputInsideContentRoot, error.ContentRootInsideOutput, error.UnreadableContent => @intFromEnum(ExitCode.io_error),
            error.OutOfMemory => @intFromEnum(ExitCode.io_error),
        };
    };

    // Delta comparison.
    if (previous_bytes) |prev| {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, prev, .{}) catch {
            diag("boris-content-audit: previous report is not valid JSON\n", .{});
            return @intFromEnum(ExitCode.contract);
        };
        defer parsed.deinit();
        audit_mod.compareDelta(&audit, gpa, parsed.value, options.collections) catch |err| {
            diag("boris-content-audit: previous report incompatible: {s}\n", .{@errorName(err)});
            return @intFromEnum(ExitCode.contract);
        };
    }

    // Stage + emit.
    const stage_path = std.fmt.allocPrint(gpa, "{s}{s}", .{ out_dir, util.stage_suffix }) catch {
        diag("boris-content-audit: out of memory building stage path\n", .{});
        return @intFromEnum(ExitCode.io_error);
    };
    const backup_path = std.fmt.allocPrint(gpa, "{s}{s}", .{ out_dir, util.backup_suffix }) catch {
        diag("boris-content-audit: out of memory building backup path\n", .{});
        return @intFromEnum(ExitCode.io_error);
    };
    const final_path = out_dir;

    output.prepareOwnedStage(io, final_path, stage_path) catch |err| {
        diag("boris-content-audit: output ownership refusal: {s}\n", .{@errorName(err)});
        return @intFromEnum(ExitCode.io_error);
    };
    var stage_dir = std.Io.Dir.cwd().openDir(io, stage_path, .{}) catch |err| {
        diag("boris-content-audit: cannot open stage dir: {s}\n", .{@errorName(err)});
        output.cleanupPath(io, stage_path);
        return @intFromEnum(ExitCode.io_error);
    };
    defer stage_dir.close(io);

    // Ownership marker first (exact content validated on later runs).
    output.writeBytes(io, stage_dir, util.output_owner_marker, util.output_owner_marker_content) catch |err| {
        diag("boris-content-audit: marker write failed: {s}\n", .{@errorName(err)});
        output.cleanupPath(io, stage_path);
        return @intFromEnum(ExitCode.io_error);
    };

    // Reproduction command.
    const repro = buildRepro(gpa, &options, final_path) catch |err| {
        diag("boris-content-audit: repro build failed: {s}\n", .{@errorName(err)});
        return @intFromEnum(ExitCode.io_error);
    };

    if (options.format.includeJson()) {
        const json = report_json.emit(gpa, &audit, &.{ .collections = options.collections }) catch |err| {
            diag("boris-content-audit: json emit failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
        defer gpa.free(json);
        output.writeBytes(io, stage_dir, "report.json", json) catch |err| {
            diag("boris-content-audit: report.json write failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
    }
    if (options.format.includeMarkdown()) {
        const md = report_md.emit(gpa, &audit, &.{ .collections = options.collections, .reproduction = repro }) catch |err| {
            diag("boris-content-audit: md emit failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
        defer gpa.free(md);
        output.writeBytes(io, stage_dir, "REPORT.md", md) catch |err| {
            diag("boris-content-audit: REPORT.md write failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
    }
    if (options.format.includeHtml()) {
        stage_dir.createDirPath(io, "site") catch |err| {
            diag("boris-content-audit: site dir create failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
        var site_dir = stage_dir.openDir(io, "site", .{}) catch |err| {
            diag("boris-content-audit: site dir open failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
        defer site_dir.close(io);
        report_html.emitAll(gpa, &audit, &.{ .collections = options.collections }, site_dir, io) catch |err| {
            diag("boris-content-audit: html emit failed: {s}\n", .{@errorName(err)});
            output.cleanupPath(io, stage_path);
            return @intFromEnum(ExitCode.io_error);
        };
    }

    output.publishOwnedStage(io, final_path, stage_path, backup_path) catch |err| {
        if (err == error.BackupRestoreFailed) {
            diag("boris-content-audit: publish failed: {s} — the previous report was not restored; it remains recoverable at {s}{s} (do not delete it by hand)\n", .{ @errorName(err), out_dir, util.backup_suffix });
        } else if (err == error.RefuseUnownedBackup) {
            diag("boris-content-audit: publish refused: the backup path {s}{s} is not a boris-content-audit backup (no valid ownership marker); it was left untouched\n", .{ out_dir, util.backup_suffix });
        } else {
            diag("boris-content-audit: publish failed: {s}\n", .{@errorName(err)});
        }
        output.cleanupPath(io, stage_path);
        return @intFromEnum(ExitCode.io_error);
    };

    // Findings.
    const findings = countFindings(&audit, options.collections);
    const exit_code: ExitCode = switch (options.fail_on) {
        .none => .success,
        .structural => if (findings.structural > 0) .findings else .success,
        .policy => if (findings.structural > 0 or findings.policy > 0) .findings else .success,
    };

    if (!options.quiet) {
        diag(
            "boris-content-audit: wrote {s}/report.json, {s}/REPORT.md, {s}/site/ · {d} source records, {d} poetry records, {d} exceptions, exit {d}\n",
            .{ final_path, final_path, final_path, findings.source_count, findings.poetry_count, audit.exceptions.len, @intFromEnum(exit_code) },
        );
    }
    return @intFromEnum(exit_code);
}

fn buildRepro(gpa: std.mem.Allocator, options: *const cli.Options, final_path: []const u8) ![]u8 {
    _ = final_path;
    // The reproduction command is intentionally stable across output dirs so
    // the report tree is byte-identical between runs; --out is caller-chosen.
    var repro: std.ArrayList(u8) = .empty;
    errdefer repro.deinit(gpa);
    try repro.appendSlice(gpa, "boris-content-audit --mode=poetry --root=");
    try repro.appendSlice(gpa, options.root_dir);
    try repro.appendSlice(gpa, " --content-root=");
    try repro.appendSlice(gpa, options.content_root);
    if (options.policy_path) |p| {
        try repro.appendSlice(gpa, " --policy=");
        try repro.appendSlice(gpa, p);
    }
    try repro.appendSlice(gpa, " --out=<output-dir>");
    return try repro.toOwnedSlice(gpa);
}

const Findings = struct {
    structural: usize,
    policy: usize,
    source_count: usize,
    poetry_count: usize,
};

fn countFindings(audit: *const audit_mod.Audit, collections: []const []const u8) Findings {
    var f: Findings = .{ .structural = 0, .policy = 0, .source_count = 0, .poetry_count = 0 };
    // Structural findings follow the same collection scope as every other
    // section of a filtered report.
    for (audit.exceptions) |e| {
        if (e.severity != .structural) continue;
        if (!audit_mod.recordIdInScope(audit, e.record_id, collections)) continue;
        f.structural += 1;
    }
    var missing_pairs: usize = 0;
    var placeholder_records: usize = 0;
    var orphan_records: usize = 0;
    for (audit.records) |*rec| {
        if (collections.len > 0) {
            var sel = false;
            for (collections) |c| {
                if (util.eql(c, rec.collection)) sel = true;
            }
            if (!sel) continue;
        }
        switch (rec.kind) {
            .source => {
                f.source_count += 1;
                for (rec.coverage_classes) |c| {
                    if (c == .missing) missing_pairs += 1;
                }
            },
            .poetry => {
                f.poetry_count += 1;
                if (rec.alignment == .orphan) orphan_records += 1;
                if (rec.excluded) continue; // excluded records are not policy findings
                if (rec.verse) |v| {
                    if (v.complete_count > 0 and v.substantive_count == 0) placeholder_records += 1;
                }
            },
            .other => {},
        }
    }
    f.policy = missing_pairs + placeholder_records + orphan_records;
    return f;
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------

fn tmpPath(a: std.mem.Allocator, tmp: std.testing.TmpDir, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, suffix });
}

/// Run the full CLI pipeline against a temp tree (root/content structure).
fn runAudit(io: std.Io, a: std.mem.Allocator, root: []const u8, policy: []const u8, out: []const u8, previous: ?[]const u8, extra: []const []const u8) !u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(a);
    try args.appendSlice(a, &.{ "boris-content-audit", "--mode=poetry", "--content-root=content", "--quiet" });
    try args.append(a, try std.fmt.allocPrint(a, "--root={s}", .{root}));
    try args.append(a, try std.fmt.allocPrint(a, "--policy={s}", .{policy}));
    try args.append(a, try std.fmt.allocPrint(a, "--out={s}", .{out}));
    if (previous) |p| try args.append(a, try std.fmt.allocPrint(a, "--previous-report={s}", .{p}));
    for (extra) |e| try args.append(a, e);
    return runTool(io, a, args.items);
}

fn makeTree(io: std.Io, a: std.mem.Allocator, root: []const u8, files: []const struct { path: []const u8, data: []const u8 }) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    for (files) |f| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, f.path });
        if (std.fs.path.dirname(full)) |parent| try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = full, .data = f.data });
    }
}

fn hashTree(io: std.Io, a: std.mem.Allocator, root: []const u8, files: []const []const u8) ![][]const u8 {
    var hashes: std.ArrayList([]const u8) = .empty;
    for (files) |rel| {
        try hashes.append(a, try output.hashFile(io, a, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel })));
    }
    return try hashes.toOwnedSlice(a);
}

const full_policy =
    \\{
    \\  "schema_version": 1,
    \\  "eligible_collections": { "lorelog": ["haiku", "limerick", "aphorism"] },
    \\  "poetry_collections": { "haikus": "haiku", "limericks": "limerick", "aphorisms": "aphorism" },
    \\  "excluded_statuses": ["draft"],
    \\  "excluded_ids": ["lorelog/EXCL"],
    \\  "placeholder": { "exact_lines": ["Awaiting context"], "title_prefixes": ["Stub:"], "case_sensitive": false },
    \\  "density_bands": { "haiku": [1], "limerick": [1], "aphorism": [1] },
    \\  "exact_mappings": {
    \\    "haikus/HAI-100": "lorelog/LLG-100",
    \\    "haikus/HAI-101": "lorelog/LLG-101",
    \\    "haikus/HAI-102": "lorelog/LLG-102",
    \\    "haikus/HAI-MAL": "lorelog/LLG-103",
    \\    "limericks/LIM-100": "lorelog/LLG-100",
    \\    "aphorisms/APH-100": "lorelog/LLG-100"
    \\  }
    \\}
;

fn writeFixturePolicy(io: std.Io, a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return writePolicyJson(io, a, dir, full_policy);
}

fn writePolicyJson(io: std.Io, a: std.mem.Allocator, dir: []const u8, json: []const u8) ![]const u8 {
    const p = try std.fmt.allocPrint(a, "{s}/policy.json", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = json });
    return p;
}

/// Policy whose exact_mappings cover only records present in the small
/// runAudit trees (lorelog/LLG-100 with haiku+limerick+aphorism expected).
/// Stale mapping keys are structural findings, so fixture policies must not
/// name records that are absent from the fixture tree.
const pair_policy =
    \\{
    \\  "schema_version": 1,
    \\  "eligible_collections": { "lorelog": ["haiku", "limerick", "aphorism"] },
    \\  "poetry_collections": { "haikus": "haiku", "limericks": "limerick", "aphorisms": "aphorism" },
    \\  "excluded_statuses": ["draft"],
    \\  "placeholder": { "exact_lines": ["Awaiting context"], "title_prefixes": ["Stub:"], "case_sensitive": false },
    \\  "density_bands": { "haiku": [1], "limerick": [1], "aphorism": [1] },
    \\  "exact_mappings": {
    \\    "haikus/HAI-100": "lorelog/LLG-100",
    \\    "limericks/LIM-100": "lorelog/LLG-100"
    \\  }
    \\}
;

/// Same shape but only the haiku mapping (for trees without a limerick).
const one_policy =
    \\{
    \\  "schema_version": 1,
    \\  "eligible_collections": { "lorelog": ["haiku", "limerick", "aphorism"] },
    \\  "poetry_collections": { "haikus": "haiku", "limericks": "limerick", "aphorisms": "aphorism" },
    \\  "excluded_statuses": ["draft"],
    \\  "placeholder": { "exact_lines": ["Awaiting context"], "title_prefixes": ["Stub:"], "case_sensitive": false },
    \\  "density_bands": { "haiku": [1], "limerick": [1], "aphorism": [1] },
    \\  "exact_mappings": {
    \\    "haikus/HAI-100": "lorelog/LLG-100"
    \\  }
    \\}
;

/// No exact mappings at all (trees that contain no poetry to map).
const bare_policy =
    \\{
    \\  "schema_version": 1,
    \\  "eligible_collections": { "lorelog": ["haiku", "limerick", "aphorism"] },
    \\  "poetry_collections": { "haikus": "haiku", "limericks": "limerick", "aphorisms": "aphorism" },
    \\  "excluded_statuses": ["draft"],
    \\  "placeholder": { "exact_lines": ["Awaiting context"], "title_prefixes": ["Stub:"], "case_sensitive": false },
    \\  "density_bands": { "haiku": [1], "limerick": [1], "aphorism": [1] },
    \\  "exact_mappings": {}
    \\}
;

test "full fixture: coverage classes, mapping, placeholder, empty, orphan, missing target" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "full-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "lorelog/llg-101.md", .data = "---\nid: lorelog/LLG-101\nparent: lorelog\nstatus: published\n---\n# 101\n" },
        .{ .path = "lorelog/llg-102.md", .data = "---\nid: lorelog/LLG-102\nparent: lorelog\nstatus: published\n---\n# 102\n" },
        .{ .path = "lorelog/llg-103.md", .data = "---\nid: lorelog/LLG-103\nparent: lorelog\nstatus: published\n---\n# 103\n" },
        .{ .path = "lorelog/llg-104.md", .data = "---\nid: lorelog/LLG-104\nparent: lorelog\nstatus: draft\n---\n# 104\n" },
        .{ .path = "lorelog/excl.md", .data = "---\nid: lorelog/EXCL\nparent: lorelog\nstatus: published\n---\n# excl\n" },
        .{ .path = "lorelog/noid.md", .data = "---\nparent: lorelog\nstatus: published\n---\n# no id\n" },
        .{ .path = "lorelog/unclosed.md", .data = "---\nid: lorelog/UNCLOSED\nparent: lorelog\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: haikus\ntitle: For 100\n---\n# For 100\n\nline one\nline two\nline three\n\nnext one\nnext two\nnext three\n\nlast one\nlast two\nlast three\n" },
        .{ .path = "haikus/hai-101.md", .data = "---\nid: haikus/HAI-101\nparent: haikus\ntitle: Stub: For 101\n---\n# Stub\n\nAwaiting context\nAwaiting context\nAwaiting context\n" },
        .{ .path = "haikus/hai-102.md", .data = "---\nid: haikus/HAI-102\nparent: haikus\ntitle: For 102\n---\n" },
        .{ .path = "haikus/hai-mal.md", .data = "---\nid: haikus/HAI-MAL\nparent: haikus\ntitle: For 103\n---\n# For 103\n\none\ntwo\nthree\nfour\n" },
        .{ .path = "haikus/hai-orphan.md", .data = "---\nid: haikus/HAI-ORPHAN\nparent: haikus\ntitle: Orphan\n---\n# Orphan\n\nx\ny\nz\n" },
        .{ .path = "haikus/hai-miss.md", .data = "---\nid: haikus/HAI-MISS\nparent: lorelog/LLG-999\ntitle: Missing\n---\n# Missing\n\nx\ny\nz\n" },
        .{ .path = "limericks/lim-100.md", .data = "---\nid: limericks/LIM-100\nparent: limericks\ntitle: For 100\n---\n# For 100\n\na\na\nb\na\na\n" },
        .{ .path = "aphorisms/aph-100.md", .data = "---\nid: aphorisms/APH-100\nparent: aphorisms\ntitle: For 100\n---\n# For 100\n\nFirst aphorism sentence here.\n\nSecond aphorism sentence here.\n" },
    });

    const policy_path = try writeFixturePolicy(io, a, root);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});

    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    var policy = try policy_mod.parse(a, full_policy);
    const audit = try audit_mod.run(io, a, root_dir, .{
        .root_dir = root,
        .content_root = "content",
        .out_dir = out_dir,
        .content_root_abs = try std.fmt.allocPrint(a, "{s}/content", .{root}),
        .out_abs = out_dir,
        .policy = policy,
        .policy_digest = try util.sha256Hex(a, full_policy),
    });
    _ = &policy;
    _ = policy_path;

    // Alignment
    var mapped: usize = 0;
    var orphan: usize = 0;
    var missing_target: usize = 0;
    var malformed: usize = 0;
    for (audit.records) |rec| {
        switch (rec.alignment orelse continue) {
            .mapped => mapped += 1,
            .orphan => orphan += 1,
            .missing_target => missing_target += 1,
            .malformed_record => malformed += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(mapped, 6); // HAI-100, HAI-101, HAI-102, HAI-MAL, LIM-100, APH-100
    try std.testing.expectEqual(orphan, 1); // HAI-ORPHAN
    try std.testing.expectEqual(missing_target, 1); // HAI-MISS

    // Coverage: LLG-100 all three substantive
    var llg100: ?*const audit_mod.Record = null;
    for (audit.records) |*rec| {
        const rid = rec.id orelse continue;
        if (util.eql(rid, "lorelog/LLG-100")) llg100 = rec;
    }
    try std.testing.expectEqual(@as(usize, 3), llg100.?.coverage_classes.len);
    try std.testing.expect(llg100.?.coverage_classes[0] == .present_substantive);
    try std.testing.expect(llg100.?.coverage_classes[1] == .present_substantive);
    try std.testing.expect(llg100.?.coverage_classes[2] == .present_substantive);

    // LLG-101: placeholder haiku, missing limerick+aphorism
    var llg101: ?*const audit_mod.Record = null;
    for (audit.records) |*rec| {
        const rid = rec.id orelse continue;
        if (util.eql(rid, "lorelog/LLG-101")) llg101 = rec;
    }
    try std.testing.expectEqual(llg101.?.coverage_classes[0], .present_placeholder);
    try std.testing.expectEqual(llg101.?.coverage_classes[1], .missing);
    try std.testing.expectEqual(llg101.?.coverage_classes[2], .missing);

    // LLG-102 empty; LLG-103 malformed-shape haiku
    var llg102: ?*const audit_mod.Record = null;
    var llg103: ?*const audit_mod.Record = null;
    for (audit.records) |*rec| {
        const rid = rec.id orelse continue;
        if (util.eql(rid, "lorelog/LLG-102")) llg102 = rec;
        if (util.eql(rid, "lorelog/LLG-103")) llg103 = rec;
    }
    try std.testing.expectEqual(llg102.?.coverage_classes[0], .present_empty);
    try std.testing.expectEqual(llg103.?.coverage_classes[0], .malformed);

    // Excluded records are not coverage targets.
    var llg104_seen = false;
    for (audit.records) |rec| {
        const rid = rec.id orelse continue;
        if (util.eql(rid, "lorelog/LLG-104")) llg104_seen = rec.excluded;
    }
    try std.testing.expect(llg104_seen);
}

test "byte-identical second run" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "det-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: haikus\ntitle: For 100\n---\n# For 100\n\none\ntwo\nthree\n" },
        .{ .path = "limericks/lim-100.md", .data = "---\nid: limericks/LIM-100\nparent: limericks\ntitle: L\n---\n# L\n\na\na\nb\na\na\n" },
    });
    const policy_path = try writePolicyJson(io, a, root, pair_policy);
    const out1 = try std.fmt.allocPrint(a, "{s}/out1", .{root});
    const out2 = try std.fmt.allocPrint(a, "{s}/out2", .{root});

    const code1 = try runAudit(io, a, root, policy_path, out1, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code1);
    const code2 = try runAudit(io, a, root, policy_path, out2, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code2);

    const rels = [_][]const u8{ "report.json", "REPORT.md", "site/index.html", "site/coverage.html", "site/density.html", "site/alignment.html", "site/exceptions.html", "site/changes.html", "site/audit.css" };
    for (rels) |rel| {
        const b1 = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ out1, rel }), a);
        const b2 = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ out2, rel }), a);
        try std.testing.expectEqualStrings(b1, b2);
    }
}

test "source tree unchanged after success and after failure" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "mut-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    const src_files = [_][]const u8{ "content/lorelog/llg-100.md", "content/haikus/hai-100.md", "content/limericks/lim-100.md" };
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: haikus\ntitle: For 100\n---\n# For 100\n\none\ntwo\nthree\n" },
        .{ .path = "limericks/lim-100.md", .data = "---\nid: limericks/LIM-100\nparent: limericks\ntitle: L\n---\n# L\n\na\na\nb\na\na\n" },
    });
    const policy_path = try writePolicyJson(io, a, root, pair_policy);
    const before = try hashTree(io, a, root, &src_files);

    const out_ok = try std.fmt.allocPrint(a, "{s}/out-ok", .{root});
    const code_ok = try runAudit(io, a, root, policy_path, out_ok, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code_ok);
    const after_ok = try hashTree(io, a, root, &src_files);
    for (before, after_ok) |b, c| try std.testing.expectEqualStrings(b, c);

    // Failure: output inside content root is refused before any write.
    const bad_out = try std.fmt.allocPrint(a, "{s}/content/out-inside", .{root});
    const code_bad = try runAudit(io, a, root, policy_path, bad_out, null, &.{});
    try std.testing.expectEqual(@as(u8, 3), code_bad);
    const after_bad = try hashTree(io, a, root, &src_files);
    for (before, after_bad) |b, c| try std.testing.expectEqualStrings(b, c);
}

test "symlink refusal and unmarked output refusal" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "sym-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    const external = try std.fmt.allocPrint(a, "{s}/external", .{root});
    try makeTree(io, a, external, &.{.{ .path = "escaped.md", .data = "---\nid: escaped/OUTSIDE\nparent: escaped\nstatus: published\n---\n# outside\n" }});
    try std.Io.Dir.cwd().createDirPath(io, content);
    // An in-tree symlink directory is never followed: discovery skips it and
    // the audit completes without reading the external target.
    try std.Io.Dir.cwd().symLink(io, "../external", try std.fmt.allocPrint(a, "{s}/lorelog", .{content}), .{ .is_directory = true });
    const policy_path = try writePolicyJson(io, a, root, bare_policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code);
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "escaped/OUTSIDE") == null);

    // A content root that is itself a symlink is refused before any traversal.
    const root2 = try tmpPath(a, tmp, "sym-root2");
    const external2 = try std.fmt.allocPrint(a, "{s}/external2", .{root2});
    const real_content = try std.fmt.allocPrint(a, "{s}/real", .{root2});
    try makeTree(io, a, real_content, &.{.{ .path = "lorelog/llg.md", .data = "---\nid: lorelog/LLG\nparent: lorelog\nstatus: published\n---\n" }});
    try std.Io.Dir.cwd().createDirPath(io, root2);
    try std.Io.Dir.cwd().symLink(io, "real", try std.fmt.allocPrint(a, "{s}/content", .{root2}), .{ .is_directory = true });
    const policy2 = try writePolicyJson(io, a, root2, bare_policy);
    const out2 = try std.fmt.allocPrint(a, "{s}/out", .{root2});
    const code_sym = try runAudit(io, a, root2, policy2, out2, null, &.{});
    try std.testing.expectEqual(@as(u8, 3), code_sym);
    _ = external2;

    // Unmarked non-empty output refused.
    const root3 = try tmpPath(a, tmp, "unmarked-root");
    const content3 = try std.fmt.allocPrint(a, "{s}/content", .{root3});
    try makeTree(io, a, content3, &.{.{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n" }});
    const policy3 = try writePolicyJson(io, a, root3, bare_policy);
    const out3 = try std.fmt.allocPrint(a, "{s}/out", .{root3});
    try std.Io.Dir.cwd().createDirPath(io, out3);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/precious.txt", .{out3}), .data = "mine" });
    const code3 = try runAudit(io, a, root3, policy3, out3, null, &.{});
    try std.testing.expectEqual(@as(u8, 3), code3);
}

test "delta mode reports changes with policy identity check" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "delta-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: haikus\ntitle: For 100\n---\n# For 100\n\nAwaiting context\nAwaiting context\nAwaiting context\n" },
    });
    const policy_path = try writePolicyJson(io, a, root, one_policy);
    const out1 = try std.fmt.allocPrint(a, "{s}/out1", .{root});
    const out2 = try std.fmt.allocPrint(a, "{s}/out2", .{root});

    const code1 = try runAudit(io, a, root, policy_path, out1, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code1);

    // Make the placeholder substantive with a different verse count (3 -> 2),
    // proving both the transition and verse-count delta are reported.
    const hai = try std.fmt.allocPrint(a, "{s}/haikus/hai-100.md", .{content});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hai, .data = "---\nid: haikus/HAI-100\nparent: haikus\ntitle: For 100\n---\n# For 100\n\nreal one\nreal two\nreal three\n\nsecond unit\nsecond two\nsecond three\n" });

    const prev_report = try std.fmt.allocPrint(a, "{s}/report.json", .{out1});
    const code2 = try runAudit(io, a, root, policy_path, out2, prev_report, &.{});
    try std.testing.expectEqual(@as(u8, 0), code2);

    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out2}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const delta = parsed.value.object.get("delta").?;
    try std.testing.expectEqualStrings("true", if (delta.object.get("present").?.bool) "true" else "false");
    const changes = delta.object.get("changes").?.array.items;
    var found_transition = false;
    var found_verse = false;
    for (changes) |c| {
        const kind = c.object.get("kind").?.string;
        if (util.eql(kind, "placeholder_to_substantive")) found_transition = true;
        if (util.eql(kind, "verse_changed")) found_verse = true;
    }
    try std.testing.expect(found_transition);
    try std.testing.expect(found_verse);

    // Policy identity mismatch refuses delta.
    const other_policy = try std.fmt.allocPrint(a, "{s}/other-policy.json", .{root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = other_policy, .data = "{\"schema_version\":1,\"eligible_collections\":{\"lorelog\":[\"haiku\"]},\"poetry_collections\":{\"haikus\":\"haiku\"}}" });
    const out3 = try std.fmt.allocPrint(a, "{s}/out3", .{root});
    const code3 = try runAudit(io, a, root, other_policy, out3, prev_report, &.{});
    try std.testing.expectEqual(@as(u8, 4), code3);
}

test "fail-on exit codes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "exit-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "lorelog/bad.md", .data = "---\nid: lorelog/BAD\nparent: lorelog\nstatus: published\n" }, // unclosed
    });
    const policy_path = try writePolicyJson(io, a, root, bare_policy);
    const out1 = try std.fmt.allocPrint(a, "{s}/o1", .{root});
    const c1 = try runAudit(io, a, root, policy_path, out1, null, &.{"--fail-on=structural"});
    try std.testing.expectEqual(@as(u8, 1), c1);
    const out2 = try std.fmt.allocPrint(a, "{s}/o2", .{root});
    const c2 = try runAudit(io, a, root, policy_path, out2, null, &.{"--fail-on=none"});
    try std.testing.expectEqual(@as(u8, 0), c2);
}

test "no-id poetry, fence-at-eof, and trailing-slash out are safe" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "safe-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        // Parseable frontmatter with no id: must not panic in density/type stats.
        .{ .path = "haikus/hai-noid.md", .data = "---\nparent: haikus\nstatus: published\n---\n# no id\n" },
        // File that closes frontmatter at EOF with no trailing newline: the
        // body_offset clamp must keep the body slice in bounds.
        .{ .path = "haikus/hai-eof.md", .data = "---\nid: haikus/HAI-EOF\nparent: haikus\n---" },
    });
    const policy_path = try writePolicyJson(io, a, root, bare_policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out/", .{root}); // trailing slash
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    try std.testing.expectEqual(@as(u8, 1), code); // missing_id record -> structural
    // The report tree must exist despite the trailing-slash --out.
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}report.json", .{out_dir}), a);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "malformed_records") != null);
}

test "oversized source file is classified oversized and not analyzed" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "oversize-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-huge.md", .data = "" },
    });
    // Replace the haiku with a file larger than max_source_bytes (1 MiB + 1).
    const big = try a.alloc(u8, frontmatter_mod.max_source_bytes + 1);
    @memset(big, 'x');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/haikus/hai-huge.md", .{content}), .data = big });
    const policy_path = try writePolicyJson(io, a, root, bare_policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    // The oversized record is malformed (structural), never parsed as verse.
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    try std.testing.expectEqual(@as(u8, 1), code);
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const malformed = parsed.value.object.get("totals").?.object.get("malformed_records").?.integer;
    try std.testing.expectEqual(@as(i64, 1), malformed);
    const vt = parsed.value.object.get("verse_totals").?.array.items;
    for (vt) |row| {
        try std.testing.expectEqual(@as(i64, 0), row.object.get("verse_units").?.integer);
    }
}

test "usage errors exit 2" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = runTool(io, a, &.{ "boris-content-audit", "--mode=poetry", "--root=.", "--content-root=content" });
    try std.testing.expectEqual(@as(u8, 2), c); // missing --out
}

fn scanExceptions(io: std.Io, a: std.mem.Allocator, out_dir: []const u8, kind: []const u8) !usize {
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const exceptions = parsed.value.object.get("exceptions").?.array.items;
    var count: usize = 0;
    for (exceptions) |e| {
        if (util.eql(e.object.get("kind").?.string, kind)) count += 1;
    }
    return count;
}

test "stale mapping key and non-source mapping target are structural" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "stale-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: lorelog/LLG-100\ntitle: A\n---\n# A\n\none\ntwo\nthree\n" },
        .{ .path = "haikus/hai-200.md", .data = "---\nid: haikus/HAI-200\nparent: lorelog/LLG-100\ntitle: B\n---\n# B\n\na\nb\nc\n" },
    });
    // GHOST key does not exist (stale); HAI-200 maps to HAI-100 which exists
    // but is a poetry record, not a source (impossible mapping).
    const policy =
        \\{"schema_version": 1, "eligible_collections": {"lorelog": ["haiku"]}, "poetry_collections": {"haikus": "haiku"}, "exact_mappings": {"haikus/HAI-100": "lorelog/LLG-100", "haikus/GHOST": "lorelog/LLG-100", "haikus/HAI-200": "haikus/HAI-100"}}
    ;
    const policy_path = try writePolicyJson(io, a, root, policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    try std.testing.expectEqual(@as(u8, 1), code); // structural gate fails
    try std.testing.expectEqual(@as(usize, 1), try scanExceptions(io, a, out_dir, "stale_exact_mapping_key"));
    try std.testing.expectEqual(@as(usize, 1), try scanExceptions(io, a, out_dir, "mapping_target_not_source"));
    // Valid evidence still resolves the owner: HAI-100 stays mapped.
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const records = parsed.value.object.get("records").?.array.items;
    var hai100_alignment: []const u8 = "";
    for (records) |rv| {
        const id = rv.object.get("id").?.string;
        if (util.eql(id, "haikus/HAI-100")) hai100_alignment = rv.object.get("alignment").?.string;
    }
    try std.testing.expectEqualStrings("mapped", hai100_alignment);
}

test "valid evidence plus one dead evidence target resolves owner and fails the structural gate" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "dead-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: lorelog/LLG-100\ntitle: A\nrelations: [relates_to=lorelog/LLG-999]\n---\n# A\n\none\ntwo\nthree\n" },
    });
    const policy_path = try writePolicyJson(io, a, root, one_policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    // The dead relation is a structural finding even though the parent edge
    // resolves the owner: the run fails its structural gate.
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 1), try scanExceptions(io, a, out_dir, "missing_target"));
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const alignment_records = parsed.value.object.get("alignment").?.object.get("records").?.array.items;
    var hai100_status: []const u8 = "";
    for (alignment_records) |rv| {
        if (util.eql(rv.object.get("id").?.string, "haikus/HAI-100")) hai100_status = rv.object.get("status").?.string;
    }
    try std.testing.expectEqualStrings("mapped", hai100_status);
    // Coverage still resolved from the valid evidence. one_policy declares
    // three eligible types, so find the haiku row by type name.
    const cov = parsed.value.object.get("coverage_by_collection").?.array.items;
    var haiku_substantive: i64 = -1;
    for (cov) |row| {
        if (util.eql(row.object.get("type").?.string, "haiku")) haiku_substantive = row.object.get("present_substantive").?.integer;
    }
    try std.testing.expectEqual(@as(i64, 1), haiku_substantive);
}

test "duplicate source/type poetry companions are ambiguous and structural" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "dup-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: lorelog/LLG-100\ntitle: A\n---\n# A\n\none\ntwo\nthree\n" },
        .{ .path = "haikus/hai-100b.md", .data = "---\nid: haikus/HAI-100B\nparent: lorelog/LLG-100\ntitle: B\n---\n# B\n\na\nb\nc\n" },
    });
    // Both haiku records claim lorelog/LLG-100 via their parent edge: the
    // source/type coverage must be ambiguous, never the first record.
    const policy =
        \\{"schema_version": 1, "eligible_collections": {"lorelog": ["haiku"]}, "poetry_collections": {"haikus": "haiku"}, "exact_mappings": {}}
    ;
    const policy_path = try writePolicyJson(io, a, root, policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    try std.testing.expectEqual(@as(u8, 1), code); // duplicate_coverage is structural
    try std.testing.expectEqual(@as(usize, 1), try scanExceptions(io, a, out_dir, "duplicate_coverage"));
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const rows = parsed.value.object.get("coverage_by_collection").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), rows[0].object.get("ambiguous_mapping").?.integer);
    try std.testing.expectEqual(@as(i64, 0), rows[0].object.get("present_substantive").?.integer);
}

test "unsupported poetry type is not counted and is structural" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "sonnet-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "sonnets/son-100.md", .data = "---\nid: sonnets/SON-100\nparent: lorelog/LLG-100\ntitle: A\n---\n# A\n\nline one\nline two\nline three\n" },
    });
    const policy =
        \\{"schema_version": 1, "eligible_collections": {"lorelog": ["sonnet"]}, "poetry_collections": {"sonnets": "sonnet"}, "exact_mappings": {}}
    ;
    const policy_path = try writePolicyJson(io, a, root, policy);
    const out_dir = try std.fmt.allocPrint(a, "{s}/out", .{root});
    const code = try runAudit(io, a, root, policy_path, out_dir, null, &.{});
    // Unsupported shape is structural; the poem-like lines are never counted
    // as paragraph units and never grant substantive coverage.
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 1), try scanExceptions(io, a, out_dir, "unregistered_poetry_shape"));
    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_dir}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const vt = parsed.value.object.get("verse_totals").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), vt[0].object.get("records").?.integer);
    try std.testing.expectEqual(@as(i64, 0), vt[0].object.get("verse_units").?.integer);
    try std.testing.expectEqual(@as(i64, 0), vt[0].object.get("substantive_units").?.integer);
    try std.testing.expectEqual(@as(i64, 1), vt[0].object.get("malformed_units").?.integer);
    const rows = parsed.value.object.get("coverage_by_collection").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), rows[0].object.get("malformed").?.integer);
}

const ReportOverrides = struct {
    format_id: ?[]const u8 = null,
    schema_version: ?i64 = null,
    mode: ?[]const u8 = null,
    source_root_label: ?[]const u8 = null,
    remove_policy_digest: bool = false,
    collection_filter: ?[]const []const u8 = null,
};

fn writeMutatedReport(io: std.Io, a: std.mem.Allocator, src: []const u8, out: []const u8, overrides: ReportOverrides) !void {
    const bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), src, a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    if (overrides.format_id) |v| try parsed.value.object.put(a, "format_id", .{ .string = v });
    if (overrides.schema_version) |v| try parsed.value.object.put(a, "schema_version", .{ .integer = v });
    if (overrides.mode) |v| try parsed.value.object.put(a, "mode", .{ .string = v });
    if (overrides.source_root_label) |v| try parsed.value.object.put(a, "source_root_label", .{ .string = v });
    if (overrides.remove_policy_digest) _ = parsed.value.object.orderedRemove("policy_digest");
    if (overrides.collection_filter) |cols| {
        var items = std.json.Array.init(a);
        for (cols) |c| try items.append(.{ .string = c });
        try parsed.value.object.put(a, "collection_filter", .{ .array = items });
    }
    const out_bytes = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = out_bytes });
}

test "delta compatibility is strict across format, schema, mode, root, digest, filter" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "strict-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: lorelog/LLG-100\ntitle: A\n---\n# A\n\none\ntwo\nthree\n" },
    });
    const policy_path = try writePolicyJson(io, a, root, one_policy);
    const out_base = try std.fmt.allocPrint(a, "{s}/out-base", .{root});
    const code_base = try runAudit(io, a, root, policy_path, out_base, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code_base);
    const prev = try std.fmt.allocPrint(a, "{s}/report.json", .{out_base});

    // Unmutated previous report still compares (sanity).
    const out_ok = try std.fmt.allocPrint(a, "{s}/out-ok", .{root});
    try std.testing.expectEqual(@as(u8, 0), try runAudit(io, a, root, policy_path, out_ok, prev, &.{}));

    var case: usize = 0;
    const cases = [_]ReportOverrides{
        .{ .format_id = "not-boris-content-audit" },
        .{ .schema_version = 2 },
        .{ .mode = "filed" },
        .{ .source_root_label = "src" },
        .{ .remove_policy_digest = true },
        .{ .collection_filter = &.{"lorelog"} },
    };
    for (cases) |overrides| {
        const mut = try std.fmt.allocPrint(a, "{s}/mut-{d}.json", .{ root, case });
        const out_mut = try std.fmt.allocPrint(a, "{s}/out-mut-{d}", .{ root, case });
        case += 1;
        try writeMutatedReport(io, a, prev, mut, overrides);
        try std.testing.expectEqual(@as(u8, 4), try runAudit(io, a, root, policy_path, out_mut, mut, &.{}));
    }
}

test "mixed collection filtering is scoped consistently" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try tmpPath(a, tmp, "scope-root");
    const content = try std.fmt.allocPrint(a, "{s}/content", .{root});
    try makeTree(io, a, content, &.{
        .{ .path = "lorelog/llg-100.md", .data = "---\nid: lorelog/LLG-100\nparent: lorelog\nstatus: published\n---\n# 100\n" },
        .{ .path = "mascots/msc-100.md", .data = "---\nid: mascots/MSC-100\nparent: mascots\nstatus: published\n---\n# M\n" },
        .{ .path = "haikus/hai-100.md", .data = "---\nid: haikus/HAI-100\nparent: lorelog/LLG-100\ntitle: A\n---\n# A\n\none\ntwo\nthree\n" },
        .{ .path = "haikus/hai-200.md", .data = "---\nid: haikus/HAI-200\nparent: mascots/MSC-100\ntitle: B\n---\n# B\n\na\nb\nc\n" },
        .{ .path = "limericks/lim-100.md", .data = "---\nid: limericks/LIM-100\nparent: lorelog/LLG-100\ntitle: L\n---\n# L\n\na\na\nb\na\na\n" },
        .{ .path = "limericks/lim-200.md", .data = "---\nid: limericks/LIM-200\nparent: mascots/MSC-100\ntitle: L2\n---\n# L2\n\n1\n2\n3\n4\n5\n" },
    });
    const policy =
        \\{"schema_version": 1, "eligible_collections": {"lorelog": ["haiku", "limerick"], "mascots": ["haiku", "limerick"]}, "poetry_collections": {"haikus": "haiku", "limericks": "limerick"}, "exact_mappings": {}}
    ;
    const policy_path = try writePolicyJson(io, a, root, policy);
    const out_scoped = try std.fmt.allocPrint(a, "{s}/out-scoped", .{root});
    const code = try runAudit(io, a, root, policy_path, out_scoped, null, &.{"--collection=lorelog"});
    try std.testing.expectEqual(@as(u8, 0), code);

    const json_bytes = try output.readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{out_scoped}), a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_bytes, .{});
    const totals = parsed.value.object.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 3), totals.get("records_discovered").?.integer); // LLG-100 + HAI-100 + LIM-100
    try std.testing.expectEqual(@as(i64, 1), totals.get("source_records").?.integer);
    try std.testing.expectEqual(@as(i64, 2), totals.get("poetry_records").?.integer);
    try std.testing.expectEqual(@as(i64, 0), totals.get("excluded_records").?.integer); // scoped, not global
    // Verse totals are scoped: one haiku and one limerick record.
    const vt = parsed.value.object.get("verse_totals").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), vt[0].object.get("records").?.integer);
    try std.testing.expectEqual(@as(i64, 1), vt[1].object.get("records").?.integer);
    // Coverage rows only for lorelog.
    const rows = parsed.value.object.get("coverage_by_collection").?.array.items;
    for (rows) |row| try std.testing.expectEqualStrings("lorelog", row.object.get("collection").?.string);
    // Alignment records only for the two mapped lorelog poems.
    const align_records = parsed.value.object.get("alignment").?.object.get("records").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), align_records.len);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("alignment").?.object.get("counts").?.object.get("mapped").?.integer);
    // Per-record output is scoped too.
    const records = parsed.value.object.get("records").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), records.len);
    // Scope is labeled explicitly.
    const scope = parsed.value.object.get("scope").?.object;
    try std.testing.expectEqualStrings("source_collection_and_mapped_poetry", scope.get("type").?.string);
    try std.testing.expectEqualStrings("scoped", scope.get("totals").?.string);

    // A delta against an unfiltered previous report must be rejected: the two
    // runs are not the same population.
    const out_all = try std.fmt.allocPrint(a, "{s}/out-all", .{root});
    const code_all = try runAudit(io, a, root, policy_path, out_all, null, &.{});
    try std.testing.expectEqual(@as(u8, 0), code_all);
    const prev_all = try std.fmt.allocPrint(a, "{s}/report.json", .{out_all});
    const out_mixed = try std.fmt.allocPrint(a, "{s}/out-mixed", .{root});
    try std.testing.expectEqual(@as(u8, 4), try runAudit(io, a, root, policy_path, out_mixed, prev_all, &.{"--collection=lorelog"}));

    // Collection-filter semantics are a set: argument order must not change
    // the population. A previous report filtered with the same names in a
    // different order still compares.
    const out_both_ab = try std.fmt.allocPrint(a, "{s}/out-both-ab", .{root});
    try std.testing.expectEqual(@as(u8, 0), try runAudit(io, a, root, policy_path, out_both_ab, null, &.{ "--collection=lorelog", "--collection=mascots" }));
    const prev_ab = try std.fmt.allocPrint(a, "{s}/report.json", .{out_both_ab});
    const out_both_ba = try std.fmt.allocPrint(a, "{s}/out-both-ba", .{root});
    try std.testing.expectEqual(@as(u8, 0), try runAudit(io, a, root, policy_path, out_both_ba, prev_ab, &.{ "--collection=mascots", "--collection=lorelog" }));
    // A genuinely different set still mismatches.
    const out_both_lonly = try std.fmt.allocPrint(a, "{s}/out-both-lonly", .{root});
    try std.testing.expectEqual(@as(u8, 4), try runAudit(io, a, root, policy_path, out_both_lonly, prev_ab, &.{"--collection=lorelog"}));
}
