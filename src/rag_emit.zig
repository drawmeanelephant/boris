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
const graph_mod = @import("graph.zig");
const structured_out = @import("structured_out.zig");

const Sink = structured_out.Sink;
const Cell = structured_out.Cell;

/// Complete source documents are emitted verbatim — escaping them would destroy
/// the authoring fidelity the working packs exist to preserve. Structural
/// containment comes from the delimiters between documents, not from encoding
/// the payload.
const body_is_raw_by_design =
    "complete source document payload is emitted verbatim for authoring fidelity";

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

pub const Stats = struct {
    system_docs: usize,
    content_pages: usize,
    graph_docs: usize,
    catalog_entries: usize,
};

pub fn sortCatalogByRagPath(entries: []CatalogEntry) void {
    std.mem.sort(CatalogEntry, entries, {}, struct {
        fn less(_: void, a: CatalogEntry, b: CatalogEntry) bool {
            return std.mem.order(u8, a.rag_path, b.rag_path) == .lt;
        }
    }.less);
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

// ---------------------------------------------------------------------------
// Working-context packs (default `--rag`)
// ---------------------------------------------------------------------------

/// One document instance inside a working pack. Unsplit documents appear once
/// with `part_count == 1`; oversized documents appear once per split part.
pub const WorkingDoc = struct {
    rag_id: []const u8,
    /// Content-root-relative source path of the site document.
    source: []const u8,
    category: []const u8,
    /// Entity id of the site document (never empty in working mode).
    entity_id: []const u8 = "",
    part_number: usize = 1,
    part_count: usize = 1,
    /// Complete source document bytes (verbatim; for split parts, one slice).
    body: []const u8,
};

fn appendWorkingBody(sink: *Sink, body: []const u8) !void {
    try sink.rawTrusted(body_is_raw_by_design, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try sink.lit("\n");
}

/// Line prefix of the pack document envelope. Bodies are emitted verbatim, so
/// a source line beginning with this prefix would be indistinguishable from a
/// real boundary during marker-free reassembly.
pub const doc_marker_prefix = "<!-- boris-rag-doc:";

/// True when any body line (after leading whitespace) starts with the document
/// marker prefix. The export rejects such documents rather than emitting an
/// ambiguous pack.
pub fn containsDocMarkerCollision(body: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, doc_marker_prefix)) return true;
    }
    return false;
}

/// Render one bounded model-facing pack file. Documents are delimited by
/// `<!-- boris-rag-doc: ... -->` markers; reassembly is the marker-free
/// concatenation of each document's bytes (in order).
pub fn renderWorkingPack(
    gpa: std.mem.Allocator,
    pack_index: usize,
    pack_count: usize,
    docs: []const WorkingDoc,
) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit("# Boris working context pack ");
    try doc.num(pack_index);
    try doc.lit("/");
    try doc.num(pack_count);
    try doc.lit("\n\nEach document below is a complete Boris source file. To reuse one, copy\n" ++
        "everything after its `<!-- boris-rag-doc: ... -->` marker through the next\n" ++
        "marker (or the end of the file).\n\n");
    for (docs) |d| {
        try doc.lit("\n<!-- boris-rag-doc: id=\"");
        try doc.field(.md_block_text, d.rag_id);
        try doc.lit("\" source=\"");
        try doc.field(.md_block_text, d.source);
        try doc.lit("\" category=\"");
        try doc.field(.md_block_text, d.category);
        if (d.part_count > 1) {
            try doc.lit("\" part=\"");
            try doc.num(d.part_number);
            try doc.lit("/");
            try doc.num(d.part_count);
        }
        try doc.lit("\" -->\n");
        try appendWorkingBody(&doc, d.body);
        try doc.lit("\n");
    }
    return try doc.toOwnedSlice();
}

pub const WorkingPackInfo = struct {
    path: []const u8,
    bytes: usize,
    documents: usize,
};

pub const ManifestDoc = struct {
    rag_id: []const u8,
    source: []const u8,
    category: []const u8,
    entity_id: []const u8,
    /// Pack file containing this document instance (e.g. `working-1.md`).
    pack: []const u8,
    part: usize,
    part_count: usize,
    continuation: []const u8,
    /// Bytes of this document instance (source file size for unsplit docs).
    bytes: usize,
    source_sha256: []const u8,
};

pub const WorkingManifest = struct {
    version: []const u8,
    scope: []const u8,
    graph_page_count: usize,
    selected_page_count: usize,
    structural_parent_count: usize,
    semantic_neighbor_count: usize,
    graph_relation_count: usize,
    selected_relation_count: usize,
    pack_target: usize,
    approximate_tokens: usize,
    packs: []const WorkingPackInfo,
    docs: []const ManifestDoc,
};

/// Sidecar manifest for the working-context export. Deliberately not intended
/// for model upload: it carries scope, counts, pack membership, and integrity
/// records (per-document sha256 and byte sizes) that model-facing packs omit.
pub fn renderWorkingManifest(gpa: std.mem.Allocator, m: WorkingManifest) ![]u8 {
    var doc = Sink.init(gpa);
    errdefer doc.deinit();
    try doc.lit("{\n  \"format\":\"boris-rag\",\n  \"schema_version\":2,\n  \"boris_version\":");
    try doc.jsonString(m.version);
    try doc.lit(",\n  \"mode\":\"working\",\n  \"scope\":");
    try doc.jsonString(m.scope);
    try doc.lit(",\n  \"scope_closure\":\"parents+semantic-relations\",\n  \"graph_page_count\":");
    try doc.num(m.graph_page_count);
    try doc.lit(",\n  \"selected_page_count\":");
    try doc.num(m.selected_page_count);
    try doc.lit(",\n  \"structural_parent_count\":");
    try doc.num(m.structural_parent_count);
    try doc.lit(",\n  \"semantic_neighbor_count\":");
    try doc.num(m.semantic_neighbor_count);
    try doc.lit(",\n  \"graph_relation_count\":");
    try doc.num(m.graph_relation_count);
    try doc.lit(",\n  \"selected_relation_count\":");
    try doc.num(m.selected_relation_count);
    try doc.lit(",\n  \"pack_target\":");
    try doc.num(m.pack_target);
    try doc.lit(",\n  \"approximate_tokens\":");
    try doc.num(m.approximate_tokens);
    try doc.lit(",\n  \"upload_files\":[");
    for (m.packs, 0..) |pack, i| {
        if (i > 0) try doc.lit(",");
        try doc.lit("{\"path\":");
        try doc.jsonString(pack.path);
        try doc.lit(",\"bytes\":");
        try doc.num(pack.bytes);
        try doc.lit(",\"documents\":");
        try doc.num(pack.documents);
        try doc.lit("}");
    }
    try doc.lit("],\n  \"documents\":[");
    for (m.docs, 0..) |d, i| {
        if (i > 0) try doc.lit(",");
        try doc.lit("{\"rag_id\":");
        try doc.jsonString(d.rag_id);
        try doc.lit(",\"source\":");
        try doc.jsonString(d.source);
        try doc.lit(",\"category\":");
        try doc.jsonString(d.category);
        try doc.lit(",\"entity_id\":");
        try doc.jsonString(d.entity_id);
        try doc.lit(",\"pack\":");
        try doc.jsonString(d.pack);
        try doc.lit(",\"part\":");
        try doc.num(d.part);
        try doc.lit(",\"part_count\":");
        try doc.num(d.part_count);
        try doc.lit(",\"continuation\":");
        try doc.jsonString(d.continuation);
        try doc.lit(",\"bytes\":");
        try doc.num(d.bytes);
        try doc.lit(",\"source_sha256\":");
        try doc.jsonString(d.source_sha256);
        try doc.lit("}");
    }
    try doc.lit("],\n  \"sidecar_files\":[\"manifest.json\"]\n}\n");
    return try doc.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Complete-corpus export (`--rag --complete`)
// ---------------------------------------------------------------------------

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

pub fn renderEntityCatalog(gpa: std.mem.Allocator, pages: []const graph_mod.Node) ![]u8 {
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
        try doc.tableRow(&.{
            .{ .code = page.id },
            .{ .text = pageTitle(page) },
            .{ .text = page.role.name() },
            .{ .code = page.source_path },
            .{ .code_parts = &.{ "content/pages/", page.id, ".md" } },
        });
    }
    return try doc.toOwnedSlice();
}

/// Render relations from an id-sorted page slice. Scoped exports compact the
/// frozen graph into a new slice, so parent lookup must be rebuilt locally
/// from entity ids rather than reusing full-graph `parent_index` values.
pub fn renderRelations(gpa: std.mem.Allocator, pages: []const graph_mod.Node) ![]u8 {
    var page_indices: std.StringHashMapUnmanaged(usize) = .empty;
    defer page_indices.deinit(gpa);
    try page_indices.ensureTotalCapacity(gpa, @intCast(pages.len));
    for (pages, 0..) |page, page_index| {
        const gop = try page_indices.getOrPut(gpa, page.id);
        if (!gop.found_existing) gop.value_ptr.* = page_index;
    }

    var children_by_parent = try gpa.alloc(std.ArrayList(u32), pages.len);
    defer {
        for (children_by_parent) |*children| children.deinit(gpa);
        gpa.free(children_by_parent);
    }
    for (children_by_parent) |*children| children.* = .empty;

    for (pages, 0..) |child, child_index| {
        if (child.role != .satellite) continue;
        const parent = child.parent orelse continue;
        const parent_index = page_indices.get(parent) orelse continue;
        try children_by_parent[parent_index].append(gpa, @intCast(child_index));
    }

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
    for (pages, 0..) |page, parent_index| {
        try doc.lit("### ");
        try doc.inlineCode(page.id);
        try doc.lit(" — ");
        try doc.field(.md_heading, pageTitle(page));
        try doc.lit("\n\n- ");
        if (page.role == .trunk) try doc.lit("Root RAG") else try doc.lit("Parent RAG");
        try doc.lit(": ");
        try doc.inlineCodeJoined(&.{ "content/pages/", page.id, ".md" });
        try doc.lit("\n- Children:\n");
        if (children_by_parent[parent_index].items.len == 0) {
            try doc.lit("  - *(none)*\n");
        } else {
            for (children_by_parent[parent_index].items) |child_index| {
                const child = pages[child_index];
                try doc.lit("  - ");
                try doc.inlineCode(child.id);
                try doc.lit(" (");
                try doc.field(.md_block_text, pageTitle(child));
                try doc.lit(") → ");
                try doc.inlineCodeJoined(&.{ "content/pages/", child.id, ".md" });
                try doc.lit("\n");
            }
        }
        try doc.lit("\n");
    }
    try doc.lit("## Edge list (machine-friendly)\n\n```\n");
    for (pages) |page| {
        const parent = page.parent orelse continue;
        try doc.lit("parent\t");
        try doc.field(.md_block_text, page.id);
        try doc.lit("\t->\t");
        try doc.field(.md_block_text, parent);
        try doc.lit("\n");
    }
    try doc.lit("```\n");
    return try doc.toOwnedSlice();
}

pub fn renderCatalogMeta(allocator: std.mem.Allocator, format: []const u8, schema_version: u32, version: []const u8, vcs_revision: []const u8) ![]u8 {
    var doc = Sink.init(allocator);
    errdefer doc.deinit();
    try doc.lit("{\"format\":");
    try doc.jsonString(format);
    try doc.lit(",\"schema_version\":");
    try doc.jsonNumber(schema_version);
    try doc.lit(",\"boris_version\":");
    try doc.jsonString(version);
    // Additive build provenance (#781): the opaque VCS revision token the
    // producing binary was compiled from ("" when undetected, e.g. a
    // tarball). Never part of the product version; the compact fixed key
    // order gains this trailing field only, mirroring the HTML-path
    // report's additive `vcsRevision` (#776).
    try doc.lit(",\"vcs_revision\":");
    try doc.jsonString(vcs_revision);
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
        \\Master retrieval map for the Boris complete-corpus RAG export. Upload
        \\this directory tree to a chat LLM knowledge base. Content pages are
        \\verbatim authoring documents (frontmatter, H1s, and `<Aside>` /
        \\`<Details>` syntax preserved).
        \\
        \\## Counts
        \\
        \\| Segment | Count |
        \\|---------|------:|
    );
    try doc.lit("\n| system | ");
    try doc.num(stats.system_docs);
    try doc.lit(" |\n| content pages | ");
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
        \\| `content/pages/**` | Verbatim content page sources |
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
        \\or random ids. Content documents are complete authoring sources:
        \\frontmatter and H1s are preserved, and `<Aside>` / `<Details>`
        \\remain authoring syntax (no `:::kind` export representation).
        \\
        \\### catalog_meta.json
        \\
        \\```json
        \\{"format":"boris-rag","schema_version":2,"boris_version":"
    );
    try doc.field(.md_block_text, version);
    try doc.lit("\"}\n```\n");
    return try doc.toOwnedSlice();
}

pub fn renderUploadGuide(gpa: std.mem.Allocator) ![]u8 {
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
        \\3. All of `content/` (site knowledge)
        \\4. All of `graph/` (relations)
        \\
        \\Optional for scripts: `catalog.jsonl` and `catalog_meta.json` (machine
        \\files; not catalog rows).
        \\
        \\For normal site-writing work, the **working-context packs** (`--rag`
        \\without `--complete`) are the recommended upload: a small number of
        \\bounded files plus a `manifest.json` sidecar that is not meant for upload.
        \\
        \\## Regenerating this corpus
        \\
        \\```bash
        \\zig build run -- --input content --rag --complete
        \\zig build run -- --input content --rag --complete --rag-dir ./uploads/boris-rag
        \\```
        \\
        \\## Integrity notes
        \\
        \\- Paths inside documents are logical RAG paths (not OS-absolute).
        \\- Graph-dependent files are published only after shared `graph.validate` succeeds.
        \\- Content pages are verbatim authoring documents; `<Aside>` / `<Details>`
        \\  remain authoring syntax (no `:::kind` export representation).
        \\
    );
    return try doc.toOwnedSlice();
}

test "catalog JSONL field order and escaping are stable" {
    const bytes = try renderCatalogJsonl(std.testing.allocator, &.{.{ .rag_id = "content/quote", .rag_path = "content/pages/quote.md", .category = "content", .title = "Say \"hi\"\nthere", .entity_id = "quote", .role = "trunk", .tags = "[content, trunk]" }});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"rag_id\":\"content/quote\",\"rag_path\":\"content/pages/quote.md\",\"category\":\"content\",\"title\":\"Say \\\"hi\\\"\\nthere\",\"entity_id\":\"quote\",\"role\":\"trunk\",\"parent_entry\":\"\",\"tags\":\"[content, trunk]\"}\n", bytes);
}

test "working pack delimiters and verbatim bodies" {
    const gpa = std.testing.allocator;
    const body =
        \\---
        \\title: Intro
        \\---
        \\
        \\# Intro
        \\
        \\Body with <Aside kind="tip">kept</Aside>.
        \\
    ;
    const pack = try renderWorkingPack(gpa, 1, 2, &.{
        .{ .rag_id = "content/intro", .source = "intro.md", .category = "content", .entity_id = "intro", .body = body },
        .{ .rag_id = "system/00-overview", .source = "00-overview.md", .category = "system", .body = "seed body\n" },
    });
    defer gpa.free(pack);
    try std.testing.expect(std.mem.indexOf(u8, pack, "# Boris working context pack 1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "<!-- boris-rag-doc: id=\"content/intro\" source=\"intro.md\" category=\"content\" -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "<Aside kind=\"tip\">kept</Aside>") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack, "<!-- boris-rag-doc: id=\"system/00-overview\" source=\"00-overview.md\" category=\"system\" -->") != null);
    // No ::: directive representation anywhere.
    try std.testing.expect(std.mem.indexOf(u8, pack, ":::") == null);
    // Split document carries part metadata in the marker only.
    const split = try renderWorkingPack(gpa, 2, 2, &.{
        .{ .rag_id = "content/big", .source = "big.md", .category = "content", .entity_id = "big", .part_number = 2, .part_count = 3, .body = "second slice\n" },
    });
    defer gpa.free(split);
    try std.testing.expect(std.mem.indexOf(u8, split, "part=\"2/3\"") != null);
}

test "working manifest field order is stable and complete" {
    const gpa = std.testing.allocator;
    const bytes = try renderWorkingManifest(gpa, .{
        .version = "0.8.2",
        .scope = "mascots",
        .graph_page_count = 12,
        .selected_page_count = 4,
        .structural_parent_count = 1,
        .semantic_neighbor_count = 2,
        .graph_relation_count = 3,
        .selected_relation_count = 1,
        .pack_target = 262144,
        .approximate_tokens = 512,
        .packs = &.{.{ .path = "working-1.md", .bytes = 2048, .documents = 2 }},
        .docs = &.{.{ .rag_id = "content/mascots/foo", .source = "mascots/foo.md", .category = "content", .entity_id = "mascots/foo", .pack = "working-1.md", .part = 1, .part_count = 1, .continuation = "single", .bytes = 1000, .source_sha256 = "abc" }},
    });
    defer gpa.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("working", parsed.value.object.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("schema_version").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("structural_parent_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("semantic_neighbor_count").?.integer);
    const upload_files = parsed.value.object.get("upload_files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), upload_files.len);
    try std.testing.expectEqualStrings("working-1.md", upload_files[0].object.get("path").?.string);
}
