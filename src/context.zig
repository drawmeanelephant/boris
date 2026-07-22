//! Deterministic, provenance-rich AI Context Bundle export.
//!
//! This surface deliberately reuses `pipeline.compile` and `pipeline.renderGraph`.
//! It does not parse source metadata or reconstruct graph edges independently.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const graph_mod = @import("graph.zig");
const json_out = @import("json_out.zig");
const pipeline = @import("pipeline.zig");
const identity = @import("identity.zig");
const export_scope = @import("export_scope.zig");

pub const format = "boris-context";
pub const schema_version: u32 = 1;

pub const ContextOptions = struct {
    content_root: []const u8 = "content",
    out_dir: []const u8 = "context",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
    scope: ?[]const u8 = null,
    split_size: ?usize = null,
};

pub const ContextResult = struct {
    compile: pipeline.Result,
    published: bool = false,
    selected_pages: usize = 0,
    graph_pages: usize = 0,
    relation_count: usize = 0,
    part_count: usize = 0,
    chunk_count: usize = 0,

    pub fn deinit(self: *ContextResult) void {
        self.compile.deinit();
    }

    pub fn ok(self: *const ContextResult) bool {
        return self.compile.ok and self.published;
    }
};

const PageArtifact = struct {
    page: graph_mod.Node,
    source_hash: [64]u8,
    page_hash: [64]u8,
    page_doc: []const u8,
};

const ContextChunk = struct {
    page: graph_mod.Node,
    doc: []const u8,
    number: usize,
    count: usize,
    source_sha256: [64]u8,
};

const ContextPart = struct {
    doc: []const u8,
    first_chunk: usize,
    last_chunk: usize,
};

const ContextChunkInfo = struct {
    number: usize,
    count: usize,
};

fn log(opts: ContextOptions, comptime fmt: []const u8, args: anytype) void {
    if (!opts.quiet) std.debug.print(fmt, args);
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, bytes: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = bytes });
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn hexDigest(bytes: []const u8) [64]u8 {
    return cache.hexDigest(cache.hashBytes(bytes));
}

fn appendQuoted(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try buf.append(gpa, '"');
    try json_out.escapeAppend(buf, gpa, value);
    try buf.append(gpa, '"');
}

fn appendYamlString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try buf.appendSlice(gpa, key);
    try buf.appendSlice(gpa, ": ");
    try appendQuoted(buf, gpa, value);
    try buf.append(gpa, '\n');
}

fn maxBacktickRun(source: []const u8) usize {
    var best: usize = 0;
    var current_run: usize = 0;
    for (source) |c| {
        if (c == '`') {
            current_run += 1;
            if (current_run > best) best = current_run;
        } else {
            current_run = 0;
        }
    }
    return best;
}

fn appendFence(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, source: []const u8) !void {
    const count = @max(@as(usize, 3), maxBacktickRun(source) + 1);
    var i: usize = 0;
    while (i < count) : (i += 1) try buf.append(gpa, '`');
}

fn relationCount(result: *const pipeline.Result) usize {
    return relationCountPages(result.pages.items);
}

fn relationCountPages(pages: []const graph_mod.Node) usize {
    var count: usize = 0;
    for (pages) |page| count += page.semantic_relations.len;
    return count;
}

fn relationCountArtifacts(artifacts: []const PageArtifact) usize {
    var count: usize = 0;
    for (artifacts) |artifact| count += artifact.page.semantic_relations.len;
    return count;
}

fn irSchemaVersion(result: *const pipeline.Result) []const u8 {
    return if (relationCount(result) > 0) pipeline.semantic_schema_version else pipeline.schema_version;
}

fn compilerId(result: *const pipeline.Result) []const u8 {
    return if (relationCount(result) > 0) pipeline.semantic_compiler_id else pipeline.compiler_id;
}

fn pageTitle(page: graph_mod.Node) []const u8 {
    return page.title orelse page.id;
}

fn renderPageDocWithChunk(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    source: []const u8,
    source_hash: []const u8,
    chunk: ?ContextChunkInfo,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "---\nformat: boris-context-page\nschema_version: 1\n");
    try appendYamlString(&buf, gpa, "entity_id", page.id);
    try appendYamlString(&buf, gpa, "source_path", page.source_path);
    try appendYamlString(&buf, gpa, "source_sha256", source_hash);
    try appendYamlString(&buf, gpa, "role", page.role.name());
    try appendYamlString(&buf, gpa, "title", pageTitle(page));
    try appendYamlString(&buf, gpa, "parent", page.parent orelse "");
    if (chunk) |info| {
        try buf.appendSlice(gpa, "part: ");
        try json_out.writeUsize(&buf, gpa, info.number);
        try buf.appendSlice(gpa, "\npart_count: ");
        try json_out.writeUsize(&buf, gpa, info.count);
        try buf.appendSlice(gpa, "\ncontinuation: ");
        try appendQuoted(&buf, gpa, if (info.count == 1) "single" else if (info.number == 1) "continues" else if (info.number == info.count) "continued" else "continues");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "relations:\n");
    for (page.semantic_relations) |relation| {
        try buf.appendSlice(gpa, "  - kind: ");
        try appendQuoted(&buf, gpa, relation.kind.name());
        try buf.appendSlice(gpa, "\n    target: ");
        try appendQuoted(&buf, gpa, relation.target);
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "---\n\n# ");
    try buf.appendSlice(gpa, pageTitle(page));
    try buf.appendSlice(gpa, "\n\n## Source\n");
    try appendFence(&buf, gpa, source);
    try buf.appendSlice(gpa, "markdown\n");
    try buf.appendSlice(gpa, source);
    if (source.len == 0 or source[source.len - 1] != '\n') try buf.append(gpa, '\n');
    try appendFence(&buf, gpa, source);
    try buf.append(gpa, '\n');
    return try buf.toOwnedSlice(gpa);
}

fn renderPageDoc(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    source: []const u8,
    source_hash: []const u8,
) ![]u8 {
    return renderPageDocWithChunk(gpa, page, source, source_hash, null);
}

fn renderBundle(
    gpa: std.mem.Allocator,
    result: *const pipeline.Result,
    artifacts: []const PageArtifact,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "---\nformat: boris-context\nschema_version: 1\n");
    try appendYamlString(&buf, gpa, "content_root", result.content_root);
    try appendYamlString(&buf, gpa, "ir_schema_version", irSchemaVersion(result));
    try buf.appendSlice(gpa, "page_count: ");
    try json_out.writeUsize(&buf, gpa, artifacts.len);
    try buf.appendSlice(gpa, "\nrelation_count: ");
    try json_out.writeUsize(&buf, gpa, relationCountArtifacts(artifacts));
    try buf.appendSlice(gpa, "\n---\n\n# Boris AI context bundle\n\n");
    try buf.appendSlice(gpa, "This bundle contains validated Boris pages in canonical entity-id order.\n");
    try buf.appendSlice(gpa, "Use each source hash and relative source path as provenance.\n\n## Contents\n\n");
    for (artifacts) |artifact| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, artifact.page.id);
        try buf.appendSlice(gpa, "` — ");
        try buf.appendSlice(gpa, pageTitle(artifact.page));
        try buf.appendSlice(gpa, " (`");
        try buf.appendSlice(gpa, artifact.page.source_path);
        try buf.appendSlice(gpa, "`)\n");
    }
    try buf.append(gpa, '\n');
    for (artifacts) |artifact| {
        try buf.appendSlice(gpa, "\n---\n\n");
        try buf.appendSlice(gpa, artifact.page_doc);
    }
    return try buf.toOwnedSlice(gpa);
}

fn renderParts(gpa: std.mem.Allocator, chunks: []const ContextChunk, split_size: ?usize) ![]const ContextPart {
    if (split_size == null) return try gpa.alloc(ContextPart, 0);
    const cap = split_size.?;
    const prefix = "# Boris AI context bundle part\n\n";
    var parts: std.ArrayList(ContextPart) = .empty;
    errdefer {
        for (parts.items) |part| gpa.free(part.doc);
        parts.deinit(gpa);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);
    try current.appendSlice(gpa, prefix);
    var first_chunk: usize = 0;
    for (chunks, 0..) |chunk, i| {
        if (prefix.len + chunk.doc.len > cap) return error.OversizedBlock;
        if (current.items.len > prefix.len and current.items.len + chunk.doc.len > cap) {
            try parts.append(gpa, .{
                .doc = try current.toOwnedSlice(gpa),
                .first_chunk = first_chunk,
                .last_chunk = i,
            });
            current = .empty;
            try current.appendSlice(gpa, prefix);
            first_chunk = i;
        }
        try current.appendSlice(gpa, chunk.doc);
    }
    if (current.items.len > prefix.len) {
        try parts.append(gpa, .{
            .doc = try current.toOwnedSlice(gpa),
            .first_chunk = first_chunk,
            .last_chunk = chunks.len,
        });
    }
    return try parts.toOwnedSlice(gpa);
}

fn renderManifest(
    gpa: std.mem.Allocator,
    result: *const pipeline.Result,
    artifacts: []const PageArtifact,
    bundle: []const u8,
    graph: []const u8,
    opts: ContextOptions,
    chunks: []const ContextChunk,
    parts: []const ContextPart,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"format\": ");
    try appendQuoted(&buf, gpa, format);
    try buf.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n  \"compiler\": ");
    try appendQuoted(&buf, gpa, compilerId(result));
    try buf.appendSlice(gpa, ",\n  \"ir_schema_version\": ");
    try appendQuoted(&buf, gpa, irSchemaVersion(result));
    try buf.appendSlice(gpa, ",\n  \"content_root\": ");
    try appendQuoted(&buf, gpa, result.content_root);
    try buf.appendSlice(gpa, ",\n  \"scope\": ");
    try appendQuoted(&buf, gpa, opts.scope orelse "");
    try buf.appendSlice(gpa, ",\n  \"scope_closure\": \"parents+semantic-relations\"");
    try buf.appendSlice(gpa, ",\n  \"graph_page_count\": ");
    try json_out.writeUsize(&buf, gpa, result.pages.items.len);
    try buf.appendSlice(gpa, ",\n  \"page_count\": ");
    try json_out.writeUsize(&buf, gpa, artifacts.len);
    try buf.appendSlice(gpa, ",\n  \"selected_page_count\": ");
    try json_out.writeUsize(&buf, gpa, artifacts.len);
    try buf.appendSlice(gpa, ",\n  \"relation_count\": ");
    try json_out.writeUsize(&buf, gpa, relationCountArtifacts(artifacts));
    try buf.appendSlice(gpa, ",\n  \"split_size\": ");
    if (opts.split_size) |size| try json_out.writeUsize(&buf, gpa, size) else try json_out.writeNull(&buf, gpa);
    try buf.appendSlice(gpa, ",\n  \"part_count\": ");
    try json_out.writeUsize(&buf, gpa, parts.len);
    try buf.appendSlice(gpa, ",\n  \"chunk_count\": ");
    try json_out.writeUsize(&buf, gpa, chunks.len);
    try buf.appendSlice(gpa, ",\n  \"parts\": [");
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.print(gpa, "{{\"path\":\"parts/part-{d}.md\",\"bytes\":{d},\"chunks\":[", .{ i + 1, part.doc.len });
        for (chunks[part.first_chunk..part.last_chunk], 0..) |chunk, j| {
            if (j > 0) try buf.append(gpa, ',');
            try buf.print(gpa, "{{\"entity_id\":", .{});
            try appendQuoted(&buf, gpa, chunk.page.id);
            try buf.appendSlice(gpa, ",\"source_path\":");
            try appendQuoted(&buf, gpa, chunk.page.source_path);
            try buf.appendSlice(gpa, ",\"source_sha256\":");
            try appendQuoted(&buf, gpa, &chunk.source_sha256);
            try buf.print(gpa, ",\"part\":{d},\"part_count\":{d},\"continuation\":", .{ chunk.number, chunk.count });
            try appendQuoted(&buf, gpa, if (chunk.count == 1) "single" else if (chunk.number == 1) "continues" else if (chunk.number == chunk.count) "continued" else "continues");
            try buf.append(gpa, '}');
        }
        try buf.appendSlice(gpa, "]}");
    }
    try buf.append(gpa, ']');
    try buf.appendSlice(gpa, ",\n  \"artifacts\": [\n");

    const bundle_hash = hexDigest(bundle);
    const graph_hash = hexDigest(graph);
    try buf.appendSlice(gpa, "    {\"path\":\"bundle.md\",\"sha256\":");
    try appendQuoted(&buf, gpa, &bundle_hash);
    try buf.appendSlice(gpa, "},\n    {\"path\":\"graph.json\",\"sha256\":");
    try appendQuoted(&buf, gpa, &graph_hash);
    try buf.appendSlice(gpa, "},\n");
    for (artifacts, 0..) |artifact, i| {
        try buf.appendSlice(gpa, "    {\"path\":\"pages/");
        try buf.appendSlice(gpa, artifact.page.id);
        try buf.appendSlice(gpa, ".md\",\"sha256\":");
        try appendQuoted(&buf, gpa, &artifact.page_hash);
        try buf.appendSlice(gpa, "}");
        if (i + 1 < artifacts.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn tryRenameDir(io: Io, from: []const u8, to: []const u8) bool {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.isAbsolute(from) and std.fs.path.isAbsolute(to)) {
        Io.Dir.renameAbsolute(from, to, io) catch return false;
        return true;
    }
    cwd.rename(from, cwd, to, io) catch return false;
    return true;
}

fn publish(io: Io, gpa: std.mem.Allocator, stage: []const u8, out: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (tryRenameDir(io, stage, out)) return;
    const prev = try std.fmt.allocPrint(gpa, "{s}.boris-context-prev", .{out});
    defer gpa.free(prev);
    cwd.deleteTree(io, prev) catch {};
    const had_prev = tryRenameDir(io, out, prev);
    if (tryRenameDir(io, stage, out)) {
        if (had_prev) cwd.deleteTree(io, prev) catch {};
        return;
    }
    if (had_prev) _ = tryRenameDir(io, prev, out);
    return error.ContextPublishFailed;
}

fn renderContextChunks(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    body: []const u8,
    source_hash: []const u8,
    cap: usize,
) ![]const ContextChunk {
    const max_number = body.len + 1;
    const probe = try renderPageDocWithChunk(gpa, page, "", source_hash, .{ .number = max_number, .count = max_number });
    defer gpa.free(probe);
    if (probe.len > cap) return error.OversizedBlock;
    const body_budget = cap - probe.len;
    const pieces = try export_scope.partitionMarkdown(gpa, body, body_budget);
    defer gpa.free(pieces);

    var chunks: std.ArrayList(ContextChunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| gpa.free(chunk.doc);
        chunks.deinit(gpa);
    }
    for (pieces, 0..) |piece, i| {
        const doc = try renderPageDocWithChunk(gpa, page, piece, source_hash, .{ .number = i + 1, .count = pieces.len });
        if (doc.len > cap) {
            gpa.free(doc);
            return error.OversizedBlock;
        }
        var digest: [64]u8 = undefined;
        @memcpy(&digest, source_hash[0..64]);
        try chunks.append(gpa, .{ .page = page, .doc = doc, .number = i + 1, .count = pieces.len, .source_sha256 = digest });
    }
    return try chunks.toOwnedSlice(gpa);
}

/// Compile and publish a complete deterministic context bundle.
pub fn run(io: Io, gpa: std.mem.Allocator, opts: ContextOptions) !ContextResult {
    if (std.fs.path.isAbsolute(opts.content_root)) return error.AbsoluteContentRoot;

    var result = ContextResult{ .compile = try pipeline.compile(io, gpa, .{
        .content_root = opts.content_root,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
    }) };
    errdefer result.deinit();
    if (!result.compile.ok) return result;

    const arena = result.compile.arena.allocator();
    const cwd = Io.Dir.cwd();
    var content_dir = try cwd.openDir(io, opts.content_root, .{});
    defer content_dir.close(io);

    var artifacts: std.ArrayList(PageArtifact) = .empty;
    defer artifacts.deinit(gpa);
    defer {
        for (artifacts.items) |artifact| gpa.free(artifact.page_doc);
    }
    var chunks: std.ArrayList(ContextChunk) = .empty;
    defer chunks.deinit(gpa);
    defer {
        for (chunks.items) |chunk| gpa.free(chunk.doc);
    }
    const selected = try export_scope.selectPages(gpa, result.compile.pages.items, opts.scope);
    defer gpa.free(selected);
    result.graph_pages = result.compile.pages.items.len;
    result.selected_pages = selected.len;
    result.relation_count = relationCountPages(selected);
    for (selected) |page| {
        const source = try readFileAlloc(io, content_dir, page.source_path, arena);
        const digest = cache.hexDigest(cache.hashBytes(source));
        const page_doc = try renderPageDoc(gpa, page, source, &digest);
        const page_hash = hexDigest(page_doc);
        try artifacts.append(gpa, .{ .page = page, .source_hash = digest, .page_hash = page_hash, .page_doc = page_doc });
        if (opts.split_size) |cap| {
            const body = if (page.body_offset <= source.len) source[page.body_offset..] else return error.InvalidBodyOffset;
            const page_chunks = try renderContextChunks(gpa, page, body, &digest, cap);
            defer gpa.free(page_chunks);
            try chunks.appendSlice(gpa, page_chunks);
        }
    }

    const graph = try pipeline.renderGraph(gpa, &result.compile);
    defer gpa.free(graph);
    const bundle = try renderBundle(gpa, &result.compile, artifacts.items);
    defer gpa.free(bundle);
    const parts = try renderParts(gpa, chunks.items, opts.split_size);
    defer {
        for (parts) |part| gpa.free(part.doc);
        gpa.free(parts);
    }
    result.part_count = parts.len;
    result.chunk_count = chunks.items.len;
    const manifest = try renderManifest(gpa, &result.compile, artifacts.items, bundle, graph, opts, chunks.items, parts);
    defer gpa.free(manifest);

    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-context-stage", .{opts.out_dir});
    defer gpa.free(stage);
    cwd.deleteTree(io, stage) catch {};
    try ensureDirPath(io, stage);
    // A failed write or publish must not leave a partially rendered bundle for
    // a later invocation to mistake for its own staging area. On success the
    // stage is renamed away, so this cleanup is a no-op.
    errdefer cwd.deleteTree(io, stage) catch {};
    {
        var stage_dir = try cwd.openDir(io, stage, .{});
        defer stage_dir.close(io);
        try stage_dir.createDirPath(io, "pages");
        if (parts.len > 0) try stage_dir.createDirPath(io, "parts");
        try writeBytes(io, stage_dir, "bundle.md", bundle);
        try writeBytes(io, stage_dir, "graph.json", graph);
        try writeBytes(io, stage_dir, "manifest.json", manifest);
        for (artifacts.items) |artifact| {
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(gpa);
            try path_buf.appendSlice(gpa, "pages/");
            try path_buf.appendSlice(gpa, artifact.page.id);
            try path_buf.appendSlice(gpa, ".md");
            try writeBytes(io, stage_dir, path_buf.items, artifact.page_doc);
        }
        for (parts, 0..) |part, i| {
            const path = try std.fmt.allocPrint(gpa, "parts/part-{d}.md", .{i + 1});
            defer gpa.free(path);
            try writeBytes(io, stage_dir, path, part.doc);
        }
    }
    try publish(io, gpa, stage, opts.out_dir);
    result.published = true;
    log(opts, "context export complete: {s} ({d} page(s))\n", .{ opts.out_dir, artifacts.items.len });
    return result;
}

test "context chunks preserve provenance and fenced source boundaries" {
    var source_hash: [64]u8 = undefined;
    @memset(&source_hash, 'a');
    const page = graph_mod.Node{
        .id = "guides/chunks",
        .source_path = "guides/chunks.md",
        .title = "Chunks",
        .role = .trunk,
    };
    const body = "# First\n\nA paragraph that can end safely.\n\n```zig\nconst answer = 42;\n```\n\n# Second\n\nAnother paragraph.\n";
    const chunks = try renderContextChunks(std.testing.allocator, page, body, &source_hash, 430);
    defer {
        for (chunks) |chunk| std.testing.allocator.free(chunk.doc);
        std.testing.allocator.free(chunks);
    }
    try std.testing.expect(chunks.len > 1);
    for (chunks, 0..) |chunk, i| {
        try std.testing.expect(chunk.doc.len <= 430);
        try std.testing.expect(std.mem.indexOf(u8, chunk.doc, "entity_id: \"guides/chunks\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, chunk.doc, "source_sha256: \"aaaaaaaa") != null);
        try std.testing.expect(std.mem.indexOf(u8, chunk.doc, "part_count:") != null);
        try std.testing.expectEqual(i + 1, chunk.number);
    }
}
