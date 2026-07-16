//! Obsidian vault → Boris migration laboratory (phase 1).
//!
//! Discovers Markdown in an Obsidian vault, maps vault-relative paths to Boris
//! entity ids, rewrites unambiguous wiki links / asset embeds, copies local
//! attachments with a deterministic manifest, and emits human-review reports
//! for unresolved, ambiguous, heading/block, Canvas, Dataview, and plugin
//! syntax. Never mutates the vault. No product-compiler imports.
//!
//! Not part of the Boris product compiler pipeline.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-obsidian-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.1";

pub const max_entity_id_bytes: usize = 255;

pub const RunOptions = struct {
    /// Obsidian vault root (never modified).
    vault_dir: []const u8,
    /// Output root: content/ + assets/ + reports + manifests.
    out_dir: []const u8,
    quiet: bool = false,
};

pub const ConversionClass = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    pub fn jsonName(self: ConversionClass) []const u8 {
        return switch (self) {
            .exact => "exact",
            .transformed => "transformed",
            .unsupported => "unsupported",
            .human_review => "human_review",
        };
    }

    pub fn rank(self: ConversionClass) u8 {
        return switch (self) {
            .exact => 0,
            .transformed => 1,
            .unsupported => 2,
            .human_review => 3,
        };
    }

    pub fn worse(a: ConversionClass, b: ConversionClass) ConversionClass {
        return if (a.rank() >= b.rank()) a else b;
    }
};

pub const LinkStatus = enum {
    resolved,
    unresolved,
    ambiguous,
    heading_or_block,
    skipped_fence,
    unsupported_embed,
    /// Templater / `${…}` / `<%…%>` inside a wiki target — not a real note link.
    plugin_template,

    pub fn jsonName(self: LinkStatus) []const u8 {
        return switch (self) {
            .resolved => "resolved",
            .unresolved => "unresolved",
            .ambiguous => "ambiguous",
            .heading_or_block => "heading_or_block",
            .skipped_fence => "skipped_fence",
            .unsupported_embed => "unsupported_embed",
            .plugin_template => "plugin_template",
        };
    }
};

/// True when a wiki target is plugin/template syntax rather than a note path.
pub fn isPluginTemplateWikiTarget(target: []const u8) bool {
    if (std.mem.indexOf(u8, target, "${") != null) return true;
    if (std.mem.indexOf(u8, target, "<%") != null) return true;
    return false;
}

/// True when `hay` equals `needle` or ends with `"/" ++ needle` (Obsidian path-suffix style).
pub fn pathSuffixMatch(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (std.mem.eql(u8, hay, needle)) return true;
    if (hay.len > needle.len and
        hay[hay.len - needle.len - 1] == '/' and
        std.mem.endsWith(u8, hay, needle))
        return true;
    return false;
}

// ---------------------------------------------------------------------------
// Directory skip policy
// ---------------------------------------------------------------------------

const skip_dir_names = [_][]const u8{
    ".obsidian",
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "dist",
    ".output",
    ".vercel",
    ".netlify",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    ".trash",
    ".DS_Store",
};

pub fn isSkippedDirName(name: []const u8) bool {
    for (skip_dir_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

pub fn isMarkdownPage(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md");
}

pub fn isCanvasFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".canvas");
}

fn isImageExt(path: []const u8) bool {
    const lower_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".ico" };
    for (lower_exts) |ext| {
        if (endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(hay: []const u8, suffix: []const u8) bool {
    if (hay.len < suffix.len) return false;
    const tail = hay[hay.len - suffix.len ..];
    if (tail.len != suffix.len) return false;
    for (tail, suffix) |a, b| {
        const al: u8 = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const bl: u8 = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (al != bl) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Path / entity-id helpers
// ---------------------------------------------------------------------------

pub fn normalizeRelPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    if (i + 1 < path.len and path[i] == '.' and (path[i + 1] == '/' or path[i + 1] == '\\')) i += 2;
    var need_slash = false;
    while (i < path.len) {
        while (i < path.len and (path[i] == '/' or path[i] == '\\')) : (i += 1) {}
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/' and path[i] != '\\') : (i += 1) {}
        const seg = path[start..i];
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) return error.IllegalSegment;
        if (need_slash) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
        need_slash = true;
    }
    if (out.items.len == 0) return error.EmptyPath;
    return try out.toOwnedSlice(allocator);
}

/// Map a vault-relative page path (…/Note.md) to a Boris entity id.
/// Spaces and other non-id characters become `-`; case preserved; `/` kept.
pub fn pathToEntityId(allocator: std.mem.Allocator, vault_rel: []const u8) ![]u8 {
    const norm = try normalizeRelPathAlloc(allocator, vault_rel);
    defer allocator.free(norm);
    const stem = if (std.mem.endsWith(u8, norm, ".md"))
        norm[0 .. norm.len - 3]
    else
        norm;
    return try sanitizeEntityId(allocator, stem);
}

/// Sanitize into a fixed buffer (no alloc). Returns null if empty or too long.
pub fn sanitizeEntityIdBuf(buf: []u8, stem: []const u8) ?[]const u8 {
    if (buf.len == 0) return null;
    var len: usize = 0;
    var prev_dash = false;
    var i: usize = 0;
    while (i < stem.len) {
        const c = stem[i];
        if (c == '/') {
            if (len > 0 and buf[len - 1] == '-') len -= 1;
            if (len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) return null;
                buf[len] = '/';
                len += 1;
            }
            prev_dash = false;
            i += 1;
            continue;
        }
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '.' or c == '-';
        if (ok) {
            if (len >= buf.len) return null;
            buf[len] = c;
            len += 1;
            prev_dash = c == '-';
        } else if (c == ' ' or c == '\t') {
            if (!prev_dash and len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) return null;
                buf[len] = '-';
                len += 1;
                prev_dash = true;
            }
        } else {
            // drop non-ASCII / punctuation as dash boundary
            if (!prev_dash and len > 0 and buf[len - 1] != '/') {
                if (len >= buf.len) return null;
                buf[len] = '-';
                len += 1;
                prev_dash = true;
            }
        }
        i += 1;
    }
    while (len > 0 and buf[len - 1] == '-') len -= 1;
    if (len == 0) {
        const untitled = "untitled";
        if (untitled.len > buf.len) return null;
        @memcpy(buf[0..untitled.len], untitled);
        return buf[0..untitled.len];
    }
    if (len > max_entity_id_bytes) return null;
    if (buf[0] == '/' or buf[len - 1] == '/') return null;
    return buf[0..len];
}

/// Sanitize a vault stem into a wiki-safe entity id: [A-Za-z0-9/_.-], no spaces.
pub fn sanitizeEntityId(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    var buf: [max_entity_id_bytes]u8 = undefined;
    const s = sanitizeEntityIdBuf(&buf, stem) orelse return error.IdTooLong;
    return try allocator.dupe(u8, s);
}

pub fn basenameStem(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') start = i + 1;
    }
    const base = path[start..];
    if (std.mem.endsWith(u8, base, ".md")) return base[0 .. base.len - 3];
    return base;
}

fn dirNameOf(path: []const u8) []const u8 {
    if (std.fs.path.dirname(path)) |d| return d;
    return "";
}

/// Relative path from a content page file to an assets file under out root.
/// page_out like "content/Notes/Alpha.md", asset_out like "assets/Attachments/diagram.png"
pub fn relativeLink(allocator: std.mem.Allocator, from_file: []const u8, to_file: []const u8) ![]u8 {
    const from_dir = dirNameOf(from_file);
    // Count depth of from_dir
    var ups: usize = 0;
    if (from_dir.len > 0) {
        ups = 1;
        for (from_dir) |c| {
            if (c == '/') ups += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var u: usize = 0;
    while (u < ups) : (u += 1) {
        if (u > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, "..");
    }
    if (ups > 0) try out.append(allocator, '/');
    try out.appendSlice(allocator, to_file);
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Frontmatter (compatible subset only)
// ---------------------------------------------------------------------------

const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

fn isBorisKey(key: []const u8) bool {
    for (boris_keys) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

pub const FrontmatterInfo = struct {
    present: bool = false,
    body_offset: usize = 0,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tags_raw: ?[]const u8 = null,
    id_override: ?[]const u8 = null,
    unknown_keys: []const []const u8 = &.{},
    incompatible: bool = false,
    notes: []const []const u8 = &.{},
};

fn trimSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Lightweight closed-grammar frontmatter extract. Does not mutate input.
pub fn parseFrontmatterLite(allocator: std.mem.Allocator, source: []const u8) !FrontmatterInfo {
    var info: FrontmatterInfo = .{};
    if (!std.mem.startsWith(u8, source, "---\n") and !std.mem.startsWith(u8, source, "---\r\n")) {
        return info;
    }
    const after_open: usize = if (std.mem.startsWith(u8, source, "---\r\n")) 5 else 4;
    var i = after_open;
    var fm_end: ?usize = null; // exclusive end of field region (start of closing fence)
    var body_off: ?usize = null;
    while (i < source.len) {
        const line_start = i;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        var line = source[line_start..i];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) {
            fm_end = line_start;
            body_off = if (i < source.len and source[i] == '\n') i + 1 else i;
            break;
        }
        if (i < source.len) i += 1;
    }
    if (fm_end == null or body_off == null) {
        info.present = true;
        info.incompatible = true;
        info.body_offset = 0;
        info.notes = try allocator.dupe([]const u8, &[_][]const u8{"unclosed frontmatter fence; body kept intact"});
        return info;
    }
    info.present = true;
    info.body_offset = body_off.?;

    var unknown: std.ArrayList([]const u8) = .empty;
    defer unknown.deinit(allocator);
    var notes: std.ArrayList([]const u8) = .empty;
    defer notes.deinit(allocator);

    var pos = after_open;
    const fields_end = fm_end.?;
    while (pos < fields_end) {
        const line_start = pos;
        while (pos < fields_end and source[pos] != '\n') : (pos += 1) {}
        var line = source[line_start..pos];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (pos < fields_end) pos += 1;
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t' or std.mem.startsWith(u8, line, "- ")) {
            info.incompatible = true;
            try notes.append(allocator, try allocator.dupe(u8, "nested YAML / sequence form in frontmatter"));
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            info.incompatible = true;
            try notes.append(allocator, try allocator.dupe(u8, "malformed frontmatter field"));
            continue;
        };
        const key = trimSpace(line[0..colon]);
        var value = trimSpace(line[colon + 1 ..]);
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (!isBorisKey(key)) {
            try unknown.append(allocator, try allocator.dupe(u8, key));
            continue;
        }
        if (std.mem.eql(u8, key, "title")) info.title = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "parent")) info.parent = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "status")) info.status = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, key, "tags")) {
            // only accept [ ... ] form
            if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
                info.tags_raw = try allocator.dupe(u8, value);
            } else {
                info.incompatible = true;
                try notes.append(allocator, try allocator.dupe(u8, "tags must be [a, b] form for Boris"));
            }
        }
        if (std.mem.eql(u8, key, "id")) info.id_override = try allocator.dupe(u8, value);
    }
    info.unknown_keys = try unknown.toOwnedSlice(allocator);
    info.notes = try notes.toOwnedSlice(allocator);
    return info;
}

pub fn escapeFmValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var need_quote = false;
    for (value) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '\'' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ' ' or c == '\t')
            need_quote = true;
    }
    if (!need_quote) return try allocator.dupe(u8, value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |c| {
        if (c == '"') continue; // strip embedded quotes rather than escape
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

pub fn buildFrontmatter(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    title: ?[]const u8,
    parent: ?[]const u8,
    status: ?[]const u8,
    tags_raw: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "---\n");
    if (id) |v| {
        const esc = try escapeFmValue(allocator, v);
        defer allocator.free(esc);
        try buf.appendSlice(allocator, "id: ");
        try buf.appendSlice(allocator, esc);
        try buf.append(allocator, '\n');
    }
    if (title) |v| {
        const esc = try escapeFmValue(allocator, v);
        defer allocator.free(esc);
        try buf.appendSlice(allocator, "title: ");
        try buf.appendSlice(allocator, esc);
        try buf.append(allocator, '\n');
    }
    if (parent) |v| {
        // parent must be entity id; sanitize display-ish values later by caller
        const esc = try escapeFmValue(allocator, v);
        defer allocator.free(esc);
        try buf.appendSlice(allocator, "parent: ");
        try buf.appendSlice(allocator, esc);
        try buf.append(allocator, '\n');
    }
    if (status) |v| {
        // only emit if closed status
        if (std.mem.eql(u8, v, "draft") or std.mem.eql(u8, v, "published") or std.mem.eql(u8, v, "archived")) {
            try buf.appendSlice(allocator, "status: ");
            try buf.appendSlice(allocator, v);
            try buf.append(allocator, '\n');
        }
    }
    if (tags_raw) |v| {
        try buf.appendSlice(allocator, "tags: ");
        try buf.appendSlice(allocator, v);
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "---\n");
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Hazard / plugin detection
// ---------------------------------------------------------------------------

pub const HazardKind = enum {
    dataview,
    dataviewjs,
    tasks_plugin,
    canvas,
    plugin_syntax,
    unknown_frontmatter_key,
    incompatible_frontmatter,
    heading_or_block_ref,
    ambiguous_link,
    unresolved_link,
    unsupported_embed,
    note_embed,

    pub fn jsonName(self: HazardKind) []const u8 {
        return switch (self) {
            .dataview => "dataview",
            .dataviewjs => "dataviewjs",
            .tasks_plugin => "tasks_plugin",
            .canvas => "canvas",
            .plugin_syntax => "plugin_syntax",
            .unknown_frontmatter_key => "unknown_frontmatter_key",
            .incompatible_frontmatter => "incompatible_frontmatter",
            .heading_or_block_ref => "heading_or_block_ref",
            .ambiguous_link => "ambiguous_link",
            .unresolved_link => "unresolved_link",
            .unsupported_embed => "unsupported_embed",
            .note_embed => "note_embed",
        };
    }
};

pub const Hazard = struct {
    kind: HazardKind,
    source_path: []const u8,
    detail: []const u8,
};

pub fn detectBodyHazards(allocator: std.mem.Allocator, source_path: []const u8, body: []const u8) ![]Hazard {
    var list: std.ArrayList(Hazard) = .empty;
    errdefer list.deinit(allocator);

    if (std.mem.indexOf(u8, body, "```dataviewjs") != null or std.mem.indexOf(u8, body, "``` dataviewjs") != null) {
        try list.append(allocator, .{
            .kind = .dataviewjs,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "dataviewjs fenced block (not evaluated)"),
        });
    }
    if (std.mem.indexOf(u8, body, "```dataview") != null or std.mem.indexOf(u8, body, "``` dataview") != null) {
        // avoid double-counting dataviewjs already covered — still report dataview if plain present
        if (std.mem.indexOf(u8, body, "```dataview\n") != null or
            std.mem.indexOf(u8, body, "```dataview\r") != null or
            std.mem.indexOf(u8, body, "``` dataview\n") != null or
            (std.mem.indexOf(u8, body, "```dataview") != null and std.mem.indexOf(u8, body, "```dataviewjs") == null))
        {
            try list.append(allocator, .{
                .kind = .dataview,
                .source_path = source_path,
                .detail = try allocator.dupe(u8, "dataview fenced block (not evaluated)"),
            });
        }
    }
    if (std.mem.indexOf(u8, body, "```tasks") != null or std.mem.indexOf(u8, body, "``` tasks") != null) {
        try list.append(allocator, .{
            .kind = .tasks_plugin,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "tasks plugin fenced block (not evaluated)"),
        });
    }
    if (std.mem.indexOf(u8, body, "$=") != null) {
        try list.append(allocator, .{
            .kind = .plugin_syntax,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "inline $= query syntax retained raw"),
        });
    }
    // Obsidian inline fields: word:: value (simple heuristic outside fences later not perfect)
    if (std.mem.indexOf(u8, body, ":: ") != null) {
        try list.append(allocator, .{
            .kind = .plugin_syntax,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, "possible inline field (key:: value) retained raw"),
        });
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Wiki / embed scanning (fence-aware)
// ---------------------------------------------------------------------------

pub const WikiHit = struct {
    is_embed: bool,
    raw_inner: []const u8, // inside [[...]] without bang
    target: []const u8, // before | and before #/^
    alias: ?[]const u8,
    fragment: ?[]const u8, // heading or ^block including marker shape
    has_heading_or_block: bool,
    has_size_param: bool, // embed width form image|400
    start: usize, // byte offset of '!' or first '['
    end: usize, // exclusive end after ]]
    in_fence: bool,
};

fn scanFenceMap(body: []const u8, allocator: std.mem.Allocator) ![]bool {
    const map = try allocator.alloc(bool, body.len);
    @memset(map, false);
    var i: usize = 0;
    var in_fence = false;
    while (i < body.len) {
        if (i + 2 < body.len and body[i] == '`' and body[i + 1] == '`' and body[i + 2] == '`') {
            // toggle fence at line-ish triple backtick
            in_fence = !in_fence;
            map[i] = in_fence;
            map[i + 1] = in_fence;
            map[i + 2] = in_fence;
            i += 3;
            continue;
        }
        map[i] = in_fence;
        i += 1;
    }
    return map;
}

pub fn scanWikiHits(allocator: std.mem.Allocator, body: []const u8) ![]WikiHit {
    const fence = try scanFenceMap(body, allocator);
    defer allocator.free(fence);

    var hits: std.ArrayList(WikiHit) = .empty;
    errdefer hits.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) {
        const is_embed = i + 3 < body.len and body[i] == '!' and body[i + 1] == '[' and body[i + 2] == '[';
        const is_link = i + 2 < body.len and body[i] == '[' and body[i + 1] == '[';
        if (!is_embed and !is_link) {
            i += 1;
            continue;
        }
        const start = i;
        const open_end = if (is_embed) i + 3 else i + 2;
        var j = open_end;
        while (j + 1 < body.len and !(body[j] == ']' and body[j + 1] == ']')) : (j += 1) {
            if (body[j] == '\n') break; // wiki links are single-line in practice
        }
        if (j + 1 >= body.len or body[j] != ']' or body[j + 1] != ']') {
            i = open_end;
            continue;
        }
        const inner = body[open_end..j];
        const end = j + 2;
        const in_fence = fence[start];

        var target = inner;
        var alias: ?[]const u8 = null;
        var fragment: ?[]const u8 = null;
        var has_hb = false;
        var has_size = false;

        if (std.mem.indexOfScalar(u8, inner, '|')) |pipe| {
            target = inner[0..pipe];
            const after = inner[pipe + 1 ..];
            // embed size: digits only after |
            var all_digit = after.len > 0;
            for (after) |c| {
                if (c < '0' or c > '9') {
                    all_digit = false;
                    break;
                }
            }
            if (is_embed and all_digit) {
                has_size = true;
                alias = null;
            } else {
                alias = after;
            }
        }
        // strip fragment from target
        if (std.mem.indexOfScalar(u8, target, '#')) |hash| {
            fragment = target[hash + 1 ..];
            target = target[0..hash];
            has_hb = true;
        }
        // block-only form rare; also target may include ^ in fragment already
        if (fragment) |f| {
            if (f.len > 0) has_hb = true;
        }

        target = trimSpace(target);
        if (alias) |a| alias = trimSpace(a);

        try hits.append(allocator, .{
            .is_embed = is_embed,
            .raw_inner = inner,
            .target = target,
            .alias = alias,
            .fragment = fragment,
            .has_heading_or_block = has_hb,
            .has_size_param = has_size,
            .start = start,
            .end = end,
            .in_fence = in_fence,
        });
        i = end;
    }
    return try hits.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Vault inventory
// ---------------------------------------------------------------------------

pub const VaultFileKind = enum { page, attachment, canvas, other };

pub const VaultFile = struct {
    rel_path: []const u8,
    kind: VaultFileKind,
};

fn collectFiles(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList(VaultFile),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = entry.name;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.eql(u8, name, ".DS_Store") or std.mem.eql(u8, name, "Thumbs.db")) continue;

        if (entry.kind == .directory) {
            if (isSkippedDirName(name)) continue;
            const rel = if (prefix.len == 0)
                try retain.dupe(u8, name)
            else
                try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, name });
            var child = try dir.openDir(io, name, .{ .iterate = true });
            defer child.close(io);
            try collectFiles(io, gpa, retain, child, rel, out);
            continue;
        }
        if (entry.kind != .file) continue;

        const rel = if (prefix.len == 0)
            try retain.dupe(u8, name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, name });

        const kind: VaultFileKind = if (isMarkdownPage(name))
            .page
        else if (isCanvasFile(name))
            .canvas
        else
            .attachment;
        try out.append(gpa, .{ .rel_path = rel, .kind = kind });
    }
}

// ---------------------------------------------------------------------------
// Resolution index
// ---------------------------------------------------------------------------

const PageEntry = struct {
    vault_path: []const u8, // vault-relative .md path
    vault_stem: []const u8, // without .md, original spaces
    entity_id: []const u8,
    output_path: []const u8, // content/{entity_id}.md
    basename: []const u8, // original basename stem
};

const AttachEntry = struct {
    vault_path: []const u8,
    output_path: []const u8, // assets/{vault_path sanitized lightly}
};

const ResolveResult = union(enum) {
    none,
    page: *const PageEntry,
    attachment: *const AttachEntry,
    ambiguous_pages: []const []const u8, // entity ids or paths
    ambiguous_attachments: []const []const u8,
};

const Index = struct {
    pages: []PageEntry,
    attachments: []AttachEntry,
    // basename (original) → list of page indices
    // built as maps of slices

    fn resolvePage(self: *const Index, target: []const u8) ResolveResult {
        const t = trimSpace(target);
        if (t.len == 0) return .none;
        // strip optional .md
        const t_stem = if (std.mem.endsWith(u8, t, ".md")) t[0 .. t.len - 3] else t;

        // 1. exact vault stem match (path form)
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.vault_stem, t_stem)) return .{ .page = p };
        }

        // 2. exact entity-id match
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.entity_id, t_stem)) return .{ .page = p };
        }

        // 3. sanitized target equals entity id (spaces/punct → wiki-safe form)
        var san_buf: [max_entity_id_bytes]u8 = undefined;
        const san = sanitizeEntityIdBuf(&san_buf, t_stem);
        if (san) |s| {
            if (!std.mem.eql(u8, s, t_stem)) {
                for (self.pages) |*p| {
                    if (std.mem.eql(u8, p.entity_id, s)) return .{ .page = p };
                }
            }
        }

        // 4. unique path-suffix on vault stem (Obsidian-style partial paths)
        {
            var matches: [32]*const PageEntry = undefined;
            const n = self.collectPathSuffixMatchesVault(t_stem, &matches);
            if (n == 1) return .{ .page = matches[0] };
            if (n > 1) return .none; // ambiguous; outer collect reports
        }

        // 5. unique path-suffix on entity id using sanitized target
        if (san) |s| {
            var matches: [32]*const PageEntry = undefined;
            const n = self.collectPathSuffixMatchesEntity(s, &matches);
            if (n == 1) return .{ .page = matches[0] };
            if (n > 1) return .none;
        }

        // 6. unique basename (full target as note name)
        {
            var matches: [32]*const PageEntry = undefined;
            const n = self.collectBasenameMatches(t_stem, &matches);
            if (n == 1) return .{ .page = matches[0] };
            if (n > 1) return .none;
        }

        // 7. unique last-segment basename when target has a path component
        if (std.mem.indexOfScalar(u8, t_stem, '/') != null) {
            const last = basenameStem(t_stem);
            if (last.len > 0 and !std.mem.eql(u8, last, t_stem)) {
                var matches: [32]*const PageEntry = undefined;
                var n: usize = 0;
                for (self.pages) |*p| {
                    if (std.mem.eql(u8, p.basename, last)) {
                        if (n < matches.len) {
                            matches[n] = p;
                            n += 1;
                        }
                    }
                }
                if (n == 1) return .{ .page = matches[0] };
            }
        }

        return .none;
    }

    fn collectPathSuffixMatchesVault(self: *const Index, t_stem: []const u8, buf: []*const PageEntry) usize {
        var n: usize = 0;
        for (self.pages) |*p| {
            if (pathSuffixMatch(p.vault_stem, t_stem)) {
                if (n < buf.len) {
                    buf[n] = p;
                    n += 1;
                }
            }
        }
        return n;
    }

    fn collectPathSuffixMatchesEntity(self: *const Index, entity_needle: []const u8, buf: []*const PageEntry) usize {
        var n: usize = 0;
        for (self.pages) |*p| {
            if (pathSuffixMatch(p.entity_id, entity_needle)) {
                if (n < buf.len) {
                    buf[n] = p;
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Basename matches: full target as basename, plus last path segment when present.
    fn collectBasenameMatches(self: *const Index, target: []const u8, buf: []*const PageEntry) usize {
        const t = trimSpace(target);
        const t_stem = if (std.mem.endsWith(u8, t, ".md")) t[0 .. t.len - 3] else t;
        var n: usize = 0;
        for (self.pages) |*p| {
            if (std.mem.eql(u8, p.basename, t_stem)) {
                if (n < buf.len) {
                    buf[n] = p;
                    n += 1;
                }
            }
        }
        if (n > 0) return n;
        // path form: try last segment only when no full-string basename hits
        if (std.mem.indexOfScalar(u8, t_stem, '/') != null) {
            const last = basenameStem(t_stem);
            if (last.len > 0) {
                for (self.pages) |*p| {
                    if (std.mem.eql(u8, p.basename, last)) {
                        if (n < buf.len) {
                            buf[n] = p;
                            n += 1;
                        }
                    }
                }
            }
        }
        return n;
    }

    /// All pages matching path-suffix strategies (for ambiguous reporting).
    fn collectPathSuffixMatches(self: *const Index, target: []const u8, buf: []*const PageEntry) usize {
        const t = trimSpace(target);
        const t_stem = if (std.mem.endsWith(u8, t, ".md")) t[0 .. t.len - 3] else t;
        var n = self.collectPathSuffixMatchesVault(t_stem, buf);
        if (n > 0) return n;
        var san_buf: [max_entity_id_bytes]u8 = undefined;
        if (sanitizeEntityIdBuf(&san_buf, t_stem)) |s| {
            n = self.collectPathSuffixMatchesEntity(s, buf);
        }
        return n;
    }

    fn resolveAttachment(self: *const Index, target: []const u8) ResolveResult {
        const t = trimSpace(target);
        if (t.len == 0) return .none;
        // exact vault path
        for (self.attachments) |*a| {
            if (std.mem.eql(u8, a.vault_path, t)) return .{ .attachment = a };
        }
        // basename match
        var matches: [32]*const AttachEntry = undefined;
        var n: usize = 0;
        const base = basenameStem(t);
        // for attachments basenameStem won't strip non-md; use last segment
        const want = blk: {
            var start: usize = 0;
            for (t, 0..) |c, i| {
                if (c == '/') start = i + 1;
            }
            break :blk t[start..];
        };
        _ = base;
        for (self.attachments) |*a| {
            var start: usize = 0;
            for (a.vault_path, 0..) |c, i| {
                if (c == '/') start = i + 1;
            }
            const ab = a.vault_path[start..];
            if (std.mem.eql(u8, ab, want) or std.mem.eql(u8, ab, t)) {
                if (n < matches.len) {
                    matches[n] = a;
                    n += 1;
                }
            }
        }
        if (n == 1) return .{ .attachment = matches[0] };
        if (n > 1) return .none;
        return .none;
    }

    fn collectAttachBasename(self: *const Index, target: []const u8, buf: []*const AttachEntry) usize {
        const t = trimSpace(target);
        var start: usize = 0;
        for (t, 0..) |c, i| {
            if (c == '/') start = i + 1;
        }
        const want = t[start..];
        var n: usize = 0;
        for (self.attachments) |*a| {
            if (std.mem.eql(u8, a.vault_path, t)) {
                if (n < buf.len) {
                    buf[n] = a;
                    n += 1;
                }
                continue;
            }
            var s2: usize = 0;
            for (a.vault_path, 0..) |c, i| {
                if (c == '/') s2 = i + 1;
            }
            if (std.mem.eql(u8, a.vault_path[s2..], want)) {
                if (n < buf.len) {
                    buf[n] = a;
                    n += 1;
                }
            }
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Link rewrite
// ---------------------------------------------------------------------------

pub const LinkFinding = struct {
    source_path: []const u8,
    raw: []const u8,
    target: []const u8,
    status: LinkStatus,
    resolved_to: ?[]const u8 = null,
    is_embed: bool = false,
    note: []const u8 = "",
};

fn isEntityIdChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '/' or c == '_' or c == '-' or c == '.';
}

fn entityIdIsWikiSafe(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| {
        if (!isEntityIdChar(c)) return false;
    }
    return true;
}

fn rewriteBody(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    body: []const u8,
    page: *const PageEntry,
    index: *const Index,
    findings: *std.ArrayList(LinkFinding),
    hazards: *std.ArrayList(Hazard),
    referenced_assets: *std.ArrayList([]const u8),
) !struct { []u8, ConversionClass } {
    const hits = try scanWikiHits(allocator, body);
    defer allocator.free(hits);

    if (hits.len == 0) {
        return .{ try allocator.dupe(u8, body), .exact };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var class: ConversionClass = .exact;
    var cursor: usize = 0;

    for (hits) |hit| {
        // copy prefix
        try out.appendSlice(allocator, body[cursor..hit.start]);
        cursor = hit.end;

        const raw_full = body[hit.start..hit.end];

        if (hit.in_fence) {
            try out.appendSlice(allocator, raw_full);
            try findings.append(allocator, .{
                .source_path = source_path,
                .raw = try allocator.dupe(u8, raw_full),
                .target = try allocator.dupe(u8, hit.target),
                .status = .skipped_fence,
                .is_embed = hit.is_embed,
                .note = "inside fenced code; left unchanged",
            });
            continue;
        }

        // Templater / JS template placeholders are not note targets
        if (isPluginTemplateWikiTarget(hit.target) or isPluginTemplateWikiTarget(raw_full)) {
            try out.appendSlice(allocator, raw_full);
            class = ConversionClass.worse(class, .human_review);
            try findings.append(allocator, .{
                .source_path = source_path,
                .raw = try allocator.dupe(u8, raw_full),
                .target = try allocator.dupe(u8, hit.target),
                .status = .plugin_template,
                .is_embed = hit.is_embed,
                .note = "plugin/template placeholder in wiki target; left raw",
            });
            try hazards.append(allocator, .{
                .kind = .plugin_syntax,
                .source_path = source_path,
                .detail = try allocator.dupe(u8, raw_full),
            });
            continue;
        }

        if (hit.has_heading_or_block) {
            try out.appendSlice(allocator, raw_full);
            class = ConversionClass.worse(class, .human_review);
            try findings.append(allocator, .{
                .source_path = source_path,
                .raw = try allocator.dupe(u8, raw_full),
                .target = try allocator.dupe(u8, hit.target),
                .status = .heading_or_block,
                .is_embed = hit.is_embed,
                .note = "heading or block reference not rewritten in phase-1",
            });
            try hazards.append(allocator, .{
                .kind = .heading_or_block_ref,
                .source_path = source_path,
                .detail = try allocator.dupe(u8, raw_full),
            });
            continue;
        }

        if (hit.has_size_param) {
            try out.appendSlice(allocator, raw_full);
            class = ConversionClass.worse(class, .human_review);
            try findings.append(allocator, .{
                .source_path = source_path,
                .raw = try allocator.dupe(u8, raw_full),
                .target = try allocator.dupe(u8, hit.target),
                .status = .unsupported_embed,
                .is_embed = true,
                .note = "embed size parameter not supported; left raw",
            });
            try hazards.append(allocator, .{
                .kind = .unsupported_embed,
                .source_path = source_path,
                .detail = try allocator.dupe(u8, raw_full),
            });
            continue;
        }

        // Try attachment first for embeds, then page; for links try page then attachment
        if (hit.is_embed) {
            var abuf: [32]*const AttachEntry = undefined;
            const an = index.collectAttachBasename(hit.target, &abuf);
            // also exact
            var attach: ?*const AttachEntry = null;
            if (an == 1) {
                attach = abuf[0];
            } else if (an == 0) {
                // exact path via resolve
                switch (index.resolveAttachment(hit.target)) {
                    .attachment => |a| attach = a,
                    else => {},
                }
            } else {
                try out.appendSlice(allocator, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try findings.append(allocator, .{
                    .source_path = source_path,
                    .raw = try allocator.dupe(u8, raw_full),
                    .target = try allocator.dupe(u8, hit.target),
                    .status = .ambiguous,
                    .is_embed = true,
                    .note = "ambiguous attachment target",
                });
                try hazards.append(allocator, .{
                    .kind = .ambiguous_link,
                    .source_path = source_path,
                    .detail = try allocator.dupe(u8, raw_full),
                });
                continue;
            }

            if (attach) |a| {
                // rewrite to markdown image or link
                const rel = try relativeLink(allocator, page.output_path, a.output_path);
                defer allocator.free(rel);
                const alt = blk: {
                    var s: usize = 0;
                    for (a.vault_path, 0..) |c, i| {
                        if (c == '/') s = i + 1;
                    }
                    break :blk a.vault_path[s..];
                };
                if (isImageExt(a.vault_path)) {
                    try out.appendSlice(allocator, "![");
                    try out.appendSlice(allocator, alt);
                    try out.appendSlice(allocator, "](");
                    try out.appendSlice(allocator, rel);
                    try out.appendSlice(allocator, ")");
                } else {
                    try out.appendSlice(allocator, "[");
                    try out.appendSlice(allocator, alt);
                    try out.appendSlice(allocator, "](");
                    try out.appendSlice(allocator, rel);
                    try out.appendSlice(allocator, ")");
                }
                class = ConversionClass.worse(class, .transformed);
                try findings.append(allocator, .{
                    .source_path = source_path,
                    .raw = try allocator.dupe(u8, raw_full),
                    .target = try allocator.dupe(u8, hit.target),
                    .status = .resolved,
                    .resolved_to = try allocator.dupe(u8, a.output_path),
                    .is_embed = true,
                    .note = "embed rewritten to Markdown link/image",
                });
                try referenced_assets.append(allocator, a.vault_path);
                continue;
            }

            // try note embed
            var pbuf: [32]*const PageEntry = undefined;
            var page_target: ?*const PageEntry = null;
            switch (index.resolvePage(hit.target)) {
                .page => |p| page_target = p,
                else => {},
            }
            var pn: usize = 0;
            if (page_target == null) {
                pn = index.collectBasenameMatches(hit.target, &pbuf);
                if (pn == 0) pn = index.collectPathSuffixMatches(hit.target, &pbuf);
            }
            if (page_target == null and pn == 1) page_target = pbuf[0];
            if (page_target == null and pn > 1) {
                try out.appendSlice(allocator, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try findings.append(allocator, .{
                    .source_path = source_path,
                    .raw = try allocator.dupe(u8, raw_full),
                    .target = try allocator.dupe(u8, hit.target),
                    .status = .ambiguous,
                    .is_embed = true,
                    .note = "ambiguous note embed target",
                });
                try hazards.append(allocator, .{
                    .kind = .ambiguous_link,
                    .source_path = source_path,
                    .detail = try allocator.dupe(u8, raw_full),
                });
                continue;
            }
            if (page_target) |pt| {
                // flatten note embed to wiki link
                if (!entityIdIsWikiSafe(pt.entity_id)) {
                    try out.appendSlice(allocator, raw_full);
                    class = ConversionClass.worse(class, .human_review);
                    try findings.append(allocator, .{
                        .source_path = source_path,
                        .raw = try allocator.dupe(u8, raw_full),
                        .target = try allocator.dupe(u8, hit.target),
                        .status = .unsupported_embed,
                        .is_embed = true,
                        .note = "resolved note id not wiki-safe; left raw",
                    });
                    continue;
                }
                try out.appendSlice(allocator, "[[");
                try out.appendSlice(allocator, pt.entity_id);
                try out.appendSlice(allocator, "]]");
                class = ConversionClass.worse(class, .transformed);
                try findings.append(allocator, .{
                    .source_path = source_path,
                    .raw = try allocator.dupe(u8, raw_full),
                    .target = try allocator.dupe(u8, hit.target),
                    .status = .resolved,
                    .resolved_to = try allocator.dupe(u8, pt.entity_id),
                    .is_embed = true,
                    .note = "note embed flattened to wiki link (no live embed)",
                });
                try hazards.append(allocator, .{
                    .kind = .note_embed,
                    .source_path = source_path,
                    .detail = try std.fmt.allocPrint(allocator, "{s} → [[{s}]]", .{ raw_full, pt.entity_id }),
                });
                continue;
            }

            // unresolved embed
            try out.appendSlice(allocator, raw_full);
            class = ConversionClass.worse(class, .human_review);
            try findings.append(allocator, .{
                .source_path = source_path,
                .raw = try allocator.dupe(u8, raw_full),
                .target = try allocator.dupe(u8, hit.target),
                .status = .unresolved,
                .is_embed = true,
                .note = "unresolved embed target; left raw",
            });
            try hazards.append(allocator, .{
                .kind = .unresolved_link,
                .source_path = source_path,
                .detail = try allocator.dupe(u8, raw_full),
            });
            continue;
        }

        // ordinary wiki link (non-embed)
        var pbuf: [32]*const PageEntry = undefined;
        var page_target: ?*const PageEntry = null;
        // exact / path / suffix / basename
        switch (index.resolvePage(hit.target)) {
            .page => |p| page_target = p,
            else => {},
        }
        if (page_target == null) {
            var pn = index.collectBasenameMatches(hit.target, &pbuf);
            if (pn == 0) pn = index.collectPathSuffixMatches(hit.target, &pbuf);
            if (pn == 1) {
                page_target = pbuf[0];
            } else if (pn > 1) {
                try out.appendSlice(allocator, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try findings.append(allocator, .{
                    .source_path = source_path,
                    .raw = try allocator.dupe(u8, raw_full),
                    .target = try allocator.dupe(u8, hit.target),
                    .status = .ambiguous,
                    .note = "ambiguous note target",
                });
                try hazards.append(allocator, .{
                    .kind = .ambiguous_link,
                    .source_path = source_path,
                    .detail = try allocator.dupe(u8, raw_full),
                });
                continue;
            }
        }

        if (page_target) |pt| {
            if (!entityIdIsWikiSafe(pt.entity_id)) {
                try out.appendSlice(allocator, raw_full);
                class = ConversionClass.worse(class, .human_review);
                try findings.append(allocator, .{
                    .source_path = source_path,
                    .raw = try allocator.dupe(u8, raw_full),
                    .target = try allocator.dupe(u8, hit.target),
                    .status = .unresolved,
                    .note = "mapped entity id not wiki-safe; left raw",
                });
                continue;
            }
            try out.appendSlice(allocator, "[[");
            try out.appendSlice(allocator, pt.entity_id);
            if (hit.alias) |al| {
                try out.append(allocator, '|');
                try out.appendSlice(allocator, al);
            } else if (!std.mem.eql(u8, hit.target, pt.entity_id)) {
                // preserve human display of original target when it differs
                try out.append(allocator, '|');
                try out.appendSlice(allocator, hit.target);
            }
            try out.appendSlice(allocator, "]]");
            class = ConversionClass.worse(class, .transformed);
            try findings.append(allocator, .{
                .source_path = source_path,
                .raw = try allocator.dupe(u8, raw_full),
                .target = try allocator.dupe(u8, hit.target),
                .status = .resolved,
                .resolved_to = try allocator.dupe(u8, pt.entity_id),
                .note = "wiki link rewritten to entity id",
            });
            continue;
        }

        // unresolved
        try out.appendSlice(allocator, raw_full);
        class = ConversionClass.worse(class, .human_review);
        try findings.append(allocator, .{
            .source_path = source_path,
            .raw = try allocator.dupe(u8, raw_full),
            .target = try allocator.dupe(u8, hit.target),
            .status = .unresolved,
            .note = "unresolved note target; left raw",
        });
        try hazards.append(allocator, .{
            .kind = .unresolved_link,
            .source_path = source_path,
            .detail = try allocator.dupe(u8, raw_full),
        });
    }

    try out.appendSlice(allocator, body[cursor..]);
    return .{ try out.toOwnedSlice(allocator), class };
}

// ---------------------------------------------------------------------------
// Report model + emit
// ---------------------------------------------------------------------------

pub const PageRecord = struct {
    source_path: []const u8,
    entity_id: []const u8,
    output_path: []const u8,
    title: []const u8,
    conversion: ConversionClass,
    notes: []const []const u8,
};

pub const AttachmentManifestEntry = struct {
    source_path: []const u8,
    output_path: []const u8,
    referenced: bool,
    copied: bool,
};

pub const UnsupportedItem = struct {
    source_path: []const u8,
    kind: []const u8,
    detail: []const u8,
};

pub const HumanReview = struct {
    source_path: []const u8,
    reason: []const u8,
    detail: []const u8,
};

pub const Report = struct {
    source_vault: []const u8,
    pages: []PageRecord,
    links: []LinkFinding,
    hazards: []Hazard,
    attachments: []AttachmentManifestEntry,
    unsupported_items: []UnsupportedItem,
    human_review: []HumanReview,
    summary_pages: usize,
    summary_attachments: usize,
    summary_links_resolved: usize,
    summary_links_unresolved: usize,
    summary_links_ambiguous: usize,
    summary_heading_block: usize,
};

fn jsonEscapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(gpa, "\\u00");
                    const hex = "0123456789abcdef";
                    try buf.append(gpa, hex[c >> 4]);
                    try buf.append(gpa, hex[c & 0xf]);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

fn emitReportJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try buf.appendSlice(gpa, "  \"format\": \"");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "\",\n");
    try buf.appendSlice(gpa, "  \"schema_version\": 1,\n");
    try buf.appendSlice(gpa, "  \"tool_version\": \"");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "\",\n");
    try buf.appendSlice(gpa, "  \"source_vault\": ");
    try jsonEscapeAppend(&buf, gpa, report.source_vault);
    try buf.appendSlice(gpa, ",\n");

    try buf.appendSlice(gpa, "  \"summary\": {\n");
    try appendUsizeField(&buf, gpa, "pages", report.summary_pages, true);
    try appendUsizeField(&buf, gpa, "attachments", report.summary_attachments, true);
    try appendUsizeField(&buf, gpa, "links_resolved", report.summary_links_resolved, true);
    try appendUsizeField(&buf, gpa, "links_unresolved", report.summary_links_unresolved, true);
    try appendUsizeField(&buf, gpa, "links_ambiguous", report.summary_links_ambiguous, true);
    try appendUsizeField(&buf, gpa, "heading_or_block_refs", report.summary_heading_block, false);
    try buf.appendSlice(gpa, "\n  },\n");

    try buf.appendSlice(gpa, "  \"pages\": [\n");
    for (report.pages, 0..) |p, i| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ",\n      \"entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.entity_id);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.output_path);
        try buf.appendSlice(gpa, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n      \"conversion\": \"");
        try buf.appendSlice(gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, "\",\n      \"notes\": [");
        for (p.notes, 0..) |n, ni| {
            if (ni > 0) try buf.appendSlice(gpa, ", ");
            try jsonEscapeAppend(&buf, gpa, n);
        }
        try buf.appendSlice(gpa, "]\n    }");
        if (i + 1 < report.pages.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"links\": [\n");
    for (report.links, 0..) |l, i| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, l.source_path);
        try buf.appendSlice(gpa, ",\n      \"raw\": ");
        try jsonEscapeAppend(&buf, gpa, l.raw);
        try buf.appendSlice(gpa, ",\n      \"target\": ");
        try jsonEscapeAppend(&buf, gpa, l.target);
        try buf.appendSlice(gpa, ",\n      \"status\": \"");
        try buf.appendSlice(gpa, l.status.jsonName());
        try buf.appendSlice(gpa, "\",\n      \"is_embed\": ");
        try buf.appendSlice(gpa, if (l.is_embed) "true" else "false");
        try buf.appendSlice(gpa, ",\n      \"resolved_to\": ");
        if (l.resolved_to) |r| {
            try jsonEscapeAppend(&buf, gpa, r);
        } else {
            try buf.appendSlice(gpa, "null");
        }
        try buf.appendSlice(gpa, ",\n      \"note\": ");
        try jsonEscapeAppend(&buf, gpa, l.note);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.links.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"hazards\": [\n");
    for (report.hazards, 0..) |h, i| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"kind\": \"");
        try buf.appendSlice(gpa, h.kind.jsonName());
        try buf.appendSlice(gpa, "\",\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, h.source_path);
        try buf.appendSlice(gpa, ",\n      \"detail\": ");
        try jsonEscapeAppend(&buf, gpa, h.detail);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.hazards.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"attachments\": [\n");
    for (report.attachments, 0..) |a, i| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.source_path);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.output_path);
        try buf.appendSlice(gpa, ",\n      \"referenced\": ");
        try buf.appendSlice(gpa, if (a.referenced) "true" else "false");
        try buf.appendSlice(gpa, ",\n      \"copied\": ");
        try buf.appendSlice(gpa, if (a.copied) "true" else "false");
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.attachments.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"unsupported_items\": [\n");
    for (report.unsupported_items, 0..) |u, i| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, u.source_path);
        try buf.appendSlice(gpa, ",\n      \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, u.kind);
        try buf.appendSlice(gpa, ",\n      \"detail\": ");
        try jsonEscapeAppend(&buf, gpa, u.detail);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.unsupported_items.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    try buf.appendSlice(gpa, "  \"human_review\": [\n");
    for (report.human_review, 0..) |hr, i| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, hr.source_path);
        try buf.appendSlice(gpa, ",\n      \"reason\": ");
        try jsonEscapeAppend(&buf, gpa, hr.reason);
        try buf.appendSlice(gpa, ",\n      \"detail\": ");
        try jsonEscapeAppend(&buf, gpa, hr.detail);
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < report.human_review.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n");
    try buf.appendSlice(gpa, "}\n");
    return try buf.toOwnedSlice(gpa);
}

fn appendUsizeField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, value: usize, trailing_comma: bool) !void {
    try buf.appendSlice(gpa, "    \"");
    try buf.appendSlice(gpa, name);
    try buf.appendSlice(gpa, "\": ");
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{value});
    try buf.appendSlice(gpa, s);
    if (trailing_comma) try buf.append(gpa, ',');
    try buf.append(gpa, '\n');
}

fn emitReportMd(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "# Obsidian → Boris migration laboratory\n\n");
    try buf.appendSlice(gpa, "Format: `");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "` · schema ");
    var tmp: [16]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{schema_version}));
    try buf.appendSlice(gpa, " · tool ");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "\n\n");
    try buf.appendSlice(gpa, "Source vault: `");
    try buf.appendSlice(gpa, report.source_vault);
    try buf.appendSlice(gpa, "`\n\n");

    try buf.appendSlice(gpa, "## Summary\n\n");
    try buf.appendSlice(gpa, "| Metric | Count |\n|---|---:|\n");
    try appendMdCount(&buf, gpa, "Pages", report.summary_pages);
    try appendMdCount(&buf, gpa, "Attachments inventoried", report.summary_attachments);
    try appendMdCount(&buf, gpa, "Links resolved", report.summary_links_resolved);
    try appendMdCount(&buf, gpa, "Links unresolved", report.summary_links_unresolved);
    try appendMdCount(&buf, gpa, "Links ambiguous", report.summary_links_ambiguous);
    try appendMdCount(&buf, gpa, "Heading/block refs", report.summary_heading_block);
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Pages\n\n");
    for (report.pages) |p| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, p.source_path);
        try buf.appendSlice(gpa, "` → `");
        try buf.appendSlice(gpa, p.entity_id);
        try buf.appendSlice(gpa, "` (");
        try buf.appendSlice(gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, ")\n");
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Links\n\n");
    for (report.links) |l| {
        if (l.status == .skipped_fence) continue;
        try buf.appendSlice(gpa, "- [");
        try buf.appendSlice(gpa, l.status.jsonName());
        try buf.appendSlice(gpa, "] `");
        try buf.appendSlice(gpa, l.source_path);
        try buf.appendSlice(gpa, "`: `");
        try buf.appendSlice(gpa, l.raw);
        try buf.appendSlice(gpa, "`");
        if (l.resolved_to) |r| {
            try buf.appendSlice(gpa, " → `");
            try buf.appendSlice(gpa, r);
            try buf.appendSlice(gpa, "`");
        }
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Hazards (Dataview / Canvas / plugins / review)\n\n");
    if (report.hazards.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.hazards) |h| {
            try buf.appendSlice(gpa, "- **");
            try buf.appendSlice(gpa, h.kind.jsonName());
            try buf.appendSlice(gpa, "** in `");
            try buf.appendSlice(gpa, h.source_path);
            try buf.appendSlice(gpa, "`: ");
            try buf.appendSlice(gpa, h.detail);
            try buf.append(gpa, '\n');
        }
        try buf.append(gpa, '\n');
    }

    try buf.appendSlice(gpa, "## Unsupported items\n\n");
    for (report.unsupported_items) |u| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, u.source_path);
        try buf.appendSlice(gpa, "` (");
        try buf.appendSlice(gpa, u.kind);
        try buf.appendSlice(gpa, "): ");
        try buf.appendSlice(gpa, u.detail);
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Human review queue\n\n");
    for (report.human_review) |hr| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, hr.source_path);
        try buf.appendSlice(gpa, "` — ");
        try buf.appendSlice(gpa, hr.reason);
        try buf.appendSlice(gpa, ": ");
        try buf.appendSlice(gpa, hr.detail);
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "## Attachments\n\n");
    for (report.attachments) |a| {
        try buf.appendSlice(gpa, "- `");
        try buf.appendSlice(gpa, a.source_path);
        try buf.appendSlice(gpa, "` → `");
        try buf.appendSlice(gpa, a.output_path);
        try buf.appendSlice(gpa, "`");
        if (a.copied) try buf.appendSlice(gpa, " (copied)");
        if (a.referenced) try buf.appendSlice(gpa, " (referenced)");
        try buf.append(gpa, '\n');
    }
    try buf.append(gpa, '\n');

    try buf.appendSlice(gpa, "---\n\nPhase-1 boundaries: no Dataview/Canvas/plugin evaluation; ");
    try buf.appendSlice(gpa, "heading/block refs left raw; ambiguous/unresolved links left raw; vault never modified.\n");
    return try buf.toOwnedSlice(gpa);
}

fn appendMdCount(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, label: []const u8, n: usize) !void {
    try buf.appendSlice(gpa, "| ");
    try buf.appendSlice(gpa, label);
    try buf.appendSlice(gpa, " | ");
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
    try buf.appendSlice(gpa, " |\n");
}

fn emitAttachmentsManifest(gpa: std.mem.Allocator, entries: []const AttachmentManifestEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n  \"format\": \"boris-obsidian-attachments-manifest\",\n  \"schema_version\": 1,\n  \"entries\": [\n");
    for (entries, 0..) |a, i| {
        try buf.appendSlice(gpa, "    {\n      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.source_path);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, a.output_path);
        try buf.appendSlice(gpa, ",\n      \"referenced\": ");
        try buf.appendSlice(gpa, if (a.referenced) "true" else "false");
        try buf.appendSlice(gpa, ",\n      \"copied\": ");
        try buf.appendSlice(gpa, if (a.copied) "true" else "false");
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < entries.len) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
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

fn copyFileRel(io: Io, src_root: Io.Dir, src_rel: []const u8, dst_root: Io.Dir, dst_rel: []const u8) !void {
    const data = try readFileAlloc(io, src_root, src_rel, std.heap.page_allocator);
    defer std.heap.page_allocator.free(data);
    try writeBytes(io, dst_root, dst_rel, data);
}

fn buildProvenanceComment(allocator: std.mem.Allocator, source_path: []const u8, entity_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\<!-- boris-migration-provenance
        \\  format: {s}
        \\  source_path: {s}
        \\  entity_id: {s}
        \\  tool_version: {s}
        \\-->
        \\
    , .{ format_id, source_path, entity_id, tool_version });
}

/// Sanitize attachment vault path for output under assets/ (keep structure; spaces→-).
fn attachmentOutputPath(allocator: std.mem.Allocator, vault_path: []const u8) ![]u8 {
    const sanitized = try sanitizeEntityId(allocator, vault_path);
    defer allocator.free(sanitized);
    // sanitizeEntityId may strip extension dots incorrectly if last segment has dots — dots are allowed
    return try std.fmt.allocPrint(allocator, "assets/{s}", .{sanitized});
}

/// When multiple vault notes map to the same entity id, keep the first (by
/// vault_path order within the group) and assign `-2`, `-3`, … to the rest so
/// output paths never clobber each other. Records each collision in `unsupported`.
fn disambiguateEntityIdCollisions(
    retain: std.mem.Allocator,
    pages: []PageEntry,
    unsupported: *std.ArrayList(UnsupportedItem),
) !void {
    if (pages.len < 2) return;

    const order = try retain.alloc(usize, pages.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, pages, struct {
        fn less(ps: []PageEntry, a: usize, b: usize) bool {
            const c = std.mem.order(u8, ps[a].entity_id, ps[b].entity_id);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, ps[a].vault_path, ps[b].vault_path) == .lt;
        }
    }.less);

    var i: usize = 0;
    while (i < order.len) {
        const base_id = pages[order[i]].entity_id;
        var j = i + 1;
        while (j < order.len and std.mem.eql(u8, pages[order[j]].entity_id, base_id)) : (j += 1) {}
        if (j - i > 1) {
            var suffix: usize = 2;
            var k: usize = i + 1;
            while (k < j) : (k += 1) {
                const idx = order[k];
                const original = pages[idx].entity_id;
                const new_id = try allocUniqueEntityId(retain, pages, original, &suffix);
                try unsupported.append(retain, .{
                    .source_path = pages[idx].vault_path,
                    .kind = "entity_id_collision",
                    .detail = try std.fmt.allocPrint(retain, "collides with {s} → {s}; remapped to {s}", .{
                        pages[order[i]].vault_path,
                        original,
                        new_id,
                    }),
                });
                pages[idx].entity_id = new_id;
                pages[idx].output_path = try std.fmt.allocPrint(retain, "content/{s}.md", .{new_id});
            }
        }
        i = j;
    }
}

fn entityIdTaken(pages: []const PageEntry, id: []const u8) bool {
    for (pages) |p| {
        if (std.mem.eql(u8, p.entity_id, id)) return true;
    }
    return false;
}

fn allocUniqueEntityId(
    retain: std.mem.Allocator,
    pages: []const PageEntry,
    base: []const u8,
    suffix: *usize,
) ![]u8 {
    while (suffix.* < 10_000) : (suffix.* += 1) {
        const candidate = try std.fmt.allocPrint(retain, "{s}-{d}", .{ base, suffix.* });
        if (!entityIdTaken(pages, candidate)) {
            suffix.* += 1;
            return candidate;
        }
    }
    return error.IdTooLong;
}

// ---------------------------------------------------------------------------
// Main pipeline
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const retain = arena_state.allocator();

    if (std.mem.eql(u8, opts.vault_dir, opts.out_dir)) return error.OutEqualsVault;

    var vault = try Io.Dir.cwd().openDir(io, opts.vault_dir, .{ .iterate = true });
    defer vault.close(io);

    var files: std.ArrayList(VaultFile) = .empty;
    defer files.deinit(gpa);
    try collectFiles(io, gpa, retain, vault, "", &files);

    // Sort files for determinism
    std.mem.sort(VaultFile, files.items, {}, struct {
        fn less(_: void, a: VaultFile, b: VaultFile) bool {
            return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
        }
    }.less);

    var pages_list: std.ArrayList(PageEntry) = .empty;
    // pages/attachments lists live in the retain arena
    var attach_list: std.ArrayList(AttachEntry) = .empty;
    var unsupported: std.ArrayList(UnsupportedItem) = .empty;

    for (files.items) |f| {
        switch (f.kind) {
            .page => {
                const entity_id = try pathToEntityId(retain, f.rel_path);
                const vault_stem = if (std.mem.endsWith(u8, f.rel_path, ".md"))
                    f.rel_path[0 .. f.rel_path.len - 3]
                else
                    f.rel_path;
                const output_path = try std.fmt.allocPrint(retain, "content/{s}.md", .{entity_id});
                try pages_list.append(retain, .{
                    .vault_path = f.rel_path,
                    .vault_stem = try retain.dupe(u8, vault_stem),
                    .entity_id = entity_id,
                    .output_path = output_path,
                    .basename = try retain.dupe(u8, basenameStem(f.rel_path)),
                });
            },
            .attachment => {
                const outp = try attachmentOutputPath(retain, f.rel_path);
                try attach_list.append(retain, .{
                    .vault_path = f.rel_path,
                    .output_path = outp,
                });
            },
            .canvas => {
                try unsupported.append(retain, .{
                    .source_path = f.rel_path,
                    .kind = "canvas",
                    .detail = "Obsidian Canvas is not converted in phase-1; inventoried only",
                });
            },
            .other => {
                try unsupported.append(retain, .{
                    .source_path = f.rel_path,
                    .kind = "other",
                    .detail = "non-page file not classified as attachment",
                });
            },
        }
    }

    // Collision-safe entity ids: same sanitized path → unique -2, -3, … suffixes.
    // Deterministic: groups ordered by entity_id then vault_path; first keeps base id.
    try disambiguateEntityIdCollisions(retain, pages_list.items, &unsupported);

    std.mem.sort(PageEntry, pages_list.items, {}, struct {
        fn less(_: void, a: PageEntry, b: PageEntry) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);
    std.mem.sort(AttachEntry, attach_list.items, {}, struct {
        fn less(_: void, a: AttachEntry, b: AttachEntry) bool {
            return std.mem.order(u8, a.vault_path, b.vault_path) == .lt;
        }
    }.less);

    const index = Index{
        .pages = pages_list.items,
        .attachments = attach_list.items,
    };

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out_root = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out_root.close(io);

    var page_records: std.ArrayList(PageRecord) = .empty;
    var all_links: std.ArrayList(LinkFinding) = .empty;
    var all_hazards: std.ArrayList(Hazard) = .empty;
    var human_review: std.ArrayList(HumanReview) = .empty;
    var referenced: std.ArrayList([]const u8) = .empty;

    // Map parent display names → entity ids when possible (for FM parent field)
    // Build basename map for parent rewrite
    for (index.pages) |*page| {
        const raw = try readFileAlloc(io, vault, page.vault_path, gpa);
        defer gpa.free(raw);

        const fm = try parseFrontmatterLite(retain, raw);
        const body_src = if (fm.present and fm.body_offset <= raw.len) raw[fm.body_offset..] else raw;

        var notes: std.ArrayList([]const u8) = .empty;
        // notes retained
        var class: ConversionClass = .exact;

        for (fm.unknown_keys) |uk| {
            class = ConversionClass.worse(class, .human_review);
            try notes.append(retain, try std.fmt.allocPrint(retain, "dropped unknown frontmatter key: {s}", .{uk}));
            try all_hazards.append(retain, .{
                .kind = .unknown_frontmatter_key,
                .source_path = page.vault_path,
                .detail = try std.fmt.allocPrint(retain, "key `{s}` not in Boris closed grammar", .{uk}),
            });
            try human_review.append(retain, .{
                .source_path = page.vault_path,
                .reason = "unknown_frontmatter_key",
                .detail = uk,
            });
        }
        if (fm.incompatible) {
            class = ConversionClass.worse(class, .human_review);
            try notes.append(retain, "incompatible frontmatter forms stripped or reported");
            try all_hazards.append(retain, .{
                .kind = .incompatible_frontmatter,
                .source_path = page.vault_path,
                .detail = "nested or non-closed frontmatter constructs",
            });
        }
        for (fm.notes) |n| try notes.append(retain, n);

        const body_hazards = try detectBodyHazards(retain, page.vault_path, body_src);
        for (body_hazards) |h| {
            class = ConversionClass.worse(class, .unsupported);
            try all_hazards.append(retain, h);
            try human_review.append(retain, .{
                .source_path = page.vault_path,
                .reason = h.kind.jsonName(),
                .detail = h.detail,
            });
            try notes.append(retain, try std.fmt.allocPrint(retain, "hazard: {s}", .{h.kind.jsonName()}));
        }

        var page_links: std.ArrayList(LinkFinding) = .empty;
        const rewritten = try rewriteBody(retain, page.vault_path, body_src, page, &index, &page_links, &all_hazards, &referenced);
        class = ConversionClass.worse(class, rewritten[1]);
        const new_body = rewritten[0];

        for (page_links.items) |lf| {
            try all_links.append(retain, lf);
            if (lf.status == .unresolved or lf.status == .ambiguous or lf.status == .heading_or_block or lf.status == .unsupported_embed or lf.status == .plugin_template) {
                try human_review.append(retain, .{
                    .source_path = page.vault_path,
                    .reason = lf.status.jsonName(),
                    .detail = lf.raw,
                });
            }
        }

        // Resolve parent field if present: map note name → entity id when unique
        var parent_out: ?[]const u8 = null;
        if (fm.parent) |par| {
            // if already looks like entity id of a page, keep; else resolve
            var resolved: ?[]const u8 = null;
            for (index.pages) |*p| {
                if (std.mem.eql(u8, p.entity_id, par) or std.mem.eql(u8, p.vault_stem, par) or std.mem.eql(u8, p.basename, par)) {
                    if (resolved != null and !std.mem.eql(u8, resolved.?, p.entity_id)) {
                        resolved = null;
                        class = ConversionClass.worse(class, .human_review);
                        try notes.append(retain, try std.fmt.allocPrint(retain, "ambiguous parent `{s}`; omitted", .{par}));
                        try human_review.append(retain, .{
                            .source_path = page.vault_path,
                            .reason = "ambiguous_parent",
                            .detail = par,
                        });
                        break;
                    }
                    resolved = p.entity_id;
                }
            }
            if (resolved) |r| {
                parent_out = r;
                if (!std.mem.eql(u8, r, par)) {
                    class = ConversionClass.worse(class, .transformed);
                    try notes.append(retain, try std.fmt.allocPrint(retain, "parent `{s}` → `{s}`", .{ par, r }));
                }
            } else if (fm.parent != null and parent_out == null) {
                // leave as sanitized if wiki-safe else drop
                if (entityIdIsWikiSafe(par)) {
                    parent_out = par;
                } else {
                    class = ConversionClass.worse(class, .human_review);
                    try notes.append(retain, try std.fmt.allocPrint(retain, "unresolved parent `{s}`; omitted", .{par}));
                    try human_review.append(retain, .{
                        .source_path = page.vault_path,
                        .reason = "unresolved_parent",
                        .detail = par,
                    });
                }
            }
        }

        const title = fm.title orelse basenameStem(page.vault_path);
        const fm_out = try buildFrontmatter(retain, null, title, parent_out, fm.status, fm.tags_raw);
        const prov = try buildProvenanceComment(retain, page.vault_path, page.entity_id);

        var md: std.ArrayList(u8) = .empty;
        try md.appendSlice(retain, fm_out);
        try md.appendSlice(retain, prov);
        try md.appendSlice(retain, new_body);
        // ensure trailing newline
        if (md.items.len == 0 or md.items[md.items.len - 1] != '\n') try md.append(retain, '\n');

        try writeBytes(io, out_root, page.output_path, md.items);

        if (class != .exact) {
            // already noted
        }

        try page_records.append(retain, .{
            .source_path = page.vault_path,
            .entity_id = page.entity_id,
            .output_path = page.output_path,
            .title = title,
            .conversion = class,
            .notes = try notes.toOwnedSlice(retain),
        });
    }

    // Sort page records / links / hazards for determinism
    std.mem.sort(PageRecord, page_records.items, {}, struct {
        fn less(_: void, a: PageRecord, b: PageRecord) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);
    std.mem.sort(LinkFinding, all_links.items, {}, struct {
        fn less(_: void, a: LinkFinding, b: LinkFinding) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.raw, b.raw) == .lt;
        }
    }.less);
    std.mem.sort(Hazard, all_hazards.items, {}, struct {
        fn less(_: void, a: Hazard, b: Hazard) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const k = std.mem.order(u8, a.kind.jsonName(), b.kind.jsonName());
            if (k != .eq) return k == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
    std.mem.sort(HumanReview, human_review.items, {}, struct {
        fn less(_: void, a: HumanReview, b: HumanReview) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const r = std.mem.order(u8, a.reason, b.reason);
            if (r != .eq) return r == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
    std.mem.sort(UnsupportedItem, unsupported.items, {}, struct {
        fn less(_: void, a: UnsupportedItem, b: UnsupportedItem) bool {
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    // Attachments: copy all inventoried (deterministic inventory); mark referenced
    var attach_manifest: std.ArrayList(AttachmentManifestEntry) = .empty;

    for (index.attachments) |a| {
        var is_ref = false;
        for (referenced.items) |r| {
            if (std.mem.eql(u8, r, a.vault_path)) {
                is_ref = true;
                break;
            }
        }
        const copy_ok = blk: {
            copyFileRel(io, vault, a.vault_path, out_root, a.output_path) catch break :blk false;
            break :blk true;
        };
        if (!copy_ok) {
            try human_review.append(retain, .{
                .source_path = a.vault_path,
                .reason = "attachment_copy_failed",
                .detail = a.output_path,
            });
        }
        try attach_manifest.append(retain, .{
            .source_path = a.vault_path,
            .output_path = a.output_path,
            .referenced = is_ref,
            .copied = copy_ok,
        });
    }

    // Canvas already in unsupported; also add hazard
    for (unsupported.items) |u| {
        if (std.mem.eql(u8, u.kind, "canvas")) {
            try all_hazards.append(retain, .{
                .kind = .canvas,
                .source_path = u.source_path,
                .detail = u.detail,
            });
            try human_review.append(retain, .{
                .source_path = u.source_path,
                .reason = "canvas",
                .detail = u.detail,
            });
        }
    }
    // re-sort hazards and human_review after canvas append
    std.mem.sort(Hazard, all_hazards.items, {}, struct {
        fn less(_: void, a: Hazard, b: Hazard) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const k = std.mem.order(u8, a.kind.jsonName(), b.kind.jsonName());
            if (k != .eq) return k == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
    std.mem.sort(HumanReview, human_review.items, {}, struct {
        fn less(_: void, a: HumanReview, b: HumanReview) bool {
            const o = std.mem.order(u8, a.source_path, b.source_path);
            if (o != .eq) return o == .lt;
            const r = std.mem.order(u8, a.reason, b.reason);
            if (r != .eq) return r == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);

    var n_resolved: usize = 0;
    var n_unresolved: usize = 0;
    var n_ambiguous: usize = 0;
    var n_hb: usize = 0;
    for (all_links.items) |l| {
        switch (l.status) {
            .resolved => n_resolved += 1,
            .unresolved => n_unresolved += 1,
            .ambiguous => n_ambiguous += 1,
            .heading_or_block => n_hb += 1,
            else => {},
        }
    }

    const report = Report{
        .source_vault = opts.vault_dir,
        .pages = page_records.items,
        .links = all_links.items,
        .hazards = all_hazards.items,
        .attachments = attach_manifest.items,
        .unsupported_items = unsupported.items,
        .human_review = human_review.items,
        .summary_pages = page_records.items.len,
        .summary_attachments = attach_manifest.items.len,
        .summary_links_resolved = n_resolved,
        .summary_links_unresolved = n_unresolved,
        .summary_links_ambiguous = n_ambiguous,
        .summary_heading_block = n_hb,
    };

    const json = try emitReportJson(gpa, report);
    defer gpa.free(json);
    try writeBytes(io, out_root, "report.json", json);

    const mdrep = try emitReportMd(gpa, report);
    defer gpa.free(mdrep);
    try writeBytes(io, out_root, "REPORT.md", mdrep);

    const man = try emitAttachmentsManifest(gpa, attach_manifest.items);
    defer gpa.free(man);
    try writeBytes(io, out_root, "attachments_manifest.json", man);

    if (!opts.quiet) {
        std.debug.print(
            "obsidian-migration-lab: wrote {s}/content/, {s}/assets/, {s}/report.json, {s}/REPORT.md, {s}/attachments_manifest.json\n",
            .{ opts.out_dir, opts.out_dir, opts.out_dir, opts.out_dir, opts.out_dir },
        );
    }
}

// ---------------------------------------------------------------------------
// Unit + fixture tests
// ---------------------------------------------------------------------------

test "pathToEntityId: spaces and nested paths" {
    const gpa = std.testing.allocator;
    const id = try pathToEntityId(gpa, "Projects/Q1 Plan.md");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("Projects/Q1-Plan", id);

    const id2 = try pathToEntityId(gpa, "Notes/Sub/Gamma.md");
    defer gpa.free(id2);
    try std.testing.expectEqualStrings("Notes/Sub/Gamma", id2);
}

test "sanitizeEntityId: wiki-safe charset" {
    const gpa = std.testing.allocator;
    const id = try sanitizeEntityId(gpa, "Hello World!");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("Hello-World", id);
    try std.testing.expect(entityIdIsWikiSafe(id));
}

test "pathSuffixMatch: exact and nested suffix" {
    try std.testing.expect(pathSuffixMatch("Vault/Concept Board/Concept Board", "Concept Board/Concept Board"));
    try std.testing.expect(pathSuffixMatch("Vault/Concept-Board/Concept-Board", "Concept-Board/Concept-Board"));
    try std.testing.expect(pathSuffixMatch("Notes/Beta", "Notes/Beta"));
    try std.testing.expect(!pathSuffixMatch("Notes/Beta", "eta")); // must be path-boundary
    try std.testing.expect(!pathSuffixMatch("Notes/Beta", "Other/Beta"));
}

test "isPluginTemplateWikiTarget: templater and dollar braces" {
    try std.testing.expect(isPluginTemplateWikiTarget("${navLink}"));
    try std.testing.expect(isPluginTemplateWikiTarget("<% tp.file.title %>"));
    try std.testing.expect(!isPluginTemplateWikiTarget("Notes/Beta"));
    try std.testing.expect(!isPluginTemplateWikiTarget("Q1 Plan"));
}

test "scanWikiHits: link alias embed and fence" {
    const gpa = std.testing.allocator;
    const body =
        \\See [[Beta|label]] and ![[Attachments/diagram.png]].
        \\
        \\```
        \\[[Beta]]
        \\```
        \\
        \\[[Beta#Details]]
    ;
    const hits = try scanWikiHits(gpa, body);
    defer gpa.free(hits);
    try std.testing.expect(hits.len >= 4);
    var saw_alias = false;
    var saw_embed = false;
    var saw_fence = false;
    var saw_heading = false;
    for (hits) |h| {
        if (h.alias != null and std.mem.eql(u8, h.target, "Beta")) saw_alias = true;
        if (h.is_embed) saw_embed = true;
        if (h.in_fence) saw_fence = true;
        if (h.has_heading_or_block) saw_heading = true;
    }
    try std.testing.expect(saw_alias);
    try std.testing.expect(saw_embed);
    try std.testing.expect(saw_fence);
    try std.testing.expect(saw_heading);
}

test "parseFrontmatterLite: keeps closed keys drops unknown" {
    const gpa = std.testing.allocator;
    const src =
        \\---
        \\title: Alpha
        \\parent: Welcome
        \\status: published
        \\tags: [notes]
        \\cssclass: fancy
        \\---
        \\
        \\Body
    ;
    const fm = try parseFrontmatterLite(gpa, src);
    defer {
        if (fm.title) |t| gpa.free(t);
        if (fm.parent) |p| gpa.free(p);
        if (fm.status) |s| gpa.free(s);
        if (fm.tags_raw) |t| gpa.free(t);
        if (fm.id_override) |i| gpa.free(i);
        for (fm.unknown_keys) |k| gpa.free(k);
        gpa.free(fm.unknown_keys);
        for (fm.notes) |n| gpa.free(n);
        gpa.free(fm.notes);
    }
    try std.testing.expect(fm.present);
    try std.testing.expectEqualStrings("Alpha", fm.title.?);
    try std.testing.expectEqualStrings("Welcome", fm.parent.?);
    try std.testing.expect(fm.unknown_keys.len == 1);
    try std.testing.expectEqualStrings("cssclass", fm.unknown_keys[0]);
    try std.testing.expect(std.mem.indexOf(u8, src[fm.body_offset..], "Body") != null);
}

test "relativeLink: nested page to assets" {
    const gpa = std.testing.allocator;
    const rel = try relativeLink(gpa, "content/Notes/Alpha.md", "assets/Attachments/diagram.png");
    defer gpa.free(rel);
    try std.testing.expectEqualStrings("../../assets/Attachments/diagram.png", rel);
}

test "isSkippedDirName: obsidian git node_modules" {
    try std.testing.expect(isSkippedDirName(".obsidian"));
    try std.testing.expect(isSkippedDirName(".git"));
    try std.testing.expect(isSkippedDirName("node_modules"));
    try std.testing.expect(isSkippedDirName("dist"));
    try std.testing.expect(!isSkippedDirName("Notes"));
}

test "fixture: obsidian end-to-end determinism + immutability + link resolution" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var vault_dir = try Io.Dir.cwd().openDir(io, "fixtures/mini-obsidian", .{});
    defer vault_dir.close(io);
    const before = try readFileAlloc(io, vault_dir, "Notes/Alpha.md", gpa);
    defer gpa.free(before);
    const before_png = try readFileAlloc(io, vault_dir, "Attachments/diagram.png", gpa);
    defer gpa.free(before_png);

    const out_a = "fixtures/.test-obsidian-out-a";
    const out_b = "fixtures/.test-obsidian-out-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    try run(io, gpa, .{ .vault_dir = "fixtures/mini-obsidian", .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .vault_dir = "fixtures/mini-obsidian", .out_dir = out_b, .quiet = true });

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);

    const ja = try readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try readFileAlloc(io, a, "REPORT.md", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, b, "REPORT.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    const aa = try readFileAlloc(io, a, "attachments_manifest.json", gpa);
    defer gpa.free(aa);
    const ab = try readFileAlloc(io, b, "attachments_manifest.json", gpa);
    defer gpa.free(ab);
    try std.testing.expectEqualStrings(aa, ab);

    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-obsidian-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"pages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"hazards\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"attachments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"human_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unsupported_items\"") != null);

    // Link resolution signals
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"resolved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"ambiguous\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unresolved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "heading_or_block") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "dataview") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "canvas") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "Shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "Missing Note") != null);

    // Skipped dirs: no node_modules / .obsidian content in pages
    try std.testing.expect(std.mem.indexOf(u8, ja, "node_modules") == null);
    try std.testing.expect(std.mem.indexOf(u8, ja, ".obsidian") == null);

    // Rewritten page content
    const alpha = try readFileAlloc(io, a, "content/Notes/Alpha.md", gpa);
    defer gpa.free(alpha);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "[[Notes/Beta") != null or std.mem.indexOf(u8, alpha, "[[Notes/Beta]]") != null or std.mem.indexOf(u8, alpha, "Notes/Beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "boris-migration-provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "cssclass") == null); // dropped unknown key
    // Raw ambiguous / missing retained
    try std.testing.expect(std.mem.indexOf(u8, alpha, "[[Shared]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "[[Missing Note]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "[[Beta#Details]]") != null);
    // Fenced not rewritten — still [[Beta]] inside fence
    try std.testing.expect(std.mem.indexOf(u8, alpha, "```markdown\n[[Beta]]") != null or std.mem.indexOf(u8, alpha, "[[Beta]]") != null);

    // Content-byte determinism (not only reports)
    const alpha_b = try readFileAlloc(io, b, "content/Notes/Alpha.md", gpa);
    defer gpa.free(alpha_b);
    try std.testing.expectEqualStrings(alpha, alpha_b);

    // Spaces path mapped
    const q1 = try readFileAlloc(io, a, "content/Projects/Q1-Plan.md", gpa);
    defer gpa.free(q1);
    try std.testing.expect(std.mem.indexOf(u8, q1, "title:") != null);

    // Path-suffix resolution (Vault/ omitted in link target)
    const hydro = try readFileAlloc(io, a, "content/Vault/Concept-Board/Concepts/Vertical-Hydroponics.md", gpa);
    defer gpa.free(hydro);
    try std.testing.expect(std.mem.indexOf(u8, hydro, "[[Vault/Concept-Board/Concept-Board") != null);
    // Content-byte determinism on rewritten path-suffix page
    const hydro_b = try readFileAlloc(io, b, "content/Vault/Concept-Board/Concepts/Vertical-Hydroponics.md", gpa);
    defer gpa.free(hydro_b);
    try std.testing.expectEqualStrings(hydro, hydro_b);

    // Ambiguous path suffix retained raw
    const probe = try readFileAlloc(io, a, "content/Notes/Suffix-Probe.md", gpa);
    defer gpa.free(probe);
    try std.testing.expect(std.mem.indexOf(u8, probe, "[[Shared Path/Deep]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "Shared Path/Deep") != null);

    // Templater placeholders classified as plugin_template (not unresolved)
    try std.testing.expect(std.mem.indexOf(u8, ja, "plugin_template") != null);
    const nav = try readFileAlloc(io, a, "content/Templates/Nav.md", gpa);
    defer gpa.free(nav);
    try std.testing.expect(std.mem.indexOf(u8, nav, "[[${navLink}|${navName}]]") != null);

    // Entity-id collision remapped to unique output paths (no clobber)
    const clash1 = try readFileAlloc(io, a, "content/Clash/Hello-World.md", gpa);
    defer gpa.free(clash1);
    const clash2 = try readFileAlloc(io, a, "content/Clash/Hello-World-2.md", gpa);
    defer gpa.free(clash2);
    try std.testing.expect(std.mem.indexOf(u8, clash1, "Hello World") != null or std.mem.indexOf(u8, clash1, "spaced") != null or std.mem.indexOf(u8, clash1, "dashed") != null);
    try std.testing.expect(std.mem.indexOf(u8, clash2, "Hello World") != null or std.mem.indexOf(u8, clash2, "spaced") != null or std.mem.indexOf(u8, clash2, "dashed") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "entity_id_collision") != null);
    // both collision outputs deterministic across runs
    const clash1b = try readFileAlloc(io, b, "content/Clash/Hello-World.md", gpa);
    defer gpa.free(clash1b);
    const clash2b = try readFileAlloc(io, b, "content/Clash/Hello-World-2.md", gpa);
    defer gpa.free(clash2b);
    try std.testing.expectEqualStrings(clash1, clash1b);
    try std.testing.expectEqualStrings(clash2, clash2b);

    // Embed image rewritten
    const embeds = try readFileAlloc(io, a, "content/Embeds.md", gpa);
    defer gpa.free(embeds);
    try std.testing.expect(std.mem.indexOf(u8, embeds, "assets/Attachments/diagram.png") != null or std.mem.indexOf(u8, embeds, "diagram.png") != null);

    // Attachment copied
    const png = try readFileAlloc(io, a, "assets/Attachments/diagram.png", gpa);
    defer gpa.free(png);
    try std.testing.expectEqualStrings(before_png, png);

    // Source immutability
    const after = try readFileAlloc(io, vault_dir, "Notes/Alpha.md", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    const after_png = try readFileAlloc(io, vault_dir, "Attachments/diagram.png", gpa);
    defer gpa.free(after_png);
    try std.testing.expectEqualStrings(before_png, after_png);

    try std.testing.expect(std.mem.indexOf(u8, ma, "# Obsidian → Boris migration laboratory") != null);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "detectBodyHazards: dataview and tasks" {
    const gpa = std.testing.allocator;
    const body =
        \\```dataview
        \\TABLE x
        \\```
        \\
        \\```tasks
        \\not done
        \\```
        \\
        \\$= dv.current()
        \\field:: value
    ;
    const hs = try detectBodyHazards(gpa, "x.md", body);
    defer {
        for (hs) |h| gpa.free(h.detail);
        gpa.free(hs);
    }
    try std.testing.expect(hs.len >= 3);
}
