//! Optional deterministic RAG export.
//!
//! Two surfaces share `pipeline.compile` (scan → parse → PageDb → graph
//! validate → freeze) and never invent a second parser or graph validator:
//!
//! * **Working context (default `--rag`)** — a small set of bounded
//!   model-facing pack files (`working-N.md`) containing complete, verbatim
//!   site documents (the selected subtree plus required site graph closure
//!   only — never the `docs/rag/system` corpus), plus a `manifest.json`
//!   sidecar that is not intended for model upload. Attachment count and
//!   context size are first-class product constraints.
//! * **Complete corpus (`--rag --complete`)** — the explicit full export of
//!   the entire validated corpus: system seeds, path-mirrored content pages,
//!   graph docs, catalog, and meta files, all preserving authoring fidelity.
//!   It rejects `--scope`: complete means complete.
//!
//! Both surfaces preserve complete authoring documents: Markdown input is
//! verbatim (frontmatter, H1 structure, and `<Aside>` / `<Details>` authoring
//! syntax are not rewritten); Textile input is deterministically adapted to
//! Boris-authorable Markdown. Verification metadata (per-document sha256,
//! byte counts, pack membership) lives in the sidecar manifest, not in
//! model-facing bytes.
//!
//! Normative contract: `docs/contracts/rag-export.md`.
//!
//! Determinism: no timestamps, absolute paths, hostnames, random values, or
//! hash-map / filesystem walk order in emitted bytes. Stable sorts:
//!   content pages → entity id (freeze order)
//!   system seeds  → normalized relative rag path (complete mode)
//!   graph edges   → source id then target id
//!   catalog rows  → rag_path

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const diag = @import("diag.zig");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");
const target_mod = @import("target.zig");
const source_io = @import("source_io.zig");
const timings = @import("timings.zig");
const pipeline = @import("pipeline.zig");
const rag_emit = @import("rag_emit.zig");
const textile = @import("textile.zig");
const export_scope = @import("export_scope.zig");

/// Machine format id (`format` in `manifest.json` and complete-mode
/// `catalog_meta.json`).
pub const catalog_format = "boris-rag";

/// Integer schema version for the RAG machine interface. Bumped to 2 by the
/// working-context rework: the default `--rag` tree changed shape.
pub const catalog_schema_version: u32 = 2;

/// Product version stamped into `manifest.json` and complete-mode
/// `catalog_meta.json`.
pub const boris_version = pipeline.boris_version;

/// Default working pack target (bytes) when `--split-size` is not given.
pub const default_pack_target: usize = 262144;

fn relationCountForPages(pages: []const graph_mod.Node) usize {
    var count: usize = 0;
    for (pages) |page| count += page.semantic_relations.len;
    return count;
}

pub const RagOptions = struct {
    /// Content root (same as IR `--input`).
    content_root: []const u8 = "content",
    /// Final RAG corpus directory (default `rag`).
    out_dir: []const u8 = "rag",
    /// Curated system-seed root; missing → skip seeds (no error).
    system_docs_dir: []const u8 = "docs/rag/system",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
    scope: ?[]const u8 = null,
    /// Working-mode pack target (bytes); complete mode rejects this.
    split_size: ?usize = null,
    /// Complete-corpus export (system + per-page + graph + catalog tree).
    complete: bool = false,
    /// Accepted for compatibility with the pre-v2 scoped-bundle workflow;
    /// working packs are bundle-style by construction, so this is a no-op.
    bundles_only: bool = false,
    /// Opt-in phase timing/counter recorder (`--timings`); null by default.
    timings: ?*timings.Recorder = null,
};

pub const RagStats = struct {
    system_docs: usize = 0,
    content_pages: usize = 0,
    graph_docs: usize = 0,
    catalog_entries: usize = 0,
    /// True when a complete graph-dependent corpus was published.
    published: bool = false,
    graph_pages: usize = 0,
    selected_pages: usize = 0,
    structural_parent_count: usize = 0,
    semantic_neighbor_count: usize = 0,
    graph_relation_count: usize = 0,
    relation_count: usize = 0,
    complete: bool = false,
    /// Working mode: number of model-facing upload files.
    pack_count: usize = 0,
    /// Working mode: exact model-facing upload file paths (arena-owned),
    /// e.g. `working-1.md`, `working-2.md`.
    pack_paths: []const []const u8 = &.{},
    /// Working mode: document instances (split documents count per part).
    document_count: usize = 0,
    /// Working mode: total model-facing pack bytes.
    approximate_bytes: usize = 0,
    /// Working mode: deterministic approximate token count (bytes / 4).
    approximate_tokens: usize = 0,
    /// Working mode: non-upload sidecar files (manifest.json only).
    sidecar_count: usize = 0,
};

pub const RagResult = struct {
    arena: std.heap.ArenaAllocator,
    /// Shared compile result (pages, edges, diagnostics, ok/failure).
    compile: pipeline.Result,
    stats: RagStats = .{},

    pub fn deinit(self: *RagResult) void {
        self.compile.deinit();
        self.arena.deinit();
    }

    pub fn diagnostics(self: *const RagResult) []const diag.Diagnostic {
        return self.compile.diagnostics.items;
    }

    pub fn ok(self: *const RagResult) bool {
        return self.compile.ok and self.stats.published;
    }
};

/// Machine catalog row (`catalog.jsonl`, complete mode). Field order fixed.
const CatalogEntry = rag_emit.CatalogEntry;

fn log(opts: RagOptions, comptime fmt: []const u8, args: anytype) void {
    if (!opts.quiet) std.debug.print(fmt, args);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

/// Normalize a relative path to `/` separators (no leading `./`, no `//`).
fn normalizeRelPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    // Skip leading ./ and ./
    while (i < raw.len) {
        if (raw[i] == '/' or raw[i] == '\\') {
            i += 1;
            continue;
        }
        break;
    }
    var need_slash = false;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '/' or c == '\\') {
            need_slash = true;
            i += 1;
            // collapse multiple separators
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

fn appendCatalog(
    catalog: *std.ArrayList(CatalogEntry),
    list_gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    entry: CatalogEntry,
) !void {
    try catalog.append(list_gpa, .{
        .rag_id = try arena.dupe(u8, entry.rag_id),
        .rag_path = try arena.dupe(u8, entry.rag_path),
        .category = try arena.dupe(u8, entry.category),
        .title = try arena.dupe(u8, entry.title),
        .entity_id = try arena.dupe(u8, entry.entity_id),
        .role = try arena.dupe(u8, entry.role),
        .parent_entry = try arena.dupe(u8, entry.parent_entry),
        .tags = try arena.dupe(u8, entry.tags),
    });
}

// ---------------------------------------------------------------------------
// System seeds
// ---------------------------------------------------------------------------

const SeedDoc = struct {
    rag_id: []const u8,
    /// Normalized relative path under the seed root.
    rel: []const u8,
    /// Full seed file bytes (verbatim).
    source: []const u8,
    title: []const u8,
    tags: []const []const u8,
};

fn titleFromFilename(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".md")) return base[0 .. base.len - 3];
    return base;
}

fn firstHeadingOrFallback(body: []const u8, fallback: []const u8) []const u8 {
    var i: usize = 0;
    while (i < body.len) {
        var line_end = i;
        while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
        var line = body[i..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            i = if (line_end < body.len) line_end + 1 else body.len;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) {
            var j: usize = 0;
            while (j < trimmed.len and trimmed[j] == '#') : (j += 1) {}
            while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '\t')) : (j += 1) {}
            if (j < trimmed.len) return trimmed[j..];
        }
        break;
    }
    return fallback;
}

fn stripFrontmatter(source: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, source, "---")) return source;
    var i: usize = 3;
    if (i < source.len and source[i] == '\r') i += 1;
    if (i < source.len and source[i] == '\n') i += 1;
    var line_start = i;
    while (line_start < source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var line = source[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) {
            var body = line_end;
            if (body < source.len and source[body] == '\n') body += 1;
            return source[body..];
        }
        if (line_end < source.len and source[line_end] == '\n') {
            line_start = line_end + 1;
        } else break;
    }
    return source;
}

fn extractTagsLine(source: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, source, "---")) return "";
    var i: usize = 3;
    if (i < source.len and source[i] == '\r') i += 1;
    if (i < source.len and source[i] == '\n') i += 1;
    var line_start = i;
    while (line_start < source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var line = source[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "tags:")) {
            return std.mem.trim(u8, trimmed["tags:".len..], " \t");
        }
        if (line_end < source.len and source[line_end] == '\n') {
            line_start = line_end + 1;
        } else break;
    }
    return "";
}

fn extractTagTokens(arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const line = extractTagsLine(source);
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return &.{};
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (inner.len == 0) return &.{};

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(arena);
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        var token = std.mem.trim(u8, raw, " \t");
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
            token = token[1 .. token.len - 1];
        }
        if (token.len == 0) continue;
        try list.append(arena, token);
    }
    return try list.toOwnedSlice(arena);
}

fn extractRagId(source: []const u8, fallback: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, source, "---")) return fallback;
    var i: usize = 3;
    if (i < source.len and source[i] == '\r') i += 1;
    if (i < source.len and source[i] == '\n') i += 1;
    var line_start = i;
    while (line_start < source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var line = source[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "rag_id:")) {
            return std.mem.trim(u8, trimmed["rag_id:".len..], " \t");
        }
        if (line_end < source.len and source[line_end] == '\n') {
            line_start = line_end + 1;
        } else break;
    }
    return fallback;
}

/// Read and sort system seeds (missing seed root → empty list, no error).
fn collectSystemDocs(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: RagOptions,
) ![]SeedDoc {
    const cwd = Io.Dir.cwd();
    var sys_dir = cwd.openDir(io, opts.system_docs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer sys_dir.close(io);

    var rels: std.ArrayList([]const u8) = .empty;
    defer rels.deinit(gpa);
    {
        var walker = try sys_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".md")) continue;
            const norm = try normalizeRelPath(arena, entry.path);
            try rels.append(gpa, norm);
        }
    }
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var docs: std.ArrayList(SeedDoc) = .empty;
    errdefer docs.deinit(gpa);
    for (rels.items) |rel| {
        const source = try readFileAlloc(io, sys_dir, rel, arena);
        const body = stripFrontmatter(source);
        const title = firstHeadingOrFallback(body, titleFromFilename(rel));
        const fallback_id = try std.fmt.allocPrint(arena, "system/{s}", .{titleFromFilename(rel)});
        const rag_id = extractRagId(source, fallback_id);
        const parsed_tags = try extractTagTokens(arena, source);
        try docs.append(gpa, .{
            .rag_id = rag_id,
            .rel = rel,
            .source = source,
            .title = title,
            .tags = parsed_tags,
        });
    }
    return try docs.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Working-context packs
// ---------------------------------------------------------------------------

const WorkingItem = struct {
    rag_id: []const u8,
    source: []const u8,
    category: []const u8,
    entity_id: []const u8,
    /// Verbatim document bytes (markdown source, or frontmatter + adapted
    /// markdown for textile input).
    body: []const u8,
    source_sha256: [64]u8,
    /// Original source file bytes (for the sidecar integrity record).
    source_size: usize,
};

const WorkingInstance = struct {
    item_index: usize,
    part_number: usize,
    part_count: usize,
    body: []const u8,
    /// Exact rendered byte length of this instance (envelope + body + separators).
    len: usize,
};

fn digitCount(n: usize) usize {
    var v = n;
    var count: usize = 1;
    while (v >= 10) : (v /= 10) count += 1;
    return count;
}

/// Byte length of one `<!-- boris-rag-doc: ... -->` marker (without the
/// surrounding newlines). Values are validated single-line strings, so the
/// rendered length equals the arithmetic length.
fn envelopeLen(rag_id: []const u8, source: []const u8, category: []const u8, part_number: usize, part_count: usize) usize {
    var len: usize = 24 + rag_id.len + 10 + source.len + 12 + category.len + 5;
    if (part_count > 1) len += 8 + digitCount(part_number) + 1 + digitCount(part_count);
    return len;
}

fn instanceLen(item: WorkingItem, part_number: usize, part_count: usize, body: []const u8) usize {
    var len = envelopeLen(item.rag_id, item.source, item.category, part_number, part_count) + body.len + 3;
    if (body.len == 0 or body[body.len - 1] != '\n') len += 1;
    return len;
}

/// Expand items into packable instances. Whole documents under the target stay
/// whole; only a single document larger than the target is split at safe
/// Markdown boundaries (reusing `export_scope.partitionMarkdown`).
fn buildWorkingInstances(
    gpa: std.mem.Allocator,
    cap: usize,
    items: []const WorkingItem,
) ![]WorkingInstance {
    // Boundary collision guard: a source line that begins with the document
    // marker prefix would be indistinguishable from a real envelope during
    // marker-free reassembly, so such documents are rejected outright instead
    // of silently producing an ambiguous pack.
    for (items) |item| {
        if (rag_emit.containsDocMarkerCollision(item.body)) return error.SeparatorCollision;
    }
    var instances: std.ArrayList(WorkingInstance) = .empty;
    errdefer instances.deinit(gpa);
    for (items, 0..) |item, item_index| {
        if (item.body.len <= cap) {
            try instances.append(gpa, .{
                .item_index = item_index,
                .part_number = 1,
                .part_count = 1,
                .body = item.body,
                .len = instanceLen(item, 1, 1, item.body),
            });
            continue;
        }
        // Oversized single document. Budget leaves room for the envelope and
        // separators; `partitionMarkdown` splits at blank-line / heading
        // boundaries outside fenced code and fails on an indivisible block.
        const base = envelopeLen(item.rag_id, item.source, item.category, 1, 1);
        if (base + 24 >= cap) return error.OversizedBlock;
        const budget = cap - base - 24;
        const parts = try export_scope.partitionMarkdown(gpa, item.body, budget);
        defer gpa.free(parts);
        for (parts, 0..) |part, i| {
            const number = i + 1;
            try instances.append(gpa, .{
                .item_index = item_index,
                .part_number = number,
                .part_count = parts.len,
                .body = part,
                .len = instanceLen(item, number, parts.len, part),
            });
        }
    }
    return try instances.toOwnedSlice(gpa);
}

const PackPlan = struct {
    first_instance: usize,
    count: usize,
};

/// Greedy deterministic packing: fill a pack until the next instance would
/// exceed the target, then start a new pack. The small fixed pack header is
/// not counted against the target; a whole document that cannot fit alongside
/// anything else gets its own pack even if envelope overhead pushes the total
/// slightly over (whole documents are never split merely to meet a cap).
fn packWorkingInstances(
    gpa: std.mem.Allocator,
    cap: usize,
    instances: []const WorkingInstance,
) ![]PackPlan {
    var plans: std.ArrayList(PackPlan) = .empty;
    errdefer plans.deinit(gpa);
    var current_bytes: usize = 0;
    var first: usize = 0;
    for (instances, 0..) |inst, i| {
        if (i > first and current_bytes + inst.len > cap) {
            try plans.append(gpa, .{ .first_instance = first, .count = i - first });
            first = i;
            current_bytes = 0;
        }
        current_bytes += inst.len;
    }
    if (first < instances.len) {
        try plans.append(gpa, .{ .first_instance = first, .count = instances.len - first });
    }
    return try plans.toOwnedSlice(gpa);
}

fn gatherWorkingItems(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: RagOptions,
    selected_pages: []const graph_mod.Node,
) ![]WorkingItem {
    // Working mode carries the selected site documents and the required site
    // graph closure only. The `docs/rag/system` corpus belongs to the explicit
    // complete-corpus export (`--rag --complete`), never to default working
    // packs; unscoped working mode is the site, not the Boris system corpus.
    var items: std.ArrayList(WorkingItem) = .empty;
    errdefer items.deinit(gpa);

    const cwd = Io.Dir.cwd();
    var content_dir = try cwd.openDir(io, opts.content_root, .{});
    defer content_dir.close(io);
    for (selected_pages) |p| {
        const source = try source_io.readPageAlloc(io, content_dir, p.source_path, arena);
        const doc = if (opts.input_format == .textile) blk: {
            const adapted = try textile.toMarkdown(source[p.body_offset..], arena);
            if (!adapted.isOk()) return error.UnexpectedParseFailure;
            break :blk try std.mem.concat(arena, u8, &.{ source[0..p.body_offset], adapted.markdown });
        } else source;
        const rag_id = try std.fmt.allocPrint(arena, "content/{s}", .{p.id});
        try items.append(gpa, .{
            .rag_id = rag_id,
            .source = p.source_path,
            .category = "content",
            .entity_id = p.id,
            .body = doc,
            .source_sha256 = cache.hexDigest(cache.hashBytes(source)),
            .source_size = source.len,
        });
    }
    return try items.toOwnedSlice(gpa);
}

fn exportWorking(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    opts: RagOptions,
    selected_pages: []const graph_mod.Node,
    stats: *RagStats,
) !void {
    const cap = opts.split_size orelse default_pack_target;
    const items = try gatherWorkingItems(io, gpa, arena, opts, selected_pages);
    defer gpa.free(items);

    const instances = try buildWorkingInstances(gpa, cap, items);
    defer gpa.free(instances);
    const plans = try packWorkingInstances(gpa, cap, instances);
    defer gpa.free(plans);

    var manifest_docs: std.ArrayList(rag_emit.ManifestDoc) = .empty;
    defer manifest_docs.deinit(gpa);
    var pack_infos: std.ArrayList(rag_emit.WorkingPackInfo) = .empty;
    defer pack_infos.deinit(gpa);

    var pack_docs: std.ArrayList(rag_emit.WorkingDoc) = .empty;
    defer pack_docs.deinit(gpa);

    var total_upload_bytes: usize = 0;
    var pack_paths: std.ArrayList([]const u8) = .empty;
    defer pack_paths.deinit(arena);
    for (plans, 0..) |plan, plan_index| {
        const pack_number = plan_index + 1;
        const pack_path = try std.fmt.allocPrint(arena, "working-{d}.md", .{pack_number});
        try pack_paths.append(arena, pack_path);

        pack_docs.clearRetainingCapacity();
        for (instances[plan.first_instance .. plan.first_instance + plan.count]) |inst| {
            const item = items[inst.item_index];
            try pack_docs.append(gpa, .{
                .rag_id = item.rag_id,
                .source = item.source,
                .category = item.category,
                .entity_id = item.entity_id,
                .part_number = inst.part_number,
                .part_count = inst.part_count,
                .body = inst.body,
            });
        }
        const pack_bytes = try rag_emit.renderWorkingPack(gpa, pack_number, plans.len, pack_docs.items);
        defer gpa.free(pack_bytes);
        try writeBytes(io, out_dir, pack_path, pack_bytes);
        total_upload_bytes += pack_bytes.len;

        try pack_infos.append(gpa, .{
            .path = pack_path,
            .bytes = pack_bytes.len,
            .documents = plan.count,
        });
        for (pack_docs.items, 0..) |_, j| {
            const inst = instances[plan.first_instance + j];
            const item_index = inst.item_index;
            const item = &items[item_index];
            try manifest_docs.append(gpa, .{
                .rag_id = item.rag_id,
                .source = item.source,
                .category = item.category,
                .entity_id = item.entity_id,
                .pack = pack_path,
                .part = inst.part_number,
                .part_count = inst.part_count,
                .continuation = if (inst.part_count == 1) "single" else if (inst.part_number == inst.part_count) "continued" else "continues",
                .bytes = inst.body.len,
                .source_sha256 = &items[item_index].source_sha256,
            });
        }
        log(opts, "  rag pack    {s} ({d} bytes, {d} document(s))\n", .{ pack_path, pack_bytes.len, plan.count });
    }

    const manifest = try rag_emit.renderWorkingManifest(gpa, .{
        .version = boris_version,
        .scope = opts.scope orelse "",
        .graph_page_count = stats.graph_pages,
        .selected_page_count = stats.selected_pages,
        .structural_parent_count = stats.structural_parent_count,
        .semantic_neighbor_count = stats.semantic_neighbor_count,
        .graph_relation_count = stats.graph_relation_count,
        .selected_relation_count = stats.relation_count,
        .pack_target = cap,
        .approximate_tokens = total_upload_bytes / 4,
        .packs = pack_infos.items,
        .docs = manifest_docs.items,
    });
    defer gpa.free(manifest);
    try writeBytes(io, out_dir, "manifest.json", manifest);

    // Working mode carries site documents only; the system corpus is complete-
    // mode territory, so the seed count is always zero here.
    stats.system_docs = 0;
    stats.content_pages = selected_pages.len;
    stats.pack_count = plans.len;
    stats.pack_paths = try pack_paths.toOwnedSlice(arena);
    stats.document_count = manifest_docs.items.len;
    stats.approximate_bytes = total_upload_bytes;
    stats.approximate_tokens = total_upload_bytes / 4;
    // manifest.json is the single non-upload sidecar; catalog_meta.json belongs
    // to the complete-corpus catalog surface only.
    stats.sidecar_count = 1;
}

// ---------------------------------------------------------------------------
// Complete-corpus export (`--rag --complete`)
// ---------------------------------------------------------------------------

fn exportGraphDocs(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    pages: []const graph_mod.Node,
    catalog: *std.ArrayList(CatalogEntry),
    opts: RagOptions,
) !usize {
    var n: usize = 0;

    const entity_catalog = try rag_emit.renderEntityCatalog(gpa, pages);
    defer gpa.free(entity_catalog);
    try writeBytes(io, out_dir, "graph/entity-catalog.md", entity_catalog);
    try appendCatalog(catalog, gpa, arena, .{
        .rag_id = "graph/entity-catalog",
        .rag_path = "graph/entity-catalog.md",
        .category = "graph",
        .title = "Entity catalog",
        .tags = "[graph, catalog, entities]",
    });
    n += 1;
    log(opts, "  rag graph   graph/entity-catalog.md\n", .{});

    const relations = try rag_emit.renderRelations(gpa, pages);
    defer gpa.free(relations);
    try writeBytes(io, out_dir, "graph/relations.md", relations);
    try appendCatalog(catalog, gpa, arena, .{
        .rag_id = "graph/relations",
        .rag_path = "graph/relations.md",
        .category = "graph",
        .title = "Graph relations (parent hierarchy)",
        .tags = "[graph, relations, hierarchy, trunk, satellite]",
    });
    n += 1;
    log(opts, "  rag graph   graph/relations.md\n", .{});

    return n;
}

fn exportCatalogMeta(io: Io, gpa: std.mem.Allocator, out_dir: Io.Dir) !void {
    const text = try rag_emit.renderCatalogMeta(gpa, catalog_format, catalog_schema_version, boris_version);
    defer gpa.free(text);
    try writeBytes(io, out_dir, "catalog_meta.json", text);
}

fn exportComplete(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    opts: RagOptions,
    selected_pages: []const graph_mod.Node,
    catalog: *std.ArrayList(CatalogEntry),
    stats: *RagStats,
) !void {
    const cwd = Io.Dir.cwd();

    // system/** — verbatim seeds
    const seeds = try collectSystemDocs(io, gpa, arena, opts);
    defer gpa.free(seeds);
    const default_tags = [_][]const u8{ "boris", "system" };
    for (seeds) |seed| {
        const rag_path = try std.fmt.allocPrint(arena, "system/{s}", .{seed.rel});
        try writeBytes(io, out_dir, rag_path, seed.source);
        const tags_out: []const []const u8 = if (seed.tags.len > 0) seed.tags else &default_tags;
        try appendCatalog(catalog, gpa, arena, .{
            .rag_id = seed.rag_id,
            .rag_path = rag_path,
            .category = "system",
            .title = seed.title,
            .tags = try rag_emit.formatTags(arena, tags_out),
        });
        log(opts, "  rag system  {s}\n", .{rag_path});
    }
    stats.system_docs = seeds.len;

    // content/pages/** — verbatim authoring documents
    var content_dir = try cwd.openDir(io, opts.content_root, .{});
    defer content_dir.close(io);
    for (selected_pages) |p| {
        const source = try source_io.readPageAlloc(io, content_dir, p.source_path, arena);
        const doc = if (opts.input_format == .textile) blk: {
            const adapted = try textile.toMarkdown(source[p.body_offset..], arena);
            if (!adapted.isOk()) return error.UnexpectedParseFailure;
            break :blk try std.mem.concat(arena, u8, &.{ source[0..p.body_offset], adapted.markdown });
        } else source;
        const rag_path = try identity.ragPagePath(arena, p.id);
        const rag_id = try std.fmt.allocPrint(arena, "content/{s}", .{p.id});
        try writeBytes(io, out_dir, rag_path, doc);
        try appendCatalog(catalog, gpa, arena, try rag_emit.contentCatalogEntry(arena, p, rag_id, rag_path));
        log(opts, "  rag page    {s}\n", .{rag_path});
    }
    stats.content_pages = selected_pages.len;

    // graph/**
    stats.graph_docs = try exportGraphDocs(io, gpa, arena, out_dir, selected_pages, catalog, opts);

    // meta + machine catalog
    const guide = try rag_emit.renderUploadGuide(gpa);
    defer gpa.free(guide);
    try writeBytes(io, out_dir, "UPLOAD-GUIDE.md", guide);
    try appendCatalog(catalog, gpa, arena, .{
        .rag_id = "meta/upload-guide",
        .rag_path = "UPLOAD-GUIDE.md",
        .category = "meta",
        .title = "Upload guide — Grok, Gemini, and similar chat LLMs",
        .tags = "[upload, grok, gemini, llm, rag]",
    });

    // INDEX is itself a catalog row. Append its row before sorting and
    // counting so INDEX's counts table, INDEX's full-catalog table, and
    // catalog.jsonl all describe the same row set (INDEX included).
    try appendCatalog(catalog, gpa, arena, .{
        .rag_id = "meta/index",
        .rag_path = "INDEX.md",
        .category = "meta",
        .title = "Boris RAG corpus — INDEX",
        .tags = "[index, catalog, retrieval-map]",
    });
    rag_emit.sortCatalogByRagPath(catalog.items);
    stats.catalog_entries = catalog.items.len;

    const index = try rag_emit.renderIndex(gpa, catalog.items, .{
        .system_docs = stats.system_docs,
        .content_pages = stats.content_pages,
        .graph_docs = stats.graph_docs,
        .catalog_entries = stats.catalog_entries,
    }, boris_version);
    defer gpa.free(index);
    try writeBytes(io, out_dir, "INDEX.md", index);

    const jsonl = try rag_emit.renderCatalogJsonl(gpa, catalog.items);
    defer gpa.free(jsonl);
    try writeBytes(io, out_dir, "catalog.jsonl", jsonl);
}

// ---------------------------------------------------------------------------
// Staging publish
// ---------------------------------------------------------------------------

/// Ensure a directory path exists (relative or absolute).
///
/// Zig's `createDirPath` on `cwd` does **not** reliably accept absolute paths
/// (e.g. parent `/tmp` can yield `error.NotDir`). Walk parents with open/create
/// instead so `--rag-dir /tmp/...` works on POSIX.
fn ensureDirPath(io: Io, path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".") or
        std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "\\"))
        return;

    const cwd = Io.Dir.cwd();

    // Fast path: already a directory.
    if (cwd.openDir(io, path, .{})) |*d| {
        d.close(io);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Ensure parent exists first.
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, path)) {
            try ensureDirPath(io, parent);
        }
    }

    // Create the leaf component.
    if (std.fs.path.isAbsolute(path)) {
        Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            var parent_dir = try cwd.openDir(io, parent, .{});
            defer parent_dir.close(io);
            const base = std.fs.path.basename(path);
            parent_dir.createDir(io, base, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            return;
        }
    }

    cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Open a directory given a relative or absolute path.
fn openPathDir(io: Io, path: []const u8, opts: Io.Dir.OpenOptions) !Io.Dir {
    return try Io.Dir.cwd().openDir(io, path, opts);
}

/// Try to rename directory `from` → `to` (absolute or cwd-relative).
/// Returns true on success, false on any rename failure (caller falls back).
fn tryRenameDir(io: Io, from: []const u8, to: []const u8) bool {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.isAbsolute(from) and std.fs.path.isAbsolute(to)) {
        Io.Dir.renameAbsolute(from, to, io) catch return false;
        return true;
    }
    cwd.rename(from, cwd, to, io) catch return false;
    return true;
}

/// Copy every file under `src_root` into `dst_root` (created if needed).
fn copyTreeFiles(io: Io, gpa: std.mem.Allocator, src_root: []const u8, dst_root: []const u8) !void {
    try ensureDirPath(io, dst_root);
    var stage = try openPathDir(io, src_root, .{ .iterate = true });
    defer stage.close(io);
    var out = try openPathDir(io, dst_root, .{});
    defer out.close(io);

    var walker = try stage.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try normalizeRelPath(gpa, entry.path);
        defer gpa.free(rel);
        const data = try readFileAlloc(io, stage, entry.path, gpa);
        defer gpa.free(data);
        try ensureParent(io, out, rel);
        try out.writeFile(io, .{ .sub_path = rel, .data = data });
    }
}

/// Write the full corpus under `stage_path`, then install it at `out_dir`.
///
/// **Never deletes `out_dir` before the new corpus is ready.** Order:
/// 1. Prefer rename `stage` → `out` when `out` is free.
/// 2. Else move `out` → `out.boris-rag-prev`, rename `stage` → `out`, then
///    delete the previous tree. On install failure, restore the previous tree.
/// 3. Else copy `stage` → `out.boris-rag-next` and swap via the same move-aside
///    dance (cross-volume / rename-of-stage failure path).
///
/// Cross-volume **atomic** replace is still not claimed. Concurrent readers may
/// briefly observe the previous tree moved aside during the swap window.
fn publishCorpus(
    io: Io,
    gpa: std.mem.Allocator,
    stage_path: []const u8,
    out_dir: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    // Ensure parent of out_dir exists (rename does not create parents).
    if (std.fs.path.dirname(out_dir)) |parent| {
        if (parent.len > 0) try ensureDirPath(io, parent);
    }

    // Fast path: out free → rename stage into place.
    if (tryRenameDir(io, stage_path, out_dir)) return;

    const prev_path = try std.fmt.allocPrint(gpa, "{s}.boris-rag-prev", .{out_dir});
    defer gpa.free(prev_path);
    const next_path = try std.fmt.allocPrint(gpa, "{s}.boris-rag-next", .{out_dir});
    defer gpa.free(next_path);

    // Drop leftovers from a previous interrupted publish.
    cwd.deleteTree(io, prev_path) catch {};
    cwd.deleteTree(io, next_path) catch {};

    // Move existing out aside only after stage is complete (caller already
    // finished writing stage). Install stage; restore on failure.
    const had_prev = tryRenameDir(io, out_dir, prev_path);
    if (tryRenameDir(io, stage_path, out_dir)) {
        if (had_prev) cwd.deleteTree(io, prev_path) catch {};
        return;
    }
    if (had_prev) {
        // Stage rename failed after moving out aside — put the old corpus back.
        if (!tryRenameDir(io, prev_path, out_dir)) {
            // Catastrophic: both stage and prev may be orphaned; leave both.
            return error.RagPublishSwapFailed;
        }
    }

    // Rename of stage failed (cross-volume, etc.): materialize a full next tree
    // beside out, then swap. Never delete out until next is fully written.
    try copyTreeFiles(io, gpa, stage_path, next_path);
    const moved = tryRenameDir(io, out_dir, prev_path);
    if (!tryRenameDir(io, next_path, out_dir)) {
        if (moved) _ = tryRenameDir(io, prev_path, out_dir);
        cwd.deleteTree(io, next_path) catch {};
        return error.RagPublishSwapFailed;
    }
    if (moved) cwd.deleteTree(io, prev_path) catch {};
    cwd.deleteTree(io, stage_path) catch {};
}

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

/// Run shared compile + RAG export.
///
/// Graph validation runs **before** any graph-dependent corpus write. On
/// content failure, no RAG tree is published (staging is discarded).
pub fn run(io: Io, gpa: std.mem.Allocator, opts: RagOptions) !RagResult {
    try target_mod.validateExportPath(io, gpa, opts.content_root, opts.out_dir);
    var result: RagResult = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .compile = undefined,
        .stats = .{},
    };

    // Shared scan → parse → PageDb nodes → graph.validate → freeze.
    result.compile = try pipeline.compile(io, gpa, .{
        .content_root = opts.content_root,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .timings = opts.timings,
    });
    errdefer {
        result.compile.deinit();
        result.arena.deinit();
    }

    if (!result.compile.ok) {
        // No graph-dependent RAG publication.
        log(opts, "boris: RAG export aborted (content validation failed)\n", .{});
        return result;
    }

    var counts: export_scope.SelectionCounts = .{};
    const selected_pages = try export_scope.selectPages(result.arena.allocator(), result.compile.pages.items, opts.scope, &counts);
    defer result.arena.allocator().free(selected_pages);

    const retain = result.arena.allocator();
    const stage_rel = try std.fmt.allocPrint(gpa, "{s}.boris-rag-stage", .{opts.out_dir});
    defer gpa.free(stage_rel);

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, stage_rel) catch {};
    try ensureDirPath(io, stage_rel);
    errdefer cwd.deleteTree(io, stage_rel) catch {};

    var catalog: std.ArrayList(CatalogEntry) = .empty;
    defer catalog.deinit(gpa);

    var stats: RagStats = .{};
    stats.complete = opts.complete;
    stats.graph_pages = result.compile.pages.items.len;
    stats.selected_pages = selected_pages.len;
    stats.graph_relation_count = relationCountForPages(result.compile.pages.items);
    for (selected_pages) |page| stats.relation_count += page.semantic_relations.len;
    stats.structural_parent_count = counts.structural_parents;
    stats.semantic_neighbor_count = counts.semantic_neighbors;

    log(opts, "\nExporting RAG corpus → {s}/\n", .{opts.out_dir});

    // Write into the staging directory, then close all handles before rename/publish.
    {
        var stage_dir = try cwd.openDir(io, stage_rel, .{});
        defer stage_dir.close(io);

        if (opts.complete) {
            try exportComplete(io, gpa, retain, stage_dir, opts, selected_pages, &catalog, &stats);
            // catalog_meta.json is part of the complete-corpus catalog surface
            // only; working mode records format/schema/version in manifest.json
            // and does not emit a redundant sidecar.
            try exportCatalogMeta(io, gpa, stage_dir);
        } else {
            try exportWorking(io, gpa, retain, stage_dir, opts, selected_pages, &stats);
        }
    }

    // Publish only after the full stage tree is written and handles closed.
    try publishCorpus(io, gpa, stage_rel, opts.out_dir);
    stats.published = true;
    result.stats = stats;

    if (opts.complete) {
        log(opts,
            \\RAG complete-corpus export done.
            \\  system={d}  pages={d}  graph={d}  catalog={d}
            \\
        , .{
            stats.system_docs,
            stats.content_pages,
            stats.graph_docs,
            stats.catalog_entries,
        });
    } else {
        log(opts,
            \\RAG working-context export done.
            \\  seeds={d}  selected={d}/{d}  parents={d}  neighbors={d}  packs={d}  tokens≈{d}
            \\
        , .{
            stats.system_docs,
            stats.selected_pages,
            stats.graph_pages,
            stats.structural_parent_count,
            stats.semantic_neighbor_count,
            stats.pack_count,
            stats.approximate_tokens,
        });
    }

    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "catalog_meta.json shape is fixed and compact (schema v2)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/meta-only", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);
    var out_dir = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out_dir.close(io);

    try exportCatalogMeta(io, gpa, out_dir);

    const bytes = try readFileAlloc(io, out_dir, "catalog_meta.json", gpa);
    defer gpa.free(bytes);

    const expected = try std.fmt.allocPrint(
        gpa,
        "{{\"format\":\"{s}\",\"schema_version\":{d},\"boris_version\":\"{s}\"}}\n",
        .{ catalog_format, catalog_schema_version, boris_version },
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("boris-rag", parsed.value.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("schema_version").?.integer);
}

const RagTestPaths = struct {
    base: []u8,
    content: []u8,
    system: []u8,
    out_a: []u8,
    out_b: []u8,

    fn deinit(self: *RagTestPaths, gpa: std.mem.Allocator) void {
        gpa.free(self.base);
        gpa.free(self.content);
        gpa.free(self.system);
        gpa.free(self.out_a);
        gpa.free(self.out_b);
    }
};

fn ragTestPaths(gpa: std.mem.Allocator, sub: []const u8) !RagTestPaths {
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{sub});
    errdefer gpa.free(base);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{base});
    errdefer gpa.free(content);
    const system = try std.fmt.allocPrint(gpa, "{s}/system", .{base});
    errdefer gpa.free(system);
    const out_a = try std.fmt.allocPrint(gpa, "{s}/out-a", .{base});
    errdefer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, "{s}/out-b", .{base});
    errdefer gpa.free(out_b);
    return .{ .base = base, .content = content, .system = system, .out_a = out_a, .out_b = out_b };
}

/// Content created in reverse entity_id order; system seeds deliberately unsorted.
fn writeRagFixtures(io: Io, gpa: std.mem.Allocator, content_rel: []const u8, system_rel: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, content_rel);
    try cwd.createDirPath(io, system_rel);
    {
        const guides_rel = try std.fmt.allocPrint(gpa, "{s}/guides", .{content_rel});
        defer gpa.free(guides_rel);
        try cwd.createDirPath(io, guides_rel);
    }
    {
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{
            .sub_path = "z-last.md",
            .data =
            \\---
            \\title: Z Last
            \\tags: [z]
            \\---
            \\
            \\# Z Last
            \\
            \\Tail page with "quotes" and a tip.
            \\
            \\<Aside kind="tip" id="z1">
            \\Tip body.
            \\</Aside>
            \\
            \\<Details summary="More">
            \\Extra details body.
            \\</Details>
            \\
            ,
        });
        try content.writeFile(io, .{
            .sub_path = "m-mid.md",
            .data =
            \\---
            \\title: M Mid
            \\parent: a-first
            \\---
            \\
            \\# Source H1 Should Vanish
            \\
            \\Satellite body.
            \\
            \\# Nested H1 Becomes H2
            \\
            ,
        });
        try content.writeFile(io, .{
            .sub_path = "a-first.md",
            .data =
            \\---
            \\title: A First
            \\---
            \\
            \\# A First
            \\
            \\Trunk body.
            \\
            ,
        });
        try content.writeFile(io, .{
            .sub_path = "guides/nested.md",
            .data =
            \\---
            \\title: Nested Guide
            \\---
            \\
            \\# Nested Guide
            \\
            \\Nested path page.
            \\
            ,
        });
        try content.writeFile(io, .{
            .sub_path = "guides/deep.md",
            .data =
            \\---
            \\title: Deep Guide
            \\parent: m-mid
            \\---
            \\
            \\# Deep Guide
            \\
            \\Nested child page.
            \\
            ,
        });
    }
    {
        var sys = try cwd.openDir(io, system_rel, .{});
        defer sys.close(io);
        try sys.writeFile(io, .{
            .sub_path = "b-second.md",
            .data =
            \\---
            \\rag_id: system/b-second
            \\tags: [boris, system]
            \\---
            \\
            \\# System B
            \\
            \\Second seed.
            \\
            ,
        });
        try sys.writeFile(io, .{
            .sub_path = "a-first.md",
            .data =
            \\---
            \\rag_id: system/a-first
            \\tags: [boris, system]
            \\---
            \\
            \\# System A
            \\
            \\First seed.
            \\
            ,
        });
    }
}

fn collectRelFiles(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root_rel: []const u8,
    list: *std.ArrayList([]const u8),
) !void {
    var root = try Io.Dir.cwd().openDir(io, root_rel, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const norm = try normalizeRelPath(arena, entry.path);
        try list.append(gpa, norm);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

fn expectDirsByteIdentical(io: Io, gpa: std.mem.Allocator, a_rel: []const u8, b_rel: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var files_a: std.ArrayList([]const u8) = .empty;
    defer files_a.deinit(gpa);
    var files_b: std.ArrayList([]const u8) = .empty;
    defer files_b.deinit(gpa);

    try collectRelFiles(io, gpa, retain, a_rel, &files_a);
    try collectRelFiles(io, gpa, retain, b_rel, &files_b);
    try std.testing.expectEqual(files_a.items.len, files_b.items.len);

    var dir_a = try Io.Dir.cwd().openDir(io, a_rel, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, b_rel, .{});
    defer dir_b.close(io);

    for (files_a.items, files_b.items) |pa, pb| {
        try std.testing.expectEqualStrings(pa, pb);
        const ba = try readFileAlloc(io, dir_a, pa, gpa);
        defer gpa.free(ba);
        const bb = try readFileAlloc(io, dir_b, pb, gpa);
        defer gpa.free(bb);
        try std.testing.expectEqualStrings(ba, bb);
    }
}

fn readRel(io: Io, gpa: std.mem.Allocator, root_rel: []const u8, rel: []const u8) ![]u8 {
    var dir = try Io.Dir.cwd().openDir(io, root_rel, .{});
    defer dir.close(io);
    return readFileAlloc(io, dir, rel, gpa);
}

/// Count real document markers (line-leading). The pack preamble mentions the
/// marker syntax inline; only `\n<!-- boris-rag-doc:` lines delimit documents.
fn countMarkers(bytes: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "\n<!-- boris-rag-doc:")) |found| {
        count += 1;
        pos = found + 1;
    }
    return count;
}

test "working export: authoring fidelity, packing, attachment ergonomics, no hashes in packs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    var res = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .quiet = true,
    });
    defer res.deinit();
    try std.testing.expect(res.ok());
    try std.testing.expectEqual(@as(usize, 5), res.stats.content_pages);
    // Working mode is the selected site only — the system corpus never seeds
    // default working packs.
    try std.testing.expectEqual(@as(usize, 0), res.stats.system_docs);
    // 5 site documents fit one bounded pack.
    try std.testing.expectEqual(@as(usize, 1), res.stats.pack_count);
    try std.testing.expectEqual(@as(usize, 5), res.stats.document_count);
    try std.testing.expectEqual(@as(usize, 1), res.stats.sidecar_count);

    const pack = try readRel(io, gpa, paths.out_a, "working-1.md");
    defer gpa.free(pack);
    // One pack file holds every document: boundaries are unambiguous markers.
    try std.testing.expectEqual(@as(usize, 5), countMarkers(pack));
    // No system seed documents leak into model-facing packs.
    try std.testing.expect(std.mem.indexOf(u8, pack, "system/") == null);
    // Model-facing bytes carry no integrity hashes.
    try std.testing.expect(std.mem.indexOf(u8, pack, "sha256") == null);

    // Fidelity: H1s and authoring components survive verbatim; no ::: form.
    try std.testing.expect(std.mem.indexOf(u8, pack, "# Source H1 Should Vanish") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "## Nested H1 Becomes H2") == null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "<Aside kind=\"tip\" id=\"z1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "<Details summary=\"More\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, ":::") == null);

    // Sidecar manifest: machine files are separate and carry integrity records.
    const manifest = try readRel(io, gpa, paths.out_a, "manifest.json");
    defer gpa.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("working", parsed.value.object.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("schema_version").?.integer);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.get("documents").?.array.items.len);
    const doc0 = parsed.value.object.get("documents").?.array.items[0];
    try std.testing.expectEqualStrings("content", doc0.object.get("category").?.string);
    try std.testing.expectEqual(@as(usize, 64), doc0.object.get("source_sha256").?.string.len);
    // Per-document digests must be content-sensitive (regression: a loop-local
    // pointer previously made every manifest entry share one stack-slot hash).
    const docs_arr = parsed.value.object.get("documents").?.array.items;
    const h0 = docs_arr[0].object.get("source_sha256").?.string;
    const h1 = docs_arr[1].object.get("source_sha256").?.string;
    try std.testing.expect(!std.mem.eql(u8, h0, h1));
    const sidecars = parsed.value.object.get("sidecar_files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sidecars.len);
    try std.testing.expectEqualStrings("manifest.json", sidecars[0].string);

    // catalog_meta.json is complete-mode surface only; working mode does not
    // emit a redundant sidecar.
    {
        var out = try Io.Dir.cwd().openDir(io, paths.out_a, .{});
        defer out.close(io);
        if (out.statFile(io, "catalog_meta.json", .{})) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "working export: scoped set includes subtree, parents, neighbors; excludes unrelated" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    var res = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .scope = "m-mid",
        .quiet = true,
    });
    defer res.deinit();
    try std.testing.expect(res.ok());
    try std.testing.expectEqual(@as(usize, 5), res.stats.graph_pages);
    try std.testing.expectEqual(@as(usize, 2), res.stats.selected_pages);
    try std.testing.expectEqual(@as(usize, 1), res.stats.structural_parent_count);
    try std.testing.expectEqual(@as(usize, 0), res.stats.semantic_neighbor_count);

    const manifest = try readRel(io, gpa, paths.out_a, "manifest.json");
    defer gpa.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("m-mid", parsed.value.object.get("scope").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("selected_page_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("structural_parent_count").?.integer);

    // The selected content documents are m-mid and its parent a-first; the
    // unrelated pages (z-last, guides/nested) stay out of the packs.
    const pack = try readRel(io, gpa, paths.out_a, "working-1.md");
    defer gpa.free(pack);
    try std.testing.expect(std.mem.indexOf(u8, pack, "content/m-mid") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "content/a-first") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "content/z-last") == null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "content/guides/nested") == null);
    // System seeds never enter working packs, scoped or unscoped.
    try std.testing.expect(std.mem.indexOf(u8, pack, "system/a-first") == null);
    try std.testing.expectEqual(@as(usize, 0), res.stats.system_docs);
}

test "working export: oversized document splits deterministically at safe boundaries" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    // Expand m-mid into a document larger than the pack target.
    var content = try Io.Dir.cwd().openDir(io, paths.content, .{});
    defer content.close(io);
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(gpa);
    try expanded.appendSlice(gpa,
        \\---
        \\title: M Mid
        \\parent: a-first
        \\---
        \\
        \\# M Mid
        \\
    );
    for (0..40) |i| {
        try expanded.print(gpa, "Paragraph {d} supplies a stable boundary for oversized packing coverage.\n\n", .{i});
    }
    try content.writeFile(io, .{ .sub_path = "m-mid.md", .data = expanded.items });

    var res = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .split_size = 512,
        .quiet = true,
    });
    defer res.deinit();
    try std.testing.expect(res.ok());
    // The oversized m-mid was split into parts; other docs stay whole.
    try std.testing.expect(res.stats.pack_count >= 3);
    try std.testing.expect(res.stats.document_count > res.stats.pack_count);

    const manifest = try readRel(io, gpa, paths.out_a, "manifest.json");
    defer gpa.free(manifest);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest, .{});
    defer parsed.deinit();
    var split_doc: ?std.json.Value = null;
    var part_count: usize = 0;
    for (parsed.value.object.get("documents").?.array.items) |d| {
        if (std.mem.eql(u8, d.object.get("entity_id").?.string, "m-mid")) {
            if (split_doc == null) split_doc = d;
            part_count += 1;
        }
    }
    try std.testing.expect(split_doc != null);
    try std.testing.expect(part_count > 1);
    const first_part = split_doc.?;
    try std.testing.expect(first_part.object.get("part_count").?.integer > 1);
    try std.testing.expectEqualStrings("continues", first_part.object.get("continuation").?.string);

    // Split parts stay in document order across packs, so the whole source
    // body is recoverable by concatenating the part instances in order.
    var all_packs: std.ArrayList(u8) = .empty;
    defer all_packs.deinit(gpa);
    for (1..res.stats.pack_count + 1) |pack_number| {
        const pack_path = try std.fmt.allocPrint(gpa, "working-{d}.md", .{pack_number});
        defer gpa.free(pack_path);
        const pack_bytes = try readRel(io, gpa, paths.out_a, pack_path);
        defer gpa.free(pack_bytes);
        try all_packs.appendSlice(gpa, pack_bytes);
    }
    var prior: usize = 0;
    for (0..40) |i| {
        const needle = try std.fmt.allocPrint(gpa, "Paragraph {d} supplies", .{i});
        defer gpa.free(needle);
        const found = std.mem.indexOfPos(u8, all_packs.items, prior, needle) orelse return error.TestUnexpectedResult;
        prior = found + needle.len;
    }
}

test "working export: a source line that collides with the document marker fails loudly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);
    {
        var content = try Io.Dir.cwd().openDir(io, paths.content, .{});
        defer content.close(io);
        try content.writeFile(io, .{
            .sub_path = "collision.md",
            .data =
            \\---
            \\title: Collision
            \\---
            \\
            \\# Collision
            \\
            \\<!-- boris-rag-doc: id="evil" -->
            \\
            ,
        });
    }
    // The marker-prefix line would be indistinguishable from a real envelope
    // during marker-free reassembly, so the export rejects it instead of
    // emitting an ambiguous pack, and a prior export stays untouched.
    try std.testing.expectError(error.SeparatorCollision, run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .quiet = true,
    }));
}

test "working export: bundles_only is a byte-identical compat no-op" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    var plain = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .quiet = true,
    });
    defer plain.deinit();
    try std.testing.expect(plain.ok());

    // Pre-v2 scoped-bundle workflows passed --bundles-only; it is documented
    // as a no-op for working packs, which are bundle-style by construction.
    var compat = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_b,
        .system_docs_dir = paths.system,
        .bundles_only = true,
        .quiet = true,
    });
    defer compat.deinit();
    try std.testing.expect(compat.ok());
    try expectDirsByteIdentical(io, gpa, paths.out_a, paths.out_b);
}

// Complete mode is the entire validated corpus: `--complete` combined with
// `--scope` is rejected as a CLI usage error (see cli.zig conflict matrix), so
// there is deliberately no scoped complete-mode projection to test here.

test "working export: repeated exports are byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    var res_a = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .scope = "m-mid",
        .split_size = 700,
        .quiet = true,
    });
    defer res_a.deinit();
    try std.testing.expect(res_a.ok());

    var res_b = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_b,
        .system_docs_dir = paths.system,
        .scope = "m-mid",
        .split_size = 700,
        .quiet = true,
    });
    defer res_b.deinit();
    try std.testing.expect(res_b.ok());
    try expectDirsByteIdentical(io, gpa, paths.out_a, paths.out_b);
}

test "working export: invalid scope fails without replacing prior export" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    var ok = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .quiet = true,
    });
    defer ok.deinit();
    try std.testing.expect(ok.ok());
    const before = try readRel(io, gpa, paths.out_a, "manifest.json");
    defer gpa.free(before);

    try std.testing.expectError(error.InvalidScope, run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .scope = "missing",
        .quiet = true,
    }));
    const after = try readRel(io, gpa, paths.out_a, "manifest.json");
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "complete export: full tree, authoring fidelity, catalog, determinism" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);

    var res_a = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_a,
        .system_docs_dir = paths.system,
        .complete = true,
        .quiet = true,
    });
    defer res_a.deinit();
    try std.testing.expect(res_a.ok());
    try std.testing.expectEqual(@as(usize, 5), res_a.stats.content_pages);
    try std.testing.expectEqual(@as(usize, 2), res_a.stats.system_docs);
    try std.testing.expectEqual(@as(usize, 2), res_a.stats.graph_docs);

    // Verbatim content page: H1s and authoring components preserved.
    const mpage = try readRel(io, gpa, paths.out_a, "content/pages/m-mid.md");
    defer gpa.free(mpage);
    try std.testing.expect(std.mem.indexOf(u8, mpage, "# Source H1 Should Vanish") != null);
    try std.testing.expect(std.mem.indexOf(u8, mpage, "## Nested H1 Becomes H2") == null);
    const zpage = try readRel(io, gpa, paths.out_a, "content/pages/z-last.md");
    defer gpa.free(zpage);
    try std.testing.expect(std.mem.indexOf(u8, zpage, "<Aside kind=\"tip\" id=\"z1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, zpage, "<Details summary=\"More\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, zpage, ":::") == null);

    // Required complete-tree files.
    for ([_][]const u8{
        "INDEX.md",
        "UPLOAD-GUIDE.md",
        "catalog.jsonl",
        "catalog_meta.json",
        "graph/entity-catalog.md",
        "graph/relations.md",
        "system/a-first.md",
    }) |name| {
        const bytes = try readRel(io, gpa, paths.out_a, name);
        defer gpa.free(bytes);
    }

    // catalog.jsonl: content rows carry the author page title.
    const jsonl = try readRel(io, gpa, paths.out_a, "catalog.jsonl");
    defer gpa.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"entity_id\":\"m-mid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"title\":\"M Mid\"") != null);

    // Catalog self-consistency: INDEX's catalog count and full-catalog table
    // agree with catalog.jsonl, and INDEX is itself a catalog row.
    const jsonl_lines = blk: {
        var count: usize = 0;
        for (jsonl) |c| {
            if (c == '\n') count += 1;
        }
        break :blk count;
    };
    // 5 content + 2 system + 2 graph + UPLOAD-GUIDE + INDEX.
    try std.testing.expectEqual(@as(usize, 11), res_a.stats.catalog_entries);
    try std.testing.expectEqual(res_a.stats.catalog_entries, jsonl_lines);
    const index = try readRel(io, gpa, paths.out_a, "INDEX.md");
    defer gpa.free(index);
    const count_line = try std.fmt.allocPrint(gpa, "| catalog entries | {d} |", .{res_a.stats.catalog_entries});
    defer gpa.free(count_line);
    try std.testing.expect(std.mem.indexOf(u8, index, count_line) != null);
    // INDEX's own row appears in its full-catalog table and in catalog.jsonl.
    try std.testing.expect(std.mem.indexOf(u8, index, "| `INDEX.md` | meta | Boris RAG corpus — INDEX | — |") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"rag_path\":\"INDEX.md\"") != null);

    var res_b = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_b,
        .system_docs_dir = paths.system,
        .complete = true,
        .quiet = true,
    });
    defer res_b.deinit();
    try std.testing.expect(res_b.ok());
    try expectDirsByteIdentical(io, gpa, paths.out_a, paths.out_b);
}

test "rag vs IR: identical diagnostic categories; no graph RAG on failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const ir_out = try std.fmt.allocPrint(gpa, "{s}/ir-out", .{base});
    defer gpa.free(ir_out);
    const rag_out = try std.fmt.allocPrint(gpa, "{s}/rag-out", .{base});
    defer gpa.free(rag_out);

    // Seed a prior RAG tree that must not be replaced with a valid-looking partial.
    try Io.Dir.cwd().createDirPath(io, rag_out);
    {
        var d = try Io.Dir.cwd().openDir(io, rag_out, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = "stale-marker.txt", .data = "stale\n" });
    }

    const content = "docs/contracts/fixtures/duplicate-ids/content";

    var ir = try pipeline.run(io, gpa, .{
        .content_root = content,
        .out_dir = ir_out,
        .quiet = true,
    });
    defer ir.deinit();
    try std.testing.expect(!ir.ok);

    var rag = try run(io, gpa, .{
        .content_root = content,
        .out_dir = rag_out,
        .system_docs_dir = "docs/rag/system",
        .quiet = true,
    });
    defer rag.deinit();
    try std.testing.expect(!rag.compile.ok);
    try std.testing.expect(!rag.stats.published);

    for (ir.diagnostics.items) |d| {
        var found = false;
        for (rag.diagnostics()) |rd| {
            if (rd.code == d.code) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expect(diag.countErrors(ir.diagnostics.items) > 0);
    try std.testing.expectEqual(
        diag.countErrors(ir.diagnostics.items),
        diag.countErrors(rag.diagnostics()),
    );

    var out = try Io.Dir.cwd().openDir(io, rag_out, .{});
    defer out.close(io);
    _ = out.statFile(io, "stale-marker.txt", .{}) catch return error.TestUnexpectedResult;
    const has_catalog = blk: {
        _ = out.statFile(io, "catalog.jsonl", .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!has_catalog);
    const has_pack = blk: {
        _ = out.statFile(io, "working-1.md", .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!has_pack);
}

test "rag export against fixtures/content/valid (working + complete)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/valid-rag", .{tmp.sub_path});
    defer gpa.free(out);

    var res = try run(io, gpa, .{
        .content_root = "fixtures/content/valid",
        .out_dir = out,
        .system_docs_dir = "docs/rag/system",
        .quiet = true,
    });
    defer res.deinit();
    try std.testing.expect(res.ok());
    try std.testing.expectEqual(@as(usize, 8), res.stats.content_pages);
    {
        const pack = try readRel(io, gpa, out, "working-1.md");
        defer gpa.free(pack);
        try std.testing.expect(std.mem.indexOf(u8, pack, "# Boris working context pack 1/") != null);
    }
    {
        const manifest = try readRel(io, gpa, out, "manifest.json");
        defer gpa.free(manifest);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 8), parsed.value.object.get("selected_page_count").?.integer);
    }

    // Complete mode preserves the four-level hierarchy in relations.
    const complete_out = try std.fmt.allocPrint(gpa, "{s}/complete", .{out});
    defer gpa.free(complete_out);
    var comp = try run(io, gpa, .{
        .content_root = "fixtures/content/valid",
        .out_dir = complete_out,
        .system_docs_dir = "docs/rag/system",
        .complete = true,
        .quiet = true,
    });
    defer comp.deinit();
    try std.testing.expect(comp.ok());

    const relations = try readRel(io, gpa, complete_out, "graph/relations.md");
    defer gpa.free(relations);
    const expected_relations = try readRel(io, gpa, "fixtures/expected/rag", "graph/relations.md");
    defer gpa.free(expected_relations);
    try std.testing.expectEqualStrings(expected_relations, relations);

    const edges = [_][]const u8{
        "parent\thierarchy-great-grandchild\t->\thierarchy-leaf",
        "parent\thierarchy-leaf\t->\thierarchy-mid",
        "parent\thierarchy-mid\t->\thierarchy-trunk",
    };
    var prior: usize = 0;
    for (edges) |edge| {
        const found = std.mem.indexOfPos(u8, relations, prior, edge) orelse return error.TestExpectedEqual;
        prior = found + edge.len;
    }
}
