//! Content compiler pipeline (Feature 8):
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
const ir_emit = @import("ir_emit.zig");
const page_mod = @import("page.zig");
const include_mod = @import("include.zig");
const wikilink = @import("wikilink.zig");
const dependency = @import("dependency.zig");
const identity = @import("identity.zig");
const textile = @import("textile.zig");

pub const schema_version = "0.2.0";
pub const compiler_id = "boris/0.4.0";
pub const semantic_schema_version = "0.3.0";
pub const semantic_compiler_id = "boris/0.4.0+semantic-relations";
/// Product version string (package / catalog_meta.boris_version).
pub const boris_version = "0.4.0";

pub const Options = struct {
    content_root: []const u8 = "content",
    out_dir: []const u8 = ".boris",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
};

/// Shared load options for IR and RAG (no output paths).
pub const CompileOptions = struct {
    content_root: []const u8 = "content",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
};

pub const PageEntry = graph_mod.Node;

pub const EndpointType = enum {
    page,
    source,

    pub fn name(self: EndpointType) []const u8 {
        return @tagName(self);
    }
};

pub const Endpoint = struct {
    type: EndpointType,
    value: []const u8,
};

pub const DependencyEdge = struct {
    from: Endpoint,
    to: Endpoint,
    kind: []const u8,
};

pub const ReverseEntry = struct {
    target: Endpoint,
    incoming_edges: []const u32,
};

/// Pipeline failure class for CLI exit mapping.
pub const FailureKind = enum {
    none,
    content,
    io,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    pages: std.ArrayList(PageEntry),
    edges: std.ArrayList(DependencyEdge),
    reverse_index: std.ArrayList(ReverseEntry),
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
        for (self.reverse_index.items) |entry| gpa.free(entry.incoming_edges);
        self.reverse_index.deinit(gpa);
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

fn endpointLess(a: Endpoint, b: Endpoint) bool {
    const type_order = std.mem.order(u8, a.type.name(), b.type.name());
    if (type_order != .eq) return type_order == .lt;
    return std.mem.order(u8, a.value, b.value) == .lt;
}

fn endpointEql(a: Endpoint, b: Endpoint) bool {
    return a.type == b.type and std.mem.eql(u8, a.value, b.value);
}

fn edgeLess(_: void, a: DependencyEdge, b: DependencyEdge) bool {
    if (!endpointEql(a.from, b.from)) return endpointLess(a.from, b.from);
    if (!endpointEql(a.to, b.to)) return endpointLess(a.to, b.to);
    return std.mem.order(u8, a.kind, b.kind) == .lt;
}

fn edgeEql(a: DependencyEdge, b: DependencyEdge) bool {
    return endpointEql(a.from, b.from) and endpointEql(a.to, b.to) and
        std.mem.eql(u8, a.kind, b.kind);
}

fn findPage(nodes: []const PageEntry, id: []const u8) bool {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.id, id)) return true;
    }
    return false;
}

fn validateSemanticRelations(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    nodes: []const PageEntry,
    diagnostics: *std.ArrayList(diag.Diagnostic),
) !void {
    for (nodes) |node| {
        for (node.semantic_relations, 0..) |relation, relation_index| {
            if (std.mem.eql(u8, node.id, relation.target)) {
                try diagnostics.append(list_gpa, .{
                    .severity = .error_,
                    .code = .ERELATIONSELF,
                    .message = try std.fmt.allocPrint(retain, "semantic relation {s} targets its source page", .{relation.kind.name()}),
                    .remediation = try retain.dupe(u8, "Choose a different target page"),
                    .source_path = node.source_path,
                    .line = 1,
                    .column = 1,
                    .id = node.id,
                });
                continue;
            }
            if (!findPage(nodes, relation.target)) {
                try diagnostics.append(list_gpa, .{
                    .severity = .error_,
                    .code = .ERELATIONMISSING,
                    .message = try std.fmt.allocPrint(retain, "semantic relation {s} targets missing page \"{s}\"", .{ relation.kind.name(), relation.target }),
                    .remediation = try retain.dupe(u8, "Create the target page or remove the relation"),
                    .source_path = node.source_path,
                    .line = 1,
                    .column = 1,
                    .id = node.id,
                });
            }
            var prior: usize = 0;
            while (prior < relation_index) : (prior += 1) {
                const earlier = node.semantic_relations[prior];
                if (earlier.kind == relation.kind and std.mem.eql(u8, earlier.target, relation.target)) {
                    try diagnostics.append(list_gpa, .{
                        .severity = .error_,
                        .code = .ERELATIONDUPLICATE,
                        .message = try std.fmt.allocPrint(retain, "duplicate semantic relation {s} -> \"{s}\"", .{ relation.kind.name(), relation.target }),
                        .remediation = try retain.dupe(u8, "Keep each semantic relation tuple only once"),
                        .source_path = node.source_path,
                        .line = 1,
                        .column = 1,
                        .id = node.id,
                    });
                    break;
                }
            }
        }
    }
}

const DependencyResolver = struct {
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    content_dir: Io.Dir,
    nodes: []const PageEntry,
    edges: *std.ArrayList(DependencyEdge),
    diagnostics: *std.ArrayList(diag.Diagnostic),
    scanned_sources: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *DependencyResolver) void {
        self.scanned_sources.deinit(self.gpa);
    }

    fn appendEdge(self: *DependencyResolver, from: Endpoint, to: Endpoint, kind: []const u8) !void {
        try self.edges.append(self.gpa, .{
            .from = .{ .type = from.type, .value = try self.retain.dupe(u8, from.value) },
            .to = .{ .type = to.type, .value = try self.retain.dupe(u8, to.value) },
            .kind = kind,
        });
    }

    fn scanWiki(self: *DependencyResolver, body: []const u8, locus: []const u8, from: Endpoint) !void {
        var hits: std.ArrayList(wikilink.WikiHit) = .empty;
        defer hits.deinit(self.gpa);
        var fail: wikilink.FailInfo = .{};
        wikilink.scanWikiLinks(body, self.gpa, &hits, &fail, locus) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.diagnostics.append(self.gpa, try wikilink.makeDiagnostic(self.retain, err, locus, fail));
                return;
            },
        };

        for (hits.items) |hit| {
            if (!findPage(self.nodes, hit.entity_id)) {
                fail.set(hit.line, hit.column, hit.entity_id, locus);
                try self.diagnostics.append(self.gpa, try wikilink.makeDiagnostic(
                    self.retain,
                    error.ReferenceMissing,
                    locus,
                    fail,
                ));
                continue;
            }
            try self.appendEdge(from, .{ .type = .page, .value = hit.entity_id }, "reference");
        }
    }

    fn scanIncludes(
        self: *DependencyResolver,
        body: []const u8,
        locus: []const u8,
        from: Endpoint,
        stack: *std.ArrayList([]const u8),
        depth: usize,
    ) !void {
        var hits: std.ArrayList(include_mod.ScanHit) = .empty;
        defer hits.deinit(self.gpa);
        var fail: include_mod.FailInfo = .{};
        include_mod.scanIncludeDirectives(body, self.gpa, &hits, &fail, locus) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.diagnostics.append(self.gpa, try include_mod.makeDiagnostic(self.retain, err, locus, fail));
                return;
            },
        };

        for (hits.items) |hit| {
            try self.appendEdge(from, .{ .type = .source, .value = hit.path }, "include");

            var in_stack = false;
            for (stack.items) |path| {
                if (std.mem.eql(u8, path, hit.path)) {
                    in_stack = true;
                    break;
                }
            }
            if (in_stack) {
                fail.set(hit.line, hit.column, hit.path, locus);
                try self.diagnostics.append(self.gpa, try include_mod.makeDiagnostic(
                    self.retain,
                    error.IncludeCycle,
                    locus,
                    fail,
                ));
                continue;
            }
            if (depth + 1 > include_mod.max_include_depth) {
                fail.set(hit.line, hit.column, hit.path, locus);
                try self.diagnostics.append(self.gpa, try include_mod.makeDiagnostic(
                    self.retain,
                    error.DepthExceeded,
                    locus,
                    fail,
                ));
                continue;
            }
            if (self.scanned_sources.contains(hit.path)) continue;

            const source = include_mod.readSourceAlloc(self.io, self.content_dir, hit.path, self.gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    fail.set(hit.line, hit.column, hit.path, locus);
                    try self.diagnostics.append(self.gpa, try include_mod.makeDiagnostic(self.retain, err, locus, fail));
                    continue;
                },
            };
            defer self.gpa.free(source);

            try stack.append(self.gpa, hit.path);
            defer _ = stack.pop();
            const source_body = include_mod.bodyOfSource(source);
            const source_from: Endpoint = .{ .type = .source, .value = hit.path };
            try self.scanWiki(source_body, hit.path, source_from);
            try self.scanIncludes(source_body, hit.path, source_from, stack, depth + 1);

            const retained_path = try self.retain.dupe(u8, hit.path);
            try self.scanned_sources.put(self.gpa, retained_path, {});
        }
    }

    fn scanPage(self: *DependencyResolver, page: PageEntry, body: []const u8) !void {
        const from: Endpoint = .{ .type = .page, .value = page.id };
        try self.scanWiki(body, page.source_path, from);
        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(self.gpa);
        try stack.append(self.gpa, page.source_path);
        try self.scanIncludes(body, page.source_path, from, &stack, 0);
    }
};

fn resolveDependencies(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    content_dir: Io.Dir,
    input_format: identity.InputFormat,
    result: *Result,
) !void {
    var resolver: DependencyResolver = .{
        .io = io,
        .gpa = gpa,
        .retain = retain,
        .content_dir = content_dir,
        .nodes = result.pages.items,
        .edges = &result.edges,
        .diagnostics = &result.diagnostics,
    };
    defer resolver.deinit();

    for (result.pages.items) |page| {
        const source = readFileAlloc(io, content_dir, page.source_path, gpa) catch |err| {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .EIO,
                .message = try std.fmt.allocPrint(retain, "failed to read \"{s}\" while resolving dependencies: {s}", .{ page.source_path, @errorName(err) }),
                .remediation = try retain.dupe(u8, "Ensure the page source is readable"),
                .source_path = page.source_path,
                .line = 1,
                .column = 1,
            });
            result.failure = .io;
            continue;
        };
        defer gpa.free(source);
        if (page.body_offset > source.len) return error.InvalidBodyOffset;
        if (input_format == .textile) {
            const adapted = try textile.toMarkdown(source[page.body_offset..], gpa);
            if (!adapted.isOk()) return error.InvalidTextile;
            defer gpa.free(adapted.markdown);
            try resolver.scanPage(page, adapted.markdown);
        } else {
            try resolver.scanPage(page, source[page.body_offset..]);
        }
    }
}

/// resolver used by IR 0.2. Page endpoints are keyed by entity id and source
/// endpoints by content-root-relative path, matching `getAffectedPages`.
/// Layout/asset dependencies remain HTML-internal and are added by that path.
pub fn populateDependencyIndex(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    content_root: []const u8,
    nodes: []const graph_mod.Node,
    quiet: bool,
    index: *dependency.DependencyIndex,
) !void {
    return populateDependencyIndexFormat(io, gpa, retain, content_root, nodes, quiet, .markdown, index);
}

/// Mode-aware dependency population used by explicit Textile builds. The
/// Markdown wrapper above preserves its pre-existing call contract.
pub fn populateDependencyIndexFormat(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    content_root: []const u8,
    nodes: []const graph_mod.Node,
    quiet: bool,
    input_format: identity.InputFormat,
    index: *dependency.DependencyIndex,
) !void {
    var content_dir = try Io.Dir.cwd().openDir(io, content_root, .{});
    defer content_dir.close(io);

    var edges: std.ArrayList(DependencyEdge) = .empty;
    defer edges.deinit(gpa);
    var diagnostics: std.ArrayList(diag.Diagnostic) = .empty;
    defer diagnostics.deinit(gpa);

    var resolver: DependencyResolver = .{
        .io = io,
        .gpa = gpa,
        .retain = retain,
        .content_dir = content_dir,
        .nodes = nodes,
        .edges = &edges,
        .diagnostics = &diagnostics,
    };
    defer resolver.deinit();

    for (nodes) |page| {
        const source = readFileAlloc(io, content_dir, page.source_path, gpa) catch |err| {
            if (!quiet) std.debug.print("error: EIO: failed to read {s}: {s}\n", .{ page.source_path, @errorName(err) });
            return err;
        };
        defer gpa.free(source);
        if (page.body_offset > source.len) return error.InvalidBodyOffset;
        if (input_format == .textile) {
            const adapted = try textile.toMarkdown(source[page.body_offset..], gpa);
            if (!adapted.isOk()) return error.InvalidTextile;
            defer gpa.free(adapted.markdown);
            try resolver.scanPage(page, adapted.markdown);
        } else {
            try resolver.scanPage(page, source[page.body_offset..]);
        }
        if (page.parent) |parent| {
            try resolver.appendEdge(
                .{ .type = .page, .value = page.id },
                .{ .type = .page, .value = parent },
                "parent",
            );
        }
    }

    if (diag.countErrors(diagnostics.items) > 0) {
        var include_failure = false;
        if (!quiet) {
            diag.sortDiagnostics(diagnostics.items);
            for (diagnostics.items) |d| {
                const line = diag.formatText(d, gpa) catch continue;
                defer gpa.free(line);
                std.debug.print("{s}\n", .{line});
            }
        }
        for (diagnostics.items) |d| switch (d.code) {
            .EINCLUDESYNTAX, .EINCLUDEMISSING, .EINCLUDECYCLE, .EINVALIDPATH => include_failure = true,
            else => {},
        };
        if (include_failure) return error.IncludeFailed;
        return error.ReferenceFailed;
    }

    std.mem.sort(DependencyEdge, edges.items, {}, edgeLess);
    var write: usize = 0;
    for (edges.items) |edge| {
        if (write == 0 or !edgeEql(edges.items[write - 1], edge)) {
            edges.items[write] = edge;
            write += 1;
        }
    }
    edges.items.len = write;

    for (edges.items) |edge| {
        const kind: dependency.DependencyKind = if (std.mem.eql(u8, edge.kind, "parent"))
            .parent
        else if (std.mem.eql(u8, edge.kind, "include"))
            .include
        else if (std.mem.eql(u8, edge.kind, "reference"))
            .reference
        else
            unreachable;
        try index.addDependency(edge.from.value, edge.to.value, kind);
    }
}

fn freezeDependencyIndex(gpa: std.mem.Allocator, result: *Result) !void {
    // Parent edges join resolved authored edges only after page indices/ids are frozen.
    for (result.pages.items) |page| {
        if (page.parent) |parent| {
            try result.edges.append(gpa, .{
                .from = .{ .type = .page, .value = page.id },
                .to = .{ .type = .page, .value = parent },
                .kind = "parent",
            });
        }
    }

    std.mem.sort(DependencyEdge, result.edges.items, {}, edgeLess);
    var write: usize = 0;
    for (result.edges.items) |edge| {
        if (write == 0 or !edgeEql(result.edges.items[write - 1], edge)) {
            result.edges.items[write] = edge;
            write += 1;
        }
    }
    result.edges.items.len = write;

    var targets: std.ArrayList(Endpoint) = .empty;
    defer targets.deinit(gpa);
    for (result.edges.items) |edge| try targets.append(gpa, edge.to);
    std.mem.sort(Endpoint, targets.items, {}, struct {
        fn less(_: void, a: Endpoint, b: Endpoint) bool {
            return endpointLess(a, b);
        }
    }.less);
    write = 0;
    for (targets.items) |target| {
        if (write == 0 or !endpointEql(targets.items[write - 1], target)) {
            targets.items[write] = target;
            write += 1;
        }
    }
    targets.items.len = write;

    for (targets.items) |target| {
        var incoming: std.ArrayList(u32) = .empty;
        errdefer incoming.deinit(gpa);
        for (result.edges.items, 0..) |edge, i| {
            if (endpointEql(edge.to, target)) try incoming.append(gpa, @intCast(i));
        }
        const owned_incoming = try incoming.toOwnedSlice(gpa);
        errdefer gpa.free(owned_incoming);
        try result.reverse_index.append(gpa, .{
            .target = target,
            .incoming_edges = owned_incoming,
        });
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
// JSON renderers
// ---------------------------------------------------------------------------

pub fn renderManifest(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    return ir_emit.renderManifest(gpa, result, .{
        .schema_version = schema_version,
        .compiler_id = compiler_id,
        .semantic_schema_version = semantic_schema_version,
        .semantic_compiler_id = semantic_compiler_id,
    });
}

pub fn renderGraph(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    return ir_emit.renderGraph(gpa, result, .{
        .schema_version = schema_version,
        .compiler_id = compiler_id,
        .semantic_schema_version = semantic_schema_version,
        .semantic_compiler_id = semantic_compiler_id,
    });
}

pub fn renderBuildReport(gpa: std.mem.Allocator, result: *const Result) ![]u8 {
    return ir_emit.renderBuildReport(gpa, result, .{
        .schema_version = schema_version,
        .compiler_id = compiler_id,
        .semantic_schema_version = semantic_schema_version,
        .semantic_compiler_id = semantic_compiler_id,
    });
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
/// rename from staging is preferred. On `error.CrossDevice`, copy+delete is
/// used (same as HTML stage publish). Cross-volume **atomic** replace is not
/// claimed. Not proven cross-platform atomic for concurrent readers. Temp
/// staging path names never appear inside JSON.
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
    // Cross-device: copy then delete source (not atomic; same honesty as HTML/RAG).
    var stage_dir = try cwd.openDir(io, stage_rel, .{});
    defer stage_dir.close(io);
    var out_dir = try cwd.openDir(io, result.out_dir, .{});
    defer out_dir.close(io);

    const names = [_][]const u8{ "manifest.json", "graph.json", "build-report.json" };
    for (names) |name| {
        stage_dir.rename(name, out_dir, name, io) catch |err| switch (err) {
            error.CrossDevice => {
                try stage_dir.copyFile(name, out_dir, name, io, .{ .replace = true });
                stage_dir.deleteFile(io, name) catch {};
            },
            else => return err,
        };
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
        .reverse_index = .empty,
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

    scanner.scan(io, .{ .content_root = options.content_root, .input_format = options.input_format }, &scan_list) catch |err| switch (err) {
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
        error.InputFormatMismatch => {
            try result.diagnostics.append(gpa, .{
                .severity = .error_,
                .code = .ETEXTILE,
                .message = try retain.dupe(u8, "content root mixes Markdown and Textile page extensions, or uses the wrong explicit input mode"),
                .remediation = try retain.dupe(u8, "Use Markdown-only input by default, or pass --textile for a .textile-only tree"),
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
            // Per-file read failure is I/O (exit 3), not content validation (exit 1).
            result.failure = .io;
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

        // Textile mode adapts only the already-frontmatter-split body. The
        // adapted Markdown then enters the same component/parser pipeline.
        // Scratch arena owns tokenizer arrays; only diagnostics are retained.
        {
            var tok_arena = std.heap.ArenaAllocator.init(gpa);
            defer tok_arena.deinit();
            var body = parsed.doc.body;
            if (options.input_format == .textile) {
                const adapted = try textile.toMarkdown(body, tok_arena.allocator());
                if (adapted.diagnostic) |td| {
                    const body_line_base = countLinesUpTo(source, parsed.doc.body_offset);
                    try result.diagnostics.append(gpa, .{
                        .severity = .error_,
                        .code = .ETEXTILE,
                        .message = try retain.dupe(u8, td.message),
                        .remediation = try retain.dupe(u8, "Use only the bounded Textile compatibility subset"),
                        .source_path = disc.source_path,
                        .line = body_line_base + td.line - 1,
                        .column = td.column,
                    });
                    // Preserve metadata promotion so graph diagnostics remain
                    // available alongside the adapter error.
                    body = "";
                } else {
                    body = adapted.markdown;
                }
            }
            const tok = aside.tokenizeBody(body, tok_arena.allocator()) catch |err| switch (err) {
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
            .semantic_relations = p.relations,
        });
    }

    // --- 5. Validate page identity/topology, then direct dependencies -------
    logCompile(options.quiet, "boris: ignite validating graph\n", .{});
    try graph_mod.validate(gpa, retain, result.pages.items, &result.diagnostics);
    diag.sortDiagnostics(result.diagnostics.items);

    var err_count = diag.countErrors(result.diagnostics.items);
    if (err_count == 0) {
        try validateSemanticRelations(gpa, retain, result.pages.items, &result.diagnostics);
        diag.sortDiagnostics(result.diagnostics.items);
        err_count = diag.countErrors(result.diagnostics.items);
    }
    if (err_count == 0) {
        try resolveDependencies(io, gpa, retain, content_dir, options.input_format, &result);
        diag.sortDiagnostics(result.diagnostics.items);
        err_count = diag.countErrors(result.diagnostics.items);
    }
    result.ok = err_count == 0;
    if (!result.ok) {
        // Preserve .io if a per-file read already failed; otherwise content/graph.
        if (result.failure != .io) {
            result.failure = .content;
        }
        result.graph_frozen = false;
        logCompile(options.quiet, "boris: content validation failed ({d} error(s))\n", .{err_count});
        return result;
    }

    // --- 6. Freeze only after clean validation ------------------------------
    // TODO: wire layout_path when CompileOptions gains one; layouts not on IR options yet.
    const frozen = try graph_mod.freeze(gpa, result.pages.items, null);
    defer gpa.free(frozen.edges);
    try freezeDependencyIndex(gpa, &result);
    result.graph_frozen = frozen.frozen;
    return result;
}

/// Full IR pipeline. Validates the whole graph before publishing artifacts.
/// Graph-dependent IR is published only when validation succeeds.
pub fn run(io: Io, gpa: std.mem.Allocator, options: Options) !Result {
    var result = try compile(io, gpa, .{
        .content_root = options.content_root,
        .quiet = options.quiet,
        .input_format = options.input_format,
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
    try std.testing.expectEqualStrings(schema_version, man_parsed.value.object.get("schemaVersion").?.string);
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

    // Root key order: schemaVersion, frozen, nodes, edges, reverseIndex, nav
    const k_schema = std.mem.indexOf(u8, graph_bytes, "\"schemaVersion\"").?;
    const k_frozen = std.mem.indexOf(u8, graph_bytes, "\"frozen\"").?;
    const k_nodes = std.mem.indexOf(u8, graph_bytes, "\"nodes\"").?;
    const k_edges = std.mem.indexOf(u8, graph_bytes, "\"edges\"").?;
    const k_reverse = std.mem.indexOf(u8, graph_bytes, "\"reverseIndex\"").?;
    const k_nav = std.mem.indexOf(u8, graph_bytes, "\"nav\"").?;
    try std.testing.expect(k_schema < k_frozen and k_frozen < k_nodes and k_nodes < k_edges and k_edges < k_reverse and k_reverse < k_nav);

    // No absolute paths in outputs.
    try std.testing.expect(std.mem.indexOf(u8, man_bytes, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, man_bytes, "/tmp/") == null);
    try std.testing.expect(std.mem.indexOf(u8, graph_bytes, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, graph_bytes, ".boris-stage") == null);
}

test "Textile mode preserves graph identity and fails closed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var valid = try compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .quiet = true,
        .input_format = .textile,
    });
    defer valid.deinit();
    try std.testing.expect(valid.ok);
    try std.testing.expect(valid.graph_frozen);
    try std.testing.expectEqual(@as(usize, 2), valid.pages.items.len);
    try std.testing.expectEqualStrings("guides/intro", valid.pages.items[0].id);
    try std.testing.expectEqualStrings("index", valid.pages.items[0].parent.?);
    try std.testing.expectEqualStrings("guides/intro.textile", valid.pages.items[0].source_path);
    try std.testing.expectEqualStrings("index", valid.pages.items[1].id);

    var malformed = try compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/invalid/content",
        .quiet = true,
        .input_format = .textile,
    });
    defer malformed.deinit();
    try std.testing.expect(!malformed.ok);
    try std.testing.expect(!malformed.graph_frozen);
    var saw_textile = false;
    var saw_table_declaration = false;
    for (malformed.diagnostics.items) |d| if (d.code == .ETEXTILE) {
        saw_textile = true;
        if (std.mem.eql(u8, d.source_path, "table.textile")) {
            saw_table_declaration = true;
            try std.testing.expectEqual(@as(u32, 4), d.line.?);
            try std.testing.expectEqual(@as(u32, 1), d.column.?);
        }
    };
    try std.testing.expect(saw_textile);
    try std.testing.expect(saw_table_declaration);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "textile-table-reject");
    defer gpa.free(out);
    var rejected = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/invalid/content",
        .out_dir = out,
        .quiet = true,
        .input_format = .textile,
    });
    defer rejected.deinit();
    try std.testing.expect(!rejected.ok);
    try std.testing.expect(!rejected.graph_frozen);
    try std.testing.expect(!rejected.published_graph_ir);
    try std.testing.expect(!fileExists(io, out, "manifest.json"));
    try std.testing.expect(!fileExists(io, out, "graph.json"));
    try std.testing.expect(fileExists(io, out, "build-report.json"));

    var mixed = try compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/mixed/content",
        .quiet = true,
        .input_format = .textile,
    });
    defer mixed.deinit();
    try std.testing.expect(!mixed.ok);
    try std.testing.expectEqual(diag.Code.ETEXTILE, mixed.diagnostics.items[0].code);
}

test "F8 graph-native fixture matches full graph golden" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try outRel(gpa, &tmp, "graph-native");
    defer gpa.free(out);

    var result = try run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/graph-native-dependencies/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok and result.graph_frozen);
    try std.testing.expectEqual(@as(usize, 5), result.edges.items.len);
    try std.testing.expectEqual(@as(usize, 4), result.reverse_index.items.len);

    const actual = try readOutFile(io, gpa, out, "graph.json");
    defer gpa.free(actual);
    const expected = try readFileAlloc(
        io,
        Io.Dir.cwd(),
        "docs/contracts/fixtures/graph-native-dependencies/expected/graph.json",
        gpa,
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}

test "include and wiki failures prevent dependency graph freeze and publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try outRel(gpa, &tmp, "content");
    defer gpa.free(content);
    const out = try outRel(gpa, &tmp, "out");
    defer gpa.free(out);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, content);
    var dir = try cwd.openDir(io, content, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{
        .sub_path = "index.md",
        .data = "{{include includes/missing.md}}\nSee [[missing/page]].\n",
    });

    var result = try run(io, gpa, .{
        .content_root = content,
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try std.testing.expect(!result.graph_frozen);
    try std.testing.expect(!result.published_graph_ir);
    try expectCode(&result, .EINCLUDEMISSING);
    try expectCode(&result, .EREFERENCEMISSING);
    try std.testing.expect(!fileExists(io, out, "manifest.json"));
    try std.testing.expect(!fileExists(io, out, "graph.json"));
    try std.testing.expect(fileExists(io, out, "build-report.json"));
}

test "Feature 9 IR: wiki fragment still emits page reference edge only" {
    // IR does not validate heading membership (no Apex); fragment syntax must not
    // break edge projection and must not invent a new edge kind.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try outRel(gpa, &tmp, "content");
    defer gpa.free(content);
    const out = try outRel(gpa, &tmp, "out");
    defer gpa.free(out);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, content);
    {
        const guides_rel = try std.fmt.allocPrint(gpa, "{s}/guides", .{content});
        defer gpa.free(guides_rel);
        try cwd.createDirPath(io, guides_rel);
    }
    var dir = try cwd.openDir(io, content, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{
        .sub_path = "index.md",
        .data =
            \\---
            \\title: Home
            \\---
            \\
            \\# Home
            \\
            \\See [[guides/t#sec]] and [[guides/t]].
            \\
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "guides/t.md",
        .data =
            \\---
            \\title: T
            \\parent: index
            \\---
            \\
            \\# T
            \\
            \\## Sec
            \\
        ,
    });

    var result = try run(io, gpa, .{
        .content_root = content,
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expect(result.published_graph_ir);

    // Exactly one reference edge page:index → page:guides/t (fragment ignored for identity).
    var ref_count: usize = 0;
    for (result.edges.items) |e| {
        if (!std.mem.eql(u8, e.kind, "reference")) continue;
        ref_count += 1;
        try std.testing.expect(e.from.type == .page);
        try std.testing.expectEqualStrings("index", e.from.value);
        try std.testing.expect(e.to.type == .page);
        try std.testing.expectEqualStrings("guides/t", e.to.value);
    }
    try std.testing.expectEqual(@as(usize, 1), ref_count);
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
        .{ .root = "docs/contracts/fixtures/case-id-collision/content", .code = .EINVALIDPATH },
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

test "per-file read failure remains EIO with I/O failure classification" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "content", .default_dir);
    var content = try tmp.dir.openDir(io, "content", .{ .iterate = true });
    defer content.close(io);
    try content.writeFile(io, .{ .sub_path = "unreadable.md", .data = "# unreadable\n" });
    try content.setFilePermissions(io, "unreadable.md", @enumFromInt(0), .{});
    defer content.setFilePermissions(io, "unreadable.md", .default_file, .{}) catch {};

    // Privileged test processes may still read mode-000 files; in that
    // environment this filesystem regression cannot be exercised reliably.
    if (content.openFile(io, "unreadable.md", .{})) |file| {
        file.close(io);
        return error.SkipZigTest;
    } else |_| {}

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
    defer gpa.free(root);
    var result = try compile(io, gpa, .{ .content_root = root, .quiet = true });
    defer result.deinit();

    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(FailureKind.io, result.failure);
    try expectCode(&result, .EIO);
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
