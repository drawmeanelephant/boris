//! Phase 1: recursive content/ directory walker (HTML / RAG compile path).
//!
//! Scans exactly once, populates the in-memory Page database, and performs
//! no rendering. Paths and entity ids are allocated in the PageDb arena.
//!
//! Aligns with `discover.zig` / `pathutil.zig` policy:
//! - **Entity ids** via `pathutil.canonicalEntityId` (case-preserving, `/` only)
//! - **HTML output paths** via `pathutil.htmlOutputPath` (validated entity ids only)
//! - **Symlinks** rejected (directory and page-file); never follow directory links
//! - **Deterministic order**: sort pages by entity_id after scan

const std = @import("std");
const Io = std.Io;
const page_mod = @import("page.zig");
const pathutil = @import("pathutil.zig");
const Page = page_mod.Page;
const PageDb = page_mod.PageDb;

pub const ScanError = error{
    ContentDirMissing,
    ContentDirNotIterable,
    /// Directory walk revisited a previously seen directory inode.
    SymlinkCycle,
    /// Symlinked directory or page file under content root (v0.1 rejects both).
    SymlinkRejected,
    /// Two source paths / entity ids differ only in letter case.
    EntityCaseCollision,
    /// Hard-linked (or equivalent) page discovered under two paths.
    DuplicatePhysicalFile,
} || Allocator.Error || Io.Dir.OpenError || Io.Dir.Walker.Error || Io.Dir.StatError || Io.Dir.StatFileError || Io.File.OpenError || Io.File.Reader.Error;

const Allocator = std.mem.Allocator;

/// content/guides/intro.md -> guides/intro.html via validated entity id.
pub fn outputPathFromSource(allocator: Allocator, source_rel: []const u8) ![]u8 {
    const entity_id = try pathutil.canonicalEntityId(allocator, source_rel);
    defer allocator.free(entity_id);
    return pathutil.htmlOutputPath(allocator, entity_id);
}

/// content/guides/intro.md -> guides/intro (entity key for Trunk/Satellite graph)
pub fn entityIdFromSource(allocator: Allocator, source_rel: []const u8) ![]u8 {
    return pathutil.canonicalEntityId(allocator, source_rel);
}

/// Composite filesystem identity for cycle / hard-link detection.
const FsIdentity = struct {
    dev: u64,
    ino: u64,

    fn fromStat(st: Io.File.Stat) FsIdentity {
        return .{ .dev = 0, .ino = @intCast(st.inode) };
    }

    fn eql(a: FsIdentity, b: FsIdentity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

fn identitySeen(list: []const FsIdentity, id: FsIdentity) bool {
    for (list) |v| {
        if (FsIdentity.eql(v, id)) return true;
    }
    return false;
}

/// Walk `content/` exactly once and append a Page for every markdown page file.
/// Does not read file bodies (that happens in the compile/parse phase so the
/// whiteboard arena can own transient work). Paths are stored permanently.
///
/// Aborts with `error.SymlinkRejected` on content symlinks and
/// `error.SymlinkCycle` if a directory inode is visited twice.
pub fn scanContentDir(
    io: Io,
    content_dir: Io.Dir,
    db: *PageDb,
) !void {
    const arena = db.allocator();
    const list_gpa = db.arena.child_allocator;

    var visited_dirs: std.ArrayList(FsIdentity) = .empty;
    defer visited_dirs.deinit(list_gpa);
    var visited_files: std.ArrayList(FsIdentity) = .empty;
    defer visited_files.deinit(list_gpa);

    const root_st = try content_dir.stat(io);
    try visited_dirs.append(list_gpa, FsIdentity.fromStat(root_st));

    var walker = try content_dir.walkSelectively(list_gpa);
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io) catch |err| switch (err) {
            error.AccessDenied,
            error.PermissionDenied,
            error.SystemResources,
            error.Unexpected,
            => {
                std.log.err("directory walk error: {s}", .{@errorName(err)});
                return err;
            },
            else => return err,
        } orelse break;

        // v0.1: never follow symlinks (dirs or page files).
        if (entry.kind == .sym_link) {
            std.log.err("symlink rejected under content root: '{s}'", .{entry.path});
            return error.SymlinkRejected;
        }

        if (entry.kind == .directory) {
            const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            };
            if (st.kind != .directory) continue;

            const identity = FsIdentity.fromStat(st);
            if (identitySeen(visited_dirs.items, identity)) {
                std.log.err(
                    "symlink cycle: directory inode already visited at '{s}'",
                    .{entry.path},
                );
                return error.SymlinkCycle;
            }
            try visited_dirs.append(list_gpa, identity);
            walker.enter(io, entry) catch |err| switch (err) {
                error.SymLinkLoop => {
                    std.log.err("symlink cycle at '{s}'", .{entry.path});
                    return error.SymlinkCycle;
                },
                else => return err,
            };
            continue;
        }

        if (entry.kind != .file) continue;
        if (!pathutil.isPageFile(entry.basename)) continue;

        const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => null,
            else => return err,
        };
        if (st) |s| {
            const identity = FsIdentity.fromStat(s);
            if (identitySeen(visited_files.items, identity)) {
                std.log.err(
                    "duplicate physical file at '{s}' (hard link or equivalent)",
                    .{entry.path},
                );
                return error.DuplicatePhysicalFile;
            }
            try visited_files.append(list_gpa, identity);
        }

        // entry.path is relative to content_dir and is invalidated on next next().
        const source_path = pathutil.canonicalize(arena, entry.path) catch |err| {
            std.log.err("illegal source path '{s}': {s}", .{ entry.path, @errorName(err) });
            return err;
        };
        const entity_id = pathutil.canonicalEntityId(arena, source_path) catch |err| {
            std.log.err("cannot derive entity id from '{s}': {s}", .{ source_path, @errorName(err) });
            return err;
        };
        const output_path = pathutil.htmlOutputPath(arena, entity_id) catch |err| {
            std.log.err("cannot derive output path for '{s}': {s}", .{ entity_id, @errorName(err) });
            return err;
        };

        try db.append(.{
            .source_path = source_path,
            .output_path = output_path,
            .entity_id = entity_id,
        });
    }

    // Deterministic order independent of filesystem enumeration.
    std.mem.sort(Page, db.pages.items, {}, struct {
        fn less(_: void, a: Page, b: Page) bool {
            const id_ord = std.mem.order(u8, a.entity_id, b.entity_id);
            if (id_ord != .eq) return id_ord == .lt;
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    try diagnoseCaseCollisions(db);
}

fn diagnoseCaseCollisions(db: *PageDb) !void {
    const pages = db.items();
    var i: usize = 0;
    while (i < pages.len) : (i += 1) {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const path_case = pathutil.pathsDifferOnlyInCase(pages[i].source_path, pages[j].source_path);
            const id_case = pathutil.pathsDifferOnlyInCase(pages[i].entity_id, pages[j].entity_id);
            if (!path_case and !id_case) continue;
            std.log.err(
                "entity case collision: '{s}' ({s}) and '{s}' ({s})",
                .{ pages[i].source_path, pages[i].entity_id, pages[j].source_path, pages[j].entity_id },
            );
            return error.EntityCaseCollision;
        }
    }
}

/// Open `content/` with iterate capability and scan into `db`.
pub fn scanFromCwd(io: Io, db: *PageDb, content_subdir: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var content_dir = cwd.openDir(io, content_subdir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("content directory '{s}' not found", .{content_subdir});
            return error.ContentDirMissing;
        },
        else => return err,
    };
    defer content_dir.close(io);

    try scanContentDir(io, content_dir, db);
}

/// Print every mapped page path (phase 1 verification).
pub fn printMappedPages(pages: []const Page) void {
    std.debug.print("Boris content database: {d} page(s)\n", .{pages.len});
    for (pages) |p| {
        std.debug.print(
            "  entity={s}  source={s}  output={s}\n",
            .{ p.entity_id, p.source_path, p.output_path },
        );
    }
}

test "outputPathFromSource" {
    const gpa = std.testing.allocator;
    const out = try outputPathFromSource(gpa, "guides/intro.md");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("guides/intro.html", out);
}

test "outputPathFromSource normalizes backslash and preserves case" {
    const gpa = std.testing.allocator;
    const out = try outputPathFromSource(gpa, "Guides\\Intro.md");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("Guides/Intro.html", out);
}

test "entityIdFromSource" {
    const gpa = std.testing.allocator;
    const id = try entityIdFromSource(gpa, "guides/intro.md");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("guides/intro", id);
}

test "entityIdFromSource preserves case and uses slash separators" {
    const gpa = std.testing.allocator;
    const id = try entityIdFromSource(gpa, "Guides\\Intro.md");
    defer gpa.free(id);
    try std.testing.expectEqualStrings("Guides/Intro", id);
}
