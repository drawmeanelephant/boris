//! Migration-lab-only frontmatter preservation report.
//!
//! Scans a content tree (Markdown / MDX files with a Boris-style
//! `--- … ---` fence) and collects every frontmatter key that is NOT in
//! the Boris closed grammar {id, title, parent, status, tags}.  Each
//! occurrence is classified by source file so that a migration author can
//! decide how to dispose of the data (map to tags, move to body, drop).
//!
//! Outputs (written to --out-dir):
//!   frontmatter_review.json   machine-readable, schema_version 1
//!   FRONTMATTER_REVIEW.md     deterministic human-readable summary
//!
//! Boris core (src/frontmatter.zig) is intentionally NOT imported here.
//! No source file is ever modified.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-frontmatter-review-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

/// Keys in the Boris closed grammar.  Anything else is unknown / unsupported.
const boris_keys = [_][]const u8{ "id", "title", "parent", "status", "tags" };

fn isBorisKey(key: []const u8) bool {
    for (boris_keys) |k| if (std.mem.eql(u8, key, k)) return true;
    return false;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// One unknown-key occurrence inside a single source file.
pub const KeyOccurrence = struct {
    /// Exact key bytes as found in source (no normalisation).
    key: []const u8,
    /// 1-based line number inside the frontmatter block (opening fence = 1).
    line: usize,
    /// Raw value bytes (trimmed, quotes kept).  May be empty.
    value: []const u8,
};

/// Per-file review record.
pub const FileReview = struct {
    /// Repo-root-relative path of the source file.
    source_path: []const u8,
    /// Unknown keys found in this file.
    unknown_keys: []const KeyOccurrence,
    /// True when the frontmatter fence was not properly closed.
    incompatible_fence: bool,
};

/// Result of a complete scan run.
pub const ScanResult = struct {
    source_root: []const u8,
    /// One entry per file that had at least one unknown key OR an
    /// incompatible fence.  Files with no frontmatter at all are omitted.
    files: []const FileReview,
    /// Total count of distinct unknown key *names* across all files.
    total_unknown_keys: usize,
    /// Total count of individual key occurrences.
    total_occurrences: usize,
};

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

/// Parse a single file's frontmatter and return its unknown-key occurrences.
/// Allocations go into `a`; the caller owns the returned slice.
pub fn scanFile(a: std.mem.Allocator, source: []const u8) !struct { occurrences: []KeyOccurrence, incompatible_fence: bool } {
    var list: std.ArrayList(KeyOccurrence) = .empty;
    errdefer list.deinit(a);

    // Must start with `---\n` or `---\r\n`.
    if (!std.mem.startsWith(u8, source, "---")) {
        return .{ .occurrences = try list.toOwnedSlice(a), .incompatible_fence = false };
    }
    const after_open: usize = blk: {
        if (source.len > 4 and source[3] == '\r' and source[4] == '\n') break :blk 5;
        if (source.len > 3 and source[3] == '\n') break :blk 4;
        return .{ .occurrences = try list.toOwnedSlice(a), .incompatible_fence = false };
    };

    // Find the closing fence.
    const close = std.mem.indexOfPos(u8, source, after_open, "\n---") orelse {
        return .{ .occurrences = try list.toOwnedSlice(a), .incompatible_fence = true };
    };
    const frontmatter = source[after_open..close];

    var pos: usize = 0;
    var line_no: usize = 2; // opening fence is line 1
    while (pos < frontmatter.len) {
        const line_end = std.mem.indexOfScalarPos(u8, frontmatter, pos, '\n') orelse frontmatter.len;
        const line = frontmatter[pos..line_end];
        const raw = trim(line);
        // Skip blank, indented (nested YAML), and list-item lines.
        if (raw.len > 0 and raw[0] != ' ' and raw[0] != '\t' and raw[0] != '-') {
            if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
                const key = trim(raw[0..colon]);
                const val = trim(raw[colon + 1 ..]);
                if (key.len > 0 and !isBorisKey(key)) {
                    try list.append(a, .{
                        .key = try a.dupe(u8, key),
                        .line = line_no,
                        .value = try a.dupe(u8, val),
                    });
                }
            }
        }
        pos = if (line_end == frontmatter.len) frontmatter.len else line_end + 1;
        line_no += 1;
    }
    return .{ .occurrences = try list.toOwnedSlice(a), .incompatible_fence = false };
}

// ---------------------------------------------------------------------------
// Directory walk helpers
// ---------------------------------------------------------------------------

const skip_dir_names = [_][]const u8{
    ".git", ".hg", "node_modules", "dist", "zig-out", "zig-cache",
    ".zig-cache", ".boris", ".output", ".vercel", ".netlify",
};

fn shouldSkipDir(name: []const u8) bool {
    for (skip_dir_names) |s| if (std.mem.eql(u8, name, s)) return true;
    if (name.len > 0 and name[0] == '.') return true;
    return false;
}

fn isMarkdown(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".mdx");
}

const WalkEntry = struct { rel_path: []const u8 };

fn collectFiles(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_prefix: []const u8,
    out: *std.ArrayList(WalkEntry),
) !void {
    var dir = try root.openDir(io, if (rel_prefix.len == 0) "." else rel_prefix, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (!isMarkdown(entry.name)) continue;
                const rel = if (rel_prefix.len == 0)
                    try a.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, entry.name });
                try out.append(a, .{ .rel_path = rel });
            },
            .directory => {
                if (shouldSkipDir(entry.name)) continue;
                const sub = if (rel_prefix.len == 0)
                    try a.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, entry.name });
                try collectFiles(io, a, root, sub, out);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// JSON / Markdown emission
// ---------------------------------------------------------------------------

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

pub fn emitJson(a: std.mem.Allocator, result: ScanResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, format_id);
    try buf.appendSlice(a, ",\n  \"schema_version\": 1,\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, result.source_root);
    try buf.appendSlice(a, ",\n  \"total_unknown_keys\": ");
    try appendUsize(&buf, a, result.total_unknown_keys);
    try buf.appendSlice(a, ",\n  \"total_occurrences\": ");
    try appendUsize(&buf, a, result.total_occurrences);
    try buf.appendSlice(a, ",\n  \"files\": [\n");
    for (result.files, 0..) |file, fi| {
        try buf.appendSlice(a, "    {\n      \"source_path\": ");
        try appendJson(&buf, a, file.source_path);
        try buf.appendSlice(a, ",\n      \"incompatible_fence\": ");
        try buf.appendSlice(a, if (file.incompatible_fence) "true" else "false");
        try buf.appendSlice(a, ",\n      \"unknown_keys\": [");
        for (file.unknown_keys, 0..) |occ, oi| {
            if (oi > 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, "{ \"key\": ");
            try appendJson(&buf, a, occ.key);
            try buf.appendSlice(a, ", \"line\": ");
            try appendUsize(&buf, a, occ.line);
            try buf.appendSlice(a, ", \"value\": ");
            try appendJson(&buf, a, occ.value);
            try buf.appendSlice(a, " }");
        }
        try buf.appendSlice(a, "]\n    }");
        if (fi + 1 < result.files.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return buf.toOwnedSlice(a);
}

pub fn emitMd(a: std.mem.Allocator, result: ScanResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a,
        \\# Unsupported frontmatter preservation report
        \\
        \\> **Migration-lab only.** Boris core grammar is unchanged.
        \\> Source files are never modified.
        \\
        \\
    );
    try buf.appendSlice(a, "**Source root:** `");
    try buf.appendSlice(a, result.source_root);
    try buf.appendSlice(a, "`  \n**Tool version:** ");
    try buf.appendSlice(a, tool_version);
    try buf.appendSlice(a, "  \n**Total unsupported key occurrences:** ");
    try appendUsize(&buf, a, result.total_occurrences);
    try buf.appendSlice(a, "  \n**Files with unsupported keys:** ");
    try appendUsize(&buf, a, result.files.len);
    try buf.appendSlice(a, "\n\n---\n\n## Per-file classification\n\n");
    if (result.files.len == 0) {
        try buf.appendSlice(a, "None — all files use only supported Boris frontmatter keys.\n");
    } else {
        for (result.files) |file| {
            try buf.appendSlice(a, "### `");
            try buf.appendSlice(a, file.source_path);
            try buf.appendSlice(a, "`\n\n");
            if (file.incompatible_fence) {
                try buf.appendSlice(a, "⚠️  Unclosed frontmatter fence — keys below may be incomplete.\n\n");
            }
            if (file.unknown_keys.len == 0) {
                try buf.appendSlice(a, "_(No unknown keys — fence issue only.)_\n\n");
            } else {
                try buf.appendSlice(a, "| Line | Key | Raw value |\n|-----:|-----|-----------|\n");
                for (file.unknown_keys) |occ| {
                    try buf.appendSlice(a, "| ");
                    try appendUsize(&buf, a, occ.line);
                    try buf.appendSlice(a, " | `");
                    try buf.appendSlice(a, occ.key);
                    try buf.appendSlice(a, "` | `");
                    try buf.appendSlice(a, occ.value);
                    try buf.appendSlice(a, "` |\n");
                }
                try buf.append(a, '\n');
            }
        }
    }
    try buf.appendSlice(a,
        \\---
        \\
        \\_Machine-readable twin: `frontmatter_review.json`._
        \\
    );
    return buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Public run entry-point
// ---------------------------------------------------------------------------

pub const RunOptions = struct {
    /// Directory tree to scan.  Never modified.
    source_root: []const u8,
    /// Directory where outputs are written.
    out_dir: []const u8,
    quiet: bool = false,
};

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    // Guard against writing into the source tree.
    if (std.mem.eql(u8, opts.source_root, opts.out_dir) or
        (opts.out_dir.len > opts.source_root.len and
            std.mem.startsWith(u8, opts.out_dir, opts.source_root) and
            (opts.out_dir[opts.source_root.len] == '/' or
                opts.out_dir[opts.source_root.len] == '\\')))
        return error.OutputInsideSource;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var source_dir = try Io.Dir.cwd().openDir(io, opts.source_root, .{ .iterate = true });
    defer source_dir.close(io);

    var entries: std.ArrayList(WalkEntry) = .empty;
    try collectFiles(io, a, source_dir, "", &entries);

    // Sort deterministically.
    std.mem.sort(WalkEntry, entries.items, {}, struct {
        fn less(_: void, x: WalkEntry, y: WalkEntry) bool {
            return std.mem.order(u8, x.rel_path, y.rel_path) == .lt;
        }
    }.less);

    var reviews: std.ArrayList(FileReview) = .empty;
    var total_occurrences: usize = 0;
    var all_key_names: std.ArrayList([]const u8) = .empty;

    for (entries.items) |entry| {
        var file = try source_dir.openFile(io, entry.rel_path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const raw = try reader.interface.allocRemaining(a, .unlimited);
        const scanned = try scanFile(a, raw);
        if (scanned.occurrences.len == 0 and !scanned.incompatible_fence) continue;
        total_occurrences += scanned.occurrences.len;
        for (scanned.occurrences) |occ| {
            var found = false;
            for (all_key_names.items) |k| if (std.mem.eql(u8, k, occ.key)) { found = true; break; };
            if (!found) try all_key_names.append(a, occ.key);
        }
        try reviews.append(a, .{
            .source_path = entry.rel_path,
            .unknown_keys = scanned.occurrences,
            .incompatible_fence = scanned.incompatible_fence,
        });
    }

    const result = ScanResult{
        .source_root = opts.source_root,
        .files = reviews.items,
        .total_unknown_keys = all_key_names.items.len,
        .total_occurrences = total_occurrences,
    };

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);

    const json_bytes = try emitJson(a, result);
    try out.writeFile(io, .{ .sub_path = "frontmatter_review.json", .data = json_bytes });

    const md_bytes = try emitMd(a, result);
    try out.writeFile(io, .{ .sub_path = "FRONTMATTER_REVIEW.md", .data = md_bytes });

    if (!opts.quiet) std.debug.print(
        "frontmatter-review-lab: scanned {d} files, {d} unknown-key occurrences → {s}/\n",
        .{ entries.items.len, total_occurrences, opts.out_dir },
    );
}

// ---------------------------------------------------------------------------
// Unit tests — pure logic
// ---------------------------------------------------------------------------

test "scanFile: all Boris keys are not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\id: guides/intro
        \\title: Introduction
        \\parent: guides
        \\status: draft
        \\tags: a, b
        \\---
        \\Body text.
    ;
    const r = try scanFile(a, src);
    try std.testing.expectEqual(@as(usize, 0), r.occurrences.len);
    try std.testing.expect(!r.incompatible_fence);
}

test "scanFile: unknown keys are captured with line numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\title: My Page
        \\caseNumber: CASE-001
        \\slug: my-page
        \\status: published
        \\updatedAt: 2026-07-01
        \\---
        \\Body.
    ;
    const r = try scanFile(a, src);
    try std.testing.expect(!r.incompatible_fence);
    try std.testing.expectEqual(@as(usize, 3), r.occurrences.len);
    try std.testing.expectEqualStrings("caseNumber", r.occurrences[0].key);
    try std.testing.expectEqual(@as(usize, 3), r.occurrences[0].line);
    try std.testing.expectEqualStrings("CASE-001", r.occurrences[0].value);
    try std.testing.expectEqualStrings("slug", r.occurrences[1].key);
    try std.testing.expectEqualStrings("updatedAt", r.occurrences[2].key);
    try std.testing.expectEqualStrings("2026-07-01", r.occurrences[2].value);
}

test "scanFile: no frontmatter returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try scanFile(a, "# Just a heading\n\nBody.");
    try std.testing.expectEqual(@as(usize, 0), r.occurrences.len);
    try std.testing.expect(!r.incompatible_fence);
}

test "scanFile: unclosed fence sets incompatible_fence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\title: Broken
        \\caseNumber: X
    ;
    const r = try scanFile(a, src);
    try std.testing.expect(r.incompatible_fence);
    // Scanner returns empty occurrences for unclosed fence (no end boundary).
    try std.testing.expectEqual(@as(usize, 0), r.occurrences.len);
}

test "scanFile: list item lines under tags are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\title: T
        \\tags:
        \\  - alpha
        \\  - beta
        \\---
    ;
    const r = try scanFile(a, src);
    try std.testing.expectEqual(@as(usize, 0), r.occurrences.len);
}

test "emitJson: unknown_keys array present and ordered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = ScanResult{
        .source_root = "content",
        .files = &.{
            .{
                .source_path = "pages/alpha.md",
                .unknown_keys = &.{
                    .{ .key = "caseNumber", .line = 3, .value = "CASE-001" },
                    .{ .key = "slug", .line = 4, .value = "my-page" },
                },
                .incompatible_fence = false,
            },
        },
        .total_unknown_keys = 2,
        .total_occurrences = 2,
    };
    const json = try emitJson(a, result);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"caseNumber\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"incompatible_fence\": false") != null);
    // key order: caseNumber before slug (source order preserved)
    const cn = std.mem.indexOf(u8, json, "caseNumber").?;
    const sl = std.mem.indexOf(u8, json, "\"slug\"").?;
    try std.testing.expect(cn < sl);
}

test "emitMd: section headers and table present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = ScanResult{
        .source_root = "content",
        .files = &.{
            .{
                .source_path = "pages/beta.md",
                .unknown_keys = &.{
                    .{ .key = "mascotId", .line = 2, .value = "cass" },
                },
                .incompatible_fence = false,
            },
        },
        .total_unknown_keys = 1,
        .total_occurrences = 1,
    };
    const md = try emitMd(a, result);
    try std.testing.expect(std.mem.indexOf(u8, md, "# Unsupported frontmatter preservation report") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Migration-lab only") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "pages/beta.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "mascotId") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| Line |") != null);
}

test "emitMd: no-unknown case says None" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = ScanResult{
        .source_root = "content",
        .files = &.{},
        .total_unknown_keys = 0,
        .total_occurrences = 0,
    };
    const md = try emitMd(a, result);
    try std.testing.expect(std.mem.indexOf(u8, md, "None") != null);
}

// ---------------------------------------------------------------------------
// Fixture tests
// ---------------------------------------------------------------------------

test "fixture: fm-review-no-unknown — JSON unknown_keys empty, MD says None" {
    const io = std.testing.io;
    const out = "fixtures/.test-fmreview-no-unknown";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};

    try run(io, std.testing.allocator, .{
        .source_root = "fixtures/fm-review-no-unknown",
        .out_dir = out,
        .quiet = true,
    });

    var odir = try Io.Dir.cwd().openDir(io, out, .{});
    defer odir.close(io);

    var jf = try odir.openFile(io, "frontmatter_review.json", .{});
    defer jf.close(io);
    var jr = jf.reader(io, &.{});
    const json = try jr.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(json);
    // No files array entries.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"files\": [\n  ]") != null or
        std.mem.indexOf(u8, json, "\"total_occurrences\": 0") != null);

    var mf = try odir.openFile(io, "FRONTMATTER_REVIEW.md", .{});
    defer mf.close(io);
    var mr = mf.reader(io, &.{});
    const md = try mr.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "None") != null);
}

test "fixture: fm-review-mixed — deterministic, known keys absent from report" {
    const io = std.testing.io;
    const out_a = "fixtures/.test-fmreview-mixed-a";
    const out_b = "fixtures/.test-fmreview-mixed-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_a) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_b) catch {};

    // Confirm source immutability: read a fixture file before and after.
    var fixture_dir = try Io.Dir.cwd().openDir(io, "fixtures/fm-review-mixed", .{});
    defer fixture_dir.close(io);
    var src_file = try fixture_dir.openFile(io, "content/posts/case-alpha.md", .{});
    defer src_file.close(io);
    var src_r = src_file.reader(io, &.{});
    const before = try src_r.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{ .source_root = "fixtures/fm-review-mixed", .out_dir = out_a, .quiet = true });
    try run(io, std.testing.allocator, .{ .source_root = "fixtures/fm-review-mixed", .out_dir = out_b, .quiet = true });

    var ao = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer bo.close(io);

    // Byte-for-byte determinism.
    for ([_][]const u8{ "frontmatter_review.json", "FRONTMATTER_REVIEW.md" }) |path| {
        var fa = try ao.openFile(io, path, .{});
        defer fa.close(io);
        var ra = fa.reader(io, &.{});
        const xa = try ra.interface.allocRemaining(std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(xa);

        var fb = try bo.openFile(io, path, .{});
        defer fb.close(io);
        var rb = fb.reader(io, &.{});
        const xb = try rb.interface.allocRemaining(std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(xb);

        try std.testing.expectEqualStrings(xa, xb);
    }

    var jf = try ao.openFile(io, "frontmatter_review.json", .{});
    defer jf.close(io);
    var jr = jf.reader(io, &.{});
    const json = try jr.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(json);

    // Unknown keys present; Boris keys absent.
    try std.testing.expect(std.mem.indexOf(u8, json, "caseNumber") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "slug") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "updatedAt") != null);
    // Boris keys must not appear as flagged.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"key\": \"title\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"key\": \"status\"") == null);

    // Source immutability.
    var src_file2 = try fixture_dir.openFile(io, "content/posts/case-alpha.md", .{});
    defer src_file2.close(io);
    var src_r2 = src_file2.reader(io, &.{});
    const after = try src_r2.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "fixture: fm-review-open-fence — no crash, fence flag set" {
    const io = std.testing.io;
    const out = "fixtures/.test-fmreview-open-fence";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};

    try run(io, std.testing.allocator, .{
        .source_root = "fixtures/fm-review-open-fence",
        .out_dir = out,
        .quiet = true,
    });

    var odir = try Io.Dir.cwd().openDir(io, out, .{});
    defer odir.close(io);
    var jf = try odir.openFile(io, "frontmatter_review.json", .{});
    defer jf.close(io);
    var jr = jf.reader(io, &.{});
    const json = try jr.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"incompatible_fence\": true") != null);

    var mf = try odir.openFile(io, "FRONTMATTER_REVIEW.md", .{});
    defer mf.close(io);
    var mr = mf.reader(io, &.{});
    const md = try mr.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "Unclosed frontmatter fence") != null);
}
