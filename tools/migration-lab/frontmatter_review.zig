//! boris-migration-lab — frontmatter-review mode.
//!
//! Read-only scan of a Markdown content tree.  For every file that has
//! frontmatter, every key that is NOT in the Boris closed grammar
//! (id, title, parent, status, tags) is collected with its raw value,
//! classified by source page, and written to two deterministic outputs:
//!
//!   <out>/frontmatter_review.json   — machine-readable record
//!   <out>/FRONTMATTER_REVIEW.md     — human-readable summary
//!
//! Boris core grammar is never touched.  Converted content produced by
//! other migration-lab modes is never modified.  This mode is additive
//! and read-only.
//!
//! Hard limits
//!   - no YAML evaluation beyond simple key: value top-level parsing
//!   - no network, no zip, no Node/Astro runtime
//!   - source tree is read-only; all writes go under --out
//!   - unknown-key values are preserved verbatim (trimmed, not evaluated)
//!
//! Not part of the Boris product compiler pipeline.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-frontmatter-review-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

/// Boris closed frontmatter keys — never modified.
const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

fn isBorisClosed(key: []const u8) bool {
    for (boris_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

pub const RunOptions = struct {
    /// Root of the content tree to scan (never modified).
    content_dir: []const u8,
    /// Output root — frontmatter_review.json and FRONTMATTER_REVIEW.md.
    out_dir: []const u8,
    quiet: bool = false,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// One unknown key occurrence on a specific page.
pub const KeyEntry = struct {
    /// Relative path of the source file inside content_dir.
    source_path: []const u8,
    /// The frontmatter key name.
    key: []const u8,
    /// Raw (trimmed) value string, quotes stripped if present.
    raw_value: []const u8,
    /// 1-based line number of the key inside the frontmatter block.
    line: u32,
};

/// Per-page summary: which unknown keys were found.
pub const PageSummary = struct {
    source_path: []const u8,
    /// Slice of KeyEntry indices belonging to this page (into the flat list).
    key_count: usize,
};

pub const Report = struct {
    content_root: []const u8,
    entries: []const KeyEntry,
    total_pages_scanned: usize,
    pages_with_unknown_keys: usize,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

const skip_dirs = [_][]const u8{
    ".git", ".hg", ".svn", "node_modules", "dist",
    ".output", ".vercel", ".netlify", "zig-out", "zig-cache", ".zig-cache",
};

fn isSkipDir(name: []const u8) bool {
    for (skip_dirs) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    // skip hidden dirs not already listed
    if (name.len > 0 and name[0] == '.') return true;
    return false;
}

fn isMarkdown(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".mdx");
}

// ---------------------------------------------------------------------------
// File collection
// ---------------------------------------------------------------------------

fn collectMarkdownFiles(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate;
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            const child_rel = if (prefix.len == 0)
                try retain.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try collectMarkdownFiles(io, gpa, retain, sub, child_rel, out);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!isMarkdown(entry.name)) continue;
        const rel = if (prefix.len == 0)
            try retain.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
        try out.append(rel);
    }
}

// ---------------------------------------------------------------------------
// Frontmatter parser — unknown-key extraction only
// ---------------------------------------------------------------------------

/// Scan the frontmatter of `source` and append all unknown-key entries
/// to `out`.  Returns the number of entries appended.
fn extractUnknownKeys(
    retain: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    out: *std.ArrayList(KeyEntry),
) !usize {
    const before = out.items.len;

    // Must start with --- or ---\r\n
    if (!std.mem.startsWith(u8, source, "---")) return 0;
    const after_open: usize = if (std.mem.startsWith(u8, source, "---\r\n")) 5 else 4;

    var i: usize = after_open;
    var found_close = false;
    var line_no: u32 = 2; // frontmatter lines start at source line 2

    while (i < source.len) {
        const line_start = i;
        // advance to end-of-line
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        var line = source[line_start..i];
        if (i < source.len) i += 1; // consume \n
        // strip trailing \r
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.eql(u8, line, "---")) {
            found_close = true;
            break;
        }
        if (line.len == 0) { line_no += 1; continue; }
        // skip indented lines and sequence markers — not top-level keys
        if (line[0] == ' ' or line[0] == '\t' or line[0] == '-') { line_no += 1; continue; }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse { line_no += 1; continue; };
        const key = trim(line[0..colon]);
        if (key.len == 0) { line_no += 1; continue; }

        if (!isBorisClosed(key)) {
            const raw_val = trim(line[colon + 1 ..]);
            const clean_val = stripQuotes(raw_val);
            try out.append(.{
                .source_path = try retain.dupe(u8, source_path),
                .key = try retain.dupe(u8, key),
                .raw_value = try retain.dupe(u8, clean_val),
                .line = line_no,
            });
        }
        line_no += 1;
    }
    _ = found_close; // we collect even from unclosed frontmatter
    return out.items.len - before;
}

// ---------------------------------------------------------------------------
// JSON / Markdown emitters
// ---------------------------------------------------------------------------

fn jsonEscapeAppend(
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    s: []const u8,
) !void {
    try buf.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(c),
        }
    }
    try buf.append('"');
}

fn emitJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try buf.appendSlice(gpa, "  \"format\": \"");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "\",\n  \"schema_version\": 1,\n  \"tool_version\": \"");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "\",\n");
    try buf.appendSlice(gpa, "  \"content_root\": ");
    try jsonEscapeAppend(&buf, gpa, report.content_root);
    try buf.appendSlice(gpa, ",\n");

    // summary
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(gpa, "  \"summary\": {\n");
    try buf.appendSlice(gpa, "    \"pages_scanned\": ");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{report.total_pages_scanned}));
    try buf.appendSlice(gpa, ",\n    \"pages_with_unknown_keys\": ");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{report.pages_with_unknown_keys}));
    try buf.appendSlice(gpa, ",\n    \"total_unknown_keys\": ");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{report.entries.len}));
    try buf.appendSlice(gpa, "\n  },\n");

    // entries array
    try buf.appendSlice(gpa, "  \"entries\": [\n");
    for (report.entries, 0..) |e, idx| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"source_path\": ");
        try jsonEscapeAppend(&buf, gpa, e.source_path);
        try buf.appendSlice(gpa, ",\n      \"key\": ");
        try jsonEscapeAppend(&buf, gpa, e.key);
        try buf.appendSlice(gpa, ",\n      \"raw_value\": ");
        try jsonEscapeAppend(&buf, gpa, e.raw_value);
        try buf.appendSlice(gpa, ",\n      \"line\": ");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{e.line}));
        try buf.appendSlice(gpa, "\n    }");
        if (idx + 1 < report.entries.len) try buf.append(',');
        try buf.append('\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn emitMarkdown(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "# Frontmatter Review\n\n");
    try buf.appendSlice(gpa, "Format: ");
    try buf.appendSlice(gpa, format_id);
    try buf.appendSlice(gpa, "  \nSchema version: 1  \nTool version: ");
    try buf.appendSlice(gpa, tool_version);
    try buf.appendSlice(gpa, "  \nContent root: `");
    try buf.appendSlice(gpa, report.content_root);
    try buf.appendSlice(gpa, "`\n\n");

    // summary table
    try buf.appendSlice(gpa, "## Summary\n\n");
    try buf.appendSlice(gpa, "| Metric | Value |\n|--------|-------|\n");
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(gpa, "| Pages scanned | ");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{report.total_pages_scanned}));
    try buf.appendSlice(gpa, " |\n| Pages with unknown keys | ");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{report.pages_with_unknown_keys}));
    try buf.appendSlice(gpa, " |\n| Total unknown key occurrences | ");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{report.entries.len}));
    try buf.appendSlice(gpa, " |\n\n");

    if (report.entries.len == 0) {
        try buf.appendSlice(gpa, "No unknown frontmatter keys found.\n");
        return try buf.toOwnedSlice(gpa);
    }

    // per-page detail — group entries by source_path
    try buf.appendSlice(gpa, "## Unknown Keys by Source Page\n\n");
    var page_start: usize = 0;
    while (page_start < report.entries.len) {
        const page_path = report.entries[page_start].source_path;
        var page_end = page_start + 1;
        while (page_end < report.entries.len and
            std.mem.eql(u8, report.entries[page_end].source_path, page_path))
        {
            page_end += 1;
        }

        try buf.appendSlice(gpa, "### `");
        try buf.appendSlice(gpa, page_path);
        try buf.appendSlice(gpa, "`\n\n");
        try buf.appendSlice(gpa, "| Line | Key | Raw value |\n|------|-----|-----------|\n");
        for (report.entries[page_start..page_end]) |e| {
            try buf.appendSlice(gpa, "| ");
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{e.line}));
            try buf.appendSlice(gpa, " | `");
            try buf.appendSlice(gpa, e.key);
            try buf.appendSlice(gpa, "` | `");
            // limit raw_value display to 80 chars for readability
            const display = if (e.raw_value.len > 80) e.raw_value[0..80] else e.raw_value;
            try buf.appendSlice(gpa, display);
            if (e.raw_value.len > 80) try buf.appendSlice(gpa, "…");
            try buf.appendSlice(gpa, "` |\n");
        }
        try buf.append('\n');
        page_start = page_end;
    }

    try buf.appendSlice(gpa,
        "---\n"
        ++ "Migration-lab only.  Boris core grammar is unchanged.  "
        ++ "Source tree was not modified.\n");
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// IO helpers
// ---------------------------------------------------------------------------

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, .{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn ensureParent(io: Io, root: Io.Dir, relpath: []const u8) !void {
    if (std.fs.path.dirname(relpath)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, relpath: []const u8, data: []const u8) !void {
    try ensureParent(io, root, relpath);
    try root.writeFile(io, .{ .sub_path = relpath, .data = data });
}

// ---------------------------------------------------------------------------
// Public run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const retain = arena_state.allocator();

    var content_root = try Io.Dir.cwd.openDir(io, opts.content_dir, .{ .iterate = true });
    defer content_root.close(io);

    // Collect all Markdown files under content_dir
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(gpa);
    try collectMarkdownFiles(io, gpa, retain, content_root, "", &files);

    // Sort deterministically
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    // Extract unknown keys from every file
    var entries = std.ArrayList(KeyEntry).empty;
    defer entries.deinit(gpa);

    var pages_scanned: usize = 0;
    var pages_with_unknown: usize = 0;

    for (files.items) |rel| {
        const raw = readFileAlloc(io, content_root, rel, gpa) catch continue;
        defer gpa.free(raw);
        pages_scanned += 1;
        const before = entries.items.len;
        try extractUnknownKeys(retain, rel, raw, &entries);
        if (entries.items.len > before) pages_with_unknown += 1;
    }

    // Entries are already grouped by source_path because files were sorted.
    // Within each page they are in line order.

    const report = Report{
        .content_root = opts.content_dir,
        .entries = entries.items,
        .total_pages_scanned = pages_scanned,
        .pages_with_unknown_keys = pages_with_unknown,
    };

    try Io.Dir.cwd.createDirPath(io, opts.out_dir);
    var out_root = try Io.Dir.cwd.openDir(io, opts.out_dir, .{});
    defer out_root.close(io);

    const json = try emitJson(gpa, report);
    defer gpa.free(json);
    try writeBytes(io, out_root, "frontmatter_review.json", json);

    const md = try emitMarkdown(gpa, report);
    defer gpa.free(md);
    try writeBytes(io, out_root, "FRONTMATTER_REVIEW.md", md);

    if (!opts.quiet) {
        std.debug.print(
            "frontmatter-review: scanned {d} pages, {d} with unknown keys, {d} entries → {s}/\n",
            .{ pages_scanned, pages_with_unknown, entries.items.len, opts.out_dir },
        );
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "extractUnknownKeys: known keys are not collected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    const src =
        \\---
        \\id: mascot-cass-d
        \\title: Cass D
        \\parent: mascots
        \\status: draft
        \\tags: [mascot]
        \\---
        \\Body text.
    ;
    var out = std.ArrayList(KeyEntry).empty;
    defer out.deinit(gpa);
    const n = try extractUnknownKeys(retain, "cass.md", src, &out);
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractUnknownKeys: unknown keys are collected with correct metadata" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    const src =
        \\---
        \\title: Hello
        \\cssClass: fancy
        \\updatedAt: 2026-01-01
        \\status: published
        \\---
        \\Body.
    ;
    var out = std.ArrayList(KeyEntry).empty;
    defer out.deinit(gpa);
    const n = try extractUnknownKeys(retain, "hello.md", src, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("cssClass", out.items[0].key);
    try std.testing.expectEqualStrings("fancy", out.items[0].raw_value);
    try std.testing.expectEqualStrings("updatedAt", out.items[1].key);
    try std.testing.expectEqualStrings("2026-01-01", out.items[1].raw_value);
    try std.testing.expectEqualStrings("hello.md", out.items[0].source_path);
}

test "extractUnknownKeys: no frontmatter → zero entries" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    const src = "No frontmatter here.\nJust body.\n";
    var out = std.ArrayList(KeyEntry).empty;
    defer out.deinit(gpa);
    const n = try extractUnknownKeys(retain, "plain.md", src, &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "extractUnknownKeys: quoted value stripped" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    const src =
        \\---
        \\description: "A nice page"
        \\---
    ;
    var out = std.ArrayList(KeyEntry).empty;
    defer out.deinit(gpa);
    _ = try extractUnknownKeys(retain, "q.md", src, &out);
    try std.testing.expect(out.items.len == 1);
    try std.testing.expectEqualStrings("A nice page", out.items[0].raw_value);
}

test "emitJson: deterministic round-trip smoke" {
    const gpa = std.testing.allocator;
    const entries = [_]KeyEntry{
        .{ .source_path = "a.md", .key = "slug", .raw_value = "my-slug", .line = 3 },
        .{ .source_path = "b.md", .key = "updatedAt", .raw_value = "2026-07-01", .line = 2 },
    };
    const report = Report{
        .content_root = "content",
        .entries = &entries,
        .total_pages_scanned = 5,
        .pages_with_unknown_keys = 2,
    };
    const json = try emitJson(gpa, report);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updatedAt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, format_id) != null);
    // second call produces identical output (determinism)
    const json2 = try emitJson(gpa, report);
    defer gpa.free(json2);
    try std.testing.expectEqualStrings(json, json2);
}

test "emitMarkdown: unknown keys appear grouped by page" {
    const gpa = std.testing.allocator;
    const entries = [_]KeyEntry{
        .{ .source_path = "posts/alpha.md", .key = "caseNumber", .raw_value = "POST-001", .line = 4 },
        .{ .source_path = "posts/alpha.md", .key = "slug", .raw_value = "alpha", .line = 5 },
        .{ .source_path = "posts/beta.md", .key = "updatedAt", .raw_value = "2026-01-15", .line = 3 },
    };
    const report = Report{
        .content_root = "content",
        .entries = &entries,
        .total_pages_scanned = 3,
        .pages_with_unknown_keys = 2,
    };
    const md = try emitMarkdown(gpa, report);
    defer gpa.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "posts/alpha.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "caseNumber") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "updatedAt") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Migration-lab only") != null);
}

test "fixture end-to-end determinism" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const outa = "fixtures/.test-fmreview-out-a";
    const outb = "fixtures/.test-fmreview-out-b";
    Io.Dir.cwd.deleteTree(io, outa) catch {};
    Io.Dir.cwd.deleteTree(io, outb) catch {};
    try run(io, gpa, .{
        .content_dir = "fixtures/mini-frontmatter-review",
        .out_dir = outa,
        .quiet = true,
    });
    try run(io, gpa, .{
        .content_dir = "fixtures/mini-frontmatter-review",
        .out_dir = outb,
        .quiet = true,
    });
    var da = try Io.Dir.cwd.openDir(io, outa, .{});
    defer da.close(io);
    var db = try Io.Dir.cwd.openDir(io, outb, .{});
    defer db.close(io);
    const ja = try readFileAlloc(io, da, "frontmatter_review.json", gpa);
    defer gpa.free(ja);
    const jb = try readFileAlloc(io, db, "frontmatter_review.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);
    const ma = try readFileAlloc(io, da, "FRONTMATTER_REVIEW.md", gpa);
    defer gpa.free(ma);
    const mb = try readFileAlloc(io, db, "FRONTMATTER_REVIEW.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);
    // Check known content
    try std.testing.expect(std.mem.indexOf(u8, ja, "caseNumber") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "slug") != null);
    // Boris keys must NOT appear as unknown
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"title\"") == null or
        std.mem.indexOf(u8, ja, "\"key\": \"title\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"key\": \"status\"") == null);
}
