//! Optional deterministic RAG export (milestone 7).
//!
//! Reuses the shared compile path: `pipeline.compile` → scanner → parser →
//! PageDb-derived graph nodes → `graph.validate` → freeze. Does **not** invent
//! a second parser or graph validator. No Apex / HTML rendering.
//!
//! Normative contract: `docs/contracts/rag-export.md`.
//!
//! Output tree (default `rag/`):
//!   INDEX.md, UPLOAD-GUIDE.md, catalog.jsonl, catalog_meta.json
//!   system/**          — seeds from system_docs_dir when present
//!   content/pages/**   — path-mirrored page segments
//!   graph/entity-catalog.md, graph/relations.md
//!
//! Determinism: no timestamps, absolute paths, hostnames, random values, or
//! hash-map / filesystem walk order in emitted bytes. Stable sorts:
//!   system seeds  → normalized relative rag path
//!   content pages → entity id
//!   graph edges   → source id then target id
//!   catalog rows  → rag_path
//!
//! Aside / `:::kind`: authoring is constrained `<Aside>`. On export, parsed
//! asides become `:::kind` / `:::kind{id="…"}` blocks (export representation
//! only — not round-trippable authoring syntax). See
//! `docs/contracts/components.md` and `docs/contracts/rag-export.md`.

const std = @import("std");
const Io = std.Io;
const diag = @import("diag.zig");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");
const json_out = @import("json_out.zig");
const parser = @import("parser.zig");
const aside = @import("aside.zig");
const pipeline = @import("pipeline.zig");
const textile = @import("textile.zig");

/// Machine format id written into `catalog_meta.json`.
pub const catalog_format = "boris-rag";

/// Integer schema version for the RAG catalog machine interface.
pub const catalog_schema_version: u32 = 1;

/// Product version stamped into `catalog_meta.json`.
pub const boris_version = pipeline.boris_version;

pub const RagOptions = struct {
    /// Content root (same as IR `--input`).
    content_root: []const u8 = "content",
    /// Final RAG corpus directory (default `rag`).
    out_dir: []const u8 = "rag",
    /// Curated system-seed root; missing → skip system segment (no error).
    system_docs_dir: []const u8 = "docs/rag/system",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
};

pub const RagStats = struct {
    system_docs: usize = 0,
    content_pages: usize = 0,
    graph_docs: usize = 0,
    catalog_entries: usize = 0,
    /// True when a complete graph-dependent corpus was published.
    published: bool = false,
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

/// Machine catalog row (`catalog.jsonl`). Field order is fixed and normative.
const CatalogEntry = struct {
    rag_id: []const u8,
    rag_path: []const u8,
    category: []const u8,
    title: []const u8,
    entity_id: []const u8 = "",
    role: []const u8 = "",
    parent_entry: []const u8 = "",
    tags: []const u8 = "",
};

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

fn sortCatalogByRagPath(entries: []CatalogEntry) void {
    std.mem.sort(CatalogEntry, entries, {}, struct {
        fn less(_: void, a: CatalogEntry, b: CatalogEntry) bool {
            return std.mem.order(u8, a.rag_path, b.rag_path) == .lt;
        }
    }.less);
}

// ---------------------------------------------------------------------------
// H1 ownership (metadata-owned title)
// ---------------------------------------------------------------------------

/// True when `left_trimmed` is an ATX level-1 heading (`#` not `##`).
fn isAtxH1Line(left_trimmed: []const u8) bool {
    if (left_trimmed.len == 0) return false;
    if (left_trimmed[0] != '#') return false;
    if (left_trimmed.len >= 2 and left_trimmed[1] == '#') return false;
    if (left_trimmed.len == 1) return true;
    return left_trimmed[1] == ' ' or left_trimmed[1] == '\t';
}

/// Drop a leading ATX H1 (and blank lines before it).
fn stripLeadingAtxH1(body: []const u8) []const u8 {
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
        if (isAtxH1Line(trimmed)) {
            if (line_end < body.len and body[line_end] == '\n') return body[line_end + 1 ..];
            return body[line_end..];
        }
        return body;
    }
    return body;
}

/// Demote remaining ATX H1 lines to H2.
fn demoteAtxH1ToH2(body: []const u8, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < body.len) {
        var line_end = i;
        while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
        var line = body[i..line_end];
        var had_cr = false;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
            had_cr = true;
        }
        const left = std.mem.trimStart(u8, line, " \t");
        const indent_len = line.len - left.len;
        if (isAtxH1Line(left)) {
            try out.appendSlice(arena, line[0..indent_len]);
            try out.append(arena, '#'); // # Title → ## Title
            try out.appendSlice(arena, left);
        } else {
            try out.appendSlice(arena, line);
        }
        if (had_cr) try out.append(arena, '\r');
        if (line_end < body.len) {
            try out.append(arena, '\n');
            i = line_end + 1;
        } else {
            i = line_end;
        }
    }
    return try out.toOwnedSlice(arena);
}

fn prepareContentBody(body: []const u8, arena: std.mem.Allocator) ![]const u8 {
    return demoteAtxH1ToH2(stripLeadingAtxH1(body), arena);
}

/// Export body: H1-normalize markdown segments; emit asides as `:::kind` blocks.
fn exportBodyForRag(segments: []const aside.Segment, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) {
                    try out.appendSlice(arena, md);
                    continue;
                }
                const prepared = try prepareContentBody(md, arena);
                try out.appendSlice(arena, prepared);
            },
            .aside => |a| {
                const block = try aside.formatRagDirective(a, arena);
                try out.appendSlice(arena, block);
            },
        }
    }
    return try out.toOwnedSlice(arena);
}

fn countAtxH1(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var line_end = i;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        var line = text[i..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (isAtxH1Line(trimmed)) n += 1;
        i = if (line_end < text.len) line_end + 1 else text.len;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tags / titles helpers
// ---------------------------------------------------------------------------

fn formatTags(arena: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    if (tags.len == 0) return try arena.dupe(u8, "[]");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    try buf.append(arena, '[');
    for (tags, 0..) |t, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, t);
    }
    try buf.append(arena, ']');
    return try buf.toOwnedSlice(arena);
}

fn pageTitle(p: graph_mod.Node) []const u8 {
    if (p.title) |t| return t;
    return p.id;
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

fn titleFromFilename(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".md")) return base[0 .. base.len - 3];
    return base;
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

// ---------------------------------------------------------------------------
// System seeds
// ---------------------------------------------------------------------------

fn exportSystemDocs(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    opts: RagOptions,
    catalog: *std.ArrayList(CatalogEntry),
) !usize {
    const cwd = Io.Dir.cwd();
    var sys_dir = cwd.openDir(io, opts.system_docs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            log(opts, "  rag system  (seed dir missing; skipped)\n", .{});
            return 0;
        },
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

    var count: usize = 0;
    for (rels.items) |rel| {
        const source = try readFileAlloc(io, sys_dir, rel, arena);
        const body = stripFrontmatter(source);
        const title = firstHeadingOrFallback(body, titleFromFilename(rel));
        const rag_path = try std.fmt.allocPrint(arena, "system/{s}", .{rel});
        const fallback_id = try std.fmt.allocPrint(arena, "system/{s}", .{titleFromFilename(rel)});
        const rag_id = extractRagId(source, fallback_id);
        const tags = extractTagsLine(source);
        const tags_out = if (tags.len > 0) tags else "[boris, system]";

        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);
        try doc.appendSlice(gpa, "---\n");
        try doc.appendSlice(gpa, "rag_id: ");
        try doc.appendSlice(gpa, rag_id);
        try doc.appendSlice(gpa, "\nrag_path: ");
        try doc.appendSlice(gpa, rag_path);
        try doc.appendSlice(gpa, "\ncategory: system\n");
        try doc.appendSlice(gpa, "tags: ");
        try doc.appendSlice(gpa, tags_out);
        try doc.appendSlice(gpa, "\n---\n\n");
        try doc.appendSlice(gpa, body);
        if (body.len == 0 or body[body.len - 1] != '\n') try doc.append(gpa, '\n');

        try writeBytes(io, out_dir, rag_path, doc.items);
        try appendCatalog(catalog, gpa, arena, .{
            .rag_id = rag_id,
            .rag_path = rag_path,
            .category = "system",
            .title = title,
            .tags = tags_out,
        });
        count += 1;
        log(opts, "  rag system  {s}\n", .{rag_path});
    }
    return count;
}

// ---------------------------------------------------------------------------
// Content pages
// ---------------------------------------------------------------------------

fn exportContentPages(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    pages: []const graph_mod.Node,
    content_root: []const u8,
    opts: RagOptions,
    catalog: *std.ArrayList(CatalogEntry),
) !usize {
    const cwd = Io.Dir.cwd();
    var content_dir = try cwd.openDir(io, content_root, .{});
    defer content_dir.close(io);

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    var n: usize = 0;
    // pages already sorted by entity id after freeze
    for (pages) |p| {
        _ = doc_arena.reset(.free_all);
        const scratch = doc_arena.allocator();

        const source = try readFileAlloc(io, content_dir, p.source_path, scratch);
        const parsed = parser.parse(source);
        if (parsed.diagnostic != null) {
            // Should not happen after successful compile; treat as I/O-class abort.
            return error.UnexpectedParseFailure;
        }
        // Component scan already hard-failed compile when invalid; re-tokenize
        // for export representation (:::kind blocks, non-round-trippable).
        const body = if (opts.input_format == .textile) blk: {
            const adapted = try textile.toMarkdown(parsed.doc.body, scratch);
            if (!adapted.isOk()) return error.UnexpectedParseFailure;
            break :blk adapted.markdown;
        } else parsed.doc.body;
        const tok = aside.tokenizeBody(body, scratch) catch return error.UnexpectedParseFailure;
        if (tok.hasErrors()) return error.UnexpectedParseFailure;
        const body_full = try exportBodyForRag(tok.segments, scratch);
        const title = pageTitle(p);
        const role = p.role.name();
        const parent = p.parent orelse "";
        const tags_str = try formatTags(arena, p.tags);

        const rag_path = try identity.ragPagePath(arena, p.id);
        const rag_id = try std.fmt.allocPrint(arena, "content/{s}", .{p.id});

        // related: direct graph neighbors only, stable order (parent first, then
        // children by entity id — pages are already id-sorted).
        var related: std.ArrayList(u8) = .empty;
        defer related.deinit(scratch);
        try related.appendSlice(scratch, "related:\n");
        if (parent.len > 0) {
            try related.appendSlice(scratch, "  - content/pages/");
            try related.appendSlice(scratch, parent);
            try related.appendSlice(scratch, ".md\n");
        }
        for (pages) |other| {
            if (other.role != .satellite) continue;
            const op = other.parent orelse continue;
            if (!std.mem.eql(u8, op, p.id)) continue;
            try related.appendSlice(scratch, "  - content/pages/");
            try related.appendSlice(scratch, other.id);
            try related.appendSlice(scratch, ".md\n");
        }

        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);

        try doc.appendSlice(gpa, "---\n");
        try doc.appendSlice(gpa, "rag_id: ");
        try doc.appendSlice(gpa, rag_id);
        try doc.appendSlice(gpa, "\nrag_path: ");
        try doc.appendSlice(gpa, rag_path);
        try doc.appendSlice(gpa, "\ncategory: content\n");
        try doc.appendSlice(gpa, "entity_id: ");
        try doc.appendSlice(gpa, p.id);
        try doc.appendSlice(gpa, "\nsource_path: ");
        try doc.appendSlice(gpa, p.source_path);
        try doc.appendSlice(gpa, "\nrole: ");
        try doc.appendSlice(gpa, role);
        try doc.append(gpa, '\n');
        if (parent.len > 0) {
            try doc.appendSlice(gpa, "parent_entry: ");
            try doc.appendSlice(gpa, parent);
            try doc.append(gpa, '\n');
        }
        try doc.appendSlice(gpa, "title: ");
        try doc.appendSlice(gpa, title);
        try doc.append(gpa, '\n');
        try doc.appendSlice(gpa, "tags: ");
        try doc.appendSlice(gpa, tags_str);
        try doc.append(gpa, '\n');
        try doc.appendSlice(gpa, related.items);
        try doc.appendSlice(gpa, "---\n\n");

        // Sole document H1 — metadata-owned (frontmatter title else entity id).
        try doc.appendSlice(gpa, "# ");
        try doc.appendSlice(gpa, title);
        try doc.appendSlice(gpa, "\n\n");
        try doc.appendSlice(gpa, body_full);
        if (body_full.len == 0 or body_full[body_full.len - 1] != '\n') {
            try doc.append(gpa, '\n');
        }

        try writeBytes(io, out_dir, rag_path, doc.items);
        try appendCatalog(catalog, gpa, arena, .{
            .rag_id = rag_id,
            .rag_path = rag_path,
            .category = "content",
            .title = title,
            .entity_id = p.id,
            .role = role,
            .parent_entry = parent,
            .tags = tags_str,
        });
        n += 1;
        log(opts, "  rag page    {s}\n", .{rag_path});
    }
    return n;
}

// ---------------------------------------------------------------------------
// Graph docs
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

    // entity-catalog.md
    {
        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);
        try doc.appendSlice(gpa,
            \\---
            \\rag_id: graph/entity-catalog
            \\rag_path: graph/entity-catalog.md
            \\category: graph
            \\tags: [graph, catalog, entities]
            \\related:
            \\  - graph/relations.md
            \\---
            \\
            \\# Entity catalog
            \\
            \\Content entities after shared scan / parse / graph validation.
            \\Pages are the only first-class graph nodes; asides are not nodes.
            \\
            \\| entity_id | title | role | source | RAG path |
            \\|-----------|-------|------|--------|----------|
            \\
        );
        for (pages) |p| {
            try doc.appendSlice(gpa, "| `");
            try doc.appendSlice(gpa, p.id);
            try doc.appendSlice(gpa, "` | ");
            try doc.appendSlice(gpa, pageTitle(p));
            try doc.appendSlice(gpa, " | ");
            try doc.appendSlice(gpa, p.role.name());
            try doc.appendSlice(gpa, " | `");
            try doc.appendSlice(gpa, p.source_path);
            try doc.appendSlice(gpa, "` | `content/pages/");
            try doc.appendSlice(gpa, p.id);
            try doc.appendSlice(gpa, ".md` |\n");
        }
        try writeBytes(io, out_dir, "graph/entity-catalog.md", doc.items);
        try appendCatalog(catalog, gpa, arena, .{
            .rag_id = "graph/entity-catalog",
            .rag_path = "graph/entity-catalog.md",
            .category = "graph",
            .title = "Entity catalog",
            .tags = "[graph, catalog, entities]",
        });
        n += 1;
        log(opts, "  rag graph   graph/entity-catalog.md\n", .{});
    }

    // relations.md — edges sorted by source id then target id
    {
        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);
        try doc.appendSlice(gpa,
            \\---
            \\rag_id: graph/relations
            \\rag_path: graph/relations.md
            \\category: graph
            \\tags: [graph, relations, trunk, satellite]
            \\related:
            \\  - graph/entity-catalog.md
            \\---
            \\
            \\# Graph relations (Trunk → Satellite)
            \\
            \\Edges come from satellite frontmatter `parent: <trunk-entity-id>`.
            \\Hubs and satellite lists are ordered by `entity_id`. Edge list is
            \\ordered by source id then target id. Invalid graphs never publish
            \\this file (shared `graph.validate` must pass first).
            \\
            \\## Trunk hubs
            \\
            \\
        );

        for (pages) |p| {
            if (p.role != .trunk) continue;
            try doc.appendSlice(gpa, "### `");
            try doc.appendSlice(gpa, p.id);
            try doc.appendSlice(gpa, "` — ");
            try doc.appendSlice(gpa, pageTitle(p));
            try doc.appendSlice(gpa, "\n\n");
            try doc.appendSlice(gpa, "- Trunk RAG: `content/pages/");
            try doc.appendSlice(gpa, p.id);
            try doc.appendSlice(gpa, ".md`\n");
            try doc.appendSlice(gpa, "- Satellites:\n");
            var any = false;
            for (pages) |child| {
                if (child.role != .satellite) continue;
                const par = child.parent orelse continue;
                if (!std.mem.eql(u8, par, p.id)) continue;
                any = true;
                try doc.appendSlice(gpa, "  - `");
                try doc.appendSlice(gpa, child.id);
                try doc.appendSlice(gpa, "` (");
                try doc.appendSlice(gpa, pageTitle(child));
                try doc.appendSlice(gpa, ") → `content/pages/");
                try doc.appendSlice(gpa, child.id);
                try doc.appendSlice(gpa, ".md`\n");
            }
            if (!any) try doc.appendSlice(gpa, "  - *(none)*\n");
            try doc.append(gpa, '\n');
        }

        try doc.appendSlice(gpa,
            \\## Edge list (machine-friendly)
            \\
            \\```
            \\
        );

        // Build (source_id, target_id) pairs and sort.
        const EdgePair = struct { src: []const u8, tgt: []const u8 };
        var pairs: std.ArrayList(EdgePair) = .empty;
        defer pairs.deinit(gpa);
        for (pages) |p| {
            if (p.role != .satellite) continue;
            const par = p.parent orelse continue;
            try pairs.append(gpa, .{ .src = p.id, .tgt = par });
        }
        std.mem.sort(EdgePair, pairs.items, {}, struct {
            fn less(_: void, a: EdgePair, b: EdgePair) bool {
                const o = std.mem.order(u8, a.src, b.src);
                if (o != .eq) return o == .lt;
                return std.mem.order(u8, a.tgt, b.tgt) == .lt;
            }
        }.less);
        for (pairs.items) |e| {
            try doc.appendSlice(gpa, "parent\t");
            try doc.appendSlice(gpa, e.src);
            try doc.appendSlice(gpa, "\t->\t");
            try doc.appendSlice(gpa, e.tgt);
            try doc.append(gpa, '\n');
        }
        try doc.appendSlice(gpa, "```\n");

        try writeBytes(io, out_dir, "graph/relations.md", doc.items);
        try appendCatalog(catalog, gpa, arena, .{
            .rag_id = "graph/relations",
            .rag_path = "graph/relations.md",
            .category = "graph",
            .title = "Graph relations (Trunk → Satellite)",
            .tags = "[graph, relations, trunk, satellite]",
        });
        n += 1;
        log(opts, "  rag graph   graph/relations.md\n", .{});
    }

    return n;
}

// ---------------------------------------------------------------------------
// Catalog / INDEX / UPLOAD-GUIDE
// ---------------------------------------------------------------------------

fn exportCatalogMeta(io: Io, out_dir: Io.Dir) !void {
    var buf: [160]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buf,
        "{{\"format\":\"{s}\",\"schema_version\":{d},\"boris_version\":\"{s}\"}}\n",
        .{ catalog_format, catalog_schema_version, boris_version },
    );
    try writeBytes(io, out_dir, "catalog_meta.json", text);
}

/// Fixed field order: rag_id, rag_path, category, title, entity_id, role, parent_entry, tags.
fn exportCatalogJsonl(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    catalog: []const CatalogEntry,
) !void {
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    for (catalog) |e| {
        try doc.appendSlice(gpa, "{\"rag_id\":\"");
        try json_out.escapeAppend(&doc, gpa, e.rag_id);
        try doc.appendSlice(gpa, "\",\"rag_path\":\"");
        try json_out.escapeAppend(&doc, gpa, e.rag_path);
        try doc.appendSlice(gpa, "\",\"category\":\"");
        try json_out.escapeAppend(&doc, gpa, e.category);
        try doc.appendSlice(gpa, "\",\"title\":\"");
        try json_out.escapeAppend(&doc, gpa, e.title);
        try doc.appendSlice(gpa, "\",\"entity_id\":\"");
        try json_out.escapeAppend(&doc, gpa, e.entity_id);
        try doc.appendSlice(gpa, "\",\"role\":\"");
        try json_out.escapeAppend(&doc, gpa, e.role);
        try doc.appendSlice(gpa, "\",\"parent_entry\":\"");
        try json_out.escapeAppend(&doc, gpa, e.parent_entry);
        try doc.appendSlice(gpa, "\",\"tags\":\"");
        try json_out.escapeAppend(&doc, gpa, e.tags);
        try doc.appendSlice(gpa, "\"}\n");
    }
    try writeBytes(io, out_dir, "catalog.jsonl", doc.items);
}

fn exportIndex(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    catalog: []const CatalogEntry,
    stats: RagStats,
) !void {
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);

    try doc.appendSlice(gpa,
        \\---
        \\rag_id: meta/index
        \\rag_path: INDEX.md
        \\category: meta
        \\tags: [index, catalog, retrieval-map]
        \\---
        \\
        \\# Boris RAG corpus — INDEX
        \\
        \\Master retrieval map for the Boris product RAG pack. Upload this
        \\directory tree to a chat LLM knowledge base.
        \\
        \\## Counts
        \\
        \\
    );
    try doc.print(gpa,
        \\| Segment | Count |
        \\|---------|------:|
        \\| system | {d} |
        \\| content pages | {d} |
        \\| graph | {d} |
        \\| catalog entries | {d} |
        \\
        \\
    , .{
        stats.system_docs,
        stats.content_pages,
        stats.graph_docs,
        stats.catalog_entries,
    });

    try doc.appendSlice(gpa,
        \\## Generated artifacts
        \\
        \\| Path | Role |
        \\|------|------|
        \\| `INDEX.md` | This retrieval map (catalog row) |
        \\| `UPLOAD-GUIDE.md` | Upload notes (catalog row) |
        \\| `catalog.jsonl` | Machine catalog — **not** a catalog row |
        \\| `catalog_meta.json` | Format + versions — **not** a catalog row |
        \\| `system/**` | Curated architecture seeds |
        \\| `content/pages/**` | Content page segments |
        \\| `graph/entity-catalog.md` | Entity table |
        \\| `graph/relations.md` | Trunk → Satellite edges |
        \\
        \\## Full catalog
        \\
        \\| rag_path | category | title | entity_id |
        \\|----------|----------|-------|-----------|
        \\
    );

    for (catalog) |e| {
        try doc.appendSlice(gpa, "| `");
        try doc.appendSlice(gpa, e.rag_path);
        try doc.appendSlice(gpa, "` | ");
        try doc.appendSlice(gpa, e.category);
        try doc.appendSlice(gpa, " | ");
        try doc.appendSlice(gpa, e.title);
        try doc.appendSlice(gpa, " | ");
        if (e.entity_id.len > 0) {
            try doc.appendSlice(gpa, "`");
            try doc.appendSlice(gpa, e.entity_id);
            try doc.appendSlice(gpa, "`");
        } else {
            try doc.appendSlice(gpa, "—");
        }
        try doc.appendSlice(gpa, " |\n");
    }

    try doc.appendSlice(gpa,
        \\
        \\## Catalog schema (stable field order)
        \\
        \\```text
        \\rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
        \\```
        \\
        \\Rows sorted by `rag_path`. No timestamps, absolute paths, hostnames,
        \\or random ids. Content title H1 is metadata-owned (frontmatter `title`
        \\else entity id). Source leading H1 stripped; remaining ATX H1s demoted
        \\to H2. Parsed `<Aside>` callouts are emitted as `:::kind` blocks
        \\(export representation only — not round-trippable authoring syntax).
        \\
        \\### catalog_meta.json
        \\
        \\```json
        \\{"format":"boris-rag","schema_version":1,"boris_version":"
    );
    try doc.appendSlice(gpa, boris_version);
    try doc.appendSlice(gpa,
        \\"}
        \\```
        \\
    );

    try writeBytes(io, out_dir, "INDEX.md", doc.items);
}

fn exportUploadGuide(io: Io, out_dir: Io.Dir) !void {
    const text =
        \\---
        \\rag_id: meta/upload-guide
        \\rag_path: UPLOAD-GUIDE.md
        \\category: meta
        \\tags: [upload, grok, gemini, llm, rag]
        \\related:
        \\  - INDEX.md
        \\---
        \\
        \\# Upload guide — Grok, Gemini, and similar chat LLMs
        \\
        \\## What to upload
        \\
        \\Upload the **entire** generated RAG directory. Prefer folder upload when
        \\the product supports it.
        \\
        \\Minimum useful set if you must subset:
        \\
        \\1. `INDEX.md` (always)
        \\2. All of `system/` (Boris behavior)
        \\3. All of `content/` (site knowledge)
        \\4. All of `graph/` (relations)
        \\
        \\Optional for scripts: `catalog.jsonl` and `catalog_meta.json` (machine
        \\files; not catalog rows).
        \\
        \\## Regenerating this corpus
        \\
        \\```bash
        \\zig build run -- --input content --rag
        \\zig build run -- --input content --rag-dir ./uploads/boris-rag
        \\```
        \\
        \\## Integrity notes
        \\
        \\- Paths inside documents are logical RAG paths (not OS-absolute).
        \\- Content segments mirror `entity_id` (`guides/intro` → `content/pages/guides/intro.md`).
        \\- Graph-dependent files are published only after shared `graph.validate` succeeds.
        \\- Parsed `<Aside>` callouts appear as `:::kind` export blocks (not authoring syntax).
        \\
    ;
    try writeBytes(io, out_dir, "UPLOAD-GUIDE.md", text);
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

    const retain = result.arena.allocator();
    const stage_rel = try std.fmt.allocPrint(gpa, "{s}.boris-rag-stage", .{opts.out_dir});
    defer gpa.free(stage_rel);

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, stage_rel) catch {};
    try ensureDirPath(io, stage_rel);

    var catalog: std.ArrayList(CatalogEntry) = .empty;
    defer catalog.deinit(gpa);

    var stats: RagStats = .{};

    log(opts, "\nExporting RAG corpus → {s}/\n", .{opts.out_dir});

    // Write into the staging directory, then close all handles before rename/publish.
    {
        var stage_dir = try cwd.openDir(io, stage_rel, .{});
        defer stage_dir.close(io);

        try stage_dir.createDirPath(io, "system");
        try stage_dir.createDirPath(io, "content/pages");
        try stage_dir.createDirPath(io, "graph");

        stats.system_docs = try exportSystemDocs(io, gpa, retain, stage_dir, opts, &catalog);
        stats.content_pages = try exportContentPages(
            io,
            gpa,
            retain,
            stage_dir,
            result.compile.pages.items,
            opts.content_root,
            opts,
            &catalog,
        );
        stats.graph_docs = try exportGraphDocs(
            io,
            gpa,
            retain,
            stage_dir,
            result.compile.pages.items,
            &catalog,
            opts,
        );

        try exportUploadGuide(io, stage_dir);
        try appendCatalog(&catalog, gpa, retain, .{
            .rag_id = "meta/upload-guide",
            .rag_path = "UPLOAD-GUIDE.md",
            .category = "meta",
            .title = "Upload guide — Grok, Gemini, and similar chat LLMs",
            .tags = "[upload, grok, gemini, llm, rag]",
        });
        try appendCatalog(&catalog, gpa, retain, .{
            .rag_id = "meta/index",
            .rag_path = "INDEX.md",
            .category = "meta",
            .title = "Boris RAG corpus — INDEX",
            .tags = "[index, catalog, retrieval-map]",
        });

        sortCatalogByRagPath(catalog.items);
        stats.catalog_entries = catalog.items.len;

        try exportIndex(io, gpa, stage_dir, catalog.items, stats);
        try exportCatalogJsonl(io, gpa, stage_dir, catalog.items);
        try exportCatalogMeta(io, stage_dir);
    }

    // Publish only after the full stage tree is written and handles closed.
    try publishCorpus(io, gpa, stage_rel, opts.out_dir);
    stats.published = true;
    result.stats = stats;

    log(opts,
        \\RAG export complete.
        \\  system={d}  pages={d}  graph={d}  catalog={d}
        \\
    , .{
        stats.system_docs,
        stats.content_pages,
        stats.graph_docs,
        stats.catalog_entries,
    });

    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "prepareContentBody strips leading H1 and demotes extras" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try prepareContentBody("# Title\n\nBody.\n", a);
    try std.testing.expectEqualStrings("\nBody.\n", one);
    try std.testing.expectEqual(@as(usize, 0), countAtxH1(one));

    const multi = try prepareContentBody("# Keep meta\n\nPara.\n# Second\n", a);
    try std.testing.expectEqual(@as(usize, 0), countAtxH1(multi));
    try std.testing.expect(std.mem.indexOf(u8, multi, "## Second") != null);
}

test "catalog_meta.json shape is fixed and compact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/meta-only", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);
    var out_dir = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out_dir.close(io);

    try exportCatalogMeta(io, out_dir);

    const bytes = try readFileAlloc(io, out_dir, "catalog_meta.json", gpa);
    defer gpa.free(bytes);

    const expected = try std.fmt.allocPrint(
        gpa,
        "{{\"format\":\"{s}\",\"schema_version\":{d},\"boris_version\":\"{s}\"}}\n",
        .{ catalog_format, catalog_schema_version, boris_version },
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);

    const fmt_i = std.mem.indexOf(u8, bytes, "\"format\"").?;
    const sch_i = std.mem.indexOf(u8, bytes, "\"schema_version\"").?;
    const bor_i = std.mem.indexOf(u8, bytes, "\"boris_version\"").?;
    try std.testing.expect(fmt_i < sch_i);
    try std.testing.expect(sch_i < bor_i);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("boris-rag", parsed.value.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
}

test "catalog.jsonl field order and string escaping" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/jsonl-only", .{tmp.sub_path});
    defer gpa.free(out_rel);
    try Io.Dir.cwd().createDirPath(io, out_rel);
    var out_dir = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out_dir.close(io);

    const entries = [_]CatalogEntry{.{
        .rag_id = "content/quote",
        .rag_path = "content/pages/quote.md",
        .category = "content",
        .title = "Say \"hi\"\nthere",
        .entity_id = "quote",
        .role = "trunk",
        .parent_entry = "",
        .tags = "[content, trunk]",
    }};
    try exportCatalogJsonl(io, gpa, out_dir, &entries);

    const bytes = try readFileAlloc(io, out_dir, "catalog.jsonl", gpa);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
    const line = bytes[0 .. bytes.len - 1];
    const expected =
        \\{"rag_id":"content/quote","rag_path":"content/pages/quote.md","category":"content","title":"Say \"hi\"\nthere","entity_id":"quote","role":"trunk","parent_entry":"","tags":"[content, trunk]"}
    ;
    try std.testing.expectEqualStrings(expected, line);

    const keys = [_][]const u8{ "rag_id", "rag_path", "category", "title", "entity_id", "role", "parent_entry", "tags" };
    var prev: usize = 0;
    for (keys) |k| {
        const needle = try std.fmt.allocPrint(gpa, "\"{s}\":", .{k});
        defer gpa.free(needle);
        const pos = std.mem.indexOfPos(u8, line, prev, needle) orelse return error.TestExpectedEqual;
        prev = pos + needle.len;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("content/quote", parsed.value.object.get("rag_id").?.string);
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

fn requiredRagFilesPresent(io: Io, out_rel: []const u8) !void {
    const names = [_][]const u8{
        "INDEX.md",
        "UPLOAD-GUIDE.md",
        "catalog.jsonl",
        "catalog_meta.json",
        "graph/entity-catalog.md",
        "graph/relations.md",
    };
    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);
    for (names) |name| {
        _ = out.statFile(io, name, .{}) catch return error.MissingRequiredRagFile;
    }
}

test "rag export: valid corpus, dual-run determinism, catalog, H1, system order" {
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
        .quiet = true,
    });
    defer res_a.deinit();
    try std.testing.expect(res_a.ok());
    try std.testing.expectEqual(@as(usize, 4), res_a.stats.content_pages);
    try std.testing.expectEqual(@as(usize, 2), res_a.stats.system_docs);
    try requiredRagFilesPresent(io, paths.out_a);

    var res_b = try run(io, gpa, .{
        .content_root = paths.content,
        .out_dir = paths.out_b,
        .system_docs_dir = paths.system,
        .quiet = true,
    });
    defer res_b.deinit();
    try std.testing.expect(res_b.ok());
    try expectDirsByteIdentical(io, gpa, paths.out_a, paths.out_b);

    var out = try Io.Dir.cwd().openDir(io, paths.out_a, .{});
    defer out.close(io);

    // catalog_meta
    const meta = try readFileAlloc(io, out, "catalog_meta.json", gpa);
    defer gpa.free(meta);
    var meta_j = try std.json.parseFromSlice(std.json.Value, gpa, meta, .{});
    defer meta_j.deinit();
    try std.testing.expectEqualStrings("boris-rag", meta_j.value.object.get("format").?.string);

    // catalog.jsonl: each line independent JSON; stable field order; sorted paths; relative `/`
    const jsonl = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(jsonl);
    var path_arena = std.heap.ArenaAllocator.init(gpa);
    defer path_arena.deinit();
    const path_retain = path_arena.allocator();
    var line_start: usize = 0;
    var prev_path: []const u8 = "";
    var line_count: usize = 0;
    while (line_start < jsonl.len) {
        var line_end = line_start;
        while (line_end < jsonl.len and jsonl[line_end] != '\n') : (line_end += 1) {}
        const line = jsonl[line_start..line_end];
        if (line.len > 0) {
            line_count += 1;
            try std.testing.expect(std.mem.startsWith(u8, line, "{\"rag_id\":\""));
            const keys = [_][]const u8{ "rag_id", "rag_path", "category", "title", "entity_id", "role", "parent_entry", "tags" };
            var prev: usize = 0;
            for (keys) |k| {
                const needle = try std.fmt.allocPrint(gpa, "\"{s}\":", .{k});
                defer gpa.free(needle);
                const pos = std.mem.indexOfPos(u8, line, prev, needle) orelse return error.TestExpectedEqual;
                prev = pos + needle.len;
            }
            var row = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
            defer row.deinit();
            const rp = row.value.object.get("rag_path").?.string;
            try std.testing.expect(std.mem.indexOf(u8, rp, "\\") == null);
            try std.testing.expect(rp.len == 0 or rp[0] != '/');
            if (prev_path.len > 0) {
                try std.testing.expect(std.mem.order(u8, prev_path, rp) == .lt);
            }
            prev_path = try path_retain.dupe(u8, rp);
        }
        line_start = if (line_end < jsonl.len) line_end + 1 else jsonl.len;
    }
    try std.testing.expect(line_count >= 8);

    // system seed order
    const a_sys = std.mem.indexOf(u8, jsonl, "system/a-first.md").?;
    const b_sys = std.mem.indexOf(u8, jsonl, "system/b-second.md").?;
    try std.testing.expect(a_sys < b_sys);

    // content order by entity id in catalog paths
    const a_c = std.mem.indexOf(u8, jsonl, "content/pages/a-first.md").?;
    const g_c = std.mem.indexOf(u8, jsonl, "content/pages/guides/nested.md").?;
    const m_c = std.mem.indexOf(u8, jsonl, "content/pages/m-mid.md").?;
    const z_c = std.mem.indexOf(u8, jsonl, "content/pages/z-last.md").?;
    try std.testing.expect(a_c < g_c and g_c < m_c and m_c < z_c);

    // exactly one H1 per content page
    const page_paths = [_][]const u8{
        "content/pages/a-first.md",
        "content/pages/m-mid.md",
        "content/pages/z-last.md",
        "content/pages/guides/nested.md",
    };
    for (page_paths) |pp| {
        const body = try readFileAlloc(io, out, pp, gpa);
        defer gpa.free(body);
        try std.testing.expectEqual(@as(usize, 1), countAtxH1(body));
    }
    const mid = try readFileAlloc(io, out, "content/pages/m-mid.md", gpa);
    defer gpa.free(mid);
    try std.testing.expect(std.mem.indexOf(u8, mid, "# M Mid\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "Source H1 Should Vanish") == null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "## Nested H1 Becomes H2") != null);

    // Asides export as :::kind (non-round-trippable); raw <Aside> must not remain.
    const zpage = try readFileAlloc(io, out, "content/pages/z-last.md", gpa);
    defer gpa.free(zpage);
    try std.testing.expect(std.mem.indexOf(u8, zpage, ":::tip{id=\"z1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, zpage, "Tip body.") != null);
    try std.testing.expect(std.mem.indexOf(u8, zpage, "<Aside") == null);

    // INDEX uses sorted catalog
    const index = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "catalog_meta.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "content/pages/a-first.md") != null);
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

    // Same diagnostic codes (categories) present in both modes.
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

    // Graph-dependent RAG files must not be published as a fresh corpus.
    // Prior out dir is left alone (no staging rename on failure).
    var out = try Io.Dir.cwd().openDir(io, rag_out, .{});
    defer out.close(io);
    _ = out.statFile(io, "stale-marker.txt", .{}) catch return error.TestUnexpectedResult;
    const has_catalog = blk: {
        _ = out.statFile(io, "catalog.jsonl", .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!has_catalog);
    const has_relations = blk: {
        _ = out.statFile(io, "graph/relations.md", .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!has_relations);
}

test "rag export against fixtures/content/valid" {
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
    try requiredRagFilesPresent(io, out);
    try std.testing.expect(res.stats.content_pages >= 2);

    // Second publish must replace via move-aside, not delete-before-install.
    var res2 = try run(io, gpa, .{
        .content_root = "fixtures/content/valid",
        .out_dir = out,
        .system_docs_dir = "docs/rag/system",
        .quiet = true,
    });
    defer res2.deinit();
    try std.testing.expect(res2.ok());
    try requiredRagFilesPresent(io, out);
    // Leftover swap dirs must not linger after a successful second publish.
    const cwd = Io.Dir.cwd();
    const prev = try std.fmt.allocPrint(gpa, "{s}.boris-rag-prev", .{out});
    defer gpa.free(prev);
    const next = try std.fmt.allocPrint(gpa, "{s}.boris-rag-next", .{out});
    defer gpa.free(next);
    if (cwd.openDir(io, prev, .{})) |*d| {
        d.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
    if (cwd.openDir(io, next, .{})) |*d| {
        d.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}

    // Parse catalog_meta + each JSONL line
    var dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer dir.close(io);
    const meta = try readFileAlloc(io, dir, "catalog_meta.json", gpa);
    defer gpa.free(meta);
    var mj = try std.json.parseFromSlice(std.json.Value, gpa, meta, .{});
    defer mj.deinit();

    const jsonl = try readFileAlloc(io, dir, "catalog.jsonl", gpa);
    defer gpa.free(jsonl);
    var ls: usize = 0;
    while (ls < jsonl.len) {
        var le = ls;
        while (le < jsonl.len and jsonl[le] != '\n') : (le += 1) {}
        const line = jsonl[ls..le];
        if (line.len > 0) {
            var row = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
            defer row.deinit();
        }
        ls = if (le < jsonl.len) le + 1 else jsonl.len;
    }
}
