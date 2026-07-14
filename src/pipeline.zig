//! Content compiler pipeline (milestone 6–7):
//!   scan → parse frontmatter → promote PageDb → graph validate → freeze
//!   → IR emit (`run`) or shared compile for RAG (`compile`)
//!
//! No HTML, layouts, or Apex on this path.

const std = @import("std");
const Io = std.Io;
const diag = @import("diag.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const aside = @import("aside.zig");
const graph_mod = @import("graph.zig");
const json_out = @import("json_out.zig");
const page_mod = @import("page.zig");

pub const schema_version = "0.1.0";
pub const compiler_id = "boris/0.1.1";
/// Product version string (package / catalog_meta.boris_version).
pub const boris_version = "0.1.1";

pub const Options = struct {
    content_root: []const u8 = "content",
    out_dir: []const u8 = ".boris",
    quiet: bool = false,
};

/// Shared load options for IR and RAG (no output paths).
pub const CompileOptions = struct {
    content_root: []const u8 = "content",
    quiet: bool = false,
};

pub const PageEntry = graph_mod.Node;

/// Pipeline failure class for CLI exit mapping.
pub const FailureKind = enum {
    none,
    content,
    io,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    pages: std.ArrayList(PageEntry),
    edges: std.ArrayList(graph_mod.Edge),
    diagnostics: std.ArrayList(diag.Diagnostic),
    content_root: []const u8,
    out_dir: []const u8,
    ok: bool,
    graph_frozen: bool = false,
    /// True when graph-dependent artifacts (manifest + graph) were published.
    published_graph_ir: bool = false,
    failure: FailureKind = .none,

    pub fn deinit(self: *Result) void {
        const gpa = self.arena.child_allocator;
        self.pages.deinit(gpa);
        self.edges.deinit(gpa);
        self.diagnostics.deinit(gpa);
        self.arena.deinit();
    }

    pub fn errorCount(self: *const Result) usize {
        return diag.countErrors(self.diagnostics.items);
    }
};

fn log(opts: Options, comptime fmt: []const u8, args: anytype) void {
    if (!opts.quiet) {
        std.debug.print(fmt, args);
    }
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeOptionalString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| {
        try json_out.writeString(buf, gpa, v);
    } else {
        try json_out.writeNull(buf, gpa);
    }
}

fn parserCategoryToCode(cat: parser.Category) diag.Code {
    return switch (cat) {
        .EFRONTMATTER => .EFRONTMATTER,
        .EINVALIDUTF8 => .EINVALIDUTF8,
        .EINVALIDPATH => .EINVALIDPATH,
    };
}

fn statusName(st: ?page_mod.Status) ?[]const u8 {
    if (st) |s| return s.name();
    return null;
}

// ---------------------------------------------------------------------------
// JSON renderers (stable field order; no hash-map iteration)
// ---------------------------------------------------------------------------

pub fn renderManifest(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"compiler\": ");
    try json_out.writeString(&buf, gpa, compiler_id);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"contentRoot\": ");
    try json_out.writeString(&buf, gpa, result.content_root);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"pageCount\": ");
    try json_out.writeUsize(&buf, gpa, result.pages.items.len);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"pages\": [\n");

    for (result.pages.items, 0..) |p, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"index\": ");
        try json_out.writeUsize(&buf, gpa, p.index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"id\": ");
        try json_out.writeString(&buf, gpa, p.id);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"sourcePath\": ");
        try json_out.writeString(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"role\": ");
        try json_out.writeString(&buf, gpa, p.role.name());
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"parent\": ");
        try writeOptionalString(&buf, gpa, p.parent);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"title\": ");
        try writeOptionalString(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"status\": ");
        try writeOptionalString(&buf, gpa, p.status);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.pages.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn writeU32Array(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const u32) !void {
    try buf.append(gpa, '[');
    for (values, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(gpa, ", ");
        try json_out.writeUsize(buf, gpa, v);
    }
    try buf.append(gpa, ']');
}

pub fn renderGraph(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Nav is derived only from the frozen node list (parent_index / role).
    // Not published when validation failed (caller does not write graph.json).
    const nav = try graph_mod.buildNav(gpa, result.pages.items);
    defer graph_mod.freeNav(gpa, nav);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"frozen\": ");
    try json_out.writeBool(&buf, gpa, result.graph_frozen);
    try buf.appendSlice(gpa, ",\n");

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"nodes\": [\n");
    for (result.pages.items, 0..) |p, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"index\": ");
        try json_out.writeUsize(&buf, gpa, p.index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"id\": ");
        try json_out.writeString(&buf, gpa, p.id);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"sourcePath\": ");
        try json_out.writeString(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"role\": ");
        try json_out.writeString(&buf, gpa, p.role.name());
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"parent\": ");
        try writeOptionalString(&buf, gpa, p.parent);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"parentIndex\": ");
        try json_out.writeOptionalU32(&buf, gpa, p.parent_index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"title\": ");
        try writeOptionalString(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"status\": ");
        try writeOptionalString(&buf, gpa, p.status);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"tags\": [");
        for (p.tags, 0..) |t, ti| {
            if (ti > 0) try buf.appendSlice(gpa, ", ");
            try json_out.writeString(&buf, gpa, t);
        }
        try buf.appendSlice(gpa, "],\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"bodyOffset\": ");
        try json_out.writeUsize(&buf, gpa, p.body_offset);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.pages.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "],\n");

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"edges\": [\n");
    for (result.edges.items, 0..) |e, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"from\": ");
        try json_out.writeUsize(&buf, gpa, e.from);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"to\": ");
        try json_out.writeUsize(&buf, gpa, e.to);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"kind\": ");
        try json_out.writeString(&buf, gpa, e.kind);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.edges.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "],\n");

    // Key order after edges: nav (derived, id-sorted parallel to nodes).
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"nav\": [\n");
    for (nav, 0..) |entry, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"index\": ");
        try json_out.writeUsize(&buf, gpa, entry.index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"id\": ");
        try json_out.writeString(&buf, gpa, entry.id);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"breadcrumb\": ");
        try writeU32Array(&buf, gpa, entry.breadcrumb);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"children\": ");
        try writeU32Array(&buf, gpa, entry.children);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"siblings\": ");
        try writeU32Array(&buf, gpa, entry.siblings);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < nav.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "]\n}\n");

    return try buf.toOwnedSlice(gpa);
}

pub fn renderBuildReport(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"ok\": ");
    try json_out.writeBool(&buf, gpa, result.ok);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"contentRoot\": ");
    try json_out.writeString(&buf, gpa, result.content_root);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"outDir\": ");
    try json_out.writeString(&buf, gpa, result.out_dir);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"pageCount\": ");
    try json_out.writeUsize(&buf, gpa, result.pages.items.len);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"errorCount\": ");
    try json_out.writeUsize(&buf, gpa, result.errorCount());
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"diagnostics\": ");
    if (result.diagnostics.items.len == 0) {
        try buf.appendSlice(gpa, "[]\n");
    } else {
        try buf.appendSlice(gpa, "[\n");
        for (result.diagnostics.items, 0..) |d, i| {
            try json_out.indent(&buf, gpa, 2);
            try buf.appendSlice(gpa, "{\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"severity\": ");
            try json_out.writeString(&buf, gpa, d.severity.jsonName());
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"code\": ");
            try json_out.writeString(&buf, gpa, d.code.name());
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"message\": ");
            try json_out.writeString(&buf, gpa, d.message);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"remediation\": ");
            try json_out.writeString(&buf, gpa, d.remediation);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"sourcePath\": ");
            if (d.source_path.len == 0)
                try json_out.writeNull(&buf, gpa)
            else
                try json_out.writeString(&buf, gpa, d.source_path);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"line\": ");
            try json_out.writeOptionalU32(&buf, gpa, d.line);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"column\": ");
            try json_out.writeOptionalU32(&buf, gpa, d.column);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"id\": ");
            if (d.id.len == 0)
                try json_out.writeNull(&buf, gpa)
            else
                try json_out.writeString(&buf, gpa, d.id);
            try buf.appendSlice(gpa, "\n");
            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, '}');
            if (i + 1 < result.diagnostics.items.len) try buf.append(gpa, ',');
            try buf.append(gpa, '\n');
        }
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "]\n");
    }
    try buf.appendSlice(gpa, "}\n");
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Output publication
// ---------------------------------------------------------------------------

/// Artifact publication policy (v0.1):
///
/// **Success (`ok`):** write `manifest.json`, `graph.json`, and
/// `build-report.json` under a sibling staging directory
/// (`{out_dir}.boris-stage`), then rename each file into `out_dir`. This avoids
/// publishing a partial three-file set if a mid-write fails. Staging lives
/// next to the final directory (same parent) so same-filesystem rename is
/// likely; **cross-volume atomic replace is not claimed**.
///
/// **Content failure:** do **not** publish graph-dependent artifacts
/// (`manifest.json`, `graph.json`). Write only `build-report.json` with
/// `ok: false` and diagnostics. Remove any prior graph/manifest in `out_dir`
/// so a failed rebuild cannot leave a valid-looking IR set.
///
/// Limitations: directory rename of the whole tree is not used; per-file
/// rename from staging is best-effort. Not proven cross-platform atomic for
/// concurrent readers. Temp staging path names never appear inside JSON.
fn publishArtifacts(io: Io, gpa: std.mem.Allocator, result: *Result) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, result.out_dir);

    const report = try renderBuildReport(gpa, result);
    defer gpa.free(report);

    if (!result.ok) {
        // Remove graph-dependent artifacts from a previous successful build.
        var out = try cwd.openDir(io, result.out_dir, .{});
        defer out.close(io);
        out.deleteFile(io, "manifest.json") catch {};
        out.deleteFile(io, "graph.json") catch {};
        try out.writeFile(io, .{ .sub_path = "build-report.json", .data = report });
        result.published_graph_ir = false;
        return;
    }

    const manifest = try renderManifest(gpa, result);
    defer gpa.free(manifest);
    const graph_json = try renderGraph(gpa, result);
    defer gpa.free(graph_json);

    // Sibling staging directory: `{out_dir}.boris-stage`
    const stage_rel = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{result.out_dir});
    defer gpa.free(stage_rel);

    cwd.deleteTree(io, stage_rel) catch {};
    try cwd.createDirPath(io, stage_rel);

    {
        var stage = try cwd.openDir(io, stage_rel, .{});
        defer stage.close(io);
        try stage.writeFile(io, .{ .sub_path = "manifest.json", .data = manifest });
        try stage.writeFile(io, .{ .sub_path = "graph.json", .data = graph_json });
        try stage.writeFile(io, .{ .sub_path = "build-report.json", .data = report });
    }

    // Publish: rename each staged file into the final directory (replaces if present).
    var stage_dir = try cwd.openDir(io, stage_rel, .{});
    defer stage_dir.close(io);
    var out_dir = try cwd.openDir(io, result.out_dir, .{});
    defer out_dir.close(io);

    const names = [_][]const u8{ "manifest.json", "graph.json", "build-report.json" };
    for (names) |name| {
        try stage_dir.rename(name, out_dir, name, io);
    }

    cwd.deleteTree(io, stage_rel) catch {};
    result.published_graph_ir = true;
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

fn logCompile(quiet: bool, comptime fmt: []const u8, args: anytype) void {
    if (!quiet) std.debug.print(fmt, args);
}

/// 1-based line number of the byte at `index` (line of index 0 is 1).
fn countLinesUpTo(source: []const u8, index: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    const end = @min(index, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

/// Shared compile path for IR and RAG: scan → parse → PageDb → `graph.validate`
/// → freeze when clean. Does **not** publish artifacts.
///
/// Call sites must use this (or `run` / `rag.run`, which call it) so both modes
/// share one graph-validation entry (`graph.validate`) and the same diagnostic
/// categories for invalid content.
pub fn compile(io: Io, gpa: std.mem.Allocator, options: CompileOptions) !Result {
    var result: Result = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .pages = .empty,
        .edges = .empty,
        .diagnostics = .empty,
        .content_root = undefined,
        .out_dir = undefined,
        .ok = false,
        .failure = .none,
    };
    errdefer result.deinit();

    const retain = result.arena.allocator();
    result.content_root = try retain.dupe(u8, options.content_root);
    // Callers that publish IR set out_dir before publishArtifacts.
    result.out_dir = try retain.dupe(u8, "");

    logCompile(options.quiet, "boris: load  scanning {s}\n", .{options.content_root});

    // --- 1. Scan once -------------------------------------------------------
    var scan_list = page_mod.PageList.init(gpa, retain);
    defer scan_list.deinit();

    scanner.scan(io, .{ .content_root = options.content_root }, &scan_list) catch |err| switch (err) {
        error.ContentDirMissing => {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .EIO,
                .message = try std.fmt.allocPrint(retain, "content root \"{s}\" not found or not a directory", .{options.content_root}),
                .remediation = try retain.dupe(u8, "Create the content directory or pass --input=DIR"),
            });
            result.failure = .io;
            diag.sortDiagnostics(result.diagnostics.items);
            return result;
        },
        error.SymlinkRejected, error.SymlinkCycle => {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .EIO,
                .message = try std.fmt.allocPrint(retain, "content tree rejected symlink policy under \"{s}\": {s}", .{ options.content_root, @errorName(err) }),
                .remediation = try retain.dupe(u8, "Remove symlinks under the content root (v0.1 does not follow them)"),
            });
            result.failure = .content;
            diag.sortDiagnostics(result.diagnostics.items);
            return result;
        },
        error.InvalidPath => {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .EINVALIDPATH,
                .message = try retain.dupe(u8, "content path or entity id cannot be canonicalized"),
                .remediation = try retain.dupe(u8, "Rename paths so they have no empty, ., or .. segments"),
            });
            result.failure = .content;
            diag.sortDiagnostics(result.diagnostics.items);
            return result;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .EIO,
                .message = try std.fmt.allocPrint(retain, "discovery failed: {s}", .{@errorName(err)}),
                .remediation = try retain.dupe(u8, "Check filesystem permissions and path spelling"),
            });
            result.failure = .io;
            diag.sortDiagnostics(result.diagnostics.items);
            return result;
        },
    };

    logCompile(options.quiet, "boris: roll  parsing {d} page(s)\n", .{scan_list.len()});

    // --- 2–3. Read, parse, promote durable metadata only --------------------
    var db = page_mod.PageDb.init(gpa, retain);
    defer db.deinit();

    const cwd = Io.Dir.cwd();
    var content_dir = cwd.openDir(io, options.content_root, .{}) catch |err| {
        try result.diagnostics.append(gpa, .{
            .severity = .error_,
            .code = .EIO,
            .message = try std.fmt.allocPrint(retain, "failed to open content root \"{s}\": {s}", .{ options.content_root, @errorName(err) }),
            .remediation = try retain.dupe(u8, "Check that the content directory is readable"),
        });
        result.failure = .io;
        diag.sortDiagnostics(result.diagnostics.items);
        return result;
    };
    defer content_dir.close(io);

    // Per-file scratch: freed after each promote so no parser slice can leak.
    for (scan_list.items()) |disc| {
        const source = readFileAlloc(io, content_dir, disc.source_path, gpa) catch |err| {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .EIO,
                .message = try std.fmt.allocPrint(retain, "failed to read \"{s}\": {s}", .{ disc.source_path, @errorName(err) }),
                .remediation = try retain.dupe(u8, "Ensure the file is readable"),
                .source_path = disc.source_path,
                .line = 1,
                .column = 1,
            });
            continue;
        };
        defer gpa.free(source);

        const parsed = parser.parse(source);
        if (parsed.diagnostic) |pd| {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = parserCategoryToCode(pd.category),
                .message = try retain.dupe(u8, pd.message),
                .remediation = try retain.dupe(u8, "Fix the frontmatter or encoding for this file"),
                .source_path = disc.source_path,
                .line = pd.line,
                .column = pd.column,
            });
            // Skip durable page on hard parse failure.
            continue;
        }

        // Aside / component scan on the body (document order; hard errors).
        // Scratch arena owns tokenizer arrays; only diagnostics are retained.
        {
            var tok_arena = std.heap.ArenaAllocator.init(gpa);
            defer tok_arena.deinit();
            const tok = aside.tokenizeBody(parsed.doc.body, tok_arena.allocator()) catch |err| switch (err) {
                error.InvalidUtf8 => {
                    // Frontmatter path already UTF-8-gated; treat as content error.
                    try result.diagnostics.append(gpa, .{
                        .severity = .error_,
                        .code = .EINVALIDUTF8,
                        .message = try retain.dupe(u8, "body is not valid UTF-8"),
                        .remediation = try retain.dupe(u8, "Re-encode the file as UTF-8"),
                        .source_path = disc.source_path,
                        .line = 1,
                        .column = 1,
                    });
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (tok.hasErrors()) {
                // Map body-relative lines to full-source lines via body_offset.
                const body_line_base = countLinesUpTo(source, parsed.doc.body_offset);
                for (tok.diagnostics) |cd| {
                    const full_line = body_line_base + cd.line - 1;
                    const msg = if (cd.name.len > 0)
                        try std.fmt.allocPrint(retain, "{s}: {s}", .{ cd.name, cd.message })
                    else
                        try retain.dupe(u8, cd.message);
                    try result.diagnostics.append(gpa, .{
                        .severity = .error_,
                        .code = .ECOMPONENT,
                        .message = msg,
                        .remediation = try retain.dupe(u8, "Use only <Aside kind=\"…\" id=\"…\"> with allowlisted kind/id, outside fenced code"),
                        .source_path = disc.source_path,
                        .line = full_line,
                        .column = cd.column,
                    });
                }
                // Still promote so graph diagnostics can run; compile fails overall.
            }
        }

        // Resolve final entity id: frontmatter id: override or path-derived.
        const final_id: []const u8 = if (parsed.doc.meta.id) |override| override else disc.entity_id;

        // Promote copies all durable strings into retain before source free.
        try db.promote(disc, final_id, parsed.doc.meta, parsed.doc.body_offset);
    }

    // --- 4. Build provisional graph nodes from PageDb -----------------------
    try result.pages.ensureTotalCapacity(gpa, db.len());
    for (db.items()) |p| {
        try result.pages.append(gpa, .{
            .id = p.entity_id,
            .source_path = p.source_path,
            .title = p.title,
            .parent = p.parent,
            .status = statusName(p.status),
            .tags = p.tags,
            .body_offset = p.body_offset,
            .role = if (p.parent != null) .satellite else .trunk,
        });
    }

    // --- 5. Validate whole graph once (shared with RAG) ---------------------
    logCompile(options.quiet, "boris: ignite validating graph\n", .{});
    try graph_mod.validate(gpa, retain, result.pages.items, &result.diagnostics);
    diag.sortDiagnostics(result.diagnostics.items);

    const err_count = diag.countErrors(result.diagnostics.items);
    result.ok = err_count == 0;
    if (!result.ok) {
        result.failure = .content;
        result.graph_frozen = false;
        logCompile(options.quiet, "boris: content validation failed ({d} error(s))\n", .{err_count});
        return result;
    }

    // --- 6. Freeze only after clean validation ------------------------------
    const frozen = try graph_mod.freeze(gpa, result.pages.items);
    result.edges.deinit(gpa);
    result.edges = std.ArrayList(graph_mod.Edge).fromOwnedSlice(frozen.edges);
    result.graph_frozen = frozen.frozen;
    return result;
}

/// Full IR pipeline. Validates the whole graph before publishing artifacts.
/// Graph-dependent IR is published only when validation succeeds.
pub fn run(io: Io, gpa: std.mem.Allocator, options: Options) !Result {
    var result = try compile(io, gpa, .{
        .content_root = options.content_root,
        .quiet = options.quiet,
    });
    errdefer result.deinit();

    const retain = result.arena.allocator();
    result.out_dir = try retain.dupe(u8, options.out_dir);

    if (result.ok) {
        log(options, "boris: ignite emitting IR → {s}\n", .{options.out_dir});
    }
    try publishArtifacts(io, gpa, &result);
    if (result.ok) {
        log(options, "boris: reset done ({d} page(s))\n", .{result.pages.items.len});
    }
    return result;
}

/// Print diagnostics to stderr (text form). Does not change artifacts.
pub fn printDiagnostics(gpa: std.mem.Allocator, diags: []const diag.Diagnostic) !void {
    for (diags) |d| {
        const line = try diag.formatText(d, gpa);
        defer gpa.free(line);
        std.debug.print("{s}\n", .{line});
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectCode(result: *const Result, code: diag.Code) !void {
    for (result.diagnostics.items) |d| {
        if (d.code == code) return;
    }
    return error.TestExpectedDiagnostic;
}

fn hasCode(diags: []const diag.Diagnostic, code: diag.Code) bool {
    for (diags) |d| {
        if (d.code == code) return true;
    }
    return false;
}

fn outRel(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn fileExists(io: Io, dir_path: []const u8, name: []const u8) bool {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    _ = dir.statFile(io, name, .{}) catch return false;
    return true;
}

fn readOutFile(io: Io, gpa: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    return try readFileAlloc(io, dir, name, gpa);
}

test "e2e valid fixture builds three JSON artifacts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "valid-out");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expect(result.graph_frozen);
    try std.testing.expect(result.published_graph_ir);
    try std.testing.expectEqual(@as(usize, 3), result.pages.items.len);

    try std.testing.expect(fileExists(io, out, "manifest.json"));
    try std.testing.expect(fileExists(io, out, "graph.json"));
    try std.testing.expect(fileExists(io, out, "build-report.json"));

    // Sorted by id after freeze: guides/intro, guides/intro-tips, index
    try std.testing.expectEqualStrings("guides/intro", result.pages.items[0].id);
    try std.testing.expect(result.pages.items[0].role == .trunk);
    try std.testing.expectEqualStrings("guides/intro-tips", result.pages.items[1].id);
    try std.testing.expect(result.pages.items[1].role == .satellite);
    try std.testing.expectEqualStrings("guides/intro", result.pages.items[1].parent.?);
    try std.testing.expect(result.pages.items[1].parent_index.? == 0);

    // Parse generated JSON with Zig's JSON parser.
    const man_bytes = try readOutFile(io, gpa, out, "manifest.json");
    defer gpa.free(man_bytes);
    var man_parsed = try std.json.parseFromSlice(std.json.Value, gpa, man_bytes, .{});
    defer man_parsed.deinit();
    try std.testing.expectEqualStrings("0.1.0", man_parsed.value.object.get("schemaVersion").?.string);
    try std.testing.expectEqualStrings(compiler_id, man_parsed.value.object.get("compiler").?.string);
    try std.testing.expectEqual(@as(i64, 3), man_parsed.value.object.get("pageCount").?.integer);

    const graph_bytes = try readOutFile(io, gpa, out, "graph.json");
    defer gpa.free(graph_bytes);
    var graph_parsed = try std.json.parseFromSlice(std.json.Value, gpa, graph_bytes, .{});
    defer graph_parsed.deinit();
    try std.testing.expect(graph_parsed.value.object.get("frozen").?.bool);
    try std.testing.expectEqual(@as(usize, 3), graph_parsed.value.object.get("nodes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph_parsed.value.object.get("edges").?.array.items.len);

    // Deterministic node order by id.
    const nodes = graph_parsed.value.object.get("nodes").?.array.items;
    try std.testing.expectEqualStrings("guides/intro", nodes[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("guides/intro-tips", nodes[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("index", nodes[2].object.get("id").?.string);

    // Graph-aware nav (from frozen parent_index only).
    const nav = graph_parsed.value.object.get("nav").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), nav.len);
    // guides/intro (trunk): breadcrumb [0], children [1], siblings []
    try std.testing.expectEqualStrings("guides/intro", nav[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), nav[0].object.get("breadcrumb").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), nav[0].object.get("breadcrumb").?.array.items[0].integer);
    try std.testing.expectEqual(@as(usize, 1), nav[0].object.get("children").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), nav[0].object.get("children").?.array.items[0].integer);
    try std.testing.expectEqual(@as(usize, 0), nav[0].object.get("siblings").?.array.items.len);
    // guides/intro-tips (satellite): breadcrumb [0,1], children [], siblings []
    try std.testing.expectEqualStrings("guides/intro-tips", nav[1].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 2), nav[1].object.get("breadcrumb").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), nav[1].object.get("breadcrumb").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 1), nav[1].object.get("breadcrumb").?.array.items[1].integer);
    try std.testing.expectEqual(@as(usize, 0), nav[1].object.get("children").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), nav[1].object.get("siblings").?.array.items.len);
    // index (lonely trunk)
    try std.testing.expectEqualStrings("index", nav[2].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 1), nav[2].object.get("breadcrumb").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 2), nav[2].object.get("breadcrumb").?.array.items[0].integer);
    try std.testing.expectEqual(@as(usize, 0), nav[2].object.get("children").?.array.items.len);

    // Root key order: schemaVersion, frozen, nodes, edges, nav
    const k_schema = std.mem.indexOf(u8, graph_bytes, "\"schemaVersion\"").?;
    const k_frozen = std.mem.indexOf(u8, graph_bytes, "\"frozen\"").?;
    const k_nodes = std.mem.indexOf(u8, graph_bytes, "\"nodes\"").?;
    const k_edges = std.mem.indexOf(u8, graph_bytes, "\"edges\"").?;
    const k_nav = std.mem.indexOf(u8, graph_bytes, "\"nav\"").?;
    try std.testing.expect(k_schema < k_frozen and k_frozen < k_nodes and k_nodes < k_edges and k_edges < k_nav);

    // No absolute paths in outputs.
    try std.testing.expect(std.mem.indexOf(u8, man_bytes, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, man_bytes, "/tmp/") == null);
    try std.testing.expect(std.mem.indexOf(u8, graph_bytes, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, graph_bytes, ".boris-stage") == null);
}

test "duplicate id fails and does not publish graph-dependent IR" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "dup-out");
    defer gpa.free(out);

    // Seed a prior "successful" artifact set that must be cleared on failure.
    try Io.Dir.cwd().createDirPath(io, out);
    {
        var d = try Io.Dir.cwd().openDir(io, out, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = "manifest.json", .data = "{\"stale\":true}\n" });
        try d.writeFile(io, .{ .sub_path = "graph.json", .data = "{\"frozen\":true}\n" });
    }

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/duplicate-ids/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();

    try std.testing.expect(!result.ok);
    try std.testing.expect(!result.graph_frozen);
    try std.testing.expect(!result.published_graph_ir);
    try expectCode(&result, .EDUPLICATEID);

    try std.testing.expect(!fileExists(io, out, "manifest.json"));
    try std.testing.expect(!fileExists(io, out, "graph.json"));
    try std.testing.expect(fileExists(io, out, "build-report.json"));

    const report = try readOutFile(io, gpa, out, "build-report.json");
    defer gpa.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("ok").?.bool);
}

test "invalid graph fixtures emit stable categories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Case = struct {
        root: []const u8,
        code: diag.Code,
    };
    const dir_cases = [_]Case{
        .{ .root = "docs/contracts/fixtures/missing-parent/content", .code = .EPARENTMISSING },
        .{ .root = "docs/contracts/fixtures/self-parent/content", .code = .EPARENTSELF },
        .{ .root = "docs/contracts/fixtures/satellite-of-satellite/content", .code = .EPARENTNOTTRUNK },
        .{ .root = "docs/contracts/fixtures/cycles/content", .code = .EPARENTCYCLE },
        .{ .root = "docs/contracts/fixtures/longer-cycle/content", .code = .EPARENTCYCLE },
        .{ .root = "fixtures/content/invalid/duplicate-id", .code = .EDUPLICATEID },
        .{ .root = "fixtures/content/invalid/cycle", .code = .EPARENTCYCLE },
        .{ .root = "fixtures/content/invalid/satellite-of-satellite", .code = .EPARENTNOTTRUNK },
    };

    for (dir_cases, 0..) |c, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/inv-{d}", .{ tmp.sub_path, i });
        defer gpa.free(out);

        var result = try run(io, gpa, .{
            .content_root = c.root,
            .out_dir = out,
            .quiet = true,
        });
        defer result.deinit();

        try std.testing.expect(!result.ok);
        try std.testing.expect(!result.published_graph_ir);
        try expectCode(&result, c.code);
        try std.testing.expect(!fileExists(io, out, "manifest.json"));
        try std.testing.expect(!fileExists(io, out, "graph.json"));
    }
}

test "determinism: two builds produce byte-identical IR" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_a = try outRel(gpa, &tmp, "det-a");
    defer gpa.free(out_a);
    const out_b = try outRel(gpa, &tmp, "det-b");
    defer gpa.free(out_b);

    // Same content_root string; distinct out dirs.
    const content = "docs/contracts/fixtures/valid/content";

    var ra = try run(io, gpa, .{ .content_root = content, .out_dir = out_a, .quiet = true });
    defer ra.deinit();
    var rb = try run(io, gpa, .{ .content_root = content, .out_dir = out_b, .quiet = true });
    defer rb.deinit();

    try std.testing.expect(ra.ok and rb.ok);

    const names = [_][]const u8{ "manifest.json", "graph.json" };
    for (names) |name| {
        const a = try readOutFile(io, gpa, out_a, name);
        defer gpa.free(a);
        const b = try readOutFile(io, gpa, out_b, name);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }

    // build-report differs only in outDir when paths differ — compare with same outDir via renderer.
    const rep_a = try renderBuildReport(gpa, &ra);
    defer gpa.free(rep_a);
    // Force same outDir for comparison of non-path identity: re-render rb with swapped out.
    const saved = rb.out_dir;
    rb.out_dir = ra.out_dir;
    const rep_b = try renderBuildReport(gpa, &rb);
    rb.out_dir = saved;
    defer gpa.free(rep_b);
    try std.testing.expectEqualStrings(rep_a, rep_b);
}

test "render twice is byte-identical (no ambient entropy)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "render-twice");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);

    const g1 = try renderGraph(gpa, &result);
    defer gpa.free(g1);
    const g2 = try renderGraph(gpa, &result);
    defer gpa.free(g2);
    try std.testing.expectEqualStrings(g1, g2);

    const m1 = try renderManifest(gpa, &result);
    defer gpa.free(m1);
    const m2 = try renderManifest(gpa, &result);
    defer gpa.free(m2);
    try std.testing.expectEqualStrings(m1, m2);
}

test "fixtures/content/valid builds and orders by id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "fix-valid");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "fixtures/content/valid",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);
    // empty-no-fm, nested/deep/page, satellite-child (parent home), trunk-root (id home)
    try std.testing.expectEqual(@as(usize, 4), result.pages.items.len);
    // Sorted by id: empty-no-fm, home (from trunk-root id:), nested/deep/page, satellite-child
    try std.testing.expectEqualStrings("empty-no-fm", result.pages.items[0].id);
    try std.testing.expectEqualStrings("home", result.pages.items[1].id);
    try std.testing.expect(result.pages.items[1].role == .trunk);
    try std.testing.expectEqualStrings("nested/deep/page", result.pages.items[2].id);
    try std.testing.expectEqualStrings("satellite-child", result.pages.items[3].id);
    try std.testing.expect(result.pages.items[3].role == .satellite);
}

test "promoted metadata survives source buffer free (via PageDb unit + pipeline)" {
    // Covered primarily by page.zig PageDb.promote test; pipeline re-uses promote.
    // Here: run valid content and assert title strings are still readable after run.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "promote-live");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("Introduction", result.pages.items[0].title.?);
    try std.testing.expectEqualStrings("Intro Tips", result.pages.items[1].title.?);
    try std.testing.expectEqualStrings("Home", result.pages.items[2].title.?);
}

test "parser error fixtures map to EFRONTMATTER / EINVALIDPATH" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cases = [_]struct { root: []const u8, code: diag.Code }{
        .{ .root = "docs/contracts/fixtures/invalid-status/content", .code = .EFRONTMATTER },
        .{ .root = "docs/contracts/fixtures/invalid-tags/content", .code = .EFRONTMATTER },
        .{ .root = "docs/contracts/fixtures/invalid-id/content", .code = .EINVALIDPATH },
        .{ .root = "docs/contracts/fixtures/unsupported-syntax/content", .code = .EFRONTMATTER },
        .{ .root = "docs/contracts/fixtures/duplicate-key/content", .code = .EFRONTMATTER },
        .{ .root = "docs/contracts/fixtures/malformed-frontmatter/content", .code = .EFRONTMATTER },
    };

    for (cases, 0..) |c, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/parse-{d}", .{ tmp.sub_path, i });
        defer gpa.free(out);
        var result = try run(io, gpa, .{ .content_root = c.root, .out_dir = out, .quiet = true });
        defer result.deinit();
        try std.testing.expect(!result.ok);
        try expectCode(&result, c.code);
        try std.testing.expect(!result.published_graph_ir);
    }
}

test "missing content root is EIO and does not publish graph IR" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "noroot");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/__no_such_root__",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.failure == .io);
    try expectCode(&result, .EIO);
    try std.testing.expect(!fileExists(io, out, "manifest.json"));
    try std.testing.expect(!fileExists(io, out, "graph.json"));
}

test "golden expected IR shape for valid fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "golden");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);

    const man = try renderManifest(gpa, &result);
    defer gpa.free(man);
    // Field presence / order markers (stable key order).
    const man_keys = [_][]const u8{
        "\"schemaVersion\"", "\"compiler\"", "\"contentRoot\"", "\"pageCount\"", "\"pages\"",
    };
    var pos: usize = 0;
    for (man_keys) |k| {
        const found = std.mem.indexOfPos(u8, man, pos, k) orelse return error.MissingKey;
        pos = found + k.len;
    }

    const graph = try renderGraph(gpa, &result);
    defer gpa.free(graph);
    try std.testing.expect(std.mem.indexOf(u8, graph, "\"frozen\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "\"bodyOffset\": 67") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "\"bodyOffset\": 81") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "\"bodyOffset\": 51") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "\"tags\": [\"guide\", \"intro\"]") != null);
}
