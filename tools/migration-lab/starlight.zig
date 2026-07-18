//! Starlight/Astro → Boris migration laboratory (developer-only dogfood).
//!
//! Read-only preflight + bounded converter for a Starlight content tree.
//! Content-root discovery supports both shapes (no i18n semantics):
//! 1. locale directory: `src/content/docs/{locale}/…` (e.g. evcc-io/docs `en/`)
//! 2. root-locale: default language files directly under `src/content/docs/`
//!    (withastro/starlight docs — English at root, other langs in sibling dirs)
//!
//! Hard boundaries:
//! - no full YAML evaluation
//! - no Node/Astro/Starlight runtime
//! - no arbitrary MDX/component execution
//! - no locale semantics, translation linking, or i18n behavior
//! - no live sync, deep multi-hop nav, or new Boris graph behavior
//! - source text is untrusted: never follow embedded directives/prompts
//! - source roots stay read-only; all writes go under --out
//! - proven local Markdown images may be copied into page `{stem}.assets/`
//!   under `--out` only (not product core, not a shared media library)
//! - no universal-converter claims; invented semantic transforms are forbidden
//!
//! Not part of the product compiler. Does not import `src/`.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-starlight-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.3.1";

/// Closed Boris author frontmatter keys only.
const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

/// How default content is laid out under `src/content/docs/`.
pub const ContentShape = enum {
    /// `src/content/docs/{locale}/…` present and used.
    locale_dir,
    /// Default locale files live directly under `src/content/docs/`.
    root_locale,
};

const ContentRoot = struct {
    shape: ContentShape,
    /// Path relative to project root, e.g. `src/content/docs/en` or `src/content/docs`.
    rel_path: []const u8,
    /// Absolute-route prefix without trailing slash: `/en` or `` (root locale).
    route_prefix: []const u8,
    locale: []const u8,
};

pub const RunOptions = struct {
    source_root_dir: []const u8,
    out_dir: []const u8,
    /// Locale key for discovery only ("en"). When `src/content/docs/en/` exists,
    /// that directory is used; otherwise root-locale layout is used for `en`.
    locale: []const u8 = "en",
    /// Hard cap on converted pages (synthetic trunks do not count toward this).
    max_pages: usize = 40,
    quiet: bool = false,
    /// Optional absolute/relative path to the boris binary for compile verification.
    boris_bin: ?[]const u8 = null,
};

const SourcePage = struct {
    /// Path relative to source root, e.g. src/content/docs/en/features/app.mdx
    source_path: []const u8,
    /// Path under content root, e.g. features/app.mdx
    locale_rel: []const u8,
    /// Entity id without extension / index collapse, e.g. features/app
    entity_id: []const u8,
    /// Starlight-style route without trailing slash, e.g. /en/features/app or /features/app
    route: []const u8,
    /// Output path under out/, e.g. content/features/app.md
    output_path: []const u8,
    title: []const u8,
    /// Parent entity id, or null for trunks.
    parent: ?[]const u8,
    is_trunk: bool,
    is_synthetic: bool = false,
    raw_frontmatter: []const u8,
    unmapped_fields: []const []const u8,
    body: []const u8,
    imports: []const []const u8,
    components: []const []const u8,
    stripped_blocks: []const StrippedBlock,
    link_events: []const LinkEvent,
    component_events: []const LinkEvent,
    bytes: u64,
};

const StrippedBlock = struct {
    line: usize,
    category: []const u8,
};

const LinkEvent = struct {
    kind: []const u8, // markdown | href | to | relative
    target: []const u8,
    line: u32,
    resolution: []const u8, // rewritten | review | external | asset | leave
    rewritten_to: ?[]const u8 = null,
    review_reason: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

const AssetEntry = struct {
    source_path: []const u8,
    kind: []const u8, // public | content_local | referenced | migrated_page_asset
    referenced_from: ?[]const u8 = null,
    exists: bool = false,
    bytes: u64 = 0,
    /// Lowercase hex SHA-256 when a local source file was opened and hashed.
    sha256_hex: ?[]const u8 = null,
    /// Out-dir-relative destination when kind is migrated_page_asset.
    dest_path: ?[]const u8 = null,
    /// Within-tree path under the page sibling `.assets/` root.
    within_tree: ?[]const u8 = null,
};

/// One proven Markdown image copied into a page sibling `{stem}.assets/` tree.
const MigratedAsset = struct {
    source_path: []const u8,
    dest_path: []const u8,
    within_tree: []const u8,
    page_entity: []const u8,
    original_ref: []const u8,
    rewritten_ref: []const u8,
    bytes: u64,
    sha256_hex: []const u8,
};

const NavDecision = struct {
    kind: []const u8,
    evidence: []const u8,
    decision: []const u8,
};

const InventoryRow = struct {
    source_path: []const u8,
    kind: []const u8,
    bytes: u64,
};

const SelectionRow = struct {
    source_path: []const u8,
    content_rel: []const u8,
    selected: bool,
    reason: []const u8,
};

/// One boundary classification row: preserved body, stripped untrusted block,
/// or an item that still needs human migration work.
const BoundaryItem = struct {
    class: []const u8, // preserved | stripped | manual_review
    source_path: []const u8,
    detail: []const u8,
    line: ?usize = null,
    category: ?[]const u8 = null,
};

const CollisionRecord = struct {
    entity_id: []const u8,
    source_paths: []const []const u8,
    resolution: []const u8, // first_wins_others_disambiguated
};

const product_relation_limit: usize = 16;

const relation_source_fields = [_][]const u8{
    "relatedEntries",
    "relatedHaiku",
    "relatedLimerick",
    "relatedLorelog",
    "mascotRef",
    "concepts",
    "escalationPath",
};

/// Review-first evidence extracted from known Filed-shaped source frontmatter.
/// These rows never alter emitted Markdown or Boris product relations.
const RelationCandidate = struct {
    source_path: []const u8,
    output_path: []const u8,
    source_entity: []const u8,
    source_field: []const u8,
    source_line: u32,
    value_index: usize,
    raw_value: []const u8,
    normalized_target: ?[]const u8,
    proposed_kind: ?[]const u8,
    target_resolution: []const u8, // resolved | unresolved | ambiguous | not_attempted | not_applicable
    resolved_entity: ?[]const u8,
    relation_ordinal: ?usize,
    within_product_limit: ?bool,
    review_reason: ?[]const u8,
};

const RawRelationValue = struct {
    source_field: []const u8,
    source_line: u32,
    value_index: usize,
    raw_value: []const u8,
    target_value: ?[]const u8,
    collection: ?[]const u8 = null,
    review_reason: ?[]const u8 = null,
};

const FrontmatterLine = struct {
    raw: []const u8,
    text: []const u8,
    start: usize,
    end: usize,
    indent: usize,
    line: u32,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isMarkdownName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".mdx");
}

fn isBorisKey(key: []const u8) bool {
    for (boris_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn isSkipDir(name: []const u8) bool {
    const skip = [_][]const u8{
        ".git",    ".hg",      ".svn",    "node_modules", ".astro",     "dist",
        ".vercel", ".netlify", ".output", "zig-out",      ".zig-cache", "zig-cache",
    };
    for (skip) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn startsWithPath(hay: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, hay, prefix)) return false;
    if (hay.len == prefix.len) return true;
    return hay[prefix.len] == '/';
}

fn slugStem(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".mdx")) return name[0 .. name.len - 4];
    if (std.mem.endsWith(u8, name, ".md")) return name[0 .. name.len - 3];
    return name;
}

/// Collapse `foo/index` → `foo`, `index` → `index`.
fn entityIdFromLocaleRel(allocator: std.mem.Allocator, locale_rel: []const u8) ![]u8 {
    const stem_path = if (std.mem.endsWith(u8, locale_rel, ".mdx"))
        locale_rel[0 .. locale_rel.len - 4]
    else if (std.mem.endsWith(u8, locale_rel, ".md"))
        locale_rel[0 .. locale_rel.len - 3]
    else
        locale_rel;

    if (std.mem.eql(u8, stem_path, "index")) return try allocator.dupe(u8, "index");
    if (std.mem.endsWith(u8, stem_path, "/index")) {
        return try allocator.dupe(u8, stem_path[0 .. stem_path.len - "/index".len]);
    }
    return try allocator.dupe(u8, stem_path);
}

/// Deterministic route from entity id. `route_prefix` is `/en` or `` (root locale).
fn routeFromEntity(allocator: std.mem.Allocator, route_prefix: []const u8, entity_id: []const u8) ![]u8 {
    if (std.mem.eql(u8, entity_id, "index")) {
        if (route_prefix.len == 0) return try allocator.dupe(u8, "/");
        return try allocator.dupe(u8, route_prefix);
    }
    if (route_prefix.len == 0) {
        return try std.fmt.allocPrint(allocator, "/{s}", .{entity_id});
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ route_prefix, entity_id });
}

fn outputPathFromEntity(allocator: std.mem.Allocator, entity_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "content/{s}.md", .{entity_id});
}

/// Narrow BCP-47-ish first-level dir names used by Starlight translations.
/// Used only to skip sibling locale trees under a root-locale docs root.
/// Not full i18n: no linking, no fallback, no translation graph.
fn looksLikeLocaleDirName(name: []const u8) bool {
    if (name.len == 2) {
        return std.ascii.isLower(name[0]) and std.ascii.isLower(name[1]);
    }
    // xx-yy (e.g. zh-cn, pt-br)
    if (name.len == 5 and name[2] == '-') {
        return std.ascii.isLower(name[0]) and std.ascii.isLower(name[1]) and
            std.ascii.isLower(name[3]) and std.ascii.isLower(name[4]);
    }
    return false;
}

fn dirExists(io: Io, root: Io.Dir, rel: []const u8) bool {
    var d = root.openDir(io, rel, .{}) catch return false;
    d.close(io);
    return true;
}

/// Candidate page filter: exclude underscore partials only (no preferred sections).
fn isCandidatePage(content_rel: []const u8) bool {
    const base = std.fs.path.basename(content_rel);
    if (base.len > 0 and base[0] == '_') return false;
    return true;
}

/// Discover content root: prefer `docs/{locale}/` when present; else root-locale.
fn discoverContentRoot(io: Io, a: std.mem.Allocator, source: Io.Dir, locale: []const u8) !ContentRoot {
    const docs_base = "src/content/docs";
    if (!dirExists(io, source, docs_base)) return error.ContentRootNotFound;

    const locale_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ docs_base, locale });
    if (dirExists(io, source, locale_path)) {
        var probe: std.ArrayList([]const u8) = .empty;
        collectMarkdownFiles(io, a, source, locale_path, &probe, false) catch {};
        if (probe.items.len > 0) {
            return .{
                .shape = .locale_dir,
                .rel_path = locale_path,
                .route_prefix = try std.fmt.allocPrint(a, "/{s}", .{locale}),
                .locale = locale,
            };
        }
    }

    // Root-locale: default content directly under docs base (skip sibling locale dirs).
    var probe_root: std.ArrayList([]const u8) = .empty;
    collectMarkdownFiles(io, a, source, docs_base, &probe_root, true) catch {};
    if (probe_root.items.len > 0) {
        return .{
            .shape = .root_locale,
            .rel_path = try a.dupe(u8, docs_base),
            .route_prefix = "",
            .locale = locale,
        };
    }
    return error.ContentRootNotFound;
}

fn titleFromStem(allocator: std.mem.Allocator, entity_id: []const u8) ![]u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, entity_id, '/')) |i| entity_id[i + 1 ..] else entity_id;
    var out: std.ArrayList(u8) = .empty;
    var cap = true;
    for (base) |c| {
        if (c == '-' or c == '_') {
            try out.append(allocator, ' ');
            cap = true;
        } else {
            const ch = if (cap and c >= 'a' and c <= 'z') c - 32 else c;
            try out.append(allocator, ch);
            cap = false;
        }
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "Untitled");
    return try out.toOwnedSlice(allocator);
}

fn parseFrontmatterLite(allocator: std.mem.Allocator, raw: []const u8, fallback_title: []const u8) !struct {
    title: []const u8,
    frontmatter: []const u8,
    body: []const u8,
    unmapped: []const []const u8,
    all_keys: []const []const u8,
} {
    if (!std.mem.startsWith(u8, raw, "---\n") and !std.mem.startsWith(u8, raw, "---\r\n")) {
        return .{
            .title = fallback_title,
            .frontmatter = "",
            .body = raw,
            .unmapped = &.{},
            .all_keys = &.{},
        };
    }
    const start: usize = if (std.mem.startsWith(u8, raw, "---\r\n")) 5 else 4;
    const end_pat = if (std.mem.indexOfPos(u8, raw, start, "\n---\r\n") != null) "\n---\r\n" else "\n---\n";
    const end_start = std.mem.indexOfPos(u8, raw, start, end_pat) orelse {
        return .{
            .title = fallback_title,
            .frontmatter = raw,
            .body = "",
            .unmapped = &.{},
            .all_keys = &.{},
        };
    };
    const frontmatter = raw[start..end_start];
    const body = raw[end_start + end_pat.len ..];

    var title: []const u8 = fallback_title;
    var unmapped: std.ArrayList([]const u8) = .empty;
    var all_keys: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (pos < frontmatter.len) {
        const line_end = std.mem.indexOfScalarPos(u8, frontmatter, pos, '\n') orelse frontmatter.len;
        var line = frontmatter[pos..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        // Top-level keys only (no indent) — not full YAML.
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and line[0] != '#' and line[0] != '-') {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const key = trim(line[0..colon]);
                if (key.len > 0) {
                    try all_keys.append(allocator, try allocator.dupe(u8, key));
                    if (!isBorisKey(key) or std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "parent") or std.mem.eql(u8, key, "status") or std.mem.eql(u8, key, "tags")) {
                        // Map only title from source; id/parent/status/tags are emitted by converter.
                        if (!std.mem.eql(u8, key, "title")) {
                            try unmapped.append(allocator, try allocator.dupe(u8, key));
                        }
                    }
                    if (std.mem.eql(u8, key, "title")) {
                        var value = trim(line[colon + 1 ..]);
                        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
                            (value[0] == '\'' and value[value.len - 1] == '\'')))
                        {
                            value = value[1 .. value.len - 1];
                        }
                        if (value.len > 0) title = try allocator.dupe(u8, value);
                    }
                }
            }
        }
        pos = if (line_end == frontmatter.len) frontmatter.len else line_end + 1;
    }
    return .{
        .title = title,
        .frontmatter = frontmatter,
        .body = body,
        .unmapped = try unmapped.toOwnedSlice(allocator),
        .all_keys = try all_keys.toOwnedSlice(allocator),
    };
}

fn canonicalRelationSourceField(key: []const u8) ?[]const u8 {
    for (relation_source_fields) |field| {
        if (std.mem.eql(u8, key, field)) return field;
    }
    return null;
}

fn relationFieldProposesKind(field: []const u8) bool {
    return std.mem.eql(u8, field, "relatedEntries") or
        std.mem.eql(u8, field, "relatedHaiku") or
        std.mem.eql(u8, field, "relatedLimerick") or
        std.mem.eql(u8, field, "relatedLorelog") or
        std.mem.eql(u8, field, "mascotRef");
}

fn splitFrontmatterLines(a: std.mem.Allocator, raw: []const u8) ![]const FrontmatterLine {
    var lines: std.ArrayList(FrontmatterLine) = .empty;
    var pos: usize = 0;
    var line_no: u32 = 1;
    while (pos < raw.len) : (line_no += 1) {
        const line_end = std.mem.indexOfScalarPos(u8, raw, pos, '\n') orelse raw.len;
        var text = raw[pos..line_end];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        var indent: usize = 0;
        while (indent < text.len and (text[indent] == ' ' or text[indent] == '\t')) : (indent += 1) {}
        try lines.append(a, .{
            .raw = text,
            .text = text[indent..],
            .start = pos,
            .end = if (line_end < raw.len) line_end + 1 else line_end,
            .indent = indent,
            .line = line_no,
        });
        pos = if (line_end < raw.len) line_end + 1 else raw.len;
    }
    return try lines.toOwnedSlice(a);
}

fn topLevelField(line: FrontmatterLine) ?struct { key: []const u8, value: []const u8 } {
    if (line.indent != 0 or line.text.len == 0 or line.text[0] == '#') return null;
    const colon = std.mem.indexOfScalar(u8, line.text, ':') orelse return null;
    const key = trim(line.text[0..colon]);
    if (key.len == 0) return null;
    return .{ .key = key, .value = trim(line.text[colon + 1 ..]) };
}

fn appendRawRelationValue(
    a: std.mem.Allocator,
    out: *std.ArrayList(RawRelationValue),
    field: []const u8,
    line: u32,
    value_index: *usize,
    raw_value: []const u8,
    target_value: ?[]const u8,
    collection: ?[]const u8,
    review_reason: ?[]const u8,
) !void {
    try out.append(a, .{
        .source_field = field,
        .source_line = line,
        .value_index = value_index.*,
        .raw_value = try a.dupe(u8, raw_value),
        .target_value = if (target_value) |v| try a.dupe(u8, v) else null,
        .collection = if (collection) |v| try a.dupe(u8, v) else null,
        .review_reason = review_reason,
    });
    value_index.* += 1;
}

fn scalarLooksNonScalar(value: []const u8) bool {
    const v = trim(value);
    if (v.len == 0) return true;
    return v[0] == '{' or v[0] == '|' or v[0] == '>' or v[0] == '&' or v[0] == '*';
}

fn parseInlineRelationValues(
    a: std.mem.Allocator,
    out: *std.ArrayList(RawRelationValue),
    field: []const u8,
    line: u32,
    value: []const u8,
    value_index: *usize,
) !void {
    const v = trim(value);
    if (v.len == 0) {
        try appendRawRelationValue(a, out, field, line, value_index, v, null, null, "empty_value");
        return;
    }
    if (v[0] != '[') {
        if (scalarLooksNonScalar(v)) {
            try appendRawRelationValue(a, out, field, line, value_index, v, null, null, "non_scalar_value");
        } else {
            try appendRawRelationValue(a, out, field, line, value_index, v, v, null, null);
        }
        return;
    }
    if (v.len < 2 or v[v.len - 1] != ']') {
        try appendRawRelationValue(a, out, field, line, value_index, v, null, null, "malformed_inline_list");
        return;
    }

    const inner = v[1 .. v.len - 1];
    var start: usize = 0;
    var quote: ?u8 = null;
    var malformed = false;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const at_end = i == inner.len;
        if (!at_end) {
            const c = inner[i];
            if (quote) |q| {
                if (c == q) quote = null;
                if (c == '\\') malformed = true; // escapes need a YAML parser; preserve for review
            } else if (c == '\'' or c == '"') {
                quote = c;
            } else if (c == '[' or c == ']' or c == '{' or c == '}') {
                malformed = true;
            }
        }
        if (at_end or (quote == null and inner[i] == ',')) {
            const item = trim(inner[start..i]);
            if (item.len == 0) malformed = true;
            if (!malformed and item.len > 0) {
                try appendRawRelationValue(a, out, field, line, value_index, item, item, null, null);
            }
            start = i + 1;
        }
    }
    if (quote != null) malformed = true;
    if (malformed) {
        // Preserve the entire value once when safe item boundaries cannot be proven.
        while (out.items.len > 0 and out.items[out.items.len - 1].source_line == line and
            std.mem.eql(u8, out.items[out.items.len - 1].source_field, field))
        {
            _ = out.pop();
            value_index.* -= 1;
        }
        try appendRawRelationValue(a, out, field, line, value_index, v, null, null, "malformed_inline_list");
    }
}

fn parseObjectItem(
    a: std.mem.Allocator,
    out: *std.ArrayList(RawRelationValue),
    field: []const u8,
    lines: []const FrontmatterLine,
    item_start: usize,
    item_end: usize,
    raw_frontmatter: []const u8,
    value_index: *usize,
) !void {
    const first = lines[item_start];
    const raw_end = if (item_end > item_start) lines[item_end - 1].end else first.end;
    const raw_item = trim(raw_frontmatter[first.start..raw_end]);
    var target: ?[]const u8 = null;
    var collection: ?[]const u8 = null;
    var malformed = false;

    var idx = item_start;
    while (idx < item_end) : (idx += 1) {
        var text = trim(lines[idx].raw);
        if (idx == item_start and std.mem.startsWith(u8, text, "-")) text = trim(text[1..]);
        if (text.len == 0 or text[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse {
            malformed = true;
            continue;
        };
        const key = trim(text[0..colon]);
        const value = trim(text[colon + 1 ..]);
        if (value.len == 0 or scalarLooksNonScalar(value)) {
            malformed = true;
            continue;
        }
        if (std.mem.eql(u8, key, "id")) {
            if (target != null) malformed = true else target = value;
        } else if (std.mem.eql(u8, key, "collection")) {
            if (collection != null) malformed = true else collection = value;
        } else {
            malformed = true;
        }
    }

    if (target == null or malformed) {
        try appendRawRelationValue(a, out, field, first.line, value_index, raw_item, null, null, "non_scalar_or_ambiguous_object");
    } else {
        try appendRawRelationValue(a, out, field, first.line, value_index, raw_item, target, collection, null);
    }
}

fn parseBlockRelationValues(
    a: std.mem.Allocator,
    out: *std.ArrayList(RawRelationValue),
    field: []const u8,
    field_line: u32,
    lines: []const FrontmatterLine,
    block_start: usize,
    block_end: usize,
    raw_frontmatter: []const u8,
    value_index: *usize,
) !void {
    var found_item = false;
    var i = block_start;
    while (i < block_end) {
        const text = trim(lines[i].raw);
        if (text.len == 0 or text[0] == '#') {
            i += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, text, "-")) {
            const raw_block = trim(raw_frontmatter[lines[block_start].start..lines[block_end - 1].end]);
            try appendRawRelationValue(a, out, field, field_line, value_index, raw_block, null, null, "non_scalar_block");
            return;
        }

        found_item = true;
        var next = i + 1;
        while (next < block_end) : (next += 1) {
            const next_text = trim(lines[next].raw);
            if (std.mem.startsWith(u8, next_text, "-")) break;
        }
        const after_dash = trim(text[1..]);
        if (after_dash.len == 0) {
            const raw_item = trim(raw_frontmatter[lines[i].start..lines[next - 1].end]);
            try appendRawRelationValue(a, out, field, lines[i].line, value_index, raw_item, null, null, "empty_list_item");
        } else if (std.mem.indexOfScalar(u8, after_dash, ':') != null or next > i + 1) {
            try parseObjectItem(a, out, field, lines, i, next, raw_frontmatter, value_index);
        } else if (scalarLooksNonScalar(after_dash)) {
            try appendRawRelationValue(a, out, field, lines[i].line, value_index, after_dash, null, null, "non_scalar_value");
        } else {
            try appendRawRelationValue(a, out, field, lines[i].line, value_index, after_dash, after_dash, null, null);
        }
        i = next;
    }
    if (!found_item) {
        try appendRawRelationValue(a, out, field, field_line, value_index, "", null, null, "empty_value");
    }
}

fn extractRawRelationValues(a: std.mem.Allocator, raw_frontmatter: []const u8) ![]const RawRelationValue {
    var out: std.ArrayList(RawRelationValue) = .empty;
    const lines = try splitFrontmatterLines(a, raw_frontmatter);
    var i: usize = 0;
    var value_index: usize = 0;
    while (i < lines.len) {
        const field_line = topLevelField(lines[i]) orelse {
            i += 1;
            continue;
        };
        const field = canonicalRelationSourceField(field_line.key) orelse {
            i += 1;
            continue;
        };
        var block_end = i + 1;
        while (block_end < lines.len) : (block_end += 1) {
            if (topLevelField(lines[block_end]) != null) break;
        }
        if (field_line.value.len > 0) {
            try parseInlineRelationValues(a, &out, field, lines[i].line, field_line.value, &value_index);
        } else {
            try parseBlockRelationValues(a, &out, field, lines[i].line, lines, i + 1, block_end, raw_frontmatter, &value_index);
        }
        i = block_end;
    }
    return try out.toOwnedSlice(a);
}

fn unquoteRelationScalar(raw: []const u8) ?[]const u8 {
    const v = trim(raw);
    if (v.len == 0) return null;
    if (v[0] == '\'' or v[0] == '"') {
        if (v.len < 2 or v[v.len - 1] != v[0]) return null;
        const inner = v[1 .. v.len - 1];
        if (std.mem.indexOfScalar(u8, inner, v[0]) != null or std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
        return if (inner.len == 0) null else inner;
    }
    if (v[v.len - 1] == '\'' or v[v.len - 1] == '"') return null;
    return v;
}

fn isTargetLikeEntityId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or id[0] == '/' or id[id.len - 1] == '/') return false;
    var it = std.mem.splitScalar(u8, id, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| {
            if (c == '\\' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '#' or c == '?') return false;
        }
    }
    return true;
}

fn normalizeRelationTarget(a: std.mem.Allocator, route_prefix: []const u8, raw: []const u8) !?[]const u8 {
    var value = unquoteRelationScalar(raw) orelse return null;
    if (std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "~")) return null;
    while (value.len > 1 and value[value.len - 1] == '/') value = value[0 .. value.len - 1];
    if (std.mem.startsWith(u8, value, "/")) {
        const from_route = try routeToEntityCandidate(a, route_prefix, value);
        if (from_route == null) return null;
        value = from_route.?;
    } else if (std.mem.startsWith(u8, value, "./")) {
        value = value[2..];
    }
    if (std.mem.endsWith(u8, value, ".mdx")) value = value[0 .. value.len - 4] else if (std.mem.endsWith(u8, value, ".md")) value = value[0 .. value.len - 3];
    if (std.mem.endsWith(u8, value, "/index")) value = value[0 .. value.len - 6];
    if (!isTargetLikeEntityId(value)) return null;
    return try a.dupe(u8, value);
}

const TargetResolution = struct {
    normalized_target: ?[]const u8,
    resolved_entity: ?[]const u8,
    state: []const u8,
    review_reason: ?[]const u8,
};

fn resolveRelationTarget(
    a: std.mem.Allocator,
    route_prefix: []const u8,
    raw_target: []const u8,
    raw_collection: ?[]const u8,
    entities: *const EntityMap,
) !TargetResolution {
    const normalized = try normalizeRelationTarget(a, route_prefix, raw_target) orelse return .{
        .normalized_target = null,
        .resolved_entity = null,
        .state = "not_attempted",
        .review_reason = "malformed_or_non_target_scalar",
    };

    if (raw_collection) |raw| {
        const collection = unquoteRelationScalar(raw);
        if (collection) |c| {
            if (!std.mem.eql(u8, c, "docs") and std.mem.indexOfScalar(u8, normalized, '/') == null and isTargetLikeEntityId(c)) {
                const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ c, normalized });
                if (entities.get(joined)) |resolved| {
                    return .{ .normalized_target = joined, .resolved_entity = resolved, .state = "resolved", .review_reason = null };
                }
            }
        }
    }
    if (entities.get(normalized)) |resolved| {
        return .{ .normalized_target = normalized, .resolved_entity = resolved, .state = "resolved", .review_reason = null };
    }

    // A bare slug may resolve only when it uniquely names one converted entity.
    var match: ?[]const u8 = null;
    var ambiguous = false;
    var it = entities.keyIterator();
    while (it.next()) |key_ptr| {
        const key = key_ptr.*;
        const suffix_match = std.mem.eql(u8, pageStemFromEntity(key), normalized) or
            (key.len > normalized.len and key[key.len - normalized.len - 1] == '/' and std.mem.endsWith(u8, key, normalized));
        if (!suffix_match) continue;
        if (match != null and !std.mem.eql(u8, match.?, key)) {
            ambiguous = true;
            break;
        }
        match = key;
    }
    if (ambiguous) return .{
        .normalized_target = normalized,
        .resolved_entity = null,
        .state = "ambiguous",
        .review_reason = "ambiguous_target_in_converted_entity_map",
    };
    if (match) |resolved| return .{
        .normalized_target = normalized,
        .resolved_entity = resolved,
        .state = "resolved",
        .review_reason = null,
    };
    return .{
        .normalized_target = normalized,
        .resolved_entity = null,
        .state = "unresolved",
        .review_reason = "target_not_in_converted_entity_map",
    };
}

fn collectRelationCandidatesForPage(
    a: std.mem.Allocator,
    page: SourcePage,
    route_prefix: []const u8,
    entities: *const EntityMap,
    out: *std.ArrayList(RelationCandidate),
) !void {
    const raw_values = try extractRawRelationValues(a, page.raw_frontmatter);
    var relation_ordinal: usize = 0;
    for (raw_values) |raw| {
        if (!relationFieldProposesKind(raw.source_field)) {
            try out.append(a, .{
                .source_path = page.source_path,
                .output_path = page.output_path,
                .source_entity = page.entity_id,
                .source_field = raw.source_field,
                .source_line = raw.source_line,
                .value_index = raw.value_index,
                .raw_value = raw.raw_value,
                .normalized_target = null,
                .proposed_kind = null,
                .target_resolution = if (raw.review_reason == null) "not_applicable" else "not_attempted",
                .resolved_entity = null,
                .relation_ordinal = null,
                .within_product_limit = null,
                .review_reason = raw.review_reason orelse "review_only_field_no_relation_kind",
            });
            continue;
        }
        if (raw.review_reason) |reason| {
            try out.append(a, .{
                .source_path = page.source_path,
                .output_path = page.output_path,
                .source_entity = page.entity_id,
                .source_field = raw.source_field,
                .source_line = raw.source_line,
                .value_index = raw.value_index,
                .raw_value = raw.raw_value,
                .normalized_target = null,
                .proposed_kind = null,
                .target_resolution = "not_attempted",
                .resolved_entity = null,
                .relation_ordinal = null,
                .within_product_limit = null,
                .review_reason = reason,
            });
            continue;
        }

        const resolution = try resolveRelationTarget(a, route_prefix, raw.target_value.?, raw.collection, entities);
        var proposed_kind: ?[]const u8 = null;
        var ordinal: ?usize = null;
        var within_limit: ?bool = null;
        var review_reason = resolution.review_reason;
        if (resolution.resolved_entity) |resolved| {
            if (std.mem.eql(u8, resolved, page.entity_id)) {
                review_reason = "self_target_not_product_relation";
            } else {
                relation_ordinal += 1;
                ordinal = relation_ordinal;
                within_limit = relation_ordinal <= product_relation_limit;
                proposed_kind = "relates_to";
                if (!within_limit.?) review_reason = "product_relation_limit_exceeded";
            }
        }
        try out.append(a, .{
            .source_path = page.source_path,
            .output_path = page.output_path,
            .source_entity = page.entity_id,
            .source_field = raw.source_field,
            .source_line = raw.source_line,
            .value_index = raw.value_index,
            .raw_value = raw.raw_value,
            .normalized_target = resolution.normalized_target,
            .proposed_kind = proposed_kind,
            .target_resolution = resolution.state,
            .resolved_entity = resolution.resolved_entity,
            .relation_ordinal = ordinal,
            .within_product_limit = within_limit,
            .review_reason = review_reason,
        });
    }
}

fn collectRelationCandidates(
    a: std.mem.Allocator,
    pages: []const SourcePage,
    route_prefix: []const u8,
    entities: *const EntityMap,
) ![]const RelationCandidate {
    var out: std.ArrayList(RelationCandidate) = .empty;
    for (pages) |page| {
        if (!page.is_synthetic) try collectRelationCandidatesForPage(a, page, route_prefix, entities, &out);
    }
    std.mem.sort(RelationCandidate, out.items, {}, struct {
        fn less(_: void, x: RelationCandidate, y: RelationCandidate) bool {
            var order = std.mem.order(u8, x.source_entity, y.source_entity);
            if (order != .eq) return order == .lt;
            order = std.mem.order(u8, x.source_field, y.source_field);
            if (order != .eq) return order == .lt;
            if (x.source_line != y.source_line) return x.source_line < y.source_line;
            if (x.value_index != y.value_index) return x.value_index < y.value_index;
            return std.mem.order(u8, x.raw_value, y.raw_value) == .lt;
        }
    }.less);
    return try out.toOwnedSlice(a);
}

fn categoryForBlockStart(line: []const u8) ?[]const u8 {
    const s = trim(line);
    const starts = [_]struct { prefix: []const u8, category: []const u8 }{
        .{ .prefix = ":::agent", .category = "agent_fence" },
        .{ .prefix = ":::directive", .category = "directive_fence" },
        .{ .prefix = ":::instruction", .category = "instruction_fence" },
        .{ .prefix = ":::prompt", .category = "prompt_fence" },
        .{ .prefix = "```agent", .category = "agent_code_fence" },
        .{ .prefix = "```directive", .category = "directive_code_fence" },
        .{ .prefix = "```instruction", .category = "instruction_code_fence" },
        .{ .prefix = "```prompt", .category = "prompt_code_fence" },
        .{ .prefix = "<Agent", .category = "agent_tag" },
        .{ .prefix = "<Directive", .category = "directive_tag" },
        .{ .prefix = "<Instruction", .category = "instruction_tag" },
    };
    for (starts) |entry| if (std.mem.startsWith(u8, s, entry.prefix)) return entry.category;
    return null;
}

fn isBlockEnd(line: []const u8, category: []const u8) bool {
    const s = trim(line);
    if (std.mem.endsWith(u8, category, "fence") or std.mem.endsWith(u8, category, "code_fence")) {
        return std.mem.eql(u8, s, ":::") or std.mem.eql(u8, s, "```");
    }
    return std.mem.startsWith(u8, s, "</");
}

fn stripUntrustedBlocks(a: std.mem.Allocator, body: []const u8) !struct { body: []const u8, blocks: []const StrippedBlock } {
    var out: std.ArrayList(u8) = .empty;
    var blocks: std.ArrayList(StrippedBlock) = .empty;
    var pos: usize = 0;
    var line_no: usize = 1;
    var active: ?[]const u8 = null;
    while (pos < body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = body[pos..end];
        const has_newline = end < body.len;
        if (active) |category| {
            if (isBlockEnd(line, category)) active = null;
        } else if (categoryForBlockStart(line)) |category| {
            try blocks.append(a, .{ .line = line_no, .category = category });
            active = category;
        } else {
            try out.appendSlice(a, line);
            if (has_newline) try out.append(a, '\n');
        }
        pos = if (has_newline) end + 1 else end;
        line_no += 1;
    }
    return .{ .body = try out.toOwnedSlice(a), .blocks = try blocks.toOwnedSlice(a) };
}

fn isImportLine(line: []const u8) bool {
    const s = trim(line);
    return std.mem.startsWith(u8, s, "import ") or std.mem.startsWith(u8, s, "export ");
}

fn extractImportPath(line: []const u8) ?[]const u8 {
    const s = trim(line);
    // import X from "path" / 'path'
    if (std.mem.indexOf(u8, s, " from ")) |fi| {
        var rest = trim(s[fi + " from ".len ..]);
        if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '\'')) {
            const q = rest[0];
            if (std.mem.indexOfScalarPos(u8, rest, 1, q)) |end| {
                return rest[1..end];
            }
        }
    }
    return null;
}

const TransformedMdx = struct {
    body: []const u8,
    events: []const LinkEvent,
};

fn parseAttribute(allocator: std.mem.Allocator, tag: []const u8, name: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        if (std.mem.startsWith(u8, tag[i..], name)) {
            const after_name = i + name.len;
            if (after_name < tag.len and (tag[after_name] == '=' or std.ascii.isWhitespace(tag[after_name]))) {
                var eq = after_name;
                while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
                if (eq < tag.len and tag[eq] == '=') {
                    var val_start = eq + 1;
                    while (val_start < tag.len and std.ascii.isWhitespace(tag[val_start])) : (val_start += 1) {}
                    if (val_start < tag.len) {
                        const quote = tag[val_start];
                        if (quote == '"' or quote == '\'') {
                            const val_end = std.mem.indexOfScalarPos(u8, tag, val_start + 1, quote);
                            if (val_end) |end| {
                                return try allocator.dupe(u8, tag[val_start + 1 .. end]);
                            }
                        } else if (quote == '{') {
                            const val_end = std.mem.indexOfScalarPos(u8, tag, val_start + 1, '}');
                            if (val_end) |end| {
                                return try allocator.dupe(u8, tag[val_start + 1 .. end]);
                            }
                        } else {
                            var end = val_start;
                            while (end < tag.len and !std.ascii.isWhitespace(tag[end]) and tag[end] != '>' and tag[end] != '/') : (end += 1) {}
                            return try allocator.dupe(u8, tag[val_start..end]);
                        }
                    }
                }
            }
        }
        i += 1;
    }
    return null;
}

fn isDynamicAssetAttribute(name: []const u8) bool {
    const names = [_][]const u8{ "src", "srcSet", "srcset", "poster", "data-src", "data-srcset" };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isHtmlAttributeNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == ':' or c == '_';
}

fn findHtmlTagEnd(line: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var braces: usize = 0;
    var i = start;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
        } else if (c == '{') {
            braces += 1;
        } else if (c == '}' and braces > 0) {
            braces -= 1;
        } else if (c == '>' and braces == 0) {
            return i;
        }
    }
    return null;
}

fn findJsxExpressionEnd(line: []const u8, start: usize, tag_end: usize) ?usize {
    if (start >= tag_end or line[start] != '{') return null;
    var quote: ?u8 = null;
    var braces: usize = 1;
    var i = start + 1;
    while (i < tag_end) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == q and line[i - 1] != '\\') quote = null;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
        } else if (c == '{') {
            braces += 1;
        } else if (c == '}') {
            braces -= 1;
            if (braces == 0) return i;
        }
    }
    return null;
}

/// Remove only dynamic JSX/HTML asset attribute values from a line. Static
/// attributes remain byte-for-byte unchanged. The exact removed attribute is
/// recorded as a review event so a human can restore the source expression.
fn neutralizeDynamicAssetAttrs(
    a: std.mem.Allocator,
    line: []const u8,
    line_no: u32,
    events: *std.ArrayList(LinkEvent),
    out: *std.ArrayList(u8),
) !usize {
    var cursor: usize = 0;
    var search: usize = 0;
    var count: usize = 0;

    while (std.mem.indexOfScalarPos(u8, line, search, '<')) |tag_start| {
        const tag_end = findHtmlTagEnd(line, tag_start) orelse break;
        if (tag_start + 1 >= tag_end or line[tag_start + 1] == '/' or
            line[tag_start + 1] == '!' or line[tag_start + 1] == '?')
        {
            search = tag_end + 1;
            continue;
        }

        var attr_scan = tag_start + 1;
        while (attr_scan < tag_end and isHtmlAttributeNameChar(line[attr_scan])) : (attr_scan += 1) {}
        while (attr_scan < tag_end) {
            while (attr_scan < tag_end and (std.ascii.isWhitespace(line[attr_scan]) or line[attr_scan] == '/')) : (attr_scan += 1) {}
            if (attr_scan >= tag_end) break;

            if (line[attr_scan] == '"' or line[attr_scan] == '\'' or line[attr_scan] == '`') {
                const q = line[attr_scan];
                attr_scan += 1;
                while (attr_scan < tag_end and line[attr_scan] != q) : (attr_scan += 1) {}
                if (attr_scan < tag_end) attr_scan += 1;
                continue;
            }
            if (line[attr_scan] == '{') {
                const expr_end = findJsxExpressionEnd(line, attr_scan, tag_end) orelse break;
                attr_scan = expr_end + 1;
                continue;
            }

            const attr_start = attr_scan;
            while (attr_scan < tag_end and isHtmlAttributeNameChar(line[attr_scan])) : (attr_scan += 1) {}
            if (attr_scan == attr_start) {
                attr_scan += 1;
                continue;
            }
            const attr_name = line[attr_start..attr_scan];
            var value_scan = attr_scan;
            while (value_scan < tag_end and std.ascii.isWhitespace(line[value_scan])) : (value_scan += 1) {}
            if (value_scan >= tag_end or line[value_scan] != '=') {
                attr_scan = value_scan;
                continue;
            }
            value_scan += 1;
            while (value_scan < tag_end and std.ascii.isWhitespace(line[value_scan])) : (value_scan += 1) {}
            if (value_scan >= tag_end or line[value_scan] != '{') {
                attr_scan = value_scan;
                continue;
            }
            const expr_end = findJsxExpressionEnd(line, value_scan, tag_end) orelse {
                attr_scan = value_scan + 1;
                continue;
            };

            if (isDynamicAssetAttribute(attr_name)) {
                try out.appendSlice(a, line[cursor..attr_start]);
                cursor = expr_end + 1;
                count += 1;
                try events.append(a, .{
                    .kind = "dynamic_asset",
                    .target = try a.dupe(u8, line[attr_start .. expr_end + 1]),
                    .line = line_no,
                    .resolution = "review",
                    .rewritten_to = "dynamic asset attribute omitted; see boundary_manifest.json",
                    .review_reason = "dynamic_asset_expression",
                });
            }
            attr_scan = expr_end + 1;
        }
        search = tag_end + 1;
    }

    if (count == 0) return 0;
    try out.appendSlice(a, line[cursor..]);
    return count;
}

fn transformStarlightMdx(a: std.mem.Allocator, body: []const u8) !TransformedMdx {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var events: std.ArrayList(LinkEvent) = .empty;
    errdefer events.deinit(a);

    var pos: usize = 0;
    var line_no: u32 = 1;

    var in_aside = false;

    while (pos < body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = body[pos..end];
        const has_newline = end < body.len;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, ":::")) {
            const block_content = std.mem.trim(u8, trimmed[3..], " \t\r");
            if (block_content.len == 0) {
                if (in_aside) {
                    try out.appendSlice(a, "</Aside>\n");
                    in_aside = false;
                    pos = if (has_newline) end + 1 else end;
                    line_no += 1;
                    continue;
                }
            } else {
                var kind: ?[]const u8 = null;
                var raw_title: ?[]const u8 = null;

                const space_pos = std.mem.indexOfScalar(u8, block_content, ' ');
                const bracket_pos = std.mem.indexOfScalar(u8, block_content, '[');
                const first_boundary = space_pos orelse bracket_pos orelse block_content.len;
                const kind_candidate = block_content[0..first_boundary];

                if (std.mem.eql(u8, kind_candidate, "note")) {
                    kind = "note";
                } else if (std.mem.eql(u8, kind_candidate, "tip")) {
                    kind = "tip";
                } else if (std.mem.eql(u8, kind_candidate, "caution") or std.mem.eql(u8, kind_candidate, "warning")) {
                    kind = "warning";
                } else if (std.mem.eql(u8, kind_candidate, "danger")) {
                    kind = "danger";
                }

                if (kind) |k| {
                    if (bracket_pos) |b_idx| {
                        if (std.mem.indexOfScalarPos(u8, block_content, b_idx, ']')) |e_idx| {
                            raw_title = block_content[b_idx + 1 .. e_idx];
                        }
                    }
                    try out.appendSlice(a, "<Aside kind=\"");
                    try out.appendSlice(a, k);
                    try out.appendSlice(a, "\">\n");

                    var rewritten_to_buf: std.ArrayList(u8) = .empty;
                    defer rewritten_to_buf.deinit(a);
                    try rewritten_to_buf.appendSlice(a, "<Aside kind=\"");
                    try rewritten_to_buf.appendSlice(a, k);
                    try rewritten_to_buf.appendSlice(a, "\">");

                    if (raw_title) |t| {
                        try out.appendSlice(a, "**");
                        try out.appendSlice(a, t);
                        try out.appendSlice(a, "**\n\n");
                        try rewritten_to_buf.appendSlice(a, " (title: ");
                        try rewritten_to_buf.appendSlice(a, t);
                        try rewritten_to_buf.appendSlice(a, ")");
                    }

                    try events.append(a, .{
                        .kind = "component_mapping",
                        .target = "MarkdownAdmonition",
                        .line = line_no,
                        .resolution = "rewritten",
                        .review_reason = "safe_mechanical_mapping",
                        .rewritten_to = try a.dupe(u8, rewritten_to_buf.items),
                    });

                    in_aside = true;
                    pos = if (has_newline) end + 1 else end;
                    line_no += 1;
                    continue;
                }
            }
        }

        if (std.mem.indexOfScalar(u8, trimmed, '<')) |_| {
            if (std.mem.indexOf(u8, trimmed, "<Tabs") != null) {
                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "Tabs",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = "flattened to Details blocks",
                });
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "</Tabs>") != null) {
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<TabItem") != null) {
                const idx = std.mem.indexOf(u8, trimmed, "<TabItem").?;
                const tag_end = std.mem.indexOfScalarPos(u8, trimmed, idx, '>') orelse trimmed.len;
                const tag_text = trimmed[idx..tag_end];
                const label = (try parseAttribute(a, tag_text, "label")) orelse "Tab";
                try out.appendSlice(a, "<Details summary=\"Tab: ");
                try out.appendSlice(a, label);
                try out.appendSlice(a, "\" open=\"true\">\n");

                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "TabItem",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = try std.fmt.allocPrint(a, "<Details summary=\"Tab: {s}\">", .{label}),
                });

                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "</TabItem>") != null) {
                try out.appendSlice(a, "</Details>\n");
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<CardGrid") != null) {
                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "CardGrid",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = "flattened grid wrapper",
                });
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "</CardGrid>") != null) {
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<Card") != null) {
                const idx = std.mem.indexOf(u8, trimmed, "<Card").?;
                const tag_end = std.mem.indexOfScalarPos(u8, trimmed, idx, '>') orelse trimmed.len;
                const tag_text = trimmed[idx..tag_end];
                const title = (try parseAttribute(a, tag_text, "title")) orelse "Card";
                const icon = try parseAttribute(a, tag_text, "icon");
                try out.appendSlice(a, "### [Card] ");
                try out.appendSlice(a, title);
                if (icon) |ic| {
                    try out.appendSlice(a, " (");
                    try out.appendSlice(a, ic);
                    try out.appendSlice(a, ")");
                }
                try out.appendSlice(a, "\n");

                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "Card",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = try std.fmt.allocPrint(a, "### [Card] {s}", .{title}),
                });

                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "</Card>") != null) {
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<Steps>") != null) {
                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "Steps",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "safe_mechanical_mapping",
                    .rewritten_to = "stripped steps wrapper",
                });
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "</Steps>") != null) {
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<Aside") != null) {
                const idx = std.mem.indexOf(u8, trimmed, "<Aside").?;
                const tag_end = std.mem.indexOfScalarPos(u8, trimmed, idx, '>') orelse trimmed.len;
                const tag_text = trimmed[idx..tag_end];
                const type_attr = (try parseAttribute(a, tag_text, "type")) orelse (try parseAttribute(a, tag_text, "kind")) orelse "note";
                const title = try parseAttribute(a, tag_text, "title");

                var is_valid_kind = false;
                var normalized_kind: []const u8 = "note";
                if (std.mem.eql(u8, type_attr, "note")) {
                    normalized_kind = "note";
                    is_valid_kind = true;
                } else if (std.mem.eql(u8, type_attr, "tip")) {
                    normalized_kind = "tip";
                    is_valid_kind = true;
                } else if (std.mem.eql(u8, type_attr, "caution") or std.mem.eql(u8, type_attr, "warning")) {
                    normalized_kind = "warning";
                    is_valid_kind = true;
                } else if (std.mem.eql(u8, type_attr, "danger")) {
                    normalized_kind = "danger";
                    is_valid_kind = true;
                }

                if (!is_valid_kind) {
                    try events.append(a, .{
                        .kind = "component_mapping",
                        .target = "Aside",
                        .line = line_no,
                        .resolution = "review",
                        .review_reason = "manual_review_required",
                        .rewritten_to = try std.fmt.allocPrint(a, "unsupported type='{s}'", .{type_attr}),
                    });
                } else {
                    try events.append(a, .{
                        .kind = "component_mapping",
                        .target = "Aside",
                        .line = line_no,
                        .resolution = "rewritten",
                        .review_reason = if (title != null) "lossy_explicit_approximation" else "safe_mechanical_mapping",
                        .rewritten_to = try std.fmt.allocPrint(a, "<Aside kind=\"{s}\">", .{normalized_kind}),
                    });
                }

                try out.appendSlice(a, "<Aside kind=\"");
                try out.appendSlice(a, normalized_kind);
                try out.appendSlice(a, "\">\n");
                if (title) |ti| {
                    try out.appendSlice(a, "**");
                    try out.appendSlice(a, ti);
                    try out.appendSlice(a, "**\n\n");
                }

                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "</Aside>") != null) {
                try out.appendSlice(a, "</Aside>\n");
                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<Badge") != null) {
                const idx = std.mem.indexOf(u8, trimmed, "<Badge").?;
                const tag_end = std.mem.indexOfScalarPos(u8, trimmed, idx, '>') orelse trimmed.len;
                const tag_text = trimmed[idx..tag_end];
                const text = (try parseAttribute(a, tag_text, "text")) orelse "Badge";
                try out.appendSlice(a, "**[");
                try out.appendSlice(a, text);
                try out.appendSlice(a, "]**");

                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "Badge",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = try std.fmt.allocPrint(a, "**[{s}]**", .{text}),
                });

                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<Icon") != null) {
                const idx = std.mem.indexOf(u8, trimmed, "<Icon").?;
                const tag_end = std.mem.indexOfScalarPos(u8, trimmed, idx, '>') orelse trimmed.len;
                const tag_text = trimmed[idx..tag_end];
                const name = (try parseAttribute(a, tag_text, "name")) orelse "icon";
                try out.appendSlice(a, "(icon: ");
                try out.appendSlice(a, name);
                try out.appendSlice(a, ")");

                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "Icon",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = try std.fmt.allocPrint(a, "(icon: {s})", .{name}),
                });

                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "<LinkCard") != null) {
                const idx = std.mem.indexOf(u8, trimmed, "<LinkCard").?;
                const tag_end = std.mem.indexOfScalarPos(u8, trimmed, idx, '>') orelse trimmed.len;
                const tag_text = trimmed[idx..tag_end];
                const title = (try parseAttribute(a, tag_text, "title")) orelse "Link";
                const href = (try parseAttribute(a, tag_text, "href")) orelse "#";
                const desc = try parseAttribute(a, tag_text, "description");

                try out.appendSlice(a, "### [Link Card] ");
                try out.appendSlice(a, title);
                try out.appendSlice(a, "\n\n");
                try out.appendSlice(a, "[Link](");
                try out.appendSlice(a, href);
                try out.appendSlice(a, ")");
                if (desc) |d| {
                    try out.appendSlice(a, " - ");
                    try out.appendSlice(a, d);
                }
                try out.appendSlice(a, "\n");

                try events.append(a, .{
                    .kind = "component_mapping",
                    .target = "LinkCard",
                    .line = line_no,
                    .resolution = "rewritten",
                    .review_reason = "lossy_explicit_approximation",
                    .rewritten_to = try std.fmt.allocPrint(a, "### [Link Card] {s}", .{title}),
                });

                pos = if (has_newline) end + 1 else end;
                line_no += 1;
                continue;
            }
        }

        try out.appendSlice(a, line);
        if (has_newline) try out.append(a, '\n');
        pos = if (has_newline) end + 1 else end;
        line_no += 1;
    }

    return TransformedMdx{
        .body = try out.toOwnedSlice(a),
        .events = try events.toOwnedSlice(a),
    };
}

/// Detect PascalCase JSX/MDX component tag names on a line.
fn scanComponentTags(a: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '<') continue;
        if (i + 1 >= line.len) break;
        const c1 = line[i + 1];
        // Skip closing tags, comments, doctype.
        if (c1 == '/' or c1 == '!' or c1 == '?') continue;
        if (c1 < 'A' or c1 > 'Z') continue;
        var j = i + 1;
        while (j < line.len) {
            const c = line[j];
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_') {
                j += 1;
            } else break;
        }
        const name = line[i + 1 .. j];
        // Dedup within page later; append raw for now.
        try out.append(a, try a.dupe(u8, name));
        i = j - 1;
    }
}

/// Strip import lines and wrap MDX component open tags so body stays mostly Markdown.
/// Component *children* text is preserved; tag shells become HTML comments.
fn sanitizeMdxBody(a: std.mem.Allocator, body: []const u8) !struct {
    body: []const u8,
    imports: []const []const u8,
    components: []const []const u8,
    asset_events: []const LinkEvent,
} {
    var out: std.ArrayList(u8) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    var components: std.ArrayList([]const u8) = .empty;
    var asset_events: std.ArrayList(LinkEvent) = .empty;
    var pos: usize = 0;
    var line_no: u32 = 1;
    while (pos < body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = body[pos..end];
        const has_newline = end < body.len;
        if (isImportLine(line)) {
            if (extractImportPath(line)) |p| {
                try imports.append(a, try a.dupe(u8, p));
            } else {
                try imports.append(a, try a.dupe(u8, trim(line)));
            }
        } else {
            var dynamic_line: std.ArrayList(u8) = .empty;
            const dynamic_count = try neutralizeDynamicAssetAttrs(a, line, line_no, &asset_events, &dynamic_line);
            defer dynamic_line.deinit(a);
            const source_line = if (dynamic_count > 0) dynamic_line.items else line;
            if (dynamic_count > 0) {
                for (asset_events.items[asset_events.items.len - dynamic_count ..]) |_| {
                    try out.appendSlice(a, "<!-- boris-migration-review: dynamic asset attribute omitted; see boundary_manifest.json -->\n");
                }
            }
            try scanComponentTags(a, source_line, &components);
            // Neutralize JSX open/self-closing tags without executing them.
            var li: usize = 0;
            while (li < source_line.len) {
                if (source_line[li] == '<' and li + 1 < source_line.len) {
                    const c1 = source_line[li + 1];
                    if (c1 == '/') {
                        // Closing tag: skip through >
                        var k = li + 2;
                        while (k < source_line.len and source_line[k] != '>') : (k += 1) {}
                        if (k < source_line.len) k += 1;
                        const tag_content = source_line[li + 2 .. k - 1];
                        var name_end: usize = 0;
                        while (name_end < tag_content.len and !std.ascii.isWhitespace(tag_content[name_end]) and tag_content[name_end] != '/' and tag_content[name_end] != '>') : (name_end += 1) {}
                        const tag_name = tag_content[0..name_end];
                        if (std.mem.eql(u8, tag_name, "Aside") or std.mem.eql(u8, tag_name, "Details")) {
                            try out.appendSlice(a, source_line[li..k]);
                        }
                        li = k;
                        continue;
                    }
                    if (c1 >= 'A' and c1 <= 'Z') {
                        var k = li + 1;
                        while (k < source_line.len and source_line[k] != '>') : (k += 1) {}
                        if (k < source_line.len) k += 1;
                        const tag_content = source_line[li + 1 .. k - 1];
                        var name_end: usize = 0;
                        while (name_end < tag_content.len and !std.ascii.isWhitespace(tag_content[name_end]) and tag_content[name_end] != '/' and tag_content[name_end] != '>') : (name_end += 1) {}
                        const tag_name = tag_content[0..name_end];
                        if (std.mem.eql(u8, tag_name, "Aside") or std.mem.eql(u8, tag_name, "Details")) {
                            try out.appendSlice(a, source_line[li..k]);
                        } else {
                            try out.appendSlice(a, "<!-- unsupported-mdx-component -->");
                        }
                        li = k;
                        continue;
                    }
                }
                try out.append(a, source_line[li]);
                li += 1;
            }
            if (has_newline) try out.append(a, '\n');
        }
        pos = if (has_newline) end + 1 else end;
        line_no += 1;
    }
    // Dedup component names deterministically.
    std.mem.sort([]const u8, components.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    var dedup: std.ArrayList([]const u8) = .empty;
    var prev: ?[]const u8 = null;
    for (components.items) |c| {
        if (prev) |p| if (std.mem.eql(u8, p, c)) {
            a.free(c);
            continue;
        };
        try dedup.append(a, c);
        prev = c;
    }
    components.deinit(a);
    return .{
        .body = try out.toOwnedSlice(a),
        .imports = try imports.toOwnedSlice(a),
        .components = try dedup.toOwnedSlice(a),
        .asset_events = try asset_events.toOwnedSlice(a),
    };
}

/// Split path and optional `#fragment` (query dropped). Empty path with fragment → path "".
fn splitTargetFragment(allocator: std.mem.Allocator, target: []const u8) !struct { path: []u8, fragment: ?[]u8 } {
    var t = target;
    if (std.mem.indexOfScalar(u8, t, '?')) |q| t = t[0..q];
    var frag: ?[]u8 = null;
    if (std.mem.indexOfScalar(u8, t, '#')) |h| {
        if (h + 1 < t.len) {
            frag = try allocator.dupe(u8, t[h + 1 ..]);
        } else {
            frag = try allocator.dupe(u8, "");
        }
        t = t[0..h];
    }
    // Strip trailing slash (Starlight often uses trailingSlash: always; others never).
    while (t.len > 1 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
    return .{ .path = try allocator.dupe(u8, t), .fragment = frag };
}

fn normalizeRouteTarget(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    const split = try splitTargetFragment(allocator, target);
    // Caller uses fragment separately; return path only.
    return split.path;
}

fn resolveRelativeToEntity(allocator: std.mem.Allocator, entity_id: []const u8, rel: []const u8) ![]u8 {
    // entity_id like features/plans; rel like ./co2 or ../installation/linux
    var base_dir: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, entity_id, '/')) |i| {
        base_dir = entity_id[0..i];
    }
    var path_buf: std.ArrayList(u8) = .empty;
    if (base_dir.len > 0) {
        try path_buf.appendSlice(allocator, base_dir);
    }
    // Split rel on /
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (path_buf.items.len == 0) continue;
            if (std.mem.lastIndexOfScalar(u8, path_buf.items, '/')) |i| {
                path_buf.items.len = i;
            } else {
                path_buf.items.len = 0;
            }
            continue;
        }
        // Drop .md/.mdx suffix if present.
        const clean = slugStem(seg);
        if (path_buf.items.len > 0) try path_buf.append(allocator, '/');
        try path_buf.appendSlice(allocator, clean);
    }
    if (path_buf.items.len == 0) return try allocator.dupe(u8, "index");
    return try path_buf.toOwnedSlice(allocator);
}

fn pageStemFromEntity(entity_id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, entity_id, '/')) |i| return entity_id[i + 1 ..];
    return entity_id;
}

fn pageDirFromLocaleRel(locale_rel: []const u8) []const u8 {
    if (std.fs.path.dirname(locale_rel)) |d| {
        if (d.len == 0 or std.mem.eql(u8, d, ".")) return "";
        return d;
    }
    return "";
}

/// Asset-like path extensions that may be content/public media.
fn isAssetLikePath(path: []const u8) bool {
    const lower_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".mp4", ".webm", ".pdf", ".ico", ".css", ".js", ".woff", ".woff2" };
    for (lower_exts) |ext| {
        if (path.len >= ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Boris content-local within-tree grammar: `/`-separated `[A-Za-z0-9._-]+` segments.
fn isBorisSafeWithinTree(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var start: usize = 0;
    while (start <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const seg = path[start..slash];
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |c| {
            const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
            if (!ok) return false;
        }
        if (slash >= path.len) break;
        start = slash + 1;
    }
    return true;
}

/// Join `base` + `rel` with `/` segments, resolving `.` and `..`.
/// Returns null when `..` would escape above the base root.
fn joinNormalized(allocator: std.mem.Allocator, base: []const u8, rel: []const u8) !?[]u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(allocator);
    const push_parts = struct {
        fn go(a: std.mem.Allocator, list: *std.ArrayList([]const u8), parts: []const u8) !?void {
            var it = std.mem.splitScalar(u8, parts, '/');
            while (it.next()) |seg| {
                if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
                if (std.mem.eql(u8, seg, "..")) {
                    if (list.items.len == 0) return null;
                    _ = list.pop();
                    continue;
                }
                try list.append(a, seg);
            }
            return {};
        }
    }.go;
    if ((try push_parts(allocator, &segs, base)) == null) return null;
    if ((try push_parts(allocator, &segs, rel)) == null) return null;
    if (segs.items.len == 0) return try allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segs.items, 0..) |s, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, s);
    }
    return try out.toOwnedSlice(allocator);
}

fn pathExistsFile(io: Io, root: Io.Dir, rel: []const u8) bool {
    if (rel.len == 0) return false;
    var file = root.openFile(io, rel, .{}) catch return false;
    file.close(io);
    return true;
}

fn stripImageDestExtras(dest: []const u8) []const u8 {
    var t = trim(dest);
    if (t.len >= 2 and t[0] == '<' and t[t.len - 1] == '>') {
        t = trim(t[1 .. t.len - 1]);
    }
    // Markdown image title: url "title" — keep only the url token.
    if (std.mem.indexOfScalar(u8, t, ' ')) |sp| {
        const rest = trim(t[sp..]);
        if (rest.len > 0 and rest[0] == '"') t = trim(t[0..sp]);
    }
    return t;
}

const ImageResolveStatus = enum {
    found,
    missing,
    escape,
    invalid,
};

const ImageResolve = struct {
    status: ImageResolveStatus,
    /// Project-root-relative source path when found.
    source_rel: ?[]const u8 = null,
    /// Within-tree path under `{stem}.assets/`.
    within_tree: ?[]const u8 = null,
    /// Preserve an already-correct `{stem}.assets/…` Markdown destination.
    preserve_ref: bool = false,
};

/// Resolve a Markdown image destination against the source document and known roots
/// (`content_root`, `public/`). Never invents paths; escape/missing/invalid are explicit.
fn resolveImageSource(
    a: std.mem.Allocator,
    io: Io,
    source: Io.Dir,
    content_root: []const u8,
    locale_rel: []const u8,
    entity_id: []const u8,
    raw_dest: []const u8,
) !ImageResolve {
    const dest = stripImageDestExtras(raw_dest);
    if (dest.len == 0) return .{ .status = .invalid };
    if (std.mem.startsWith(u8, dest, "http://") or std.mem.startsWith(u8, dest, "https://") or
        std.mem.startsWith(u8, dest, "mailto:") or std.mem.startsWith(u8, dest, "tel:") or
        std.mem.startsWith(u8, dest, "data:") or std.mem.startsWith(u8, dest, "//"))
    {
        return .{ .status = .invalid }; // caller should not treat remotes as local
    }
    if (std.mem.indexOfScalar(u8, dest, '\\') != null) return .{ .status = .invalid };

    // Drop query (documented limitation); keep path for fragment split.
    const split = try splitTargetFragment(a, dest);
    const norm = split.path;
    if (norm.len == 0) return .{ .status = .invalid };

    const stem = pageStemFromEntity(entity_id);
    const page_dir = pageDirFromLocaleRel(locale_rel);
    const already_prefix = try std.fmt.allocPrint(a, "{s}.assets/", .{stem});

    // Already-correct Boris form relative to the page: `{stem}.assets/within…`
    var rel_for_already = norm;
    if (std.mem.startsWith(u8, rel_for_already, "./")) rel_for_already = rel_for_already[2..];
    if (std.mem.startsWith(u8, rel_for_already, already_prefix)) {
        const within = rel_for_already[already_prefix.len..];
        if (!isBorisSafeWithinTree(within)) return .{ .status = .invalid };
        const under_page = if (page_dir.len == 0)
            try a.dupe(u8, rel_for_already)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ page_dir, rel_for_already });
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ content_root, under_page });
        if (pathExistsFile(io, source, full)) {
            return .{
                .status = .found,
                .source_rel = full,
                .within_tree = within,
                .preserve_ref = true,
            };
        }
        return .{ .status = .missing, .source_rel = full, .within_tree = within };
    }

    // Site-absolute → public/
    if (std.mem.startsWith(u8, norm, "/")) {
        if (std.mem.indexOf(u8, norm, "/../") != null or std.mem.endsWith(u8, norm, "/..") or
            std.mem.startsWith(u8, norm, "/.."))
            return .{ .status = .escape };
        const under_public = try std.fmt.allocPrint(a, "public{s}", .{norm});
        if (!isBorisSafeWithinTree(norm[1..])) {
            // Still report existence when possible, but refuse unsafe within-tree copy.
            if (pathExistsFile(io, source, under_public)) return .{ .status = .invalid, .source_rel = under_public };
            return .{ .status = .invalid };
        }
        if (pathExistsFile(io, source, under_public)) {
            return .{
                .status = .found,
                .source_rel = under_public,
                .within_tree = norm[1..],
            };
        }
        return .{ .status = .missing, .source_rel = under_public, .within_tree = norm[1..] };
    }

    // Relative to source document directory under the content root.
    var rel = norm;
    if (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    const joined = try joinNormalized(a, page_dir, rel) orelse return .{ .status = .escape };
    const full = if (joined.len == 0)
        try a.dupe(u8, content_root)
    else
        try std.fmt.allocPrint(a, "{s}/{s}", .{ content_root, joined });

    // Within-tree: prefer path relative to the page directory; else basename.
    var within: []const u8 = undefined;
    if (page_dir.len > 0) {
        const pfx = try std.fmt.allocPrint(a, "{s}/", .{page_dir});
        if (std.mem.startsWith(u8, joined, pfx)) {
            within = joined[pfx.len..];
        } else if (std.mem.eql(u8, joined, page_dir)) {
            return .{ .status = .invalid };
        } else {
            within = std.fs.path.basename(joined);
        }
    } else {
        within = joined;
    }
    if (within.len == 0 or !isBorisSafeWithinTree(within)) {
        if (pathExistsFile(io, source, full)) return .{ .status = .invalid, .source_rel = full };
        return .{ .status = .invalid };
    }

    if (pathExistsFile(io, source, full)) {
        return .{ .status = .found, .source_rel = full, .within_tree = within };
    }

    // Fallback: content-root-relative (authors sometimes omit ./ from section root).
    if (page_dir.len > 0) {
        const alt_join = try joinNormalized(a, "", rel) orelse return .{ .status = .escape };
        if (alt_join.len > 0) {
            const alt_full = try std.fmt.allocPrint(a, "{s}/{s}", .{ content_root, alt_join });
            if (pathExistsFile(io, source, alt_full) and isBorisSafeWithinTree(std.fs.path.basename(alt_join))) {
                return .{
                    .status = .found,
                    .source_rel = alt_full,
                    .within_tree = std.fs.path.basename(alt_join),
                };
            }
        }
    }

    return .{ .status = .missing, .source_rel = full, .within_tree = within };
}

/// Rewrite Markdown images (`![alt](dest)`) that resolve to proven local files into
/// Boris page-sibling `{stem}.assets/` destinations, and schedule byte copies under --out.
/// Missing / escape / invalid destinations are left unchanged with explicit review events.
/// Query strings are dropped (same as link targets); fragments are reattached when present.
fn migratePageImages(
    a: std.mem.Allocator,
    io: Io,
    source: Io.Dir,
    content_root: []const u8,
    page: *SourcePage,
    migrated: *std.ArrayList(MigratedAsset),
) !void {
    if (page.is_synthetic) return;
    const body = page.body;
    var out: std.ArrayList(u8) = .empty;
    var events: std.ArrayList(LinkEvent) = .empty;
    // Preserve prior link-rewrite events.
    try events.appendSlice(a, page.link_events);

    var pos: usize = 0;
    var line_no: u32 = 1;
    // Per-page within-tree occupancy for collision disambiguation.
    var used_within: std.StringHashMapUnmanaged([]const u8) = .empty; // within → source_rel

    while (pos < body.len) {
        if (body[pos] == '!' and pos + 1 < body.len and body[pos + 1] == '[') {
            if (std.mem.indexOfPos(u8, body, pos + 2, "](")) |mid| {
                const text = body[pos + 2 .. mid];
                if (std.mem.indexOfScalar(u8, text, '\n') == null) {
                    const url_start = mid + 2;
                    if (std.mem.indexOfScalarPos(u8, body, url_start, ')')) |url_end| {
                        const raw_url = body[url_start..url_end];
                        if (std.mem.indexOfScalar(u8, raw_url, '\n') == null) {
                            const dest_core = stripImageDestExtras(raw_url);
                            // Remote / non-local schemes: leave bytes unchanged.
                            if (std.mem.startsWith(u8, dest_core, "http://") or
                                std.mem.startsWith(u8, dest_core, "https://") or
                                std.mem.startsWith(u8, dest_core, "mailto:") or
                                std.mem.startsWith(u8, dest_core, "tel:") or
                                std.mem.startsWith(u8, dest_core, "data:") or
                                std.mem.startsWith(u8, dest_core, "//"))
                            {
                                try out.appendSlice(a, body[pos .. url_end + 1]);
                                pos = url_end + 1;
                                continue;
                            }

                            // Only attempt migration for asset-like destinations.
                            const split = try splitTargetFragment(a, dest_core);
                            if (!isAssetLikePath(split.path)) {
                                try out.appendSlice(a, body[pos .. url_end + 1]);
                                pos = url_end + 1;
                                continue;
                            }

                            const resolved = try resolveImageSource(
                                a,
                                io,
                                source,
                                content_root,
                                page.locale_rel,
                                page.entity_id,
                                dest_core,
                            );

                            switch (resolved.status) {
                                .found => {
                                    const within0 = resolved.within_tree.?;
                                    const source_rel = resolved.source_rel.?;
                                    // Disambiguate within-tree collisions on the same page.
                                    var within = within0;
                                    if (used_within.get(within)) |prior| {
                                        if (!std.mem.eql(u8, prior, source_rel)) {
                                            // Insert -N before extension.
                                            const ext_at = std.mem.lastIndexOfScalar(u8, within0, '.') orelse within0.len;
                                            var n: usize = 2;
                                            while (n < 1000) : (n += 1) {
                                                const cand = try std.fmt.allocPrint(a, "{s}-{d}{s}", .{
                                                    within0[0..ext_at],
                                                    n,
                                                    within0[ext_at..],
                                                });
                                                if (used_within.get(cand) == null) {
                                                    within = cand;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                    try used_within.put(a, within, source_rel);

                                    const stem = pageStemFromEntity(page.entity_id);
                                    const md_ref = if (resolved.preserve_ref)
                                        try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, within })
                                    else
                                        try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ stem, within });
                                    // Reattach fragment when present; queries stay dropped.
                                    const rewritten_ref = if (split.fragment) |frag|
                                        try std.fmt.allocPrint(a, "{s}#{s}", .{ md_ref, frag })
                                    else
                                        md_ref;

                                    // Output path: content/{entity_dir}{stem}.assets/{within}
                                    // page.output_path is content/{entity}.md
                                    const out_md = page.output_path; // content/features/alpha.md
                                    const out_stem_path = out_md[0 .. out_md.len - 3]; // strip .md
                                    const dest_path = try std.fmt.allocPrint(a, "{s}.assets/{s}", .{ out_stem_path, within });

                                    // Read + hash once for manifest.
                                    const data = try readFileAlloc(io, source, source_rel, a);
                                    const hex = try sha256Hex(a, data);

                                    try migrated.append(a, .{
                                        .source_path = source_rel,
                                        .dest_path = dest_path,
                                        .within_tree = within,
                                        .page_entity = page.entity_id,
                                        .original_ref = try a.dupe(u8, dest_core),
                                        .rewritten_ref = rewritten_ref,
                                        .bytes = data.len,
                                        .sha256_hex = hex,
                                    });

                                    try events.append(a, .{
                                        .kind = "markdown_image",
                                        .target = try a.dupe(u8, dest_core),
                                        .line = line_no,
                                        .resolution = "rewritten",
                                        .rewritten_to = rewritten_ref,
                                        .review_reason = "image_migrated_to_page_assets",
                                        .fragment = split.fragment,
                                    });

                                    try out.appendSlice(a, "![");
                                    try out.appendSlice(a, text);
                                    try out.appendSlice(a, "](");
                                    try out.appendSlice(a, rewritten_ref);
                                    try out.append(a, ')');
                                    pos = url_end + 1;
                                    continue;
                                },
                                .missing => {
                                    try events.append(a, .{
                                        .kind = "markdown_image",
                                        .target = try a.dupe(u8, dest_core),
                                        .line = line_no,
                                        .resolution = "review",
                                        .review_reason = "referenced_asset_missing",
                                        .fragment = split.fragment,
                                    });
                                    try out.appendSlice(a, body[pos .. url_end + 1]);
                                    pos = url_end + 1;
                                    continue;
                                },
                                .escape => {
                                    try events.append(a, .{
                                        .kind = "markdown_image",
                                        .target = try a.dupe(u8, dest_core),
                                        .line = line_no,
                                        .resolution = "review",
                                        .review_reason = "asset_path_escapes_migration_root",
                                        .fragment = split.fragment,
                                    });
                                    try out.appendSlice(a, body[pos .. url_end + 1]);
                                    pos = url_end + 1;
                                    continue;
                                },
                                .invalid => {
                                    try events.append(a, .{
                                        .kind = "markdown_image",
                                        .target = try a.dupe(u8, dest_core),
                                        .line = line_no,
                                        .resolution = "review",
                                        .review_reason = "asset_path_invalid_or_not_boris_safe",
                                        .fragment = split.fragment,
                                    });
                                    try out.appendSlice(a, body[pos .. url_end + 1]);
                                    pos = url_end + 1;
                                    continue;
                                },
                            }
                        }
                    }
                }
            }
        }
        if (body[pos] == '\n') line_no += 1;
        try out.append(a, body[pos]);
        pos += 1;
    }

    page.body = try out.toOwnedSlice(a);
    page.link_events = try events.toOwnedSlice(a);
}

fn routeToEntityCandidate(allocator: std.mem.Allocator, route_prefix: []const u8, route: []const u8) !?[]u8 {
    // locale_dir: /en → index ; /en/features/app → features/app
    // root_locale: / → index ; /features/app → features/app
    if (!std.mem.startsWith(u8, route, "/")) return null;

    if (route_prefix.len == 0) {
        if (std.mem.eql(u8, route, "/") or route.len == 0) return try allocator.dupe(u8, "index");
        // Absolute path under site root.
        return try allocator.dupe(u8, route[1..]);
    }

    if (std.mem.eql(u8, route, route_prefix)) return try allocator.dupe(u8, "index");
    const with_slash = try std.fmt.allocPrint(allocator, "{s}/", .{route_prefix});
    if (std.mem.startsWith(u8, route, with_slash)) {
        return try allocator.dupe(u8, route[with_slash.len..]);
    }
    return null;
}

const EntityMap = std.StringHashMapUnmanaged([]const u8); // entity_id → entity_id (presence)

fn rewriteLinks(
    a: std.mem.Allocator,
    route_prefix: []const u8,
    entity_id: []const u8,
    body: []const u8,
    entities: *const EntityMap,
) !struct { body: []const u8, events: []const LinkEvent } {
    var out: std.ArrayList(u8) = .empty;
    var events: std.ArrayList(LinkEvent) = .empty;
    var pos: usize = 0;
    var line_no: u32 = 1;

    while (pos < body.len) {
        // Scan for markdown link [text](url). Images (`![...](...)`) are left for
        // migratePageImages so page-local asset migration owns that surface.
        if (body[pos] == '[') {
            const is_image = pos > 0 and body[pos - 1] == '!';
            if (!is_image) {
                // Find ](
                if (std.mem.indexOfPos(u8, body, pos, "](")) |mid| {
                    const text = body[pos + 1 .. mid];
                    // Reject if nested newline in text for simplicity (multi-line links → leave).
                    if (std.mem.indexOfScalar(u8, text, '\n') == null) {
                        const url_start = mid + 2;
                        if (std.mem.indexOfScalarPos(u8, body, url_start, ')')) |url_end| {
                            const url = body[url_start..url_end];
                            if (std.mem.indexOfScalar(u8, url, '\n') == null) {
                                const ev = try classifyAndMaybeRewrite(a, route_prefix, entity_id, url, entities, "markdown", line_no);
                                try events.append(a, ev);
                                if (std.mem.eql(u8, ev.resolution, "rewritten")) {
                                    try out.appendSlice(a, "[[");
                                    try out.appendSlice(a, ev.rewritten_to.?);
                                    if (text.len > 0) {
                                        try out.append(a, '|');
                                        try out.appendSlice(a, text);
                                    }
                                    try out.appendSlice(a, "]]");
                                } else {
                                    try out.appendSlice(a, body[pos .. url_end + 1]);
                                }
                                pos = url_end + 1;
                                continue;
                            }
                        }
                    }
                }
            }
        }
        if (body[pos] == '\n') line_no += 1;
        try out.append(a, body[pos]);
        pos += 1;
    }

    // Second pass: scan href="/..." and to="/..." for inventory (never rewrite attributes).
    {
        var p: usize = 0;
        var ln: u32 = 1;
        while (p < body.len) {
            const end = std.mem.indexOfScalarPos(u8, body, p, '\n') orelse body.len;
            const line = body[p..end];
            try scanAttrLinks(a, route_prefix, entity_id, line, entities, ln, &events);
            p = if (end < body.len) end + 1 else end;
            ln += 1;
        }
    }

    return .{ .body = try out.toOwnedSlice(a), .events = try events.toOwnedSlice(a) };
}

fn scanAttrLinks(
    a: std.mem.Allocator,
    route_prefix: []const u8,
    entity_id: []const u8,
    line: []const u8,
    entities: *const EntityMap,
    line_no: u32,
    events: *std.ArrayList(LinkEvent),
) !void {
    const attrs = [_]struct { prefix: []const u8, kind: []const u8 }{
        .{ .prefix = "href=\"", .kind = "href" },
        .{ .prefix = "href='", .kind = "href" },
        .{ .prefix = "to=\"", .kind = "to" },
        .{ .prefix = "to='", .kind = "to" },
    };
    for (attrs) |attr| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, line, search, attr.prefix)) |at| {
            const q = attr.prefix[attr.prefix.len - 1];
            const vs = at + attr.prefix.len;
            const ve = std.mem.indexOfScalarPos(u8, line, vs, q) orelse break;
            const url = line[vs..ve];
            const ev = try classifyAndMaybeRewrite(a, route_prefix, entity_id, url, entities, attr.kind, line_no);
            // Attr links are never auto-rewritten; force explicit review when a rewrite was possible.
            if (std.mem.eql(u8, ev.resolution, "rewritten")) {
                try events.append(a, .{
                    .kind = attr.kind,
                    .target = ev.target,
                    .line = line_no,
                    .resolution = "review",
                    .rewritten_to = ev.rewritten_to,
                    .review_reason = "attribute_link_not_auto_rewritten",
                    .fragment = ev.fragment,
                });
            } else {
                try events.append(a, ev);
            }
            search = ve + 1;
        }
    }
}

fn classifyAndMaybeRewrite(
    a: std.mem.Allocator,
    route_prefix: []const u8,
    entity_id: []const u8,
    raw_url: []const u8,
    entities: *const EntityMap,
    kind: []const u8,
    line_no: u32,
) !LinkEvent {
    const url = trim(raw_url);
    if (url.len == 0) {
        return .{ .kind = kind, .target = url, .line = line_no, .resolution = "leave", .review_reason = "empty" };
    }
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "mailto:") or std.mem.startsWith(u8, url, "tel:"))
    {
        return .{ .kind = kind, .target = try a.dupe(u8, url), .line = line_no, .resolution = "external" };
    }

    const split = try splitTargetFragment(a, url);
    const norm = split.path;
    const fragment = split.fragment;

    // Pure fragment (#heading) — no page target.
    if (norm.len == 0 or (norm.len == 1 and norm[0] == '#')) {
        return .{
            .kind = kind,
            .target = try a.dupe(u8, url),
            .line = line_no,
            .resolution = "review",
            .review_reason = "fragment_only",
            .fragment = fragment,
        };
    }

    // Asset-like extension (path before fragment already in norm).
    if (std.mem.indexOfScalar(u8, norm, '.')) |_| {
        const lower_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".mp4", ".webm", ".pdf", ".ico", ".css", ".js", ".woff", ".woff2" };
        for (lower_exts) |ext| {
            if (norm.len >= ext.len and std.ascii.eqlIgnoreCase(norm[norm.len - ext.len ..], ext)) {
                return .{
                    .kind = kind,
                    .target = try a.dupe(u8, url),
                    .line = line_no,
                    .resolution = "asset",
                    .review_reason = "local_or_same_origin_asset",
                    .fragment = fragment,
                };
            }
        }
    }

    var candidate_entity: ?[]const u8 = null;

    if (std.mem.startsWith(u8, norm, "/")) {
        candidate_entity = try routeToEntityCandidate(a, route_prefix, norm);
        if (candidate_entity == null) {
            return .{
                .kind = kind,
                .target = norm,
                .line = line_no,
                .resolution = "review",
                .review_reason = "absolute_route_outside_content_root_or_unmapped",
                .fragment = fragment,
            };
        }
    } else {
        // Relative path (ignore fragment — already split).
        const rel = if (std.mem.startsWith(u8, norm, "./")) norm[2..] else norm;
        if (rel.len == 0) {
            return .{
                .kind = kind,
                .target = norm,
                .line = line_no,
                .resolution = "review",
                .review_reason = "fragment_only",
                .fragment = fragment,
            };
        }
        candidate_entity = try resolveRelativeToEntity(a, entity_id, rel);
    }

    const ent = candidate_entity orelse {
        return .{
            .kind = kind,
            .target = norm,
            .line = line_no,
            .resolution = "review",
            .review_reason = "no_candidate_entity",
            .fragment = fragment,
        };
    };

    if (entities.get(ent)) |found| {
        // Fragment present: still only rewrite the page target when proven; fragment needs review.
        if (fragment != null and fragment.?.len > 0) {
            if (std.mem.eql(u8, kind, "markdown")) {
                // Rewrite page entity only; record fragment for human heading check.
                return .{
                    .kind = kind,
                    .target = norm,
                    .line = line_no,
                    .resolution = "rewritten",
                    .rewritten_to = found,
                    .review_reason = "fragment_present_heading_not_verified",
                    .fragment = fragment,
                };
            }
            return .{
                .kind = kind,
                .target = norm,
                .line = line_no,
                .resolution = "review",
                .rewritten_to = found,
                .review_reason = "attribute_link_not_auto_rewritten",
                .fragment = fragment,
            };
        }
        // Only rewrite markdown links automatically.
        if (std.mem.eql(u8, kind, "markdown")) {
            return .{
                .kind = kind,
                .target = norm,
                .line = line_no,
                .resolution = "rewritten",
                .rewritten_to = found,
                .fragment = fragment,
            };
        }
        return .{
            .kind = kind,
            .target = norm,
            .line = line_no,
            .resolution = "review",
            .rewritten_to = found,
            .review_reason = "attribute_link_not_auto_rewritten",
            .fragment = fragment,
        };
    }
    return .{
        .kind = kind,
        .target = norm,
        .line = line_no,
        .resolution = "review",
        .review_reason = "target_not_in_converted_entity_map",
        .rewritten_to = ent,
        .fragment = fragment,
    };
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFile(io: Io, root: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
    try root.writeFile(io, .{ .sub_path = path, .data = data });
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn appendUsize(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: usize) !void {
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{value}));
}

fn appendBool(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(a, if (v) "true" else "false");
}

/// Collect markdown under `rel_dir`. When `skip_locale_siblings` is true (root-locale
/// walk at the docs root), skip first-level directories that look like locale codes.
fn collectMarkdownFiles(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_dir: []const u8,
    out: *std.ArrayList([]const u8),
    skip_locale_siblings: bool,
) !void {
    var dir = try root.openDir(io, rel_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            if (skip_locale_siblings and looksLikeLocaleDirName(entry.name)) continue;
            const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            // Only skip locale siblings at the docs root level; deeper walks are normal.
            try collectMarkdownFiles(io, a, root, child, out, false);
        } else if (entry.kind == .file and isMarkdownName(entry.name)) {
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try out.append(a, path);
        }
    }
}

fn listPublicAssets(io: Io, a: std.mem.Allocator, root: Io.Dir, rel_dir: []const u8, out: *std.ArrayList(AssetEntry)) !void {
    var dir = root.openDir(io, rel_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try listPublicAssets(io, a, root, child, out);
        } else if (entry.kind == .file) {
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try out.append(a, .{ .source_path = path, .kind = "public", .exists = true });
        }
    }
}

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = try a.alloc(u8, 64);
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = charset[byte >> 4];
        hex[i * 2 + 1] = charset[byte & 0xf];
    }
    return hex;
}

fn enrichAssetsWithHashes(io: Io, a: std.mem.Allocator, root: Io.Dir, assets: *std.ArrayList(AssetEntry)) !void {
    for (assets.items) |*e| {
        const data = readFileAlloc(io, root, e.source_path, a) catch {
            e.exists = false;
            e.sha256_hex = null;
            e.bytes = 0;
            continue;
        };
        e.exists = true;
        e.bytes = data.len;
        e.sha256_hex = try sha256Hex(a, data);
    }
}

fn inventoryReferencedAssets(a: std.mem.Allocator, pages: []const SourcePage, assets: *std.ArrayList(AssetEntry)) !void {
    // Record asset-resolution link targets and failed image migrations not already inventoried.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (assets.items) |e| try seen.put(a, e.source_path, {});
    for (pages) |p| {
        for (p.link_events) |ev| {
            const is_asset_link = std.mem.eql(u8, ev.resolution, "asset");
            const is_missing_image = std.mem.eql(u8, ev.resolution, "review") and
                ev.review_reason != null and
                (std.mem.eql(u8, ev.review_reason.?, "referenced_asset_missing") or
                    std.mem.eql(u8, ev.review_reason.?, "asset_path_escapes_migration_root") or
                    std.mem.eql(u8, ev.review_reason.?, "asset_path_invalid_or_not_boris_safe"));
            if (!is_asset_link and !is_missing_image) continue;
            const key = ev.target;
            if (seen.get(key) != null) continue;
            try seen.put(a, key, {});
            // Paths starting with / may map to public/; relative may map under content.
            // We only prove existence when an earlier walk already hashed a local file.
            // Referenced-only rows are explicit review inventory without a proven hash.
            try assets.append(a, .{
                .source_path = try a.dupe(u8, key),
                .kind = "referenced",
                .referenced_from = p.source_path,
                .exists = false,
                .bytes = 0,
                .sha256_hex = null,
            });
        }
    }
}

/// Text-scan astro.config.* for sidebar evidence (never evaluate JS).
fn scanSidebarEvidence(a: std.mem.Allocator, config_src: []const u8, out: *std.ArrayList(NavDecision)) !void {
    var pos: usize = 0;
    var line_no: usize = 1;
    while (pos < config_src.len) {
        const end = std.mem.indexOfScalarPos(u8, config_src, pos, '\n') orelse config_src.len;
        const line = config_src[pos..end];
        const s = trim(line);
        if (std.mem.indexOf(u8, s, "slug:")) |_| {
            try out.append(a, .{
                .kind = "sidebar_slug",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .decision = "map_slug_to_entity_when_in_slice_else_review",
            });
        } else if (std.mem.indexOf(u8, s, "link:")) |_| {
            try out.append(a, .{
                .kind = "sidebar_link",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .decision = "external_or_unmapped_route_review_only",
            });
        } else if (std.mem.indexOf(u8, s, "autogenerate")) |_| {
            try out.append(a, .{
                .kind = "sidebar_autogenerate",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .decision = "flatten_directory_to_trunk_plus_satellites",
            });
        } else if (std.mem.indexOf(u8, s, "label:")) |_| {
            // Record every label line as nav evidence (deterministic text scan; not a graph node).
            try out.append(a, .{
                .kind = "sidebar_label",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .decision = "section_label_only_not_a_graph_node",
            });
        }
        pos = if (end < config_src.len) end + 1 else end;
        line_no += 1;
    }
    // Always record the one-level forest policy.
    try out.append(a, .{
        .kind = "boris_graph_policy",
        .evidence = "ir-schema one-level forest",
        .decision = "section_dirs_become_trunks_children_are_satellites_no_deep_nav",
    });
}

fn slashCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '/') n += 1;
    }
    return n;
}

/// Disambiguate colliding entity ids deterministically: first source path keeps
/// the base id; later sources get `-2`, `-3`, … suffixes. Collision is always
/// reported for human review (no silent overwrite).
fn disambiguateEntityIds(
    a: std.mem.Allocator,
    pages: []SourcePage,
    route_prefix: []const u8,
    collisions_out: *std.ArrayList(CollisionRecord),
) !void {
    var by_id: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (pages, 0..) |p, i| {
        const gop = try by_id.getOrPut(a, p.entity_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, i);
    }
    var it = by_id.iterator();
    while (it.next()) |entry| {
        const idxs = entry.value_ptr.items;
        if (idxs.len < 2) continue;
        std.mem.sort(usize, idxs, pages, struct {
            fn less(ps: []SourcePage, x: usize, y: usize) bool {
                return std.mem.order(u8, ps[x].source_path, ps[y].source_path) == .lt;
            }
        }.less);
        var paths: std.ArrayList([]const u8) = .empty;
        for (idxs) |idx| try paths.append(a, pages[idx].source_path);
        try collisions_out.append(a, .{
            .entity_id = entry.key_ptr.*,
            .source_paths = try paths.toOwnedSlice(a),
            .resolution = "first_wins_others_disambiguated",
        });
        var suffix: usize = 2;
        for (idxs[1..]) |idx| {
            const base = entry.key_ptr.*;
            const new_id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, suffix });
            pages[idx].entity_id = new_id;
            pages[idx].route = try routeFromEntity(a, route_prefix, new_id);
            pages[idx].output_path = try outputPathFromEntity(a, new_id);
            suffix += 1;
        }
    }
}

fn emitPage(a: std.mem.Allocator, p: SourcePage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "---\n");
    try buf.appendSlice(a, "id: ");
    try buf.appendSlice(a, p.entity_id);
    try buf.appendSlice(a, "\n");
    try buf.appendSlice(a, "title: ");
    try buf.appendSlice(a, p.title);
    try buf.appendSlice(a, "\n");
    if (p.parent) |parent| {
        try buf.appendSlice(a, "parent: ");
        try buf.appendSlice(a, parent);
        try buf.appendSlice(a, "\n");
    }
    try buf.appendSlice(a, "status: published\n");
    try buf.appendSlice(a, "tags: [starlight, migrated]\n");
    try buf.appendSlice(a, "---\n");
    try buf.appendSlice(a, "<!-- boris-migration-provenance\n");
    try buf.appendSlice(a, "  format: ");
    try buf.appendSlice(a, format_id);
    try buf.appendSlice(a, "\n  source_path: ");
    try buf.appendSlice(a, p.source_path);
    try buf.appendSlice(a, "\n  route: ");
    try buf.appendSlice(a, p.route);
    try buf.appendSlice(a, "\n  tool_version: ");
    try buf.appendSlice(a, tool_version);
    try buf.appendSlice(a, "\n-->\n");
    try buf.appendSlice(a, p.body);
    if (p.body.len == 0 or p.body[p.body.len - 1] != '\n') try buf.append(a, '\n');
    return try buf.toOwnedSlice(a);
}

fn emitSyntheticTrunk(a: std.mem.Allocator, entity_id: []const u8, title: []const u8) ![]u8 {
    return try std.fmt.allocPrint(a,
        \\---
        \\id: {s}
        \\title: {s}
        \\status: published
        \\tags: [starlight, migrated, synthetic-trunk]
        \\---
        \\
        \\# {s}
        \\
        \\Synthetic Trunk created by the Starlight migration lab to satisfy Boris's
        \\one-level forest (section pages are Satellites of this Trunk).
        \\
    , .{ entity_id, title, title });
}

fn refuseOutputInsideSource(source: []const u8, out: []const u8) !void {
    if (std.mem.eql(u8, source, out)) return error.OutputInsideSource;
    if (out.len > source.len and std.mem.startsWith(u8, out, source) and
        (out[source.len] == '/' or out[source.len] == '\\'))
        return error.OutputInsideSource;
}

fn findFileIfExists(io: Io, path: []const u8) bool {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Absolute path for a cwd-relative *file*.
fn absFileFromCwd(a: std.mem.Allocator, io: Io, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return try a.dupe(u8, rel);
    var r = rel;
    while (std.mem.startsWith(u8, r, "./")) r = r[2..];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(io, r, &buf);
    return try a.dupe(u8, buf[0..n]);
}

/// Absolute path for a cwd-relative directory by resolving a child file, then dirname.
fn absDirFromCwdViaChild(a: std.mem.Allocator, io: Io, dir_rel: []const u8, child: []const u8) ![]u8 {
    var d = dir_rel;
    while (std.mem.startsWith(u8, d, "./")) d = d[2..];
    const child_rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ d, child });
    const child_abs = try absFileFromCwd(a, io, child_rel);
    if (std.fs.path.dirname(child_abs)) |parent| return try a.dupe(u8, parent);
    return child_abs;
}

/// Locate the Boris repo root (directory that contains `layouts/main.html`).
/// Boris layout paths must be workspace-relative with no `..` or absolute form.
fn findRepoRoot(a: std.mem.Allocator, io: Io) !?[]const u8 {
    const layout_candidates = [_][]const u8{
        "layouts/main.html",
        "../layouts/main.html",
        "../../layouts/main.html",
    };
    for (layout_candidates) |c| {
        if (!findFileIfExists(io, c)) continue;
        const layout_abs = absFileFromCwd(a, io, c) catch continue;
        const layouts_dir = std.fs.path.dirname(layout_abs) orelse continue;
        const root = std.fs.path.dirname(layouts_dir) orelse continue;
        return try a.dupe(u8, root);
    }
    return null;
}

fn tryCompileWithBoris(
    io: Io,
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    opts: RunOptions,
    out_dir: []const u8,
) !struct {
    status: []const u8,
    exit_code: ?i32,
    boris_path: ?[]const u8,
    command: []const u8,
    stderr_excerpt: []const u8,
} {
    const repo_root = try findRepoRoot(a, io) orelse {
        return .{
            .status = "skipped",
            .exit_code = null,
            .boris_path = null,
            .command = "",
            .stderr_excerpt = "could not locate Boris repo root (layouts/main.html); compile skipped",
        };
    };

    // Resolve boris binary (absolute so spawn works with cwd=repo_root).
    var boris_rel: ?[]const u8 = null;
    if (opts.boris_bin) |p| {
        if (findFileIfExists(io, p)) boris_rel = p;
    }
    if (boris_rel == null) {
        const candidates = [_][]const u8{
            "zig-out/bin/boris",
            "../../zig-out/bin/boris",
            "../zig-out/bin/boris",
        };
        for (candidates) |c| {
            if (findFileIfExists(io, c)) {
                boris_rel = c;
                break;
            }
        }
    }
    // Also try repo_root/zig-out/bin/boris via absolute join probe.
    if (boris_rel == null) {
        const under_root = try std.fmt.allocPrint(a, "{s}/zig-out/bin/boris", .{repo_root});
        var probe = Io.Dir.cwd().openFile(io, under_root, .{}) catch null;
        if (probe) |*f| {
            f.close(io);
            boris_rel = under_root;
        }
    }
    if (boris_rel == null) {
        return .{
            .status = "skipped",
            .exit_code = null,
            .boris_path = null,
            .command = "",
            .stderr_excerpt = "boris binary not found; pass --boris=PATH or build the product first",
        };
    }
    const boris_path = absFileFromCwd(a, io, boris_rel.?) catch boris_rel.?;

    // Layout must stay workspace-relative (no absolute, no ..) per validateLayoutPath.
    const layout_arg = "layouts/main.html";

    // Content may be absolute (outside or inside workspace). Resolve via a known page.
    const content_rel = try std.fmt.allocPrint(a, "{s}/content", .{out_dir});
    const content_dir = absDirFromCwdViaChild(a, io, content_rel, "index.md") catch
        (absDirFromCwdViaChild(a, io, content_rel, "features.md") catch content_rel);

    // HTML output must stay inside the Boris workspace. Prefer a sibling html-proof
    // when --out is under the repo; otherwise use test-output/ (gitignored).
    const html_dir = blk: {
        const sibling = if (std.fs.path.dirname(content_dir)) |parent|
            try std.fmt.allocPrint(a, "{s}/html-proof", .{parent})
        else
            try std.fmt.allocPrint(a, "{s}/html-proof", .{out_dir});
        if (std.mem.startsWith(u8, sibling, repo_root)) break :blk sibling;
        break :blk try std.fmt.allocPrint(a, "{s}/test-output/starlight-proof-html", .{repo_root});
    };

    const argv = [_][]const u8{
        boris_path,
        "--input",
        content_dir,
        "--html-dir",
        html_dir,
        "--html-layout",
        layout_arg,
        "--quiet",
    };
    var cmd_buf: std.ArrayList(u8) = .empty;
    try cmd_buf.appendSlice(a, "(cwd=");
    try cmd_buf.appendSlice(a, repo_root);
    try cmd_buf.appendSlice(a, ") ");
    for (argv, 0..) |arg, i| {
        if (i > 0) try cmd_buf.append(a, ' ');
        try cmd_buf.appendSlice(a, arg);
    }

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = repo_root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        return .{
            .status = "error",
            .exit_code = null,
            .boris_path = boris_path,
            .command = try cmd_buf.toOwnedSlice(a),
            .stderr_excerpt = try std.fmt.allocPrint(a, "spawn failed: {s}", .{@errorName(err)}),
        };
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        .signal => |s| -@as(i32, @intCast(@intFromEnum(s))),
        .stopped => |s| -@as(i32, @intCast(@intFromEnum(s))),
        .unknown => -999,
    };
    const excerpt = if (result.stderr.len > 0)
        try a.dupe(u8, result.stderr[0..@min(result.stderr.len, 2000)])
    else
        try a.dupe(u8, result.stdout[0..@min(result.stdout.len, 500)]);

    return .{
        .status = if (code == 0) "ok" else "failed",
        .exit_code = code,
        .boris_path = boris_path,
        .command = try cmd_buf.toOwnedSlice(a),
        .stderr_excerpt = excerpt,
    };
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    try refuseOutputInsideSource(opts.source_root_dir, opts.out_dir);

    if (!std.mem.eql(u8, opts.locale, "en")) {
        return error.LocaleNotSupported;
    }
    if (opts.max_pages < 1 or opts.max_pages > 200) return error.InvalidMaxPages;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var source = try Io.Dir.cwd().openDir(io, opts.source_root_dir, .{ .iterate = true });
    defer source.close(io);

    const content = try discoverContentRoot(io, a, source, opts.locale);
    const content_root = content.rel_path;
    const route_prefix = content.route_prefix;
    const skip_locale_siblings = content.shape == .root_locale;

    // ---- Inventory: markdown under content root ----
    var md_files: std.ArrayList([]const u8) = .empty;
    try collectMarkdownFiles(io, a, source, content_root, &md_files, skip_locale_siblings);
    std.mem.sort([]const u8, md_files.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    // Deterministic candidate selection: sort order, drop underscore partials, cap max_pages.
    // No preferred-section allowlist (evcc-specific paths are not privileged).
    var selection_rows: std.ArrayList(SelectionRow) = .empty;
    var selected: std.ArrayList([]const u8) = .empty;
    const prefix = try std.fmt.allocPrint(a, "{s}/", .{content_root});
    for (md_files.items) |path| {
        const content_rel = if (std.mem.startsWith(u8, path, prefix))
            path[prefix.len..]
        else if (std.mem.eql(u8, path, content_root))
            ""
        else
            path;
        if (!isCandidatePage(content_rel)) {
            try selection_rows.append(a, .{
                .source_path = path,
                .content_rel = content_rel,
                .selected = false,
                .reason = "underscore_partial",
            });
            continue;
        }
        if (selected.items.len >= opts.max_pages) {
            try selection_rows.append(a, .{
                .source_path = path,
                .content_rel = content_rel,
                .selected = false,
                .reason = "max_pages_cap",
            });
            continue;
        }
        try selected.append(a, path);
        try selection_rows.append(a, .{
            .source_path = path,
            .content_rel = content_rel,
            .selected = true,
            .reason = "lexicographic_cap",
        });
    }

    // ---- Parse pages ----
    var pages: std.ArrayList(SourcePage) = .empty;
    var inventory: std.ArrayList(InventoryRow) = .empty;
    var section_needs_trunk: std.StringHashMapUnmanaged(void) = .empty;

    for (selected.items) |path| {
        const raw = try readFileAlloc(io, source, path, a);
        const locale_rel = if (std.mem.startsWith(u8, path, prefix)) path[prefix.len..] else path;
        const entity_id = try entityIdFromLocaleRel(a, locale_rel);
        const fallback_title = try titleFromStem(a, entity_id);
        const parsed = try parseFrontmatterLite(a, raw, fallback_title);
        const stripped = try stripUntrustedBlocks(a, parsed.body);
        const transformed = try transformStarlightMdx(a, stripped.body);
        const mdx = try sanitizeMdxBody(a, transformed.body);

        // Parent / trunk assignment (one-level forest, path-derived only).
        var parent: ?[]const u8 = null;
        var is_trunk = false;
        if (std.mem.eql(u8, entity_id, "index")) {
            is_trunk = true;
        } else if (std.mem.indexOfScalar(u8, entity_id, '/')) |slash| {
            const section = entity_id[0..slash];
            parent = try a.dupe(u8, section);
            try section_needs_trunk.put(a, section, {});
        } else {
            // Top-level page (including collapsed section index → section id) →
            // satellite of site index, unless this entity is a section trunk for children.
            // Section trunks from `section/index` collapse to entity_id without slash and
            // become trunks when children reference them; mark trunk if section dir kids exist
            // is handled by synthetic path below. Bare top-level files parent to index.
            parent = "index";
        }

        const route = try routeFromEntity(a, route_prefix, entity_id);
        const output_path = try outputPathFromEntity(a, entity_id);

        try pages.append(a, .{
            .source_path = path,
            .locale_rel = locale_rel,
            .entity_id = entity_id,
            .route = route,
            .output_path = output_path,
            .title = parsed.title,
            .parent = parent,
            .is_trunk = is_trunk,
            .raw_frontmatter = parsed.frontmatter,
            .unmapped_fields = parsed.unmapped,
            .body = mdx.body,
            .imports = mdx.imports,
            .components = mdx.components,
            .stripped_blocks = stripped.blocks,
            .link_events = mdx.asset_events,
            .component_events = transformed.events,
            .bytes = raw.len,
        });
        try inventory.append(a, .{ .source_path = path, .kind = "content_page", .bytes = raw.len });
    }

    // Synthetic trunks for sections that have children but no real trunk page.
    var existing: std.StringHashMapUnmanaged(void) = .empty;
    for (pages.items) |p| try existing.put(a, p.entity_id, {});

    // If a page entity_id equals a needed section (e.g. installation/index → installation),
    // promote it to trunk and clear parent.
    for (pages.items) |*p| {
        if (section_needs_trunk.get(p.entity_id) != null) {
            p.is_trunk = true;
            p.parent = null;
        }
    }

    var synth_keys: std.ArrayList([]const u8) = .empty;
    var sec_it = section_needs_trunk.keyIterator();
    while (sec_it.next()) |k| try synth_keys.append(a, k.*);
    std.mem.sort([]const u8, synth_keys.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    for (synth_keys.items) |section| {
        if (existing.get(section) != null) continue;
        const title = try titleFromStem(a, section);
        const route = try routeFromEntity(a, route_prefix, section);
        const output_path = try outputPathFromEntity(a, section);
        try pages.append(a, .{
            .source_path = try std.fmt.allocPrint(a, "(synthetic)/{s}", .{section}),
            .locale_rel = try std.fmt.allocPrint(a, "{s}/index.md", .{section}),
            .entity_id = section,
            .route = route,
            .output_path = output_path,
            .title = title,
            .parent = null,
            .is_trunk = true,
            .is_synthetic = true,
            .raw_frontmatter = "",
            .unmapped_fields = &.{},
            .body = try std.fmt.allocPrint(a, "# {s}\n\nSynthetic section trunk.\n", .{title}),
            .imports = &.{},
            .components = &.{},
            .stripped_blocks = &.{},
            .link_events = &.{},
            .component_events = &.{},
            .bytes = 0,
        });
        try existing.put(a, section, {});
    }

    // Ensure index trunk exists if we have top-level satellites.
    var need_index = false;
    for (pages.items) |p| {
        if (p.parent) |par| {
            if (std.mem.eql(u8, par, "index")) need_index = true;
        }
    }
    if (need_index and existing.get("index") == null) {
        try pages.append(a, .{
            .source_path = "(synthetic)/index",
            .locale_rel = "index.md",
            .entity_id = "index",
            .route = try routeFromEntity(a, route_prefix, "index"),
            .output_path = try outputPathFromEntity(a, "index"),
            .title = "Home",
            .parent = null,
            .is_trunk = true,
            .is_synthetic = true,
            .raw_frontmatter = "",
            .unmapped_fields = &.{},
            .body = "# Home\n\nSynthetic site trunk.\n",
            .imports = &.{},
            .components = &.{},
            .stripped_blocks = &.{},
            .link_events = &.{},
            .component_events = &.{},
            .bytes = 0,
        });
    }

    // Detect entity-id collisions (duplicate/ambiguous routes) before link rewrite.
    var collisions: std.ArrayList(CollisionRecord) = .empty;
    try disambiguateEntityIds(a, pages.items, route_prefix, &collisions);

    std.mem.sort(SourcePage, pages.items, {}, struct {
        fn less(_: void, x: SourcePage, y: SourcePage) bool {
            return std.mem.order(u8, x.entity_id, y.entity_id) == .lt;
        }
    }.less);

    // Entity map for link resolution.
    var entities: EntityMap = .empty;
    for (pages.items) |p| try entities.put(a, p.entity_id, p.entity_id);

    // Review-first relationship evidence from known Filed-shaped frontmatter.
    // This never mutates generated Markdown or product relation semantics.
    const relation_candidates = try collectRelationCandidates(a, pages.items, route_prefix, &entities);

    // Link rewrite pass (wiki targets only; Markdown images handled next).
    for (pages.items) |*p| {
        if (p.is_synthetic) continue;
        const rewritten = try rewriteLinks(a, route_prefix, p.entity_id, p.body, &entities);
        p.body = rewritten.body;
        var all_events: std.ArrayList(LinkEvent) = .empty;
        try all_events.appendSlice(a, p.link_events);
        try all_events.appendSlice(a, rewritten.events);
        p.link_events = try all_events.toOwnedSlice(a);
    }

    // ---- Proven local Markdown images → page `{stem}.assets/` (F-L1) ----
    var migrated: std.ArrayList(MigratedAsset) = .empty;
    for (pages.items) |*p| {
        if (p.is_synthetic) continue;
        try migratePageImages(a, io, source, content_root, p, &migrated);
    }

    // ---- Assets inventory (existence + SHA-256 when local file proven) ----
    var assets: std.ArrayList(AssetEntry) = .empty;
    try listPublicAssets(io, a, source, "public", &assets);
    try collectLocalAssets(io, a, source, content_root, &assets, skip_locale_siblings);
    try enrichAssetsWithHashes(io, a, source, &assets);
    // Migrated page assets (copied under --out).
    for (migrated.items) |m| {
        try assets.append(a, .{
            .source_path = m.source_path,
            .kind = "migrated_page_asset",
            .referenced_from = m.page_entity,
            .exists = true,
            .bytes = m.bytes,
            .sha256_hex = m.sha256_hex,
            .dest_path = m.dest_path,
            .within_tree = m.within_tree,
        });
    }
    // Referenced asset-like links/images that are missing from inventory.
    try inventoryReferencedAssets(a, pages.items, &assets);
    std.mem.sort(AssetEntry, assets.items, {}, struct {
        fn less(_: void, x: AssetEntry, y: AssetEntry) bool {
            return std.mem.order(u8, x.source_path, y.source_path) == .lt;
        }
    }.less);

    // ---- Sidebar / nav evidence ----
    var nav: std.ArrayList(NavDecision) = .empty;
    try nav.append(a, .{
        .kind = "content_root_discovery",
        .evidence = try std.fmt.allocPrint(a, "shape={s}; path={s}; route_prefix={s}", .{
            @tagName(content.shape),
            content_root,
            if (route_prefix.len == 0) "(root)" else route_prefix,
        }),
        .decision = "content_root_only_no_i18n_semantics",
    });
    try nav.append(a, .{
        .kind = "candidate_selection",
        .evidence = "lexicographic order; drop underscore partials; apply max_pages cap",
        .decision = "no_preferred_section_allowlist",
    });
    const config_names = [_][]const u8{ "astro.config.mjs", "astro.config.ts", "astro.config.js" };
    var config_found = false;
    for (config_names) |cn| {
        const cfg = readFileAlloc(io, source, cn, a) catch continue;
        config_found = true;
        try inventory.append(a, .{ .source_path = cn, .kind = "config", .bytes = cfg.len });
        try scanSidebarEvidence(a, cfg, &nav);
        break;
    }
    if (!config_found) {
        try nav.append(a, .{
            .kind = "sidebar_missing",
            .evidence = "no astro.config.* at source root",
            .decision = "parent_from_path_only",
        });
    }
    // Record flatten decisions for each section trunk.
    for (synth_keys.items) |section| {
        try nav.append(a, .{
            .kind = "section_flatten",
            .evidence = try std.fmt.allocPrint(a, "directory {s}/", .{section}),
            .decision = try std.fmt.allocPrint(a, "trunk={s}; children parent={s}", .{ section, section }),
        });
    }

    // ---- Write outputs ----
    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);

    for (pages.items) |p| {
        const text = if (p.is_synthetic and std.mem.startsWith(u8, p.source_path, "(synthetic)"))
            try emitSyntheticTrunk(a, p.entity_id, p.title)
        else
            try emitPage(a, p);
        try writeFile(io, out, p.output_path, text);
    }

    // Copy proven Markdown images into page sibling `.assets/` trees under --out.
    for (migrated.items) |m| {
        const data = try readFileAlloc(io, source, m.source_path, a);
        try writeFile(io, out, m.dest_path, data);
    }

    // Boundary classification (preserved / stripped / manual_review).
    const boundary = try buildBoundaryItems(a, pages.items, selection_rows.items, assets.items, collisions.items);

    // Sidecar manifests
    try writeRouteMap(a, io, out, pages.items);
    try writeUnsupported(a, io, out, pages.items, collisions.items);
    try writeAssetsManifest(a, io, out, assets.items);
    try writeNavManifest(a, io, out, nav.items);
    try writeProvenance(a, io, out, opts, content, pages.items);
    try writeLinkReview(a, io, out, pages.items);
    try writeRelationCandidates(a, io, out, relation_candidates);
    try writeHeadingFragments(a, io, out, pages.items);
    try writeSelectionManifest(a, io, out, content, selection_rows.items, opts.max_pages);
    try writeBoundaryManifest(a, io, out, boundary.items);
    try writeReports(a, io, out, opts, content, pages.items, inventory.items, assets.items, nav.items, selection_rows.items, boundary.items, collisions.items);

    // Compile proof
    const compile = try tryCompileWithBoris(io, gpa, a, opts, opts.out_dir);
    try writeCompileReport(a, io, out, compile);

    if (!opts.quiet) {
        std.debug.print(
            "starlight-migration-lab: shape={s} wrote {s}/content/ ({d} pages), manifests, reports; compile={s}\n",
            .{ @tagName(content.shape), opts.out_dir, pages.items.len, compile.status },
        );
    }
}

fn buildBoundaryItems(
    a: std.mem.Allocator,
    pages: []const SourcePage,
    selection: []const SelectionRow,
    assets: []const AssetEntry,
    collisions: []const CollisionRecord,
) !std.ArrayList(BoundaryItem) {
    var items: std.ArrayList(BoundaryItem) = .empty;

    // Selection exclusions → manual review (not converted).
    for (selection) |r| {
        if (r.selected) continue;
        try items.append(a, .{
            .class = "manual_review",
            .source_path = r.source_path,
            .detail = try std.fmt.allocPrint(a, "not_selected:{s}", .{r.reason}),
            .category = r.reason,
        });
    }

    for (pages) |p| {
        if (p.is_synthetic) {
            try items.append(a, .{
                .class = "manual_review",
                .source_path = p.source_path,
                .detail = try std.fmt.allocPrint(a, "synthetic_trunk entity={s}", .{p.entity_id}),
                .category = "synthetic_trunk",
            });
            continue;
        }

        // Preserved: converted body retained under closed Boris frontmatter.
        try items.append(a, .{
            .class = "preserved",
            .source_path = p.source_path,
            .detail = try std.fmt.allocPrint(a, "body_retained entity={s} output={s}", .{ p.entity_id, p.output_path }),
            .category = "converted_page",
        });

        for (p.stripped_blocks) |b| {
            try items.append(a, .{
                .class = "stripped",
                .source_path = p.source_path,
                .detail = "untrusted_embedded_block_payload_not_replayed",
                .line = b.line,
                .category = b.category,
            });
        }

        for (p.unmapped_fields) |f| {
            try items.append(a, .{
                .class = "manual_review",
                .source_path = p.source_path,
                .detail = try std.fmt.allocPrint(a, "unmapped_frontmatter:{s}", .{f}),
                .category = "unsupported_frontmatter",
            });
        }
        for (p.component_events) |ev| {
            const is_review = std.mem.eql(u8, ev.resolution, "review");
            try items.append(a, .{
                .class = if (is_review) "manual_review" else "preserved",
                .source_path = p.source_path,
                .detail = try std.fmt.allocPrint(a, "component {s} -> mapping_confidence={s}: {s}", .{ ev.target, ev.review_reason orelse "", ev.rewritten_to orelse "" }),
                .line = ev.line,
                .category = "component_mapping",
            });
        }
        if (p.imports.len > 0 or p.components.len > 0) {
            try items.append(a, .{
                .class = "manual_review",
                .source_path = p.source_path,
                .detail = try std.fmt.allocPrint(a, "mdx imports={d} components={d} (not executed)", .{ p.imports.len, p.components.len }),
                .category = "unsupported_mdx",
            });
        }
        if (slashCount(p.entity_id) > 1) {
            try items.append(a, .{
                .class = "manual_review",
                .source_path = p.source_path,
                .detail = try std.fmt.allocPrint(a, "deep_path_flattened entity={s} parent={s}", .{ p.entity_id, p.parent orelse "(trunk)" }),
                .category = "deep_path",
            });
        }
        for (p.link_events) |ev| {
            if (std.mem.eql(u8, ev.resolution, "review")) {
                if (ev.review_reason != null and std.mem.eql(u8, ev.review_reason.?, "dynamic_asset_expression")) {
                    try items.append(a, .{
                        .class = "manual_review",
                        .source_path = p.source_path,
                        .detail = try std.fmt.allocPrint(a, "dynamic_asset_expression:{s}", .{ev.target}),
                        .line = ev.line,
                        .category = "dynamic_asset",
                    });
                    continue;
                }
                try items.append(a, .{
                    .class = "manual_review",
                    .source_path = p.source_path,
                    .detail = try std.fmt.allocPrint(a, "link:{s}", .{ev.review_reason orelse "review"}),
                    .line = ev.line,
                    .category = "link_review",
                });
            } else if (std.mem.eql(u8, ev.resolution, "rewritten") and ev.review_reason != null) {
                // Fragment present but heading not verified.
                try items.append(a, .{
                    .class = "manual_review",
                    .source_path = p.source_path,
                    .detail = try std.fmt.allocPrint(a, "fragment:{s}", .{ev.fragment orelse ""}),
                    .line = ev.line,
                    .category = "heading_fragment",
                });
            } else if (std.mem.eql(u8, ev.resolution, "asset")) {
                try items.append(a, .{
                    .class = "manual_review",
                    .source_path = p.source_path,
                    .detail = try std.fmt.allocPrint(a, "asset_not_auto_copied:{s}", .{ev.target}),
                    .line = ev.line,
                    .category = "asset_inventory_only",
                });
            } else if (std.mem.eql(u8, ev.resolution, "rewritten")) {
                if (ev.review_reason) |rr| {
                    if (std.mem.eql(u8, rr, "image_migrated_to_page_assets")) {
                        try items.append(a, .{
                            .class = "preserved",
                            .source_path = p.source_path,
                            .detail = try std.fmt.allocPrint(a, "image_migrated:{s}->{s}", .{ ev.target, ev.rewritten_to orelse "" }),
                            .line = ev.line,
                            .category = "migrated_page_asset",
                        });
                    }
                }
            }
        }
    }

    for (collisions) |c| {
        for (c.source_paths) |sp| {
            try items.append(a, .{
                .class = "manual_review",
                .source_path = sp,
                .detail = try std.fmt.allocPrint(a, "entity_collision base={s} resolution={s}", .{ c.entity_id, c.resolution }),
                .category = "ambiguous_route",
            });
        }
    }

    for (assets) |e| {
        if (!e.exists) {
            try items.append(a, .{
                .class = "manual_review",
                .source_path = e.source_path,
                .detail = "referenced_asset_missing",
                .category = "missing_asset",
            });
        } else if (std.mem.eql(u8, e.kind, "migrated_page_asset")) {
            try items.append(a, .{
                .class = "preserved",
                .source_path = e.source_path,
                .detail = try std.fmt.allocPrint(a, "migrated_page_asset dest={s} within={s}", .{
                    e.dest_path orelse "",
                    e.within_tree orelse "",
                }),
                .category = "migrated_page_asset",
            });
        } else if (e.sha256_hex != null) {
            try items.append(a, .{
                .class = "preserved",
                .source_path = e.source_path,
                .detail = try std.fmt.allocPrint(a, "asset_inventoried kind={s} sha256_proven (inventory; page images may also migrate)", .{e.kind}),
                .category = "asset_inventory",
            });
        }
    }

    // Deterministic order: class, source_path, detail.
    std.mem.sort(BoundaryItem, items.items, {}, struct {
        fn less(_: void, x: BoundaryItem, y: BoundaryItem) bool {
            const c = std.mem.order(u8, x.class, y.class);
            if (c != .eq) return c == .lt;
            const s = std.mem.order(u8, x.source_path, y.source_path);
            if (s != .eq) return s == .lt;
            return std.mem.order(u8, x.detail, y.detail) == .lt;
        }
    }.less);
    return items;
}

fn collectLocalAssets(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_dir: []const u8,
    out: *std.ArrayList(AssetEntry),
    skip_locale_siblings: bool,
) !void {
    var dir = root.openDir(io, rel_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            if (skip_locale_siblings and looksLikeLocaleDirName(entry.name)) continue;
            const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try collectLocalAssets(io, a, root, child, out, false);
        } else if (entry.kind == .file) {
            if (isMarkdownName(entry.name)) continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try out.append(a, .{ .source_path = path, .kind = "content_local", .exists = true });
        }
    }
}

fn writeRouteMap(a: std.mem.Allocator, io: Io, out: Io.Dir, pages: []const SourcePage) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-route-map\",\n  \"schema_version\": 1,\n  \"routes\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"route\": ");
        try appendJson(&buf, a, p.route);
        try buf.appendSlice(a, ", \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"output_path\": ");
        try appendJson(&buf, a, p.output_path);
        try buf.appendSlice(a, ", \"parent\": ");
        if (p.parent) |par| try appendJson(&buf, a, par) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"is_trunk\": ");
        try appendBool(&buf, a, p.is_trunk);
        try buf.appendSlice(a, ", \"synthetic\": ");
        try appendBool(&buf, a, p.is_synthetic);
        try buf.appendSlice(a, " }");
        if (i + 1 < pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "route_map.json", buf.items);
}

fn writeUnsupported(
    a: std.mem.Allocator,
    io: Io,
    out: Io.Dir,
    pages: []const SourcePage,
    collisions: []const CollisionRecord,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-unsupported\",\n  \"schema_version\": 1,\n  \"frontmatter\": [\n");
    var first = true;
    for (pages) |p| {
        if (p.unmapped_fields.len == 0) continue;
        if (!first) try buf.appendSlice(a, ",\n");
        first = false;
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"fields\": [");
        for (p.unmapped_fields, 0..) |f, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try appendJson(&buf, a, f);
        }
        try buf.appendSlice(a, "] }");
    }
    try buf.appendSlice(a, "\n  ],\n  \"mdx\": [\n");
    first = true;
    for (pages) |p| {
        if (p.imports.len == 0 and p.components.len == 0) continue;
        if (!first) try buf.appendSlice(a, ",\n");
        first = false;
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"imports\": [");
        for (p.imports, 0..) |im, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try appendJson(&buf, a, im);
        }
        try buf.appendSlice(a, "], \"components\": [");
        for (p.components, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(a, ", ");
            try appendJson(&buf, a, c);
        }
        try buf.appendSlice(a, "] }");
    }
    try buf.appendSlice(a, "\n  ],\n  \"entity_collisions\": [\n");
    for (collisions, 0..) |c, i| {
        try buf.appendSlice(a, "    { \"entity_id\": ");
        try appendJson(&buf, a, c.entity_id);
        try buf.appendSlice(a, ", \"resolution\": ");
        try appendJson(&buf, a, c.resolution);
        try buf.appendSlice(a, ", \"source_paths\": [");
        for (c.source_paths, 0..) |sp, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try appendJson(&buf, a, sp);
        }
        try buf.appendSlice(a, "] }");
        if (i + 1 < collisions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "unsupported_manifest.json", buf.items);
}

fn writeHeadingFragments(a: std.mem.Allocator, io: Io, out: Io.Dir, pages: []const SourcePage) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-heading-fragments\",\n  \"schema_version\": 1,\n  \"policy\": \"Fragments are inventoried only. Heading ids are not verified against Apex or source headings. Page targets may still be wiki-rewritten when proven.\",\n  \"fragments\": [\n");
    var first = true;
    for (pages) |p| {
        for (p.link_events) |ev| {
            if (ev.fragment == null) continue;
            if (!first) try buf.appendSlice(a, ",\n");
            first = false;
            try buf.appendSlice(a, "    { \"source_path\": ");
            try appendJson(&buf, a, p.source_path);
            try buf.appendSlice(a, ", \"line\": ");
            try appendUsize(&buf, a, ev.line);
            try buf.appendSlice(a, ", \"target\": ");
            try appendJson(&buf, a, ev.target);
            try buf.appendSlice(a, ", \"fragment\": ");
            try appendJson(&buf, a, ev.fragment.?);
            try buf.appendSlice(a, ", \"resolution\": ");
            try appendJson(&buf, a, ev.resolution);
            try buf.appendSlice(a, ", \"rewritten_to\": ");
            if (ev.rewritten_to) |r| try appendJson(&buf, a, r) else try buf.appendSlice(a, "null");
            try buf.appendSlice(a, ", \"review_reason\": ");
            if (ev.review_reason) |r| try appendJson(&buf, a, r) else try buf.appendSlice(a, "null");
            try buf.appendSlice(a, " }");
        }
    }
    try buf.appendSlice(a, "\n  ]\n}\n");
    try writeFile(io, out, "heading_fragments.json", buf.items);
}

fn writeBoundaryManifest(a: std.mem.Allocator, io: Io, out: Io.Dir, items: []const BoundaryItem) !void {
    var preserved_n: usize = 0;
    var stripped_n: usize = 0;
    var review_n: usize = 0;
    for (items) |it| {
        if (std.mem.eql(u8, it.class, "preserved")) preserved_n += 1;
        if (std.mem.eql(u8, it.class, "stripped")) stripped_n += 1;
        if (std.mem.eql(u8, it.class, "manual_review")) review_n += 1;
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-boundary\",\n  \"schema_version\": 1,\n  \"policy\": \"Mechanical classification only. preserved = body/asset retained without invented semantics; stripped = untrusted instruction/directive/agent/prompt fences removed without payload replay; manual_review = human migration work still required. Not a universal converter.\",\n  \"counts\": {\n    \"preserved\": ");
    try appendUsize(&buf, a, preserved_n);
    try buf.appendSlice(a, ",\n    \"stripped\": ");
    try appendUsize(&buf, a, stripped_n);
    try buf.appendSlice(a, ",\n    \"manual_review\": ");
    try appendUsize(&buf, a, review_n);
    try buf.appendSlice(a, "\n  },\n  \"items\": [\n");
    for (items, 0..) |it, i| {
        try buf.appendSlice(a, "    { \"class\": ");
        try appendJson(&buf, a, it.class);
        try buf.appendSlice(a, ", \"source_path\": ");
        try appendJson(&buf, a, it.source_path);
        try buf.appendSlice(a, ", \"detail\": ");
        try appendJson(&buf, a, it.detail);
        try buf.appendSlice(a, ", \"line\": ");
        if (it.line) |ln| try appendUsize(&buf, a, ln) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"category\": ");
        if (it.category) |c| try appendJson(&buf, a, c) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, " }");
        if (i + 1 < items.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "boundary_manifest.json", buf.items);
}

fn writeAssetsManifest(a: std.mem.Allocator, io: Io, out: Io.Dir, assets: []const AssetEntry) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-assets\",\n  \"schema_version\": 1,\n  \"policy\": \"Public/content inventory plus proven Markdown images migrated into page {stem}.assets/ under --out. SHA-256 present when a local source file was opened and hashed. Missing/escape/invalid image refs are review-only (never invented). Query strings on image URLs are dropped; fragments are preserved when present.\",\n  \"assets\": [\n");
    for (assets, 0..) |e, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, e.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try appendJson(&buf, a, e.kind);
        try buf.appendSlice(a, ", \"exists\": ");
        try appendBool(&buf, a, e.exists);
        try buf.appendSlice(a, ", \"bytes\": ");
        try appendUsize(&buf, a, e.bytes);
        try buf.appendSlice(a, ", \"sha256\": ");
        if (e.sha256_hex) |h| try appendJson(&buf, a, h) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"referenced_from\": ");
        if (e.referenced_from) |r| try appendJson(&buf, a, r) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"dest_path\": ");
        if (e.dest_path) |d| try appendJson(&buf, a, d) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"within_tree\": ");
        if (e.within_tree) |w| try appendJson(&buf, a, w) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, " }");
        if (i + 1 < assets.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "assets_manifest.json", buf.items);
}

fn writeNavManifest(a: std.mem.Allocator, io: Io, out: Io.Dir, nav: []const NavDecision) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-nav-flatten\",\n  \"schema_version\": 1,\n  \"decisions\": [\n");
    for (nav, 0..) |d, i| {
        try buf.appendSlice(a, "    { \"kind\": ");
        try appendJson(&buf, a, d.kind);
        try buf.appendSlice(a, ", \"evidence\": ");
        try appendJson(&buf, a, d.evidence);
        try buf.appendSlice(a, ", \"decision\": ");
        try appendJson(&buf, a, d.decision);
        try buf.appendSlice(a, " }");
        if (i + 1 < nav.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "nav_flatten.json", buf.items);
}

fn writeProvenance(a: std.mem.Allocator, io: Io, out: Io.Dir, opts: RunOptions, content: ContentRoot, pages: []const SourcePage) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-provenance\",\n  \"schema_version\": 1,\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, opts.source_root_dir);
    try buf.appendSlice(a, ",\n  \"locale\": ");
    try appendJson(&buf, a, opts.locale);
    try buf.appendSlice(a, ",\n  \"content_shape\": ");
    try appendJson(&buf, a, @tagName(content.shape));
    try buf.appendSlice(a, ",\n  \"content_root\": ");
    try appendJson(&buf, a, content.rel_path);
    try buf.appendSlice(a, ",\n  \"route_prefix\": ");
    try appendJson(&buf, a, content.route_prefix);
    try buf.appendSlice(a, ",\n  \"source_site\": \"Starlight-compatible tree (withastro/starlight docs or locale-dir sites)\",\n  \"license_note\": \"Clone upstream to /tmp only; never commit upstream content into Boris.\",\n  \"records\": [\n");
    for (pages, 0..) |p, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, p.source_path);
        try buf.appendSlice(a, ", \"output_path\": ");
        try appendJson(&buf, a, p.output_path);
        try buf.appendSlice(a, ", \"entity_id\": ");
        try appendJson(&buf, a, p.entity_id);
        try buf.appendSlice(a, ", \"raw_frontmatter\": ");
        try appendJson(&buf, a, p.raw_frontmatter);
        try buf.appendSlice(a, ", \"synthetic\": ");
        try appendBool(&buf, a, p.is_synthetic);
        try buf.appendSlice(a, " }");
        if (i + 1 < pages.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "provenance_manifest.json", buf.items);
}

fn writeLinkReview(a: std.mem.Allocator, io: Io, out: Io.Dir, pages: []const SourcePage) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-link-review\",\n  \"schema_version\": 1,\n  \"policy\": \"Rewrite markdown route/relative links to wiki only when the target entity exists in the converted entity map. Attribute links, unresolved routes, fragments, assets, and external URLs get explicit review/inventory rows.\",\n  \"links\": [\n");
    var first = true;
    for (pages) |p| {
        for (p.link_events) |ev| {
            if (!first) try buf.appendSlice(a, ",\n");
            first = false;
            try buf.appendSlice(a, "    { \"source_path\": ");
            try appendJson(&buf, a, p.source_path);
            try buf.appendSlice(a, ", \"line\": ");
            try appendUsize(&buf, a, ev.line);
            try buf.appendSlice(a, ", \"kind\": ");
            try appendJson(&buf, a, ev.kind);
            try buf.appendSlice(a, ", \"target\": ");
            try appendJson(&buf, a, ev.target);
            try buf.appendSlice(a, ", \"resolution\": ");
            try appendJson(&buf, a, ev.resolution);
            try buf.appendSlice(a, ", \"rewritten_to\": ");
            if (ev.rewritten_to) |r| try appendJson(&buf, a, r) else try buf.appendSlice(a, "null");
            try buf.appendSlice(a, ", \"review_reason\": ");
            if (ev.review_reason) |r| try appendJson(&buf, a, r) else try buf.appendSlice(a, "null");
            try buf.appendSlice(a, ", \"fragment\": ");
            if (ev.fragment) |f| try appendJson(&buf, a, f) else try buf.appendSlice(a, "null");
            try buf.appendSlice(a, " }");
        }
    }
    try buf.appendSlice(a, "\n  ]\n}\n");
    try writeFile(io, out, "link_review.json", buf.items);
}

fn writeRelationCandidates(
    a: std.mem.Allocator,
    io: Io,
    out: Io.Dir,
    candidates: []const RelationCandidate,
) !void {
    var resolved_n: usize = 0;
    var unresolved_n: usize = 0;
    var ambiguous_n: usize = 0;
    var review_only_n: usize = 0;
    var over_limit_n: usize = 0;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.target_resolution, "resolved")) resolved_n += 1;
        if (std.mem.eql(u8, candidate.target_resolution, "unresolved")) unresolved_n += 1;
        if (std.mem.eql(u8, candidate.target_resolution, "ambiguous")) ambiguous_n += 1;
        if (candidate.proposed_kind == null) review_only_n += 1;
        if (candidate.within_product_limit != null and !candidate.within_product_limit.?) over_limit_n += 1;
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-relation-candidates\",\n" ++
        "  \"schema_version\": 1,\n" ++
        "  \"policy\": \"Review-first evidence only. Known Filed-shaped fields are inventoried without changing generated Markdown. relates_to is proposed only for safely normalized targets resolved in the converted entity map; no product relation is emitted. concepts and escalationPath never receive an invented kind.\",\n" ++
        "  \"product_relation_limit\": ");
    try appendUsize(&buf, a, product_relation_limit);
    try buf.appendSlice(a, ",\n  \"counts\": { \"total\": ");
    try appendUsize(&buf, a, candidates.len);
    try buf.appendSlice(a, ", \"resolved\": ");
    try appendUsize(&buf, a, resolved_n);
    try buf.appendSlice(a, ", \"unresolved\": ");
    try appendUsize(&buf, a, unresolved_n);
    try buf.appendSlice(a, ", \"ambiguous\": ");
    try appendUsize(&buf, a, ambiguous_n);
    try buf.appendSlice(a, ", \"review_only\": ");
    try appendUsize(&buf, a, review_only_n);
    try buf.appendSlice(a, ", \"over_limit\": ");
    try appendUsize(&buf, a, over_limit_n);
    try buf.appendSlice(a, " },\n  \"candidates\": [\n");
    for (candidates, 0..) |candidate, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, candidate.source_path);
        try buf.appendSlice(a, ", \"output_path\": ");
        try appendJson(&buf, a, candidate.output_path);
        try buf.appendSlice(a, ", \"source_entity\": ");
        try appendJson(&buf, a, candidate.source_entity);
        try buf.appendSlice(a, ", \"source_field\": ");
        try appendJson(&buf, a, candidate.source_field);
        try buf.appendSlice(a, ", \"source_line\": ");
        try appendUsize(&buf, a, @intCast(candidate.source_line));
        try buf.appendSlice(a, ", \"value_index\": ");
        try appendUsize(&buf, a, candidate.value_index);
        try buf.appendSlice(a, ", \"raw_value\": ");
        try appendJson(&buf, a, candidate.raw_value);
        try buf.appendSlice(a, ", \"normalized_target\": ");
        if (candidate.normalized_target) |value| try appendJson(&buf, a, value) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"proposed_kind\": ");
        if (candidate.proposed_kind) |value| try appendJson(&buf, a, value) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"target_resolution\": ");
        try appendJson(&buf, a, candidate.target_resolution);
        try buf.appendSlice(a, ", \"resolved_entity\": ");
        if (candidate.resolved_entity) |value| try appendJson(&buf, a, value) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"relation_ordinal\": ");
        if (candidate.relation_ordinal) |value| try appendUsize(&buf, a, value) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"within_product_limit\": ");
        if (candidate.within_product_limit) |value| try appendBool(&buf, a, value) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"review_reason\": ");
        if (candidate.review_reason) |value| try appendJson(&buf, a, value) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, " }");
        if (i + 1 < candidates.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "relation_candidates.json", buf.items);
}

fn writeSelectionManifest(
    a: std.mem.Allocator,
    io: Io,
    out: Io.Dir,
    content: ContentRoot,
    rows: []const SelectionRow,
    max_pages: usize,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-selection\",\n  \"schema_version\": 1,\n  \"policy\": \"Deterministic lexicographic order; exclude underscore partials; apply max_pages. No preferred-section allowlist.\",\n  \"content_shape\": ");
    try appendJson(&buf, a, @tagName(content.shape));
    try buf.appendSlice(a, ",\n  \"content_root\": ");
    try appendJson(&buf, a, content.rel_path);
    try buf.appendSlice(a, ",\n  \"max_pages\": ");
    try appendUsize(&buf, a, max_pages);
    try buf.appendSlice(a, ",\n  \"candidates\": [\n");
    for (rows, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"content_rel\": ");
        try appendJson(&buf, a, r.content_rel);
        try buf.appendSlice(a, ", \"selected\": ");
        try appendBool(&buf, a, r.selected);
        try buf.appendSlice(a, ", \"reason\": ");
        try appendJson(&buf, a, r.reason);
        try buf.appendSlice(a, " }");
        if (i + 1 < rows.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "selection_manifest.json", buf.items);
}

fn writeCompileReport(
    a: std.mem.Allocator,
    io: Io,
    out: Io.Dir,
    compile: anytype,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-compile-report\",\n  \"schema_version\": 1,\n  \"status\": ");
    try appendJson(&buf, a, compile.status);
    try buf.appendSlice(a, ",\n  \"exit_code\": ");
    if (compile.exit_code) |c| {
        var tmp: [16]u8 = undefined;
        try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{c}));
    } else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ",\n  \"boris_path\": ");
    if (compile.boris_path) |p| try appendJson(&buf, a, p) else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ",\n  \"command\": ");
    try appendJson(&buf, a, compile.command);
    try buf.appendSlice(a, ",\n  \"stderr_excerpt\": ");
    try appendJson(&buf, a, compile.stderr_excerpt);
    try buf.appendSlice(a, "\n}\n");
    try writeFile(io, out, "compile_report.json", buf.items);
}

fn writeReports(
    a: std.mem.Allocator,
    io: Io,
    out: Io.Dir,
    opts: RunOptions,
    content: ContentRoot,
    pages: []const SourcePage,
    inventory: []const InventoryRow,
    assets: []const AssetEntry,
    nav: []const NavDecision,
    selection: []const SelectionRow,
    boundary: []const BoundaryItem,
    collisions: []const CollisionRecord,
) !void {
    var selected_n: usize = 0;
    for (selection) |r| {
        if (r.selected) selected_n += 1;
    }
    var preserved_n: usize = 0;
    var stripped_n: usize = 0;
    var review_n: usize = 0;
    for (boundary) |it| {
        if (std.mem.eql(u8, it.class, "preserved")) preserved_n += 1;
        if (std.mem.eql(u8, it.class, "stripped")) stripped_n += 1;
        if (std.mem.eql(u8, it.class, "manual_review")) review_n += 1;
    }

    // report.json
    var report: std.ArrayList(u8) = .empty;
    try report.appendSlice(a, "{\n  \"format\": \"");
    try report.appendSlice(a, format_id);
    try report.appendSlice(a, "\",\n  \"schema_version\": ");
    try appendUsize(&report, a, schema_version);
    try report.appendSlice(a, ",\n  \"tool_version\": ");
    try appendJson(&report, a, tool_version);
    try report.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&report, a, opts.source_root_dir);
    try report.appendSlice(a, ",\n  \"locale\": ");
    try appendJson(&report, a, opts.locale);
    try report.appendSlice(a, ",\n  \"content_shape\": ");
    try appendJson(&report, a, @tagName(content.shape));
    try report.appendSlice(a, ",\n  \"content_root\": ");
    try appendJson(&report, a, content.rel_path);
    try report.appendSlice(a, ",\n  \"route_prefix\": ");
    try appendJson(&report, a, content.route_prefix);
    try report.appendSlice(a, ",\n  \"selection_policy\": \"lexicographic; drop underscore partials; max_pages cap; no preferred sections\",\n");
    try report.appendSlice(a, "  \"max_pages\": ");
    try appendUsize(&report, a, opts.max_pages);
    try report.appendSlice(a, ",\n  \"selected_candidates\": ");
    try appendUsize(&report, a, selected_n);
    try report.appendSlice(a, ",\n  \"converted_pages\": ");
    try appendUsize(&report, a, pages.len);
    try report.appendSlice(a, ",\n  \"entity_collisions\": ");
    try appendUsize(&report, a, collisions.len);
    try report.appendSlice(a, ",\n  \"boundary_counts\": {\n    \"preserved\": ");
    try appendUsize(&report, a, preserved_n);
    try report.appendSlice(a, ",\n    \"stripped\": ");
    try appendUsize(&report, a, stripped_n);
    try report.appendSlice(a, ",\n    \"manual_review\": ");
    try appendUsize(&report, a, review_n);
    try report.appendSlice(a, "\n  },\n  \"supported_frontmatter\": [\"id\", \"title\", \"parent\", \"status\", \"tags\"],\n");
    try report.appendSlice(a, "  \"unsupported_summary\": {\n");
    try report.appendSlice(a, "    \"full_yaml\": false,\n");
    try report.appendSlice(a, "    \"mdx_components\": false,\n");
    try report.appendSlice(a, "    \"starlight_runtime\": false,\n");
    try report.appendSlice(a, "    \"locale_semantics\": false,\n");
    try report.appendSlice(a, "    \"translation_linking\": false,\n");
    try report.appendSlice(a, "    \"content_asset_copy\": \"proven_markdown_images_to_page_assets_only\",\n");
    try report.appendSlice(a, "    \"live_sync\": false,\n");
    try report.appendSlice(a, "    \"deep_nav\": false,\n");
    try report.appendSlice(a, "    \"universal_converter\": false\n");
    try report.appendSlice(a, "  },\n  \"inventory_count\": ");
    try appendUsize(&report, a, inventory.len);
    try report.appendSlice(a, ",\n  \"asset_count\": ");
    try appendUsize(&report, a, assets.len);
    try report.appendSlice(a, ",\n  \"nav_decisions\": ");
    try appendUsize(&report, a, nav.len);
    try report.appendSlice(a, ",\n  \"pages\": [\n");
    for (pages, 0..) |p, i| {
        try report.appendSlice(a, "    { \"id\": ");
        try appendJson(&report, a, p.entity_id);
        try report.appendSlice(a, ", \"source_path\": ");
        try appendJson(&report, a, p.source_path);
        try report.appendSlice(a, ", \"route\": ");
        try appendJson(&report, a, p.route);
        try report.appendSlice(a, ", \"title\": ");
        try appendJson(&report, a, p.title);
        try report.appendSlice(a, ", \"trunk\": ");
        try appendBool(&report, a, p.is_trunk);
        try report.appendSlice(a, ", \"synthetic\": ");
        try appendBool(&report, a, p.is_synthetic);
        try report.appendSlice(a, " }");
        if (i + 1 < pages.len) try report.append(a, ',');
        try report.append(a, '\n');
    }
    try report.appendSlice(a, "  ]\n}\n");
    try writeFile(io, out, "report.json", report.items);

    // REPORT.md
    var md: std.ArrayList(u8) = .empty;
    try md.appendSlice(a, "# Starlight → Boris migration report\n\n");
    try md.appendSlice(a, "Developer-only **read-only dogfood** for a Starlight content tree (content-root discovery only; no i18n; not a universal converter).\n\n");
    try md.appendSlice(a, "| | |\n|--|--|\n| Format | `");
    try md.appendSlice(a, format_id);
    try md.appendSlice(a, "` |\n| Tool version | `");
    try md.appendSlice(a, tool_version);
    try md.appendSlice(a, "` |\n| Content shape | `");
    try md.appendSlice(a, @tagName(content.shape));
    try md.appendSlice(a, "` |\n| Content root | `");
    try md.appendSlice(a, content.rel_path);
    try md.appendSlice(a, "` |\n| Route prefix | `");
    try md.appendSlice(a, if (content.route_prefix.len == 0) "(root)" else content.route_prefix);
    try md.appendSlice(a, "` |\n| Locale key | `");
    try md.appendSlice(a, opts.locale);
    try md.appendSlice(a, "` |\n| Converted pages | ");
    try appendUsize(&md, a, pages.len);
    try md.appendSlice(a, " |\n| Entity collisions | ");
    try appendUsize(&md, a, collisions.len);
    try md.appendSlice(a, " |\n| Boundary preserved / stripped / manual_review | ");
    try appendUsize(&md, a, preserved_n);
    try md.appendSlice(a, " / ");
    try appendUsize(&md, a, stripped_n);
    try md.appendSlice(a, " / ");
    try appendUsize(&md, a, review_n);
    try md.appendSlice(a, " |\n| Source | `");
    try md.appendSlice(a, opts.source_root_dir);
    try md.appendSlice(a, "` (read-only) |\n\n");

    try md.appendSlice(a, "## Boundary summary\n\n");
    try md.appendSlice(a,
        \\| Class | Meaning |
        \\|-------|---------|
        \\| **preserved** | Body text retained; proven local Markdown images migrated into page `{stem}.assets/` |
        \\| **stripped** | Untrusted agent/directive/instruction/prompt fences removed; payload never replayed |
        \\| **manual_review** | Human migration work still required (MDX, FM, links, fragments, collisions, missing/escape assets, …) |
        \\
        \\
    );

    try md.appendSlice(a, "## Supported / unsupported matrix\n\n");
    try md.appendSlice(a,
        \\| Area | Status | Notes |
        \\|------|--------|-------|
        \\| Content root `docs/{locale}/` | **Supported** | Locale-directory shape |
        \\| Content root `docs/` (default locale) | **Supported** | Root-locale shape; sibling locale dirs skipped |
        \\| Frontmatter `title` | **Supported** | Mapped into Boris `title` |
        \\| Frontmatter `id` / `parent` / `status` / `tags` | **Emitted** | Converter-owned; source values listed as unmapped when present |
        \\| Other YAML keys (`sidebar`, `draft`, nested maps, …) | **Unsupported** | Retained in provenance; never interpreted |
        \\| Full YAML / JS config evaluation | **Unsupported** | `astro.config.*` text-scanned only |
        \\| Markdown body | **Supported** | Passed through after MDX import strip |
        \\| MDX imports / components | **Unsupported** | Inventoried; tags neutralized; not executed |
        \\| Internal markdown route/relative links | **Conditional** | Rewritten to `[[entity]]` only when target is in entity map |
        \\| Fragments (`#heading`) | **Review** | Explicit fragment inventory; heading not verified |
        \\| Attribute `href`/`to` routes | **Review** | Never auto-rewritten |
        \\| External links | **Left as-is** | Inventoried as external |
        \\| Local / public Markdown images | **Conditional** | Proven relative/public images → page `{stem}.assets/` + rewrite; missing/escape → review (never invented) |
        \\| Duplicate / ambiguous entity ids | **Disambiguated** | First source path wins; others get `-2`…; all reviewed |
        \\| Sidebar / autogenerate | **Flattened** | One-level forest: section Trunk + Satellite children |
        \\| Translation linking / i18n | **Unsupported** | Content-root discovery only |
        \\| Live sync / Node runtime | **Unsupported** | |
        \\| Deep multi-hop parents | **Unsupported** | Boris one-level forest |
        \\| Universal conversion | **Not claimed** | Mechanical inventory + proven rewrites only |
        \\
        \\
    );

    try md.appendSlice(a, "## Sidecar manifests\n\n");
    try md.appendSlice(a,
        \\- `route_map.json` — source path → route → entity id → output
        \\- `selection_manifest.json` — deterministic candidate selection rows
        \\- `unsupported_manifest.json` — unmapped frontmatter + MDX + entity collisions
        \\- `assets_manifest.json` — public + content-local inventory + migrated page assets
        \\- `nav_flatten.json` — discovery + sidebar evidence + flatten decisions
        \\- `provenance_manifest.json` — raw frontmatter + source provenance
        \\- `link_review.json` — every link event (rewritten / review / external / asset)
        \\- `relation_candidates.json` — review-first known relationship fields + target resolution evidence
        \\- `heading_fragments.json` — fragment inventory (headings not verified)
        \\- `boundary_manifest.json` — preserved / stripped / manual_review classification
        \\- `compile_report.json` — Boris compile attempt result
        \\- `report.json` — machine summary
        \\
        \\
    );

    try md.appendSlice(a, "## Pages\n\n");
    for (pages) |p| {
        try md.appendSlice(a, "- `");
        try md.appendSlice(a, p.entity_id);
        try md.appendSlice(a, "` (`");
        try md.appendSlice(a, p.route);
        try md.appendSlice(a, "`) ← `");
        try md.appendSlice(a, p.source_path);
        try md.appendSlice(a, "`");
        if (p.is_synthetic) try md.appendSlice(a, " *(synthetic trunk)*");
        try md.appendSlice(a, "\n");
    }

    try md.appendSlice(a, "\n## Unmapped frontmatter\n\n");
    var any_fm = false;
    for (pages) |p| {
        if (p.unmapped_fields.len == 0) continue;
        any_fm = true;
        try md.appendSlice(a, "- `");
        try md.appendSlice(a, p.source_path);
        try md.appendSlice(a, "` — ");
        for (p.unmapped_fields, 0..) |f, i| {
            if (i > 0) try md.appendSlice(a, ", ");
            try md.appendSlice(a, "`");
            try md.appendSlice(a, f);
            try md.appendSlice(a, "`");
        }
        try md.appendSlice(a, "\n");
    }
    if (!any_fm) try md.appendSlice(a, "None.\n");

    try md.appendSlice(a, "\n## MDX imports / components\n\n");
    var any_mdx = false;
    for (pages) |p| {
        if (p.imports.len == 0 and p.components.len == 0) continue;
        any_mdx = true;
        try md.appendSlice(a, "- `");
        try md.appendSlice(a, p.source_path);
        try md.appendSlice(a, "`\n");
        if (p.imports.len > 0) {
            try md.appendSlice(a, "  - imports: ");
            for (p.imports, 0..) |im, i| {
                if (i > 0) try md.appendSlice(a, ", ");
                try md.appendSlice(a, "`");
                try md.appendSlice(a, im);
                try md.appendSlice(a, "`");
            }
            try md.appendSlice(a, "\n");
        }
        if (p.components.len > 0) {
            try md.appendSlice(a, "  - components: ");
            for (p.components, 0..) |c, i| {
                if (i > 0) try md.appendSlice(a, ", ");
                try md.appendSlice(a, "`");
                try md.appendSlice(a, c);
                try md.appendSlice(a, "`");
            }
            try md.appendSlice(a, "\n");
        }
    }
    if (!any_mdx) try md.appendSlice(a, "None.\n");

    try md.appendSlice(a, "\n## Link review (non-rewritten)\n\n");
    var any_review = false;
    for (pages) |p| {
        for (p.link_events) |ev| {
            if (!std.mem.eql(u8, ev.resolution, "review")) continue;
            any_review = true;
            try md.appendSlice(a, "- `");
            try md.appendSlice(a, p.source_path);
            try md.appendSlice(a, "` L");
            try appendUsize(&md, a, ev.line);
            try md.appendSlice(a, " `");
            try md.appendSlice(a, ev.target);
            try md.appendSlice(a, "` — ");
            try md.appendSlice(a, ev.review_reason orelse "review");
            if (ev.fragment) |f| {
                try md.appendSlice(a, " (fragment `#");
                try md.appendSlice(a, f);
                try md.appendSlice(a, "`)");
            }
            try md.appendSlice(a, "\n");
        }
    }
    if (!any_review) try md.appendSlice(a, "None.\n");

    try md.appendSlice(a, "\n## Local assets (proven)\n\n");
    var any_asset = false;
    for (assets) |e| {
        if (!e.exists or e.sha256_hex == null) continue;
        any_asset = true;
        try md.appendSlice(a, "- `");
        try md.appendSlice(a, e.source_path);
        try md.appendSlice(a, "` (");
        try md.appendSlice(a, e.kind);
        try md.appendSlice(a, ", ");
        try appendUsize(&md, a, e.bytes);
        try md.appendSlice(a, " bytes, sha256=`");
        try md.appendSlice(a, e.sha256_hex.?);
        try md.appendSlice(a, "`)\n");
    }
    if (!any_asset) try md.appendSlice(a, "None with proven local hash.\n");

    try md.appendSlice(a, "\n## Stripped untrusted blocks\n\n");
    var any_strip = false;
    for (pages) |p| {
        for (p.stripped_blocks) |b| {
            any_strip = true;
            try md.appendSlice(a, "- `");
            try md.appendSlice(a, p.source_path);
            try md.appendSlice(a, "` — line ");
            try appendUsize(&md, a, b.line);
            try md.appendSlice(a, ", category `");
            try md.appendSlice(a, b.category);
            try md.appendSlice(a, "`, stripped: true\n");
        }
    }
    if (!any_strip) try md.appendSlice(a, "None.\n");

    try md.appendSlice(a, "\n## Entity collisions (ambiguous routes)\n\n");
    if (collisions.len == 0) {
        try md.appendSlice(a, "None.\n");
    } else {
        for (collisions) |c| {
            try md.appendSlice(a, "- base entity `");
            try md.appendSlice(a, c.entity_id);
            try md.appendSlice(a, "` (");
            try md.appendSlice(a, c.resolution);
            try md.appendSlice(a, "): ");
            for (c.source_paths, 0..) |sp, i| {
                if (i > 0) try md.appendSlice(a, ", ");
                try md.appendSlice(a, "`");
                try md.appendSlice(a, sp);
                try md.appendSlice(a, "`");
            }
            try md.appendSlice(a, "\n");
        }
    }

    try md.appendSlice(a, "\n## Safety\n\n");
    try md.appendSlice(a, "- Source root is never written.\n");
    try md.appendSlice(a, "- No network, no package install, no Node/Astro/MDX execution.\n");
    try md.appendSlice(a, "- Embedded agent/directive/instruction/prompt fences are stripped without replaying payloads.\n");
    try md.appendSlice(a, "- Proven Markdown images copy into page `{stem}.assets/` under `--out` only; missing/escape paths are review-only.\n");
    try md.appendSlice(a, "- Not a universal converter; no invented semantic transformations.\n");
    try md.appendSlice(a, "- Repeated runs with the same inputs produce byte-identical reports (relative `--root`/`--out`).\n");

    try writeFile(io, out, "REPORT.md", md.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "starlight: entity id and route helpers" {
    const a = std.testing.allocator;
    const id1 = try entityIdFromLocaleRel(a, "features/app.mdx");
    defer a.free(id1);
    try std.testing.expectEqualStrings("features/app", id1);

    const id2 = try entityIdFromLocaleRel(a, "installation/index.mdx");
    defer a.free(id2);
    try std.testing.expectEqualStrings("installation", id2);

    const id3 = try entityIdFromLocaleRel(a, "index.mdx");
    defer a.free(id3);
    try std.testing.expectEqualStrings("index", id3);

    const r = try routeFromEntity(a, "/en", "features/plans");
    defer a.free(r);
    try std.testing.expectEqualStrings("/en/features/plans", r);

    const r_root = try routeFromEntity(a, "", "guides/pages");
    defer a.free(r_root);
    try std.testing.expectEqualStrings("/guides/pages", r_root);

    const r_idx = try routeFromEntity(a, "", "index");
    defer a.free(r_idx);
    try std.testing.expectEqualStrings("/", r_idx);
}

test "starlight: candidate filter excludes only underscore partials" {
    try std.testing.expect(isCandidatePage("index.mdx"));
    try std.testing.expect(isCandidatePage("features/app.mdx"));
    try std.testing.expect(isCandidatePage("blog/2024/x.md"));
    try std.testing.expect(isCandidatePage("reference/cli/evcc.md"));
    try std.testing.expect(!isCandidatePage("tariffs/_dynamic_electricity_price.mdx"));
    try std.testing.expect(!isCandidatePage("_partial.mdx"));
    try std.testing.expect(looksLikeLocaleDirName("de"));
    try std.testing.expect(looksLikeLocaleDirName("zh-cn"));
    try std.testing.expect(!looksLikeLocaleDirName("guides"));
    try std.testing.expect(!looksLikeLocaleDirName("components"));
}

test "starlight: relation candidates retain over-limit and ambiguous evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entities: EntityMap = .empty;
    const targets = [_][]const u8{
        "targets/t01", "targets/t02", "targets/t03", "targets/t04", "targets/t05", "targets/t06",
        "targets/t07", "targets/t08", "targets/t09", "targets/t10", "targets/t11", "targets/t12",
        "targets/t13", "targets/t14", "targets/t15", "targets/t16", "targets/t17",
    };
    for (targets) |target| try entities.put(a, target, target);
    try entities.put(a, "a/shared", "a/shared");
    try entities.put(a, "b/shared", "b/shared");

    const page: SourcePage = .{
        .source_path = "src/content/docs/en/source.mdx",
        .locale_rel = "source.mdx",
        .entity_id = "source",
        .route = "/en/source",
        .output_path = "content/source.md",
        .title = "Source",
        .parent = null,
        .is_trunk = true,
        .raw_frontmatter =
        \\relatedEntries: [targets/t01, targets/t02, targets/t03, targets/t04, targets/t05, targets/t06, targets/t07, targets/t08, targets/t09, targets/t10, targets/t11, targets/t12, targets/t13, targets/t14, targets/t15, targets/t16, targets/t17]
        \\mascotRef: shared
        ,
        .unmapped_fields = &.{},
        .body = "",
        .imports = &.{},
        .components = &.{},
        .stripped_blocks = &.{},
        .link_events = &.{},
        .component_events = &.{},
        .bytes = 0,
    };
    var candidates: std.ArrayList(RelationCandidate) = .empty;
    try collectRelationCandidatesForPage(a, page, "/en", &entities, &candidates);
    try std.testing.expectEqual(@as(usize, 18), candidates.items.len);
    for (candidates.items[0..16], 0..) |candidate, i| {
        try std.testing.expectEqual(@as(?usize, i + 1), candidate.relation_ordinal);
        try std.testing.expectEqual(@as(?bool, true), candidate.within_product_limit);
        try std.testing.expectEqualStrings("relates_to", candidate.proposed_kind.?);
    }
    try std.testing.expectEqual(@as(?usize, 17), candidates.items[16].relation_ordinal);
    try std.testing.expectEqual(@as(?bool, false), candidates.items[16].within_product_limit);
    try std.testing.expectEqualStrings("product_relation_limit_exceeded", candidates.items[16].review_reason.?);
    try std.testing.expectEqualStrings("ambiguous", candidates.items[17].target_resolution);
    try std.testing.expect(candidates.items[17].proposed_kind == null);
    try std.testing.expectEqualStrings("ambiguous_target_in_converted_entity_map", candidates.items[17].review_reason.?);
}

test "starlight: link rewrite only when proven" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entities: EntityMap = .empty;
    try entities.put(a, "features/co2", "features/co2");
    try entities.put(a, "features/plans", "features/plans");

    const body =
        \\See [CO2](./co2) and [missing](./nope) and [external](https://example.com).
        \\Also [abs](/en/features/plans) and [out](/en/tariffs).
        \\And [frag](/en/features/plans#heading) plus [asset](/images/hero.png).
        \\
    ;
    const result = try rewriteLinks(a, "/en", "features/plans", body, &entities);

    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[features/co2|CO2]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[features/plans|abs]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[features/plans|frag]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[missing](./nope)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "https://example.com") != null);

    var rewritten: usize = 0;
    var review: usize = 0;
    var asset: usize = 0;
    var frag_note: usize = 0;
    for (result.events) |ev| {
        if (std.mem.eql(u8, ev.resolution, "rewritten")) rewritten += 1;
        if (std.mem.eql(u8, ev.resolution, "review")) review += 1;
        if (std.mem.eql(u8, ev.resolution, "asset")) asset += 1;
        if (ev.review_reason) |rr| {
            if (std.mem.eql(u8, rr, "fragment_present_heading_not_verified")) frag_note += 1;
        }
    }
    try std.testing.expect(rewritten >= 3);
    try std.testing.expect(review >= 1);
    try std.testing.expect(asset >= 1);
    try std.testing.expect(frag_note >= 1);
}

test "starlight: root-locale link rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entities: EntityMap = .empty;
    try entities.put(a, "guides/pages", "guides/pages");
    try entities.put(a, "index", "index");

    const body =
        \\See [pages](/guides/pages/) and [home](/) and [missing](/nope).
        \\
    ;
    const result = try rewriteLinks(a, "", "getting-started", body, &entities);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[guides/pages|pages]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[index|home]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[missing](/nope)") != null);
}

test "starlight: locale-dir fixture is deterministic, preserves source, reports MDX" {
    const io = std.testing.io;
    const a_out = "fixtures/.test-starlight-a";
    const b_out = "fixtures/.test-starlight-b";
    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/mini-starlight", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/mini-starlight",
        .out_dir = a_out,
        .quiet = true,
    });
    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/mini-starlight",
        .out_dir = b_out,
        .quiet = true,
    });

    var ao = try Io.Dir.cwd().openDir(io, a_out, .{});
    defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, b_out, .{});
    defer bo.close(io);

    // Byte-identical across repeated runs for key manifests + content.
    const compare = [_][]const u8{
        "route_map.json",
        "selection_manifest.json",
        "link_review.json",
        "relation_candidates.json",
        "assets_manifest.json",
        "boundary_manifest.json",
        "heading_fragments.json",
        "report.json",
        "content/features/alpha.md",
    };
    for (compare) |name| {
        const xa = try readFileAlloc(io, ao, name, std.testing.allocator);
        defer std.testing.allocator.free(xa);
        const xb = try readFileAlloc(io, bo, name, std.testing.allocator);
        defer std.testing.allocator.free(xb);
        try std.testing.expectEqualStrings(xa, xb);
    }

    const unsup = try readFileAlloc(io, ao, "unsupported_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(unsup);
    try std.testing.expect(std.mem.indexOf(u8, unsup, "Screenshot") != null or std.mem.indexOf(u8, unsup, "@components/") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsup, "sidebar") != null);

    const page = try readFileAlloc(io, ao, "content/features/alpha.md", std.testing.allocator);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "parent: features") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id: features/alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "[[features/beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "fixture-payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "relations:") == null);

    const relations = try readFileAlloc(io, ao, "relation_candidates.json", std.testing.allocator);
    defer std.testing.allocator.free(relations);
    try std.testing.expect(std.mem.indexOf(u8, relations, "boris-starlight-relation-candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "\"source_field\": \"relatedEntries\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "\"resolved_entity\": \"features/beta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "\"proposed_kind\": \"relates_to\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "target_not_in_converted_entity_map") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "non_scalar_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "malformed_inline_list") != null);
    try std.testing.expect(std.mem.indexOf(u8, relations, "review_only_field_no_relation_kind") != null);

    const report = try readFileAlloc(io, ao, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, format_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "locale_dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "boundary_counts") != null);

    const assets = try readFileAlloc(io, ao, "assets_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(assets);
    try std.testing.expect(std.mem.indexOf(u8, assets, "sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets, "\"exists\": true") != null);

    const boundary = try readFileAlloc(io, ao, "boundary_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(boundary);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "\"preserved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "\"stripped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "\"manual_review\"") != null);

    const after = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    const prov = try readFileAlloc(io, ao, "provenance_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "boris-starlight-provenance") != null);
    const compile = try readFileAlloc(io, ao, "compile_report.json", std.testing.allocator);
    defer std.testing.allocator.free(compile);
    try std.testing.expect(std.mem.indexOf(u8, compile, "status") != null);

    const sel = try readFileAlloc(io, ao, "selection_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(sel);
    try std.testing.expect(std.mem.indexOf(u8, sel, "underscore_partial") != null);

    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};
}

test "starlight: root-locale fixture discovery and routes" {
    const io = std.testing.io;
    const out_dir = "fixtures/.test-starlight-root";
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/mini-starlight-root", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/index.mdx", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/mini-starlight-root",
        .out_dir = out_dir,
        .quiet = true,
        .max_pages = 50,
    });

    var od = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer od.close(io);

    const report = try readFileAlloc(io, od, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "root_locale") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "src/content/docs") != null);

    const routes = try readFileAlloc(io, od, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(routes);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\"route\": \"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\"route\": \"/guides/pages\"") != null);
    // Sibling locale tree must not be converted.
    try std.testing.expect(std.mem.indexOf(u8, routes, "de/") == null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\"entity_id\": \"de\"") == null);

    const page = try readFileAlloc(io, od, "content/guides/pages.md", std.testing.allocator);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "parent: guides") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "[[index") != null);

    const after = try readFileAlloc(io, fixture, "src/content/docs/index.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    // Determinism: second run byte-matches.
    const out_b = "fixtures/.test-starlight-root-b";
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/mini-starlight-root",
        .out_dir = out_b,
        .quiet = true,
        .max_pages = 50,
    });
    var ob = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer ob.close(io);
    const ra = try readFileAlloc(io, od, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(ra);
    const rb = try readFileAlloc(io, ob, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(rb);
    try std.testing.expectEqualStrings(ra, rb);

    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "starlight: refuse output inside source" {
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("/tmp/src", "/tmp/src"));
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("/tmp/src", "/tmp/src/out"));
}

test "starlight: dogfood fixture is deterministic at scale and preserves source" {
    const io = std.testing.io;
    const a_out = "fixtures/.test-starlight-dogfood-a";
    const b_out = "fixtures/.test-starlight-dogfood-b";
    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/dogfood-starlight", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/getting-started.mdx", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/dogfood-starlight",
        .out_dir = a_out,
        .quiet = true,
        .max_pages = 80,
    });
    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/dogfood-starlight",
        .out_dir = b_out,
        .quiet = true,
        .max_pages = 80,
    });

    var ao = try Io.Dir.cwd().openDir(io, a_out, .{});
    defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, b_out, .{});
    defer bo.close(io);

    const compare = [_][]const u8{
        "route_map.json",
        "selection_manifest.json",
        "link_review.json",
        "assets_manifest.json",
        "nav_flatten.json",
        "unsupported_manifest.json",
        "heading_fragments.json",
        "boundary_manifest.json",
        "provenance_manifest.json",
        "report.json",
        "REPORT.md",
        "content/getting-started.md",
        "content/guides/pages.md",
        "content/blog/2024/release-notes.md",
    };
    for (compare) |name| {
        const xa = try readFileAlloc(io, ao, name, std.testing.allocator);
        defer std.testing.allocator.free(xa);
        const xb = try readFileAlloc(io, bo, name, std.testing.allocator);
        defer std.testing.allocator.free(xb);
        try std.testing.expectEqualStrings(xa, xb);
    }

    const report = try readFileAlloc(io, ao, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "root_locale") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"converted_pages\"") != null);
    // Parse selected_candidates: dogfood fixture is ~67 non-partial pages.
    const sel_key = "\"selected_candidates\": ";
    const sel_at = std.mem.indexOf(u8, report, sel_key) orelse return error.TestUnexpectedResult;
    var n: usize = 0;
    var p = sel_at + sel_key.len;
    while (p < report.len and report[p] >= '0' and report[p] <= '9') : (p += 1) {
        n = n * 10 + (report[p] - '0');
    }
    try std.testing.expect(n >= 40 and n <= 80);

    const routes = try readFileAlloc(io, ao, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(routes);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\"route\": \"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\"route\": \"/guides/pages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\"route\": \"/blog/2024/release-notes\"") != null);
    // Sibling locales must not convert.
    try std.testing.expect(std.mem.indexOf(u8, routes, "de/") == null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "zh-cn") == null);

    const page = try readFileAlloc(io, ao, "content/getting-started.md", std.testing.allocator);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "untrusted-dogfood-payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "[[") != null); // proven wiki rewrite present

    const boundary = try readFileAlloc(io, ao, "boundary_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(boundary);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "stripped") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "manual_review") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "deep_path") != null);

    const frags = try readFileAlloc(io, ao, "heading_fragments.json", std.testing.allocator);
    defer std.testing.allocator.free(frags);
    try std.testing.expect(std.mem.indexOf(u8, frags, "heading-ids") != null or std.mem.indexOf(u8, frags, "fragment") != null);

    const assets = try readFileAlloc(io, ao, "assets_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(assets);
    try std.testing.expect(std.mem.indexOf(u8, assets, "public/images/hero.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets, "sha256") != null);

    const nav = try readFileAlloc(io, ao, "nav_flatten.json", std.testing.allocator);
    defer std.testing.allocator.free(nav);
    try std.testing.expect(std.mem.indexOf(u8, nav, "sidebar_autogenerate") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav, "sidebar_label") != null);

    const after = try readFileAlloc(io, fixture, "src/content/docs/getting-started.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};
}

test "starlight: hostile fixture reports collisions, unsupported MDX, and strips instructions" {
    const io = std.testing.io;
    const out_dir = "fixtures/.test-starlight-hostile";
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/hostile-starlight", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/hostile-starlight",
        .out_dir = out_dir,
        .quiet = true,
        .max_pages = 40,
    });

    var od = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer od.close(io);

    const report = try readFileAlloc(io, od, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "locale_dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"entity_collisions\": ") != null);
    // At least one collision group expected.
    const col_key = "\"entity_collisions\": ";
    const col_at = std.mem.indexOf(u8, report, col_key) orelse return error.TestUnexpectedResult;
    var cn: usize = 0;
    var cp = col_at + col_key.len;
    while (cp < report.len and report[cp] >= '0' and report[cp] <= '9') : (cp += 1) {
        cn = cn * 10 + (report[cp] - '0');
    }
    try std.testing.expect(cn >= 1);

    const unsup = try readFileAlloc(io, od, "unsupported_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(unsup);
    try std.testing.expect(std.mem.indexOf(u8, unsup, "entity_collisions") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsup, "clash/intro") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsup, "sidebar") != null or std.mem.indexOf(u8, unsup, "customObject") != null or std.mem.indexOf(u8, unsup, "draft") != null);

    const routes = try readFileAlloc(io, od, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(routes);
    // Disambiguated second entity should appear.
    try std.testing.expect(std.mem.indexOf(u8, routes, "clash/intro-2") != null or std.mem.indexOf(u8, routes, "installation-2") != null);

    const alpha = try readFileAlloc(io, od, "content/features/alpha.md", std.testing.allocator);
    defer std.testing.allocator.free(alpha);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "hostile-instruction-payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "id: features/alpha") != null); // converter-owned id

    const boundary = try readFileAlloc(io, od, "boundary_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(boundary);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "ambiguous_route") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "unsupported_mdx") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "stripped") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "deep_path") != null);

    const sel = try readFileAlloc(io, od, "selection_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(sel);
    try std.testing.expect(std.mem.indexOf(u8, sel, "underscore_partial") != null);

    const after = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    // Second run byte-identical.
    const out_b = "fixtures/.test-starlight-hostile-b";
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/hostile-starlight",
        .out_dir = out_b,
        .quiet = true,
        .max_pages = 40,
    });
    var ob = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer ob.close(io);
    const ba = try readFileAlloc(io, od, "boundary_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(ba);
    const bb = try readFileAlloc(io, ob, "boundary_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(bb);
    try std.testing.expectEqualStrings(ba, bb);

    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "starlight: joinNormalized resolves and rejects escape" {
    const a = std.testing.allocator;
    const ok = (try joinNormalized(a, "features", "./img/shot.png")).?;
    defer a.free(ok);
    try std.testing.expectEqualStrings("features/img/shot.png", ok);

    const nested = (try joinNormalized(a, "nested/deep", "./media/pic.png")).?;
    defer a.free(nested);
    try std.testing.expectEqualStrings("nested/deep/media/pic.png", nested);

    const esc = try joinNormalized(a, "escape", "../../../../secret.png");
    try std.testing.expect(esc == null);

    try std.testing.expect(isBorisSafeWithinTree("img/shot.png"));
    try std.testing.expect(isBorisSafeWithinTree("media/pic.png"));
    try std.testing.expect(!isBorisSafeWithinTree("../x.png"));
    try std.testing.expect(!isBorisSafeWithinTree("café.png"));
    try std.testing.expectEqualStrings("alpha", pageStemFromEntity("features/alpha"));
    try std.testing.expectEqualStrings("features", pageDirFromLocaleRel("features/alpha.mdx"));
}

test "starlight: F-L1 image-path fixture migrates, preserves, and fails closed" {
    const io = std.testing.io;
    const out_dir = "fixtures/.test-image-path-starlight";
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/image-path-starlight", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/image-path-starlight",
        .out_dir = out_dir,
        .quiet = true,
        .max_pages = 40,
    });

    var od = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer od.close(io);

    // 1+2: relative ./img/shot.png with asset at features/img/shot.png
    const alpha = try readFileAlloc(io, od, "content/features/alpha.md", std.testing.allocator);
    defer std.testing.allocator.free(alpha);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "![shot](alpha.assets/img/shot.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "![hero](alpha.assets/images/hero.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "./img/shot.png") == null);

    // Copied bytes exist under out.
    const shot = try readFileAlloc(io, od, "content/features/alpha.assets/img/shot.png", std.testing.allocator);
    defer std.testing.allocator.free(shot);
    try std.testing.expect(shot.len > 0);
    const hero = try readFileAlloc(io, od, "content/features/alpha.assets/images/hero.png", std.testing.allocator);
    defer std.testing.allocator.free(hero);
    try std.testing.expect(hero.len > 0);

    // 3: nested document + nested asset
    const nested = try readFileAlloc(io, od, "content/nested/deep/page.md", std.testing.allocator);
    defer std.testing.allocator.free(nested);
    try std.testing.expect(std.mem.indexOf(u8, nested, "![pic](page.assets/media/pic.png)") != null);
    const pic = try readFileAlloc(io, od, "content/nested/deep/page.assets/media/pic.png", std.testing.allocator);
    defer std.testing.allocator.free(pic);
    try std.testing.expect(pic.len > 0);

    // 4: missing asset — leave original, explicit review
    const missing = try readFileAlloc(io, od, "content/missing/page.md", std.testing.allocator);
    defer std.testing.allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "![nope](./nope.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "nope.assets") == null);

    // 5: escape attempt — leave original, explicit review
    const escape = try readFileAlloc(io, od, "content/escape/page.md", std.testing.allocator);
    defer std.testing.allocator.free(escape);
    try std.testing.expect(std.mem.indexOf(u8, escape, "![bad](../../../../secret.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, escape, "page.assets") == null);

    // 6: already-correct `{stem}.assets/…` form preserved + copied
    const ready = try readFileAlloc(io, od, "content/ready/note.md", std.testing.allocator);
    defer std.testing.allocator.free(ready);
    try std.testing.expect(std.mem.indexOf(u8, ready, "![ok](note.assets/ok.png)") != null);
    const ok_bytes = try readFileAlloc(io, od, "content/ready/note.assets/ok.png", std.testing.allocator);
    defer std.testing.allocator.free(ok_bytes);
    try std.testing.expect(ok_bytes.len > 0);

    const links = try readFileAlloc(io, od, "link_review.json", std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expect(std.mem.indexOf(u8, links, "image_migrated_to_page_assets") != null);
    try std.testing.expect(std.mem.indexOf(u8, links, "referenced_asset_missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, links, "asset_path_escapes_migration_root") != null);

    const assets = try readFileAlloc(io, od, "assets_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(assets);
    try std.testing.expect(std.mem.indexOf(u8, assets, "migrated_page_asset") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets, "content/features/alpha.assets/img/shot.png") != null);

    // Source immutability.
    const after = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    // Determinism.
    const out_b = "fixtures/.test-image-path-starlight-b";
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/image-path-starlight",
        .out_dir = out_b,
        .quiet = true,
        .max_pages = 40,
    });
    var ob = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer ob.close(io);
    const aa = try readFileAlloc(io, od, "content/features/alpha.md", std.testing.allocator);
    defer std.testing.allocator.free(aa);
    const ab = try readFileAlloc(io, ob, "content/features/alpha.md", std.testing.allocator);
    defer std.testing.allocator.free(ab);
    try std.testing.expectEqualStrings(aa, ab);
    const ma = try readFileAlloc(io, od, "assets_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(ma);
    const mb = try readFileAlloc(io, ob, "assets_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "starlight: dynamic asset attributes become explicit review placeholders" {
    const io = std.testing.io;
    const out_dir = "fixtures/.test-dynamic-asset-starlight";
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/dynamic-asset-starlight", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/en/dynamic-assets.mdx", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/dynamic-asset-starlight",
        .out_dir = out_dir,
        .quiet = true,
        .max_pages = 10,
    });

    var od = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer od.close(io);

    const page = try readFileAlloc(io, od, "content/dynamic-assets.md", std.testing.allocator);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<!-- boris-migration-review: dynamic asset attribute omitted; see boundary_manifest.json -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "src={localBirdImage.src}") == null);
    // Static and missing static raw-HTML references retain their prior bytes.
    try std.testing.expect(std.mem.indexOf(u8, page, "<img src=\"image.png\" alt=\"Static image\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<img src=\"missing.png\" alt=\"Missing image\" />") != null);

    const boundary = try readFileAlloc(io, od, "boundary_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(boundary);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "dynamic_asset_expression:src={localBirdImage.src}") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "\"category\": \"dynamic_asset\"") != null);

    const links = try readFileAlloc(io, od, "link_review.json", std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expect(std.mem.indexOf(u8, links, "\"kind\": \"dynamic_asset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, links, "src={localBirdImage.src}") != null);
    try std.testing.expect(std.mem.indexOf(u8, links, "dynamic_asset_expression") != null);

    const after = try readFileAlloc(io, fixture, "src/content/docs/en/dynamic-assets.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
}

test "starlight: dogfood relative images migrate for Boris compile surface" {
    const io = std.testing.io;
    const out_dir = "fixtures/.test-starlight-dogfood-images";
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try run(io, std.testing.allocator, .{
        .source_root_dir = "fixtures/dogfood-starlight",
        .out_dir = out_dir,
        .quiet = true,
        .max_pages = 80,
    });

    var od = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer od.close(io);

    const alpha = try readFileAlloc(io, od, "content/features/alpha.md", std.testing.allocator);
    defer std.testing.allocator.free(alpha);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "![shot](alpha.assets/img/shot.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "./img/shot.png") == null);

    const shot = try readFileAlloc(io, od, "content/features/alpha.assets/img/shot.png", std.testing.allocator);
    defer std.testing.allocator.free(shot);
    try std.testing.expect(shot.len > 0);

    const pages = try readFileAlloc(io, od, "content/guides/pages.md", std.testing.allocator);
    defer std.testing.allocator.free(pages);
    try std.testing.expect(std.mem.indexOf(u8, pages, "pages.assets/assets/diagram.png") != null);

    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
}

test "starlight: sanitizeMdxBody preserves attributed Aside and Details" {
    const a = std.testing.allocator;
    const body =
        \\<Details summary="Custom Details Summary" open="true">
        \\This is inside details.
        \\</Details>
        \\
        \\<Aside type="note" title="Custom Aside Title" class="extra-style">
        \\This is inside aside.
        \\</Aside>
    ;

    const res = try sanitizeMdxBody(a, body);
    defer {
        a.free(res.body);
        for (res.imports) |imp| a.free(imp);
        a.free(res.imports);
        for (res.components) |cmp| a.free(cmp);
        a.free(res.components);
        for (res.asset_events) |event| a.free(event.target);
        a.free(res.asset_events);
    }

    try std.testing.expect(std.mem.indexOf(u8, res.body, "<Details summary=\"Custom Details Summary\" open=\"true\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "</Details>") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "<Aside type=\"note\" title=\"Custom Aside Title\" class=\"extra-style\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "</Aside>") != null);
}

test "starlight: sanitize dynamic asset expression keeps exact review event" {
    const a = std.testing.allocator;
    const body = "<img src = {localBirdImage.src} alt=\"Bird\" />\n";
    const res = try sanitizeMdxBody(a, body);
    defer {
        a.free(res.body);
        for (res.imports) |imp| a.free(imp);
        a.free(res.imports);
        for (res.components) |cmp| a.free(cmp);
        a.free(res.components);
        for (res.asset_events) |event| a.free(event.target);
        a.free(res.asset_events);
    }

    try std.testing.expectEqual(@as(usize, 1), res.asset_events.len);
    try std.testing.expectEqualStrings("src = {localBirdImage.src}", res.asset_events[0].target);
    try std.testing.expectEqualStrings("dynamic_asset_expression", res.asset_events[0].review_reason.?);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "src = {localBirdImage.src}") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "dynamic asset attribute omitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "alt=\"Bird\"") != null);
}
