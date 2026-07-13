//! boris-source-rag — standalone source-code corpus exporter for LLM upload.
//!
//! **Not** part of the Boris content compiler or product `boris-rag` pipeline.
//! Walks selected project trees, wraps each text source file as a retrieval
//! document, and emits INDEX / catalog sidecars under `--out` (default
//! `source-rag/`).
//!
//! Usage (from repo root):
//!   zig build source-rag
//!   zig build source-rag -- --out=./uploads/source-rag
//!   zig-out/bin/boris-source-rag --help

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-source-rag";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub const Options = struct {
    help: bool = false,
    quiet: bool = false,
    /// Corpus output directory (relative to process cwd unless absolute).
    out_dir: []const u8 = "source-rag",
    /// Project root to scan (relative to process cwd unless absolute).
    root_dir: []const u8 = ".",
    /// Skip files larger than this many bytes.
    max_bytes: usize = 512 * 1024,
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
};

/// Default directory names (under root) that are always walked when present.
pub const default_scan_dirs = [_][]const u8{
    "src",
    "docs",
    "content",
    "layouts",
    "scripts",
    "tools",
    "vendor",
    "test",
    "SUPPORT",
};

/// Root-level files packed when present.
pub const default_root_files = [_][]const u8{
    "AGENTS.md",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "build.zig",
    "build.zig.zon",
};

/// Directory basenames skipped anywhere in the walk.
/// Note: do **not** list `source-rag` here — that would also skip
/// `tools/source-rag/` (this tool). Output self-skip uses path prefix.
/// Do **not** list bare `rag` — that would skip curated `docs/rag/`.
const skip_dir_names = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "dist",
    "test-output",
    ".boris",
    ".release-gate",
    "node_modules",
    ".DS_Store",
};

/// Top-level product / cache trees only (repo-relative path equals or is under).
const skip_top_level_dirs = [_][]const u8{
    "rag",
    "rag1",
    "rag2",
    "source-rag",
    "dist",
    "zig-out",
    "test-output",
};

/// File basenames skipped.
const skip_file_names = [_][]const u8{
    ".DS_Store",
};

/// Extensions included (case-sensitive, lowercase expected in repo).
const include_extensions = [_][]const u8{
    ".zig",
    ".md",
    ".c",
    ".h",
    ".html",
    ".htm",
    ".json",
    ".jsonl",
    ".sh",
    ".zon",
    ".txt",
    ".yml",
    ".yaml",
    ".toml",
    ".css",
    ".svg",
};

const CatalogEntry = struct {
    rag_id: []const u8,
    rag_path: []const u8,
    category: []const u8,
    title: []const u8,
    source_path: []const u8,
    lang: []const u8,
    bytes: usize,
};

pub const ExportStats = struct {
    source_files: usize = 0,
    skipped: usize = 0,
    catalog_entries: usize = 0,
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

pub fn parseOptions(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            opts.help = true;
            return opts;
        } else if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-q")) {
            opts.quiet = true;
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            const v = a["--out=".len..];
            if (v.len == 0) return error.MissingValue;
            opts.out_dir = v;
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (args[i].len == 0) return error.MissingValue;
            opts.out_dir = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            const v = a["--root=".len..];
            if (v.len == 0) return error.MissingValue;
            opts.root_dir = v;
        } else if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (args[i].len == 0) return error.MissingValue;
            opts.root_dir = args[i];
        } else if (std.mem.startsWith(u8, a, "--max-bytes=")) {
            const v = a["--max-bytes=".len..];
            if (v.len == 0) return error.MissingValue;
            opts.max_bytes = std.fmt.parseInt(usize, v, 10) catch return error.InvalidValue;
        } else {
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn printUsage() void {
    std.debug.print(
        \\boris-source-rag — pack project source files for LLM upload
        \\
        \\Standalone tool (not the Boris content compiler / product RAG).
        \\
        \\Usage:
        \\  boris-source-rag [options]
        \\  zig build source-rag -- [options]
        \\
        \\Options:
        \\  -h, --help           Show this help and exit 0
        \\  -q, --quiet          Suppress progress lines
        \\  --out=DIR            Output corpus root (default: source-rag)
        \\  --root=DIR           Project root to scan (default: .)
        \\  --max-bytes=N        Skip files larger than N bytes (default: 524288)
        \\
        \\Default scan (when present under --root):
        \\  dirs:  src docs content layouts scripts tools vendor test SUPPORT
        \\  files: AGENTS.md README.md CHANGELOG.md LICENSE build.zig build.zig.zon
        \\
        \\Output tree:
        \\  INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json
        \\  files/**  (one markdown document per source path)
        \\
        \\Exit codes: 0 success, 2 usage, 3 I/O error
        \\
    , .{});
}

// ---------------------------------------------------------------------------
// Path / language helpers
// ---------------------------------------------------------------------------

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

pub fn hasIncludedExtension(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    // Extensionless allowlist (LICENSE, etc.) handled by explicit root files.
    for (include_extensions) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return true;
    }
    // Common extensionless license / notices at any depth.
    if (std.mem.eql(u8, base, "LICENSE") or std.mem.eql(u8, base, "LICENSE.txt")) return true;
    if (std.mem.eql(u8, base, "NOTICE") or std.mem.eql(u8, base, "COPYING")) return true;
    return false;
}

pub fn langFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".zig")) return "zig";
    if (std.mem.endsWith(u8, base, ".md")) return "markdown";
    if (std.mem.endsWith(u8, base, ".c")) return "c";
    if (std.mem.endsWith(u8, base, ".h")) return "c";
    if (std.mem.endsWith(u8, base, ".html") or std.mem.endsWith(u8, base, ".htm")) return "html";
    if (std.mem.endsWith(u8, base, ".json") or std.mem.endsWith(u8, base, ".jsonl")) return "json";
    if (std.mem.endsWith(u8, base, ".sh")) return "bash";
    if (std.mem.endsWith(u8, base, ".zon")) return "zig";
    if (std.mem.endsWith(u8, base, ".yml") or std.mem.endsWith(u8, base, ".yaml")) return "yaml";
    if (std.mem.endsWith(u8, base, ".toml")) return "toml";
    if (std.mem.endsWith(u8, base, ".css")) return "css";
    if (std.mem.endsWith(u8, base, ".svg")) return "xml";
    if (std.mem.endsWith(u8, base, ".txt")) return "text";
    return "text";
}

/// Corpus path for a source path: `files/<source>.md` (no double `.md.md`).
pub fn ragPathForSource(arena: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, source_path, ".md")) {
        return std.fmt.allocPrint(arena, "files/{s}", .{source_path});
    }
    return std.fmt.allocPrint(arena, "files/{s}.md", .{source_path});
}

pub fn ragIdForSource(arena: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "source/{s}", .{source_path});
}

/// Longest run of backticks in `body`, used to pick a safe fence length.
pub fn maxBacktickRun(body: []const u8) usize {
    var max: usize = 0;
    var run: usize = 0;
    for (body) |c| {
        if (c == '`') {
            run += 1;
            if (run > max) max = run;
        } else {
            run = 0;
        }
    }
    return max;
}

pub fn fenceLenFor(body: []const u8) usize {
    const n = maxBacktickRun(body) + 1;
    return if (n < 3) 3 else n;
}

pub fn looksBinary(data: []const u8) bool {
    const n = @min(data.len, 8192);
    for (data[0..n]) |b| {
        if (b == 0) return true;
    }
    return false;
}

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

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

fn pathExists(io: Io, root: Io.Dir, rel: []const u8) bool {
    _ = root.statFile(io, rel, .{}) catch return false;
    return true;
}

/// True when `rel` equals `prefix` or is a child path under it.
fn isUnderPrefix(rel: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or std.mem.eql(u8, prefix, ".")) return false;
    const p = if (std.mem.startsWith(u8, prefix, "./")) prefix[2..] else prefix;
    if (p.len == 0) return false;
    if (std.mem.eql(u8, rel, p)) return true;
    if (rel.len > p.len and std.mem.startsWith(u8, rel, p) and rel[p.len] == '/') return true;
    return false;
}

/// True when `rel` is the corpus out dir or a path under it (repo-relative).
fn isUnderOutDir(rel: []const u8, out_rel: []const u8) bool {
    return isUnderPrefix(rel, out_rel);
}

/// Skip generated product trees at repo root only (not `docs/rag/`, `tools/source-rag/`).
fn isSkippedTopLevelTree(rel: []const u8) bool {
    for (skip_top_level_dirs) |top| {
        if (isUnderPrefix(rel, top)) return true;
    }
    return false;
}

fn collectUnderDir(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out_rel: []const u8,
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
            if (isUnderOutDir(child_rel, out_rel)) continue;
            if (isSkippedTopLevelTree(child_rel)) continue;
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try collectUnderDir(io, gpa, retain, sub, child_rel, out_rel, out);
            continue;
        }
        if (entry.kind != .file) continue;
        if (isSkippedFileName(entry.name)) continue;
        const child_rel = if (prefix.len == 0)
            try retain.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
        if (isUnderOutDir(child_rel, out_rel)) continue;
        if (isSkippedTopLevelTree(child_rel)) continue;
        if (!hasIncludedExtension(child_rel)) continue;
        try out.append(gpa, child_rel);
    }
}

/// Collect source-relative paths under `root_dir`, sorted ascending.
/// `out_rel` is the corpus output path relative to the scan root (or basename when out is outside).
fn collectSourcePaths(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    root: Io.Dir,
    out_rel: []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    // Explicit root files.
    for (default_root_files) |name| {
        if (!pathExists(io, root, name)) continue;
        if (isUnderOutDir(name, out_rel)) continue;
        try list.append(gpa, try retain.dupe(u8, name));
    }

    // Default scan dirs.
    for (default_scan_dirs) |dname| {
        if (isSkippedDirName(dname)) continue;
        if (isUnderOutDir(dname, out_rel)) continue;
        if (!pathExists(io, root, dname)) continue;
        var sub = root.openDir(io, dname, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        try collectUnderDir(io, gpa, retain, sub, dname, out_rel, &list);
    }

    // De-dupe (root file also under a dir is rare; keep stable unique set).
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var uniq: std.ArrayList([]const u8) = .empty;
    errdefer uniq.deinit(gpa);
    var prev: ?[]const u8 = null;
    for (list.items) |p| {
        if (prev) |pr| {
            if (std.mem.eql(u8, pr, p)) continue;
        }
        try uniq.append(gpa, p);
        prev = p;
    }
    list.deinit(gpa);

    return try uniq.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
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

fn log(opts: Options, comptime fmt: []const u8, args: anytype) void {
    if (opts.quiet) return;
    std.debug.print(fmt, args);
}

// ---------------------------------------------------------------------------
// Document emit
// ---------------------------------------------------------------------------

fn renderSourceDocument(
    gpa: std.mem.Allocator,
    rag_id: []const u8,
    rag_path: []const u8,
    source_path: []const u8,
    lang: []const u8,
    body: []const u8,
) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);

    const fence_n = fenceLenFor(body);
    try doc.appendSlice(gpa, "---\n");
    try doc.appendSlice(gpa, "rag_id: ");
    try doc.appendSlice(gpa, rag_id);
    try doc.appendSlice(gpa, "\nrag_path: ");
    try doc.appendSlice(gpa, rag_path);
    try doc.appendSlice(gpa, "\nsource_path: ");
    try doc.appendSlice(gpa, source_path);
    try doc.appendSlice(gpa, "\ncategory: source\nlang: ");
    try doc.appendSlice(gpa, lang);
    try doc.appendSlice(gpa, "\nbytes: ");
    var num_buf: [32]u8 = undefined;
    const num = try std.fmt.bufPrint(&num_buf, "{d}", .{body.len});
    try doc.appendSlice(gpa, num);
    try doc.appendSlice(gpa, "\n---\n\n# `");
    try doc.appendSlice(gpa, source_path);
    try doc.appendSlice(gpa, "`\n\n");

    // Opening fence: ```lang
    try doc.appendNTimes(gpa, '`', fence_n);
    try doc.appendSlice(gpa, lang);
    try doc.append(gpa, '\n');
    try doc.appendSlice(gpa, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try doc.append(gpa, '\n');
    try doc.appendNTimes(gpa, '`', fence_n);
    try doc.append(gpa, '\n');

    return try doc.toOwnedSlice(gpa);
}

fn exportCatalogMeta(io: Io, out_dir: Io.Dir) !void {
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"format\":\"{s}\",\"schema_version\":{d},\"tool_version\":\"{s}\"}}\n",
        .{ format_id, schema_version, tool_version },
    );
    try writeBytes(io, out_dir, "catalog_meta.json", line);
}

fn exportCatalogJsonl(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    entries: []const CatalogEntry,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    for (entries) |e| {
        try buf.appendSlice(gpa, "{\"rag_id\":\"");
        try jsonEscapeAppend(&buf, gpa, e.rag_id);
        try buf.appendSlice(gpa, "\",\"rag_path\":\"");
        try jsonEscapeAppend(&buf, gpa, e.rag_path);
        try buf.appendSlice(gpa, "\",\"category\":\"");
        try jsonEscapeAppend(&buf, gpa, e.category);
        try buf.appendSlice(gpa, "\",\"title\":\"");
        try jsonEscapeAppend(&buf, gpa, e.title);
        try buf.appendSlice(gpa, "\",\"source_path\":\"");
        try jsonEscapeAppend(&buf, gpa, e.source_path);
        try buf.appendSlice(gpa, "\",\"lang\":\"");
        try jsonEscapeAppend(&buf, gpa, e.lang);
        try buf.appendSlice(gpa, "\",\"bytes\":");
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{e.bytes});
        try buf.appendSlice(gpa, num);
        try buf.appendSlice(gpa, "}\n");
    }
    try writeBytes(io, out_dir, "catalog.jsonl", buf.items);
}

fn exportIndex(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    entries: []const CatalogEntry,
    stats: ExportStats,
) !void {
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);

    try doc.appendSlice(gpa,
        \\---
        \\rag_id: meta/index
        \\rag_path: INDEX.md
        \\category: meta
        \\tags: [index, source-rag, llm]
        \\---
        \\
        \\# Source RAG corpus — INDEX
        \\
        \\This pack is a **source-code knowledge dump** for LLM notebooks and chat
        \\uploads. It is produced by `boris-source-rag` and is **not** the product
        \\content RAG (`boris-rag` / site pages + architecture seeds).
        \\
        \\## Counts
        \\
        \\| Segment | Count |
        \\|---------|------:|
        \\
    );
    {
        var line_buf: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "| source files | {d} |\n| catalog entries | {d} |\n| skipped | {d} |\n\n", .{
            stats.source_files,
            stats.catalog_entries,
            stats.skipped,
        });
        try doc.appendSlice(gpa, line);
    }

    try doc.appendSlice(gpa,
        \\## How to use
        \\
        \\1. Upload this entire directory (or zip it).
        \\2. Start from `INDEX.md` as the path map.
        \\3. Prefer `files/src/**` for implementation questions.
        \\4. Prefer `files/docs/contracts/**` for IR / machine contracts.
        \\5. Cite `source_path` from document frontmatter when answering.
        \\
        \\## Full catalog
        \\
        \\| rag_path | lang | source_path | bytes |
        \\|----------|------|-------------|------:|
        \\
    );

    for (entries) |e| {
        if (!std.mem.eql(u8, e.category, "source")) continue;
        try doc.appendSlice(gpa, "| `");
        try doc.appendSlice(gpa, e.rag_path);
        try doc.appendSlice(gpa, "` | ");
        try doc.appendSlice(gpa, e.lang);
        try doc.appendSlice(gpa, " | `");
        try doc.appendSlice(gpa, e.source_path);
        try doc.appendSlice(gpa, "` | ");
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{e.bytes});
        try doc.appendSlice(gpa, num);
        try doc.appendSlice(gpa, " |\n");
    }

    try doc.appendSlice(gpa,
        \\
        \\## Machine files
        \\
        \\| File | Role |
        \\|------|------|
        \\| `catalog_meta.json` | format + schema_version + tool_version |
        \\| `catalog.jsonl` | one JSON object per document (sorted by rag_path) |
        \\
        \\These two files are **not** catalog rows.
        \\
    );

    try writeBytes(io, out_dir, "INDEX.md", doc.items);
}

fn exportUploadGuide(io: Io, out_dir: Io.Dir) !void {
    const body =
        \\---
        \\rag_id: meta/upload-guide
        \\rag_path: UPLOAD-GUIDE.md
        \\category: meta
        \\tags: [upload, llm, source-rag]
        \\---
        \\
        \\# Upload guide — source RAG
        \\
        \\## What this is
        \\
        \\A **codebase pack**: project sources and key docs wrapped as markdown
        \\retrieval documents. Separate from Boris product content RAG.
        \\
        \\## What to upload
        \\
        \\Upload the **entire** generated directory (`source-rag/` by default).
        \\
        \\Minimum useful subset:
        \\
        \\1. `INDEX.md`
        \\2. `files/src/**`
        \\3. `files/docs/contracts/**` (if present)
        \\4. `files/AGENTS.md` / `files/README.md` (if present)
        \\
        \\## Suggested system prompt
        \\
        \\```
        \\You are answering questions about this repository using the source RAG corpus.
        \\Prefer files under files/src/ for implementation details.
        \\Prefer files/docs/contracts/ for normative IR and machine contracts.
        \\Cite source_path from document frontmatter when you rely on a file.
        \\Do not invent APIs that are not present in the corpus.
        \\```
        \\
        \\## Regenerating
        \\
        \\From the repo root (Zig 0.16+):
        \\
        \\```bash
        \\zig build source-rag
        \\# or
        \\zig-out/bin/boris-source-rag --out=./source-rag
        \\```
        \\
        \\## Integrity
        \\
        \\- Paths are repo-relative (no absolute host paths).
        \\- Catalog rows are sorted by `rag_path`.
        \\- No timestamps or random ids in corpus files.
        \\
    ;
    try writeBytes(io, out_dir, "UPLOAD-GUIDE.md", body);
}

fn sortCatalog(entries: []CatalogEntry) void {
    std.mem.sort(CatalogEntry, entries, {}, struct {
        fn less(_: void, a: CatalogEntry, b: CatalogEntry) bool {
            return std.mem.order(u8, a.rag_path, b.rag_path) == .lt;
        }
    }.less);
}

/// Export a source RAG corpus. `root_dir` is opened for read; `out_dir` is created/replaced contents-wise by overwrite.
pub fn exportCorpus(io: Io, gpa: std.mem.Allocator, opts: Options) !ExportStats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = Io.Dir.cwd();
    var root = try cwd.openDir(io, opts.root_dir, .{ .iterate = true });
    defer root.close(io);

    // Skip the output tree when it lives under the scan root (e.g. ./source-rag).
    const out_skip = blk: {
        const o = opts.out_dir;
        if (std.mem.startsWith(u8, o, "./")) break :blk o[2..];
        break :blk o;
    };

    const paths = try collectSourcePaths(io, gpa, arena, root, out_skip);
    defer gpa.free(paths);

    try cwd.createDirPath(io, opts.out_dir);
    var out = try cwd.openDir(io, opts.out_dir, .{});
    defer out.close(io);
    try out.createDirPath(io, "files");

    var catalog: std.ArrayList(CatalogEntry) = .empty;
    defer catalog.deinit(gpa);

    var stats: ExportStats = .{};

    log(opts, "\nSource RAG → {s}/  (root={s})\n", .{ opts.out_dir, opts.root_dir });

    for (paths) |source_path| {
        const data = readFileAlloc(io, root, source_path, gpa) catch |err| {
            log(opts, "  skip read  {s} ({s})\n", .{ source_path, @errorName(err) });
            stats.skipped += 1;
            continue;
        };
        defer gpa.free(data);

        if (data.len > opts.max_bytes) {
            log(opts, "  skip large {s} ({d} bytes)\n", .{ source_path, data.len });
            stats.skipped += 1;
            continue;
        }
        if (looksBinary(data)) {
            log(opts, "  skip bin   {s}\n", .{source_path});
            stats.skipped += 1;
            continue;
        }

        const lang = langFromPath(source_path);
        const rag_path = try ragPathForSource(arena, source_path);
        const rag_id = try ragIdForSource(arena, source_path);
        const doc = try renderSourceDocument(gpa, rag_id, rag_path, source_path, lang, data);
        defer gpa.free(doc);

        try writeBytes(io, out, rag_path, doc);

        try catalog.append(gpa, .{
            .rag_id = rag_id,
            .rag_path = rag_path,
            .category = "source",
            .title = source_path,
            .source_path = source_path,
            .lang = lang,
            .bytes = data.len,
        });
        stats.source_files += 1;
        log(opts, "  source     {s}\n", .{source_path});
    }

    // Meta documents (not source rows until we add them to catalog).
    try exportUploadGuide(io, out);
    try catalog.append(gpa, .{
        .rag_id = "meta/upload-guide",
        .rag_path = "UPLOAD-GUIDE.md",
        .category = "meta",
        .title = "Upload guide — source RAG",
        .source_path = "",
        .lang = "markdown",
        .bytes = 0,
    });
    try catalog.append(gpa, .{
        .rag_id = "meta/index",
        .rag_path = "INDEX.md",
        .category = "meta",
        .title = "Source RAG corpus — INDEX",
        .source_path = "",
        .lang = "markdown",
        .bytes = 0,
    });

    sortCatalog(catalog.items);
    stats.catalog_entries = catalog.items.len;

    // INDEX after catalog is sorted (lists source rows).
    try exportIndex(io, gpa, out, catalog.items, stats);
    try exportCatalogJsonl(io, gpa, out, catalog.items);
    try exportCatalogMeta(io, out);

    log(opts, "\nDone: {d} source files, {d} catalog entries, {d} skipped → {s}/\n", .{
        stats.source_files,
        stats.catalog_entries,
        stats.skipped,
        opts.out_dir,
    });

    return stats;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args_z = init.minimal.args.toSlice(cold) catch {
        std.log.err("failed to read process arguments", .{});
        return ExitCode.usage.int();
    };

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(cold);
    args_list.ensureTotalCapacity(cold, args_z.len) catch {
        std.log.err("out of memory parsing arguments", .{});
        return ExitCode.usage.int();
    };
    for (args_z) |a| {
        args_list.appendAssumeCapacity(a);
    }

    const opts = parseOptions(args_list.items) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                var i: usize = if (args_list.items.len > 0) 1 else 0;
                while (i < args_list.items.len) : (i += 1) {
                    const a = args_list.items[i];
                    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) continue;
                    if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-q")) continue;
                    if (std.mem.startsWith(u8, a, "--out=") or std.mem.startsWith(u8, a, "--root=") or std.mem.startsWith(u8, a, "--max-bytes=")) continue;
                    if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "--root")) {
                        i += 1;
                        continue;
                    }
                    std.log.err("unknown argument: {s} (try --help)", .{a});
                    printUsage();
                    return ExitCode.usage.int();
                }
            },
            error.MissingValue => std.log.err("missing value for flag (try --help)", .{}),
            error.InvalidValue => std.log.err("invalid flag value (try --help)", .{}),
        }
        printUsage();
        return ExitCode.usage.int();
    };

    if (opts.help) {
        printUsage();
        return ExitCode.success.int();
    }

    _ = exportCorpus(io, gpa, opts) catch |err| {
        std.log.err("source-rag export failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseOptions: help and defaults" {
    const o = try parseOptions(&.{"boris-source-rag"});
    try std.testing.expect(!o.help);
    try std.testing.expectEqualStrings("source-rag", o.out_dir);
    try std.testing.expectEqualStrings(".", o.root_dir);

    const h = try parseOptions(&.{ "boris-source-rag", "--help" });
    try std.testing.expect(h.help);

    const o2 = try parseOptions(&.{ "boris-source-rag", "--out=./pack", "--root=../repo", "--max-bytes=1000", "--quiet" });
    try std.testing.expectEqualStrings("./pack", o2.out_dir);
    try std.testing.expectEqualStrings("../repo", o2.root_dir);
    try std.testing.expectEqual(@as(usize, 1000), o2.max_bytes);
    try std.testing.expect(o2.quiet);
}

test "parseOptions: unknown flag" {
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "x", "--rag" }));
}

test "langFromPath and extensions" {
    try std.testing.expectEqualStrings("zig", langFromPath("src/main.zig"));
    try std.testing.expectEqualStrings("markdown", langFromPath("README.md"));
    try std.testing.expectEqualStrings("c", langFromPath("vendor/apex/apex.c"));
    try std.testing.expect(hasIncludedExtension("src/a.zig"));
    try std.testing.expect(hasIncludedExtension("LICENSE"));
    try std.testing.expect(!hasIncludedExtension("photo.png"));
    try std.testing.expect(isSkippedDirName("zig-out"));
    try std.testing.expect(!isSkippedDirName("source-rag")); // tool lives at tools/source-rag
    try std.testing.expect(isUnderOutDir("source-rag", "source-rag"));
    try std.testing.expect(isUnderOutDir("source-rag/INDEX.md", "source-rag"));
    try std.testing.expect(!isUnderOutDir("tools/source-rag/main.zig", "source-rag"));
    try std.testing.expect(isSkippedTopLevelTree("rag/INDEX.md"));
    try std.testing.expect(!isSkippedTopLevelTree("docs/rag/system/00-overview.md"));
    try std.testing.expect(!isSkippedTopLevelTree("tools/source-rag/main.zig"));
}

test "ragPathForSource avoids double md" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const p1 = try ragPathForSource(a, "src/main.zig");
    try std.testing.expectEqualStrings("files/src/main.zig.md", p1);
    const p2 = try ragPathForSource(a, "README.md");
    try std.testing.expectEqualStrings("files/README.md", p2);
}

test "fenceLenFor handles nested fences" {
    try std.testing.expectEqual(@as(usize, 3), fenceLenFor("plain"));
    try std.testing.expectEqual(@as(usize, 4), fenceLenFor("has ``` inside"));
    try std.testing.expectEqual(@as(usize, 5), fenceLenFor("```` longer"));
}

test "looksBinary" {
    try std.testing.expect(!looksBinary("hello\n"));
    try std.testing.expect(looksBinary(&[_]u8{ 'a', 0, 'b' }));
}

test "renderSourceDocument wraps body" {
    const gpa = std.testing.allocator;
    const doc = try renderSourceDocument(gpa, "source/a.zig", "files/a.zig.md", "a.zig", "zig", "const x = 1;\n");
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "source_path: a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "```zig\nconst x = 1;\n```\n") != null);
}

test "exportCorpus mini fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/src-rag-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/src-rag-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try Io.Dir.cwd().createDirPath(io, root_rel);
    {
        const src_rel = try std.fmt.allocPrint(gpa, "{s}/src", .{root_rel});
        defer gpa.free(src_rel);
        try Io.Dir.cwd().createDirPath(io, src_rel);
    }
    {
        var root = try Io.Dir.cwd().openDir(io, root_rel, .{});
        defer root.close(io);
        try root.writeFile(io, .{ .sub_path = "README.md", .data = "# Demo\n" });
        try root.writeFile(io, .{ .sub_path = "src/hello.zig", .data = "pub fn main() void {}\n" });
        try root.writeFile(io, .{ .sub_path = "src/skip.bin", .data = &[_]u8{ 0x00, 0x01, 0x02 } });
    }

    const stats = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .max_bytes = 512 * 1024,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.source_files);
    try std.testing.expect(stats.catalog_entries >= 2);

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);

    const meta = try readFileAlloc(io, out, "catalog_meta.json", gpa);
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, format_id) != null);

    const index = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "files/src/hello.zig.md") != null);

    const hello = try readFileAlloc(io, out, "files/src/hello.zig.md", gpa);
    defer gpa.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "pub fn main()") != null);

    const catalog = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "src/hello.zig") != null);
}
