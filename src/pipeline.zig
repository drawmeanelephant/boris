//! Content compiler pipeline:
//!   discover → parse frontmatter → ids → graph resolve → freeze
//!   → emit manifest.json, graph.json, build-report.json
//!
//! No HTML, layouts, Apex, components, or RAG.

const std = @import("std");
const Io = std.Io;
const pathutil = @import("pathutil.zig");
const diag = @import("diag.zig");
const discover_mod = @import("discover.zig");
const frontmatter = @import("frontmatter.zig");
const graph_mod = @import("graph.zig");
const json_out = @import("json_out.zig");
const page_mod = @import("page.zig");
const rag = @import("rag.zig");

pub const schema_version = "0.1.0";
pub const compiler_id = "boris/0.1.1";

pub const Options = struct {
    content_root: []const u8 = "content",
    out_dir: []const u8 = ".boris",
    quiet: bool = false,
};

pub const PageEntry = graph_mod.Node;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    pages: std.ArrayList(PageEntry),
    edges: std.ArrayList(graph_mod.Edge),
    diagnostics: std.ArrayList(diag.Diagnostic),
    content_root: []const u8,
    out_dir: []const u8,
    ok: bool,
    graph_frozen: bool = false,

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

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeJsonFiles(io: Io, gpa: std.mem.Allocator, result: *const Result) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, result.out_dir);
    var out = try cwd.openDir(io, result.out_dir, .{});
    defer out.close(io);

    const manifest = try renderManifest(gpa, result);
    defer gpa.free(manifest);
    const graph_json = try renderGraph(gpa, result);
    defer gpa.free(graph_json);
    const report = try renderBuildReport(gpa, result);
    defer gpa.free(report);

    try out.writeFile(io, .{ .sub_path = "manifest.json", .data = manifest });
    try out.writeFile(io, .{ .sub_path = "graph.json", .data = graph_json });
    try out.writeFile(io, .{ .sub_path = "build-report.json", .data = report });
}

fn writeOptionalString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| {
        try json_out.writeString(buf, gpa, v);
    } else {
        try json_out.writeNull(buf, gpa);
    }
}

fn writeOptionalU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: ?u32) !void {
    try json_out.writeOptionalU32(buf, gpa, v);
}

/// Emit `E_ENTITY_CASE_COLLISION` when two page ids differ only in letter case
/// (after path derivation and optional frontmatter `id:` override).
fn diagnoseEntityIdCaseCollisions(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    pages: []const PageEntry,
    diags: *std.ArrayList(diag.Diagnostic),
) !void {
    var i: usize = 0;
    while (i < pages.len) : (i += 1) {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (!pathutil.pathsDifferOnlyInCase(pages[i].id, pages[j].id)) continue;
            const msg = try std.fmt.allocPrint(
                retain,
                "entity ids differ only in case: \"{s}\" ({s}) and \"{s}\" ({s})",
                .{ pages[i].id, pages[i].source_path, pages[j].id, pages[j].source_path },
            );
            try diags.append(list_gpa, .{
                .severity = .error_,
                .code = .E_ENTITY_CASE_COLLISION,
                .message = msg,
                .remediation = try retain.dupe(u8, "Rename a file or id: override so entity ids are unique ignoring case"),
                .source_path = pages[i].source_path,
                .line = 1,
                .column = 1,
                .id = pages[i].id,
            });
            break;
        }
    }
}

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

pub fn renderGraph(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

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
        try writeOptionalU32(&buf, gpa, p.parent_index);
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

/// Full pipeline. Always aggregates diagnostics; emits artifacts even on failure.
pub fn run(io: Io, gpa: std.mem.Allocator, options: Options) !Result {
    var result: Result = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .pages = .empty,
        .edges = .empty,
        .diagnostics = .empty,
        .content_root = undefined,
        .out_dir = undefined,
        .ok = false,
    };
    errdefer result.deinit();

    const retain = result.arena.allocator();
    result.content_root = try retain.dupe(u8, options.content_root);
    result.out_dir = try retain.dupe(u8, options.out_dir);

    var found: std.ArrayList(discover_mod.Found) = .empty;
    defer found.deinit(gpa);

    var content_missing = false;
    discover_mod.discover(io, gpa, retain, .{
        .content_root = options.content_root,
    }, &found, &result.diagnostics) catch |err| switch (err) {
        error.ContentDirMissing => {
            content_missing = true;
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .E_CONTENT_ROOT,
                .message = try std.fmt.allocPrint(retain, "content root \"{s}\" not found or not a directory", .{options.content_root}),
                .remediation = try retain.dupe(u8, "Create the content directory or pass --input=DIR"),
            });
        },
        else => {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .E_INTERNAL,
                .message = try std.fmt.allocPrint(retain, "discovery failed: {s}", .{@errorName(err)}),
                .remediation = try retain.dupe(u8, "Check filesystem permissions and path spelling"),
            });
            content_missing = true;
        },
    };

    if (!content_missing) {
        const cwd = Io.Dir.cwd();
        var content_dir = try cwd.openDir(io, options.content_root, .{});
        defer content_dir.close(io);

        // Scratch arena for file bytes (not retained after parse).
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();

        for (found.items) |f| {
            _ = scratch.reset(.free_all);
            const sa = scratch.allocator();

            const source = readFileAlloc(io, content_dir, f.source_path, sa) catch |err| {
                try result.diagnostics.append(gpa, .{
                    .severity = .error_,
                    .code = .E_INTERNAL,
                    .message = try std.fmt.allocPrint(retain, "failed to read \"{s}\": {s}", .{ f.source_path, @errorName(err) }),
                    .remediation = try retain.dupe(u8, "Ensure the file is readable"),
                    .source_path = f.source_path,
                    .line = 1,
                    .column = 1,
                });
                continue;
            };

            const meta = try frontmatter.parse(source, f.source_path, retain, gpa, &result.diagnostics);

            // Path-derived id from discovery (`pathutil.canonicalEntityId`); case-preserving.
            const path_id = f.entity_id;

            // Frontmatter id/parent: normalize separators only; preserve case.
            // Case-insensitive collisions are diagnosed after the full set is built.
            const id = if (meta.id) |override|
                pathutil.normalizeEntityId(retain, override) catch |err| switch (err) {
                    error.IdTooLong => {
                        try result.diagnostics.append(gpa, .{
                            .severity = .error_,
                            .code = .E_FRONTMATTER_VALUE,
                            .message = try std.fmt.allocPrint(retain, "id exceeds maximum length of {d} bytes", .{page_mod.max_entity_id_bytes}),
                            .remediation = try retain.dupe(u8, "Shorten the id to at most 255 bytes"),
                            .source_path = f.source_path,
                            .line = 1,
                            .column = 1,
                        });
                        continue;
                    },
                    error.EmptyId, error.IllegalSegment, error.AbsolutePath, error.UnsupportedExtension, error.EmptyPath => {
                        try result.diagnostics.append(gpa, .{
                            .severity = .error_,
                            .code = .E_FRONTMATTER_VALUE,
                            .message = try std.fmt.allocPrint(retain, "id is not a valid canonical document id: {s}", .{@errorName(err)}),
                            .remediation = try retain.dupe(u8, "Use slash-separated segments without ., .., backslashes, or whitespace"),
                            .source_path = f.source_path,
                            .line = 1,
                            .column = 1,
                        });
                        continue;
                    },
                    else => return err,
                }
            else
                path_id;
            const parent: ?[]const u8 = if (meta.parent) |p|
                pathutil.normalizeEntityId(retain, p) catch |err| switch (err) {
                    error.IdTooLong => {
                        try result.diagnostics.append(gpa, .{
                            .severity = .error_,
                            .code = .E_FRONTMATTER_VALUE,
                            .message = try std.fmt.allocPrint(retain, "parent exceeds maximum length of {d} bytes", .{page_mod.max_entity_id_bytes}),
                            .remediation = try retain.dupe(u8, "Shorten the parent id to at most 255 bytes"),
                            .source_path = f.source_path,
                            .line = 1,
                            .column = 1,
                        });
                        continue;
                    },
                    error.EmptyId, error.IllegalSegment, error.AbsolutePath, error.UnsupportedExtension, error.EmptyPath => {
                        try result.diagnostics.append(gpa, .{
                            .severity = .error_,
                            .code = .E_FRONTMATTER_VALUE,
                            .message = try std.fmt.allocPrint(retain, "parent is not a valid canonical document id: {s}", .{@errorName(err)}),
                            .remediation = try retain.dupe(u8, "Use the parent document id, not a file path or URL"),
                            .source_path = f.source_path,
                            .line = 1,
                            .column = 1,
                        });
                        continue;
                    },
                    else => return err,
                }
            else
                null;
            const status_str: ?[]const u8 = if (meta.status) |st| st.name() else null;

            try result.pages.append(gpa, .{
                .id = id,
                .source_path = f.source_path,
                .title = meta.title,
                .parent = parent,
                .status = status_str,
                .tags = meta.tags,
                .body_offset = meta.body_offset,
                .role = .trunk,
            });
        }

        // Case-insensitive entity-id collisions after id: overrides (path-level
        // collisions already diagnosed during discover).
        try diagnoseEntityIdCaseCollisions(gpa, retain, result.pages.items, &result.diagnostics);

        // Single shared graph entry (dups then topology) — same as RAG export.
        try graph_mod.validate(gpa, retain, result.pages.items, &result.diagnostics);

        const frozen = try graph_mod.freeze(gpa, result.pages.items);
        // freeze reorders pages in place and returns edges owned by gpa list → transfer
        result.edges.deinit(gpa);
        result.edges = std.ArrayList(graph_mod.Edge).fromOwnedSlice(frozen.edges);
        result.graph_frozen = frozen.frozen;
    }

    diag.sortDiagnostics(result.diagnostics.items);
    result.ok = diag.countErrors(result.diagnostics.items) == 0;

    try writeJsonFiles(io, gpa, &result);
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fixture valid has trunk and satellite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/valid-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/valid/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expect(result.graph_frozen);
    try std.testing.expectEqual(@as(usize, 3), result.pages.items.len);

    // Sorted by id: guides/intro, guides/intro-tips, index
    try std.testing.expectEqualStrings("guides/intro", result.pages.items[0].id);
    try std.testing.expect(result.pages.items[0].role == .trunk);
    try std.testing.expectEqualStrings("guides/intro-tips", result.pages.items[1].id);
    try std.testing.expect(result.pages.items[1].role == .satellite);
    try std.testing.expectEqualStrings("guides/intro", result.pages.items[1].parent.?);
    try std.testing.expect(result.pages.items[1].parent_index.? == 0);

    const g1 = try renderGraph(gpa, &result);
    defer gpa.free(g1);
    const g2 = try renderGraph(gpa, &result);
    defer gpa.free(g2);
    try std.testing.expectEqualStrings(g1, g2);
}

test "fixture missing parent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/miss-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/missing-parent/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    var saw = false;
    for (result.diagnostics.items) |d| {
        if (d.code == .E_PARENT_MISSING) saw = true;
    }
    try std.testing.expect(saw);
}

test "fixture cycles" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cyc-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/cycles/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    var saw = false;
    for (result.diagnostics.items) |d| {
        if (d.code == .E_PARENT_CYCLE) saw = true;
    }
    try std.testing.expect(saw);
}

test "fixture longer cycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/long-cyc-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/longer-cycle/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try expectCode(&result, .E_PARENT_CYCLE);
}

test "fixture satellite-of-satellite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sos-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/satellite-of-satellite/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try expectCode(&result, .E_PARENT_NOT_TRUNK);
}

test "fixture malformed frontmatter aggregates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mal-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/malformed-frontmatter/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    // Multiple files / rules → more than one diagnostic
    try std.testing.expect(result.diagnostics.items.len >= 2);
}

test "fixture duplicate ids via override" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/dup-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/duplicate-ids/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    var saw = false;
    for (result.diagnostics.items) |d| {
        if (d.code == .E_DUP_ID) saw = true;
    }
    try std.testing.expect(saw);
}

test "fixture self parent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/self-out", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/self-parent/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    var saw = false;
    for (result.diagnostics.items) |d| {
        if (d.code == .E_PARENT_SELF) saw = true;
    }
    try std.testing.expect(saw);
}

test "missing content root still writes report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/noroot", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/__no_such_root__",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.diagnostics.items[0].code == .E_CONTENT_ROOT);
}

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

// Pipeline IR path and RAG path must surface the same graph diagnostic class
// for each invalid graph fixture (shared `graph.validate` entry).
test "pipeline and rag share graph diagnostic class on fixtures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Case = struct {
        root: []const u8,
        code: diag.Code,
        /// When true, pipeline must succeed (ok) and RAG must also accept the graph.
        ok: bool = false,
    };
    const cases = [_]Case{
        .{ .root = "docs/contracts/fixtures/valid/content", .code = .E_INTERNAL, .ok = true },
        .{ .root = "docs/contracts/fixtures/missing-parent/content", .code = .E_PARENT_MISSING },
        .{ .root = "docs/contracts/fixtures/self-parent/content", .code = .E_PARENT_SELF },
        .{ .root = "docs/contracts/fixtures/cycles/content", .code = .E_PARENT_CYCLE },
        .{ .root = "docs/contracts/fixtures/longer-cycle/content", .code = .E_PARENT_CYCLE },
        .{ .root = "docs/contracts/fixtures/satellite-of-satellite/content", .code = .E_PARENT_NOT_TRUNK },
        .{ .root = "docs/contracts/fixtures/duplicate-ids/content", .code = .E_DUP_ID },
    };

    for (cases, 0..) |c, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/dual-{d}", .{ tmp.sub_path, i });
        defer gpa.free(out_rel);
        try Io.Dir.cwd().createDirPath(io, out_rel);

        // --- IR / normal build path ---
        var pipe = try run(io, gpa, .{
            .content_root = c.root,
            .out_dir = out_rel,
            .quiet = true,
        });
        defer pipe.deinit();

        // --- RAG path (same graph.validate, no corpus write required) ---
        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        const retain = retain_arena.allocator();
        var rag_diags: std.ArrayList(diag.Diagnostic) = .empty;
        defer rag_diags.deinit(gpa);
        const rag_result = rag.validateContentGraph(io, gpa, retain, c.root, &rag_diags);

        if (c.ok) {
            try std.testing.expect(pipe.ok);
            try rag_result;
            try std.testing.expectEqual(@as(usize, 0), diag.countErrors(rag_diags.items));
        } else {
            try std.testing.expect(!pipe.ok);
            try expectCode(&pipe, c.code);
            try std.testing.expectError(error.GraphValidationFailed, rag_result);
            try std.testing.expect(hasCode(rag_diags.items, c.code));
        }
    }
}

test "fixture invalid status tags id unsupported dup-key aggregate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cases = [_]struct { root: []const u8, code: diag.Code }{
        .{ .root = "docs/contracts/fixtures/invalid-status/content", .code = .E_FRONTMATTER_VALUE },
        .{ .root = "docs/contracts/fixtures/invalid-tags/content", .code = .E_FRONTMATTER_VALUE },
        .{ .root = "docs/contracts/fixtures/invalid-id/content", .code = .E_FRONTMATTER_VALUE },
        .{ .root = "docs/contracts/fixtures/unsupported-syntax/content", .code = .E_FRONTMATTER },
        .{ .root = "docs/contracts/fixtures/duplicate-key/content", .code = .E_FRONTMATTER_DUP_KEY },
    };

    for (cases, 0..) |c, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/case-{d}", .{ tmp.sub_path, i });
        defer gpa.free(out_rel);
        try Io.Dir.cwd().createDirPath(io, out_rel);
        var result = try run(io, gpa, .{ .content_root = c.root, .out_dir = out_rel, .quiet = true });
        defer result.deinit();
        try std.testing.expect(!result.ok);
        try expectCode(&result, c.code);
    }

    // Aggregate: multiple independent codes
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/agg", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);
    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/aggregate/content",
        .out_dir = out_rel,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try expectCode(&result, .E_PARENT_MISSING);
    try expectCode(&result, .E_PARENT_SELF);
    try expectCode(&result, .E_FRONTMATTER);
    try std.testing.expect(result.diagnostics.items.len >= 3);
}
