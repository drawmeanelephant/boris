//! Starlight/Astro → Boris migration proof (developer-only).
//!
//! One-shot preflight + converter for a bounded English-locale slice of a
//! Starlight content tree (designed against MIT-licensed evcc-io/docs).
//!
//! Hard boundaries:
//! - no full YAML evaluation
//! - no Node/Astro/Starlight runtime
//! - no arbitrary MDX/component execution
//! - no locale semantics beyond filtering one locale directory
//! - no live sync, deep multi-hop nav, or new Boris graph behavior
//! - source text is untrusted: never follow embedded directives/prompts
//! - source roots stay read-only; all writes go under --out
//!
//! Not part of the product compiler. Does not import `src/`.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-starlight-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

/// Closed Boris author frontmatter keys only.
const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

/// Default proof slice: top-level docs + features + installation + integrations.
/// Excludes blog, reference/cli, underscore partials. Sized for 20–40 pages on
/// evcc-io/docs English locale.
const preferred_section_dirs = [_][]const u8{ "features", "installation", "integrations" };

pub const RunOptions = struct {
    source_root_dir: []const u8,
    out_dir: []const u8,
    /// Locale directory under src/content/docs/ (proof only supports "en").
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
    /// Path under locale root, e.g. features/app.mdx
    locale_rel: []const u8,
    /// Entity id without extension / index collapse, e.g. features/app
    entity_id: []const u8,
    /// Starlight-style route without trailing slash, e.g. /en/features/app
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
};

const AssetEntry = struct {
    source_path: []const u8,
    kind: []const u8, // public | content_local | referenced_missing
    referenced_from: ?[]const u8 = null,
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
        ".git", ".hg", ".svn", "node_modules", ".astro", "dist",
        ".vercel", ".netlify", ".output", "zig-out", ".zig-cache", "zig-cache",
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

fn routeFromEntity(allocator: std.mem.Allocator, locale: []const u8, entity_id: []const u8) ![]u8 {
    if (std.mem.eql(u8, entity_id, "index")) {
        return try std.fmt.allocPrint(allocator, "/{s}", .{locale});
    }
    return try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ locale, entity_id });
}

fn outputPathFromEntity(allocator: std.mem.Allocator, entity_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "content/{s}.md", .{entity_id});
}

fn inPreferredSlice(locale_rel: []const u8) bool {
    // Underscore partials are Starlight-internal includes, not pages.
    const base = std.fs.path.basename(locale_rel);
    if (base.len > 0 and base[0] == '_') return false;
    if (startsWithPath(locale_rel, "blog")) return false;
    if (startsWithPath(locale_rel, "reference/cli")) return false;

    // Top-level files (no slash).
    if (std.mem.indexOfScalar(u8, locale_rel, '/') == null) return true;

    for (preferred_section_dirs) |sec| {
        if (startsWithPath(locale_rel, sec)) return true;
    }
    return false;
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
} {
    var out: std.ArrayList(u8) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    var components: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
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
            try scanComponentTags(a, line, &components);
            // Neutralize JSX open/self-closing tags without executing them.
            var li: usize = 0;
            while (li < line.len) {
                if (line[li] == '<' and li + 1 < line.len) {
                    const c1 = line[li + 1];
                    if (c1 == '/') {
                        // Closing tag: skip through >
                        var k = li + 2;
                        while (k < line.len and line[k] != '>') : (k += 1) {}
                        if (k < line.len) k += 1;
                        li = k;
                        continue;
                    }
                    if (c1 >= 'A' and c1 <= 'Z') {
                        var k = li + 1;
                        while (k < line.len and line[k] != '>') : (k += 1) {}
                        if (k < line.len) k += 1;
                        try out.appendSlice(a, "<!-- unsupported-mdx-component -->");
                        li = k;
                        continue;
                    }
                }
                try out.append(a, line[li]);
                li += 1;
            }
            if (has_newline) try out.append(a, '\n');
        }
        pos = if (has_newline) end + 1 else end;
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
        if (prev) |p| if (std.mem.eql(u8, p, c)) continue;
        try dedup.append(a, c);
        prev = c;
    }
    return .{
        .body = try out.toOwnedSlice(a),
        .imports = try imports.toOwnedSlice(a),
        .components = try dedup.toOwnedSlice(a),
    };
}

fn normalizeRouteTarget(allocator: std.mem.Allocator, locale: []const u8, target: []const u8) ![]u8 {
    var t = target;
    // Drop query/fragment for route identity.
    if (std.mem.indexOfScalar(u8, t, '?')) |q| t = t[0..q];
    if (std.mem.indexOfScalar(u8, t, '#')) |h| t = t[0..h];
    // Strip trailing slash (evcc uses trailingSlash: never).
    while (t.len > 1 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];

    if (std.mem.startsWith(u8, t, "http://") or std.mem.startsWith(u8, t, "https://") or
        std.mem.startsWith(u8, t, "mailto:") or std.mem.startsWith(u8, t, "tel:"))
    {
        return try allocator.dupe(u8, t);
    }
    // Absolute site path.
    if (std.mem.startsWith(u8, t, "/")) {
        // /en/foo → /en/foo ; /foo may be locale-less device pages (out of slice).
        return try allocator.dupe(u8, t);
    }
    // Relative — caller resolves against page entity dir.
    _ = locale;
    return try allocator.dupe(u8, t);
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

fn routeToEntityCandidate(allocator: std.mem.Allocator, locale: []const u8, route: []const u8) !?[]u8 {
    // /en → index ; /en/features/app → features/app
    if (!std.mem.startsWith(u8, route, "/")) return null;
    const loc_prefix = try std.fmt.allocPrint(allocator, "/{s}", .{locale});
    if (std.mem.eql(u8, route, loc_prefix)) return try allocator.dupe(u8, "index");
    const with_slash = try std.fmt.allocPrint(allocator, "/{s}/", .{locale});
    if (std.mem.startsWith(u8, route, with_slash)) {
        return try allocator.dupe(u8, route[with_slash.len..]);
    }
    return null;
}

const EntityMap = std.StringHashMapUnmanaged([]const u8); // entity_id → entity_id (presence)

fn rewriteLinks(
    a: std.mem.Allocator,
    locale: []const u8,
    entity_id: []const u8,
    body: []const u8,
    entities: *const EntityMap,
) !struct { body: []const u8, events: []const LinkEvent } {
    var out: std.ArrayList(u8) = .empty;
    var events: std.ArrayList(LinkEvent) = .empty;
    var pos: usize = 0;
    var line_no: u32 = 1;

    while (pos < body.len) {
        // Scan for markdown link [text](url) or bare patterns.
        if (body[pos] == '[') {
            // Find ](
            if (std.mem.indexOfPos(u8, body, pos, "](")) |mid| {
                const text = body[pos + 1 .. mid];
                // Reject if nested newline in text for simplicity (multi-line links → leave).
                if (std.mem.indexOfScalar(u8, text, '\n') == null) {
                    const url_start = mid + 2;
                    if (std.mem.indexOfScalarPos(u8, body, url_start, ')')) |url_end| {
                        const url = body[url_start..url_end];
                        if (std.mem.indexOfScalar(u8, url, '\n') == null) {
                            const ev = try classifyAndMaybeRewrite(a, locale, entity_id, url, entities, "markdown", line_no);
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
                            // Count newlines skipped? url has none; text has none.
                            pos = url_end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        if (body[pos] == '\n') line_no += 1;
        try out.append(a, body[pos]);
        pos += 1;
    }

    // Second pass: scan remaining href="/..." and to="/..." for inventory (no rewrite of raw HTML).
    // Walk original body lines for href/to attributes.
    {
        var p: usize = 0;
        var ln: u32 = 1;
        while (p < body.len) {
            const end = std.mem.indexOfScalarPos(u8, body, p, '\n') orelse body.len;
            const line = body[p..end];
            try scanAttrLinks(a, locale, entity_id, line, entities, ln, &events);
            p = if (end < body.len) end + 1 else end;
            ln += 1;
        }
    }

    return .{ .body = try out.toOwnedSlice(a), .events = try events.toOwnedSlice(a) };
}

fn scanAttrLinks(
    a: std.mem.Allocator,
    locale: []const u8,
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
            const ev = try classifyAndMaybeRewrite(a, locale, entity_id, url, entities, attr.kind, line_no);
            // Attr links are never auto-rewritten (not markdown); force review/external inventory.
            if (std.mem.eql(u8, ev.resolution, "rewritten")) {
                try events.append(a, .{
                    .kind = attr.kind,
                    .target = ev.target,
                    .line = line_no,
                    .resolution = "review",
                    .rewritten_to = ev.rewritten_to,
                    .review_reason = "attribute_link_not_auto_rewritten",
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
    locale: []const u8,
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
    // Asset-like extension
    if (std.mem.indexOfScalar(u8, url, '.')) |_| {
        const lower_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".mp4", ".webm", ".pdf", ".ico", ".css", ".js", ".woff", ".woff2" };
        for (lower_exts) |ext| {
            // Compare case-insensitive against suffix before query
            var bare = url;
            if (std.mem.indexOfScalar(u8, bare, '?')) |q| bare = bare[0..q];
            if (std.mem.indexOfScalar(u8, bare, '#')) |h| bare = bare[0..h];
            if (bare.len >= ext.len and std.ascii.eqlIgnoreCase(bare[bare.len - ext.len ..], ext)) {
                return .{ .kind = kind, .target = try a.dupe(u8, url), .line = line_no, .resolution = "asset" };
            }
        }
    }

    var candidate_entity: ?[]const u8 = null;
    var norm = try normalizeRouteTarget(a, locale, url);

    if (std.mem.startsWith(u8, norm, "/")) {
        candidate_entity = try routeToEntityCandidate(a, locale, norm);
        if (candidate_entity == null) {
            return .{
                .kind = kind,
                .target = norm,
                .line = line_no,
                .resolution = "review",
                .review_reason = "absolute_route_outside_locale_or_unmapped",
            };
        }
    } else {
        // Relative path
        const rel = if (std.mem.startsWith(u8, norm, "./")) norm[2..] else norm;
        candidate_entity = try resolveRelativeToEntity(a, entity_id, rel);
    }

    const ent = candidate_entity orelse {
        return .{
            .kind = kind,
            .target = norm,
            .line = line_no,
            .resolution = "review",
            .review_reason = "no_candidate_entity",
        };
    };

    if (entities.get(ent)) |found| {
        // Only rewrite markdown links automatically.
        if (std.mem.eql(u8, kind, "markdown")) {
            return .{
                .kind = kind,
                .target = norm,
                .line = line_no,
                .resolution = "rewritten",
                .rewritten_to = found,
            };
        }
        return .{
            .kind = kind,
            .target = norm,
            .line = line_no,
            .resolution = "review",
            .rewritten_to = found,
            .review_reason = "non_markdown_link_needs_review",
        };
    }
    return .{
        .kind = kind,
        .target = norm,
        .line = line_no,
        .resolution = "review",
        .review_reason = "target_not_in_converted_slice",
        .rewritten_to = ent,
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

fn collectMarkdownFiles(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_dir: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = try root.openDir(io, rel_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try collectMarkdownFiles(io, a, root, child, out);
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
            try out.append(a, .{ .source_path = path, .kind = "public" });
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
            // keep noise low — only labels near sidebar context are recorded as group labels
            if (std.mem.indexOf(u8, s, "Introduction") != null or
                std.mem.indexOf(u8, s, "Installation") != null or
                std.mem.indexOf(u8, s, "Features") != null or
                std.mem.indexOf(u8, s, "Integrations") != null or
                std.mem.indexOf(u8, s, "Reference") != null or
                std.mem.indexOf(u8, s, "Devices") != null)
            {
                try out.append(a, .{
                    .kind = "sidebar_label",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .decision = "section_label_only_not_a_graph_node",
                });
            }
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

    const locale_root = try std.fmt.allocPrint(a, "src/content/docs/{s}", .{opts.locale});

    // ---- Inventory: markdown under locale ----
    var md_files: std.ArrayList([]const u8) = .empty;
    try collectMarkdownFiles(io, a, source, locale_root, &md_files);
    std.mem.sort([]const u8, md_files.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    // Filter to preferred slice and max_pages.
    var selected: std.ArrayList([]const u8) = .empty;
    for (md_files.items) |path| {
        const prefix = try std.fmt.allocPrint(a, "{s}/", .{locale_root});
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        const locale_rel = path[prefix.len..];
        if (!inPreferredSlice(locale_rel)) continue;
        try selected.append(a, path);
    }
    if (selected.items.len > opts.max_pages) {
        // Deterministic trim: keep sort order, take first max_pages.
        selected.items.len = opts.max_pages;
    }

    // ---- Parse pages ----
    var pages: std.ArrayList(SourcePage) = .empty;
    var inventory: std.ArrayList(InventoryRow) = .empty;
    var section_needs_trunk: std.StringHashMapUnmanaged(void) = .empty;

    for (selected.items) |path| {
        const raw = try readFileAlloc(io, source, path, a);
        const prefix = try std.fmt.allocPrint(a, "{s}/", .{locale_root});
        const locale_rel = path[prefix.len..];
        const entity_id = try entityIdFromLocaleRel(a, locale_rel);
        const fallback_title = try titleFromStem(a, entity_id);
        const parsed = try parseFrontmatterLite(a, raw, fallback_title);
        const stripped = try stripUntrustedBlocks(a, parsed.body);
        const mdx = try sanitizeMdxBody(a, stripped.body);

        // Parent / trunk assignment (one-level forest).
        var parent: ?[]const u8 = null;
        var is_trunk = false;
        if (std.mem.eql(u8, entity_id, "index")) {
            is_trunk = true;
        } else if (std.mem.indexOfScalar(u8, entity_id, '/')) |slash| {
            const section = entity_id[0..slash];
            parent = try a.dupe(u8, section);
            try section_needs_trunk.put(a, section, {});
        } else {
            // Top-level page → satellite of index; section name alone is a trunk if it is a section dir.
            var is_section = false;
            for (preferred_section_dirs) |sec| {
                if (std.mem.eql(u8, entity_id, sec)) {
                    is_section = true;
                    break;
                }
            }
            if (is_section) {
                is_trunk = true;
            } else {
                parent = "index";
            }
        }

        const route = try routeFromEntity(a, opts.locale, entity_id);
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
            .link_events = &.{},
            .bytes = raw.len,
        });
        try inventory.append(a, .{ .source_path = path, .kind = "content_page", .bytes = raw.len });
    }

    // Synthetic trunks for sections that have children but no real trunk page.
    var existing: std.StringHashMapUnmanaged(void) = .empty;
    for (pages.items) |p| try existing.put(a, p.entity_id, {});

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
        const route = try routeFromEntity(a, opts.locale, section);
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
            .route = try routeFromEntity(a, opts.locale, "index"),
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
            .bytes = 0,
        });
    }

    std.mem.sort(SourcePage, pages.items, {}, struct {
        fn less(_: void, x: SourcePage, y: SourcePage) bool {
            return std.mem.order(u8, x.entity_id, y.entity_id) == .lt;
        }
    }.less);

    // Entity map for link resolution.
    var entities: EntityMap = .empty;
    for (pages.items) |p| try entities.put(a, p.entity_id, p.entity_id);

    // Link rewrite pass.
    for (pages.items) |*p| {
        if (p.is_synthetic) continue;
        const rewritten = try rewriteLinks(a, opts.locale, p.entity_id, p.body, &entities);
        p.body = rewritten.body;
        p.link_events = rewritten.events;
    }

    // ---- Assets inventory ----
    var assets: std.ArrayList(AssetEntry) = .empty;
    try listPublicAssets(io, a, source, "public", &assets);
    // Co-located content assets (images next to pages).
    for (md_files.items) |path| {
        _ = path;
    }
    // Walk locale tree for non-md assets.
    try collectLocalAssets(io, a, source, locale_root, &assets);
    std.mem.sort(AssetEntry, assets.items, {}, struct {
        fn less(_: void, x: AssetEntry, y: AssetEntry) bool {
            return std.mem.order(u8, x.source_path, y.source_path) == .lt;
        }
    }.less);

    // ---- Sidebar / nav evidence ----
    var nav: std.ArrayList(NavDecision) = .empty;
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

    // Sidecar manifests
    try writeRouteMap(a, io, out, pages.items);
    try writeUnsupported(a, io, out, pages.items);
    try writeAssetsManifest(a, io, out, assets.items);
    try writeNavManifest(a, io, out, nav.items);
    try writeProvenance(a, io, out, opts, pages.items);
    try writeLinkReview(a, io, out, pages.items);
    try writeReports(a, io, out, opts, pages.items, inventory.items, assets.items, nav.items);

    // Compile proof
    const compile = try tryCompileWithBoris(io, gpa, a, opts, opts.out_dir);
    try writeCompileReport(a, io, out, compile);

    if (!opts.quiet) {
        std.debug.print(
            "starlight-migration-lab: wrote {s}/content/ ({d} pages), manifests, reports; compile={s}\n",
            .{ opts.out_dir, pages.items.len, compile.status },
        );
    }
}

fn collectLocalAssets(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_dir: []const u8,
    out: *std.ArrayList(AssetEntry),
) !void {
    var dir = root.openDir(io, rel_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try collectLocalAssets(io, a, root, child, out);
        } else if (entry.kind == .file) {
            if (isMarkdownName(entry.name)) continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, entry.name });
            try out.append(a, .{ .source_path = path, .kind = "content_local" });
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

fn writeUnsupported(a: std.mem.Allocator, io: Io, out: Io.Dir, pages: []const SourcePage) !void {
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
    try buf.appendSlice(a, "\n  ]\n}\n");
    try writeFile(io, out, "unsupported_manifest.json", buf.items);
}

fn writeAssetsManifest(a: std.mem.Allocator, io: Io, out: Io.Dir, assets: []const AssetEntry) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-assets\",\n  \"schema_version\": 1,\n  \"assets\": [\n");
    for (assets, 0..) |e, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, e.source_path);
        try buf.appendSlice(a, ", \"kind\": ");
        try appendJson(&buf, a, e.kind);
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

fn writeProvenance(a: std.mem.Allocator, io: Io, out: Io.Dir, opts: RunOptions, pages: []const SourcePage) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-provenance\",\n  \"schema_version\": 1,\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, opts.source_root_dir);
    try buf.appendSlice(a, ",\n  \"locale\": ");
    try appendJson(&buf, a, opts.locale);
    try buf.appendSlice(a, ",\n  \"source_site\": \"evcc-io/docs (or compatible Starlight tree)\",\n  \"license_note\": \"Upstream evcc-io/docs is MIT; do not commit cloned upstream into Boris.\",\n  \"records\": [\n");
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
    try buf.appendSlice(a, "{\n  \"format\": \"boris-starlight-link-review\",\n  \"schema_version\": 1,\n  \"policy\": \"Rewrite markdown route links to wiki only when the target entity exists in the converted slice. Otherwise emit an explicit review row.\",\n  \"links\": [\n");
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
            try buf.appendSlice(a, " }");
        }
    }
    try buf.appendSlice(a, "\n  ]\n}\n");
    try writeFile(io, out, "link_review.json", buf.items);
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
    pages: []const SourcePage,
    inventory: []const InventoryRow,
    assets: []const AssetEntry,
    nav: []const NavDecision,
) !void {
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
    try report.appendSlice(a, ",\n  \"max_pages\": ");
    try appendUsize(&report, a, opts.max_pages);
    try report.appendSlice(a, ",\n  \"converted_pages\": ");
    try appendUsize(&report, a, pages.len);
    try report.appendSlice(a, ",\n  \"supported_frontmatter\": [\"id\", \"title\", \"parent\", \"status\", \"tags\"],\n");
    try report.appendSlice(a, "  \"unsupported_summary\": {\n");
    try report.appendSlice(a, "    \"full_yaml\": false,\n");
    try report.appendSlice(a, "    \"mdx_components\": false,\n");
    try report.appendSlice(a, "    \"starlight_runtime\": false,\n");
    try report.appendSlice(a, "    \"locale_semantics\": false,\n");
    try report.appendSlice(a, "    \"live_sync\": false,\n");
    try report.appendSlice(a, "    \"deep_nav\": false\n");
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
    try md.appendSlice(a, "Developer-only proof for a bounded **English** Starlight slice.\n\n");
    try md.appendSlice(a, "| | |\n|--|--|\n| Format | `");
    try md.appendSlice(a, format_id);
    try md.appendSlice(a, "` |\n| Locale | `");
    try md.appendSlice(a, opts.locale);
    try md.appendSlice(a, "` |\n| Converted pages | ");
    try appendUsize(&md, a, pages.len);
    try md.appendSlice(a, " |\n| Source | `");
    try md.appendSlice(a, opts.source_root_dir);
    try md.appendSlice(a, "` (read-only) |\n\n");

    try md.appendSlice(a, "## Supported / unsupported matrix\n\n");
    try md.appendSlice(a,
        \\| Area | Status | Notes |
        \\|------|--------|-------|
        \\| Frontmatter `title` | **Supported** | Mapped into Boris `title` |
        \\| Frontmatter `id` / `parent` / `status` / `tags` | **Emitted** | Converter-owned; source values listed as unmapped when present |
        \\| Other YAML keys (`sidebar`, `draft`, nested maps, …) | **Unsupported** | Retained in provenance; never interpreted |
        \\| Full YAML / JS config evaluation | **Unsupported** | `astro.config.*` text-scanned only |
        \\| Markdown body | **Supported** | Passed through after MDX import strip |
        \\| MDX imports / components | **Unsupported** | Inventoried; tags neutralized; not executed |
        \\| Internal markdown route links | **Conditional** | Rewritten to `[[entity]]` only when target is in slice |
        \\| Attribute `href`/`to` routes | **Review** | Never auto-rewritten |
        \\| External links | **Left as-is** | |
        \\| Local / public assets | **Inventoried** | Not auto-copied in this proof |
        \\| Sidebar / autogenerate | **Flattened** | One-level forest: section Trunk + Satellite children |
        \\| Locales other than `en` | **Unsupported** | Locale filter only; no i18n semantics |
        \\| Live sync / Node runtime | **Unsupported** | |
        \\| Deep multi-hop parents | **Unsupported** | Boris one-level forest |
        \\
        \\
    );

    try md.appendSlice(a, "## Sidecar manifests\n\n");
    try md.appendSlice(a,
        \\- `route_map.json` — source path → route → entity id → output
        \\- `unsupported_manifest.json` — unmapped frontmatter + MDX imports/components
        \\- `assets_manifest.json` — public + content-local assets
        \\- `nav_flatten.json` — sidebar evidence + flatten decisions
        \\- `provenance_manifest.json` — raw frontmatter + source provenance
        \\- `link_review.json` — every link event (rewritten / review / external / asset)
        \\- `compile_report.json` — Boris compile attempt result
        \\- `report.json` — machine summary
        \\
        \\
    );

    try md.appendSlice(a, "## Pages\n\n");
    for (pages) |p| {
        try md.appendSlice(a, "- `");
        try md.appendSlice(a, p.entity_id);
        try md.appendSlice(a, "` ← `");
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
            try md.appendSlice(a, "\n");
        }
    }
    if (!any_review) try md.appendSlice(a, "None.\n");

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

    try md.appendSlice(a, "\n## Safety\n\n");
    try md.appendSlice(a, "- Source root is never written.\n");
    try md.appendSlice(a, "- No network, no package install, no Node/Astro execution.\n");
    try md.appendSlice(a, "- Embedded agent/directive/instruction/prompt fences are stripped without replaying payloads.\n");

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

    const r = try routeFromEntity(a, "en", "features/plans");
    defer a.free(r);
    try std.testing.expectEqualStrings("/en/features/plans", r);
}

test "starlight: preferred slice filter" {
    try std.testing.expect(inPreferredSlice("index.mdx"));
    try std.testing.expect(inPreferredSlice("features/app.mdx"));
    try std.testing.expect(inPreferredSlice("installation/linux.mdx"));
    try std.testing.expect(inPreferredSlice("integrations/mcp.mdx"));
    try std.testing.expect(!inPreferredSlice("blog/2024/x.md"));
    try std.testing.expect(!inPreferredSlice("reference/cli/evcc.md"));
    try std.testing.expect(!inPreferredSlice("tariffs/_dynamic_electricity_price.mdx"));
    try std.testing.expect(!inPreferredSlice("reference/configuration/site.mdx"));
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
        \\
    ;
    const result = try rewriteLinks(a, "en", "features/plans", body, &entities);

    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[features/co2|CO2]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[[features/plans|abs]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "[missing](./nope)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "https://example.com") != null);

    var rewritten: usize = 0;
    var review: usize = 0;
    for (result.events) |ev| {
        if (std.mem.eql(u8, ev.resolution, "rewritten")) rewritten += 1;
        if (std.mem.eql(u8, ev.resolution, "review")) review += 1;
    }
    try std.testing.expect(rewritten >= 2);
    try std.testing.expect(review >= 1);
}

test "starlight: fixture is deterministic, preserves source, reports MDX" {
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

    const ma = try readFileAlloc(io, ao, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(ma);
    const mb = try readFileAlloc(io, bo, "route_map.json", std.testing.allocator);
    defer std.testing.allocator.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

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

    const report = try readFileAlloc(io, ao, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, format_id) != null);

    const after = try readFileAlloc(io, fixture, "src/content/docs/en/features/alpha.mdx", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    const prov = try readFileAlloc(io, ao, "provenance_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "boris-starlight-provenance") != null);
    const compile = try readFileAlloc(io, ao, "compile_report.json", std.testing.allocator);
    defer std.testing.allocator.free(compile);
    try std.testing.expect(std.mem.indexOf(u8, compile, "status") != null);

    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};
}

test "starlight: refuse output inside source" {
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("/tmp/src", "/tmp/src"));
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("/tmp/src", "/tmp/src/out"));
}
