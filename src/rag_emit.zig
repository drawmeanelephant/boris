//! Pure, deterministic product-RAG artifact renderers for successful frozen data.
//!
//! This module deliberately owns bytes, ordering, H1 normalization, and catalog
//! field order. It does not compile, walk filesystems, write files, or publish.
const std = @import("std");
const aside = @import("aside.zig");
const graph_mod = @import("graph.zig");
const json_out = @import("json_out.zig");

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

fn isAtxH1Line(left_trimmed: []const u8) bool {
    if (left_trimmed.len == 0 or left_trimmed[0] != '#') return false;
    if (left_trimmed.len >= 2 and left_trimmed[1] == '#') return false;
    return left_trimmed.len == 1 or left_trimmed[1] == ' ' or left_trimmed[1] == '\t';
}

fn stripLeadingAtxH1(body: []const u8) []const u8 {
    var i: usize = 0;
    while (i < body.len) {
        var end = i;
        while (end < body.len and body[end] != '\n') : (end += 1) {}
        var line = body[i..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            i = if (end < body.len) end + 1 else body.len;
            continue;
        }
        if (isAtxH1Line(trimmed)) return if (end < body.len) body[end + 1 ..] else body[end..];
        return body;
    }
    return body;
}

fn demoteAtxH1ToH2(body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) {
        var end = i;
        while (end < body.len and body[end] != '\n') : (end += 1) {}
        var line = body[i..end];
        var had_cr = false;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
            had_cr = true;
        }
        const left = std.mem.trimStart(u8, line, " \t");
        if (isAtxH1Line(left)) {
            try out.appendSlice(allocator, line[0 .. line.len - left.len]);
            try out.append(allocator, '#');
            try out.appendSlice(allocator, left);
        } else try out.appendSlice(allocator, line);
        if (had_cr) try out.append(allocator, '\r');
        if (end < body.len) {
            try out.append(allocator, '\n');
            i = end + 1;
        } else i = end;
    }
    return try out.toOwnedSlice(allocator);
}

fn renderBody(segments: []const aside.Segment, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segments) |segment| switch (segment) {
        .markdown => |markdown| {
            if (std.mem.trim(u8, markdown, " \t\r\n").len == 0) {
                try out.appendSlice(allocator, markdown);
            } else {
                const prepared = try demoteAtxH1ToH2(stripLeadingAtxH1(markdown), allocator);
                try out.appendSlice(allocator, prepared);
            }
        },
        .aside => |value| try out.appendSlice(allocator, try aside.formatRagDirective(value, allocator)),
        .details => |value| try out.appendSlice(allocator, try aside.formatDetailsRagDirective(value, allocator)),
    };
    return try out.toOwnedSlice(allocator);
}

pub fn renderRagBody(segments: []const aside.Segment, allocator: std.mem.Allocator) ![]const u8 {
    return renderBody(segments, allocator);
}

fn pageTitle(page: graph_mod.Node) []const u8 {
    return page.title orelse page.id;
}

fn formatTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    if (tags.len == 0) return try allocator.dupe(u8, "[]");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (tags, 0..) |tag, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, tag);
    }
    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

pub fn renderSystemDocument(gpa: std.mem.Allocator, rag_id: []const u8, rag_path: []const u8, tags: []const u8, body: []const u8) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.appendSlice(gpa, "---\nrag_id: ");
    try doc.appendSlice(gpa, rag_id);
    try doc.appendSlice(gpa, "\nrag_path: ");
    try doc.appendSlice(gpa, rag_path);
    try doc.appendSlice(gpa, "\ncategory: system\ntags: ");
    try doc.appendSlice(gpa, tags);
    try doc.appendSlice(gpa, "\n---\n\n");
    try doc.appendSlice(gpa, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try doc.append(gpa, '\n');
    return try doc.toOwnedSlice(gpa);
}

pub fn renderContentDocument(gpa: std.mem.Allocator, scratch: std.mem.Allocator, page: graph_mod.Node, pages: []const graph_mod.Node, rag_id: []const u8, rag_path: []const u8, segments: []const aside.Segment) ![]u8 {
    const body = try renderBody(segments, scratch);
    return renderContentDocumentBody(gpa, page, rag_id, rag_path, body, pages);
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
    const tags = try formatTags(gpa, page.tags);
    defer gpa.free(tags);
    var related: std.ArrayList(u8) = .empty;
    defer related.deinit(gpa);
    try related.appendSlice(gpa, "related:\n");
    if (parent.len > 0) {
        if (content_paths_present) try related.print(gpa, "  - content/pages/{s}.md\n", .{parent}) else try related.appendSlice(gpa, "  - parts/ (see part_manifest.json)\n");
    }
    for (pages) |other| {
        if (other.role != .satellite) continue;
        const other_parent = other.parent orelse continue;
        if (std.mem.eql(u8, other_parent, page.id)) {
            if (content_paths_present) try related.print(gpa, "  - content/pages/{s}.md\n", .{other.id}) else try related.appendSlice(gpa, "  - parts/ (see part_manifest.json)\n");
        }
    }
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.print(gpa, "---\nrag_id: {s}\nrag_path: {s}\ncategory: content\nentity_id: {s}\nsource_path: {s}\nrole: {s}\n", .{ rag_id, rag_path, page.id, page.source_path, page.role.name() });
    if (parent.len > 0) try doc.print(gpa, "parent_entry: {s}\n", .{parent});
    try doc.print(gpa, "title: {s}\ntags: {s}\n", .{ title, tags });
    if (chunk) |info| {
        try doc.print(gpa, "source_sha256: {s}\npart: {d}\npart_count: {d}\ncontinuation: {s}\n", .{
            info.source_sha256,
            info.number,
            info.count,
            if (info.count == 1) "single" else if (info.number == 1) "continues" else if (info.number == info.count) "continued" else "continues",
        });
    }
    try doc.appendSlice(gpa, related.items);
    try doc.print(gpa, "---\n\n# {s}\n\n", .{title});
    try doc.appendSlice(gpa, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try doc.append(gpa, '\n');
    return try doc.toOwnedSlice(gpa);
}

pub fn renderContentDocumentBody(gpa: std.mem.Allocator, page: graph_mod.Node, rag_id: []const u8, rag_path: []const u8, body: []const u8, pages: []const graph_mod.Node) ![]u8 {
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

pub fn contentCatalogEntry(allocator: std.mem.Allocator, page: graph_mod.Node, rag_id: []const u8, rag_path: []const u8) !CatalogEntry {
    return .{ .rag_id = rag_id, .rag_path = rag_path, .category = "content", .title = pageTitle(page), .entity_id = page.id, .role = page.role.name(), .parent_entry = page.parent orelse "", .tags = try formatTags(allocator, page.tags) };
}

pub fn renderEntityCatalog(gpa: std.mem.Allocator, pages: []const graph_mod.Node, content_paths_present: bool) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.appendSlice(gpa, "---\nrag_id: graph/entity-catalog\nrag_path: graph/entity-catalog.md\ncategory: graph\ntags: [graph, catalog, entities]\nrelated:\n  - graph/relations.md\n---\n\n# Entity catalog\n\nContent entities after shared scan / parse / graph validation.\nPages are the only first-class graph nodes; asides are not nodes.\n\n| entity_id | title | role | source | RAG path |\n|-----------|-------|------|--------|----------|\n");
    for (pages) |page| {
        if (content_paths_present) {
            try doc.print(gpa, "| `{s}` | {s} | {s} | `{s}` | `content/pages/{s}.md` |\n", .{ page.id, pageTitle(page), page.role.name(), page.source_path, page.id });
        } else {
            try doc.print(gpa, "| `{s}` | {s} | {s} | `{s}` | *(in parts; see part_manifest.json)* |\n", .{ page.id, pageTitle(page), page.role.name(), page.source_path });
        }
    }
    return try doc.toOwnedSlice(gpa);
}

pub fn renderRelations(gpa: std.mem.Allocator, pages: []const graph_mod.Node, content_paths_present: bool) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.appendSlice(gpa, "---\nrag_id: graph/relations\nrag_path: graph/relations.md\ncategory: graph\ntags: [graph, relations, trunk, satellite]\nrelated:\n  - graph/entity-catalog.md\n---\n\n# Graph relations (Trunk → Satellite)\n\nEdges come from satellite frontmatter `parent: <trunk-entity-id>`.\nHubs and satellite lists are ordered by `entity_id`. Edge list is\nordered by source id then target id. Invalid graphs never publish\nthis file (shared `graph.validate` must pass first).\n\n## Trunk hubs\n\n");
    for (pages) |page| {
        if (page.role != .trunk) continue;
        if (content_paths_present) {
            try doc.print(gpa, "### `{s}` — {s}\n\n- Trunk RAG: `content/pages/{s}.md`\n- Satellites:\n", .{ page.id, pageTitle(page), page.id });
        } else {
            try doc.print(gpa, "### `{s}` — {s}\n\n- Trunk RAG: *(in parts; see part_manifest.json)*\n- Satellites:\n", .{ page.id, pageTitle(page) });
        }
        var any = false;
        for (pages) |child| {
            if (child.role != .satellite) continue;
            const parent = child.parent orelse continue;
            if (!std.mem.eql(u8, parent, page.id)) continue;
            any = true;
            if (content_paths_present) {
                try doc.print(gpa, "  - `{s}` ({s}) → `content/pages/{s}.md`\n", .{ child.id, pageTitle(child), child.id });
            } else {
                try doc.print(gpa, "  - `{s}` ({s}) → *(in parts; see part_manifest.json)*\n", .{ child.id, pageTitle(child) });
            }
        }
        if (!any) try doc.appendSlice(gpa, "  - *(none)*\n");
        try doc.append(gpa, '\n');
    }
    try doc.appendSlice(gpa, "## Edge list (machine-friendly)\n\n```\n");
    const Pair = struct { src: []const u8, tgt: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);
    for (pages) |page| if (page.role == .satellite) if (page.parent) |parent| try pairs.append(gpa, .{ .src = page.id, .tgt = parent });
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn less(_: void, a: Pair, b: Pair) bool {
            const order = std.mem.order(u8, a.src, b.src);
            return if (order == .eq) std.mem.order(u8, a.tgt, b.tgt) == .lt else order == .lt;
        }
    }.less);
    for (pairs.items) |pair| try doc.print(gpa, "parent\t{s}\t->\t{s}\n", .{ pair.src, pair.tgt });
    try doc.appendSlice(gpa, "```\n");
    return try doc.toOwnedSlice(gpa);
}

pub fn renderCatalogMeta(allocator: std.mem.Allocator, format: []const u8, schema_version: u32, version: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"format\":\"{s}\",\"schema_version\":{d},\"boris_version\":\"{s}\"}}\n", .{ format, schema_version, version });
}

pub fn renderCatalogJsonl(gpa: std.mem.Allocator, catalog: []const CatalogEntry) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    for (catalog) |entry| {
        try doc.appendSlice(gpa, "{\"rag_id\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.rag_id);
        try doc.appendSlice(gpa, "\",\"rag_path\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.rag_path);
        try doc.appendSlice(gpa, "\",\"category\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.category);
        try doc.appendSlice(gpa, "\",\"title\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.title);
        try doc.appendSlice(gpa, "\",\"entity_id\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.entity_id);
        try doc.appendSlice(gpa, "\",\"role\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.role);
        try doc.appendSlice(gpa, "\",\"parent_entry\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.parent_entry);
        try doc.appendSlice(gpa, "\",\"tags\":\"");
        try json_out.escapeAppend(&doc, gpa, entry.tags);
        try doc.appendSlice(gpa, "\"}\n");
    }
    return try doc.toOwnedSlice(gpa);
}

pub fn renderIndex(gpa: std.mem.Allocator, catalog: []const CatalogEntry, stats: Stats, version: []const u8) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.appendSlice(gpa, "---\nrag_id: meta/index\nrag_path: INDEX.md\ncategory: meta\ntags: [index, catalog, retrieval-map]\n---\n\n# Boris RAG corpus — INDEX\n\nMaster retrieval map for the Boris product RAG pack. Upload this\ndirectory tree to a chat LLM knowledge base.\n\n## Counts\n\n");
    try doc.print(gpa, "| Segment | Count |\n|---------|------:|\n| system | {d} |\n| {s} | {d} |\n| graph | {d} |\n| catalog entries | {d} |\n\n", .{ stats.system_docs, if (stats.bundles_only) "content pages represented in parts" else "content pages", stats.content_pages, stats.graph_docs, stats.catalog_entries });
    try doc.appendSlice(gpa, "## Generated artifacts\n\n| Path | Role |\n|------|------|\n| `INDEX.md` | This retrieval map (catalog row) |\n| `UPLOAD-GUIDE.md` | Upload notes (catalog row) |\n| `catalog.jsonl` | Machine catalog — **not** a catalog row |\n| `catalog_meta.json` | Format + versions — **not** a catalog row |\n| `system/**` | Curated architecture seeds |\n");
    if (stats.bundles_only) {
        try doc.appendSlice(gpa, "| `parts/**` | Uploadable content bundles |\n| `part_manifest.json` | Ordered chunk provenance |\n");
    } else {
        try doc.appendSlice(gpa, "| `content/pages/**` | Content page segments |\n");
    }
    try doc.appendSlice(gpa, "| `graph/entity-catalog.md` | Entity table |\n| `graph/relations.md` | Trunk → Satellite edges |\n\n## Full catalog\n\n| rag_path | category | title | entity_id |\n|----------|----------|-------|-----------|\n");
    for (catalog) |entry| {
        try doc.print(gpa, "| `{s}` | {s} | {s} | ", .{ entry.rag_path, entry.category, entry.title });
        if (entry.entity_id.len > 0) try doc.print(gpa, "`{s}`", .{entry.entity_id}) else try doc.appendSlice(gpa, "—");
        try doc.appendSlice(gpa, " |\n");
    }
    try doc.print(gpa, "\n## Catalog schema (stable field order)\n\n```text\nrag_id, rag_path, category, title, entity_id, role, parent_entry, tags\n```\n\nRows sorted by `rag_path`. No timestamps, absolute paths, hostnames,\nor random ids. Content title H1 is metadata-owned (frontmatter `title`\nelse entity id). Source leading H1 stripped; remaining ATX H1s demoted\nto H2. Parsed `<Aside>` callouts are emitted as `:::kind` blocks\n(export representation only — not round-trippable authoring syntax).\n\n### catalog_meta.json\n\n```json\n{{\"format\":\"boris-rag\",\"schema_version\":1,\"boris_version\":\"{s}\"}}\n```\n\n", .{version});
    return try doc.toOwnedSlice(gpa);
}

pub fn renderUploadGuide(gpa: std.mem.Allocator, bundles_only: bool) ![]u8 {
    const content_set = if (bundles_only)
        "3. All of `parts/` and `part_manifest.json` (site knowledge bundles)\n"
    else
        "3. All of `content/` (site knowledge)\n";
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);
    try doc.appendSlice(gpa, "---\nrag_id: meta/upload-guide\nrag_path: UPLOAD-GUIDE.md\ncategory: meta\ntags: [upload, grok, gemini, llm, rag]\nrelated:\n  - INDEX.md\n---\n\n# Upload guide — Grok, Gemini, and similar chat LLMs\n\n## What to upload\n\nUpload the **entire** generated RAG directory. Prefer folder upload when\nthe product supports it.\n\nMinimum useful set if you must subset:\n\n1. `INDEX.md` (always)\n2. All of `system/` (Boris behavior)\n");
    try doc.appendSlice(gpa, content_set);
    try doc.appendSlice(gpa, "4. All of `graph/` (relations)\n\nOptional for scripts: `catalog.jsonl` and `catalog_meta.json` (machine\nfiles; not catalog rows).\n\n## Regenerating this corpus\n\n```bash\nzig build run -- --input content --rag\nzig build run -- --input content --rag-dir ./uploads/boris-rag\n```\n\n## Integrity notes\n\n- Paths inside documents are logical RAG paths (not OS-absolute).\n- Graph-dependent files are published only after shared `graph.validate` succeeds.\n- Parsed `<Aside>` callouts appear as `:::kind` export blocks (not authoring syntax).\n");
    if (bundles_only) try doc.appendSlice(gpa, "- `content/pages/**` is intentionally omitted; the ordered `parts/` documents are the content payload.\n");
    return try doc.toOwnedSlice(gpa);
}

test "catalog JSONL field order and escaping are stable" {
    const bytes = try renderCatalogJsonl(std.testing.allocator, &.{.{ .rag_id = "content/quote", .rag_path = "content/pages/quote.md", .category = "content", .title = "Say \"hi\"\nthere", .entity_id = "quote", .role = "trunk", .tags = "[content, trunk]" }});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"rag_id\":\"content/quote\",\"rag_path\":\"content/pages/quote.md\",\"category\":\"content\",\"title\":\"Say \\\"hi\\\"\\nthere\",\"entity_id\":\"quote\",\"role\":\"trunk\",\"parent_entry\":\"\",\"tags\":\"[content, trunk]\"}\n", bytes);
}
