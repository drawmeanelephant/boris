//! Canonical source paths, entity ids, and safe output-path derivation (v0.1).
//!
//! Pure path logic — no I/O. Callers own allocation of returned strings.
//!
//! ## Single derivation entry
//!
//! Every product path that turns a content-root-relative source path into a
//! graph key or an output path must go through:
//!
//! - `canonicalize` — normalize separators / reject traversal
//! - `canonicalEntityId` — validated entity id (case-preserving)
//! - `htmlOutputPath` / `ragPagePath` — output paths from validated entity ids only
//!
//! ## Case policy (v0.1)
//!
//! Entity ids **preserve** the letter case of the canonical source stem.
//! Two paths that differ only in letter case collide under a case-insensitive
//! compare and must be diagnosed with `E_ENTITY_CASE_COLLISION` — never
//! silently lowercased into platform-dependent graph keys.
//!
//! ## Extension policy (v0.1)
//!
//! Page files end with a **case-sensitive** suffix `.md` or `.mdx`.
//! `README.MD` / `Page.MDX` are not pages.

const std = @import("std");
const page_mod = @import("page.zig");

pub const PathError = error{
    EmptyPath,
    AbsolutePath,
    IllegalSegment,
    EmptyId,
    /// Path does not end with an accepted page extension (`.md` / `.mdx`).
    UnsupportedExtension,
    /// Derived or normalized entity id exceeds `page.max_entity_id_bytes`.
    IdTooLong,
} || std.mem.Allocator.Error;

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Case-sensitive page-extension check on a basename or full relative path.
pub fn isPageFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".mdx") or std.mem.endsWith(u8, name, ".md");
}

/// Alias kept for call sites that historically said "markdown".
pub fn isMarkdownFile(name: []const u8) bool {
    return isPageFile(name);
}

/// Length of the accepted trailing page extension, or null if not a page file.
pub fn pageExtensionLen(path: []const u8) ?usize {
    if (std.mem.endsWith(u8, path, ".mdx")) return 4;
    if (std.mem.endsWith(u8, path, ".md")) return 3;
    return null;
}

/// Normalize a content-root-relative path to canonical form.
///
/// Rules (see docs/contracts/source-path-and-id.md):
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
///
/// Invariants:
/// - non-empty, ≤ `max_entity_id_bytes`
/// - never starts with `/`
/// - never contains `\`
/// - never contains empty, `.`, or `..` segments
/// - no trailing `/`
/// - no ASCII whitespace
pub fn validateEntityId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id.len > page_mod.max_entity_id_bytes) return false;
    if (id[0] == '/') return false;
    if (id[id.len - 1] == '/' or id[id.len - 1] == '\\') return false;

    var i: usize = 0;
    while (i < id.len) {
        const start = i;
        while (i < id.len and id[i] != '/' and id[i] != '\\') : (i += 1) {}
        // Backslash anywhere is illegal in entity ids.
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

/// Normalize a path-stem or frontmatter id into a stable entity id:
/// - replace every `\` with `/` (hierarchy separator is always `/`)
/// - **preserve** letter case (collision detection is separate)
/// - reject empty / illegal segments and oversize ids
///
/// Returns a newly allocated string owned by `allocator`.
pub fn normalizeEntityId(allocator: std.mem.Allocator, stem: []const u8) PathError![]u8 {
    if (stem.len == 0) return error.EmptyId;
    if (stem.len > page_mod.max_entity_id_bytes) return error.IdTooLong;

    const out = try allocator.alloc(u8, stem.len);
    errdefer allocator.free(out);
    for (stem, 0..) |c, i| {
        out[i] = if (c == '\\') '/' else c;
    }
    if (!validateEntityId(out)) {
        // Distinguish absolute-looking ids; errdefer frees `out`.
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
    if (stem.len > page_mod.max_entity_id_bytes) return error.IdTooLong;
    if (!validateEntityId(stem)) return error.IllegalSegment;
    return try allocator.dupe(u8, stem);
}

/// Compatibility alias — prefer `canonicalEntityId` at new call sites.
pub fn entityIdFromSource(allocator: std.mem.Allocator, source_path: []const u8) PathError![]u8 {
    return canonicalEntityId(allocator, source_path);
}

/// Stem only (no allocation, no case change). Prefer `canonicalEntityId` for
/// graph keys. Accepts `.md` / `.mdx`.
pub fn idFromSourcePath(source_path: []const u8) PathError![]const u8 {
    return stemFromSourcePath(source_path);
}

/// HTML path relative to `dist/`, built only from a validated entity id.
/// Never introduces `..` or absolute segments — entity id is re-validated.
pub fn htmlOutputPath(allocator: std.mem.Allocator, entity_id: []const u8) PathError![]u8 {
    if (!validateEntityId(entity_id)) {
        if (entity_id.len == 0) return error.EmptyId;
        if (entity_id.len > page_mod.max_entity_id_bytes) return error.IdTooLong;
        if (entity_id[0] == '/' or entity_id[0] == '\\') return error.AbsolutePath;
        return error.IllegalSegment;
    }
    return try std.fmt.allocPrint(allocator, "{s}.html", .{entity_id});
}

/// RAG page path relative to the RAG root (`content/pages/<entity_id>.md`).
/// Entity id is re-validated so nested `..` cannot escape the output tree.
pub fn ragPagePath(allocator: std.mem.Allocator, entity_id: []const u8) PathError![]u8 {
    if (!validateEntityId(entity_id)) {
        if (entity_id.len == 0) return error.EmptyId;
        if (entity_id.len > page_mod.max_entity_id_bytes) return error.IdTooLong;
        if (entity_id[0] == '/' or entity_id[0] == '\\') return error.AbsolutePath;
        return error.IllegalSegment;
    }
    return try std.fmt.allocPrint(allocator, "content/pages/{s}.md", .{entity_id});
}

/// RAG catalog id (`content/<entity_id>`).
pub fn ragCatalogId(allocator: std.mem.Allocator, entity_id: []const u8) PathError![]u8 {
    if (!validateEntityId(entity_id)) {
        if (entity_id.len == 0) return error.EmptyId;
        if (entity_id.len > page_mod.max_entity_id_bytes) return error.IdTooLong;
        if (entity_id[0] == '/' or entity_id[0] == '\\') return error.AbsolutePath;
        return error.IllegalSegment;
    }
    return try std.fmt.allocPrint(allocator, "content/{s}", .{entity_id});
}

/// True when `a` and `b` are equal ignoring ASCII case but not byte-identical.
/// Used for `E_ENTITY_CASE_COLLISION` on source paths and entity ids.
pub fn pathsDifferOnlyInCase(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "canonicalize basic" {
    const gpa = std.testing.allocator;
    const p = try canonicalize(gpa, "guides/intro.md");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("guides/intro.md", p);
}

test "canonicalize rejects parent segments and absolute" {
    try std.testing.expectError(error.IllegalSegment, canonicalize(std.testing.allocator, "../x.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(std.testing.allocator, "a/../b.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(std.testing.allocator, "a//b.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(std.testing.allocator, "a/./b.md"));
    try std.testing.expectError(error.IllegalSegment, canonicalize(std.testing.allocator, "a/b/"));
    try std.testing.expectError(error.AbsolutePath, canonicalize(std.testing.allocator, "/abs.md"));
    try std.testing.expectError(error.AbsolutePath, canonicalize(std.testing.allocator, "C:\\abs.md"));
    try std.testing.expectError(error.AbsolutePath, canonicalize(std.testing.allocator, "c:/abs.md"));
}

test "canonicalize normalizes backslash and leading dot-slash" {
    const gpa = std.testing.allocator;
    const p = try canonicalize(gpa, "./guides\\intro.md");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("guides/intro.md", p);
}

test "canonicalize preserves nested path case" {
    const gpa = std.testing.allocator;
    const p = try canonicalize(gpa, "Guides\\API\\Overview.md");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("Guides/API/Overview.md", p);
}

test "isPageFile extension policy is case-sensitive" {
    try std.testing.expect(isPageFile("x.md"));
    try std.testing.expect(isPageFile("x.mdx"));
    try std.testing.expect(isPageFile("nested/x.md"));
    try std.testing.expect(!isPageFile("x.MD"));
    try std.testing.expect(!isPageFile("x.MDX"));
    try std.testing.expect(!isPageFile("x.txt"));
    try std.testing.expect(!isPageFile("md"));
}

test "canonicalEntityId preserves case and normalizes separators" {
    const gpa = std.testing.allocator;

    const a = try canonicalEntityId(gpa, "Guides/Intro.md");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Guides/Intro", a);

    const b = try canonicalEntityId(gpa, "Guides\\Intro.md");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("Guides/Intro", b);

    const c = try canonicalEntityId(gpa, "my.Notes.md");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("my.Notes", c);

    const d = try canonicalEntityId(gpa, "nested\\Path\\Page.mdx");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("nested/Path/Page", d);
}

test "canonicalEntityId rejects traversal-like and non-page paths" {
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
    var long: [page_mod.max_entity_id_bytes + 1 + 3]u8 = undefined;
    @memset(long[0 .. page_mod.max_entity_id_bytes + 1], 'z');
    @memcpy(long[page_mod.max_entity_id_bytes + 1 ..], ".md");
    try std.testing.expectError(error.IdTooLong, canonicalEntityId(gpa, &long));
}

test "normalizeEntityId preserves case and rejects illegal segments" {
    const gpa = std.testing.allocator;
    const a = try normalizeEntityId(gpa, "Guides\\Intro");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("Guides/Intro", a);

    try std.testing.expectError(error.IllegalSegment, normalizeEntityId(gpa, "a/../b"));
    try std.testing.expectError(error.IllegalSegment, normalizeEntityId(gpa, "a//b"));
    try std.testing.expectError(error.AbsolutePath, normalizeEntityId(gpa, "/abs"));
}

test "normalizeEntityId rejects oversize stem without allocating id body" {
    const gpa = std.testing.allocator;
    var stem: [page_mod.max_entity_id_bytes + 1]u8 = undefined;
    @memset(&stem, 'z');
    try std.testing.expectError(error.IdTooLong, normalizeEntityId(gpa, &stem));
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

test "htmlOutputPath and rag paths require validated entity ids" {
    const gpa = std.testing.allocator;

    const html = try htmlOutputPath(gpa, "guides/intro");
    defer gpa.free(html);
    try std.testing.expectEqualStrings("guides/intro.html", html);

    const rag = try ragPagePath(gpa, "guides/intro");
    defer gpa.free(rag);
    try std.testing.expectEqualStrings("content/pages/guides/intro.md", rag);

    const cat = try ragCatalogId(gpa, "guides/intro");
    defer gpa.free(cat);
    try std.testing.expectEqualStrings("content/guides/intro", cat);

    // Escape attempts must not produce output-root-relative paths.
    try std.testing.expectError(error.IllegalSegment, htmlOutputPath(gpa, "../etc/passwd"));
    try std.testing.expectError(error.IllegalSegment, ragPagePath(gpa, "a/../../x"));
    try std.testing.expectError(error.AbsolutePath, htmlOutputPath(gpa, "/abs"));
    try std.testing.expectError(error.IllegalSegment, ragPagePath(gpa, "a\\b"));
}

test "pathsDifferOnlyInCase" {
    try std.testing.expect(pathsDifferOnlyInCase("Guides/Intro.md", "guides/intro.md"));
    try std.testing.expect(pathsDifferOnlyInCase("Guides/Intro", "guides/intro"));
    try std.testing.expect(!pathsDifferOnlyInCase("guides/intro.md", "guides/intro.md"));
    try std.testing.expect(!pathsDifferOnlyInCase("a.md", "b.md"));
    try std.testing.expect(!pathsDifferOnlyInCase("ab.md", "a.md"));
}

test "idFromSourcePath strips md and mdx only" {
    try std.testing.expectEqualStrings("guides/intro", try idFromSourcePath("guides/intro.md"));
    try std.testing.expectEqualStrings("my.notes", try idFromSourcePath("my.notes.md"));
    try std.testing.expectEqualStrings("nested/Path/Page", try idFromSourcePath("nested/Path/Page.mdx"));
    try std.testing.expectError(error.EmptyId, idFromSourcePath(".md"));
    try std.testing.expectError(error.UnsupportedExtension, idFromSourcePath("x.txt"));
}
