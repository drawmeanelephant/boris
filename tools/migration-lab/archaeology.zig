//! Read-only Astro → Boris migration archaeology core.
//!
//! Walks an Astro project/export tree, classifies sources, and builds
//! deterministic report structures. Never mutates scan-root files.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-astro-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

const skip_dir_names = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    ".astro",
    "dist",
    ".vercel",
    ".netlify",
    ".output",
    "zig-out",
    ".zig-cache",
    "zig-cache",
};

const skip_file_names = [_][]const u8{
    ".DS_Store",
    "Thumbs.db",
};

/// Boris closed frontmatter keys (author grammar). Others are migration hazards.
const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

pub const FileKind = enum {
    content_page,
    page_route,
    layout,
    component,
    public_asset,
    src_asset,
    config,
    other,

    pub fn jsonName(self: FileKind) []const u8 {
        return switch (self) {
            .content_page => "content_page",
            .page_route => "page_route",
            .layout => "layout",
            .component => "component",
            .public_asset => "public_asset",
            .src_asset => "src_asset",
            .config => "config",
            .other => "other",
        };
    }
};

pub const InventoryEntry = struct {
    source_path: []const u8,
    kind: FileKind,
    bytes: u64,
    extension: []const u8,
};

pub const FrontmatterLite = struct {
    present: bool = false,
    body_offset: usize = 0,
    title: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    parent_entry: ?[]const u8 = null,
    status: ?[]const u8 = null,
    has_layout: bool = false,
    has_parent_entry: bool = false,
    has_draft: bool = false,
    has_nested_mapping: bool = false,
    has_yaml_sequence: bool = false,
    has_block_scalar: bool = false,
    has_unknown_boris_keys: bool = false,
    unknown_keys: []const []const u8 = &.{},
    all_keys: []const []const u8 = &.{},
};

pub const LinkRef = struct {
    source_path: []const u8,
    kind: []const u8,
    target: []const u8,
    line: u32,
    internal: bool,
};

pub const Hazard = struct {
    source_path: []const u8,
    code: []const u8,
    severity: []const u8,
    message: []const u8,
};

pub const Stitch = struct {
    logical_slug: []const u8,
    content_path: ?[]const u8,
    route_path: ?[]const u8,
    layout_path: ?[]const u8,
    complete: bool,
    notes: []const u8,
};

pub const ProposedId = struct {
    source_path: []const u8,
    proposed_entity_id: []const u8,
    basis: []const u8,
};

pub const ParentChild = struct {
    child_source_path: []const u8,
    child_entity_id: []const u8,
    candidate_parent_id: []const u8,
    reason: []const u8,
    confidence: []const u8,
};

pub const BrokenLink = struct {
    source_path: []const u8,
    target: []const u8,
    line: u32,
    reason: []const u8,
};

pub const SlugConflict = struct {
    slug: []const u8,
    source_paths: []const []const u8,
    kind: []const u8,
};

pub const AssetEntry = struct {
    source_path: []const u8,
    kind: []const u8,
    bytes: u64,
};

pub const MissingAsset = struct {
    source_path: []const u8,
    referenced: []const u8,
    line: u32,
};

pub const HumanReview = struct {
    source_path: []const u8,
    reason: []const u8,
    codes: []const []const u8,
};

pub const Report = struct {
    scan_root: []const u8,
    inventory: []InventoryEntry,
    stitches: []Stitch,
    proposed_ids: []ProposedId,
    parent_child_candidates: []ParentChild,
    links: []LinkRef,
    broken_links: []BrokenLink,
    slug_conflicts: []SlugConflict,
    assets: []AssetEntry,
    missing_assets: []MissingAsset,
    hazards: []Hazard,
    human_review: []HumanReview,
};

// ---------------------------------------------------------------------------
// Path / classify helpers
// ---------------------------------------------------------------------------

pub fn normalizeRelPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var start: usize = 0;
    if (std.mem.startsWith(u8, path, "./")) start = 2;
    const slice = path[start..];
    if (std.mem.indexOfScalar(u8, slice, '\\') == null) {
        return try allocator.dupe(u8, slice);
    }
    const buf = try allocator.alloc(u8, slice.len);
    for (slice, 0..) |c, i| {
        buf[i] = if (c == '\\') '/' else c;
    }
    return buf;
}

/// Zero-copy style helper for tests when path is already POSIX.
pub fn normalizeRelPath(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

pub fn fileExtension(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot == 0) return "";
        return base[dot..];
    }
    return "";
}

pub fn isSkippedDirName(name: []const u8) bool {
    for (skip_dir_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

pub fn isSkippedFileName(name: []const u8) bool {
    for (skip_file_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Well-known Astro content-collection directory names (scan-root relative).
/// Discovery is restricted to these roots so arbitrary repository Markdown
/// (README.md, docs/, notes/, …) is never treated as Astro content.
/// Preference when both exist: `src/content` (canonical) then root `content`.
pub const content_root_dir_names = [_][]const u8{ "src/content", "content" };

/// If `path` sits under a supported content root, return that root prefix
/// including the trailing slash (`src/content/` or `content/`). Longer /
/// more-specific roots are checked first so `src/content/…` is not mistaken
/// for a bare `content/…` path.
pub fn contentRootPrefix(path: []const u8) ?[]const u8 {
    // Order matters: check the longer prefix first.
    if (std.mem.startsWith(u8, path, "src/content/")) return "src/content/";
    if (std.mem.startsWith(u8, path, "content/")) return "content/";
    return null;
}

pub fn isContentPage(path: []const u8) bool {
    if (contentRootPrefix(path) == null) return false;
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
}

pub fn isPageRoute(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/pages/") and std.mem.endsWith(u8, path, ".astro");
}

pub fn isLayout(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/layouts/") and std.mem.endsWith(u8, path, ".astro");
}

pub fn isComponent(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/components/");
}

pub fn isPublicAsset(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "public/");
}

pub fn isSrcAsset(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/assets/");
}

pub fn isConfig(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "astro.config.")) return true;
    if (std.mem.eql(u8, base, "content.config.ts") or std.mem.eql(u8, base, "content.config.mjs") or
        std.mem.eql(u8, base, "content.config.js"))
        return true;
    if (std.mem.eql(u8, path, "src/content/config.ts") or std.mem.eql(u8, path, "src/content/config.mjs") or
        std.mem.eql(u8, path, "src/content/config.js"))
        return true;
    if (std.mem.eql(u8, path, "content/config.ts") or std.mem.eql(u8, path, "content/config.mjs") or
        std.mem.eql(u8, path, "content/config.js"))
        return true;
    if (std.mem.eql(u8, base, "package.json") or std.mem.eql(u8, base, "tsconfig.json")) return true;
    return false;
}

pub fn classifyPath(path: []const u8) FileKind {
    if (isContentPage(path)) return .content_page;
    if (isPageRoute(path)) return .page_route;
    if (isLayout(path)) return .layout;
    if (isComponent(path)) return .component;
    if (isPublicAsset(path)) return .public_asset;
    if (isSrcAsset(path)) return .src_asset;
    if (isConfig(path)) return .config;
    return .other;
}

/// Path under `<content-root>/<collection>/…` or `src/pages/…` with extension stripped.
pub fn proposeEntityId(path: []const u8) []const u8 {
    // Provide non-allocating for common prefixes by returning a slice of path.
    if (contentRootPrefix(path)) |prefix| {
        var rest = path[prefix.len..];
        if (std.mem.endsWith(u8, rest, ".mdx")) return rest[0 .. rest.len - 4];
        if (std.mem.endsWith(u8, rest, ".md")) return rest[0 .. rest.len - 3];
        return rest;
    }
    if (std.mem.startsWith(u8, path, "src/pages/")) {
        var rest = path["src/pages/".len..];
        if (std.mem.endsWith(u8, rest, ".astro")) rest = rest[0 .. rest.len - 6];
        // Dynamic segments are not stable entity ids.
        if (std.mem.indexOfScalar(u8, rest, '[') != null) return rest;
        if (std.mem.eql(u8, rest, "index")) return "index";
        if (std.mem.endsWith(u8, rest, "/index")) return rest[0 .. rest.len - "/index".len];
        return rest;
    }
    // Fallback: strip one extension.
    if (std.mem.endsWith(u8, path, ".mdx")) return path[0 .. path.len - 4];
    if (std.mem.endsWith(u8, path, ".md")) return path[0 .. path.len - 3];
    return path;
}

/// Collection-relative slug (drops `<content-root>/<collection>/`).
pub fn slugFromContentPath(path: []const u8) []const u8 {
    const prefix = contentRootPrefix(path) orelse return proposeEntityId(path);
    const rest = path[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        var after = rest[slash + 1 ..];
        if (std.mem.endsWith(u8, after, ".mdx")) after = after[0 .. after.len - 4];
        if (std.mem.endsWith(u8, after, ".md")) after = after[0 .. after.len - 3];
        return after;
    }
    return proposeEntityId(path);
}

pub fn collectionFromContentPath(path: []const u8) ?[]const u8 {
    const prefix = contentRootPrefix(path) orelse return null;
    const rest = path[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        return rest[0..slash];
    }
    return null;
}

/// True when a directory entry exists at `name` under `root` (file or dir).
fn entryExists(io: Io, root: Io.Dir, name: []const u8) bool {
    _ = root.statFile(io, name, .{}) catch {
        // statFile may fail for directories on some backends; try openDir.
        var d = root.openDir(io, name, .{}) catch return false;
        d.close(io);
        return true;
    };
    return true;
}

/// Detect which supported content-collection roots exist under the scan root.
/// Returns retained path prefixes with trailing slash, preference order:
/// `src/content/` then `content/`. Does not invent roots from free-form Markdown.
pub fn detectContentRoots(io: Io, retain: std.mem.Allocator, root: Io.Dir) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(retain);
    for (content_root_dir_names) |name| {
        if (!entryExists(io, root, name)) continue;
        // Only treat as a content root when it is a directory.
        var d = root.openDir(io, name, .{}) catch continue;
        d.close(io);
        const prefix = try std.fmt.allocPrint(retain, "{s}/", .{name});
        try list.append(retain, prefix);
    }
    return try list.toOwnedSlice(retain);
}

fn isBorisKey(key: []const u8) bool {
    for (boris_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// I/O
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

fn pathExists(io: Io, root: Io.Dir, rel: []const u8) bool {
    _ = root.statFile(io, rel, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Walk
// ---------------------------------------------------------------------------

fn collectUnderDir(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkippedDirName(entry.name)) continue;
            const child_rel = if (prefix.len == 0)
                try retain.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try collectUnderDir(io, gpa, retain, sub, child_rel, out);
            continue;
        }
        if (entry.kind != .file) continue;
        if (isSkippedFileName(entry.name)) continue;
        const child_rel = if (prefix.len == 0)
            try retain.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
        try out.append(gpa, child_rel);
    }
}

fn collectAllPaths(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    root: Io.Dir,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    try collectUnderDir(io, gpa, retain, root, "", &list);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Frontmatter (lightweight, non-YAML)
// ---------------------------------------------------------------------------

fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

pub fn parseFrontmatterLite(allocator: std.mem.Allocator, source: []const u8) !FrontmatterLite {
    var fm: FrontmatterLite = .{};
    if (!std.mem.startsWith(u8, source, "---\n") and !std.mem.startsWith(u8, source, "---\r\n")) {
        return fm;
    }
    const after_open: usize = if (std.mem.startsWith(u8, source, "---\r\n")) 5 else 4;
    var i = after_open;
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    var unknown: std.ArrayList([]const u8) = .empty;
    errdefer unknown.deinit(allocator);

    while (i < source.len) {
        const line_start = i;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        var line = source[line_start..i];
        if (i < source.len and source[i] == '\n') i += 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.eql(u8, line, "---")) {
            fm.present = true;
            fm.body_offset = i;
            break;
        }

        if (line.len == 0) continue;

        const line_trim_left = trimSpace(line);
        if (line[0] == ' ' or line[0] == '\t') {
            fm.has_nested_mapping = true;
            if (std.mem.startsWith(u8, line_trim_left, "- ")) {
                fm.has_yaml_sequence = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            fm.has_yaml_sequence = true;
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimSpace(line[0..colon]);
        var value = trimSpace(line[colon + 1 ..]);
        value = stripQuotes(value);

        try keys.append(allocator, try allocator.dupe(u8, key));

        if (std.mem.eql(u8, key, "title")) {
            fm.title = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "slug")) {
            fm.slug = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "layout")) {
            fm.has_layout = true;
            fm.layout = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "parent")) {
            fm.parent = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "parentEntry") or std.mem.eql(u8, key, "parent_entry")) {
            fm.has_parent_entry = true;
            fm.parent_entry = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "draft")) {
            fm.has_draft = true;
        } else if (std.mem.eql(u8, key, "status")) {
            fm.status = try allocator.dupe(u8, value);
        }

        if (std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">")) {
            fm.has_block_scalar = true;
        }

        // Nested mapping marker: key with empty value often followed by indent (detected above).
        if (value.len == 0) {
            // May be nested mapping start; flag soft.
            fm.has_nested_mapping = true;
        }

        if (!isBorisKey(key)) {
            // tags with YAML list form is still "known" as intent but hazard for form.
            if (!std.mem.eql(u8, key, "tags")) {
                fm.has_unknown_boris_keys = true;
                try unknown.append(allocator, try allocator.dupe(u8, key));
            }
        }
    }

    if (!fm.present) {
        // Unclosed frontmatter — treat whole file as body, still record keys seen.
        fm.body_offset = 0;
        fm.present = false;
    }

    fm.all_keys = try keys.toOwnedSlice(allocator);
    fm.unknown_keys = try unknown.toOwnedSlice(allocator);
    return fm;
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

fn isExternalTarget(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) return true;
    if (std.mem.startsWith(u8, target, "mailto:") or std.mem.startsWith(u8, target, "tel:")) return true;
    if (std.mem.startsWith(u8, target, "//")) return true;
    if (std.mem.startsWith(u8, target, "data:")) return true;
    if (std.mem.startsWith(u8, target, "#")) return true; // same-page fragment only
    return false;
}

fn lineNumberAt(source: []const u8, index: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < index and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

fn appendLink(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(LinkRef),
    source_path: []const u8,
    kind: []const u8,
    target_raw: []const u8,
    source: []const u8,
    at: usize,
) !void {
    var target = trimSpace(target_raw);
    // Drop title portion in markdown: url "title"
    if (std.mem.indexOfScalar(u8, target, ' ')) |sp| {
        target = trimSpace(target[0..sp]);
    }
    if (target.len == 0) return;
    if (isExternalTarget(target)) return;
    try out.append(allocator, .{
        .source_path = source_path,
        .kind = kind,
        .target = try allocator.dupe(u8, target),
        .line = lineNumberAt(source, at),
        .internal = true,
    });
}

pub fn extractLinks(allocator: std.mem.Allocator, source_path: []const u8, source: []const u8) ![]LinkRef {
    var out: std.ArrayList(LinkRef) = .empty;
    errdefer out.deinit(allocator);

    // Markdown images ![alt](url) then links [text](url)
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '!' and i + 1 < source.len and source[i + 1] == '[') {
            if (findMdDest(source, i + 1)) |dest| {
                try appendLink(allocator, &out, source_path, "markdown_image", dest.url, source, i);
                i = dest.end;
                continue;
            }
        } else if (source[i] == '[') {
            if (findMdDest(source, i)) |dest| {
                try appendLink(allocator, &out, source_path, "markdown_link", dest.url, source, i);
                i = dest.end;
                continue;
            }
        } else if (std.mem.startsWith(u8, source[i..], "href=\"")) {
            const start = i + "href=\"".len;
            if (std.mem.indexOfScalar(u8, source[start..], '"')) |end| {
                try appendLink(allocator, &out, source_path, "html_href", source[start .. start + end], source, i);
                i = start + end + 1;
                continue;
            }
        } else if (std.mem.startsWith(u8, source[i..], "href='")) {
            const start = i + "href='".len;
            if (std.mem.indexOfScalar(u8, source[start..], '\'')) |end| {
                try appendLink(allocator, &out, source_path, "html_href", source[start .. start + end], source, i);
                i = start + end + 1;
                continue;
            }
        } else if (std.mem.startsWith(u8, source[i..], "src=\"")) {
            const start = i + "src=\"".len;
            if (std.mem.indexOfScalar(u8, source[start..], '"')) |end| {
                try appendLink(allocator, &out, source_path, "html_src", source[start .. start + end], source, i);
                i = start + end + 1;
                continue;
            }
        } else if (std.mem.startsWith(u8, source[i..], "src='")) {
            const start = i + "src='".len;
            if (std.mem.indexOfScalar(u8, source[start..], '\'')) |end| {
                try appendLink(allocator, &out, source_path, "html_src", source[start .. start + end], source, i);
                i = start + end + 1;
                continue;
            }
        }
        i += 1;
    }

    // Stable order: by line then target.
    std.mem.sort(LinkRef, out.items, {}, struct {
        fn less(_: void, a: LinkRef, b: LinkRef) bool {
            if (a.line != b.line) return a.line < b.line;
            return std.mem.order(u8, a.target, b.target) == .lt;
        }
    }.less);

    return try out.toOwnedSlice(allocator);
}

const MdDest = struct { url: []const u8, end: usize };

fn findMdDest(source: []const u8, open_bracket: usize) ?MdDest {
    // open_bracket points at '['
    if (open_bracket >= source.len or source[open_bracket] != '[') return null;
    var i = open_bracket + 1;
    // Allow nested brackets lightly: find matching ]
    var depth: usize = 1;
    while (i < source.len) : (i += 1) {
        if (source[i] == '[') depth += 1;
        if (source[i] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
        if (source[i] == '\n') return null;
    }
    if (i >= source.len or source[i] != ']') return null;
    i += 1;
    if (i >= source.len or source[i] != '(') return null;
    i += 1;
    const url_start = i;
    while (i < source.len and source[i] != ')' and source[i] != '\n') : (i += 1) {}
    if (i >= source.len or source[i] != ')') return null;
    return .{ .url = source[url_start..i], .end = i + 1 };
}

// ---------------------------------------------------------------------------
// Hazards
// ---------------------------------------------------------------------------

pub fn collectHazards(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    fm: FrontmatterLite,
) ![]Hazard {
    var out: std.ArrayList(Hazard) = .empty;
    errdefer out.deinit(allocator);

    const body = if (fm.present and fm.body_offset <= source.len) source[fm.body_offset..] else source;

    const add = struct {
        fn go(
            a: std.mem.Allocator,
            list: *std.ArrayList(Hazard),
            path: []const u8,
            code: []const u8,
            severity: []const u8,
            message: []const u8,
        ) !void {
            try list.append(a, .{
                .source_path = path,
                .code = code,
                .severity = severity,
                .message = try a.dupe(u8, message),
            });
        }
    }.go;

    if (std.mem.endsWith(u8, source_path, ".mdx")) {
        try add(allocator, &out, source_path, "mdx_source", "high", "MDX source requires JSX/component strip before Boris Markdown");
    }
    if (fm.has_layout) {
        try add(allocator, &out, source_path, "astro_layout_key", "high", "Astro frontmatter layout: is not a Boris author key (use theme layout rules)");
    }
    if (fm.has_parent_entry) {
        try add(allocator, &out, source_path, "legacy_parent_key", "high", "parentEntry/parent_entry rejected by Boris; use parent only");
    }
    if (fm.has_draft) {
        try add(allocator, &out, source_path, "draft_flag", "medium", "draft: is not Boris status; map to status: draft");
    }
    if (fm.has_nested_mapping) {
        try add(allocator, &out, source_path, "nested_yaml", "high", "Nested YAML mappings are unsupported in Boris closed frontmatter");
    }
    if (fm.has_yaml_sequence) {
        try add(allocator, &out, source_path, "yaml_sequence", "high", "YAML sequence form (- item) unsupported; tags must be [a, b] on one line");
    }
    if (fm.has_block_scalar) {
        try add(allocator, &out, source_path, "block_scalar", "high", "YAML block scalars (|/>) unsupported in Boris frontmatter");
    }
    if (fm.has_unknown_boris_keys) {
        for (fm.unknown_keys) |k| {
            // layout/draft/parentEntry already covered
            if (std.mem.eql(u8, k, "layout") or std.mem.eql(u8, k, "draft") or
                std.mem.eql(u8, k, "parentEntry") or std.mem.eql(u8, k, "parent_entry"))
                continue;
            const msg = try std.fmt.allocPrint(allocator, "Unknown Boris frontmatter key: {s}", .{k});
            try add(allocator, &out, source_path, "unknown_frontmatter_key", "high", msg);
        }
    }
    if (std.mem.indexOf(u8, body, "import ") != null and
        (std.mem.endsWith(u8, source_path, ".mdx") or std.mem.indexOf(u8, body, " from ") != null))
    {
        try add(allocator, &out, source_path, "mdx_import", "high", "ESM import in content body will not compile under Boris");
    }
    if (std.mem.indexOf(u8, body, "export ") != null and std.mem.endsWith(u8, source_path, ".mdx")) {
        try add(allocator, &out, source_path, "mdx_export", "high", "ESM export in MDX body will not compile under Boris");
    }
    // JSX-ish component tags (capitalized)
    if (std.mem.indexOf(u8, body, "<") != null) {
        var bi: usize = 0;
        while (bi < body.len) : (bi += 1) {
            if (body[bi] == '<' and bi + 1 < body.len) {
                const c = body[bi + 1];
                if (c >= 'A' and c <= 'Z') {
                    try add(allocator, &out, source_path, "jsx_component", "high", "JSX/MDX component tag detected; Boris allows only registered static components such as Aside");
                    break;
                }
            }
        }
    }
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        try add(allocator, &out, source_path, "utf8_bom", "high", "UTF-8 BOM is rejected by Boris");
    }

    std.mem.sort(Hazard, out.items, {}, struct {
        fn less(_: void, a: Hazard, b: Hazard) bool {
            const sc = std.mem.order(u8, a.source_path, b.source_path);
            if (sc != .eq) return sc == .lt;
            const cc = std.mem.order(u8, a.code, b.code);
            if (cc != .eq) return cc == .lt;
            return std.mem.order(u8, a.message, b.message) == .lt;
        }
    }.less);

    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Resolution helpers
// ---------------------------------------------------------------------------

fn dirnamePosix(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx == 0) return "";
        return path[0..idx];
    }
    return "";
}

/// Strip `#fragment` and `?query` from a link target for filesystem resolution.
fn stripQueryFragment(target: []const u8) []const u8 {
    var t = target;
    if (std.mem.indexOfScalar(u8, t, '#')) |hash| t = t[0..hash];
    if (std.mem.indexOfScalar(u8, t, '?')) |q| t = t[0..q];
    return t;
}

/// Map a site-root absolute URL (`/images/hero.png`) to a `public/…` path.
pub fn absoluteToPublicPath(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    const t = stripQueryFragment(target);
    if (t.len == 0 or t[0] != '/') return try allocator.dupe(u8, t);
    if (t.len == 1) return try allocator.dupe(u8, "public");
    return try std.fmt.allocPrint(allocator, "public{s}", .{t});
}

/// Map a site-root absolute URL to a route key for page resolution.
/// `/` → `index`; `/about` → `about`; trailing slashes are trimmed.
pub fn absoluteToRouteKey(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    var t = stripQueryFragment(target);
    if (t.len == 0 or t[0] != '/') return try allocator.dupe(u8, t);
    while (t.len > 1 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
    if (t.len == 1) return try allocator.dupe(u8, "index");
    return try allocator.dupe(u8, t[1..]);
}

/// Resolve a relative URL against a source file path (POSIX).
/// Site-root absolute targets (`/…`) return the path without the leading slash
/// (empty string for `/`). Asset callers that need `public/` must use
/// `absoluteToPublicPath` instead — absolute hrefs are routes, not assets.
fn resolveRelative(allocator: std.mem.Allocator, from_file: []const u8, target: []const u8) ![]u8 {
    var t = stripQueryFragment(target);
    if (t.len == 0) return try allocator.dupe(u8, "");

    if (t[0] == '/') {
        if (t.len == 1) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, t[1..]);
    }

    const base_dir = dirnamePosix(from_file);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);

    if (base_dir.len > 0) {
        var it = std.mem.splitScalar(u8, base_dir, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            try stack.append(allocator, seg);
        }
    }

    var tit = std.mem.splitScalar(u8, t, '/');
    while (tit.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (stack.items.len > 0) _ = stack.pop();
            continue;
        }
        try stack.append(allocator, seg);
    }

    if (stack.items.len == 0) return try allocator.dupe(u8, "");
    var size: usize = 0;
    for (stack.items, 0..) |seg, idx| {
        size += seg.len;
        if (idx + 1 < stack.items.len) size += 1;
    }
    const out = try allocator.alloc(u8, size);
    var o: usize = 0;
    for (stack.items, 0..) |seg, idx| {
        @memcpy(out[o .. o + seg.len], seg);
        o += seg.len;
        if (idx + 1 < stack.items.len) {
            out[o] = '/';
            o += 1;
        }
    }
    return out;
}

fn pathSetContains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

fn isAssetLinkKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "markdown_image") or std.mem.eql(u8, kind, "html_src");
}

fn hasPageCandidate(paths: []const []const u8, entity_or_path: []const u8) bool {
    // Exact path
    if (pathSetContains(paths, entity_or_path)) return true;
    // Try with extensions
    var buf: [512]u8 = undefined;
    const candidates = [_][]const u8{ ".md", ".mdx", ".astro", "/index.md", "/index.mdx", "/index.astro" };
    for (candidates) |suf| {
        if (entity_or_path.len + suf.len > buf.len) continue;
        @memcpy(buf[0..entity_or_path.len], entity_or_path);
        @memcpy(buf[entity_or_path.len .. entity_or_path.len + suf.len], suf);
        const full = buf[0 .. entity_or_path.len + suf.len];
        if (pathSetContains(paths, full)) return true;
    }
    // Content entity under supported content roots, pages, or public assets.
    if (entity_or_path.len + 20 < buf.len) {
        const prefixes = [_][]const u8{ "src/content/", "content/", "src/pages/", "public/" };
        for (prefixes) |pre| {
            for (candidates) |suf| {
                const n = pre.len + entity_or_path.len + suf.len;
                if (n > buf.len) continue;
                @memcpy(buf[0..pre.len], pre);
                @memcpy(buf[pre.len .. pre.len + entity_or_path.len], entity_or_path);
                @memcpy(buf[pre.len + entity_or_path.len .. n], suf);
                if (pathSetContains(paths, buf[0..n])) return true;
            }
            // without extra suffix
            const n2 = pre.len + entity_or_path.len;
            if (n2 > buf.len) continue;
            @memcpy(buf[0..pre.len], pre);
            @memcpy(buf[pre.len..n2], entity_or_path);
            if (pathSetContains(paths, buf[0..n2])) return true;
        }
    }
    return false;
}

/// Classify one internal link: asset refs → missing_assets; page routes → broken_links.
fn classifyResolvedLink(
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    all_paths: []const []const u8,
    source_path: []const u8,
    link: LinkRef,
    broken: *std.ArrayList(BrokenLink),
    missing_assets: *std.ArrayList(MissingAsset),
) !void {
    const target = link.target;
    if (target.len == 0) return;
    const is_asset_kind = isAssetLinkKind(link.kind);
    const is_absolute = target[0] == '/';

    if (is_asset_kind) {
        // Image/src: absolute → public/; relative → path relative to source file.
        const resolved = if (is_absolute)
            try absoluteToPublicPath(retain, target)
        else
            try resolveRelative(retain, source_path, target);
        if (resolved.len == 0) return;
        if (!pathSetContains(all_paths, resolved) and !hasPageCandidate(all_paths, resolved)) {
            try missing_assets.append(gpa, .{
                .source_path = source_path,
                .referenced = target,
                .line = link.line,
            });
        }
        return;
    }

    // markdown_link / html_href
    if (is_absolute) {
        // Existing public file at this URL remains an asset hit (not a route miss).
        const public_path = try absoluteToPublicPath(retain, target);
        if (pathSetContains(all_paths, public_path) or hasPageCandidate(all_paths, public_path)) {
            return;
        }
        // Otherwise evaluate as a site route / content page.
        const route_key = try absoluteToRouteKey(retain, target);
        if (route_key.len > 0 and hasPageCandidate(all_paths, route_key)) {
            return;
        }
        try broken.append(gpa, .{
            .source_path = source_path,
            .target = target,
            .line = link.line,
            .reason = "target_not_found",
        });
        return;
    }

    // Relative page/doc ref
    const resolved = try resolveRelative(retain, source_path, target);
    if (resolved.len == 0) return;
    if (pathSetContains(all_paths, resolved) or hasPageCandidate(all_paths, resolved)) return;

    const looks_page = std.mem.endsWith(u8, target, ".md") or
        std.mem.endsWith(u8, target, ".mdx") or
        std.mem.endsWith(u8, target, ".astro") or
        std.mem.eql(u8, link.kind, "markdown_link") or
        std.mem.eql(u8, link.kind, "html_href");
    if (looks_page) {
        try broken.append(gpa, .{
            .source_path = source_path,
            .target = target,
            .line = link.line,
            .reason = "target_not_found",
        });
    }
}

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

const PageInfo = struct {
    source_path: []const u8,
    kind: FileKind,
    bytes: u64,
    entity_id: []const u8,
    slug: []const u8,
    collection: ?[]const u8,
    fm: FrontmatterLite,
    body: []const u8,
    source: []const u8,
};

fn routeMatchesCollection(route_path: []const u8, collection: []const u8) bool {
    // src/pages/<collection>/[...slug].astro or [slug].astro or nested
    const prefix = "src/pages/";
    if (!std.mem.startsWith(u8, route_path, prefix)) return false;
    const rest = route_path[prefix.len..];
    if (std.mem.startsWith(u8, rest, collection) and rest.len > collection.len and rest[collection.len] == '/') {
        return std.mem.indexOfScalar(u8, rest, '[') != null;
    }
    // catch-all at pages root
    if (std.mem.eql(u8, rest, "[...slug].astro") or std.mem.eql(u8, rest, "[slug].astro") or
        std.mem.eql(u8, rest, "[...path].astro"))
        return true;
    return false;
}

fn resolveLayoutPath(
    allocator: std.mem.Allocator,
    content_path: []const u8,
    layout_field: ?[]const u8,
    layout_files: []const []const u8,
) !?[]const u8 {
    if (layout_field) |lf| {
        if (lf.len == 0) return null;
        // Absolute from project: src/layouts/...
        if (std.mem.startsWith(u8, lf, "src/layouts/") or std.mem.startsWith(u8, lf, "/src/layouts/")) {
            const p = if (lf[0] == '/') lf[1..] else lf;
            return try allocator.dupe(u8, p);
        }
        // Relative to content file
        const resolved = try resolveRelative(allocator, content_path, lf);
        return resolved;
    }
    // Prefer BaseLayout / Layout / MainLayout by name if unique-ish.
    const preferred = [_][]const u8{
        "src/layouts/BaseLayout.astro",
        "src/layouts/Layout.astro",
        "src/layouts/MainLayout.astro",
        "src/layouts/DocsLayout.astro",
    };
    for (preferred) |p| {
        if (pathSetContains(layout_files, p)) return try allocator.dupe(u8, p);
    }
    if (layout_files.len == 1) return try allocator.dupe(u8, layout_files[0]);
    return null;
}

pub fn analyze(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    root: Io.Dir,
    scan_root_label: []const u8,
) !Report {
    const all_paths = try collectAllPaths(io, gpa, retain, root);
    defer gpa.free(all_paths);

    var inventory: std.ArrayList(InventoryEntry) = .empty;
    errdefer inventory.deinit(gpa);

    var content_pages: std.ArrayList(PageInfo) = .empty;
    defer content_pages.deinit(gpa);

    var page_routes: std.ArrayList([]const u8) = .empty;
    defer page_routes.deinit(gpa);

    var layout_files: std.ArrayList([]const u8) = .empty;
    defer layout_files.deinit(gpa);

    var asset_entries: std.ArrayList(AssetEntry) = .empty;
    errdefer asset_entries.deinit(gpa);

    // Index of all paths for resolution
    var path_index: std.ArrayList([]const u8) = .empty;
    defer path_index.deinit(gpa);

    for (all_paths) |raw_path| {
        const path = try normalizeRelPathAlloc(retain, raw_path);
        try path_index.append(gpa, path);

        const st = root.statFile(io, path, .{}) catch continue;
        const bytes: u64 = st.size;
        const kind = classifyPath(path);
        const ext = fileExtension(path);
        try inventory.append(gpa, .{
            .source_path = path,
            .kind = kind,
            .bytes = bytes,
            .extension = try retain.dupe(u8, ext),
        });

        switch (kind) {
            .content_page => {
                const source = readFileAlloc(io, root, path, retain) catch continue;
                const fm = try parseFrontmatterLite(retain, source);
                const body = if (fm.present and fm.body_offset <= source.len) source[fm.body_offset..] else source;
                const entity = try retain.dupe(u8, proposeEntityId(path));
                const slug = if (fm.slug) |s| s else try retain.dupe(u8, slugFromContentPath(path));
                try content_pages.append(gpa, .{
                    .source_path = path,
                    .kind = kind,
                    .bytes = bytes,
                    .entity_id = entity,
                    .slug = slug,
                    .collection = collectionFromContentPath(path),
                    .fm = fm,
                    .body = body,
                    .source = source,
                });
            },
            .page_route => try page_routes.append(gpa, path),
            .layout => try layout_files.append(gpa, path),
            .public_asset => try asset_entries.append(gpa, .{
                .source_path = path,
                .kind = "public",
                .bytes = bytes,
            }),
            .src_asset => try asset_entries.append(gpa, .{
                .source_path = path,
                .kind = "src_assets",
                .bytes = bytes,
            }),
            else => {},
        }
    }

    // Sort inventory by path (already collected sorted, but re-assert)
    std.mem.sort(InventoryEntry, inventory.items, {}, struct {
        fn less(_: void, a: InventoryEntry, b: InventoryEntry) bool {
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    // Proposed IDs
    var proposed: std.ArrayList(ProposedId) = .empty;
    errdefer proposed.deinit(gpa);
    for (content_pages.items) |p| {
        try proposed.append(gpa, .{
            .source_path = p.source_path,
            .proposed_entity_id = p.entity_id,
            .basis = "path_under_content_root_strip_ext",
        });
    }
    for (page_routes.items) |rp| {
        // Skip pure dynamic route files for id proposals
        if (std.mem.indexOfScalar(u8, rp, '[') != null) continue;
        try proposed.append(gpa, .{
            .source_path = rp,
            .proposed_entity_id = try retain.dupe(u8, proposeEntityId(rp)),
            .basis = "path_under_src_pages_strip_ext",
        });
    }
    std.mem.sort(ProposedId, proposed.items, {}, struct {
        fn less(_: void, a: ProposedId, b: ProposedId) bool {
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    // Stitches: content + matching route + layout
    var stitches: std.ArrayList(Stitch) = .empty;
    errdefer stitches.deinit(gpa);
    for (content_pages.items) |p| {
        var route_path: ?[]const u8 = null;
        var ambiguous_route = false;
        // exact route under src/pages for any supported content root
        if (contentRootPrefix(p.source_path)) |cprefix| {
            const rest = p.source_path[cprefix.len..];
            var stem = rest;
            if (std.mem.endsWith(u8, stem, ".mdx")) stem = stem[0 .. stem.len - 4];
            if (std.mem.endsWith(u8, stem, ".md")) stem = stem[0 .. stem.len - 3];
            const exact = try std.fmt.allocPrint(retain, "src/pages/{s}.astro", .{stem});
            if (pathSetContains(page_routes.items, exact)) {
                route_path = exact;
            } else if (p.collection) |col| {
                // dynamic collection route
                for (page_routes.items) |rp| {
                    if (routeMatchesCollection(rp, col)) {
                        if (route_path == null) {
                            route_path = rp;
                        } else {
                            // A report must not silently select the first lexical
                            // dynamic route when more than one can own this content.
                            route_path = null;
                            ambiguous_route = true;
                            break;
                        }
                    }
                }
            }
        }

        const layout_path = try resolveLayoutPath(retain, p.source_path, p.fm.layout, layout_files.items);
        const complete = !ambiguous_route and route_path != null and layout_path != null;
        const notes = if (complete)
            try retain.dupe(u8, "content+route+layout resolved")
        else if (ambiguous_route)
            try retain.dupe(u8, "ambiguous matching dynamic page routes; no route selected")
        else if (route_path == null and layout_path == null)
            try retain.dupe(u8, "missing route and layout")
        else if (route_path == null)
            try retain.dupe(u8, "missing matching page route")
        else
            try retain.dupe(u8, "missing layout");

        try stitches.append(gpa, .{
            .logical_slug = p.slug,
            .content_path = p.source_path,
            .route_path = route_path,
            .layout_path = layout_path,
            .complete = complete,
            .notes = notes,
        });
    }
    // Routes without content (standalone pages)
    for (page_routes.items) |rp| {
        if (std.mem.indexOfScalar(u8, rp, '[') != null) continue;
        const ent = proposeEntityId(rp);
        var has_content = false;
        for (content_pages.items) |p| {
            if (std.mem.eql(u8, p.entity_id, ent) or std.mem.eql(u8, p.slug, ent)) {
                has_content = true;
                break;
            }
        }
        if (has_content) continue;
        const layout_path = try resolveLayoutPath(retain, rp, null, layout_files.items);
        try stitches.append(gpa, .{
            .logical_slug = try retain.dupe(u8, ent),
            .content_path = null,
            .route_path = rp,
            .layout_path = layout_path,
            .complete = false,
            .notes = try retain.dupe(u8, "standalone astro route without content collection entry"),
        });
    }
    std.mem.sort(Stitch, stitches.items, {}, struct {
        fn less(_: void, a: Stitch, b: Stitch) bool {
            const sc = std.mem.order(u8, a.logical_slug, b.logical_slug);
            if (sc != .eq) return sc == .lt;
            const ap = a.content_path orelse a.route_path orelse "";
            const bp = b.content_path orelse b.route_path orelse "";
            return std.mem.order(u8, ap, bp) == .lt;
        }
    }.less);

    // Parent/child candidates
    var parents: std.ArrayList(ParentChild) = .empty;
    errdefer parents.deinit(gpa);
    // Build set of entity ids
    var entity_set: std.ArrayList([]const u8) = .empty;
    defer entity_set.deinit(gpa);
    for (content_pages.items) |p| try entity_set.append(gpa, p.entity_id);

    for (content_pages.items) |p| {
        if (p.fm.parent) |par| {
            try parents.append(gpa, .{
                .child_source_path = p.source_path,
                .child_entity_id = p.entity_id,
                .candidate_parent_id = par,
                .reason = "frontmatter_parent",
                .confidence = "high",
            });
            continue;
        }
        if (p.fm.parent_entry) |par| {
            try parents.append(gpa, .{
                .child_source_path = p.source_path,
                .child_entity_id = p.entity_id,
                .candidate_parent_id = par,
                .reason = "frontmatter_parentEntry_legacy",
                .confidence = "medium",
            });
            continue;
        }
        // Directory heuristic: guides/intro → parent guides if docs/guides exists as page
        const slug = p.slug;
        if (std.mem.lastIndexOfScalar(u8, slug, '/')) |slash| {
            const parent_slug = slug[0..slash];
            // Prefer collection/parent entity
            var candidate: []const u8 = parent_slug;
            if (p.collection) |col| {
                candidate = try std.fmt.allocPrint(retain, "{s}/{s}", .{ col, parent_slug });
            }
            // Also try parent_slug as entity suffix match
            var found = false;
            for (entity_set.items) |eid| {
                const suffix_ok = std.mem.endsWith(u8, eid, parent_slug) and
                    (eid.len == parent_slug.len or eid[eid.len - parent_slug.len - 1] == '/');
                if (std.mem.eql(u8, eid, candidate) or suffix_ok) {
                    try parents.append(gpa, .{
                        .child_source_path = p.source_path,
                        .child_entity_id = p.entity_id,
                        .candidate_parent_id = try retain.dupe(u8, eid),
                        .reason = "directory_hierarchy",
                        .confidence = "medium",
                    });
                    found = true;
                    break;
                }
            }
            if (!found) {
                try parents.append(gpa, .{
                    .child_source_path = p.source_path,
                    .child_entity_id = p.entity_id,
                    .candidate_parent_id = try retain.dupe(u8, candidate),
                    .reason = "directory_hierarchy_unverified",
                    .confidence = "low",
                });
            }
        }
    }
    std.mem.sort(ParentChild, parents.items, {}, struct {
        fn less(_: void, a: ParentChild, b: ParentChild) bool {
            const sc = std.mem.order(u8, a.child_source_path, b.child_source_path);
            if (sc != .eq) return sc == .lt;
            return std.mem.order(u8, a.candidate_parent_id, b.candidate_parent_id) == .lt;
        }
    }.less);

    // Links + broken + missing assets
    var links: std.ArrayList(LinkRef) = .empty;
    errdefer links.deinit(gpa);
    var broken: std.ArrayList(BrokenLink) = .empty;
    errdefer broken.deinit(gpa);
    var missing_assets: std.ArrayList(MissingAsset) = .empty;
    errdefer missing_assets.deinit(gpa);
    var hazards: std.ArrayList(Hazard) = .empty;
    errdefer hazards.deinit(gpa);

    const all_path_slice = path_index.items;

    // Content-root ambiguity: both supported roots present → human review only
    // (still discover pages under each root; never scan arbitrary Markdown).
    const detected_roots = try detectContentRoots(io, retain, root);
    if (detected_roots.len > 1) {
        try hazards.append(gpa, .{
            .source_path = try retain.dupe(u8, detected_roots[1]),
            .code = "ambiguous_content_roots",
            .severity = "high",
            .message = try retain.dupe(u8, "both src/content/ and content/ exist; pages under each are inventoried — confirm which collections are authoritative"),
        });
    }

    for (content_pages.items) |p| {
        const page_links = try extractLinks(retain, p.source_path, p.source);
        for (page_links) |l| {
            try links.append(gpa, l);
            try classifyResolvedLink(gpa, retain, all_path_slice, p.source_path, l, &broken, &missing_assets);
        }

        const page_hazards = try collectHazards(retain, p.source_path, p.source, p.fm);
        for (page_hazards) |h| try hazards.append(gpa, h);
    }

    // Also scan standalone .astro routes for href/src (simple)
    for (page_routes.items) |rp| {
        const source = readFileAlloc(io, root, rp, retain) catch continue;
        const page_links = try extractLinks(retain, rp, source);
        for (page_links) |l| {
            try links.append(gpa, l);
            try classifyResolvedLink(gpa, retain, all_path_slice, rp, l, &broken, &missing_assets);
        }
    }

    std.mem.sort(LinkRef, links.items, {}, struct {
        fn less(_: void, a: LinkRef, b: LinkRef) bool {
            const sc = std.mem.order(u8, a.source_path, b.source_path);
            if (sc != .eq) return sc == .lt;
            if (a.line != b.line) return a.line < b.line;
            return std.mem.order(u8, a.target, b.target) == .lt;
        }
    }.less);
    std.mem.sort(BrokenLink, broken.items, {}, struct {
        fn less(_: void, a: BrokenLink, b: BrokenLink) bool {
            const sc = std.mem.order(u8, a.source_path, b.source_path);
            if (sc != .eq) return sc == .lt;
            if (a.line != b.line) return a.line < b.line;
            return std.mem.order(u8, a.target, b.target) == .lt;
        }
    }.less);
    std.mem.sort(MissingAsset, missing_assets.items, {}, struct {
        fn less(_: void, a: MissingAsset, b: MissingAsset) bool {
            const sc = std.mem.order(u8, a.source_path, b.source_path);
            if (sc != .eq) return sc == .lt;
            if (a.line != b.line) return a.line < b.line;
            return std.mem.order(u8, a.referenced, b.referenced) == .lt;
        }
    }.less);
    std.mem.sort(Hazard, hazards.items, {}, struct {
        fn less(_: void, a: Hazard, b: Hazard) bool {
            const sc = std.mem.order(u8, a.source_path, b.source_path);
            if (sc != .eq) return sc == .lt;
            const cc = std.mem.order(u8, a.code, b.code);
            if (cc != .eq) return cc == .lt;
            return std.mem.order(u8, a.message, b.message) == .lt;
        }
    }.less);
    std.mem.sort(AssetEntry, asset_entries.items, {}, struct {
        fn less(_: void, a: AssetEntry, b: AssetEntry) bool {
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    // Slug conflicts: same collection-relative slug from different paths
    var conflicts: std.ArrayList(SlugConflict) = .empty;
    errdefer conflicts.deinit(gpa);
    {
        // Map slug -> list of paths (arena lists)
        const Pair = struct { slug: []const u8, path: []const u8 };
        var pairs: std.ArrayList(Pair) = .empty;
        defer pairs.deinit(gpa);
        for (content_pages.items) |p| {
            try pairs.append(gpa, .{ .slug = p.slug, .path = p.source_path });
        }
        std.mem.sort(Pair, pairs.items, {}, struct {
            fn less(_: void, a: Pair, b: Pair) bool {
                const sc = std.mem.order(u8, a.slug, b.slug);
                if (sc != .eq) return sc == .lt;
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);
        var i: usize = 0;
        while (i < pairs.items.len) {
            var j = i + 1;
            while (j < pairs.items.len and std.mem.eql(u8, pairs.items[j].slug, pairs.items[i].slug)) : (j += 1) {}
            if (j - i > 1) {
                var paths = try retain.alloc([]const u8, j - i);
                var k: usize = 0;
                while (k < j - i) : (k += 1) paths[k] = pairs.items[i + k].path;
                try conflicts.append(gpa, .{
                    .slug = pairs.items[i].slug,
                    .source_paths = paths,
                    .kind = "duplicate_slug",
                });
            }
            i = j;
        }
        // Case collisions on proposed entity ids
        var id_pairs: std.ArrayList(Pair) = .empty;
        defer id_pairs.deinit(gpa);
        for (content_pages.items) |p| {
            try id_pairs.append(gpa, .{ .slug = p.entity_id, .path = p.source_path });
        }
        std.mem.sort(Pair, id_pairs.items, {}, struct {
            fn less(_: void, a: Pair, b: Pair) bool {
                // case-insensitive group key via lower compare then path
                const sc = std.ascii.orderIgnoreCase(a.slug, b.slug);
                if (sc != .eq) return sc == .lt;
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);
        i = 0;
        while (i < id_pairs.items.len) {
            var j = i + 1;
            while (j < id_pairs.items.len and std.ascii.eqlIgnoreCase(id_pairs.items[j].slug, id_pairs.items[i].slug)) : (j += 1) {}
            if (j - i > 1) {
                // Only if byte-wise ids differ
                var differ = false;
                var k: usize = i + 1;
                while (k < j) : (k += 1) {
                    if (!std.mem.eql(u8, id_pairs.items[k].slug, id_pairs.items[i].slug)) {
                        differ = true;
                        break;
                    }
                }
                if (differ) {
                    var paths = try retain.alloc([]const u8, j - i);
                    k = 0;
                    while (k < j - i) : (k += 1) paths[k] = id_pairs.items[i + k].path;
                    try conflicts.append(gpa, .{
                        .slug = id_pairs.items[i].slug,
                        .source_paths = paths,
                        .kind = "case_collision",
                    });
                }
            }
            i = j;
        }
    }
    std.mem.sort(SlugConflict, conflicts.items, {}, struct {
        fn less(_: void, a: SlugConflict, b: SlugConflict) bool {
            const sc = std.mem.order(u8, a.slug, b.slug);
            if (sc != .eq) return sc == .lt;
            return std.mem.order(u8, a.kind, b.kind) == .lt;
        }
    }.less);

    // Human review: high severity hazards + incomplete stitches + conflicts + broken links
    var review: std.ArrayList(HumanReview) = .empty;
    errdefer review.deinit(gpa);
    {
        // Aggregate by source path
        const Agg = struct {
            path: []const u8,
            codes: std.ArrayList([]const u8),
            reasons: std.ArrayList([]const u8),
        };
        var aggs: std.ArrayList(Agg) = .empty;
        defer {
            for (aggs.items) |*a| {
                a.codes.deinit(gpa);
                a.reasons.deinit(gpa);
            }
            aggs.deinit(gpa);
        }

        const ensure = struct {
            fn go(a: *std.ArrayList(Agg), alloc: std.mem.Allocator, path: []const u8) !*Agg {
                for (a.items) |*it| {
                    if (std.mem.eql(u8, it.path, path)) return it;
                }
                try a.append(alloc, .{
                    .path = path,
                    .codes = .empty,
                    .reasons = .empty,
                });
                return &a.items[a.items.len - 1];
            }
        }.go;

        for (hazards.items) |h| {
            if (!std.mem.eql(u8, h.severity, "high")) continue;
            const agg = try ensure(&aggs, gpa, h.source_path);
            try agg.codes.append(gpa, h.code);
            try agg.reasons.append(gpa, h.message);
        }
        for (stitches.items) |s| {
            if (s.complete) continue;
            const path = s.content_path orelse s.route_path orelse continue;
            const agg = try ensure(&aggs, gpa, path);
            try agg.codes.append(gpa, "incomplete_stitch");
            try agg.reasons.append(gpa, s.notes);
        }
        for (conflicts.items) |c| {
            for (c.source_paths) |sp| {
                const agg = try ensure(&aggs, gpa, sp);
                try agg.codes.append(gpa, c.kind);
                try agg.reasons.append(gpa, try std.fmt.allocPrint(retain, "slug conflict on '{s}'", .{c.slug}));
            }
        }
        for (broken.items) |b| {
            const agg = try ensure(&aggs, gpa, b.source_path);
            try agg.codes.append(gpa, "broken_link");
            try agg.reasons.append(gpa, try std.fmt.allocPrint(retain, "broken link {s}", .{b.target}));
        }
        for (missing_assets.items) |m| {
            const agg = try ensure(&aggs, gpa, m.source_path);
            try agg.codes.append(gpa, "missing_asset");
            try agg.reasons.append(gpa, try std.fmt.allocPrint(retain, "missing asset {s}", .{m.referenced}));
        }

        std.mem.sort(Agg, aggs.items, {}, struct {
            fn less(_: void, a: Agg, b: Agg) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);

        for (aggs.items) |agg| {
            // Dedupe codes
            std.mem.sort([]const u8, agg.codes.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less);
            var uniq_codes: std.ArrayList([]const u8) = .empty;
            defer uniq_codes.deinit(gpa);
            var prev: ?[]const u8 = null;
            for (agg.codes.items) |c| {
                if (prev) |p| if (std.mem.eql(u8, p, c)) continue;
                try uniq_codes.append(gpa, c);
                prev = c;
            }
            const codes_slice = try retain.alloc([]const u8, uniq_codes.items.len);
            @memcpy(codes_slice, uniq_codes.items);

            // Join reasons deterministically
            std.mem.sort([]const u8, agg.reasons.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less);
            var reason_buf: std.ArrayList(u8) = .empty;
            defer reason_buf.deinit(gpa);
            var prev_r: ?[]const u8 = null;
            for (agg.reasons.items) |r| {
                if (prev_r) |p| if (std.mem.eql(u8, p, r)) continue;
                if (reason_buf.items.len > 0) try reason_buf.appendSlice(gpa, "; ");
                try reason_buf.appendSlice(gpa, r);
                prev_r = r;
            }
            try review.append(gpa, .{
                .source_path = agg.path,
                .reason = try retain.dupe(u8, reason_buf.items),
                .codes = codes_slice,
            });
        }
    }

    return .{
        .scan_root = try retain.dupe(u8, scan_root_label),
        .inventory = try inventory.toOwnedSlice(gpa),
        .stitches = try stitches.toOwnedSlice(gpa),
        .proposed_ids = try proposed.toOwnedSlice(gpa),
        .parent_child_candidates = try parents.toOwnedSlice(gpa),
        .links = try links.toOwnedSlice(gpa),
        .broken_links = try broken.toOwnedSlice(gpa),
        .slug_conflicts = try conflicts.toOwnedSlice(gpa),
        .assets = try asset_entries.toOwnedSlice(gpa),
        .missing_assets = try missing_assets.toOwnedSlice(gpa),
        .hazards = try hazards.toOwnedSlice(gpa),
        .human_review = try review.toOwnedSlice(gpa),
    };
}

// ---------------------------------------------------------------------------
// Report emission
// ---------------------------------------------------------------------------

fn jsonEscapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const piece = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(gpa, piece);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
}

fn appendJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    try jsonEscapeAppend(buf, gpa, s);
    try buf.append(gpa, '"');
}

fn appendJsonStringOpt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| {
        try appendJsonString(buf, gpa, v);
    } else {
        try buf.appendSlice(gpa, "null");
    }
}

fn emitJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try buf.appendSlice(gpa, "  \"format\": \"");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "\",\n");
    try buf.appendSlice(gpa, "  \"schema_version\": ");
    try buf.print(gpa, "{d}", .{schema_version});
    try buf.appendSlice(gpa, ",\n");
    try buf.appendSlice(gpa, "  \"tool_version\": \"");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "\",\n");
    try buf.appendSlice(gpa, "  \"scan_root\": ");
    try appendJsonString(&buf, gpa, report.scan_root);
    try buf.appendSlice(gpa, ",\n");

    // summary
    try buf.appendSlice(gpa, "  \"summary\": {\n");
    try buf.print(gpa,
        \\    "inventory_count": {d},
        \\    "content_page_count": {d},
        \\    "stitch_count": {d},
        \\    "complete_stitch_count": {d},
        \\    "proposed_id_count": {d},
        \\    "parent_child_count": {d},
        \\    "link_count": {d},
        \\    "broken_link_count": {d},
        \\    "slug_conflict_count": {d},
        \\    "asset_count": {d},
        \\    "missing_asset_count": {d},
        \\    "hazard_count": {d},
        \\    "human_review_count": {d}
        \\
    , .{
        report.inventory.len,
        countKind(report.inventory, .content_page),
        report.stitches.len,
        countCompleteStitches(report.stitches),
        report.proposed_ids.len,
        report.parent_child_candidates.len,
        report.links.len,
        report.broken_links.len,
        report.slug_conflicts.len,
        report.assets.len,
        report.missing_assets.len,
        report.hazards.len,
        report.human_review.len,
    });
    try buf.appendSlice(gpa, "  },\n");

    // inventory
    try buf.appendSlice(gpa, "  \"inventory\": [\n");
    for (report.inventory, 0..) |e, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, e.source_path);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try appendJsonString(&buf, gpa, e.kind.jsonName());
        try buf.print(gpa, ", \"bytes\": {d}, \"extension\": ", .{e.bytes});
        try appendJsonString(&buf, gpa, e.extension);
        try buf.append(gpa, '}');
        if (idx + 1 < report.inventory.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // stitches
    try buf.appendSlice(gpa, "  \"stitches\": [\n");
    for (report.stitches, 0..) |s, idx| {
        try buf.appendSlice(gpa, "    {\"logical_slug\": ");
        try appendJsonString(&buf, gpa, s.logical_slug);
        try buf.appendSlice(gpa, ", \"content_path\": ");
        try appendJsonStringOpt(&buf, gpa, s.content_path);
        try buf.appendSlice(gpa, ", \"route_path\": ");
        try appendJsonStringOpt(&buf, gpa, s.route_path);
        try buf.appendSlice(gpa, ", \"layout_path\": ");
        try appendJsonStringOpt(&buf, gpa, s.layout_path);
        try buf.appendSlice(gpa, if (s.complete) ", \"complete\": true" else ", \"complete\": false");
        try buf.appendSlice(gpa, ", \"notes\": ");
        try appendJsonString(&buf, gpa, s.notes);
        try buf.append(gpa, '}');
        if (idx + 1 < report.stitches.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // proposed_ids
    try buf.appendSlice(gpa, "  \"proposed_ids\": [\n");
    for (report.proposed_ids, 0..) |p, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ", \"proposed_entity_id\": ");
        try appendJsonString(&buf, gpa, p.proposed_entity_id);
        try buf.appendSlice(gpa, ", \"basis\": ");
        try appendJsonString(&buf, gpa, p.basis);
        try buf.append(gpa, '}');
        if (idx + 1 < report.proposed_ids.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // parent_child
    try buf.appendSlice(gpa, "  \"parent_child_candidates\": [\n");
    for (report.parent_child_candidates, 0..) |p, idx| {
        try buf.appendSlice(gpa, "    {\"child_source_path\": ");
        try appendJsonString(&buf, gpa, p.child_source_path);
        try buf.appendSlice(gpa, ", \"child_entity_id\": ");
        try appendJsonString(&buf, gpa, p.child_entity_id);
        try buf.appendSlice(gpa, ", \"candidate_parent_id\": ");
        try appendJsonString(&buf, gpa, p.candidate_parent_id);
        try buf.appendSlice(gpa, ", \"reason\": ");
        try appendJsonString(&buf, gpa, p.reason);
        try buf.appendSlice(gpa, ", \"confidence\": ");
        try appendJsonString(&buf, gpa, p.confidence);
        try buf.append(gpa, '}');
        if (idx + 1 < report.parent_child_candidates.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // links
    try buf.appendSlice(gpa, "  \"links\": [\n");
    for (report.links, 0..) |l, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, l.source_path);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try appendJsonString(&buf, gpa, l.kind);
        try buf.appendSlice(gpa, ", \"target\": ");
        try appendJsonString(&buf, gpa, l.target);
        try buf.print(gpa, ", \"line\": {d}, \"internal\": true}}", .{l.line});
        if (idx + 1 < report.links.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // broken_links
    try buf.appendSlice(gpa, "  \"broken_links\": [\n");
    for (report.broken_links, 0..) |l, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, l.source_path);
        try buf.appendSlice(gpa, ", \"target\": ");
        try appendJsonString(&buf, gpa, l.target);
        try buf.print(gpa, ", \"line\": {d}, \"reason\": ", .{l.line});
        try appendJsonString(&buf, gpa, l.reason);
        try buf.append(gpa, '}');
        if (idx + 1 < report.broken_links.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // slug_conflicts
    try buf.appendSlice(gpa, "  \"slug_conflicts\": [\n");
    for (report.slug_conflicts, 0..) |c, idx| {
        try buf.appendSlice(gpa, "    {\"slug\": ");
        try appendJsonString(&buf, gpa, c.slug);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try appendJsonString(&buf, gpa, c.kind);
        try buf.appendSlice(gpa, ", \"source_paths\": [");
        for (c.source_paths, 0..) |sp, si| {
            try appendJsonString(&buf, gpa, sp);
            if (si + 1 < c.source_paths.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "]}");
        if (idx + 1 < report.slug_conflicts.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // assets
    try buf.appendSlice(gpa, "  \"assets\": [\n");
    for (report.assets, 0..) |a, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, a.source_path);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try appendJsonString(&buf, gpa, a.kind);
        try buf.print(gpa, ", \"bytes\": {d}}}", .{a.bytes});
        if (idx + 1 < report.assets.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // missing_assets
    try buf.appendSlice(gpa, "  \"missing_assets\": [\n");
    for (report.missing_assets, 0..) |m, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, m.source_path);
        try buf.appendSlice(gpa, ", \"referenced\": ");
        try appendJsonString(&buf, gpa, m.referenced);
        try buf.print(gpa, ", \"line\": {d}}}", .{m.line});
        if (idx + 1 < report.missing_assets.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // hazards
    try buf.appendSlice(gpa, "  \"hazards\": [\n");
    for (report.hazards, 0..) |h, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, h.source_path);
        try buf.appendSlice(gpa, ", \"code\": ");
        try appendJsonString(&buf, gpa, h.code);
        try buf.appendSlice(gpa, ", \"severity\": ");
        try appendJsonString(&buf, gpa, h.severity);
        try buf.appendSlice(gpa, ", \"message\": ");
        try appendJsonString(&buf, gpa, h.message);
        try buf.append(gpa, '}');
        if (idx + 1 < report.hazards.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ],\n");

    // human_review
    try buf.appendSlice(gpa, "  \"human_review\": [\n");
    for (report.human_review, 0..) |h, idx| {
        try buf.appendSlice(gpa, "    {\"source_path\": ");
        try appendJsonString(&buf, gpa, h.source_path);
        try buf.appendSlice(gpa, ", \"reason\": ");
        try appendJsonString(&buf, gpa, h.reason);
        try buf.appendSlice(gpa, ", \"codes\": [");
        for (h.codes, 0..) |c, ci| {
            try appendJsonString(&buf, gpa, c);
            if (ci + 1 < h.codes.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "]}");
        if (idx + 1 < report.human_review.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n");
    try buf.appendSlice(gpa, "}\n");

    return try buf.toOwnedSlice(gpa);
}

fn countKind(inv: []const InventoryEntry, kind: FileKind) usize {
    var n: usize = 0;
    for (inv) |e| {
        if (e.kind == kind) n += 1;
    }
    return n;
}

fn countCompleteStitches(stitches: []const Stitch) usize {
    var n: usize = 0;
    for (stitches) |s| {
        if (s.complete) n += 1;
    }
    return n;
}

fn emitMarkdown(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "# Astro → Boris migration archaeology\n\n");
    try buf.print(gpa, "Format `{s}` schema `{d}` tool `{s}`.\n\n", .{ format_id, schema_version, tool_version });
    try buf.print(gpa, "Scan root: `{s}`\n\n", .{report.scan_root});
    try buf.appendSlice(gpa, "This report is **read-only archaeology**. Originals were not modified.\n\n");

    try buf.appendSlice(gpa, "## Summary\n\n");
    try buf.appendSlice(gpa, "| Metric | Count |\n|---|---:|\n");
    try buf.print(gpa, "| Inventory files | {d} |\n", .{report.inventory.len});
    try buf.print(gpa, "| Content pages | {d} |\n", .{countKind(report.inventory, .content_page)});
    try buf.print(gpa, "| Stitches | {d} |\n", .{report.stitches.len});
    try buf.print(gpa, "| Complete stitches | {d} |\n", .{countCompleteStitches(report.stitches)});
    try buf.print(gpa, "| Proposed entity ids | {d} |\n", .{report.proposed_ids.len});
    try buf.print(gpa, "| Parent/child candidates | {d} |\n", .{report.parent_child_candidates.len});
    try buf.print(gpa, "| Internal links | {d} |\n", .{report.links.len});
    try buf.print(gpa, "| Broken links | {d} |\n", .{report.broken_links.len});
    try buf.print(gpa, "| slug conflicts | {d} |\n", .{report.slug_conflicts.len});
    try buf.print(gpa, "| Assets | {d} |\n", .{report.assets.len});
    try buf.print(gpa, "| Missing assets | {d} |\n", .{report.missing_assets.len});
    try buf.print(gpa, "| Hazards | {d} |\n", .{report.hazards.len});
    try buf.print(gpa, "| Human review | {d} |\n\n", .{report.human_review.len});

    try buf.appendSlice(gpa, "## Inventory\n\n");
    try buf.appendSlice(gpa, "| source_path | kind | bytes |\n|---|---|---:|\n");
    for (report.inventory) |e| {
        try buf.print(gpa, "| `{s}` | {s} | {d} |\n", .{ e.source_path, e.kind.jsonName(), e.bytes });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Three-file stitches\n\n");
    try buf.appendSlice(gpa, "A stitch binds **content** + **page route** + **layout** for one logical page.\n\n");
    try buf.appendSlice(gpa, "| slug | content | route | layout | complete | notes |\n|---|---|---|---|---|---|\n");
    for (report.stitches) |s| {
        try buf.print(gpa, "| `{s}` | `{s}` | `{s}` | `{s}` | {s} | {s} |\n", .{
            s.logical_slug,
            s.content_path orelse "—",
            s.route_path orelse "—",
            s.layout_path orelse "—",
            if (s.complete) "yes" else "no",
            s.notes,
        });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Proposed Boris entity ids\n\n");
    try buf.appendSlice(gpa, "| source_path | proposed_entity_id | basis |\n|---|---|---|\n");
    for (report.proposed_ids) |p| {
        try buf.print(gpa, "| `{s}` | `{s}` | {s} |\n", .{ p.source_path, p.proposed_entity_id, p.basis });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Parent / child candidates\n\n");
    try buf.appendSlice(gpa, "| child_source_path | child_id | parent_id | reason | confidence |\n|---|---|---|---|---|\n");
    for (report.parent_child_candidates) |p| {
        try buf.print(gpa, "| `{s}` | `{s}` | `{s}` | {s} | {s} |\n", .{
            p.child_source_path,
            p.child_entity_id,
            p.candidate_parent_id,
            p.reason,
            p.confidence,
        });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Internal links\n\n");
    try buf.appendSlice(gpa, "| source_path | line | kind | target |\n|---|---:|---|---|\n");
    for (report.links) |l| {
        try buf.print(gpa, "| `{s}` | {d} | {s} | `{s}` |\n", .{ l.source_path, l.line, l.kind, l.target });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Broken links\n\n");
    if (report.broken_links.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        try buf.appendSlice(gpa, "| source_path | line | target | reason |\n|---|---:|---|---|\n");
        for (report.broken_links) |l| {
            try buf.print(gpa, "| `{s}` | {d} | `{s}` | {s} |\n", .{ l.source_path, l.line, l.target, l.reason });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Slug conflicts\n\n");
    if (report.slug_conflicts.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.slug_conflicts) |c| {
            try buf.print(gpa, "- **`{s}`** ({s}):\n", .{ c.slug, c.kind });
            for (c.source_paths) |sp| try buf.print(gpa, "  - `{s}`\n", .{sp});
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Assets\n\n");
    try buf.appendSlice(gpa, "| source_path | kind | bytes |\n|---|---|---:|\n");
    for (report.assets) |a| {
        try buf.print(gpa, "| `{s}` | {s} | {d} |\n", .{ a.source_path, a.kind, a.bytes });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Missing asset references\n\n");
    if (report.missing_assets.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        try buf.appendSlice(gpa, "| source_path | line | referenced |\n|---|---:|---|\n");
        for (report.missing_assets) |m| {
            try buf.print(gpa, "| `{s}` | {d} | `{s}` |\n", .{ m.source_path, m.line, m.referenced });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Frontmatter / content hazards\n\n");
    if (report.hazards.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        try buf.appendSlice(gpa, "| source_path | severity | code | message |\n|---|---|---|---|\n");
        for (report.hazards) |h| {
            try buf.print(gpa, "| `{s}` | {s} | `{s}` | {s} |\n", .{ h.source_path, h.severity, h.code, h.message });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Human review\n\n");
    try buf.appendSlice(gpa, "Pages/files that need author judgment before conversion.\n\n");
    if (report.human_review.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.human_review) |h| {
            try buf.print(gpa, "### `{s}`\n\n", .{h.source_path});
            try buf.appendSlice(gpa, "- Codes: ");
            for (h.codes, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try buf.print(gpa, "`{s}`", .{c});
            }
            try buf.appendSlice(gpa, "\n");
            try buf.print(gpa, "- Reason: {s}\n\n", .{h.reason});
        }
    }

    try buf.appendSlice(gpa, "---\n\nMachine-readable twin: `report.json`.\n");
    return try buf.toOwnedSlice(gpa);
}

fn freeReport(gpa: std.mem.Allocator, report: *Report) void {
    gpa.free(report.inventory);
    gpa.free(report.stitches);
    gpa.free(report.proposed_ids);
    gpa.free(report.parent_child_candidates);
    gpa.free(report.links);
    gpa.free(report.broken_links);
    gpa.free(report.slug_conflicts);
    gpa.free(report.assets);
    gpa.free(report.missing_assets);
    gpa.free(report.hazards);
    gpa.free(report.human_review);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true });
    defer root.close(io);

    // Normalize scan label to the user-provided root string (no absolute host paths).
    const scan_label = opts.root_dir;

    var report = try analyze(io, gpa, retain, root, scan_label);
    defer freeReport(gpa, &report);

    const json = try emitJson(gpa, report);
    defer gpa.free(json);
    const md = try emitMarkdown(gpa, report);
    defer gpa.free(md);

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);

    try writeBytes(io, out, "report.json", json);
    try writeBytes(io, out, "REPORT.md", md);

    if (!opts.quiet) {
        std.debug.print("migration-lab: wrote {s}/report.json and {s}/REPORT.md\n", .{ opts.out_dir, opts.out_dir });
        std.debug.print("  inventory={d} stitches={d} hazards={d} human_review={d}\n", .{
            report.inventory.len,
            report.stitches.len,
            report.hazards.len,
            report.human_review.len,
        });
    }
}
