//! Recursive discovery of page files under a content root.
//!
//! Ownership:
//! - `list_gpa` owns the ArrayList spine of discovered records.
//! - `retain` (long-lived arena) owns each canonical `source_path` / `entity_id`.
//! - Caller frees the list with `list_gpa` and the strings via `retain` reset/deinit.
//!
//! ## v0.1 symlink policy
//!
//! - **Reject** symlinked directories (`E_SYMLINK`); never enter them (no recursive
//!   follow of directory symlinks).
//! - **Reject** symlinked page files (`E_SYMLINK`); do not treat them as pages.
//! - Track visited **directory** identities (`inode`) so accidental re-entry still
//!   emits `E_SYMLINK_CYCLE` rather than looping.
//! - Track visited **file** identities so hard-linked duplicates are diagnosed
//!   (`E_SOURCE_PATH`) instead of double-registered.
//!
//! ## Determinism
//!
//! After the walk, records are sorted by **canonical entity_id** (then
//! source_path) so later stages never depend on filesystem enumeration order.

const std = @import("std");
const Io = std.Io;
const pathutil = @import("pathutil.zig");
const diag = @import("diag.zig");

pub const Options = struct {
    /// Content root relative to process CWD (e.g. `content`).
    content_root: []const u8 = "content",
};

/// One discovered page before frontmatter parse / graph resolve.
pub const Found = struct {
    /// Canonical content-root-relative path (owned by retain arena).
    source_path: []const u8,
    /// Canonical entity id derived via `pathutil.canonicalEntityId` (retain-owned).
    entity_id: []const u8,
};

/// Composite directory/file identity: device + inode when available.
/// Zig's `File.Stat` exposes `inode` portably; `dev` is 0 when not available.
const FsIdentity = struct {
    dev: u64,
    ino: u64,

    fn fromStat(st: Io.File.Stat) FsIdentity {
        return .{
            .dev = 0, // Io.File.Stat does not expose st_dev; inode alone is used.
            .ino = @intCast(st.inode),
        };
    }

    fn eql(a: FsIdentity, b: FsIdentity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

fn dirIdentityOf(dir: Io.Dir, io: Io) !FsIdentity {
    const st = try dir.stat(io);
    return FsIdentity.fromStat(st);
}

fn identitySeen(list: []const FsIdentity, id: FsIdentity) bool {
    for (list) |v| {
        if (FsIdentity.eql(v, id)) return true;
    }
    return false;
}

fn pushDiag(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    out_diags: *std.ArrayList(diag.Diagnostic),
    code: diag.Code,
    path: []const u8,
    message: []const u8,
    remediation: []const u8,
    id: []const u8,
) !void {
    const sp = try retain.dupe(u8, path);
    try out_diags.append(list_gpa, .{
        .severity = .error_,
        .code = code,
        .message = message,
        .remediation = remediation,
        .source_path = sp,
        .line = 1,
        .column = 1,
        .id = id,
    });
}

fn pushSymlink(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    out_diags: *std.ArrayList(diag.Diagnostic),
    path: []const u8,
    kind_label: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        retain,
        "symlink {s} rejected under content root: \"{s}\"",
        .{ kind_label, path },
    );
    try pushDiag(
        list_gpa,
        retain,
        out_diags,
        .E_SYMLINK,
        path,
        msg,
        try retain.dupe(u8, "Replace the symlink with a real file or directory under the content root (v0.1 does not follow content symlinks)"),
        "",
    );
}

fn pushSymlinkCycle(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    out_diags: *std.ArrayList(diag.Diagnostic),
    path: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        retain,
        "symlink cycle detected at \"{s}\" (directory inode already visited)",
        .{path},
    );
    try pushDiag(
        list_gpa,
        retain,
        out_diags,
        .E_SYMLINK_CYCLE,
        path,
        msg,
        try retain.dupe(u8, "Remove the cyclic symlink under the content root"),
        "",
    );
}

/// After discovery, emit `E_ENTITY_CASE_COLLISION` when two canonical source
/// paths or entity ids differ only in letter case.
pub fn diagnoseEntityCaseCollisions(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    found: []const Found,
    out_diags: *std.ArrayList(diag.Diagnostic),
) !void {
    // found is sorted by entity_id; still O(n²) for small content roots.
    var i: usize = 0;
    while (i < found.len) : (i += 1) {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const path_case = pathutil.pathsDifferOnlyInCase(found[i].source_path, found[j].source_path);
            const id_case = pathutil.pathsDifferOnlyInCase(found[i].entity_id, found[j].entity_id);
            if (!path_case and !id_case) continue;

            const msg = try std.fmt.allocPrint(
                retain,
                "source paths or entity ids differ only in case: \"{s}\" ({s}) and \"{s}\" ({s})",
                .{ found[i].source_path, found[i].entity_id, found[j].source_path, found[j].entity_id },
            );
            try out_diags.append(list_gpa, .{
                .severity = .error_,
                .code = .E_ENTITY_CASE_COLLISION,
                .message = msg,
                .remediation = try retain.dupe(u8, "Rename one path so source paths and entity ids are unique ignoring case"),
                .source_path = found[i].source_path,
                .line = 1,
                .column = 1,
                .id = found[i].entity_id,
            });
            break; // one diagnostic per later path is enough
        }
    }
}

fn tryRegisterPage(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    out_found: *std.ArrayList(Found),
    out_diags: *std.ArrayList(diag.Diagnostic),
    visited_files: *std.ArrayList(FsIdentity),
    entry_path: []const u8,
    file_st: ?Io.File.Stat,
) !void {
    if (file_st) |st| {
        const identity = FsIdentity.fromStat(st);
        if (identitySeen(visited_files.items, identity)) {
            const msg = try std.fmt.allocPrint(
                retain,
                "duplicate physical file at \"{s}\" (hard link or equivalent already discovered)",
                .{entry_path},
            );
            try pushDiag(
                list_gpa,
                retain,
                out_diags,
                .E_SOURCE_PATH,
                entry_path,
                msg,
                try retain.dupe(u8, "Remove hard links so each page has a single path under the content root"),
                "",
            );
            return;
        }
        try visited_files.append(list_gpa, identity);
    }

    const canon = pathutil.canonicalize(retain, entry_path) catch |err| {
        const msg = try std.fmt.allocPrint(retain, "illegal source path \"{s}\": {s}", .{
            entry_path,
            @errorName(err),
        });
        try pushDiag(
            list_gpa,
            retain,
            out_diags,
            .E_SOURCE_PATH,
            entry_path,
            msg,
            try retain.dupe(u8, "Use a content-root-relative path without ., .., empty segments, or absolute prefixes"),
            "",
        );
        return;
    };

    const entity_id = pathutil.canonicalEntityId(retain, canon) catch |err| {
        const msg = try std.fmt.allocPrint(retain, "cannot derive entity id from \"{s}\": {s}", .{
            canon,
            @errorName(err),
        });
        try pushDiag(
            list_gpa,
            retain,
            out_diags,
            .E_SOURCE_PATH,
            canon,
            msg,
            try retain.dupe(u8, "Use a .md/.mdx page path whose stem is a valid entity id (≤255 bytes, no ., ..)"),
            "",
        );
        return;
    };

    try out_found.append(list_gpa, .{
        .source_path = canon,
        .entity_id = entity_id,
    });
}

/// Walk `content_root`, collect page files, derive entity ids, sort by entity_id.
///
/// On illegal paths / rejected symlinks, appends diagnostics (strings retained
/// in `retain`) and skips that entry. Missing content root returns
/// `error.ContentDirMissing` without populating `out_found`.
pub fn discover(
    io: Io,
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    options: Options,
    out_found: *std.ArrayList(Found),
    out_diags: *std.ArrayList(diag.Diagnostic),
) !void {
    const cwd = Io.Dir.cwd();
    var content_dir = cwd.openDir(io, options.content_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.ContentDirMissing,
        error.NotDir => return error.ContentDirMissing,
        else => return err,
    };
    defer content_dir.close(io);

    var visited_dirs: std.ArrayList(FsIdentity) = .empty;
    defer visited_dirs.deinit(list_gpa);
    var visited_files: std.ArrayList(FsIdentity) = .empty;
    defer visited_files.deinit(list_gpa);

    const root_id = try dirIdentityOf(content_dir, io);
    try visited_dirs.append(list_gpa, root_id);

    var walker = try content_dir.walkSelectively(list_gpa);
    defer walker.deinit();

    while (true) {
        const entry = try walker.next(io) orelse break;

        // --- Symlinks: never follow (v0.1 policy) ---------------------------
        if (entry.kind == .sym_link) {
            // Classify target for a precise diagnostic; do not enter directories
            // and do not register symlink page files.
            const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = true }) catch |err| switch (err) {
                error.SymLinkLoop => {
                    try pushSymlinkCycle(list_gpa, retain, out_diags, entry.path);
                    continue;
                },
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => {
                    try pushSymlink(list_gpa, retain, out_diags, entry.path, "entry");
                    continue;
                },
                else => return err,
            };
            if (st.kind == .directory) {
                try pushSymlink(list_gpa, retain, out_diags, entry.path, "directory");
            } else if (st.kind == .file and pathutil.isPageFile(entry.basename)) {
                try pushSymlink(list_gpa, retain, out_diags, entry.path, "page file");
            } else {
                try pushSymlink(list_gpa, retain, out_diags, entry.path, "entry");
            }
            continue;
        }

        // --- Real directories: enter once per inode ------------------------
        if (entry.kind == .directory) {
            const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            };
            if (st.kind != .directory) continue;

            const identity = FsIdentity.fromStat(st);
            if (identitySeen(visited_dirs.items, identity)) {
                try pushSymlinkCycle(list_gpa, retain, out_diags, entry.path);
                continue;
            }
            try visited_dirs.append(list_gpa, identity);
            walker.enter(io, entry) catch |err| switch (err) {
                error.SymLinkLoop => {
                    try pushSymlinkCycle(list_gpa, retain, out_diags, entry.path);
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

        try tryRegisterPage(list_gpa, retain, out_found, out_diags, &visited_files, entry.path, st);
    }

    // Deterministic order: sort by canonical entity_id, then source_path.
    std.mem.sort(Found, out_found.items, {}, struct {
        fn less(_: void, a: Found, b: Found) bool {
            const id_ord = std.mem.order(u8, a.entity_id, b.entity_id);
            if (id_ord != .eq) return id_ord == .lt;
            return std.mem.order(u8, a.source_path, b.source_path) == .lt;
        }
    }.less);

    try diagnoseEntityCaseCollisions(list_gpa, retain, out_found.items, out_diags);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "diagnoseEntityCaseCollisions detects case-only path pairs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    const found = [_]Found{
        .{ .source_path = "Guides/Intro.md", .entity_id = "Guides/Intro" },
        .{ .source_path = "guides/intro.md", .entity_id = "guides/intro" },
        .{ .source_path = "other.md", .entity_id = "other" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    try diagnoseEntityCaseCollisions(gpa, retain, &found, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .E_ENTITY_CASE_COLLISION);
    try std.testing.expectEqualStrings("guides/intro", diags.items[0].id);
}

test "diagnoseEntityCaseCollisions ignores distinct paths" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    const found = [_]Found{
        .{ .source_path = "a.md", .entity_id = "a" },
        .{ .source_path = "b.md", .entity_id = "b" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    try diagnoseEntityCaseCollisions(gpa, retain, &found, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "discover sorts by entity_id independent of creation order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const content_rel = try std.fmt.allocPrint(gpa, "{s}/content", .{base});
    defer gpa.free(content_rel);

    try cwd.createDirPath(io, content_rel);
    {
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        // Create in reverse of expected entity_id order.
        try content.writeFile(io, .{ .sub_path = "z-last.md", .data = "---\ntitle: z\n---\n" });
        try content.writeFile(io, .{ .sub_path = "a-first.md", .data = "---\ntitle: a\n---\n" });
        try content.writeFile(io, .{ .sub_path = "m-mid.md", .data = "---\ntitle: m\n---\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var found: std.ArrayList(Found) = .empty;
    defer found.deinit(gpa);
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    try discover(io, gpa, retain, .{ .content_root = content_rel }, &found, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expectEqualStrings("a-first", found.items[0].entity_id);
    try std.testing.expectEqualStrings("m-mid", found.items[1].entity_id);
    try std.testing.expectEqualStrings("z-last", found.items[2].entity_id);
}

test "discover rejects directory symlink without following" {
    if (@import("builtin").os.tag == .windows) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const content_rel = try std.fmt.allocPrint(gpa, "{s}/content", .{base});
    defer gpa.free(content_rel);
    const real_rel = try std.fmt.allocPrint(gpa, "{s}/content/real", .{base});
    defer gpa.free(real_rel);

    try cwd.createDirPath(io, real_rel);
    {
        var real = try cwd.openDir(io, real_rel, .{});
        defer real.close(io);
        try real.writeFile(io, .{ .sub_path = "page.md", .data = "---\ntitle: page\n---\n" });
    }
    {
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        content.symLink(io, "real", "link", .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return,
            else => return err,
        };
        // Also a real page so discovery has at least one success.
        try content.writeFile(io, .{ .sub_path = "root.md", .data = "---\ntitle: root\n---\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var found: std.ArrayList(Found) = .empty;
    defer found.deinit(gpa);
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    try discover(io, gpa, retain, .{ .content_root = content_rel }, &found, &diags);

    // real/page.md discovered; linked tree not re-entered as a second root.
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    var saw_symlink = false;
    for (diags.items) |d| {
        if (d.code == .E_SYMLINK) saw_symlink = true;
    }
    try std.testing.expect(saw_symlink);
    // Must not discover the same page twice via the link.
    for (found.items) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.source_path, "link/page.md"));
    }
}

test "discover rejects page-file symlink" {
    if (@import("builtin").os.tag == .windows) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const content_rel = try std.fmt.allocPrint(gpa, "{s}/content", .{base});
    defer gpa.free(content_rel);

    try cwd.createDirPath(io, content_rel);
    {
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "real.md", .data = "---\ntitle: real\n---\n" });
        content.symLink(io, "real.md", "alias.md", .{}) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return,
            else => return err,
        };
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var found: std.ArrayList(Found) = .empty;
    defer found.deinit(gpa);
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    try discover(io, gpa, retain, .{ .content_root = content_rel }, &found, &diags);

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings("real", found.items[0].entity_id);
    var saw_symlink = false;
    for (diags.items) |d| {
        if (d.code == .E_SYMLINK) saw_symlink = true;
    }
    try std.testing.expect(saw_symlink);
}

test "discover detects symlink directory cycle without hanging" {
    // Skip on Windows: creating POSIX-style directory symlink cycles is awkward
    // in the test harness; the visited-inode logic is still compiled there.
    if (@import("builtin").os.tag == .windows) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout under tmp:
    //   content/a/page.md
    //   content/a/loop -> .   (self-cycle via directory symlink)
    const cwd = Io.Dir.cwd();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);

    const content_rel = try std.fmt.allocPrint(gpa, "{s}/content", .{base});
    defer gpa.free(content_rel);
    const a_rel = try std.fmt.allocPrint(gpa, "{s}/content/a", .{base});
    defer gpa.free(a_rel);

    try cwd.createDirPath(io, a_rel);

    {
        var a_dir = try cwd.openDir(io, a_rel, .{});
        defer a_dir.close(io);
        try a_dir.writeFile(io, .{ .sub_path = "page.md", .data = "---\ntitle: page\n---\n\nbody\n" });
        a_dir.symLink(io, ".", "loop", .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return,
            else => return err,
        };
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var found: std.ArrayList(Found) = .empty;
    defer found.deinit(gpa);
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    try discover(io, gpa, retain, .{ .content_root = content_rel }, &found, &diags);

    // Page should still be discovered; symlink dir must be diagnosed and not hang.
    try std.testing.expect(found.items.len >= 1);
    var saw_symlink_policy = false;
    for (diags.items) |d| {
        if (d.code == .E_SYMLINK or d.code == .E_SYMLINK_CYCLE) saw_symlink_policy = true;
    }
    try std.testing.expect(saw_symlink_policy);
}
