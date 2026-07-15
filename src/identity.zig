//! Centralized canonical identity and path derivation (milestone 4).
//!
//! Pure path logic — no I/O. Callers own allocation of returned strings.
//!
//! **Single derivation entry for entity ids:**
//!
//! ```text
//! canonicalEntityId(allocator, source_path)
//! ```
//!
//! Every product path that turns a content-root-relative source path into a
//! graph key or an output path must go through this module (not ad-hoc string
//! slicing). See docs/contracts/identity-and-paths.md and scanner.md.
//!
//! ## Rules (v0.1)
//!
//! - Entity ids preserve letter case of the source stem.
//! - Separators in logical metadata are always `/`.
//! - Page extensions are **case-sensitive**: only `.md` and `.mdx`.
//! - Output paths are built only from validated entity ids (cannot escape).

const std = @import("std");

/// Max UTF-8 **bytes** for entity ids (path-derived and future frontmatter `id`).
pub const max_entity_id_bytes: usize = 255;

pub const PathError = error{
    EmptyPath,
    AbsolutePath,
    IllegalSegment,
    EmptyId,
    /// Path does not end with an accepted page extension (`.md` / `.mdx`).
    UnsupportedExtension,
    /// Derived entity id exceeds `max_entity_id_bytes`.
    IdTooLong,
} || std.mem.Allocator.Error;

/// Content kind derived from the trailing page extension.
pub const ContentKind = enum {
    md,
    mdx,

    pub fn extension(self: ContentKind) []const u8 {
        return switch (self) {
            .md => ".md",
            .mdx => ".mdx",
        };
    }
};

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Case-sensitive page-extension check on a basename or full relative path.
pub fn isPageFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".mdx") or std.mem.endsWith(u8, name, ".md");
}

/// Length of the accepted trailing page extension, or null if not a page file.
pub fn pageExtensionLen(path: []const u8) ?usize {
    if (std.mem.endsWith(u8, path, ".mdx")) return 4;
    if (std.mem.endsWith(u8, path, ".md")) return 3;
    return null;
}

/// Content kind for a path ending with an accepted page extension.
pub fn contentKind(path: []const u8) PathError!ContentKind {
    if (std.mem.endsWith(u8, path, ".mdx")) return .mdx;
    if (std.mem.endsWith(u8, path, ".md")) return .md;
    return error.UnsupportedExtension;
}

/// Normalize a content-root-relative path to canonical form.
///
/// Rules:
/// - Input must be relative (no leading `/`, no Windows drive prefix)
/// - `/` separators only in the result
/// - no leading `/` or `./`
/// - no empty, `.`, or `..` segments (after normalization — never fold `..`)
/// - no trailing `/`
/// - letter case preserved
///
/// Returns a newly allocated string from `allocator` on success.
pub fn canonicalize(allocator: std.mem.Allocator, raw: []const u8) PathError![]u8 {
    if (raw.len == 0) return error.EmptyPath;

    // Reject absolute paths (POSIX and Windows drive).
    if (isSep(raw[0])) return error.AbsolutePath;
    if (raw.len >= 2 and raw[1] == ':' and std.ascii.isAlphabetic(raw[0])) return error.AbsolutePath;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    // Strip a single leading "./" or ".\"
    if (i + 1 < raw.len and raw[i] == '.' and isSep(raw[i + 1])) i += 2;

    var need_slash = false;
    while (i < raw.len) {
        // Empty segment (leading sep after strip, `//`, or trailing `/`).
        if (isSep(raw[i])) return error.IllegalSegment;

        const seg_start = i;
        while (i < raw.len and !isSep(raw[i])) : (i += 1) {}
        const seg = raw[seg_start..i];

        if (seg.len == 0) return error.IllegalSegment;
        if (std.mem.eql(u8, seg, ".")) return error.IllegalSegment;
        if (std.mem.eql(u8, seg, "..")) return error.IllegalSegment;

        if (need_slash) try buf.append(allocator, '/');
        try buf.appendSlice(allocator, seg);
        need_slash = true;

        if (i < raw.len) {
            // Exactly one separator between segments; trailing sep → illegal.
            i += 1;
            if (i >= raw.len) return error.IllegalSegment;
            // Next char must start a segment (not another sep).
            if (isSep(raw[i])) return error.IllegalSegment;
        }
    }

    if (buf.items.len == 0) return error.EmptyPath;
    return try buf.toOwnedSlice(allocator);
}

/// True when `id` is a well-formed entity id for graph keys and output paths.
pub fn validateEntityId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id.len > max_entity_id_bytes) return false;
    if (id[0] == '/') return false;
    if (id[id.len - 1] == '/' or id[id.len - 1] == '\\') return false;

    var i: usize = 0;
    while (i < id.len) {
        const start = i;
        while (i < id.len and id[i] != '/' and id[i] != '\\') : (i += 1) {}
        if (i < id.len and id[i] == '\\') return false;
        const seg = id[start..i];
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
        }
        if (i < id.len) i += 1; // skip '/'
    }
    return true;
}

/// Strip a single trailing page extension (`.md` or `.mdx`) from a canonical
/// source path. Returns a slice into `source_path` (no allocation).
pub fn stemFromSourcePath(source_path: []const u8) PathError![]const u8 {
    const ext_len = pageExtensionLen(source_path) orelse return error.UnsupportedExtension;
    const stem = source_path[0 .. source_path.len - ext_len];
    if (stem.len == 0) return error.EmptyId;
    if (stem[stem.len - 1] == '/' or stem[stem.len - 1] == '\\') return error.EmptyId;
    return stem;
}

/// Normalize a path-stem or future frontmatter id into a stable entity id:
/// - replace every `\` with `/`
/// - **preserve** letter case
/// - reject empty / illegal segments and oversize ids
pub fn normalizeEntityId(allocator: std.mem.Allocator, stem: []const u8) PathError![]u8 {
    if (stem.len == 0) return error.EmptyId;
    if (stem.len > max_entity_id_bytes) return error.IdTooLong;

    const out = try allocator.alloc(u8, stem.len);
    errdefer allocator.free(out);
    for (stem, 0..) |c, i| {
        out[i] = if (c == '\\') '/' else c;
    }
    if (!validateEntityId(out)) {
        if (stem.len > 0 and (stem[0] == '/' or stem[0] == '\\')) return error.AbsolutePath;
        return error.IllegalSegment;
    }
    return out;
}

/// **Canonical entity-id derivation** — the single function for graph keys.
///
/// Input must be a content-root-relative source path (platform separators OK).
/// Steps:
/// 1. `canonicalize` (reject absolute, `.` / `..` / empty segments)
/// 2. require case-sensitive page extension (`.md` / `.mdx`)
/// 3. strip one trailing extension
/// 4. validate entity-id shape (no leading `/`, no `\`, no empty/`.`/`..`)
/// 5. preserve letter case
///
/// Allocates; caller owns the returned slice.
pub fn canonicalEntityId(allocator: std.mem.Allocator, source_path: []const u8) PathError![]u8 {
    const canon = try canonicalize(allocator, source_path);
    defer allocator.free(canon);

    const stem = try stemFromSourcePath(canon);
    if (stem.len > max_entity_id_bytes) return error.IdTooLong;
    if (!validateEntityId(stem)) return error.IllegalSegment;
    return try allocator.dupe(u8, stem);
}

/// HTML (or other artifact) path relative to an output root, built **only**
/// from a validated entity id. Never introduces `..` or absolute segments.
///
/// Result: `{entity_id}.html` — safe to join under any output root.
pub fn safeOutputRelativePath(allocator: std.mem.Allocator, entity_id: []const u8) PathError![]u8 {
    if (!validateEntityId(entity_id)) {
        if (entity_id.len == 0) return error.EmptyId;
        if (entity_id.len > max_entity_id_bytes) return error.IdTooLong;
        if (entity_id[0] == '/' or entity_id[0] == '\\') return error.AbsolutePath;
        return error.IllegalSegment;
    }
    return try std.fmt.allocPrint(allocator, "{s}.html", .{entity_id});
}

/// Alias for HTML path derivation (historical name).
pub fn htmlOutputPath(allocator: std.mem.Allocator, entity_id: []const u8) PathError![]u8 {
    return safeOutputRelativePath(allocator, entity_id);
}

/// RAG page path relative to the RAG root (`content/pages/<entity_id>.md`).
pub fn ragPagePath(allocator: std.mem.Allocator, entity_id: []const u8) PathError![]u8 {
    if (!validateEntityId(entity_id)) {
        if (entity_id.len == 0) return error.EmptyId;
        if (entity_id.len > max_entity_id_bytes) return error.IdTooLong;
        if (entity_id[0] == '/' or entity_id[0] == '\\') return error.AbsolutePath;
        return error.IllegalSegment;
    }
    return try std.fmt.allocPrint(allocator, "content/pages/{s}.md", .{entity_id});
}

/// True when `a` and `b` are equal ignoring ASCII case but not byte-identical.
pub fn pathsDifferOnlyInCase(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Relative `href` from a page at `from_output` to a page at `to_output`.
///
/// Both paths are site-root-relative with `/` separators and no leading `/`
/// (e.g. `guides/intro.html`, `index.html`). Result never uses a leading `/`.
///
/// Examples:
/// - `guides/intro.html` → `index.html` ⇒ `../index.html`
/// - `index.html` → `guides/intro.html` ⇒ `guides/intro.html`
/// - `guides/a.html` → `guides/b.html` ⇒ `b.html`
pub fn relativeHref(allocator: std.mem.Allocator, from_output: []const u8, to_output: []const u8) ![]u8 {
    const from_dir = std.fs.path.dirnamePosix(from_output) orelse "";
    const to_dir = std.fs.path.dirnamePosix(to_output) orelse "";
    const to_base = std.fs.path.basenamePosix(to_output);

    // Split directory paths into components (empty dir → zero components).
    var from_parts: [32][]const u8 = undefined;
    var to_parts: [32][]const u8 = undefined;
    const from_n = splitPathComponents(from_dir, &from_parts);
    const to_n = splitPathComponents(to_dir, &to_parts);

    var common: usize = 0;
    while (common < from_n and common < to_n) : (common += 1) {
        if (!std.mem.eql(u8, from_parts[common], to_parts[common])) break;
    }

    var up = from_n - common;
    // Build: (../)* + remaining to_dir components + basename
    var total: usize = 0;
    total += up * 3; // "../"
    var i = common;
    while (i < to_n) : (i += 1) {
        total += to_parts[i].len + 1; // component + '/'
    }
    total += to_base.len;

    if (total == 0) return try allocator.dupe(u8, ".");

    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    var off: usize = 0;
    while (up > 0) : (up -= 1) {
        @memcpy(out[off .. off + 3], "../");
        off += 3;
    }
    i = common;
    while (i < to_n) : (i += 1) {
        @memcpy(out[off .. off + to_parts[i].len], to_parts[i]);
        off += to_parts[i].len;
        out[off] = '/';
        off += 1;
    }
    @memcpy(out[off .. off + to_base.len], to_base);
    off += to_base.len;
    std.debug.assert(off == total);
    return out;
}

fn splitPathComponents(dir: []const u8, out: [][]const u8) usize {
    if (dir.len == 0) return 0;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            if (i > start) {
                if (n >= out.len) return n; // truncate defensively
                out[n] = dir[start..i];
                n += 1;
            }
            start = i + 1;
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "relativeHref same dir one level up and root to nested" {
    const gpa = std.testing.allocator;

    const same = try relativeHref(gpa, "guides/a.html", "guides/b.html");
    defer gpa.free(same);
    try std.testing.expectEqualStrings("b.html", same);

    const up = try relativeHref(gpa, "guides/intro.html", "index.html");
    defer gpa.free(up);
    try std.testing.expectEqualStrings("../index.html", up);

    const down = try relativeHref(gpa, "index.html", "guides/intro.html");
    defer gpa.free(down);
    try std.testing.expectEqualStrings("guides/intro.html", down);

    const deep = try relativeHref(gpa, "a/b/c.html", "x/y.html");
    defer gpa.free(deep);
    try std.testing.expectEqualStrings("../../x/y.html", deep);

    const self = try relativeHref(gpa, "guides/intro.html", "guides/intro.html");
    defer gpa.free(self);
    try std.testing.expectEqualStrings("intro.html", self);
}

test "canonicalize basic and nested" {
    const gpa = std.testing.allocator;
    const p = try canonicalize(gpa, "guides/intro.md");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("guides/intro.md", p);

    const n = try canonicalize(gpa, "nested/deep/page.md");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("nested/deep/page.md", n);
}

test "canonicalize rejects absolute empty and dot components" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.EmptyPath, canonicalize(gpa, ""));
    try std.testing.expectError(error.IllegalSegment, canonicalize(gpa, "../x.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(gpa, "a/../b.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(gpa, "a//b.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(gpa, "a/./b.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(gpa, "a/b/"));
    try std.testing.expectError(error.AbsolutePath, canonicalize(gpa, "/abs.md"));
    try std.testing.expectError(error.AbsolutePath, canonicalize(gpa, "C:\\abs.md"));
    try std.testing.expectError(error.AbsolutePath, canonicalize(gpa, "c:/abs.md"));
}

test "canonicalize normalizes backslash and leading dot-slash" {
    const gpa = std.testing.allocator;
    const p = try canonicalize(gpa, "./guides\\intro.md");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("guides/intro.md", p);
}

test "isPageFile extension policy is case-sensitive lowercase only" {
    try std.testing.expect(isPageFile("x.md"));
    try std.testing.expect(isPageFile("x.mdx"));
    try std.testing.expect(isPageFile("nested/x.md"));
    try std.testing.expect(!isPageFile("x.MD"));
    try std.testing.expect(!isPageFile("x.Md"));
    try std.testing.expect(!isPageFile("x.MDX"));
    try std.testing.expect(!isPageFile("x.Mdx"));
    try std.testing.expect(!isPageFile("x.txt"));
    try std.testing.expect(!isPageFile("readme.TXT"));
    try std.testing.expect(!isPageFile("md"));
}

test "canonicalEntityId is the single derivation path" {
    const gpa = std.testing.allocator;

    const a = try canonicalEntityId(gpa, "index.md");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("index", a);

    const b = try canonicalEntityId(gpa, "guides/intro.md");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("guides/intro", b);

    const c = try canonicalEntityId(gpa, "Guides/Intro.md");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("Guides/Intro", c);

    const d = try canonicalEntityId(gpa, "nested/deep/page.md");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("nested/deep/page", d);

    const e = try canonicalEntityId(gpa, "Guides\\Intro.md");
    defer gpa.free(e);
    try std.testing.expectEqualStrings("Guides/Intro", e);

    const f = try canonicalEntityId(gpa, "my.notes.md");
    defer gpa.free(f);
    try std.testing.expectEqualStrings("my.notes", f);

    const g = try canonicalEntityId(gpa, "nested/Path/Page.mdx");
    defer gpa.free(g);
    try std.testing.expectEqualStrings("nested/Path/Page", g);
}

test "canonicalEntityId rejects traversal non-page and empty stem" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.IllegalSegment, canonicalEntityId(gpa, "../escape.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalEntityId(gpa, "a/../b.md"));
    try std.testing.expectError(error.AbsolutePath, canonicalEntityId(gpa, "/abs.md"));
    try std.testing.expectError(error.UnsupportedExtension, canonicalEntityId(gpa, "notes.txt"));
    try std.testing.expectError(error.UnsupportedExtension, canonicalEntityId(gpa, "notes.MD"));
    try std.testing.expectError(error.EmptyId, canonicalEntityId(gpa, ".md"));
    try std.testing.expectError(error.EmptyId, canonicalEntityId(gpa, ".mdx"));
}

test "canonicalEntityId rejects oversize stem" {
    const gpa = std.testing.allocator;
    var long: [max_entity_id_bytes + 1 + 3]u8 = undefined;
    @memset(long[0 .. max_entity_id_bytes + 1], 'z');
    @memcpy(long[max_entity_id_bytes + 1 ..], ".md");
    try std.testing.expectError(error.IdTooLong, canonicalEntityId(gpa, &long));
}

test "safeOutputRelativePath never escapes via bad entity ids" {
    const gpa = std.testing.allocator;

    const html = try safeOutputRelativePath(gpa, "guides/intro");
    defer gpa.free(html);
    try std.testing.expectEqualStrings("guides/intro.html", html);

    const nested = try safeOutputRelativePath(gpa, "nested/deep/page");
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("nested/deep/page.html", nested);

    try std.testing.expectError(error.IllegalSegment, safeOutputRelativePath(gpa, "../etc/passwd"));
    try std.testing.expectError(error.IllegalSegment, safeOutputRelativePath(gpa, "a/../../x"));
    try std.testing.expectError(error.AbsolutePath, safeOutputRelativePath(gpa, "/abs"));
    try std.testing.expectError(error.IllegalSegment, safeOutputRelativePath(gpa, "a\\b"));
    try std.testing.expectError(error.EmptyId, safeOutputRelativePath(gpa, ""));
}

test "validateEntityId shape" {
    try std.testing.expect(validateEntityId("guides/intro"));
    try std.testing.expect(validateEntityId("Guides/Intro"));
    try std.testing.expect(validateEntityId("my.notes"));
    try std.testing.expect(!validateEntityId(""));
    try std.testing.expect(!validateEntityId("/abs"));
    try std.testing.expect(!validateEntityId("a\\b"));
    try std.testing.expect(!validateEntityId("a//b"));
    try std.testing.expect(!validateEntityId("a/../b"));
    try std.testing.expect(!validateEntityId("a/./b"));
    try std.testing.expect(!validateEntityId("a/b/"));
    try std.testing.expect(!validateEntityId("has space"));
}
