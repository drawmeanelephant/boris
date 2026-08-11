//! Deterministic benchmark corpus generator (PERF-028).
//!
//! Generates a valid Boris HTML input tree with an exact caller-selected page
//! count below the caller-owned output directory (default `.generated`). The
//! tree deliberately exercises the costs the 2026-08-11 optimization audit
//! found on the HTML path:
//!
//! - a nav-consuming layout (`{{nav}}` renders the full site forest on every
//!   page, so per-page output is proportional to site size);
//! - Trunk/Satellite parent relations, nested includes, and wiki-links;
//! - several headings per page so heading harvest does real work.
//!
//! Determinism contract: the same `--pages` value always produces byte-identical
//! trees (no randomness, timestamps, hostnames, or map-order dependence). The
//! generator is NOT an authority for production content; it owns only its output
//! directory and removes it on success or failure.
//!
//! The benchmark runner (`zig build benchmark` → `scripts/benchmark.sh`)
//! invokes this tool for the pinned corpus, then times a ReleaseFast Boris
//! build over it with `--timings`.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const default_out = ".generated";
const default_page_count: usize = 1000;
const satellites_per_trunk: usize = 4;

const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    failed = 3,
};

const Options = struct {
    page_count: usize = default_page_count,
    out_dir: []const u8 = default_out,
    help: bool = false,
};

const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidPageCount,
    InvalidOutDir,
};

fn parseOptions(args: []const []const u8) ParseError!Options {
    var options: Options = .{};
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.startsWith(u8, arg, "--pages=")) {
            options.page_count = try parsePageCount(arg["--pages=".len..]);
        } else if (std.mem.eql(u8, arg, "--pages")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.page_count = try parsePageCount(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            const value = arg["--out=".len..];
            if (value.len == 0) return error.MissingValue;
            options.out_dir = value;
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.out_dir = args[index];
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn parsePageCount(value: []const u8) ParseError!usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPageCount;
    if (count == 0) return error.InvalidPageCount;
    return count;
}

/// The tool owns and deletes its `--out` directory, so the path must stay
/// inside the current working tree: reject absolute paths, any `..` segment
/// (or bare `.`/`..`), and existing symlink components before anything is
/// removed.
fn validateOutDir(io: Io, cwd: Io.Dir, out_dir: []const u8) ParseError!void {
    if (out_dir.len == 0) return error.InvalidOutDir;
    if (out_dir[0] == '/') return error.InvalidOutDir;
    if (std.mem.indexOfScalar(u8, out_dir, '\\') != null) return error.InvalidOutDir;
    var segments = std.mem.splitScalar(u8, out_dir, '/');
    while (segments.next()) |seg| {
        if (seg.len == 0) return error.InvalidOutDir; // empty or trailing slash
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidOutDir;
    }

    // `deleteTree` follows an intermediate symlink when given a path such as
    // `work/corpus`. Check every existing progressive path component without
    // following symlinks, so cleanup cannot be redirected outside the tree.
    var start: usize = 0;
    while (start < out_dir.len) {
        const slash = std.mem.indexOfScalarPos(u8, out_dir, start, '/') orelse out_dir.len;
        const progressive = out_dir[0..slash];
        const maybe_stat = cwd.statFile(io, progressive, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.InvalidOutDir,
        };
        if (maybe_stat) |stat| {
            if (stat.kind == .sym_link) return error.InvalidOutDir;
        }
        if (slash >= out_dir.len) break;
        start = slash + 1;
    }
}

fn printUsage() void {
    std.debug.print(
        \\boris-testdata-generator — deterministic benchmark corpus generator
        \\
        \\Usage:
        \\  zig run tools/testdata-generator/main.zig -- [options]
        \\
        \\Options:
        \\  --pages N       Exact generated page count (default: 1000; e.g. 5000)
        \\  --out DIR       Output root owned by this tool (default: .generated)
        \\  -h, --help       Show this help and exit
        \\
        \\The harness owns and removes only its --out directory, so --out must be
        \\a relative path with no . or .. segments, no trailing slash, and no
        \\existing symlink components.
        \\
    , .{});
}

fn writeFile(io: Io, full: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = data });
}

const layout_html =
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{{title}} · Corpus</title></head>
    \\<body>
    \\{{nav}}
    \\{{breadcrumb}}
    \\<main>{{content}}</main>
    \\</body>
    \\</html>
    \\
;

const common_include =
    \\Generated shared fragment.
    \\{{include includes/shared.md}}
    \\
;

const shared_include =
    \\Shared link: [[index]].
    \\
;

fn writeIndex(io: Io, root: []const u8) !void {
    const pa = std.heap.page_allocator;
    const path = try std.fmt.allocPrint(pa, "{s}/content/index.md", .{root});
    defer pa.free(path);
    try writeFile(io, path,
        \\---
        \\id: index
        \\title: Corpus Home
        \\status: published
        \\---
        \\# Corpus Home
        \\
        \\{{include includes/common.md}}
        \\
        \\## Overview
        \\
        \\This deterministic corpus exercises full per-page site navigation,
        \\nested includes, wiki-links, and heading harvest on the HTML path.
        \\
        \\Start with [[sections/section-0000]].
        \\
    );
}

fn writeTrunk(io: Io, root: []const u8, section: usize) !void {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/content/sections/section-{d:0>4}.md",
        .{ root, section },
    );
    var body_buffer: [640]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        \\---
        \\id: sections/section-{d:0>4}
        \\title: Section {d}
        \\status: published
        \\---
        \\# Section {d}
        \\
        \\{{{{include includes/common.md}}}}
        \\
        \\## Overview
        \\
        \\Section {d} is a trunk with full site navigation. It links home and
        \\its own satellites.
        \\
        \\## Details
        \\
        \\- bullet one
        \\- bullet two
        \\- bullet three
        \\
        \\Return to [[index]].
        \\
    , .{ section, section, section, section });
    try writeFile(io, path, body);
}

fn writeSatellite(io: Io, root: []const u8, page: usize, section: usize) !void {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/content/articles/article-{d:0>6}.md",
        .{ root, page },
    );
    var body_buffer: [768]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        \\---
        \\id: articles/article-{d:0>6}
        \\title: Article {d}
        \\parent: sections/section-{d:0>4}
        \\status: published
        \\---
        \\# Article {d}
        \\
        \\{{{{include includes/common.md}}}}
        \\
        \\## Overview
        \\
        \\Article {d} is a Satellite of [[sections/section-{d:0>4}]] and part of
        \\the deterministic benchmark corpus.
        \\
        \\## Details
        \\
        \\- bullet one
        \\- bullet two
        \\- bullet three
        \\
        \\Return to [[index]].
        \\
    , .{ page, page, section, page, page, section });
    try writeFile(io, path, body);
}

fn deleteSiteIfSafe(io: Io, cwd: Io.Dir, root: []const u8) void {
    // If a path component changes to a symlink while generation is running,
    // leave the partial tree in place rather than risking an external delete.
    validateOutDir(io, cwd, root) catch return;
    cwd.deleteTree(io, root) catch {};
}

/// Generate exactly `page_count` pages below `root`. Returns the number of
/// content pages written (always equals `page_count`).
fn generateSite(io: Io, root: []const u8, page_count: usize) !usize {
    const cwd = Io.Dir.cwd();
    try validateOutDir(io, cwd, root);
    // A failed pre-cleanup must be visible to the caller. The path has already
    // been constrained against traversal and symlink components, and hiding
    // this error could leave a partial tree while reporting only a later, less
    // useful create/write failure.
    try cwd.deleteTree(io, root);
    errdefer deleteSiteIfSafe(io, cwd, root);

    const pa = std.heap.page_allocator;
    const includes_dir = try std.fmt.allocPrint(pa, "{s}/content/includes", .{root});
    defer pa.free(includes_dir);
    const sections_dir = try std.fmt.allocPrint(pa, "{s}/content/sections", .{root});
    defer pa.free(sections_dir);
    const articles_dir = try std.fmt.allocPrint(pa, "{s}/content/articles", .{root});
    defer pa.free(articles_dir);
    const layouts_dir = try std.fmt.allocPrint(pa, "{s}/layouts", .{root});
    defer pa.free(layouts_dir);

    try cwd.createDirPath(io, includes_dir);
    try cwd.createDirPath(io, sections_dir);
    try cwd.createDirPath(io, articles_dir);
    try cwd.createDirPath(io, layouts_dir);

    const pa2 = std.heap.page_allocator;
    const layout_path = try std.fmt.allocPrint(pa2, "{s}/layouts/main.html", .{root});
    defer pa2.free(layout_path);
    const common_path = try std.fmt.allocPrint(pa2, "{s}/content/includes/common.md", .{root});
    defer pa2.free(common_path);
    const shared_path = try std.fmt.allocPrint(pa2, "{s}/content/includes/shared.md", .{root});
    defer pa2.free(shared_path);
    try writeFile(io, layout_path, layout_html);
    try writeFile(io, common_path, common_include);
    try writeFile(io, shared_path, shared_include);
    try writeIndex(io, root);

    var generated_pages: usize = 1; // index
    var section: usize = 0;
    while (generated_pages < page_count) : (section += 1) {
        try writeTrunk(io, root, section);
        generated_pages += 1;

        var satellites: usize = 0;
        while (generated_pages < page_count and satellites < satellites_per_trunk) : (satellites += 1) {
            try writeSatellite(io, root, generated_pages, section);
            generated_pages += 1;
        }
    }
    return generated_pages;
}

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("testdata-generator: unable to read process arguments\n", .{});
        return @intFromEnum(ExitCode.usage);
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(cold);
    args.ensureTotalCapacity(cold, args_z.len) catch return @intFromEnum(ExitCode.usage);
    for (args_z) |arg| args.appendAssumeCapacity(arg);

    const options = parseOptions(args.items) catch |err| {
        std.debug.print("testdata-generator: {s}\n", .{@errorName(err)});
        printUsage();
        return @intFromEnum(ExitCode.usage);
    };
    if (options.help) {
        printUsage();
        return @intFromEnum(ExitCode.success);
    }
    validateOutDir(init.io, Io.Dir.cwd(), options.out_dir) catch |err| {
        std.debug.print("testdata-generator: unsafe --out path \"{s}\": {s}\n", .{ options.out_dir, @errorName(err) });
        printUsage();
        return @intFromEnum(ExitCode.usage);
    };

    _ = generateSite(init.io, options.out_dir, options.page_count) catch |err| {
        std.debug.print("testdata-generator: failed: {s}\n", .{@errorName(err)});
        return @intFromEnum(ExitCode.failed);
    };
    std.debug.print("testdata-generator: wrote {d} pages under {s}\n", .{ options.page_count, options.out_dir });
    return @intFromEnum(ExitCode.success);
}

// --- tests -----------------------------------------------------------------

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn countFiles(io: Io, gpa: std.mem.Allocator, root: []const u8) !usize {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

/// Canonical concatenation of every file's relative path + bytes, in walk
/// (sorted) order. Byte-equal between two generated trees iff the trees are
/// identical file-for-file.
fn writeFingerprint(io: Io, gpa: std.mem.Allocator, root: []const u8, out: *std.ArrayList(u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try readFileAlloc(io, dir, entry.path, gpa);
        defer gpa.free(bytes);
        try out.appendSlice(gpa, entry.path);
        try out.append(gpa, '=');
        try out.appendSlice(gpa, bytes);
        try out.append(gpa, '\n');
    }
}

test "parse options accepts large page counts and custom out dir" {
    const defaults = try parseOptions(&.{"testdata-generator"});
    try std.testing.expectEqual(default_page_count, defaults.page_count);
    try std.testing.expectEqualStrings(default_out, defaults.out_dir);

    const large = try parseOptions(&.{ "testdata-generator", "--pages", "5000", "--out", ".tmp/corpus" });
    try std.testing.expectEqual(@as(usize, 5_000), large.page_count);
    try std.testing.expectEqualStrings(".tmp/corpus", large.out_dir);

    try std.testing.expectError(error.InvalidPageCount, parseOptions(&.{ "testdata-generator", "--pages=0" }));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{ "testdata-generator", "--pages" }));
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "testdata-generator", "--nope" }));
}

test "out dir must stay inside the working tree" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const safe = [_][]const u8{ ".generated", ".tmp/corpus", "a/b/c" };
    for (safe) |p| try validateOutDir(io, cwd, p);

    const unsafe = [_][]const u8{
        "/tmp/abs",
        ".",
        "..",
        "../escape",
        "a/../b",
        ".tmp/",
        "a\\b",
        "",
    };
    for (unsafe) |p| try std.testing.expectError(error.InvalidOutDir, validateOutDir(io, cwd, p));
}

test "out dir rejects intermediate symlinks before cleanup" {
    if (builtin.os.tag == .windows) return;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/keep.txt", .data = "must survive\n" });
    tmp.dir.symLink(io, "outside", "work", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    try std.testing.expectError(error.InvalidOutDir, validateOutDir(io, tmp.dir, "work/corpus"));
    const keep = try readFileAlloc(io, tmp.dir, "outside/keep.txt", gpa);
    defer gpa.free(keep);
    try std.testing.expectEqualStrings("must survive\n", keep);
}

test "generation produces the exact requested page count" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const root = ".zig-cache/tmp/testdata-count";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    _ = try generateSite(io, root, 21);
    // 21 pages + 1 layout + 2 includes = 24 files.
    try std.testing.expectEqual(@as(usize, 24), try countFiles(io, gpa, root));
}

test "repeated generation is byte-identical (determinism contract)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const root_a = ".zig-cache/tmp/testdata-a";
    const root_b = ".zig-cache/tmp/testdata-b";
    Io.Dir.cwd().deleteTree(io, root_a) catch {};
    Io.Dir.cwd().deleteTree(io, root_b) catch {};
    defer Io.Dir.cwd().deleteTree(io, root_a) catch {};
    defer Io.Dir.cwd().deleteTree(io, root_b) catch {};

    _ = try generateSite(io, root_a, 33);
    _ = try generateSite(io, root_b, 33);

    var fp_a: std.ArrayList(u8) = .empty;
    defer fp_a.deinit(gpa);
    var fp_b: std.ArrayList(u8) = .empty;
    defer fp_b.deinit(gpa);
    try writeFingerprint(io, gpa, root_a, &fp_a);
    try writeFingerprint(io, gpa, root_b, &fp_b);
    try std.testing.expectEqualSlices(u8, fp_a.items, fp_b.items);
}

test "generated layout consumes nav and breadcrumb markers" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const root = ".zig-cache/tmp/testdata-layout";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    _ = try generateSite(io, root, 5);
    var dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const layout = try readFileAlloc(io, dir, "layouts/main.html", gpa);
    defer gpa.free(layout);
    try std.testing.expect(std.mem.indexOf(u8, layout, "{{nav}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "{{breadcrumb}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "{{content}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "{{title}}") != null);
}
