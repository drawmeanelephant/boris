//! Pure, deterministic product-RAG artifact renderers for successful frozen data.
//!
//! This module deliberately owns bytes, ordering, and catalog field order. It
//! does not compile, walk filesystems, write files, or publish.
//!
//! Every artifact here is written through `structured_out.Sink`. Page-controlled
//! values — title, tags, entity ids, source paths — reach the stream only via
//! `field` / `fieldJoined` / `tableRow` / `inlineCode`, which encode for the
//! container the value lands in (`encode.Target`). Body markdown is the single
//! by-design exception and says so at the one call site that emits it.
//!
//! `emitter_discipline_test.zig` fails the build if this module regains a raw
//! formatting call. That check is the reason a future emitter cannot quietly
//! reintroduce the YAML/table breakouts this module used to have.
const std = @import("std");
const aside = @import("aside.zig");
const graph_mod = @import("graph.zig");
const rag_body = @import("rag_body.zig");
const structured_out = @import("structured_out.zig");

const Sink = structured_out.Sink;
const Cell = structured_out.Cell;

/// Body markdown is page content rendered back to markdown. It is emitted
/// verbatim on purpose — escaping it would destroy the document. Structural
/// containment comes from the frontmatter fence and the H1 normalization above
/// it, not from encoding the body.
const body_is_raw_by_design =
    "page body markdown is the document payload and is emitted verbatim by design";

pub const CatalogEntry = struct {
    rag_id: []const u8,
    rag_path: []const u8,
    category: []const u8,
    title: []const u8,
    entity_id: []const u8 = "",
    role: []const u8 = "",
    parent_entry: []const u8 = "",
    tags: []const u8 = "",
};

/// Provenance carried by an upload chunk. Full page documents intentionally
/// keep their historical frontmatter shape; only segmented upload documents
/// add these fields.
pub const ChunkInfo = struct {
    number: usize,
    count: usize,
    source_sha256: []const u8,
};

pub const Stats = struct {
    system_docs: usize,
    content_pages: usize,
    graph_docs: usize,
    catalog_entries: usize,
    bundles_only: bool = false,
};

pub fn sortCatalogByRagPath(entries: []CatalogEntry) void {
    std.mem.sort(CatalogEntry, entries, {}, struct {
        fn less(_: void, a: CatalogEntry, b: CatalogEntry) bool {
            return std.mem.order(u8, a.rag_path, b.rag_path) == .lt;
        }
    }.less);
}

pub fn renderRagBody(segments: []const aside.Segment, allocator: std.mem.Allocator) ![]const u8 {
    return rag_body.render(segments, allocator);
}

fn pageTitle(page: graph_mod.Node) []const u8 {
    return page.title orelse page.id;
}

/// Render a tag list as a YAML flow sequence. Shared by the frontmatter writers
/// and by the catalog, so both see the same escaping.
pub fn formatTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    var sink = Sink.init(allocator);
    errdefer sink.deinit();
    try sink.flowSeq(tags);
    return try sink.toOwnedSlice();
}

fn appendBody(sink: *Sink, body: []const u8) !void {
    try sink.rawTrusted(body_is_raw_by_design, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try sink.lit("\n");
}

pub fn renderSystemDocument(
    gpa: std.mem.Allocator,
    rag_id: []const u8,
    rag_path: []const u8,
    tags: []const []const u8,
    body: []const u8,
) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit("---\n");
    try doc.yamlField("rag_id", rag_id);
    try doc.yamlField("rag_path", rag_path);
    try doc.lit("category: system\n");
    try doc.yamlFlowSeq("tags", tags);
    try doc.lit("---\n\n");
    try appendBody(&doc, body);
    return try doc.toOwnedSlice();
}

pub fn renderContentDocument(
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    page: graph_mod.Node,
    pages: []const graph_mod.Node,
    rag_id: []const u8,
    rag_path: []const u8,
    segments: []const aside.Segment,
) ![]u8 {
    const body = try rag_body.render(segments, scratch);
    return renderContentDocumentBody(gpa, page, rag_id, rag_path, body, pages);
}

fn appendRelated(
    doc: *Sink,
    page: graph_mod.Node,
    pages: []const graph_mod.Node,
    parent: []const u8,
    content_paths_present: bool,
) !void {
    try doc.lit("related:\n");
    if (parent.len > 0) {
        try appendRelatedEntry(doc, parent, content_paths_present);
    }
    for (pages) |other| {
        if (other.role != .satellite) continue;
        const other_parent = other.parent orelse continue;
        if (std.mem.eql(u8, other_parent, page.id)) {
            try appendRelatedEntry(doc, other.id, content_paths_present);
        }
    }
}

fn appendRelatedEntry(doc: *Sink, entity_id: []const u8, content_paths_present: bool) !void {
    try doc.lit("  - ");
    if (content_paths_present) {
        try doc.fieldJoined(.yaml_scalar, &.{ "content/pages/", entity_id, ".md" });
    } else {
        try doc.lit("parts/ (see part_manifest.json)");
    }
    try doc.lit("\n");
}

fn renderContentDocumentWithChunk(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    rag_id: []const u8,
    rag_path: []const u8,
    body: []const u8,
    pages: []const graph_mod.Node,
    chunk: ?ChunkInfo,
    content_paths_present: bool,
) ![]u8 {
    const title = pageTitle(page);
    const parent = page.parent orelse "";

    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit("---\n");
    try doc.yamlField("rag_id", rag_id);
    try doc.yamlField("rag_path", rag_path);
    try doc.lit("category: content\n");
    try doc.yamlField("entity_id", page.id);
    try doc.yamlField("source_path", page.source_path);
    try doc.yamlField("role", page.role.name());
    if (parent.len > 0) try doc.yamlField("parent_entry", parent);
    try doc.yamlField("title", title);
    try doc.yamlFlowSeq("tags", page.tags);
    if (chunk) |info| {
        try doc.yamlField("source_sha256", info.source_sha256);
        try doc.lit("part: ");
        try doc.num(info.number);
        try doc.lit("\npart_count: ");
        try doc.num(info.count);
        try doc.lit("\ncontinuation: ");
        if (info.count == 1) {
            try doc.lit("single");
        } else if (info.number == info.count) {
            try doc.lit("continued");
        } else {
            try doc.lit("continues");
        }
        try doc.lit("\n");
    }
    try appendRelated(&doc, page, pages, parent, content_paths_present);
    try doc.lit("---\n\n# ");
    try doc.field(.md_heading, title);
    try doc.lit("\n\n");
    try appendBody(&doc, body);
    return try doc.toOwnedSlice();
}

pub fn renderContentDocumentBody(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    rag_id: []const u8,
    rag_path: []const u8,
    body: []const u8,
    pages: []const graph_mod.Node,
) ![]u8 {
    return renderContentDocumentWithChunk(gpa, page, rag_id, rag_path, body, pages, null, true);
}

pub fn renderContentDocumentChunk(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    rag_id: []const u8,
    rag_path: []const u8,
    body: []const u8,
    pages: []const graph_mod.Node,
    source_sha256: []const u8,
    number: usize,
    count: usize,
) ![]u8 {
    return renderContentDocumentChunkWithOptions(gpa, page, rag_id, rag_path, body, pages, source_sha256, number, count, true);
}

pub fn renderContentDocumentChunkWithOptions(
    gpa: std.mem.Allocator,
    page: graph_mod.Node,
    rag_id: []const u8,
    rag_path: []const u8,
    body: []const u8,
    pages: []const graph_mod.Node,
    source_sha256: []const u8,
    number: usize,
    count: usize,
    content_paths_present: bool,
) ![]u8 {
    return renderContentDocumentWithChunk(gpa, page, rag_id, rag_path, body, pages, .{
        .number = number,
        .count = count,
        .source_sha256 = source_sha256,
    }, content_paths_present);
}

pub fn contentCatalogEntry(
    allocator: std.mem.Allocator,
    page: graph_mod.Node,
    rag_id: []const u8,
    rag_path: []const u8,
) !CatalogEntry {
    return .{
        .rag_id = rag_id,
        .rag_path = rag_path,
        .category = "content",
        .title = pageTitle(page),
        .entity_id = page.id,
        .role = page.role.name(),
        .parent_entry = page.parent orelse "",
        .tags = try formatTags(allocator, page.tags),
    };
}

pub fn renderEntityCatalog(gpa: std.mem.Allocator, pages: []const graph_mod.Node, content_paths_present: bool) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit(
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
    for (pages) |page| {
        const path_cell: Cell = if (content_paths_present)
            .{ .code_parts = &.{ "content/pages/", page.id, ".md" } }
        else
            .{ .text = "*(in parts; see part_manifest.json)*" };
        try doc.tableRow(&.{
            .{ .code = page.id },
            .{ .text = pageTitle(page) },
            .{ .text = page.role.name() },
            .{ .code = page.source_path },
            path_cell,
        });
    }
    return try doc.toOwnedSlice();
}

pub fn renderRelations(gpa: std.mem.Allocator, pages: []const graph_mod.Node, content_paths_present: bool) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit(
        \\---
        \\rag_id: graph/relations
        \\rag_path: graph/relations.md
        \\category: graph
        \\tags: [graph, hierarchy, trunk, satellite]
        \\related:
        \\  - graph/entity-catalog.md
        \\---
        \\
        \\# Graph relations (parent hierarchy)
        \\
        \\Edges come from page frontmatter `parent: <entity-id>`. Hubs and direct child
        \\lists are ordered by `entity_id`; parent chains may be nested but must remain
        \\acyclic. Invalid graphs never publish this file (shared `graph.validate` must
        \\pass first).
        \\
        \\## Hierarchy hubs
        \\
        \\
    );
    for (pages) |page| {
        try doc.lit("### ");
        try doc.inlineCode(page.id);
        try doc.lit(" — ");
        try doc.field(.md_heading, pageTitle(page));
        try doc.lit("\n\n- ");
        if (page.role == .trunk) try doc.lit("Root RAG") else try doc.lit("Parent RAG");
        try doc.lit(": ");
        if (content_paths_present) {
            try doc.inlineCodeJoined(&.{ "content/pages/", page.id, ".md" });
        } else {
            try doc.lit("*(in parts; see part_manifest.json)*");
        }
        try doc.lit("\n- Children:\n");
        var any = false;
        for (pages) |child| {
            if (child.role != .satellite) continue;
            const parent = child.parent orelse continue;
            if (!std.mem.eql(u8, parent, page.id)) continue;
            any = true;
            try doc.lit("  - ");
            try doc.inlineCode(child.id);
            try doc.lit(" (");
            try doc.field(.md_block_text, pageTitle(child));
            try doc.lit(") → ");
            if (content_paths_present) {
                try doc.inlineCodeJoined(&.{ "content/pages/", child.id, ".md" });
            } else {
                try doc.lit("*(in parts; see part_manifest.json)*");
            }
            try doc.lit("\n");
        }
        if (!any) try doc.lit("  - *(none)*\n");
        try doc.lit("\n");
    }
    try doc.lit("## Edge list (machine-friendly)\n\n```\n");
    const Pair = struct { src: []const u8, tgt: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);
    for (pages) |page| if (page.parent) |parent| try pairs.append(gpa, .{ .src = page.id, .tgt = parent });
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn less(_: void, a: Pair, b: Pair) bool {
            const order = std.mem.order(u8, a.src, b.src);
            return if (order == .eq) std.mem.order(u8, a.tgt, b.tgt) == .lt else order == .lt;
        }
    }.less);
    for (pairs.items) |pair| {
        try doc.lit("parent\t");
        try doc.field(.md_block_text, pair.src);
        try doc.lit("\t->\t");
        try doc.field(.md_block_text, pair.tgt);
        try doc.lit("\n");
    }
    try doc.lit("```\n");
    return try doc.toOwnedSlice();
}

pub fn renderCatalogMeta(allocator: std.mem.Allocator, format: []const u8, schema_version: u32, version: []const u8) ![]u8 {
    var doc = Sink.init(allocator);
    errdefer doc.deinit();
    try doc.lit("{\"format\":");
    try doc.jsonString(format);
    try doc.lit(",\"schema_version\":");
    try doc.jsonNumber(schema_version);
    try doc.lit(",\"boris_version\":");
    try doc.jsonString(version);
    try doc.lit("}\n");
    return try doc.toOwnedSlice();
}

pub fn renderCatalogJsonl(gpa: std.mem.Allocator, catalog: []const CatalogEntry) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    for (catalog) |entry| {
        try doc.lit("{\"rag_id\":");
        try doc.jsonString(entry.rag_id);
        try doc.lit(",\"rag_path\":");
        try doc.jsonString(entry.rag_path);
        try doc.lit(",\"category\":");
        try doc.jsonString(entry.category);
        try doc.lit(",\"title\":");
        try doc.jsonString(entry.title);
        try doc.lit(",\"entity_id\":");
        try doc.jsonString(entry.entity_id);
        try doc.lit(",\"role\":");
        try doc.jsonString(entry.role);
        try doc.lit(",\"parent_entry\":");
        try doc.jsonString(entry.parent_entry);
        try doc.lit(",\"tags\":");
        try doc.jsonString(entry.tags);
        try doc.lit("}\n");
    }
    return try doc.toOwnedSlice();
}

pub fn renderIndex(gpa: std.mem.Allocator, catalog: []const CatalogEntry, stats: Stats, version: []const u8) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit(
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
        \\| Segment | Count |
        \\|---------|------:|
    );
    try doc.lit("\n| system | ");
    try doc.num(stats.system_docs);
    try doc.lit(" |\n| ");
    if (stats.bundles_only) {
        try doc.lit("content pages represented in parts");
    } else {
        try doc.lit("content pages");
    }
    try doc.lit(" | ");
    try doc.num(stats.content_pages);
    try doc.lit(" |\n| graph | ");
    try doc.num(stats.graph_docs);
    try doc.lit(" |\n| catalog entries | ");
    try doc.num(stats.catalog_entries);
    try doc.lit(" |\n");
    try doc.lit(
        \\
        \\## Generated artifacts
        \\
        \\| Path | Role |
        \\|------|------|
        \\| `INDEX.md` | This retrieval map (catalog row) |
        \\| `UPLOAD-GUIDE.md` | Upload notes (catalog row) |
        \\| `catalog.jsonl` | Machine catalog — **not** a catalog row |
        \\| `catalog_meta.json` | Format + versions — **not** a catalog row |
        \\| `system/**` | Curated architecture seeds |
        \\
    );
    if (stats.bundles_only) {
        try doc.lit("| `parts/**` | Uploadable content bundles |\n| `part_manifest.json` | Ordered chunk provenance |\n");
    } else {
        try doc.lit("| `content/pages/**` | Content page segments |\n");
    }
    try doc.lit(
        \\| `graph/entity-catalog.md` | Entity table |
        \\| `graph/relations.md` | Parent hierarchy edges |
        \\
        \\## Full catalog
        \\
        \\| rag_path | category | title | entity_id |
        \\|----------|----------|-------|-----------|
        \\
    );
    for (catalog) |entry| {
        const id_cell: Cell = if (entry.entity_id.len > 0)
            .{ .code = entry.entity_id }
        else
            .{ .text = "—" };
        try doc.tableRow(&.{
            .{ .code = entry.rag_path },
            .{ .text = entry.category },
            .{ .text = entry.title },
            id_cell,
        });
    }
    try doc.lit(
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
    try doc.field(.md_block_text, version);
    try doc.lit("\"}\n```\n\n");
    return try doc.toOwnedSlice();
}

pub fn renderUploadGuide(gpa: std.mem.Allocator, bundles_only: bool) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit(
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
        \\
    );
    if (bundles_only) {
        try doc.lit("3. All of `parts/` and `part_manifest.json` (site knowledge bundles)\n");
    } else {
        try doc.lit("3. All of `content/` (site knowledge)\n");
    }
    try doc.lit(
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
        \\- Graph-dependent files are published only after shared `graph.validate` succeeds.
        \\- Parsed `<Aside>` callouts appear as `:::kind` export blocks (not authoring syntax).
        \\
    );
    if (bundles_only) {
        try doc.lit("- `content/pages/**` is intentionally omitted; the ordered `parts/` documents are the content payload.\n");
    }
    return try doc.toOwnedSlice();
}

test "catalog JSONL field order and escaping are stable" {
    const bytes = try renderCatalogJsonl(std.testing.allocator, &.{.{ .rag_id = "content/quote", .rag_path = "content/pages/quote.md", .category = "content", .title = "Say \"hi\"\nthere", .entity_id = "quote", .role = "trunk", .tags = "[content, trunk]" }});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"rag_id\":\"content/quote\",\"rag_path\":\"content/pages/quote.md\",\"category\":\"content\",\"title\":\"Say \\\"hi\\\"\\nthere\",\"entity_id\":\"quote\",\"role\":\"trunk\",\"parent_entry\":\"\",\"tags\":\"[content, trunk]\"}\n", bytes);
}
