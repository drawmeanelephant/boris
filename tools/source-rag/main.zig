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
const build_info = @import("build_info");

pub const format_id = "boris-source-rag";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

/// Opaque VCS revision token baked at compile time ("" when undetected,
/// e.g. tarball builds; ".dirty" suffix for uncommitted worktrees).
/// Threaded explicitly through the export pipeline; no ambient git probe.
pub const vcs_revision: []const u8 = build_info.vcs_revision;

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
    version: bool = false,
    quiet: bool = false,
    /// Skip the combined Markdown convenience bundles.
    no_bundles: bool = false,
    /// Emit combined bundles and sidecars only; omit the per-file `files/` tree.
    /// Mutually exclusive with `no_bundles`.
    bundles_only: bool = false,
    /// Named input scope. `all` preserves the historical complete export.
    profile: Profile = .all,
    /// Output segmentation axis, orthogonal to `profile`. `none` preserves the
    /// historical single flat corpus; `tool` emits one self-contained pack per
    /// segment under `packs/` behind a root router.
    pack_by: PackBy = .none,
    /// Corpus output directory (relative to process cwd unless absolute).
    out_dir: []const u8 = "source-rag",
    /// Project root to scan (relative to process cwd unless absolute).
    root_dir: []const u8 = ".",
    /// Skip files larger than this many bytes.
    max_bytes: usize = 512 * 1024,
    /// Target maximum body bytes per combined bundle part. A single source
    /// document larger than this limit is kept whole in its own part.
    split_size: usize = 512 * 1024,
    /// Test-only deterministic failure injection after this many staged source
    /// documents have been written. Not accepted by the CLI.
    test_fail_after_stage_writes: ?usize = null,
    /// Additive build provenance (#795): opaque VCS revision token of the
    /// producing binary. Threaded explicitly from the entry point; never
    /// probed at runtime. "" sentinel when undetected.
    vcs_revision: []const u8 = "",

    pub fn includeBundles(self: Options) bool {
        return !self.no_bundles;
    }

    pub fn includePerFileDocs(self: Options) bool {
        return !self.bundles_only;
    }
};

pub const Profile = enum { all, core, docs, tools };

/// Output segmentation axis. Orthogonal to `Profile`: `profile` selects which
/// files are scanned, `pack_by` selects how the scanned set is split across
/// output packs.
pub const PackBy = enum { none, tool };

pub fn packByName(pack_by: PackBy) []const u8 {
    return switch (pack_by) {
        .none => "none",
        .tool => "tool",
    };
}

fn parsePackBy(value: []const u8) ParseError!PackBy {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "tool")) return .tool;
    return error.InvalidValue;
}

pub fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .all => "all",
        .core => "core",
        .docs => "docs",
        .tools => "tools",
    };
}

fn parseProfile(value: []const u8) ParseError!Profile {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "core")) return .core;
    if (std.mem.eql(u8, value, "docs")) return .docs;
    if (std.mem.eql(u8, value, "tools")) return .tools;
    return error.InvalidValue;
}

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
    "test",
    "fixtures",
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
    // Local object/build trees (e.g. vendor/**/build/) — host-specific and
    // gitignored; must not enter LLM source packs / external audit corpora.
    "build",
    "CMakeFiles",
};

/// Top-level product, cache, and third-party trees only (repo-relative path equals or is under).
const skip_top_level_dirs = [_][]const u8{
    "rag",
    "rag1",
    "rag2",
    "source-rag",
    "dist",
    "zig-out",
    "test-output",
    // Vendored dependencies do not belong in the source corpus. Keep this
    // root-only so the exporter itself remains at tools/source-rag/.
    "vendor",
};

fn scanDirsForProfile(profile: Profile) []const []const u8 {
    return switch (profile) {
        .all => &default_scan_dirs,
        .core => &[_][]const u8{ "src", "layouts" },
        .docs => &[_][]const u8{ "docs", "content" },
        .tools => &[_][]const u8{ "scripts", "tools", "test", "fixtures", "SUPPORT" },
    };
}

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
    /// Total packed body bytes. Authoritative size for pack routing; any token
    /// figure derived from it is an approximation.
    bytes: usize = 0,
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Tool id printed by `--version`/`-V`. Kept in lockstep with the product
/// release line (`pipeline.boris_version`); this tool does not import `src/`.
pub const tool_id = "boris-source-rag/0.8.1";

pub fn parseOptions(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            opts.help = true;
            return opts;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            opts.version = true;
            return opts;
        } else if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-q")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, a, "--no-bundles")) {
            opts.no_bundles = true;
        } else if (std.mem.eql(u8, a, "--bundles-only")) {
            opts.bundles_only = true;
        } else if (std.mem.startsWith(u8, a, "--profile=")) {
            const v = a["--profile=".len..];
            if (v.len == 0) return error.MissingValue;
            opts.profile = try parseProfile(v);
        } else if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingValue;
            opts.profile = try parseProfile(args[i]);
        } else if (std.mem.startsWith(u8, a, "--pack-by=")) {
            const v = a["--pack-by=".len..];
            if (v.len == 0) return error.MissingValue;
            opts.pack_by = try parsePackBy(v);
        } else if (std.mem.eql(u8, a, "--pack-by")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingValue;
            opts.pack_by = try parsePackBy(args[i]);
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
        } else if (std.mem.startsWith(u8, a, "--split-size=")) {
            const v = a["--split-size=".len..];
            if (v.len == 0) return error.MissingValue;
            opts.split_size = std.fmt.parseInt(usize, v, 10) catch return error.InvalidValue;
            if (opts.split_size == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, a, "--split-size")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return error.MissingValue;
            opts.split_size = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidValue;
            if (opts.split_size == 0) return error.InvalidValue;
        } else {
            return error.UnknownFlag;
        }
    }
    if (opts.no_bundles and opts.bundles_only) return error.InvalidValue;
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
        \\  -V, --version        Print the tool id and exit 0
        \\  -q, --quiet          Suppress progress lines
        \\  --no-bundles         Skip combined bundles; emit per-file corpus and sidecars
        \\  --bundles-only       Emit combined bundles and sidecars; omit files/** tree
        \\  --profile=NAME       Input scope: all (default), core, docs, or tools
        \\  --pack-by=AXIS       Output split: none (default) or tool
        \\  --out=DIR            Output corpus root (default: source-rag)
        \\  --root=DIR           Project root to scan (default: .)
        \\  --max-bytes=N        Skip files larger than N bytes (default: 524288)
        \\  --split-size=N       Target body bytes per combined bundle part (default: 524288)
        \\
        \\  --no-bundles and --bundles-only are mutually exclusive.
        \\
        \\Default scan (when present under --root):
        \\  dirs:  src docs content layouts scripts tools test SUPPORT
        \\  files: AGENTS.md README.md CHANGELOG.md LICENSE build.zig build.zig.zon
        \\
        \\Output tree:
        \\  INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json
        \\  profile_manifest.json  part_manifest.json
        \\  boris-source-N.md  boris-docs[-N].md  boris-content[-N].md  (bundles)
        \\  files/**  (one markdown document per source path; omitted with --bundles-only)
        \\
        \\With --pack-by=tool the same tree is emitted once per pack under
        \\packs/<name>/, and the root keeps only INDEX.md (a router over the
        \\packs) and pack_manifest.json. Packs are core, docs, content, and one
        \\per tools/<name>/, discovered from the scanned paths.
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
    _ = root.statFile(io, rel, .{}) catch {
        var child = root.openDir(io, rel, .{}) catch return false;
        child.close(io);
        return true;
    };
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

fn normalizePathSeparators(path: []u8) void {
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
}

fn stripTrailingPathSeparator(path: []u8) []u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

/// Resolve the scan/output relationship lexically from the process cwd.
/// Output nested under root is safe when excluded by its normalized relative
/// path; equal roots and output ancestors are rejected before publication.
fn resolveOutputSkip(
    io: Io,
    gpa: std.mem.Allocator,
    root_path: []const u8,
    out_path: []const u8,
) !struct { root_abs: []u8, out_abs: []u8, out_skip: []const u8 } {
    const cwd_owned = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_owned);
    normalizePathSeparators(cwd_owned);
    const cwd_path = stripTrailingPathSeparator(cwd_owned);

    const root_abs = try std.fs.path.resolve(gpa, &.{ cwd_path, root_path });
    errdefer gpa.free(root_abs);
    normalizePathSeparators(root_abs);
    const root_norm = stripTrailingPathSeparator(root_abs);

    const out_abs = try std.fs.path.resolve(gpa, &.{ cwd_path, out_path });
    errdefer gpa.free(out_abs);
    normalizePathSeparators(out_abs);
    const out_norm = stripTrailingPathSeparator(out_abs);

    if (std.mem.eql(u8, root_norm, out_norm) or isUnderPrefix(root_norm, out_norm)) {
        return error.SourceRagOutputCollision;
    }

    const out_skip: []const u8 = if (isUnderPrefix(out_norm, root_norm)) blk: {
        const start = if (std.mem.eql(u8, root_norm, "/")) 1 else root_norm.len + 1;
        break :blk out_norm[start..];
    } else "";

    return .{ .root_abs = root_abs, .out_abs = out_abs, .out_skip = out_skip };
}

/// Skip generated, cache, and vendor trees at repo root only (not `docs/rag/`, `tools/source-rag/`).
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
    profile: Profile,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    // Explicit root files.
    if (profile == .all or profile == .core) {
        for (default_root_files) |name| {
            if (!pathExists(io, root, name)) continue;
            if (isUnderOutDir(name, out_rel)) continue;
            try list.append(gpa, try retain.dupe(u8, name));
        }
    }

    // Default scan dirs.
    for (scanDirsForProfile(profile)) |dname| {
        if (isSkippedDirName(dname)) continue;
        if (isUnderOutDir(dname, out_rel)) continue;
        if (isSkippedTopLevelTree(dname)) continue;
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

/// Read a scanned source file while bounding the allocation used to decide
/// whether it exceeds `max_bytes`. The extra byte preserves the existing
/// skip-large decision without loading an arbitrarily large input.
fn readSourceAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    var reader = file.reader(io, &.{});
    if (size <= max_bytes) return try reader.interface.readAlloc(allocator, size);

    const prefix = try allocator.alloc(u8, max_bytes + 1);
    errdefer allocator.free(prefix);
    try reader.interface.readSliceAll(prefix);
    return prefix;
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

/// Root files owned by this exporter. `files/` is the only managed directory.
/// `upload_manifest.json` is written only for `--bundles-only`; it remains managed
/// so a later default export cleans a prior bundles-only pack.
const managed_root_file_names = [_][]const u8{
    "INDEX.md",
    "UPLOAD-GUIDE.md",
    "catalog.jsonl",
    "catalog_meta.json",
    "profile_manifest.json",
    "part_manifest.json",
    "upload_manifest.json",
    "pack_manifest.json",
};

/// Managed directory trees, moved whole by the atomic publish.
///
/// `packs` is one tree rather than a per-pack entry precisely so this list stays
/// fixed while the set of packs varies: replacing the tree retires packs that no
/// longer exist instead of stranding them in the output.
const managed_tree_names = [_][]const u8{
    "files",
    packs_dir_name,
};

/// Approximate token count for planning LLM uploads. Uses the documented
/// `chars/4` heuristic on UTF-8 byte length (integer floor). Not a tokenizer.
pub fn approxTokensFromBytes(byte_count: usize) usize {
    return byte_count / 4;
}

fn fileByteSize(io: Io, dir: Io.Dir, rel: []const u8) !usize {
    const st = try dir.statFile(io, rel, .{});
    return st.size;
}

fn isManagedBundleFileName(name: []const u8) bool {
    const exact = [_][]const u8{ "boris-docs.md", "boris-content.md" };
    for (exact) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    const prefixes = [_][]const u8{ "boris-source-", "boris-docs-", "boris-content-" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".md")) continue;
        const digits = name[prefix.len .. name.len - ".md".len];
        if (digits.len == 0) continue;
        var all_digits = true;
        for (digits) |digit| {
            if (digit < '0' or digit > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return true;
    }
    return false;
}

fn collectManagedBundleNames(
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isManagedBundleFileName(entry.name)) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try names.toOwnedSlice(gpa);
}

fn freeManagedBundleNames(gpa: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| gpa.free(name);
    gpa.free(names);
}

fn deleteManagedBundleFiles(io: Io, gpa: std.mem.Allocator, out: Io.Dir) !void {
    const names = try collectManagedBundleNames(io, gpa, out);
    defer freeManagedBundleNames(gpa, names);
    for (names) |name| try out.deleteFile(io, name);
}

fn deleteManagedFiles(io: Io, gpa: std.mem.Allocator, out: Io.Dir) !void {
    for (managed_tree_names) |tree_name| try removeTreeIfPresent(io, out, tree_name);
    for (managed_root_file_names) |file_name| {
        out.deleteFile(io, file_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    try deleteManagedBundleFiles(io, gpa, out);
}

fn removeTreeIfPresent(io: Io, dir: Io.Dir, path: []const u8) !void {
    var child = dir.openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    child.close(io);
    try dir.deleteTree(io, path);
}

fn moveIfPresent(io: Io, from: Io.Dir, path: []const u8, to: Io.Dir) !bool {
    from.rename(path, to, path, io) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn moveManagedBundleFiles(io: Io, gpa: std.mem.Allocator, from: Io.Dir, to: Io.Dir) !void {
    const names = try collectManagedBundleNames(io, gpa, from);
    defer freeManagedBundleNames(gpa, names);
    for (names) |name| try from.rename(name, to, name, io);
}

fn restorePreviousManagedCorpus(io: Io, gpa: std.mem.Allocator, prev: Io.Dir, out: Io.Dir) !void {
    for (managed_tree_names) |tree_name| {
        _ = try moveIfPresent(io, prev, tree_name, out);
    }
    for (managed_root_file_names) |file_name| {
        _ = try moveIfPresent(io, prev, file_name, out);
    }
    try moveManagedBundleFiles(io, gpa, prev, out);
}

fn moveManagedCorpus(io: Io, gpa: std.mem.Allocator, from: Io.Dir, to: Io.Dir) !void {
    for (managed_tree_names) |tree_name| {
        _ = try moveIfPresent(io, from, tree_name, to);
    }
    for (managed_root_file_names) |file_name| {
        _ = try moveIfPresent(io, from, file_name, to);
    }
    try moveManagedBundleFiles(io, gpa, from, to);
}

/// Publish a complete staged corpus without ever deleting the caller-selected
/// output root. Managed paths are moved aside, then restored if the install
/// fails; unrelated siblings are never moved or removed.
fn publishManagedCorpus(io: Io, gpa: std.mem.Allocator, stage_path: []const u8, out_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const prev_path = try std.fmt.allocPrint(gpa, "{s}.boris-source-rag-prev", .{out_path});
    defer gpa.free(prev_path);

    if (std.fs.path.dirname(out_path)) |parent| {
        if (parent.len > 0) try cwd.createDirPath(io, parent);
    }
    try cwd.createDirPath(io, out_path);
    try removeTreeIfPresent(io, cwd, prev_path);
    try cwd.createDirPath(io, prev_path);

    var stage = try cwd.openDir(io, stage_path, .{ .iterate = true });
    defer stage.close(io);
    var out = try cwd.openDir(io, out_path, .{ .iterate = true });
    defer out.close(io);
    var prev = try cwd.openDir(io, prev_path, .{ .iterate = true });
    defer prev.close(io);

    moveManagedCorpus(io, gpa, out, prev) catch |err| {
        restorePreviousManagedCorpus(io, gpa, prev, out) catch return error.SourceRagPublishRestoreFailed;
        return err;
    };
    moveManagedCorpus(io, gpa, stage, out) catch |err| {
        deleteManagedFiles(io, gpa, out) catch return error.SourceRagPublishRestoreFailed;
        restorePreviousManagedCorpus(io, gpa, prev, out) catch return error.SourceRagPublishRestoreFailed;
        return err;
    };

    // Cleanup failures leave harmless sibling recovery material; they must not
    // turn a completed publication into a failed export.
    removeTreeIfPresent(io, cwd, prev_path) catch {};
    removeTreeIfPresent(io, cwd, stage_path) catch {};
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

const PackedSource = struct {
    rag_id: []const u8,
    rag_path: []const u8,
    source_path: []const u8,
    lang: []const u8,
    body: []u8,
};

const BundleKind = enum {
    source,
    docs,
    content,
};

fn bundleKindForPath(source_path: []const u8) BundleKind {
    if (std.mem.startsWith(u8, source_path, "docs/")) return .docs;
    if (std.mem.startsWith(u8, source_path, "content/")) return .content;
    return .source;
}

fn bundleKindName(kind: BundleKind) []const u8 {
    return switch (kind) {
        .source => "source",
        .docs => "docs",
        .content => "content",
    };
}

fn bundleByteCount(files: []const PackedSource) usize {
    var total: usize = 0;
    for (files) |file| total += file.body.len;
    return total;
}

// ---------------------------------------------------------------------------
// Pack partitioning (`--pack-by=tool`)
// ---------------------------------------------------------------------------

/// Parent directory for every emitted pack.
///
/// Packs live under one tree rather than as top-level siblings so the atomic
/// publish keeps moving a fixed set of managed paths. The set of packs changes
/// between runs; the set of managed paths must not, or a pack removed from the
/// repo would be stranded in the output forever.
const packs_dir_name = "packs";

/// Pack matching the `.core` input scope: compiler sources and layouts, plus the
/// root-level files every scan collects.
const core_pack_name = "core";

/// Pack matching the `.docs` input scope.
const docs_pack_name = "docs";

/// Pack holding the part of the `.tools` input scope that belongs to no
/// individual tool.
const tooling_pack_name = "tooling";

const tool_pack_prefix = "tools-";

/// Leading path segment of a repo-relative path; the whole name for a root file.
fn topLevelSegment(source_path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, source_path, '/')) |slash| return source_path[0..slash];
    return source_path;
}

fn segmentInProfileScope(segment: []const u8, profile: Profile) bool {
    for (scanDirsForProfile(profile)) |dir| {
        if (std.mem.eql(u8, segment, dir)) return true;
    }
    return false;
}

/// Total assignment of one scanned repo-relative path to exactly one pack.
///
/// Pack boundaries are **derived from `scanDirsForProfile`** rather than restated
/// here, so the packs follow the project's own declared input scopes instead of a
/// second, independently-drifting list: `.docs` becomes the `docs` pack, `.core`
/// plus the root files become `core`, and `.tools` splits into one pack per
/// `tools/<name>/` with its remainder (`scripts`, `test`, `SUPPORT`) in `tooling`.
///
/// Tool packs come from the scanned paths, so a tool added to the repo gets its
/// own pack with no change here. Anything outside every declared scope falls to
/// `core`, which keeps the assignment total: no scanned file is dropped and none
/// is emitted into two packs.
fn packNameForPath(arena: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    // `tools/<name>/**` is the axis this flag splits on, so it is resolved before
    // the enclosing `.tools` scope.
    if (std.mem.startsWith(u8, source_path, "tools/")) {
        const rest = source_path["tools/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            if (slash > 0) {
                return try std.fmt.allocPrint(arena, "{s}{s}", .{ tool_pack_prefix, rest[0..slash] });
            }
        }
        // A loose file directly under `tools/` belongs to no individual tool but
        // is still part of the `.tools` scope.
        return tooling_pack_name;
    }

    const segment = topLevelSegment(source_path);
    if (segmentInProfileScope(segment, .docs)) return docs_pack_name;
    if (segmentInProfileScope(segment, .tools)) return tooling_pack_name;
    return core_pack_name;
}

/// One output pack: a name and the scanned paths assigned to it.
const Pack = struct {
    name: []const u8,
    paths: std.ArrayList([]const u8),
};

/// Group scanned paths into packs, ordered by name so a given repo state always
/// produces the same output tree.
fn partitionPacks(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    paths: []const []const u8,
) ![]Pack {
    var packs: std.ArrayList(Pack) = .empty;
    errdefer {
        for (packs.items) |*pack| pack.paths.deinit(gpa);
        packs.deinit(gpa);
    }

    for (paths) |source_path| {
        const name = try packNameForPath(arena, source_path);
        const pack = blk: {
            for (packs.items) |*candidate| {
                if (std.mem.eql(u8, candidate.name, name)) break :blk candidate;
            }
            try packs.append(gpa, .{ .name = name, .paths = .empty });
            break :blk &packs.items[packs.items.len - 1];
        };
        try pack.paths.append(gpa, source_path);
    }

    std.mem.sort(Pack, packs.items, {}, struct {
        fn less(_: void, a: Pack, b: Pack) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return try packs.toOwnedSlice(gpa);
}

fn freePacks(gpa: std.mem.Allocator, packs: []Pack) void {
    for (packs) |*pack| pack.paths.deinit(gpa);
    gpa.free(packs);
}

/// What a pack contains, for the root router. Describes the material only — no
/// consumer, product, or vendor is named, so the same corpus serves any reader.
fn packPurpose(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, core_pack_name)) {
        return "Compiler sources, layouts, and root project guidance.";
    }
    if (std.mem.eql(u8, name, docs_pack_name)) {
        return "Normative contracts, design records, documentation, and the site content the compiler consumes.";
    }
    if (std.mem.eql(u8, name, tooling_pack_name)) {
        return "Build, release, and test machinery: scripts, test fixtures, and support material.";
    }
    if (std.mem.startsWith(u8, name, tool_pack_prefix)) {
        return try std.fmt.allocPrint(
            arena,
            "Sources and fixtures for the `tools/{s}/` auxiliary tool.",
            .{name[tool_pack_prefix.len..]},
        );
    }
    return "Project sources.";
}

/// Questions a pack is the right place to answer. Kept behavioural rather than
/// tied to any retrieval stack or consumer.
fn packQuestions(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, core_pack_name)) {
        return "How the compiler parses, resolves, and emits; how a page is laid out.";
    }
    if (std.mem.eql(u8, name, docs_pack_name)) {
        return "What a contract requires; why a design decision was taken; what the demo site contains.";
    }
    if (std.mem.eql(u8, name, tooling_pack_name)) {
        return "How the project is built, gated, and released; what valid and invalid input fixtures look like.";
    }
    if (std.mem.startsWith(u8, name, tool_pack_prefix)) {
        return try std.fmt.allocPrint(
            arena,
            "How `tools/{s}/` works, what it converts or checks, and how to run it.",
            .{name[tool_pack_prefix.len..]},
        );
    }
    return "General questions about this repository.";
}

/// Router row for one emitted pack.
const PackSummary = struct {
    name: []const u8,
    files: usize,
    bytes: usize,
};

const BundlePart = struct {
    kind: BundleKind,
    part: usize,
    total_parts: usize,
    file_name: []const u8,
    files: []const PackedSource,
    bytes: usize,
};

const PartitionRange = struct {
    start: usize,
    end: usize,
    bytes: usize,
};

fn bundlePrefix(kind: BundleKind) []const u8 {
    return switch (kind) {
        .source => "boris-source-",
        .docs => "boris-docs-",
        .content => "boris-content-",
    };
}

fn bundleFileName(
    gpa: std.mem.Allocator,
    kind: BundleKind,
    part: usize,
    total_parts: usize,
) ![]const u8 {
    if (total_parts == 1 and kind != .source) {
        return try std.fmt.allocPrint(gpa, "boris-{s}.md", .{bundleKindName(kind)});
    }
    return try std.fmt.allocPrint(gpa, "{s}{d}.md", .{ bundlePrefix(kind), part });
}

/// Partition a sorted group into contiguous whole-document parts. The limit
/// is a target: a single document larger than it is retained alone and may
/// make that part larger than the requested size.
fn partitionBundleFiles(
    gpa: std.mem.Allocator,
    kind: BundleKind,
    files: []const PackedSource,
    split_size: usize,
) ![]const BundlePart {
    var ranges: std.ArrayList(PartitionRange) = .empty;
    defer ranges.deinit(gpa);

    if (files.len == 0) {
        try ranges.append(gpa, .{ .start = 0, .end = 0, .bytes = 0 });
    } else {
        var start: usize = 0;
        var bytes: usize = 0;
        for (files, 0..) |file, index| {
            if (index > start and (bytes > split_size or file.body.len > split_size - bytes)) {
                try ranges.append(gpa, .{ .start = start, .end = index, .bytes = bytes });
                start = index;
                bytes = 0;
            }
            bytes += file.body.len;
        }
        try ranges.append(gpa, .{ .start = start, .end = files.len, .bytes = bytes });
    }

    var parts: std.ArrayList(BundlePart) = .empty;
    errdefer {
        for (parts.items) |part| gpa.free(part.file_name);
        parts.deinit(gpa);
    }
    try parts.ensureTotalCapacity(gpa, ranges.items.len);
    for (ranges.items, 0..) |range, index| {
        parts.appendAssumeCapacity(.{
            .kind = kind,
            .part = index + 1,
            .total_parts = ranges.items.len,
            .file_name = try bundleFileName(gpa, kind, index + 1, ranges.items.len),
            .files = files[range.start..range.end],
            .bytes = range.bytes,
        });
    }
    return try parts.toOwnedSlice(gpa);
}

fn renderBundle(
    gpa: std.mem.Allocator,
    file_name: []const u8,
    kind: BundleKind,
    part: ?usize,
    parts: ?usize,
    files: []const PackedSource,
) ![]u8 {
    var doc: std.ArrayList(u8) = .empty;
    errdefer doc.deinit(gpa);

    try doc.appendSlice(gpa, "---\nrag_id: bundle/");
    try doc.appendSlice(gpa, file_name);
    try doc.appendSlice(gpa, "\nrag_path: ");
    try doc.appendSlice(gpa, file_name);
    try doc.appendSlice(gpa, "\ncategory: bundle\nbundle_kind: ");
    try doc.appendSlice(gpa, bundleKindName(kind));
    if (part) |p| {
        try doc.appendSlice(gpa, "\npart: ");
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{p});
        try doc.appendSlice(gpa, num);
    }
    if (parts) |count| {
        try doc.appendSlice(gpa, "\nparts: ");
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{count});
        try doc.appendSlice(gpa, num);
    }
    try doc.appendSlice(gpa, "\ndocuments: ");
    {
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{files.len});
        try doc.appendSlice(gpa, num);
    }
    try doc.appendSlice(gpa, "\nbytes: ");
    {
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{bundleByteCount(files)});
        try doc.appendSlice(gpa, num);
    }
    try doc.appendSlice(gpa, "\n---\n\n# Boris ");
    try doc.appendSlice(gpa, bundleKindName(kind));
    if (part) |p| {
        try doc.appendSlice(gpa, " bundle ");
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{p});
        try doc.appendSlice(gpa, num);
        if (parts) |count| {
            try doc.appendSlice(gpa, "/");
            const count_text = try std.fmt.bufPrint(&num_buf, "{d}", .{count});
            try doc.appendSlice(gpa, count_text);
        }
    } else {
        try doc.appendSlice(gpa, " bundle");
    }
    try doc.appendSlice(gpa, "\n\nEach packed source below is a whole document. Its per-document frontmatter and fenced body retain the original `source_path`, language, and byte count.\n");

    if (files.len == 0) {
        try doc.appendSlice(gpa, "\nNo packed documents are in this bundle.\n");
        return try doc.toOwnedSlice(gpa);
    }

    for (files, 0..) |file, index| {
        try doc.appendSlice(gpa, "\n\n## Packed document ");
        var num_buf: [32]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{index + 1});
        try doc.appendSlice(gpa, num);
        try doc.appendSlice(gpa, ": `");
        try doc.appendSlice(gpa, file.source_path);
        try doc.appendSlice(gpa, "`\n\n");

        const segment = try renderSourceDocument(
            gpa,
            file.rag_id,
            file.rag_path,
            file.source_path,
            file.lang,
            file.body,
        );
        defer gpa.free(segment);
        try doc.appendSlice(gpa, segment);
    }

    return try doc.toOwnedSlice(gpa);
}

fn exportBundle(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    file_name: []const u8,
    kind: BundleKind,
    part: ?usize,
    parts: ?usize,
    files: []const PackedSource,
) !void {
    const doc = try renderBundle(gpa, file_name, kind, part, parts, files);
    defer gpa.free(doc);
    try writeBytes(io, out_dir, file_name, doc);
}

fn exportBundles(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    split_size: usize,
    source_files: []const PackedSource,
    docs_files: []const PackedSource,
    content_files: []const PackedSource,
    all_parts: *std.ArrayList(BundlePart),
) !void {
    const groups = [_]struct { kind: BundleKind, files: []const PackedSource }{
        .{ .kind = .source, .files = source_files },
        .{ .kind = .docs, .files = docs_files },
        .{ .kind = .content, .files = content_files },
    };
    for (groups) |group| {
        const parts = try partitionBundleFiles(gpa, group.kind, group.files, split_size);
        defer gpa.free(parts);
        for (parts) |part| {
            try exportBundle(
                io,
                gpa,
                out_dir,
                part.file_name,
                part.kind,
                part.part,
                part.total_parts,
                part.files,
            );
            try all_parts.append(gpa, part);
        }
    }
}

fn exportCatalogMeta(io: Io, out_dir: Io.Dir, profile: Profile, split_size: usize, vcs_revision_param: []const u8) !void {
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"format\":\"{s}\",\"schema_version\":{d},\"tool_version\":\"{s}\",\"profile\":\"{s}\",\"split_size\":{d},\"vcs_revision\":\"{s}\"}}\n",
        .{ format_id, schema_version, tool_version, profileName(profile), split_size, vcs_revision_param },
    );
    try writeBytes(io, out_dir, "catalog_meta.json", line);
}

fn exportProfileManifest(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    profile: Profile,
    stats: ExportStats,
    packed_paths: []const []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"profile\":\"");
    try buf.appendSlice(gpa, profileName(profile));
    try buf.appendSlice(gpa, "\",\"source_files\":");
    var num_buf: [32]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{stats.source_files}));
    try buf.appendSlice(gpa, ",\"catalog_entries\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{stats.catalog_entries}));
    try buf.appendSlice(gpa, ",\"skipped\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d},\"paths\":[", .{stats.skipped}));
    for (packed_paths, 0..) |path, index| {
        if (index != 0) try buf.appendSlice(gpa, ",");
        try buf.append(gpa, '"');
        try jsonEscapeAppend(&buf, gpa, path);
        try buf.append(gpa, '"');
    }
    try buf.appendSlice(gpa, "]}\n");
    try writeBytes(io, out_dir, "profile_manifest.json", buf.items);
}

fn exportPartManifest(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    profile: Profile,
    split_size: usize,
    include_bundles: bool,
    parts: []const BundlePart,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"profile\":\"");
    try jsonEscapeAppend(&buf, gpa, profileName(profile));
    try buf.appendSlice(gpa, "\",\"split_size\":");
    var num_buf: [32]u8 = undefined;
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{split_size}));
    try buf.appendSlice(gpa, ",\"bundles\":");
    try buf.appendSlice(gpa, if (include_bundles) "true" else "false");
    try buf.appendSlice(gpa, ",\"parts\":[");

    for (parts, 0..) |part, part_index| {
        if (part_index != 0) try buf.appendSlice(gpa, ",");
        try buf.appendSlice(gpa, "{\"order\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{part_index + 1}));
        try buf.appendSlice(gpa, ",\"profile\":\"");
        try jsonEscapeAppend(&buf, gpa, profileName(profile));
        try buf.appendSlice(gpa, "\",\"file\":\"");
        try jsonEscapeAppend(&buf, gpa, part.file_name);
        try buf.appendSlice(gpa, "\",\"bundle\":\"");
        try buf.appendSlice(gpa, bundleKindName(part.kind));
        try buf.appendSlice(gpa, "\",\"part\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{part.part}));
        try buf.appendSlice(gpa, ",\"parts\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{part.total_parts}));
        try buf.appendSlice(gpa, ",\"bytes\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{part.bytes}));
        try buf.appendSlice(gpa, ",\"sources\":[");
        for (part.files, 0..) |file, source_index| {
            if (source_index != 0) try buf.appendSlice(gpa, ",");
            try buf.appendSlice(gpa, "{\"order\":");
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{source_index + 1}));
            try buf.appendSlice(gpa, ",\"source_path\":\"");
            try jsonEscapeAppend(&buf, gpa, file.source_path);
            try buf.appendSlice(gpa, "\",\"bytes\":");
            try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{file.body.len}));
            try buf.append(gpa, '}');
        }
        try buf.appendSlice(gpa, "]}");
    }
    try buf.appendSlice(gpa, "]}\n");
    try writeBytes(io, out_dir, "part_manifest.json", buf.items);
}

/// Upload planner for `--bundles-only` packs. Lists generated upload files with
/// on-disk byte sizes, a recommended upload order, totals, and a documented
/// `chars/4` approximate token estimate. Does not alter other manifest schemas.
/// The planner file itself is omitted from the file list (it is not model corpus).
fn exportUploadManifest(
    io: Io,
    gpa: std.mem.Allocator,
    out_dir: Io.Dir,
    profile: Profile,
    split_size: usize,
    parts: []const BundlePart,
) !void {
    // Recommended upload order: index + guide first, then machine sidecars, then
    // combined parts in the same global order as part_manifest.json.
    const sidecar_names = [_][]const u8{
        "INDEX.md",
        "UPLOAD-GUIDE.md",
        "part_manifest.json",
        "catalog_meta.json",
        "profile_manifest.json",
        "catalog.jsonl",
    };

    var ordered: std.ArrayList([]const u8) = .empty;
    defer ordered.deinit(gpa);
    try ordered.ensureTotalCapacity(gpa, sidecar_names.len + parts.len);
    for (sidecar_names) |name| try ordered.append(gpa, name);
    for (parts) |part| try ordered.append(gpa, part.file_name);

    var total_bytes: usize = 0;
    var file_sizes: std.ArrayList(usize) = .empty;
    defer file_sizes.deinit(gpa);
    try file_sizes.ensureTotalCapacity(gpa, ordered.items.len);
    for (ordered.items) |name| {
        const size = try fileByteSize(io, out_dir, name);
        try file_sizes.append(gpa, size);
        total_bytes += size;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var num_buf: [32]u8 = undefined;

    try buf.appendSlice(gpa, "{\"profile\":\"");
    try jsonEscapeAppend(&buf, gpa, profileName(profile));
    try buf.appendSlice(gpa, "\",\"split_size\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{split_size}));
    try buf.appendSlice(gpa, ",\"token_estimate_method\":\"chars/4\",\"total_bytes\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{total_bytes}));
    try buf.appendSlice(gpa, ",\"approx_tokens\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{approxTokensFromBytes(total_bytes)}));
    try buf.appendSlice(gpa, ",\"files\":[");

    for (ordered.items, 0..) |name, index| {
        if (index != 0) try buf.appendSlice(gpa, ",");
        const size = file_sizes.items[index];
        try buf.appendSlice(gpa, "{\"order\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{index + 1}));
        try buf.appendSlice(gpa, ",\"file\":\"");
        try jsonEscapeAppend(&buf, gpa, name);
        try buf.appendSlice(gpa, "\",\"bytes\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{size}));
        try buf.appendSlice(gpa, ",\"approx_tokens\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{approxTokensFromBytes(size)}));
        try buf.append(gpa, '}');
    }
    try buf.appendSlice(gpa, "]}\n");
    try writeBytes(io, out_dir, "upload_manifest.json", buf.items);
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
    opts: Options,
    parts: []const BundlePart,
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

    if (opts.bundles_only) {
        try doc.appendSlice(gpa,
            \\## How to use
            \\
            \\This corpus was generated with `--bundles-only`: combined upload
            \\parts and catalog sidecars are present; the per-file `files/**` tree
            \\is intentionally omitted.
            \\
            \\1. Upload this entire directory (or zip it).
            \\2. Start from `INDEX.md` and `upload_manifest.json` as the upload map.
            \\3. Prefer `boris-source-N.md` for implementation questions.
            \\4. Prefer `boris-docs[-N].md` for contracts and docs.
            \\5. Cite `source_path` from document frontmatter when answering.
            \\
        );
    } else {
        try doc.appendSlice(gpa,
            \\## How to use
            \\
            \\1. Upload this entire directory (or zip it).
            \\2. Start from `INDEX.md` as the path map.
            \\3. Prefer `files/src/**` for implementation questions.
            \\4. Prefer `files/docs/contracts/**` for IR / machine contracts.
            \\5. Cite `source_path` from document frontmatter when answering.
            \\
        );
    }

    if (opts.includeBundles()) {
        if (opts.bundles_only) {
            try doc.appendSlice(gpa,
                \\## Combined upload bundles
                \\
                \\These root-level Markdown files are the primary upload surface for
                \\this `--bundles-only` pack. The catalog still inventories each
                \\source path; per-file `files/**` documents are not emitted:
                \\
                \\| File | Contents |
                \\|------|----------|
                \\| `part_manifest.json` | Ordered parts, source paths, and byte counts |
                \\
                \\The part manifest records the configured body-byte target. Parts
                \\contain contiguous whole documents in sorted source-path order. A
                \\single source file larger than the target remains whole in its own part.
                \\
            );
        } else {
            try doc.appendSlice(gpa,
                \\## Combined upload bundles
                \\
                \\These root-level Markdown files are additive convenience bundles; the
                \\per-file `files/**` documents and catalog remain unchanged:
                \\
                \\| File | Contents |
                \\|------|----------|
                \\| `part_manifest.json` | Ordered parts, source paths, and byte counts |
                \\
                \\The part manifest records the configured body-byte target. Parts
                \\contain contiguous whole documents in sorted source-path order. A
                \\single source file larger than the target remains whole in its own part.
                \\
            );
        }
        var part_num_buf: [96]u8 = undefined;
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&part_num_buf, "Target body bytes per part: `{d}`.\n\n", .{opts.split_size}));
        try doc.appendSlice(gpa, "| Order | File | Bundle | Documents | Body bytes |\n|------:|------|--------|----------:|-----------:|\n");
        for (parts, 0..) |part, part_index| {
            try doc.appendSlice(gpa, "| ");
            try doc.appendSlice(gpa, try std.fmt.bufPrint(&part_num_buf, "{d}", .{part_index + 1}));
            try doc.appendSlice(gpa, " | `");
            try doc.appendSlice(gpa, part.file_name);
            try doc.appendSlice(gpa, "` | ");
            try doc.appendSlice(gpa, bundleKindName(part.kind));
            try doc.appendSlice(gpa, " | ");
            try doc.appendSlice(gpa, try std.fmt.bufPrint(&part_num_buf, "{d}", .{part.files.len}));
            try doc.appendSlice(gpa, " | ");
            try doc.appendSlice(gpa, try std.fmt.bufPrint(&part_num_buf, "{d}", .{part.bytes}));
            try doc.appendSlice(gpa, " |\n");
        }
        try doc.appendSlice(gpa, "\nA single source file larger than the target remains whole in its own part.\n\n");
    } else try doc.appendSlice(gpa,
        \\## Combined upload bundles
        \\
        \\This corpus was generated with `--no-bundles`. It intentionally contains
        \\only the per-file `files/**` documents and catalog sidecars, avoiding the
        \\duplicate bytes of the optional combined Markdown bundles.
        \\
    );

    try doc.appendSlice(gpa,
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
        \\| `catalog_meta.json` | format + schema_version + tool_version + profile + split target + vcs_revision |
        \\| `catalog.jsonl` | one JSON object per document (sorted by rag_path) |
        \\| `profile_manifest.json` | selected profile and sorted source paths |
        \\| `part_manifest.json` | ordered parts, source paths, and byte counts |
        \\
    );
    if (opts.bundles_only) {
        try doc.appendSlice(gpa,
            \\| `upload_manifest.json` | recommended upload order, byte sizes, and chars/4 token estimates |
            \\
        );
    }
    try doc.appendSlice(gpa,
        \\These machine files are **not** catalog rows.
        \\
    );

    try writeBytes(io, out_dir, "INDEX.md", doc.items);
}

fn exportUploadGuide(io: Io, out_dir: Io.Dir, opts: Options) !void {
    const common_prefix =
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
    ;
    const full_subset =
        \\Minimum useful subset:
        \\
        \\1. `INDEX.md`
        \\2. `files/src/**`
        \\3. `files/docs/contracts/**` (if present)
        \\4. `files/AGENTS.md` / `files/README.md` (if present)
        \\
    ;
    const bundles_only_subset =
        \\This corpus was generated with `--bundles-only`. There is no `files/**`
        \\tree; upload the combined Markdown parts plus the index and catalog
        \\sidecars:
        \\
        \\1. `INDEX.md`
        \\2. `UPLOAD-GUIDE.md`
        \\3. `upload_manifest.json` (recommended order, sizes, chars/4 token estimate)
        \\4. `part_manifest.json` (authoritative part map and source paths)
        \\5. `boris-source-N.md`, `boris-docs[-N].md`, `boris-content[-N].md`
        \\6. `catalog.jsonl`, `catalog_meta.json`, `profile_manifest.json`
        \\
        \\Follow `upload_manifest.json` order when the host limits concurrent files.
        \\Token counts there use the documented `chars/4` heuristic (floor of
        \\UTF-8 bytes ÷ 4), not a model tokenizer.
        \\
    ;
    const bundles =
        \\## Combined bundles
        \\
        \\For a small number of uploads, use the root-level combined Markdown
        \\parts listed in `part_manifest.json`:
        \\
        \\- `boris-source-N.md` contains packed sources outside `docs/**` and
        \\  `content/**`, including root guidance and build files.
        \\- `boris-docs[-N].md` contains packed `docs/**` files.
        \\- `boris-content[-N].md` contains packed `content/**` files.
        \\
        \\Each entry is a whole Markdown document with `source_path` frontmatter and
        \\a fence chosen to remain safe for the original body. Parts are contiguous
        \\sorted source-path ranges and never split a source file. A single source
        \\file larger than the split target is emitted whole and may exceed it.
        \\
    ;
    const no_bundles =
        \\## Combined bundles
        \\
        \\This corpus was generated with `--no-bundles`, so it intentionally omits
        \\the combined Markdown bundles and their duplicate source bytes. Upload the
        \\per-file `files/**` documents with `INDEX.md` and the catalog sidecars.
        \\
    ;
    const full_prompt =
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
    ;
    const bundles_only_prompt =
        \\## Suggested system prompt
        \\
        \\```
        \\You are answering questions about this repository using the source RAG corpus.
        \\Prefer boris-source-N.md for implementation details.
        \\Prefer boris-docs parts for normative IR and machine contracts.
        \\Cite source_path from document frontmatter when you rely on a file.
        \\Do not invent APIs that are not present in the corpus.
        \\```
        \\
    ;
    const common_suffix =
        \\## Regenerating
        \\
        \\From the repo root (Zig 0.16+):
        \\
        \\```bash
        \\zig build source-rag
        \\# or
        \\zig-out/bin/boris-source-rag --out=./source-rag
        \\# bundles only (no files/** tree)
        \\zig build source-rag -- --bundles-only
        \\```
        \\
        \\## Integrity
        \\
        \\- Paths are repo-relative (no absolute host paths).
        \\- Catalog rows are sorted by `rag_path`.
        \\- No timestamps or random ids in corpus files.
        \\
    ;

    const body_text = if (opts.bundles_only)
        common_prefix ++ bundles_only_subset ++ bundles ++ bundles_only_prompt ++ common_suffix
    else if (opts.includeBundles())
        common_prefix ++ full_subset ++ bundles ++ full_prompt ++ common_suffix
    else
        common_prefix ++ full_subset ++ no_bundles ++ full_prompt ++ common_suffix;
    try writeBytes(io, out_dir, "UPLOAD-GUIDE.md", body_text);
}

fn sortCatalog(entries: []CatalogEntry) void {
    std.mem.sort(CatalogEntry, entries, {}, struct {
        fn less(_: void, a: CatalogEntry, b: CatalogEntry) bool {
            return std.mem.order(u8, a.rag_path, b.rag_path) == .lt;
        }
    }.less);
}

/// Export a source RAG corpus. The complete next corpus is generated under a
/// sibling staging directory and only then published into `out_dir`.
/// Method used for every approximate token figure in generated artifacts.
///
/// Recorded alongside the numbers so a reader can see they are a heuristic
/// rather than any particular tokenizer's count. Bytes remain authoritative.
const token_estimate_method = "bytes/4";

/// Write the root router for `--pack-by=tool`: a human-readable `INDEX.md` and a
/// machine-readable `pack_manifest.json` describing every emitted pack.
///
/// Deliberately names no consumer, product, or vendor: the packs are described
/// by what they contain and what they answer, so the same corpus serves a chat
/// upload, a local retrieval pipeline, or a person reading the files.
fn exportPackRouter(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir: Io.Dir,
    opts: Options,
    packs: []const PackSummary,
    totals: ExportStats,
) !void {
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    var num_buf: [32]u8 = undefined;

    try doc.appendSlice(gpa,
        \\---
        \\rag_id: meta/index
        \\rag_path: INDEX.md
        \\category: meta
        \\tags: [index, router, source-rag]
        \\---
        \\
        \\# Source RAG corpus — pack router
        \\
        \\This corpus is split into self-contained packs under `packs/`. Each pack
        \\carries its own `INDEX.md`, catalog, manifests, and bundles, so a pack can
        \\be used on its own without the rest of the tree.
        \\
        \\Start here, pick the pack whose questions match yours, and use that pack.
        \\
        \\## Packs
        \\
        \\| Pack | Bytes | ~Tokens | Files | Contents |
        \\|------|------:|--------:|------:|----------|
        \\
    );
    for (packs) |pack| {
        try doc.appendSlice(gpa, "| `packs/");
        try doc.appendSlice(gpa, pack.name);
        try doc.appendSlice(gpa, "/` | ");
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{pack.bytes}));
        try doc.appendSlice(gpa, " | ");
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{approxTokensFromBytes(pack.bytes)}));
        try doc.appendSlice(gpa, " | ");
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{pack.files}));
        try doc.appendSlice(gpa, " | ");
        try doc.appendSlice(gpa, try packPurpose(arena, pack.name));
        try doc.appendSlice(gpa, " |\n");
    }

    try doc.appendSlice(gpa,
        \\
        \\## Questions each pack answers
        \\
    );
    for (packs) |pack| {
        try doc.appendSlice(gpa, "\n- **`");
        try doc.appendSlice(gpa, pack.name);
        try doc.appendSlice(gpa, "`** — ");
        try doc.appendSlice(gpa, try packQuestions(arena, pack.name));
    }

    try doc.appendSlice(gpa,
        \\
        \\
        \\## Sizes
        \\
        \\`bytes` is the packed body size and is authoritative. `~tokens` is an
        \\approximation computed as `
    );
    try doc.appendSlice(gpa, token_estimate_method);
    try doc.appendSlice(gpa,
        \\` on that byte count; it is not a
        \\tokenizer result and will differ from any specific tokenizer. Use it for
        \\rough capacity planning only, and prefer `bytes` when the exact figure
        \\matters.
        \\
        \\Totals:
    );
    try doc.appendSlice(gpa, " ");
    try doc.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{packs.len}));
    try doc.appendSlice(gpa, " packs, ");
    try doc.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{totals.source_files}));
    try doc.appendSlice(gpa, " source files, ");
    try doc.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{totals.bytes}));
    try doc.appendSlice(gpa, " bytes.\n\nThe machine-readable form of this table is `pack_manifest.json`.\n");
    try writeBytes(io, out_dir, "INDEX.md", doc.items);

    // ---- pack_manifest.json ----
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"format\":\"boris-source-rag-packs\",\"schema_version\":1,\"profile\":\"");
    try buf.appendSlice(gpa, profileName(opts.profile));
    try buf.appendSlice(gpa, "\",\"pack_by\":\"");
    try buf.appendSlice(gpa, packByName(opts.pack_by));
    try buf.appendSlice(gpa, "\",\"packs_dir\":\"");
    try buf.appendSlice(gpa, packs_dir_name);
    try buf.appendSlice(gpa, "\",\"token_estimate_method\":\"");
    try buf.appendSlice(gpa, token_estimate_method);
    try buf.appendSlice(gpa, "\",\"total_bytes\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{totals.bytes}));
    try buf.appendSlice(gpa, ",\"total_source_files\":");
    try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{totals.source_files}));
    try buf.appendSlice(gpa, ",\"packs\":[");
    for (packs, 0..) |pack, index| {
        if (index != 0) try buf.appendSlice(gpa, ",");
        try buf.appendSlice(gpa, "{\"name\":\"");
        try jsonEscapeAppend(&buf, gpa, pack.name);
        try buf.appendSlice(gpa, "\",\"path\":\"");
        try jsonEscapeAppend(&buf, gpa, try std.fmt.allocPrint(arena, "{s}/{s}", .{ packs_dir_name, pack.name }));
        try buf.appendSlice(gpa, "\",\"source_files\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{pack.files}));
        try buf.appendSlice(gpa, ",\"bytes\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{pack.bytes}));
        try buf.appendSlice(gpa, ",\"tokens_approx\":");
        try buf.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{approxTokensFromBytes(pack.bytes)}));
        try buf.appendSlice(gpa, ",\"purpose\":\"");
        try jsonEscapeAppend(&buf, gpa, try packPurpose(arena, pack.name));
        try buf.appendSlice(gpa, "\",\"answers\":\"");
        try jsonEscapeAppend(&buf, gpa, try packQuestions(arena, pack.name));
        try buf.appendSlice(gpa, "\"}");
    }
    try buf.appendSlice(gpa, "]}\n");
    try writeBytes(io, out_dir, "pack_manifest.json", buf.items);
}

pub fn exportCorpus(io: Io, gpa: std.mem.Allocator, opts: Options) !ExportStats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths_info = try resolveOutputSkip(io, gpa, opts.root_dir, opts.out_dir);
    defer gpa.free(paths_info.root_abs);
    defer gpa.free(paths_info.out_abs);

    const cwd = Io.Dir.cwd();
    var root = try cwd.openDir(io, opts.root_dir, .{ .iterate = true });
    defer root.close(io);

    const paths = try collectSourcePaths(io, gpa, arena, root, paths_info.out_skip, opts.profile);
    defer gpa.free(paths);

    const stage_path = try std.fmt.allocPrint(gpa, "{s}.boris-source-rag-stage", .{opts.out_dir});
    defer gpa.free(stage_path);
    try removeTreeIfPresent(io, cwd, stage_path);
    try cwd.createDirPath(io, stage_path);
    errdefer removeTreeIfPresent(io, cwd, stage_path) catch {};

    var out = try cwd.openDir(io, stage_path, .{});
    defer out.close(io);

    var stats: ExportStats = .{};
    var stage_writes: usize = 0;

    log(opts, "\nSource RAG → {s}/  (root={s})\n", .{ opts.out_dir, opts.root_dir });

    switch (opts.pack_by) {
        .none => {
            stats = try exportPackTree(io, gpa, arena, root, out, paths, opts, &stage_writes);
        },
        .tool => {
            const packs = try partitionPacks(gpa, arena, paths);
            defer freePacks(gpa, packs);

            try out.createDirPath(io, packs_dir_name);
            var packs_dir = try out.openDir(io, packs_dir_name, .{});
            defer packs_dir.close(io);

            var summaries: std.ArrayList(PackSummary) = .empty;
            defer summaries.deinit(gpa);

            for (packs) |pack| {
                log(opts, "\n  pack       {s}/{s}  ({d} files)\n", .{ packs_dir_name, pack.name, pack.paths.items.len });
                try packs_dir.createDirPath(io, pack.name);
                var pack_out = try packs_dir.openDir(io, pack.name, .{});
                defer pack_out.close(io);

                const pack_stats = try exportPackTree(io, gpa, arena, root, pack_out, pack.paths.items, opts, &stage_writes);
                try summaries.append(gpa, .{
                    .name = pack.name,
                    .files = pack_stats.source_files,
                    .bytes = pack_stats.bytes,
                });
                stats.source_files += pack_stats.source_files;
                stats.skipped += pack_stats.skipped;
                stats.catalog_entries += pack_stats.catalog_entries;
                stats.bytes += pack_stats.bytes;
            }

            try exportPackRouter(io, gpa, arena, out, opts, summaries.items, stats);
        },
    }

    try publishManagedCorpus(io, gpa, stage_path, opts.out_dir);

    log(opts, "\nDone: {d} source files, {d} catalog entries, {d} skipped → {s}/\n", .{
        stats.source_files,
        stats.catalog_entries,
        stats.skipped,
        opts.out_dir,
    });

    return stats;
}

/// Emit one complete, self-contained corpus tree into `out`: the per-file
/// documents, combined bundles, catalog, and sidecar manifests.
///
/// Flat output calls this once with every scanned path and the stage root, which
/// is why `--pack-by=none` stays byte-identical to the historical export: same
/// inputs, same calls, same order. Pack output calls it once per pack with that
/// pack's paths and its own directory.
fn exportPackTree(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root: Io.Dir,
    out: Io.Dir,
    paths: []const []const u8,
    opts: Options,
    stage_writes: *usize,
) !ExportStats {
    if (opts.includePerFileDocs()) try out.createDirPath(io, "files");

    var catalog: std.ArrayList(CatalogEntry) = .empty;
    defer catalog.deinit(gpa);

    var packed_source: std.ArrayList(PackedSource) = .empty;
    defer {
        for (packed_source.items) |file| gpa.free(file.body);
        packed_source.deinit(gpa);
    }
    var packed_docs: std.ArrayList(PackedSource) = .empty;
    defer {
        for (packed_docs.items) |file| gpa.free(file.body);
        packed_docs.deinit(gpa);
    }
    var packed_content: std.ArrayList(PackedSource) = .empty;
    defer {
        for (packed_content.items) |file| gpa.free(file.body);
        packed_content.deinit(gpa);
    }

    var bundle_parts: std.ArrayList(BundlePart) = .empty;
    defer {
        for (bundle_parts.items) |part| gpa.free(part.file_name);
        bundle_parts.deinit(gpa);
    }

    var stats: ExportStats = .{};
    var packed_paths: std.ArrayList([]const u8) = .empty;
    defer packed_paths.deinit(gpa);

    for (paths) |source_path| {
        const data = readSourceAlloc(io, root, source_path, gpa, opts.max_bytes) catch |err| {
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

        if (opts.includePerFileDocs()) {
            const doc = try renderSourceDocument(gpa, rag_id, rag_path, source_path, lang, data);
            defer gpa.free(doc);
            try writeBytes(io, out, rag_path, doc);
            stage_writes.* += 1;
            if (opts.test_fail_after_stage_writes) |limit| {
                if (stage_writes.* >= limit) return error.TestInjectedStageWriteFailure;
            }
        } else {
            // Bundles-only still needs a deterministic progress point for tests.
            stage_writes.* += 1;
            if (opts.test_fail_after_stage_writes) |limit| {
                if (stage_writes.* >= limit) return error.TestInjectedStageWriteFailure;
            }
        }

        try catalog.append(gpa, .{
            .rag_id = rag_id,
            .rag_path = rag_path,
            .category = "source",
            .title = source_path,
            .source_path = source_path,
            .lang = lang,
            .bytes = data.len,
        });

        const packed_file = PackedSource{
            .rag_id = rag_id,
            .rag_path = rag_path,
            .source_path = source_path,
            .lang = lang,
            .body = try gpa.dupe(u8, data),
        };
        switch (bundleKindForPath(source_path)) {
            .source => try packed_source.append(gpa, packed_file),
            .docs => try packed_docs.append(gpa, packed_file),
            .content => try packed_content.append(gpa, packed_file),
        }
        try packed_paths.append(gpa, source_path);
        stats.source_files += 1;
        stats.bytes += data.len;
        log(opts, "  source     {s}\n", .{source_path});
    }

    if (opts.includeBundles()) {
        try exportBundles(io, gpa, out, opts.split_size, packed_source.items, packed_docs.items, packed_content.items, &bundle_parts);
    }

    // Meta documents (not source rows until we add them to catalog).
    try exportUploadGuide(io, out, opts);
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
    try exportIndex(io, gpa, out, catalog.items, stats, opts, bundle_parts.items);
    try exportCatalogJsonl(io, gpa, out, catalog.items);
    try exportCatalogMeta(io, out, opts.profile, opts.split_size, opts.vcs_revision);
    try exportProfileManifest(io, gpa, out, opts.profile, stats, packed_paths.items);
    try exportPartManifest(io, gpa, out, opts.profile, opts.split_size, opts.includeBundles(), bundle_parts.items);
    if (opts.bundles_only) {
        try exportUploadManifest(io, gpa, out, opts.profile, opts.split_size, bundle_parts.items);
    }

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
                    if (std.mem.startsWith(u8, a, "--out=") or std.mem.startsWith(u8, a, "--root=") or std.mem.startsWith(u8, a, "--max-bytes=") or std.mem.startsWith(u8, a, "--split-size=") or std.mem.startsWith(u8, a, "--profile=") or std.mem.startsWith(u8, a, "--pack-by=")) continue;
                    if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "--split-size") or std.mem.eql(u8, a, "--profile") or std.mem.eql(u8, a, "--pack-by")) {
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

    if (opts.version) {
        var stdout_buffer: [128]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(tool_id ++ "\n") catch {};
        stdout_writer.interface.flush() catch {};
        return ExitCode.success.int();
    }

    var opts_with_revision = opts;
    opts_with_revision.vcs_revision = vcs_revision;

    _ = exportCorpus(io, gpa, opts_with_revision) catch |err| {
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
    try std.testing.expect(!o.no_bundles);
    try std.testing.expect(!o.bundles_only);
    try std.testing.expect(o.includeBundles());
    try std.testing.expect(o.includePerFileDocs());
    try std.testing.expectEqual(Profile.all, o.profile);
    try std.testing.expectEqual(@as(usize, 512 * 1024), o.split_size);

    const h = try parseOptions(&.{ "boris-source-rag", "--help" });
    try std.testing.expect(h.help);

    const v = try parseOptions(&.{ "boris-source-rag", "-V" });
    try std.testing.expect(v.version);
    try std.testing.expectEqualStrings("boris-source-rag/0.8.1", tool_id);

    const o2 = try parseOptions(&.{ "boris-source-rag", "--out=./pack", "--root=../repo", "--max-bytes=1000", "--split-size=100", "--quiet", "--no-bundles", "--profile=docs" });
    try std.testing.expectEqualStrings("./pack", o2.out_dir);
    try std.testing.expectEqualStrings("../repo", o2.root_dir);
    try std.testing.expectEqual(@as(usize, 1000), o2.max_bytes);
    try std.testing.expectEqual(@as(usize, 100), o2.split_size);
    try std.testing.expect(o2.quiet);
    try std.testing.expect(o2.no_bundles);
    try std.testing.expect(!o2.includeBundles());
    try std.testing.expectEqual(Profile.docs, o2.profile);

    const o3 = try parseOptions(&.{ "boris-source-rag", "--profile", "tools" });
    try std.testing.expectEqual(Profile.tools, o3.profile);
    const o4 = try parseOptions(&.{ "boris-source-rag", "--split-size", "256" });
    try std.testing.expectEqual(@as(usize, 256), o4.split_size);

    const o5 = try parseOptions(&.{ "boris-source-rag", "--bundles-only", "--split-size=128" });
    try std.testing.expect(o5.bundles_only);
    try std.testing.expect(o5.includeBundles());
    try std.testing.expect(!o5.includePerFileDocs());
    try std.testing.expectEqual(@as(usize, 128), o5.split_size);
}

test "parseOptions: unknown flag" {
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "x", "--rag" }));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{ "x", "--profile=bogus" }));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{ "x", "--split-size=0" }));
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{ "x", "--no-bundles", "--bundles-only" }));
}

test "resolveOutputSkip canonicalizes nested paths and rejects collisions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const nested = try resolveOutputSkip(io, gpa, "./.zig-cache/tmp/boris-rag-root", ".zig-cache/tmp/boris-rag-root/./docs/../docs/generated");
    defer gpa.free(nested.root_abs);
    defer gpa.free(nested.out_abs);
    try std.testing.expectEqualStrings("docs/generated", nested.out_skip);

    try std.testing.expectError(
        error.SourceRagOutputCollision,
        resolveOutputSkip(io, gpa, ".zig-cache/tmp/boris-rag-root", "./.zig-cache/tmp/boris-rag-root"),
    );
    try std.testing.expectError(
        error.SourceRagOutputCollision,
        resolveOutputSkip(io, gpa, ".zig-cache/tmp/boris-rag-root", ".zig-cache/tmp"),
    );
}

test "exportCorpus nested output is excluded across repeated runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/nested-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, "{s}/docs/generated", .{root_rel});
    defer gpa.free(out_rel);
    const catalog_rel = try std.fmt.allocPrint(gpa, "{s}/catalog.jsonl", .{out_rel});
    defer gpa.free(catalog_rel);

    try Io.Dir.cwd().createDirPath(io, root_rel);
    var root = try Io.Dir.cwd().openDir(io, root_rel, .{});
    defer root.close(io);
    try root.createDirPath(io, "docs");
    try root.writeFile(io, .{ .sub_path = "README.md", .data = "# Nested output\n" });
    try root.writeFile(io, .{ .sub_path = "docs/guide.md", .data = "# Guide\n" });

    const first = try exportCorpus(io, gpa, .{ .root_dir = root_rel, .out_dir = out_rel, .quiet = true });
    const first_catalog = try readFileAlloc(io, Io.Dir.cwd(), catalog_rel, gpa);
    defer gpa.free(first_catalog);

    const second = try exportCorpus(io, gpa, .{ .root_dir = root_rel, .out_dir = out_rel, .quiet = true });
    const second_catalog = try readFileAlloc(io, Io.Dir.cwd(), catalog_rel, gpa);
    defer gpa.free(second_catalog);

    try std.testing.expectEqual(first.source_files, second.source_files);
    try std.testing.expectEqual(first.bytes, second.bytes);
    try std.testing.expectEqualStrings(first_catalog, second_catalog);
}

test "profiles keep their documented scopes" {
    try std.testing.expectEqualStrings("all", profileName(.all));
    try std.testing.expectEqualStrings("core", profileName(.core));
    try std.testing.expectEqualStrings("docs", profileName(.docs));
    try std.testing.expectEqualStrings("tools", profileName(.tools));
    try std.testing.expectEqualStrings("src", scanDirsForProfile(.core)[0]);
    try std.testing.expectEqualStrings("layouts", scanDirsForProfile(.core)[1]);
    try std.testing.expectEqualStrings("docs", scanDirsForProfile(.docs)[0]);
    try std.testing.expectEqualStrings("content", scanDirsForProfile(.docs)[1]);
    // Full contents, not a spot check: this list gates what reaches the corpus,
    // so a silent addition or reordering should fail loudly here.
    try std.testing.expectEqual(@as(usize, 5), scanDirsForProfile(.tools).len);
    try std.testing.expectEqualStrings("scripts", scanDirsForProfile(.tools)[0]);
    try std.testing.expectEqualStrings("tools", scanDirsForProfile(.tools)[1]);
    try std.testing.expectEqualStrings("test", scanDirsForProfile(.tools)[2]);
    try std.testing.expectEqualStrings("fixtures", scanDirsForProfile(.tools)[3]);
    try std.testing.expectEqualStrings("SUPPORT", scanDirsForProfile(.tools)[4]);
    try std.testing.expectEqual(@as(usize, default_scan_dirs.len), scanDirsForProfile(.all).len);
}

test "langFromPath and extensions" {
    try std.testing.expectEqualStrings("zig", langFromPath("src/main.zig"));
    try std.testing.expectEqualStrings("markdown", langFromPath("README.md"));
    try std.testing.expectEqualStrings("c", langFromPath("vendor/sample/engine.c"));
    try std.testing.expect(hasIncludedExtension("src/a.zig"));
    try std.testing.expect(hasIncludedExtension("LICENSE"));
    try std.testing.expect(!hasIncludedExtension("photo.png"));
    try std.testing.expect(isSkippedDirName("zig-out"));
    try std.testing.expect(isSkippedDirName("build")); // local object trees e.g. vendor/x/build
    try std.testing.expect(isSkippedDirName("CMakeFiles"));
    try std.testing.expect(!isSkippedDirName("source-rag")); // tool lives at tools/source-rag
    try std.testing.expect(isUnderOutDir("source-rag", "source-rag"));
    try std.testing.expect(isUnderOutDir("source-rag/INDEX.md", "source-rag"));
    try std.testing.expect(!isUnderOutDir("tools/source-rag/main.zig", "source-rag"));
    try std.testing.expect(isSkippedTopLevelTree("rag/INDEX.md"));
    try std.testing.expect(isSkippedTopLevelTree("vendor/sample/engine.c"));
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

test "bundle partition is ordered, whole-file, and oversized-safe" {
    const gpa = std.testing.allocator;
    const files = [_]PackedSource{
        .{ .rag_id = "a", .rag_path = "a", .source_path = "a", .lang = "text", .body = @constCast("10 bytes") },
        .{ .rag_id = "b", .rag_path = "b", .source_path = "b", .lang = "text", .body = @constCast("20 bytes here") },
        .{ .rag_id = "c", .rag_path = "c", .source_path = "c", .lang = "text", .body = @constCast("30 bytes here, yes") },
    };
    const parts = try partitionBundleFiles(gpa, .source, files[0..], 20);
    defer {
        for (parts) |part| gpa.free(part.file_name);
        gpa.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0].files[0].source_path);
    try std.testing.expectEqualStrings("b", parts[1].files[0].source_path);
    try std.testing.expectEqualStrings("c", parts[2].files[0].source_path);
    try std.testing.expectEqual(@as(usize, 8), parts[0].bytes);
    try std.testing.expectEqual(@as(usize, 13), parts[1].bytes);
    try std.testing.expectEqual(@as(usize, 18), parts[2].bytes);
    try std.testing.expectEqualStrings("boris-source-1.md", parts[0].file_name);

    const oversized = try partitionBundleFiles(gpa, .docs, files[2..3], 5);
    defer {
        for (oversized) |part| gpa.free(part.file_name);
        gpa.free(oversized);
    }
    try std.testing.expectEqual(@as(usize, 1), oversized.len);
    try std.testing.expectEqual(@as(usize, 18), oversized[0].bytes);
    try std.testing.expectEqualStrings("boris-docs.md", oversized[0].file_name);
    try std.testing.expectEqual(BundleKind.docs, bundleKindForPath("docs/contracts/ir-schema.md"));
    try std.testing.expectEqual(BundleKind.content, bundleKindForPath("content/index.md"));
    try std.testing.expectEqual(BundleKind.source, bundleKindForPath("src/pipeline.zig"));
    try std.testing.expectEqual(BundleKind.source, bundleKindForPath("README.md"));
    try std.testing.expect(isManagedBundleFileName("boris-source-12.md"));
    try std.testing.expect(!isManagedBundleFileName("boris-source-final.md"));
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

fn expectOutputFileEqual(
    io: Io,
    gpa: std.mem.Allocator,
    out: Io.Dir,
    path: []const u8,
    expected: []const u8,
) !void {
    const actual = try readFileAlloc(io, out, path, gpa);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
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
        const vendor_rel = try std.fmt.allocPrint(gpa, "{s}/vendor", .{root_rel});
        defer gpa.free(vendor_rel);
        try Io.Dir.cwd().createDirPath(io, vendor_rel);
        const tool_rel = try std.fmt.allocPrint(gpa, "{s}/tools/source-rag", .{root_rel});
        defer gpa.free(tool_rel);
        try Io.Dir.cwd().createDirPath(io, tool_rel);
    }
    {
        var root = try Io.Dir.cwd().openDir(io, root_rel, .{});
        defer root.close(io);
        try root.writeFile(io, .{ .sub_path = "README.md", .data = "# Demo\n" });
        try root.writeFile(io, .{ .sub_path = "src/hello.zig", .data = "pub fn main() void {}\n" });
        try root.writeFile(io, .{ .sub_path = "src/skip.json", .data = &[_]u8{ '{', 0, '}' } });
        try root.writeFile(io, .{ .sub_path = "src/skip.bin", .data = &[_]u8{ 0x00, 0x01, 0x02 } });
        try root.writeFile(io, .{ .sub_path = "vendor/third_party.c", .data = "int third_party;\n" });
        try root.writeFile(io, .{ .sub_path = "tools/source-rag/main.zig", .data = "pub fn export() void {}\n" });
    }

    const stats = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .max_bytes = 512 * 1024,
        .split_size = 20,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.source_files);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
    try std.testing.expect(stats.catalog_entries >= 3);

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);

    const meta = try readFileAlloc(io, out, "catalog_meta.json", gpa);
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, format_id) != null);

    const upload_guide = try readFileAlloc(io, out, "UPLOAD-GUIDE.md", gpa);
    defer gpa.free(upload_guide);

    const index = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "files/src/hello.zig.md") != null);

    const hello = try readFileAlloc(io, out, "files/src/hello.zig.md", gpa);
    defer gpa.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "pub fn main()") != null);

    const catalog = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "src/hello.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "tools/source-rag/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "vendor/third_party.c") == null);

    const profile_manifest = try readFileAlloc(io, out, "profile_manifest.json", gpa);
    defer gpa.free(profile_manifest);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "src/hello.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "src/skip.json") == null);

    const source_one = try readFileAlloc(io, out, "boris-source-1.md", gpa);
    defer gpa.free(source_one);
    const source_two = try readFileAlloc(io, out, "boris-source-2.md", gpa);
    defer gpa.free(source_two);
    const source_three = try readFileAlloc(io, out, "boris-source-3.md", gpa);
    defer gpa.free(source_three);
    try std.testing.expect(std.mem.indexOf(u8, source_one, "source_path: README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, source_two, "source_path: src/hello.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, source_three, "source_path: tools/source-rag/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, source_one, "vendor/third_party.c") == null);
    try std.testing.expect(std.mem.indexOf(u8, source_two, "vendor/third_party.c") == null);
    try std.testing.expect(std.mem.indexOf(u8, source_three, "vendor/third_party.c") == null);
    const part_manifest = try readFileAlloc(io, out, "part_manifest.json", gpa);
    defer gpa.free(part_manifest);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"profile\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"order\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"source_path\":\"README.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"source_path\":\"src/hello.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"source_path\":\"tools/source-rag/main.zig\"") != null);
    const docs_bundle = try readFileAlloc(io, out, "boris-docs.md", gpa);
    defer gpa.free(docs_bundle);
    try std.testing.expect(std.mem.indexOf(u8, docs_bundle, "No packed documents") != null);
    const content_bundle = try readFileAlloc(io, out, "boris-content.md", gpa);
    defer gpa.free(content_bundle);
    try std.testing.expect(std.mem.indexOf(u8, content_bundle, "No packed documents") != null);

    // A pre-vendor-exclusion pack may retain this document even though the
    // current catalog and bundles omit it. Regeneration must remove it.
    try out.createDirPath(io, "files/vendor");
    try out.writeFile(io, .{ .sub_path = "files/vendor/third_party.c.md", .data = "stale vendor document\n" });
    try out.writeFile(io, .{ .sub_path = "user-note.txt", .data = "preserve unrelated output\n" });

    // A write failure after staging has begun must leave the last successful
    // corpus (and caller-owned siblings) untouched.
    try std.testing.expectError(error.TestInjectedStageWriteFailure, exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .split_size = 20,
        .test_fail_after_stage_writes = 1,
    }));
    const preserved_hello = try readFileAlloc(io, out, "files/src/hello.zig.md", gpa);
    defer gpa.free(preserved_hello);
    try std.testing.expectEqualStrings(hello, preserved_hello);
    const preserved_catalog = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(preserved_catalog);
    try std.testing.expectEqualStrings(catalog, preserved_catalog);
    const preserved_user_note = try readFileAlloc(io, out, "user-note.txt", gpa);
    defer gpa.free(preserved_user_note);
    try std.testing.expectEqualStrings("preserve unrelated output\n", preserved_user_note);

    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .max_bytes = 512 * 1024,
        .split_size = 20,
    });

    try std.testing.expectError(error.FileNotFound, out.statFile(io, "files/vendor/third_party.c.md", .{}));
    const user_note = try readFileAlloc(io, out, "user-note.txt", gpa);
    defer gpa.free(user_note);
    try std.testing.expectEqualStrings("preserve unrelated output\n", user_note);

    // A fresh normal publication is byte-for-byte deterministic.
    const regenerated_hello = try readFileAlloc(io, out, "files/src/hello.zig.md", gpa);
    defer gpa.free(regenerated_hello);
    try std.testing.expectEqualStrings(hello, regenerated_hello);
    const regenerated_catalog = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(regenerated_catalog);
    try std.testing.expectEqualStrings(catalog, regenerated_catalog);
    const regenerated_parts = try readFileAlloc(io, out, "part_manifest.json", gpa);
    defer gpa.free(regenerated_parts);
    try std.testing.expectEqualStrings(part_manifest, regenerated_parts);
    try expectOutputFileEqual(io, gpa, out, "INDEX.md", index);
    try expectOutputFileEqual(io, gpa, out, "UPLOAD-GUIDE.md", upload_guide);
    try expectOutputFileEqual(io, gpa, out, "catalog_meta.json", meta);
    try expectOutputFileEqual(io, gpa, out, "profile_manifest.json", profile_manifest);
    try expectOutputFileEqual(io, gpa, out, "boris-source-1.md", source_one);
    try expectOutputFileEqual(io, gpa, out, "boris-source-2.md", source_two);
    try expectOutputFileEqual(io, gpa, out, "boris-source-3.md", source_three);
    try expectOutputFileEqual(io, gpa, out, "boris-docs.md", docs_bundle);
    try expectOutputFileEqual(io, gpa, out, "boris-content.md", content_bundle);

    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .no_bundles = true,
    });

    const no_bundle_names = try collectManagedBundleNames(io, gpa, out);
    defer freeManagedBundleNames(gpa, no_bundle_names);
    try std.testing.expectEqual(@as(usize, 0), no_bundle_names.len);
    const no_bundles_hello = try readFileAlloc(io, out, "files/src/hello.zig.md", gpa);
    defer gpa.free(no_bundles_hello);
    const no_bundles_catalog = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(no_bundles_catalog);
    const no_bundles_meta = try readFileAlloc(io, out, "catalog_meta.json", gpa);
    defer gpa.free(no_bundles_meta);
    const no_bundles_index = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(no_bundles_index);
    try std.testing.expect(std.mem.indexOf(u8, no_bundles_index, "--no-bundles") != null);
    const no_bundles_parts = try readFileAlloc(io, out, "part_manifest.json", gpa);
    defer gpa.free(no_bundles_parts);
    try std.testing.expect(std.mem.indexOf(u8, no_bundles_parts, "\"bundles\":false") != null);
    try std.testing.expect(std.mem.endsWith(u8, no_bundles_parts, "\"parts\":[]}\n"));
}

/// Shared mini project tree for export layout tests.
fn writeMiniSourceRagFixture(io: Io, gpa: std.mem.Allocator, root_rel: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, root_rel);
    {
        const src_rel = try std.fmt.allocPrint(gpa, "{s}/src", .{root_rel});
        defer gpa.free(src_rel);
        try Io.Dir.cwd().createDirPath(io, src_rel);
    }
    {
        const tool_rel = try std.fmt.allocPrint(gpa, "{s}/tools/source-rag", .{root_rel});
        defer gpa.free(tool_rel);
        try Io.Dir.cwd().createDirPath(io, tool_rel);
    }
    var root = try Io.Dir.cwd().openDir(io, root_rel, .{});
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "README.md", .data = "# Demo\n" });
    try root.writeFile(io, .{ .sub_path = "src/hello.zig", .data = "pub fn main() void {}\n" });
    try root.writeFile(io, .{ .sub_path = "tools/source-rag/main.zig", .data = "pub fn export() void {}\n" });
}

/// Fixture with every pack shape: core sources, docs, content, and two tools.
/// `extra_tool` adds a tool that no code path knows about, which is how the
/// dynamic-discovery guarantee is exercised.
fn writePackByToolFixture(
    io: Io,
    gpa: std.mem.Allocator,
    root_rel: []const u8,
    extra_tool: ?[]const u8,
) !void {
    const dirs = [_][]const u8{ "src", "docs", "content", "tools/alpha-tool", "tools/beta-tool" };
    for (dirs) |dir| {
        const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_rel, dir });
        defer gpa.free(rel);
        try Io.Dir.cwd().createDirPath(io, rel);
    }
    if (extra_tool) |name| {
        const rel = try std.fmt.allocPrint(gpa, "{s}/tools/{s}", .{ root_rel, name });
        defer gpa.free(rel);
        try Io.Dir.cwd().createDirPath(io, rel);
    }

    var root = try Io.Dir.cwd().openDir(io, root_rel, .{});
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "README.md", .data = "# Demo\n" });
    try root.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build() void {}\n" });
    try root.writeFile(io, .{ .sub_path = "src/hello.zig", .data = "pub fn main() void {}\n" });
    try root.writeFile(io, .{ .sub_path = "docs/contract.md", .data = "# Contract\n" });
    try root.writeFile(io, .{ .sub_path = "content/index.md", .data = "# Index\n" });
    try root.writeFile(io, .{ .sub_path = "tools/alpha-tool/main.zig", .data = "pub fn alpha() void {}\n" });
    try root.writeFile(io, .{ .sub_path = "tools/beta-tool/main.zig", .data = "pub fn beta() void {}\n" });
    if (extra_tool) |name| {
        const rel = try std.fmt.allocPrint(gpa, "tools/{s}/main.zig", .{name});
        defer gpa.free(rel);
        try root.writeFile(io, .{ .sub_path = rel, .data = "pub fn extra() void {}\n" });
    }
}

test "profile scopes partition the default scan exactly" {
    // The pack layout is derived from these scopes, so this asserts the property
    // the derivation depends on: every scanned directory belongs to exactly one
    // profile. A directory added to default_scan_dirs without a profile — or
    // listed in two — fails here rather than silently landing in core.
    const scoped = [_]Profile{ .core, .docs, .tools };
    for (default_scan_dirs) |dir| {
        var hits: usize = 0;
        for (scoped) |profile| {
            if (segmentInProfileScope(dir, profile)) hits += 1;
        }
        if (hits != 1) {
            std.debug.print("scan dir '{s}' belongs to {d} profile scopes, expected 1\n", .{ dir, hits });
            return error.ScanDirNotInExactlyOneProfile;
        }
    }

    // ...and no profile claims a directory outside the default scan.
    for (scoped) |profile| {
        for (scanDirsForProfile(profile)) |dir| {
            var found = false;
            for (default_scan_dirs) |candidate| {
                if (std.mem.eql(u8, dir, candidate)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "packNameForPath follows the declared profile scopes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every scanned directory maps to the pack implied by its profile scope,
    // checked against scanDirsForProfile rather than a restated list.
    for (default_scan_dirs) |dir| {
        if (std.mem.eql(u8, dir, "tools")) {
            // The `.tools` scope splits per tool, so a file inside a tool
            // directory gets that tool's pack.
            try std.testing.expectEqualStrings(
                "tools-probe-tool",
                try packNameForPath(arena, "tools/probe-tool/file.md"),
            );
            continue;
        }
        const probe = try std.fmt.allocPrint(arena, "{s}/probe.md", .{dir});
        const pack = try packNameForPath(arena, probe);
        if (segmentInProfileScope(dir, .docs)) {
            try std.testing.expectEqualStrings(docs_pack_name, pack);
        } else if (segmentInProfileScope(dir, .tools)) {
            try std.testing.expectEqualStrings(tooling_pack_name, pack);
        } else {
            try std.testing.expectEqualStrings(core_pack_name, pack);
        }
    }

    // Timothy's grouping, spelled out: content ships with docs, and scripts and
    // test are tooling rather than core.
    try std.testing.expectEqualStrings("docs", try packNameForPath(arena, "docs/contracts/ir-schema.md"));
    try std.testing.expectEqualStrings("docs", try packNameForPath(arena, "content/index.md"));
    try std.testing.expectEqualStrings("tooling", try packNameForPath(arena, "scripts/release-gate.sh"));
    try std.testing.expectEqualStrings("tooling", try packNameForPath(arena, "test/fixtures/valid-site/content/index.md"));
    try std.testing.expectEqualStrings("tooling", try packNameForPath(arena, "SUPPORT/notes.md"));
    try std.testing.expectEqualStrings("core", try packNameForPath(arena, "src/pipeline.zig"));
    try std.testing.expectEqualStrings("core", try packNameForPath(arena, "layouts/main.html"));
    try std.testing.expectEqualStrings("core", try packNameForPath(arena, "README.md"));

    // Per-tool packs, including one no code path knows about.
    try std.testing.expectEqualStrings("tools-migration-lab", try packNameForPath(arena, "tools/migration-lab/main.zig"));
    try std.testing.expectEqualStrings("tools-source-rag", try packNameForPath(arena, "tools/source-rag/main.zig"));
    try std.testing.expectEqualStrings("tools-brand-new", try packNameForPath(arena, "tools/brand-new/deep/nested.zig"));
    // A loose file directly under tools/ stays in the `.tools` remainder.
    try std.testing.expectEqualStrings("tooling", try packNameForPath(arena, "tools/README.md"));
}

test "partitionPacks is exhaustive and disjoint" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = [_][]const u8{
        "AGENTS.md",
        "content/index.md",
        "docs/contract.md",
        "src/a.zig",
        "src/b.zig",
        "tools/alpha/main.zig",
        "tools/beta/main.zig",
        "tools/beta/util.zig",
        "tools/README.md",
    };

    const packs = try partitionPacks(gpa, arena, &paths);
    defer freePacks(gpa, packs);

    // Every input path lands in exactly one pack: none dropped, none duplicated.
    var seen: usize = 0;
    for (packs) |pack| seen += pack.paths.items.len;
    try std.testing.expectEqual(paths.len, seen);
    for (paths) |path| {
        var hits: usize = 0;
        for (packs) |pack| {
            for (pack.paths.items) |candidate| {
                if (std.mem.eql(u8, candidate, path)) hits += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), hits);
    }

    // Names are sorted so the same repo state always yields the same tree.
    try std.testing.expectEqual(@as(usize, 5), packs.len);
    try std.testing.expectEqualStrings("core", packs[0].name);
    try std.testing.expectEqualStrings("docs", packs[1].name);
    try std.testing.expectEqualStrings("tooling", packs[2].name);
    try std.testing.expectEqualStrings("tools-alpha", packs[3].name);
    try std.testing.expectEqualStrings("tools-beta", packs[4].name);

    // core holds the root file plus both src files; content joins docs; the
    // loose tools/README.md is the `.tools` remainder.
    try std.testing.expectEqual(@as(usize, 3), packs[0].paths.items.len);
    try std.testing.expectEqual(@as(usize, 2), packs[1].paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), packs[2].paths.items.len);
}

test "packs reproduce the declared profile scopes exactly" {
    // The totality criterion: the packs are not a new segmentation, they are the
    // existing profile scopes with `.tools` split per tool. So each profile's
    // scan must equal the union of its packs -- exactly, both directions.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-scope-root", .{tmp.sub_path});
    defer gpa.free(root_rel);

    try writePackByToolFixture(io, gpa, root_rel, "extra-tool");
    // Segments that belong to the `.tools` scope but no individual tool.
    {
        const scripts_rel = try std.fmt.allocPrint(gpa, "{s}/scripts", .{root_rel});
        defer gpa.free(scripts_rel);
        try Io.Dir.cwd().createDirPath(io, scripts_rel);
        const test_rel = try std.fmt.allocPrint(gpa, "{s}/test/fixtures", .{root_rel});
        defer gpa.free(test_rel);
        try Io.Dir.cwd().createDirPath(io, test_rel);
        var root_dir = try Io.Dir.cwd().openDir(io, root_rel, .{});
        defer root_dir.close(io);
        try root_dir.writeFile(io, .{ .sub_path = "scripts/release-gate.sh", .data = "#!/bin/sh\n" });
        try root_dir.writeFile(io, .{ .sub_path = "test/fixtures/case.md", .data = "# Case\n" });
        try root_dir.writeFile(io, .{ .sub_path = "tools/README.md", .data = "# Tools\n" });
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = try Io.Dir.cwd().openDir(io, root_rel, .{ .iterate = true });
    defer root.close(io);

    const cases = [_]struct { profile: Profile, packs: []const []const u8 }{
        .{ .profile = .core, .packs = &.{core_pack_name} },
        .{ .profile = .docs, .packs = &.{docs_pack_name} },
        .{ .profile = .tools, .packs = &.{ tooling_pack_name, "tools-alpha-tool", "tools-beta-tool", "tools-extra-tool" } },
    };

    for (cases) |case| {
        const scanned = try collectSourcePaths(io, gpa, arena, root, "out", case.profile);
        defer gpa.free(scanned);
        try std.testing.expect(scanned.len > 0);

        // Every path the profile scans lands in one of that profile's packs.
        for (scanned) |path| {
            const pack = try packNameForPath(arena, path);
            var matched = false;
            for (case.packs) |expected| {
                if (std.mem.eql(u8, pack, expected)) matched = true;
            }
            if (!matched) {
                std.debug.print(
                    "profile {s}: path '{s}' landed in pack '{s}', outside that profile's packs\n",
                    .{ profileName(case.profile), path, pack },
                );
                return error.PackOutsideProfileScope;
            }
        }

        // ...and nothing else does, so the union is exact rather than merely
        // covering. Checked against the full scan.
        const all = try collectSourcePaths(io, gpa, arena, root, "out", .all);
        defer gpa.free(all);
        var in_packs: usize = 0;
        for (all) |path| {
            const pack = try packNameForPath(arena, path);
            for (case.packs) |expected| {
                if (std.mem.eql(u8, pack, expected)) in_packs += 1;
            }
        }
        try std.testing.expectEqual(scanned.len, in_packs);
    }
}

test "parseOptions: pack-by" {
    const d = try parseOptions(&.{"boris-source-rag"});
    try std.testing.expectEqual(PackBy.none, d.pack_by);

    const a = try parseOptions(&.{ "boris-source-rag", "--pack-by=tool" });
    try std.testing.expectEqual(PackBy.tool, a.pack_by);

    const b = try parseOptions(&.{ "boris-source-rag", "--pack-by", "none" });
    try std.testing.expectEqual(PackBy.none, b.pack_by);

    try std.testing.expectError(error.InvalidValue, parseOptions(&.{ "x", "--pack-by=bogus" }));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{ "x", "--pack-by=" }));
    try std.testing.expectEqualStrings("tool", packByName(.tool));
    try std.testing.expectEqualStrings("none", packByName(.none));
}

test "pack-by=tool discovers a tool pack with no code change" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-discover-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-discover-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    // `never-seen-tool` appears nowhere in this source file.
    try writePackByToolFixture(io, gpa, root_rel, "never-seen-tool");
    const stats = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .pack_by = .tool,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);

    try std.testing.expect(pathExists(io, out, "packs/tools-never-seen-tool/INDEX.md"));
    try std.testing.expect(pathExists(io, out, "packs/tools-never-seen-tool/files/tools/never-seen-tool/main.zig.md"));
    try std.testing.expect(pathExists(io, out, "packs/tools-alpha-tool/INDEX.md"));
    try std.testing.expect(pathExists(io, out, "packs/tools-beta-tool/INDEX.md"));
    try std.testing.expect(pathExists(io, out, "packs/core/files/src/hello.zig.md"));
    try std.testing.expect(pathExists(io, out, "packs/docs/files/docs/contract.md"));
    // content ships inside the docs pack, matching the `.docs` profile scope.
    try std.testing.expect(pathExists(io, out, "packs/docs/files/content/index.md"));

    // The router names the discovered pack.
    const router = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(router);
    try std.testing.expect(std.mem.indexOf(u8, router, "packs/tools-never-seen-tool/") != null);

    const manifest = try readFileAlloc(io, out, "pack_manifest.json", gpa);
    defer gpa.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\":\"tools-never-seen-tool\"") != null);

    // 8 fixture files: README, build.zig, src, docs, content, three tool mains.
    try std.testing.expectEqual(@as(usize, 8), stats.source_files);
}

test "pack-by=none emits the historical flat tree and no pack artifacts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-flat-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-flat-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try writePackByToolFixture(io, gpa, root_rel, null);
    const flat = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);
    try std.testing.expect(pathExists(io, out, "files/src/hello.zig.md"));
    try std.testing.expect(pathExists(io, out, "INDEX.md"));
    try std.testing.expect(pathExists(io, out, "catalog.jsonl"));
    // Default output gains nothing from this feature.
    try std.testing.expect(!pathExists(io, out, "packs"));
    try std.testing.expect(!pathExists(io, out, "pack_manifest.json"));

    // The same scan split into packs covers exactly the same files.
    const out2_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-flat-out2", .{tmp.sub_path});
    defer gpa.free(out2_rel);
    const packed_stats = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out2_rel,
        .quiet = true,
        .pack_by = .tool,
    });
    try std.testing.expectEqual(flat.source_files, packed_stats.source_files);
    try std.testing.expectEqual(flat.bytes, packed_stats.bytes);
}

test "each pack carries its own manifests and composes with split-size and bundles-only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-manifest-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-manifest-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try writePackByToolFixture(io, gpa, root_rel, null);
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .pack_by = .tool,
        .bundles_only = true,
        .split_size = 8,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);

    const pack_names = [_][]const u8{ "core", "docs", "tools-alpha-tool", "tools-beta-tool" };
    for (pack_names) |name| {
        const sidecars = [_][]const u8{ "INDEX.md", "UPLOAD-GUIDE.md", "catalog.jsonl", "catalog_meta.json", "profile_manifest.json", "part_manifest.json", "upload_manifest.json" };
        for (sidecars) |sidecar| {
            const rel = try std.fmt.allocPrint(gpa, "packs/{s}/{s}", .{ name, sidecar });
            defer gpa.free(rel);
            try std.testing.expect(pathExists(io, out, rel));
        }
        // bundles-only composes per pack: no files/ tree inside any pack.
        const files_rel = try std.fmt.allocPrint(gpa, "packs/{s}/files", .{name});
        defer gpa.free(files_rel);
        try std.testing.expect(!pathExists(io, out, files_rel));
    }

    // split-size composes per pack: core holds two sources over an 8-byte
    // target, so its bundle is split rather than emitted whole.
    try std.testing.expect(pathExists(io, out, "packs/core/boris-source-2.md"));
}

test "generated router artifacts name no vendor or product" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-neutral-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-neutral-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try writePackByToolFixture(io, gpa, root_rel, null);
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .pack_by = .tool,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);

    // Scoped to tool-authored prose. Packed source legitimately names the
    // systems it migrates from, so the whole corpus cannot be asserted on.
    const authored = [_][]const u8{ "INDEX.md", "pack_manifest.json", "packs/core/UPLOAD-GUIDE.md", "packs/core/INDEX.md" };
    const vendors = [_][]const u8{ "ChatGPT", "OpenAI", "GPT-4", "Claude", "Anthropic", "Gemini", "Copilot", "Notebook LM", "NotebookLM" };
    for (authored) |rel| {
        const body = try readFileAlloc(io, out, rel, gpa);
        defer gpa.free(body);
        for (vendors) |vendor| {
            if (std.mem.indexOf(u8, body, vendor) != null) {
                std.debug.print("vendor string '{s}' leaked into generated {s}\n", .{ vendor, rel });
                return error.VendorNameInGeneratedArtifact;
            }
        }
    }

    // Any token figure is labelled as an approximation with its method recorded.
    const manifest = try readFileAlloc(io, out, "pack_manifest.json", gpa);
    defer gpa.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"tokens_approx\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"token_estimate_method\":\"bytes/4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"bytes\":") != null);
}

test "a pack that disappears is not stranded in the published output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-stale-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pack-stale-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try writePackByToolFixture(io, gpa, root_rel, "temporary-tool");
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .pack_by = .tool,
    });
    {
        var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
        defer out.close(io);
        try std.testing.expect(pathExists(io, out, "packs/tools-temporary-tool/INDEX.md"));
    }

    // Drop the tool from the repo and re-export into the same output root.
    const tool_rel = try std.fmt.allocPrint(gpa, "{s}/tools/temporary-tool", .{root_rel});
    defer gpa.free(tool_rel);
    try Io.Dir.cwd().deleteTree(io, tool_rel);

    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .pack_by = .tool,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);
    try std.testing.expect(!pathExists(io, out, "packs/tools-temporary-tool"));
    try std.testing.expect(pathExists(io, out, "packs/tools-alpha-tool/INDEX.md"));
}

test "approxTokensFromBytes uses floor chars/4" {
    try std.testing.expectEqual(@as(usize, 0), approxTokensFromBytes(0));
    try std.testing.expectEqual(@as(usize, 0), approxTokensFromBytes(3));
    try std.testing.expectEqual(@as(usize, 1), approxTokensFromBytes(4));
    try std.testing.expectEqual(@as(usize, 2), approxTokensFromBytes(9));
    try std.testing.expectEqual(@as(usize, 100), approxTokensFromBytes(400));
}

test "readSourceAlloc bounds oversized source allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/oversized-source.txt", .{tmp.sub_path});
    defer gpa.free(path);
    const data = try gpa.alloc(u8, 4097);
    defer gpa.free(data);
    @memset(data, 'x');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });

    const got = try readSourceAlloc(io, Io.Dir.cwd(), path, gpa, 4096);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 4097), got.len);
}

test "exportCorpus default mode still emits files/" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/bundles-only-default-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/bundles-only-default-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try writeMiniSourceRagFixture(io, gpa, root_rel);
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .split_size = 20,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);
    try std.testing.expect(pathExists(io, out, "files/src/hello.zig.md"));
    try std.testing.expect(pathExists(io, out, "files/README.md"));
    try std.testing.expect(pathExists(io, out, "boris-source-1.md"));
    try std.testing.expect(pathExists(io, out, "INDEX.md"));
    try std.testing.expect(pathExists(io, out, "part_manifest.json"));
    // Default exports must not emit the bundles-only upload planner.
    try std.testing.expect(!pathExists(io, out, "upload_manifest.json"));
}

test "exportCorpus bundles-only omits files/, removes stale files/, is deterministic, and keeps manifests consistent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/bundles-only-root", .{tmp.sub_path});
    defer gpa.free(root_rel);
    const out_rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/bundles-only-out", .{tmp.sub_path});
    defer gpa.free(out_rel);

    try writeMiniSourceRagFixture(io, gpa, root_rel);

    // Seed a full default export so files/ exists and must be scrubbed later.
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .split_size = 20,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{ .iterate = true });
    defer out.close(io);
    try std.testing.expect(pathExists(io, out, "files/src/hello.zig.md"));
    try out.writeFile(io, .{ .sub_path = "user-note.txt", .data = "preserve unrelated output\n" });

    const first = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .split_size = 20,
        .bundles_only = true,
    });
    try std.testing.expectEqual(@as(usize, 3), first.source_files);

    // Per-file tree omitted; prior files/ removed by successful staged publish.
    try std.testing.expect(!pathExists(io, out, "files"));
    try std.testing.expect(!pathExists(io, out, "files/src/hello.zig.md"));

    // Bundles and sidecars present.
    try std.testing.expect(pathExists(io, out, "INDEX.md"));
    try std.testing.expect(pathExists(io, out, "UPLOAD-GUIDE.md"));
    try std.testing.expect(pathExists(io, out, "catalog.jsonl"));
    try std.testing.expect(pathExists(io, out, "catalog_meta.json"));
    try std.testing.expect(pathExists(io, out, "profile_manifest.json"));
    try std.testing.expect(pathExists(io, out, "part_manifest.json"));
    try std.testing.expect(pathExists(io, out, "upload_manifest.json"));
    try std.testing.expect(pathExists(io, out, "boris-source-1.md"));
    try std.testing.expect(pathExists(io, out, "boris-docs.md"));
    try std.testing.expect(pathExists(io, out, "boris-content.md"));

    const index = try readFileAlloc(io, out, "INDEX.md", gpa);
    defer gpa.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "--bundles-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "files/**` tree") != null or std.mem.indexOf(u8, index, "files/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "upload_manifest.json") != null);

    const guide = try readFileAlloc(io, out, "UPLOAD-GUIDE.md", gpa);
    defer gpa.free(guide);
    try std.testing.expect(std.mem.indexOf(u8, guide, "--bundles-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide, "upload_manifest.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide, "chars/4") != null);

    const catalog = try readFileAlloc(io, out, "catalog.jsonl", gpa);
    defer gpa.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "src/hello.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"rag_path\":\"files/src/hello.zig.md\"") != null);

    const profile_manifest = try readFileAlloc(io, out, "profile_manifest.json", gpa);
    defer gpa.free(profile_manifest);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "\"profile\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "\"source_files\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "src/hello.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "tools/source-rag/main.zig") != null);

    const part_manifest = try readFileAlloc(io, out, "part_manifest.json", gpa);
    defer gpa.free(part_manifest);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"bundles\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"source_path\":\"README.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"source_path\":\"src/hello.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"source_path\":\"tools/source-rag/main.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "\"file\":\"boris-source-1.md\"") != null);

    const upload_manifest = try readFileAlloc(io, out, "upload_manifest.json", gpa);
    defer gpa.free(upload_manifest);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"profile\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"split_size\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"token_estimate_method\":\"chars/4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"total_bytes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"approx_tokens\":") != null);
    // Recommended order: index/guide first, then sidecars, then parts.
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"order\":1,\"file\":\"INDEX.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"order\":2,\"file\":\"UPLOAD-GUIDE.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"order\":3,\"file\":\"part_manifest.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"file\":\"boris-source-1.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"file\":\"boris-docs.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "\"file\":\"boris-content.md\"") != null);
    // Planner is not listed inside itself; existing manifests stay unchanged.
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, "upload_manifest.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, part_manifest, "upload_manifest") == null);
    try std.testing.expect(std.mem.indexOf(u8, profile_manifest, "upload_manifest") == null);

    // Per-file sizes and totals match on-disk bytes and chars/4.
    var expected_total: usize = 0;
    const upload_files = [_][]const u8{
        "INDEX.md",
        "UPLOAD-GUIDE.md",
        "part_manifest.json",
        "catalog_meta.json",
        "profile_manifest.json",
        "catalog.jsonl",
        "boris-source-1.md",
        "boris-source-2.md",
        "boris-source-3.md",
        "boris-docs.md",
        "boris-content.md",
    };
    for (upload_files) |name| {
        const size = try fileByteSize(io, out, name);
        expected_total += size;
        var size_needle: [96]u8 = undefined;
        const size_frag = try std.fmt.bufPrint(&size_needle, "\"file\":\"{s}\",\"bytes\":{d},\"approx_tokens\":{d}", .{
            name,
            size,
            approxTokensFromBytes(size),
        });
        try std.testing.expect(std.mem.indexOf(u8, upload_manifest, size_frag) != null);
    }
    var total_needle: [96]u8 = undefined;
    const total_frag = try std.fmt.bufPrint(&total_needle, "\"total_bytes\":{d},\"approx_tokens\":{d}", .{
        expected_total,
        approxTokensFromBytes(expected_total),
    });
    try std.testing.expect(std.mem.indexOf(u8, upload_manifest, total_frag) != null);

    // Internal consistency: every packed path appears in both manifests and catalog.
    const expected_paths = [_][]const u8{ "README.md", "src/hello.zig", "tools/source-rag/main.zig" };
    for (expected_paths) |path| {
        try std.testing.expect(std.mem.indexOf(u8, profile_manifest, path) != null);
        try std.testing.expect(std.mem.indexOf(u8, part_manifest, path) != null);
        try std.testing.expect(std.mem.indexOf(u8, catalog, path) != null);
    }

    const source_one = try readFileAlloc(io, out, "boris-source-1.md", gpa);
    defer gpa.free(source_one);
    const source_two = try readFileAlloc(io, out, "boris-source-2.md", gpa);
    defer gpa.free(source_two);
    const source_three = try readFileAlloc(io, out, "boris-source-3.md", gpa);
    defer gpa.free(source_three);
    const docs_bundle = try readFileAlloc(io, out, "boris-docs.md", gpa);
    defer gpa.free(docs_bundle);
    const content_bundle = try readFileAlloc(io, out, "boris-content.md", gpa);
    defer gpa.free(content_bundle);
    const meta = try readFileAlloc(io, out, "catalog_meta.json", gpa);
    defer gpa.free(meta);

    // Unrelated siblings survive staged publish.
    const user_note = try readFileAlloc(io, out, "user-note.txt", gpa);
    defer gpa.free(user_note);
    try std.testing.expectEqualStrings("preserve unrelated output\n", user_note);

    // Second bundles-only run is byte-identical for managed artifacts.
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .split_size = 20,
        .bundles_only = true,
    });
    try std.testing.expect(!pathExists(io, out, "files"));
    try expectOutputFileEqual(io, gpa, out, "INDEX.md", index);
    try expectOutputFileEqual(io, gpa, out, "UPLOAD-GUIDE.md", guide);
    try expectOutputFileEqual(io, gpa, out, "catalog.jsonl", catalog);
    try expectOutputFileEqual(io, gpa, out, "catalog_meta.json", meta);
    try expectOutputFileEqual(io, gpa, out, "profile_manifest.json", profile_manifest);
    try expectOutputFileEqual(io, gpa, out, "part_manifest.json", part_manifest);
    try expectOutputFileEqual(io, gpa, out, "upload_manifest.json", upload_manifest);
    try expectOutputFileEqual(io, gpa, out, "boris-source-1.md", source_one);
    try expectOutputFileEqual(io, gpa, out, "boris-source-2.md", source_two);
    try expectOutputFileEqual(io, gpa, out, "boris-source-3.md", source_three);
    try expectOutputFileEqual(io, gpa, out, "boris-docs.md", docs_bundle);
    try expectOutputFileEqual(io, gpa, out, "boris-content.md", content_bundle);

    // Returning to default export removes the bundles-only planner and restores files/.
    _ = try exportCorpus(io, gpa, .{
        .root_dir = root_rel,
        .out_dir = out_rel,
        .quiet = true,
        .split_size = 20,
    });
    try std.testing.expect(pathExists(io, out, "files/src/hello.zig.md"));
    try std.testing.expect(!pathExists(io, out, "upload_manifest.json"));
    const user_note_after = try readFileAlloc(io, out, "user-note.txt", gpa);
    defer gpa.free(user_note_after);
    try std.testing.expectEqualStrings("preserve unrelated output\n", user_note_after);
}
