//! Static passthrough files (#804).
//!
//! A declared site-owned directory (`--static-dir`) whose contents are copied
//! byte-identically into the root of each selected HTML target: `robots.txt`,
//! `humans.txt`, `.well-known/…`, and any other file that must be served at
//! the target root. This mirrors the well-known-file precedent (`--llms`,
//! Standard.site `.well-known` emission) and generalizes it to arbitrary
//! author-owned files.
//!
//! Rules (normative in docs/contracts/html-output.md):
//! - The directory is an input, not an output tree: its location is not
//!   workspace-contained (same policy as `--input`), but every emitted path
//!   must be a safe target-relative path and must never enter the
//!   compiler-owned `.boris-cache/` or `_boris/` namespaces.
//! - Missing directory, directory-as-file, symlinks anywhere inside, and
//!   unsafe or colliding paths fail loudly before any page is rendered.
//! - Copies are deterministic: entries sort bytewise by relative path and are
//!   staged before the artifact inventory is collected, so passthrough files
//!   are declared target-owned artifacts (`static-file`), never incidental
//!   deployment extras.
//! - On rebuild, prior-inventory `static-file` records that are no longer in
//!   the current set are scrubbed from the committed target; unrecorded
//!   deployment-owned files are never touched.

const std = @import("std");
const Io = std.Io;
const artifact_inventory = @import("artifact_inventory.zig");

pub const Error = error{
    StaticDirMissing,
    StaticDirNotDirectory,
    StaticSymlink,
    StaticPathUnsafe,
    StaticPathCollision,
    OutOfMemory,
};

/// Compiler-owned target-root namespaces a passthrough file may never enter.
const owned_namespaces = [_][]const u8{ ".boris-cache", "_boris" };

/// One staged passthrough file, target-root-relative. Owned by the caller
/// via `freeInventory`.
pub const Entry = struct {
    rel_path: []u8,
};

pub fn freeInventory(gpa: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |entry| gpa.free(entry.rel_path);
    if (entries.len > 0) gpa.free(entries);
}

/// Is this target-relative path legal for a passthrough file?
pub fn validatePassthroughPath(rel_path: []const u8) Error!void {
    if (!artifact_inventory.validateRelativePath(rel_path)) return error.StaticPathUnsafe;
    var it = std.mem.splitScalar(u8, rel_path, '/');
    while (it.next()) |segment| {
        for (owned_namespaces) |ns| {
            if (std.mem.eql(u8, segment, ns)) return error.StaticPathUnsafe;
        }
    }
}

fn joinRel(gpa: std.mem.Allocator, prefix: []const u8, name: []const u8) Error![]u8 {
    if (prefix.len == 0) return gpa.dupe(u8, name) catch return error.OutOfMemory;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, name }) catch return error.OutOfMemory;
}

/// Discover the passthrough file inventory under `static_dir_rel`, resolved
/// against `cwd`. Sorted bytewise by relative path. Fails loudly when the
/// directory is missing, is not a directory, contains symlinks, or contains
/// an unsafe path. Symlinked directories are rejected, never followed.
pub fn loadInventory(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    static_dir_rel: []const u8,
) Error![]Entry {
    if (cwd.statFile(io, static_dir_rel, .{ .follow_symlinks = false })) |st| {
        if (st.kind == .sym_link) return error.StaticSymlink;
        if (st.kind != .directory) return error.StaticDirNotDirectory;
    } else |err| switch (err) {
        error.FileNotFound => return error.StaticDirMissing,
        else => return error.StaticDirMissing,
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeInventory(gpa, entries.items);

    var dir = cwd.openDir(io, static_dir_rel, .{ .iterate = true }) catch
        return error.StaticDirMissing;
    defer dir.close(io);

    var walker = dir.walkSelectively(gpa) catch return error.StaticPathUnsafe;
    defer walker.deinit();

    while (true) {
        const maybe = walker.next(io) catch return error.StaticPathUnsafe;
        const entry = maybe orelse break;
        if (entry.kind == .sym_link) return error.StaticSymlink;
        if (entry.kind == .directory) {
            // Defensive no-follow check mirroring page discovery: the root the
            // walker reports must be a real directory.
            const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch
                return error.StaticPathUnsafe;
            if (st.kind != .directory) return error.StaticPathUnsafe;
            walker.enter(io, entry) catch return error.StaticPathUnsafe;
            continue;
        }
        if (entry.kind != .file) return error.StaticPathUnsafe;

        const rel = try joinRel(gpa, "", entry.path);
        errdefer gpa.free(rel);
        try validatePassthroughPath(rel);
        try entries.append(gpa, .{ .rel_path = rel });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
        }
    }.less);
    return entries.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Reject any passthrough path that duplicates another passthrough path or
/// collides with a compiler-owned output path (pages, theme assets,
/// content-local assets, search index, sitemap).
pub fn checkCollisions(
    entries: []const Entry,
    page_paths: []const []const u8,
    theme_paths: []const []const u8,
    content_paths: []const []const u8,
    search_path: []const u8,
    sitemap_path: ?[]const u8,
) Error!void {
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.rel_path, b.rel_path)) return error.StaticPathCollision;
        }
        for (page_paths) |p| if (std.mem.eql(u8, a.rel_path, p)) return error.StaticPathCollision;
        for (theme_paths) |p| if (std.mem.eql(u8, a.rel_path, p)) return error.StaticPathCollision;
        for (content_paths) |p| if (std.mem.eql(u8, a.rel_path, p)) return error.StaticPathCollision;
        if (std.mem.eql(u8, a.rel_path, search_path)) return error.StaticPathCollision;
        if (sitemap_path) |p| if (std.mem.eql(u8, a.rel_path, p)) return error.StaticPathCollision;
    }
}

/// Copy every passthrough file into `stage_dir` byte-identically, preserving
/// the directory tree under the static root. Deterministic order (sorted).
pub fn copyToStage(
    io: Io,
    cwd: Io.Dir,
    stage_dir: Io.Dir,
    static_dir_rel: []const u8,
    entries: []const Entry,
) !void {
    var dir = try cwd.openDir(io, static_dir_rel, .{});
    defer dir.close(io);
    for (entries) |entry| {
        if (std.fs.path.dirname(entry.rel_path)) |parent| {
            if (parent.len > 0) try stage_dir.createDirPath(io, parent);
        }
        try dir.copyFile(entry.rel_path, stage_dir, entry.rel_path, io, .{ .replace = true });
    }
}

/// Read the prior committed inventory's `static-file` paths from the live
/// target. Missing inventory → empty (nothing declared to scrub). An
/// inventory that fails strict parsing declares no static ownership, so no
/// file is scrubbed; the next successful commit replaces it and scrubbing
/// self-heals on the following build.
pub fn readPriorStaticPaths(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
    target_name: []const u8,
) ![][]const u8 {
    const bytes = dist_dir.readFileAlloc(io, artifact_inventory.output_path, gpa, .unlimited) catch
        return try gpa.alloc([]const u8, 0);
    defer gpa.free(bytes);

    var inventory = artifact_inventory.parse(gpa, bytes, target_name) catch
        return try gpa.alloc([]const u8, 0);
    defer inventory.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    for (inventory.records) |record| {
        if (record.kind != .static_file) continue;
        const copy = try gpa.dupe(u8, record.path);
        errdefer gpa.free(copy);
        try paths.append(gpa, copy);
    }
    return try paths.toOwnedSlice(gpa);
}

pub fn freePriorStaticPaths(gpa: std.mem.Allocator, paths: [][]const u8) void {
    for (paths) |p| gpa.free(p);
    if (paths.len > 0) gpa.free(paths);
}

/// Delete committed passthrough files that are no longer in the current
/// inventory. Never touches unrecorded deployment-owned files. Missing files
/// are already gone; other deletion errors are swallowed so a successful
/// commit is not rolled back by a cleanup hiccup (mirrors theme-asset scrub).
pub fn scrubStaleStaticFiles(io: Io, dist_dir: Io.Dir, prior_paths: [][]const u8, current: []const Entry) void {
    for (prior_paths) |path| {
        var live = false;
        for (current) |entry| {
            if (std.mem.eql(u8, entry.rel_path, path)) {
                live = true;
                break;
            }
        }
        if (live) continue;
        dist_dir.deleteFile(io, path) catch continue;
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn writeTree(io: Io, rel: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rel, .data = data });
}

test "validatePassthroughPath rejects unsafe and compiler-owned paths" {
    try validatePassthroughPath("robots.txt");
    try validatePassthroughPath(".well-known/security.txt");
    try validatePassthroughPath("a/b/c.txt");
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath(""));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("/abs.txt"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("a/../b.txt"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("./a.txt"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("a//b.txt"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("a\\b.txt"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath(".boris-cache/manifest.json"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("_boris/proof/x.json"));
    try testing.expectError(error.StaticPathUnsafe, validatePassthroughPath("a\x01.txt"));
}

fn tmpRoot(aa: std.mem.Allocator, sub: anytype, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/{s}", .{ sub, name });
}

test "loadInventory sorts nested files" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const aa = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_rel = try tmpRoot(aa, tmp.sub_path, "static-root");

    try writeTree(io, try std.fmt.allocPrint(aa, "{s}/robots.txt", .{root_rel}), "User-agent: *\n");
    try writeTree(io, try std.fmt.allocPrint(aa, "{s}/.well-known/security.txt", .{root_rel}), "Contact: mailto:x@example.test\n");
    try writeTree(io, try std.fmt.allocPrint(aa, "{s}/nested/deep/humans.txt", .{root_rel}), "Team\n");

    const entries = try loadInventory(io, testing.allocator, Io.Dir.cwd(), root_rel);
    defer freeInventory(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings(".well-known/security.txt", entries[0].rel_path);
    try testing.expectEqualStrings("nested/deep/humans.txt", entries[1].rel_path);
    try testing.expectEqualStrings("robots.txt", entries[2].rel_path);
}

test "loadInventory fails loudly on missing dir and file-as-dir" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const aa = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try tmpRoot(aa, tmp.sub_path, "nope");
    try testing.expectError(error.StaticDirMissing, loadInventory(io, testing.allocator, Io.Dir.cwd(), missing));

    const as_file = try tmpRoot(aa, tmp.sub_path, "plain");
    try writeTree(io, as_file, "x");
    try testing.expectError(error.StaticDirNotDirectory, loadInventory(io, testing.allocator, Io.Dir.cwd(), as_file));
}

test "loadInventory rejects symlinked files when the host allows symlinks" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const aa = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_rel = try tmpRoot(aa, tmp.sub_path, "static-link");
    const target_rel = try tmpRoot(aa, tmp.sub_path, "real.txt");

    try writeTree(io, target_rel, "x");
    const link_parent = try std.fmt.allocPrint(aa, "{s}/nested", .{root_rel});
    try Io.Dir.cwd().createDirPath(io, link_parent);
    const link_rel = try std.fmt.allocPrint(aa, "{s}/nested/link.txt", .{root_rel});
    const target_abs = try std.fmt.allocPrint(aa, "{s}/real.txt", .{tmp.sub_path});
    Io.Dir.cwd().symLink(io, target_abs, link_rel, .{}) catch {
        return; // host denies symlink creation; documented skip
    };
    try testing.expectError(error.StaticSymlink, loadInventory(io, testing.allocator, Io.Dir.cwd(), root_rel));
}

test "copyToStage stages byte-identical nested files" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const aa = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_rel = try tmpRoot(aa, tmp.sub_path, "src");
    const stage_rel = try tmpRoot(aa, tmp.sub_path, "stage");
    const body = "User-agent: *\nDisallow:\n";
    try writeTree(io, try std.fmt.allocPrint(aa, "{s}/robots.txt", .{src_rel}), body);
    try writeTree(io, try std.fmt.allocPrint(aa, "{s}/.well-known/security.txt", .{src_rel}), "c\n");

    const entries = try loadInventory(io, testing.allocator, Io.Dir.cwd(), src_rel);
    defer freeInventory(testing.allocator, entries);
    try Io.Dir.cwd().createDirPath(io, stage_rel);
    var stage = try Io.Dir.cwd().openDir(io, stage_rel, .{});
    defer stage.close(io);
    try copyToStage(io, Io.Dir.cwd(), stage, src_rel, entries);

    const copied = try stage.readFileAlloc(io, "robots.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings(body, copied);
    const well_known = try stage.readFileAlloc(io, ".well-known/security.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(well_known);
    try testing.expectEqualStrings("c\n", well_known);
}

test "checkCollisions detects duplicates and owned-output overlap" {
    const entries = [_]Entry{
        .{ .rel_path = @constCast("robots.txt") },
        .{ .rel_path = @constCast("humans.txt") },
    };
    const pages = [_][]const u8{"index.html"};
    const themes = [_][]const u8{"assets/css/site.css"};
    const contents = [_][]const u8{"guides/intro.assets/d.svg"};

    try checkCollisions(&entries, &pages, &themes, &contents, "_boris/search/search-index.json", "sitemap.xml");

    const dup = [_]Entry{
        .{ .rel_path = @constCast("a.txt") },
        .{ .rel_path = @constCast("a.txt") },
    };
    try testing.expectError(error.StaticPathCollision, checkCollisions(&dup, &.{}, &.{}, &.{}, "_boris/search/search-index.json", null));

    const hits_page = [_]Entry{.{ .rel_path = @constCast("index.html") }};
    try testing.expectError(error.StaticPathCollision, checkCollisions(&hits_page, &pages, &themes, &contents, "_boris/search/search-index.json", null));

    const hits_theme = [_]Entry{.{ .rel_path = @constCast("assets/css/site.css") }};
    try testing.expectError(error.StaticPathCollision, checkCollisions(&hits_theme, &pages, &themes, &contents, "_boris/search/search-index.json", null));

    const hits_sitemap = [_]Entry{.{ .rel_path = @constCast("sitemap.xml") }};
    try testing.expectError(error.StaticPathCollision, checkCollisions(&hits_sitemap, &pages, &themes, &contents, "_boris/search/search-index.json", "sitemap.xml"));
}
