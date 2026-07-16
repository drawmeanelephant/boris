//! Deterministic recursive content discovery (milestone 4).
//!
//! Walks a content root once, collects the explicitly selected page family,
//! derives identity via `identity.canonicalEntityId`, and sorts results
//! before any caller processes them.
//!
//! ## Policies (see docs/contracts/scanner.md)
//!
//! - **Extensions:** default Markdown accepts lowercase `.md` / `.mdx`;
//!   explicit Textile accepts lowercase `.textile` only.
//! - **Isolation:** a recognized page from the other input family fails the
//!   scan; Boris never guesses a dialect per page.
//! - **Paths:** logical metadata uses `/` only; no host absolute paths.
//! - **Identity:** single derivation function `identity.canonicalEntityId`.
//! - **Sort key:** `entity_id` ascending, then `source_path`.
//! - **Symlinks:** do **not** follow directory symlinks; **reject** (error)
//!   directory and page-file symlinks under the content root.
//! - **Duplicates:** both pages kept when entity ids collide so later graph
//!   validation can emit a precise `EDUPLICATEID` diagnostic.
//!
//! No frontmatter parse, graph resolve, RAG, Apex, HTML render, or concurrency.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const identity = @import("identity.zig");
const page_mod = @import("page.zig");

pub const Page = page_mod.Page;
pub const PageList = page_mod.PageList;
pub const ContentKind = page_mod.ContentKind;
pub const InputFormat = identity.InputFormat;

pub const ScanError = error{
    ContentDirMissing,
    /// Symlinked directory or page file under content root (v0.1 rejects both).
    SymlinkRejected,
    /// Directory walk revisited a previously seen directory inode.
    SymlinkCycle,
    /// Path or identity cannot be represented safely.
    InvalidPath,
    /// A recognized page extension belongs to the non-selected input family.
    InputFormatMismatch,
} || std.mem.Allocator.Error || Io.Dir.OpenError || Io.Dir.SelectiveWalker.Error || Io.Dir.StatError || Io.Dir.StatFileError || identity.PathError;

/// Options for a content-root scan.
pub const Options = struct {
    /// Content root relative to process CWD (or absolute — only used to open;
    /// never stored in page logical metadata).
    content_root: []const u8 = "content",
    input_format: InputFormat = .markdown,
};

/// Composite filesystem identity for cycle detection (inode when available).
const FsIdentity = struct {
    ino: u64,

    fn fromStat(st: Io.File.Stat) FsIdentity {
        return .{ .ino = @intCast(st.inode) };
    }

    fn eql(a: FsIdentity, b: FsIdentity) bool {
        return a.ino == b.ino;
    }
};

fn identitySeen(list: []const FsIdentity, id: FsIdentity) bool {
    for (list) |v| {
        if (FsIdentity.eql(v, id)) return true;
    }
    return false;
}

/// Walk `options.content_root` and append discovered pages to `out`.
///
/// Ownership:
/// - `out.list_gpa` owns the ArrayList spine and temporary walk state.
/// - `out.retain` owns every string on each `Page`.
///
/// On success, `out.pages` is sorted by (`entity_id`, `source_path`).
/// Logical metadata never contains host absolute paths.
pub fn scan(io: Io, options: Options, out: *PageList) ScanError!void {
    const cwd = Io.Dir.cwd();
    var content_dir = cwd.openDir(io, options.content_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ContentDirMissing,
        else => return err,
    };
    defer content_dir.close(io);

    try scanDirFormat(io, content_dir, options.input_format, out);
}

/// Scan an already-open content directory handle.
pub fn scanDir(io: Io, content_dir: Io.Dir, out: *PageList) ScanError!void {
    return scanDirFormat(io, content_dir, .markdown, out);
}

/// Scan an already-open content directory using one explicit input family.
pub fn scanDirFormat(io: Io, content_dir: Io.Dir, input_format: InputFormat, out: *PageList) ScanError!void {
    const list_gpa = out.list_gpa;
    const retain = out.retain;

    var visited_dirs: std.ArrayList(FsIdentity) = .empty;
    defer visited_dirs.deinit(list_gpa);

    const root_st = try content_dir.stat(io);
    try visited_dirs.append(list_gpa, FsIdentity.fromStat(root_st));

    var walker = try content_dir.walkSelectively(list_gpa);
    defer walker.deinit();

    while (true) {
        const entry = try walker.next(io) orelse break;

        // --- Symlinks: never follow; reject under content root -------------
        if (entry.kind == .sym_link) {
            // Do not enter directory symlinks; do not register symlink pages.
            return error.SymlinkRejected;
        }

        // --- Real directories: enter once per inode ------------------------
        if (entry.kind == .directory) {
            // Fragment library for `{{include}}` — never discovered as pages.
            // Only the content-root `includes/` tree is reserved (not nested
            // `guides/includes/`).
            if (std.mem.eql(u8, entry.path, "includes")) {
                continue;
            }
            // Page sibling asset trees (`{stem}.assets/`) are inventoried by
            // content-local asset publish, not page discovery. Skip the whole
            // subtree so media-only files and asset-path policy stay out of
            // the scanner (see docs/contracts/content-local-assets.md).
            if (std.mem.endsWith(u8, entry.basename, ".assets")) {
                continue;
            }

            const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            };
            if (st.kind != .directory) continue;

            const fs_id = FsIdentity.fromStat(st);
            if (identitySeen(visited_dirs.items, fs_id)) {
                return error.SymlinkCycle;
            }
            try visited_dirs.append(list_gpa, fs_id);
            walker.enter(io, entry) catch |err| switch (err) {
                error.SymLinkLoop => return error.SymlinkCycle,
                else => return err,
            };
            continue;
        }

        if (entry.kind != .file) continue;
        // Non-page files (.txt, .MD, assets, …) are ignored. Recognized page
        // extensions from the other input family fail closed.
        if (!identity.isPageFile(entry.basename)) continue;
        const entry_kind = identity.contentKind(entry.basename) catch continue;
        if (!input_format.accepts(entry_kind)) return error.InputFormatMismatch;
        // Defense in depth if includes/ were ever entered.
        if (std.mem.eql(u8, entry.path, "includes") or std.mem.startsWith(u8, entry.path, "includes/")) {
            continue;
        }

        // Double-check: not a symlink disguised as a file entry.
        const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
            else => return err,
        };
        if (st.kind == .sym_link) return error.SymlinkRejected;
        if (st.kind != .file) continue;

        // entry.path is relative to content_dir; invalidated on next next().
        try registerPage(retain, out, entry.path);
    }

    // Deterministic order independent of filesystem enumeration.
    page_mod.sortPages(out.pages.items);
}

fn registerPage(retain: std.mem.Allocator, out: *PageList, walk_path: []const u8) ScanError!void {
    // Canonicalize first so identity derivation sees a stable form.
    const source_path = identity.canonicalize(retain, walk_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPath,
    };

    // Single centralized derivation function.
    const entity_id = identity.canonicalEntityId(retain, source_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPath,
    };

    const output_path = identity.safeOutputRelativePath(retain, entity_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPath,
    };

    const kind = identity.contentKind(source_path) catch return error.InvalidPath;

    // Note: duplicate entity_ids are intentionally kept so a later graph stage
    // can emit EDUPLICATEID with both source paths. Discovery does not mask them.
    try out.append(.{
        .source_path = source_path,
        .entity_id = entity_id,
        .output_path = output_path,
        .kind = kind,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpContentRoot(gpa: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) ![]u8 {
    const cwd = Io.Dir.cwd();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    errdefer gpa.free(base);
    const content_rel = try std.fmt.allocPrint(gpa, "{s}/content", .{base});
    errdefer gpa.free(content_rel);
    try cwd.createDirPath(io, content_rel);
    gpa.free(base);
    return content_rel;
}

test "scan: recursive fixtures/content/valid" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = "fixtures/content/valid" }, &list);

    // empty-no-fm.md, nested/deep/page.md, satellite-child.md, trunk-root.md
    try testing.expectEqual(@as(usize, 4), list.len());

    // Sorted by entity_id.
    try testing.expectEqualStrings("empty-no-fm", list.items()[0].entity_id);
    try testing.expectEqualStrings("nested/deep/page", list.items()[1].entity_id);
    try testing.expectEqualStrings("satellite-child", list.items()[2].entity_id);
    try testing.expectEqualStrings("trunk-root", list.items()[3].entity_id);

    // Logical paths only — no host absolute prefixes.
    for (list.items()) |p| {
        try testing.expect(p.source_path.len > 0);
        try testing.expect(p.source_path[0] != '/');
        try testing.expect(std.mem.indexOfScalar(u8, p.source_path, '\\') == null);
        try testing.expect(std.mem.indexOfScalar(u8, p.entity_id, '\\') == null);
        try testing.expect(std.mem.endsWith(u8, p.output_path, ".html"));
        try testing.expect(!std.mem.startsWith(u8, p.output_path, "/"));
        try testing.expect(std.mem.indexOf(u8, p.output_path, "..") == null);
    }

    try testing.expectEqualStrings("nested/deep/page.md", list.items()[1].source_path);
    try testing.expectEqualStrings("nested/deep/page.html", list.items()[1].output_path);
    try testing.expect(list.items()[1].kind == .md);
}

test "scan: recursive fixtures/content discovers nested invalid suites" {
    const gpa = testing.allocator;
    const io = testing.io;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = "fixtures/content" }, &list);
    try testing.expect(list.len() >= 4 + 10); // valid + many invalid pages

    // Deterministic: sorted by entity_id.
    var i: usize = 1;
    while (i < list.len()) : (i += 1) {
        const prev = list.items()[i - 1];
        const cur = list.items()[i];
        const ord = std.mem.order(u8, prev.entity_id, cur.entity_id);
        if (ord == .eq) {
            try testing.expect(std.mem.order(u8, prev.source_path, cur.source_path) != .gt);
        } else {
            try testing.expect(ord == .lt);
        }
    }
}

test "scan: stable sorted order independent of creation order" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    {
        const cwd = Io.Dir.cwd();
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        // Create in reverse of expected entity_id order.
        try content.writeFile(io, .{ .sub_path = "z-last.md", .data = "# z\n" });
        try content.writeFile(io, .{ .sub_path = "a-first.md", .data = "# a\n" });
        try content.writeFile(io, .{ .sub_path = "m-mid.md", .data = "# m\n" });
        try content.createDirPath(io, "nested");
        try content.writeFile(io, .{ .sub_path = "nested/z-nested.md", .data = "# nz\n" });
        try content.writeFile(io, .{ .sub_path = "nested/a-nested.md", .data = "# na\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = content_rel }, &list);
    try testing.expectEqual(@as(usize, 5), list.len());
    try testing.expectEqualStrings("a-first", list.items()[0].entity_id);
    try testing.expectEqualStrings("m-mid", list.items()[1].entity_id);
    try testing.expectEqualStrings("nested/a-nested", list.items()[2].entity_id);
    try testing.expectEqualStrings("nested/z-nested", list.items()[3].entity_id);
    try testing.expectEqualStrings("z-last", list.items()[4].entity_id);
}

test "scan: skips content-root includes/ fragment library" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    {
        const cwd = Io.Dir.cwd();
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "page.md", .data = "# page\n" });
        try content.createDirPath(io, "includes");
        try content.writeFile(io, .{ .sub_path = "includes/frag.md", .data = "fragment\n" });
        try content.createDirPath(io, "guides/includes");
        try content.writeFile(io, .{ .sub_path = "guides/includes/keep.md", .data = "# keep nested\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = content_rel }, &list);
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("guides/includes/keep", list.items()[0].entity_id);
    try testing.expectEqualStrings("page", list.items()[1].entity_id);
}

test "scan: ignores .txt and case-variant .MD extensions" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    {
        const cwd = Io.Dir.cwd();
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "keep.md", .data = "# keep\n" });
        try content.writeFile(io, .{ .sub_path = "keep.mdx", .data = "# mdx\n" });
        try content.writeFile(io, .{ .sub_path = "notes.txt", .data = "not a page\n" });
        try content.writeFile(io, .{ .sub_path = "README.MD", .data = "# wrong case\n" });
        try content.writeFile(io, .{ .sub_path = "Page.MDX", .data = "# wrong case\n" });
        try content.writeFile(io, .{ .sub_path = "notes.Md", .data = "# wrong case\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = content_rel }, &list);
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("keep", list.items()[0].entity_id);
    try testing.expect(list.items()[0].kind == .md);
    try testing.expectEqualStrings("keep", list.items()[1].entity_id);
    try testing.expect(list.items()[1].kind == .mdx);
    // Same entity_id from .md and .mdx — both retained for later EDUPLICATEID.
    try testing.expectEqualStrings("keep.md", list.items()[0].source_path);
    try testing.expectEqualStrings("keep.mdx", list.items()[1].source_path);
}

test "scan: explicit Textile mode discovers only lowercase .textile pages" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    {
        var content = try Io.Dir.cwd().openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "index.textile", .data = "h1. Home\n" });
        try content.writeFile(io, .{ .sub_path = "README.TEXTILE", .data = "h1. ignored\n" });
        try content.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = content_rel, .input_format = .textile }, &list);
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("index.textile", list.items()[0].source_path);
    try testing.expectEqualStrings("index", list.items()[0].entity_id);
    try testing.expect(list.items()[0].kind == .textile);
}

test "scan: input families fail closed instead of mixing or guessing" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    {
        var content = try Io.Dir.cwd().openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "index.textile", .data = "h1. Home\n" });
        try content.writeFile(io, .{ .sub_path = "legacy.md", .data = "# Legacy\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var markdown_list = PageList.init(gpa, arena.allocator());
    defer markdown_list.deinit();
    try testing.expectError(
        error.InputFormatMismatch,
        scan(io, .{ .content_root = content_rel }, &markdown_list),
    );

    _ = arena.reset(.free_all);
    var textile_list = PageList.init(gpa, arena.allocator());
    defer textile_list.deinit();
    try testing.expectError(
        error.InputFormatMismatch,
        scan(io, .{ .content_root = content_rel, .input_format = .textile }, &textile_list),
    );
}

test "scan: missing content root" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();
    try testing.expectError(
        error.ContentDirMissing,
        scan(io, .{ .content_root = "fixtures/content/does-not-exist-m4" }, &list),
    );
}

test "scan: rejects directory symlink without following" {
    if (builtin.os.tag == .windows) return;

    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);
    const real_rel = try std.fmt.allocPrint(gpa, "{s}/real", .{content_rel});
    defer gpa.free(real_rel);

    {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, real_rel);
        var real = try cwd.openDir(io, real_rel, .{});
        defer real.close(io);
        try real.writeFile(io, .{ .sub_path = "page.md", .data = "# page\n" });

        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        content.symLink(io, "real", "link", .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return, // skip when FS denies
            else => return err,
        };
        try content.writeFile(io, .{ .sub_path = "root.md", .data = "# root\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    // Policy: reject on symlink encounter (do not follow into link/).
    try testing.expectError(
        error.SymlinkRejected,
        scan(io, .{ .content_root = content_rel }, &list),
    );
}

test "scan: rejects page-file symlink" {
    if (builtin.os.tag == .windows) return;

    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    {
        const cwd = Io.Dir.cwd();
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "real.md", .data = "# real\n" });
        content.symLink(io, "real.md", "alias.md", .{}) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return,
            else => return err,
        };
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try testing.expectError(
        error.SymlinkRejected,
        scan(io, .{ .content_root = content_rel }, &list),
    );
}

test "scan: duplicate entity ids preserved for later diagnostics" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content_rel = try tmpContentRoot(gpa, io, &tmp);
    defer gpa.free(content_rel);

    // Two different source paths that cannot share an id without different stems —
    // use .md and .mdx with same stem (same path-derived id).
    {
        const cwd = Io.Dir.cwd();
        var content = try cwd.openDir(io, content_rel, .{});
        defer content.close(io);
        try content.writeFile(io, .{ .sub_path = "same.md", .data = "# a\n" });
        try content.writeFile(io, .{ .sub_path = "same.mdx", .data = "# b\n" });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var list = PageList.init(gpa, arena.allocator());
    defer list.deinit();

    try scan(io, .{ .content_root = content_rel }, &list);
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("same", list.items()[0].entity_id);
    try testing.expectEqualStrings("same", list.items()[1].entity_id);
    // Tie-break: source_path order.
    try testing.expectEqualStrings("same.md", list.items()[0].source_path);
    try testing.expectEqualStrings("same.mdx", list.items()[1].source_path);
}
