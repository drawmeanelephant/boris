//! RAG corpus exporter — LLM-friendly, path-segmented markdown for chat upload.
//!
//! Output tree (default `rag/`):
//!   INDEX.md, UPLOAD-GUIDE.md, catalog.jsonl, catalog_meta.json
//!   system/*.md          — curated architecture knowledge
//!   content/pages/**     — site pages (entity-path mirrored; asides inlined)
//!   graph/*.md           — entity catalog + trunk→satellite edges
//!
//! Normative machine contract: `docs/contracts/rag-export.md`.
//!
//! Determinism (hard requirements):
//! - No wall-clock timestamps, random IDs, absolute paths, hostnames, or
//!   environment-specific fields in corpus files.
//! - Never serialize from hash-map iteration order.
//! - Stable sort keys (see contract):
//!     system seeds     → relative path under system_docs_dir
//!     content pages    → entity_id
//!     graph hubs/edges → entity_id
//!     catalog / INDEX  → rag_path
//!
//! Graph edges are **validated** before export via `graph.validate` (same
//! single entry as the IR compiler): duplicate ids, missing parent, self-parent,
//! multi-hop (satellite-of-satellite), and cycles are all hard fails.
//!
//! `catalog_meta.json` is corpus-level machine metadata (format + versions).
//! It is part of the generated tree and INDEX documentation but is **not** a
//! `catalog.jsonl` entry (same policy as `catalog.jsonl` itself).
//!
//! `catalog.jsonl` schema (one JSON object per line, field order fixed):
//!   rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
//!
//! Title / H1 ownership for content pages: **metadata-owned**.
//! Frontmatter `title` (else entity_id) is the sole document H1; a leading
//! source H1 is stripped and any remaining ATX H1 lines are demoted to H2.
//!
//! RAG `:::kind` blocks are an **export representation** of authoring
//! `<Aside>` components — not necessarily round-trippable authoring syntax.
//!
//! Content parse policy: one shared pass via `parser.parsePageSource` — the
//! same full-page entry point as the HTML compile loop (`compile.zig`).
//!
//! Native Zig only. No Node, Python, or external packagers.

const std = @import("std");
const Io = std.Io;
const page_mod = @import("page.zig");
const parser = @import("parser.zig");
const graph_mod = @import("graph.zig");
const diag = @import("diag.zig");
const scanner = @import("scanner.zig");
const pathutil = @import("pathutil.zig");
const json_out = @import("json_out.zig");
const PageDb = page_mod.PageDb;
const Frontmatter = page_mod.Frontmatter;

/// Machine format id written into `catalog_meta.json`.
pub const catalog_format = "boris-rag";

/// Integer schema version for the RAG catalog machine interface.
/// Bump only when `catalog.jsonl` / `catalog_meta.json` shape breaks consumers.
pub const catalog_schema_version: u32 = 1;

/// Product version stamped into `catalog_meta.json` (not per-line in catalog.jsonl).
pub const boris_version = "0.1.1";

pub const RagOptions = struct {
    out_dir: []const u8 = "rag",
    content_dir: []const u8 = "content",
    system_docs_dir: []const u8 = "docs/rag/system",
    quiet: bool = false,
};

pub const RagStats = struct {
    system_docs: usize = 0,
    content_pages: usize = 0,
    graph_docs: usize = 0,
    catalog_entries: usize = 0,
};

// ---------------------------------------------------------------------------
// Shared parse cache (one parsePageSource per content page)
// ---------------------------------------------------------------------------

/// In-memory parse result for one content page, shared by meta + body export.
///
/// `parsed` slices are zero-copy into source bytes retained on `arena`.
/// Built only via `parser.parsePageSource` — identical entry point to
/// `compile.zig`'s whiteboard loop, so HTML-path and RAG-path body trees
/// cannot diverge from different parsers or configurations.
const CachedParse = struct {
    entity_id: []const u8,
    source_path: []const u8,
    output_path: []const u8,
    /// Full pre-render parse; lives on the export retain arena with its source.
    parsed: parser.ParsedPage,
};

/// Read each page once and parse with `parser.parsePageSource` (compile-identical).
/// Callers must keep `arena` alive for the lifetime of the returned slice.
fn buildParseCache(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    db: *const PageDb,
    content_dir_name: []const u8,
) ![]CachedParse {
    const cwd = Io.Dir.cwd();
    var content_dir = try cwd.openDir(io, content_dir_name, .{});
    defer content_dir.close(io);

    var list: std.ArrayList(CachedParse) = .empty;
    errdefer list.deinit(gpa);

    try list.ensureTotalCapacity(gpa, db.items().len);

    for (db.items()) |p| {
        // Source + ParsedPage both on export arena so segment slices stay valid.
        const source = try readFileAlloc(io, content_dir, p.source_path, arena);
        const parsed = try parser.parsePageSource(source, arena);
        if (parsed.hasErrors()) {
            for (parsed.diagnostics) |d| {
                var line_buf: std.ArrayList(u8) = .empty;
                defer line_buf.deinit(gpa);
                try parser.formatDiag(d, p.source_path, &line_buf, gpa);
                std.log.err("{s}", .{line_buf.items});
            }
            return error.ComponentParseFailed;
        }
        try list.append(gpa, .{
            .entity_id = p.entity_id,
            .source_path = p.source_path,
            .output_path = p.output_path,
            .parsed = parsed,
        });
    }

    return try list.toOwnedSlice(gpa);
}

fn findCachedParse(cache: []const CachedParse, entity_id: []const u8) ?CachedParse {
    for (cache) |c| {
        if (std.mem.eql(u8, c.entity_id, entity_id)) return c;
    }
    return null;
}

/// Machine interface row for `catalog.jsonl` (pinned schema).
const CatalogEntry = struct {
    rag_id: []const u8,
    rag_path: []const u8,
    category: []const u8,
    title: []const u8,
    entity_id: []const u8 = "",
    /// `trunk` | `satellite` for content pages; empty for system/graph/meta.
    role: []const u8 = "",
    /// Parent entity id for satellites; empty otherwise.
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

/// Escape a string for JSON double quotes (same rules as IR `json_out`).
fn jsonEscapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try json_out.escapeAppend(buf, gpa, s);
}

/// True when `line` (already left-trimmed of spaces/tabs) is an ATX level-1 heading.
fn isAtxH1Line(left_trimmed: []const u8) bool {
    if (left_trimmed.len == 0) return false;
    if (left_trimmed[0] != '#') return false;
    if (left_trimmed.len >= 2 and left_trimmed[1] == '#') return false;
    if (left_trimmed.len == 1) return true;
    return left_trimmed[1] == ' ' or left_trimmed[1] == '\t';
}

/// Drop a leading ATX H1 (and blank lines before it) so metadata can own the title H1.
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
        // First non-blank line is not an H1 — keep original body intact.
        return body;
    }
    return body;
}

/// Demote remaining ATX H1 lines to H2 so exported content has exactly one H1
/// (the metadata-owned title injected by the exporter).
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

/// Prepare content body under metadata-owned H1 policy.
fn prepareContentBody(body: []const u8, arena: std.mem.Allocator) ![]const u8 {
    return demoteAtxH1ToH2(stripLeadingAtxH1(body), arena);
}

/// Count ATX level-1 headings (for tests / invariants).
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

/// Stable catalog order: ascending `rag_path` (byte-wise). Never rely on append order alone.
fn sortCatalogByRagPath(entries: []CatalogEntry) void {
    std.mem.sort(CatalogEntry, entries, {}, struct {
        fn less(_: void, a: CatalogEntry, b: CatalogEntry) bool {
            return std.mem.order(u8, a.rag_path, b.rag_path) == .lt;
        }
    }.less);
}

fn firstHeadingOrFallback(body: []const u8, fallback: []const u8) []const u8 {
    var i: usize = 0;
    while (i < body.len) {
        // Skip leading blank lines.
        var line_end = i;
        while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
        var line = body[i..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            i = if (line_end < body.len) line_end + 1 else body.len;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "# ")) {
            return std.mem.trim(u8, trimmed[2..], " \t");
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

/// Strip existing YAML frontmatter so we can rewrite a normalized header.
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

fn extractRelatedBlock(source: []const u8, arena: std.mem.Allocator) ![]const u8 {
    // Best-effort: copy related: list lines from seed frontmatter if present.
    if (!std.mem.startsWith(u8, source, "---")) return "";
    var i: usize = 3;
    if (i < source.len and source[i] == '\r') i += 1;
    if (i < source.len and source[i] == '\n') i += 1;
    var related_lines: std.ArrayList(u8) = .empty;
    defer related_lines.deinit(arena);
    var in_related = false;
    var line_start = i;
    while (line_start < source.len) {
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var line = source[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) break;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "related:")) {
            in_related = true;
            try related_lines.appendSlice(arena, line);
            try related_lines.append(arena, '\n');
        } else if (in_related) {
            if (std.mem.startsWith(u8, trimmed, "- ") or trimmed.len == 0) {
                try related_lines.appendSlice(arena, line);
                try related_lines.append(arena, '\n');
            } else {
                in_related = false;
            }
        }

        if (line_end < source.len and source[line_end] == '\n') {
            line_start = line_end + 1;
        } else break;
    }
    return try related_lines.toOwnedSlice(arena);
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
// System docs
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
            std.log.warn("system docs dir '{s}' missing; skipping system RAG seeds", .{opts.system_docs_dir});
            return 0;
        },
        else => return err,
    };
    defer sys_dir.close(io);

    // Collect relative paths first, then sort — never emit in filesystem walk order.
    var rels: std.ArrayList([]const u8) = .empty;
    defer rels.deinit(gpa);
    {
        var walker = try sys_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".md")) continue;
            try rels.append(gpa, try arena.dupe(u8, entry.path));
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
        const related_block = try extractRelatedBlock(source, arena);

        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);
        try doc.appendSlice(gpa, "---\n");
        try doc.appendSlice(gpa, "rag_id: ");
        try doc.appendSlice(gpa, rag_id);
        try doc.appendSlice(gpa, "\nrag_path: ");
        try doc.appendSlice(gpa, rag_path);
        try doc.appendSlice(gpa, "\ncategory: system\n");
        if (tags.len > 0) {
            try doc.appendSlice(gpa, "tags: ");
            try doc.appendSlice(gpa, tags);
            try doc.append(gpa, '\n');
        } else {
            try doc.appendSlice(gpa, "tags: [boris, system]\n");
        }
        if (related_block.len > 0) {
            try doc.appendSlice(gpa, related_block);
        }
        try doc.appendSlice(gpa, "---\n\n");
        try doc.appendSlice(gpa, body);
        if (body.len == 0 or body[body.len - 1] != '\n') try doc.append(gpa, '\n');

        try writeBytes(io, out_dir, rag_path, doc.items);
        try appendCatalog(catalog, gpa, arena, .{
            .rag_id = rag_id,
            .rag_path = rag_path,
            .category = "system",
            .title = title,
            .tags = if (tags.len > 0) tags else "[boris, system]",
        });
        count += 1;
        log(opts, "  rag system  {s}\n", .{rag_path});
    }
    return count;
}

// ---------------------------------------------------------------------------
// Content pages (asides inlined into page body)
// ---------------------------------------------------------------------------

fn exportContentPages(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    /// Shared parse cache (already validated; no disk re-read).
    cache: []const CachedParse,
    /// Validated, entity_id-sorted page metas (graph neighbors for `related:`).
    metas: []const PageMeta,
    opts: RagOptions,
    catalog: *std.ArrayList(CatalogEntry),
) !usize {
    var pages_n: usize = 0;

    // Whiteboard for per-page body/related scratch only (not re-parsing).
    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    // Emit pages in deterministic entity_id order (metas already sorted).
    for (metas) |m| {
        const cached = findCachedParse(cache, m.entity_id) orelse continue;
        const parsed = cached.parsed;

        _ = doc_arena.reset(.free_all);
        const scratch = doc_arena.allocator();

        // Prefer full document body with asides inlined (callouts stay on-page).
        // Segments come from the shared parsePageSource result — same tree as HTML.
        // `:::kind` blocks are export representation only (not authoring syntax).
        const body_raw = try parser.bodyWithAsidesInline(parsed.segments, scratch);
        // Metadata-owned H1: strip/demote source H1s so exactly one document H1 remains.
        const body_full = try prepareContentBody(body_raw, scratch);
        const title = m.title;
        const role = m.role;
        const parent = m.parent_entry;

        const entity_id = m.entity_id;
        const source_path = m.source_path;

        // Output paths only from validated entity ids (no output-root escape).
        const rag_path = try pathutil.ragPagePath(arena, entity_id);
        const rag_id = try pathutil.ragCatalogId(arena, entity_id);

        // related: direct graph neighbors only (token-efficient; INDEX is the hub).
        // Children are emitted in metas order (already sorted by entity_id).
        var related: std.ArrayList(u8) = .empty;
        defer related.deinit(scratch);
        try related.appendSlice(scratch, "related:\n");
        if (parent.len > 0) {
            try related.appendSlice(scratch, "  - content/pages/");
            try related.appendSlice(scratch, parent);
            try related.appendSlice(scratch, ".md\n");
        }
        for (metas) |other| {
            if (!std.mem.eql(u8, other.role, "satellite")) continue;
            if (!std.mem.eql(u8, other.parent_entry, entity_id)) continue;
            try related.appendSlice(scratch, "  - content/pages/");
            try related.appendSlice(scratch, other.entity_id);
            try related.appendSlice(scratch, ".md\n");
        }

        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);

        // Self-contained frontmatter (relative logical paths only — no absolutes/hosts).
        try doc.appendSlice(gpa, "---\n");
        try doc.appendSlice(gpa, "rag_id: ");
        try doc.appendSlice(gpa, rag_id);
        try doc.appendSlice(gpa, "\nrag_path: ");
        try doc.appendSlice(gpa, rag_path);
        try doc.appendSlice(gpa, "\ncategory: content\n");
        try doc.appendSlice(gpa, "entity_id: ");
        try doc.appendSlice(gpa, entity_id);
        try doc.appendSlice(gpa, "\nsource_path: content/");
        try doc.appendSlice(gpa, source_path);
        try doc.appendSlice(gpa, "\noutput_path: dist/");
        try doc.appendSlice(gpa, cached.output_path);
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
        try doc.print(gpa, "asides: {d}\n", .{parsed.asides.len});
        try doc.appendSlice(gpa, "tags: [content, ");
        try doc.appendSlice(gpa, role);
        try doc.appendSlice(gpa, "]\n");
        try doc.appendSlice(gpa, related.items);
        try doc.appendSlice(gpa, "---\n\n");

        // Sole document H1 — owned by frontmatter title (else entity_id).
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
            .entity_id = entity_id,
            .role = role,
            .parent_entry = parent,
            .tags = if (std.mem.eql(u8, role, "satellite")) "[content, satellite]" else "[content, trunk]",
        });
        pages_n += 1;
        log(opts, "  rag page    {s}\n", .{rag_path});
    }

    return pages_n;
}

// ---------------------------------------------------------------------------
// Graph docs
// ---------------------------------------------------------------------------

const PageMeta = struct {
    entity_id: []const u8,
    title: []const u8,
    role: []const u8,
    parent_entry: []const u8,
    source_path: []const u8,
};

/// Prefer frontmatter `id:` override when present in extras (compiler dialect);
/// otherwise path-derived entity id. Aligns graph keys with the IR path so
/// `E_DUP_ID` fixtures resolve the same way on both product surfaces.
///
/// Overrides are run through `pathutil.normalizeEntityId` so RAG output paths
/// stay under validated entity-id shape (no `..` / absolute / `\` leakage).
fn entityIdFromParsed(arena: std.mem.Allocator, path_entity_id: []const u8, fm: Frontmatter) ![]const u8 {
    for (fm.extras) |kv| {
        if (std.mem.eql(u8, kv.key, "id") and kv.value.len > 0) {
            return pathutil.normalizeEntityId(arena, kv.value) catch {
                // Fall back to path-derived id if override is malformed.
                return try arena.dupe(u8, path_entity_id);
            };
        }
    }
    return try arena.dupe(u8, path_entity_id);
}

/// Normalize parent foreign key the same way as entity ids (or empty).
fn parentFromParsed(arena: std.mem.Allocator, fm: Frontmatter) ![]const u8 {
    const parent = fm.parent_entry orelse return "";
    if (parent.len == 0) return "";
    return pathutil.normalizeEntityId(arena, parent) catch {
        // Keep raw for graph diagnostics (missing/illegal parent still fails validate).
        return try arena.dupe(u8, parent);
    };
}

/// Build PageMeta from the shared parse cache (no disk I/O, no re-parse).
fn collectPageMeta(
    arena: std.mem.Allocator,
    cache: []const CachedParse,
) ![]PageMeta {
    var list: std.ArrayList(PageMeta) = .empty;
    for (cache) |c| {
        const parsed = c.parsed;
        const entity_id = try entityIdFromParsed(arena, c.entity_id, parsed.frontmatter);
        const title = if (parsed.frontmatter.title) |t| t else entity_id;
        const role = if (parsed.frontmatter.isSatellite()) "satellite" else "trunk";
        const parent = try parentFromParsed(arena, parsed.frontmatter);
        try list.append(arena, .{
            .entity_id = entity_id,
            .title = try arena.dupe(u8, title),
            .role = try arena.dupe(u8, role),
            .parent_entry = parent,
            .source_path = try arena.dupe(u8, c.source_path),
        });
    }
    return try list.toOwnedSlice(arena);
}

/// Sort by entity_id and validate via shared `graph.validate` (dups + topology).
/// Hard-fails on duplicate id, missing parent, self-parent, multi-hop, or cycles.
fn validateAndSortPageMeta(
    gpa: std.mem.Allocator,
    metas: []PageMeta,
    opts: RagOptions,
) !void {
    std.mem.sort(PageMeta, metas, {}, struct {
        fn less(_: void, a: PageMeta, b: PageMeta) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);

    // Provisional nodes → single shared graph entry (same as pipeline).
    const nodes = try gpa.alloc(graph_mod.Node, metas.len);
    defer gpa.free(nodes);
    for (metas, 0..) |m, i| {
        nodes[i] = .{
            .id = m.entity_id,
            .source_path = m.source_path,
            .title = m.title,
            .parent = if (m.parent_entry.len > 0) m.parent_entry else null,
        };
    }

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    const retain = retain_arena.allocator();

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    // Case-insensitive entity-id collisions (after optional id: overrides).
    var i: usize = 0;
    while (i < metas.len) : (i += 1) {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (!pathutil.pathsDifferOnlyInCase(metas[i].entity_id, metas[j].entity_id)) continue;
            const msg = try std.fmt.allocPrint(
                retain,
                "entity ids differ only in case: \"{s}\" ({s}) and \"{s}\" ({s})",
                .{ metas[i].entity_id, metas[i].source_path, metas[j].entity_id, metas[j].source_path },
            );
            try diags.append(gpa, .{
                .severity = .error_,
                .code = .E_ENTITY_CASE_COLLISION,
                .message = msg,
                .remediation = try retain.dupe(u8, "Rename a file or id: override so entity ids are unique ignoring case"),
                .source_path = metas[i].source_path,
                .line = 1,
                .column = 1,
                .id = metas[i].entity_id,
            });
            break;
        }
    }

    try graph_mod.validate(gpa, retain, nodes, &diags);
    diag.sortDiagnostics(diags.items);

    // Mirror classified roles onto metas (validator is source of truth).
    for (metas, nodes) |*m, n| {
        m.role = if (n.role == .satellite) "satellite" else "trunk";
    }

    const hard_errors = diag.countErrors(diags.items);
    for (diags.items) |d| {
        const line = try diag.formatText(d, gpa);
        defer gpa.free(line);
        if (d.isError()) {
            std.log.err("{s}", .{line});
        } else {
            std.log.warn("{s}", .{line});
        }
    }

    if (hard_errors > 0) return error.GraphValidationFailed;
    if (!opts.quiet) {
        log(opts, "  graph ok    {d} entities (sorted by entity_id)\n", .{metas.len});
    }
}

/// Test/helper: run the same graph validation RAG uses on a content tree.
/// Returns collected diagnostics (strings owned by `retain`). Does not write corpus files.
pub fn validateContentGraph(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    content_dir: []const u8,
    diags: *std.ArrayList(diag.Diagnostic),
) !void {
    var db = PageDb.init(gpa);
    defer db.deinit();
    try scanner.scanFromCwd(io, &db, content_dir);

    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();
    const arena = parse_arena.allocator();

    const parse_cache = try buildParseCache(io, gpa, arena, &db, content_dir);
    defer gpa.free(parse_cache);

    const metas = try collectPageMeta(arena, parse_cache);
    // Diagnostics messages are allocated on an internal arena inside
    // validateAndSortPageMetaCollect; re-run shared validate with retain so
    // callers can keep messages for the test duration.
    std.mem.sort(PageMeta, metas, {}, struct {
        fn less(_: void, a: PageMeta, b: PageMeta) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);
    const nodes = try gpa.alloc(graph_mod.Node, metas.len);
    defer gpa.free(nodes);
    for (metas, 0..) |m, i| {
        nodes[i] = .{
            .id = m.entity_id,
            .source_path = m.source_path,
            .title = m.title,
            .parent = if (m.parent_entry.len > 0) m.parent_entry else null,
        };
    }
    try graph_mod.validate(gpa, retain, nodes, diags);
    diag.sortDiagnostics(diags.items);
    if (diag.countErrors(diags.items) > 0) return error.GraphValidationFailed;
}

fn exportGraphDocs(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    metas: []const PageMeta,
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
            \\  - system/03-trunk-and-satellite.md
            \\---
            \\
            \\# Entity catalog
            \\
            \\Complete list of content entities known to Boris after scanning `content/`.
            \\Pages are the only first-class graph nodes; asides remain in-page content.
            \\
            \\| entity_id | title | role | source | RAG path |
            \\|-----------|-------|------|--------|----------|
            \\
        );
        for (metas) |m| {
            try doc.appendSlice(gpa, "| `");
            try doc.appendSlice(gpa, m.entity_id);
            try doc.appendSlice(gpa, "` | ");
            try doc.appendSlice(gpa, m.title);
            try doc.appendSlice(gpa, " | ");
            try doc.appendSlice(gpa, m.role);
            try doc.appendSlice(gpa, " | `content/");
            try doc.appendSlice(gpa, m.source_path);
            try doc.appendSlice(gpa, "` | `content/pages/");
            try doc.appendSlice(gpa, m.entity_id);
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

    // relations.md
    {
        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);
        try doc.appendSlice(gpa,
            \\---
            \\rag_id: graph/relations
            \\rag_path: graph/relations.md
            \\category: graph
            \\tags: [graph, relations, trunk, satellite, parentEntry]
            \\related:
            \\  - graph/entity-catalog.md
            \\  - system/03-trunk-and-satellite.md
            \\---
            \\
            \\# Graph relations (Trunk → Satellite)
            \\
            \\Edges are declared by satellite frontmatter `parentEntry: <trunk-entity-id>`.
            \\Trunk hubs and satellite lists are ordered by `entity_id` (deterministic).
            \\Missing parents and satellite-of-satellite chains fail the export (hard errors).
            \\
            \\## Trunk hubs
            \\
            \\
        );

        // metas are sorted by entity_id; hubs and children therefore emit deterministically.
        for (metas) |m| {
            if (!std.mem.eql(u8, m.role, "trunk")) continue;
            try doc.appendSlice(gpa, "### `");
            try doc.appendSlice(gpa, m.entity_id);
            try doc.appendSlice(gpa, "` — ");
            try doc.appendSlice(gpa, m.title);
            try doc.appendSlice(gpa, "\n\n");
            try doc.appendSlice(gpa, "- Trunk RAG: `content/pages/");
            try doc.appendSlice(gpa, m.entity_id);
            try doc.appendSlice(gpa, ".md`\n");
            try doc.appendSlice(gpa, "- Satellites:\n");
            var any = false;
            for (metas) |child| {
                if (!std.mem.eql(u8, child.role, "satellite")) continue;
                if (!std.mem.eql(u8, child.parent_entry, m.entity_id)) continue;
                any = true;
                try doc.appendSlice(gpa, "  - `");
                try doc.appendSlice(gpa, child.entity_id);
                try doc.appendSlice(gpa, "` (");
                try doc.appendSlice(gpa, child.title);
                try doc.appendSlice(gpa, ") → `content/pages/");
                try doc.appendSlice(gpa, child.entity_id);
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
        for (metas) |m| {
            if (!std.mem.eql(u8, m.role, "satellite")) continue;
            try doc.appendSlice(gpa, "parentEntry\t");
            try doc.appendSlice(gpa, m.entity_id);
            try doc.appendSlice(gpa, "\t->\t");
            try doc.appendSlice(gpa, m.parent_entry);
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
// Index, upload guide, catalog.jsonl
// ---------------------------------------------------------------------------

/// Write `catalog_meta.json` — corpus-level format + versions (once, not per line).
/// Fixed field order: format, schema_version, boris_version. Compact + trailing LF.
/// Not a catalog entry — see `docs/contracts/rag-export.md`.
fn exportCatalogMeta(io: Io, out_dir: Io.Dir) !void {
    var buf: [160]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buf,
        "{{\"format\":\"{s}\",\"schema_version\":{d},\"boris_version\":\"{s}\"}}\n",
        .{ catalog_format, catalog_schema_version, boris_version },
    );
    try writeBytes(io, out_dir, "catalog_meta.json", text);
}

/// Write `catalog.jsonl` — pinned schema for bulk upload scripts.
/// Field order is stable: rag_id, rag_path, category, title, entity_id, role, parent_entry, tags.
/// Schema/product version lives in `catalog_meta.json`, not on each line.
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
        try jsonEscapeAppend(&doc, gpa, e.rag_id);
        try doc.appendSlice(gpa, "\",\"rag_path\":\"");
        try jsonEscapeAppend(&doc, gpa, e.rag_path);
        try doc.appendSlice(gpa, "\",\"category\":\"");
        try jsonEscapeAppend(&doc, gpa, e.category);
        try doc.appendSlice(gpa, "\",\"title\":\"");
        try jsonEscapeAppend(&doc, gpa, e.title);
        try doc.appendSlice(gpa, "\",\"entity_id\":\"");
        try jsonEscapeAppend(&doc, gpa, e.entity_id);
        try doc.appendSlice(gpa, "\",\"role\":\"");
        try jsonEscapeAppend(&doc, gpa, e.role);
        try doc.appendSlice(gpa, "\",\"parent_entry\":\"");
        try jsonEscapeAppend(&doc, gpa, e.parent_entry);
        try doc.appendSlice(gpa, "\",\"tags\":\"");
        try jsonEscapeAppend(&doc, gpa, e.tags);
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
        \\This file is the **master retrieval map** for the Boris project knowledge pack.
        \\Upload the entire `rag/` directory (or selected subtrees) to a chat LLM knowledge
        \\base such as Grok or Gemini.
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
        \\## How to retrieve (suggested order)
        \\
        \\1. **What is Boris / how does it work?** → `system/00-overview.md`, `system/10-name-and-metaphor.md`, then other `system/*`
        \\2. **Site content / guides?** → `content/pages/**`, then satellites via `graph/relations.md`
        \\3. **Callouts / tips?** → stay on the parent page segment (inlined `:::kind` blocks in Body)
        \\4. **Entity list / parentEntry edges?** → `graph/entity-catalog.md`, `graph/relations.md`
        \\5. **Upload instructions?** → `UPLOAD-GUIDE.md`
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
        \\## Path conventions
        \\
        \\| Prefix | Meaning |
        \\|--------|---------|
        \\| `system/` | Compiler & architecture (Zig + Apex native) |
        \\| `content/pages/<entity_id>.md` | Author page, path-mirrored entity id |
        \\| `graph/` | Entity catalog and relational edges |
        \\| `catalog.jsonl` | Machine catalog — one JSON object per document (see schema below) |
        \\| `catalog_meta.json` | Corpus format + versions (machine file; **not** a catalog entry) |
        \\
        \\Each **content** document is self-contained via YAML frontmatter (`entity_id`,
        \\`role`, `parent_entry`, `title`, direct-neighbor `related`). Use `INDEX.md` as
        \\the hub for the full path map; per-page files do not repeat sibling catalogs.
        \\
        \\**Catalog entry policy:** only retrieval markdown documents appear in
        \\`catalog.jsonl` / this table. Machine files `catalog.jsonl` and
        \\`catalog_meta.json` are part of the tree and documented here but are **not**
        \\catalog rows.
        \\
        \\Content title ownership: **metadata-owned** H1 (frontmatter `title`). Source
        \\leading H1 is stripped; remaining ATX H1s demoted to H2. Inlined asides use
        \\`:::kind` as an **export representation** only (authoring is `<Aside>`).
        \\
        \\### catalog_meta.json
        \\
        \\```json
        \\{"format":"boris-rag","schema_version":1,"boris_version":"0.1.1"}
        \\```
        \\
        \\### catalog.jsonl schema (stable field order)
        \\
        \\```text
        \\rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
        \\```
        \\
        \\Rows are sorted by `rag_path` (byte order). No timestamps, absolute paths,
        \\hostnames, or random ids appear in corpus files.
        \\
        \\| Field | Meaning |
        \\|-------|---------|
        \\| `rag_id` | Stable logical id |
        \\| `rag_path` | Path within the corpus |
        \\| `category` | `system` \| `content` \| `graph` \| `meta` |
        \\| `title` | Human title |
        \\| `entity_id` | Content entity id, or empty |
        \\| `role` | `trunk` \| `satellite`, or empty for non-content |
        \\| `parent_entry` | Parent entity id for satellites, else empty |
        \\| `tags` | String form of tag list |
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
        \\  - system/09-rag-export.md
        \\---
        \\
        \\# Upload guide — Grok, Gemini, and similar chat LLMs
        \\
        \\## What to upload
        \\
        \\Upload the **entire** generated `rag/` directory as a knowledge pack / collection
        \\of markdown files. Prefer folder upload when the product supports it.
        \\
        \\Minimum useful set if you must subset:
        \\
        \\1. `INDEX.md` (always)
        \\2. All of `system/` (Boris behavior)
        \\3. All of `content/` (site knowledge)
        \\4. All of `graph/` (relations)
        \\
        \\Optional for scripts: `catalog.jsonl` (schema: `rag_id`, `rag_path`, `category`,
        \\`title`, `entity_id`, `role`, `parent_entry`, `tags` — one JSON object per line,
        \\sorted by `rag_path`) and `catalog_meta.json`
        \\(`format`, `schema_version`, `boris_version` — once per corpus; not a catalog row).
        \\
        \\## Suggested system prompt snippet
        \\
        \\```
        \\You are answering questions using the Boris RAG corpus.
        \\Prefer files under system/ for architecture and implementation questions.
        \\Prefer content/pages/ for site/content questions (asides/admonitions are inlined).
        \\Use graph/relations.md to find trunk→satellite links.
        \\Cite rag_path values from document frontmatter when you rely on a source.
        \\Boris is a Zig + native Apex project; do not assume Node/React unless asked.
        \\```
        \\
        \\## Grok (xAI)
        \\
        \\1. Create or open a Grok project / collection that accepts file uploads.
        \\2. Upload the `rag/` folder (or zip it first if required).
        \\3. Pin `INDEX.md` or paste its retrieval order into the project instructions.
        \\4. Ask with explicit paths when useful, e.g. "Using system/05-memory-whiteboard.md, explain free_all".
        \\
        \\## Gemini
        \\
        \\1. Open Gemini with Apps / File upload / Gems that support document grounding.
        \\2. Upload markdown files from `rag/` (batch by folder if needed: system, content, graph).
        \\3. Start the chat with: "Read INDEX.md and use it as the retrieval map."
        \\4. For large corpora, upload `catalog.jsonl` plus folders in priority order.
        \\
        \\## Query patterns that retrieve well
        \\
        \\| Intent | Start at |
        \\|--------|----------|
        \\| What is Boris? | `system/00-overview.md`, `system/10-name-and-metaphor.md` |
        \\| How does compile work? | `system/01-architecture-pipeline.md` |
        \\| Load / Roll / Ignite / Reset | `system/10-name-and-metaphor.md` + `system/01-architecture-pipeline.md` |
        \\| Trunk vs satellite | `system/03-trunk-and-satellite.md` + `graph/relations.md` |
        \\| A specific guide | `content/pages/<entity_id>.md` |
        \\| A tip / callout | same page segment (Body `:::kind` blocks) |
        \\| Memory / performance | `system/05-memory-whiteboard.md` |
        \\| Markdown engine | `system/06-apex-native-engine.md` |
        \\| Components / admonitions | `system/04-components-and-admonitions.md` |
        \\
        \\## Regenerating this corpus
        \\
        \\From the Boris repo root (Zig 0.16+, no other toolchains required):
        \\
        \\```bash
        \\zig build rag
        \\# or
        \\zig build run -- --rag
        \\# custom output directory:
        \\zig build run -- --rag-dir=./uploads/boris-rag
        \\```
        \\
        \\## Integrity notes
        \\
        \\- Paths inside documents are logical RAG paths (not OS-absolute).
        \\- Content segments mirror `entity_id` hierarchy (`guides/intro` → `content/pages/guides/intro.md`).
        \\- System segments are numbered for reading order but are independently retrievable.
        \\
    ;
    try writeBytes(io, out_dir, "UPLOAD-GUIDE.md", text);
}

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

/// Build the full RAG corpus under `opts.out_dir`.
pub fn exportAll(
    io: Io,
    gpa: std.mem.Allocator,
    db: *const PageDb,
    opts: RagOptions,
) !RagStats {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.out_dir);
    var out_dir = try cwd.openDir(io, opts.out_dir, .{});
    defer out_dir.close(io);

    // Ensure subdirs exist even if a section is empty.
    try out_dir.createDirPath(io, "system");
    try out_dir.createDirPath(io, "content/pages");
    try out_dir.createDirPath(io, "graph");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var catalog: std.ArrayList(CatalogEntry) = .empty;
    // catalog entries live in arena; list spine uses gpa
    defer catalog.deinit(gpa);

    var stats: RagStats = .{};

    log(opts, "\nExporting RAG corpus → {s}/\n", .{opts.out_dir});

    stats.system_docs = try exportSystemDocs(io, gpa, arena, out_dir, opts, &catalog);

    // One read + parsePageSource per content page (same entry as compile.zig).
    // Meta, content export, and graph all consume this cache — no re-parse.
    const parse_cache = try buildParseCache(io, gpa, arena, db, opts.content_dir);
    defer gpa.free(parse_cache);

    // Collect + validate graph before writing content/graph segments so
    // missing parents never ship as silent broken edges in relations.md.
    const metas = try collectPageMeta(arena, parse_cache);
    try validateAndSortPageMeta(gpa, metas, opts);

    stats.content_pages = try exportContentPages(io, gpa, arena, out_dir, parse_cache, metas, opts, &catalog);
    stats.graph_docs = try exportGraphDocs(io, gpa, arena, out_dir, metas, &catalog, opts);

    try exportUploadGuide(io, out_dir);
    try appendCatalog(&catalog, gpa, arena, .{
        .rag_id = "meta/upload-guide",
        .rag_path = "UPLOAD-GUIDE.md",
        .category = "meta",
        .title = "Upload guide — Grok, Gemini, and similar chat LLMs",
        .tags = "[upload, grok, gemini, llm, rag]",
    });
    try appendCatalog(&catalog, gpa, arena, .{
        .rag_id = "meta/index",
        .rag_path = "INDEX.md",
        .category = "meta",
        .title = "Boris RAG corpus — INDEX",
        .tags = "[index, catalog, retrieval-map]",
    });

    // Stable catalog order for catalog.jsonl + INDEX table (never append order alone).
    sortCatalogByRagPath(catalog.items);
    stats.catalog_entries = catalog.items.len;

    // INDEX once with the sorted full catalog. Machine JSON files are not catalog rows.
    try exportIndex(io, gpa, out_dir, catalog.items, stats);
    try exportCatalogJsonl(io, gpa, out_dir, catalog.items);
    try exportCatalogMeta(io, out_dir);

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

    return stats;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "firstHeadingOrFallback" {
    try std.testing.expectEqualStrings("Hello", firstHeadingOrFallback("# Hello\n\nbody", "x"));
    try std.testing.expectEqualStrings("x", firstHeadingOrFallback("no heading", "x"));
}

test "stripFrontmatter" {
    const src = "---\ntitle: T\n---\n# Hi\n";
    try std.testing.expectEqualStrings("# Hi\n", stripFrontmatter(src));
}

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

    // Field order: format, schema_version, boris_version (no other keys).
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"format\"") != null);
    const fmt_i = std.mem.indexOf(u8, bytes, "\"format\"").?;
    const sch_i = std.mem.indexOf(u8, bytes, "\"schema_version\"").?;
    const bor_i = std.mem.indexOf(u8, bytes, "\"boris_version\"").?;
    try std.testing.expect(fmt_i < sch_i);
    try std.testing.expect(sch_i < bor_i);
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

    // One line, keys in exact contract order, strings escaped.
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
    const line = bytes[0 .. bytes.len - 1];
    const expected_prefix =
        \\{"rag_id":"content/quote","rag_path":"content/pages/quote.md","category":"content","title":"Say \"hi\"\nthere","entity_id":"quote","role":"trunk","parent_entry":"","tags":"[content, trunk]"}
    ;
    try std.testing.expectEqualStrings(expected_prefix, line);

    // Key order: walk key positions.
    const keys = [_][]const u8{ "rag_id", "rag_path", "category", "title", "entity_id", "role", "parent_entry", "tags" };
    var prev: usize = 0;
    for (keys) |k| {
        const needle = try std.fmt.allocPrint(gpa, "\"{s}\":", .{k});
        defer gpa.free(needle);
        const pos = std.mem.indexOfPos(u8, line, prev, needle) orelse {
            try std.testing.expect(false);
            return;
        };
        prev = pos + needle.len;
    }
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

/// Minimal content + system seeds. Content files created in reverse entity_id order
/// so discovery-order independence is exercised.
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
        // Intentionally reverse entity_id order: z, m, a.
        try content.writeFile(io, .{
            .sub_path = "z-last.md",
            .data =
            \\---
            \\title: Z Last
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
        // Create seeds out of lexical order; export must sort by relative path.
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

fn exportFixtureCorpus(
    io: Io,
    gpa: std.mem.Allocator,
    content_rel: []const u8,
    system_rel: []const u8,
    out_rel: []const u8,
) !RagStats {
    var db = PageDb.init(gpa);
    defer db.deinit();
    try scanner.scanFromCwd(io, &db, content_rel);
    return try exportAll(io, gpa, &db, .{
        .out_dir = out_rel,
        .content_dir = content_rel,
        .system_docs_dir = system_rel,
        .quiet = true,
    });
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
        try list.append(gpa, try arena.dupe(u8, entry.path));
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

test "rag export is byte-identical across two directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);

    try writeRagFixtures(io, gpa, paths.content, paths.system);

    const stats_a = try exportFixtureCorpus(io, gpa, paths.content, paths.system, paths.out_a);
    const stats_b = try exportFixtureCorpus(io, gpa, paths.content, paths.system, paths.out_b);
    try std.testing.expectEqual(stats_a.catalog_entries, stats_b.catalog_entries);
    try std.testing.expectEqual(@as(usize, 4), stats_a.content_pages);
    try std.testing.expectEqual(@as(usize, 2), stats_a.system_docs);

    try expectDirsByteIdentical(io, gpa, paths.out_a, paths.out_b);
}

test "rag export catalog_meta and catalog.jsonl contract" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);
    _ = try exportFixtureCorpus(io, gpa, paths.content, paths.system, paths.out_a);

    var out = try Io.Dir.cwd().openDir(io, paths.out_a, .{ .iterate = true });
    defer out.close(io);

    // catalog_meta.json exists and is valid JSON-ish with required keys.
    const meta = try readFileAlloc(io, out, "catalog_meta.json", gpa);
    defer gpa.free(meta);
    try std.testing.expect(std.mem.startsWith(u8, meta, "{\"format\":\"boris-rag\""));
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"schema_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"boris_version\":\"0.1.1\"") != null);

    // Parse each catalog.jsonl line independently; verify key order + sort.
    const jsonl = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(jsonl);
    try std.testing.expect(jsonl.len > 0);

    var path_arena = std.heap.ArenaAllocator.init(gpa);
    defer path_arena.deinit();
    const path_retain = path_arena.allocator();

    var line_start: usize = 0;
    var line_count: usize = 0;
    var prev_path: []const u8 = "";
    var saw_catalog_meta_row = false;
    var saw_catalog_jsonl_row = false;
    while (line_start < jsonl.len) {
        var line_end = line_start;
        while (line_end < jsonl.len and jsonl[line_end] != '\n') : (line_end += 1) {}
        const line = jsonl[line_start..line_end];
        if (line.len > 0) {
            line_count += 1;
            // Required keys in emitted order (prefix of object).
            try std.testing.expect(std.mem.startsWith(u8, line, "{\"rag_id\":\""));
            const keys = [_][]const u8{ "rag_id", "rag_path", "category", "title", "entity_id", "role", "parent_entry", "tags" };
            var prev: usize = 0;
            for (keys) |k| {
                const needle = try std.fmt.allocPrint(gpa, "\"{s}\":", .{k});
                defer gpa.free(needle);
                const pos = std.mem.indexOfPos(u8, line, prev, needle) orelse {
                    std.debug.print("missing key {s} in line: {s}\n", .{ k, line });
                    try std.testing.expect(false);
                    return;
                };
                prev = pos + needle.len;
            }
            // Sorted by rag_path: extract value after "rag_path":"
            const rp_key = "\"rag_path\":\"";
            const rp_at = std.mem.indexOf(u8, line, rp_key).?;
            const rp_val_start = rp_at + rp_key.len;
            const rp_val_end = std.mem.indexOfPos(u8, line, rp_val_start, "\"").?;
            const rp = line[rp_val_start..rp_val_end];
            if (prev_path.len > 0) {
                try std.testing.expect(std.mem.order(u8, prev_path, rp) == .lt);
            }
            prev_path = try path_retain.dupe(u8, rp);
            if (std.mem.eql(u8, rp, "catalog_meta.json")) saw_catalog_meta_row = true;
            if (std.mem.eql(u8, rp, "catalog.jsonl")) saw_catalog_jsonl_row = true;
        }
        line_start = if (line_end < jsonl.len) line_end + 1 else jsonl.len;
    }
    try std.testing.expect(line_count >= 8); // 2 system + 4 content + 2 graph + 2 meta
    // Policy: machine JSON files are not catalog entries.
    try std.testing.expect(!saw_catalog_meta_row);
    try std.testing.expect(!saw_catalog_jsonl_row);

    // INDEX documents catalog_meta.json and the non-entry policy.
    const index = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "catalog_meta.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "not**") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "catalog rows") != null);
}

test "rag export deterministic under shuffled fixture creation order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);
    _ = try exportFixtureCorpus(io, gpa, paths.content, paths.system, paths.out_a);

    var out = try Io.Dir.cwd().openDir(io, paths.out_a, .{});
    defer out.close(io);

    // System seeds sorted by relative path → a-first before b-second in catalog.
    const jsonl = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(jsonl);
    const a_sys = std.mem.indexOf(u8, jsonl, "system/a-first.md").?;
    const b_sys = std.mem.indexOf(u8, jsonl, "system/b-second.md").?;
    try std.testing.expect(a_sys < b_sys);

    // Content pages sorted by entity_id in catalog (a-first, guides/nested, m-mid, z-last).
    const a_c = std.mem.indexOf(u8, jsonl, "content/pages/a-first.md").?;
    const g_c = std.mem.indexOf(u8, jsonl, "content/pages/guides/nested.md").?;
    const m_c = std.mem.indexOf(u8, jsonl, "content/pages/m-mid.md").?;
    const z_c = std.mem.indexOf(u8, jsonl, "content/pages/z-last.md").?;
    try std.testing.expect(a_c < g_c);
    try std.testing.expect(g_c < m_c);
    try std.testing.expect(m_c < z_c);

    // relations.md edge list follows entity_id of satellites.
    const rel = try readFileAlloc(io, out, "graph/relations.md", gpa);
    defer gpa.free(rel);
    const edge_m = std.mem.indexOf(u8, rel, "parentEntry\tm-mid\t").?;
    // only one satellite in fixture
    try std.testing.expect(edge_m > 0);
}

test "rag export content pages have exactly one document H1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths = try ragTestPaths(gpa, tmp.sub_path[0..]);
    defer paths.deinit(gpa);
    try writeRagFixtures(io, gpa, paths.content, paths.system);
    _ = try exportFixtureCorpus(io, gpa, paths.content, paths.system, paths.out_a);

    var out = try Io.Dir.cwd().openDir(io, paths.out_a, .{});
    defer out.close(io);

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

    // Metadata-owned title on m-mid: source H1 was "Source H1 Should Vanish".
    const mid = try readFileAlloc(io, out, "content/pages/m-mid.md", gpa);
    defer gpa.free(mid);
    try std.testing.expect(std.mem.indexOf(u8, mid, "# M Mid\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "Source H1 Should Vanish") == null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "## Nested H1 Becomes H2") != null);
    // Export representation of Aside (not present as <Aside> in body after parse).
    const zpage = try readFileAlloc(io, out, "content/pages/z-last.md", gpa);
    defer gpa.free(zpage);
    try std.testing.expect(std.mem.indexOf(u8, zpage, ":::tip{id=\"z1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, zpage, "<Aside") == null);
}
