//! Content-local page asset publishing.
//!
//! A Markdown page may keep opaque files in an exact sibling tree:
//!
//! ```text
//! content/guides/intro.md
//! content/guides/intro.assets/diagram.svg
//! ```
//!
//! Boris discovers regular files under that tree, rewrites safe relative
//! Markdown image destinations into target-owned published URLs, and copies
//! bytes deterministically. Theme-owned `assets/` stay separate. Asset file
//! bytes are never mixed into page HTML fingerprints: an asset-only change
//! republishes the file without re-rendering page HTML.
//!
//! Normative: `docs/contracts/content-local-assets.md`.

const std = @import("std");
const Io = std.Io;
const identity = @import("identity.zig");
const include_mod = @import("include.zig");
const diag = @import("diag.zig");

pub const AssetError = error{
    AssetPath,
    AssetMissing,
    AssetSymlink,
    AssetNotFile,
    AssetCollision,
    ReadFailed,
    OutOfMemory,
};

pub const FailInfo = include_mod.FailInfo;

/// One inventoried file under a page's sibling `.assets/` tree.
pub const AssetEntry = struct {
    /// Path relative to the page asset root (e.g. `diagram.svg`, `nested/x.png`).
    within_tree: []const u8,
    /// Content-root-relative source path.
    source_rel: []const u8,
    /// Target-root-relative published path (`{entity_id}.assets/{within_tree}`).
    output_rel: []const u8,
    /// File bytes (owned by PageAssetBundle gpa).
    bytes: []u8,
};

/// Discovered sibling assets for one page.
pub const PageAssetBundle = struct {
    gpa: std.mem.Allocator,
    /// Content-root-relative page source path (view or owned — not freed here).
    source_path: []const u8 = "",
    /// Content-root-relative asset root (`guides/intro.assets`), owned when non-empty.
    source_asset_root: []const u8 = "",
    /// Entity id used for output placement (view — not freed here).
    entity_id: []const u8 = "",
    /// Sorted by `within_tree` ascending.
    entries: []AssetEntry = &.{},

    pub fn deinit(self: *PageAssetBundle) void {
        if (self.source_asset_root.len > 0) self.gpa.free(self.source_asset_root);
        for (self.entries) |e| {
            self.gpa.free(e.within_tree);
            self.gpa.free(e.source_rel);
            self.gpa.free(e.output_rel);
            self.gpa.free(e.bytes);
        }
        if (self.entries.len > 0) self.gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn findWithin(self: *const PageAssetBundle, within_tree: []const u8) ?*const AssetEntry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.within_tree, within_tree)) return e;
        }
        return null;
    }
};

/// Site-wide content-local asset inventory (parallel to PageDb order when built that way).
pub const SiteAssetInventory = struct {
    gpa: std.mem.Allocator,
    /// One bundle per page (same order as PageDb).
    pages: []PageAssetBundle = &.{},

    pub fn deinit(self: *SiteAssetInventory) void {
        for (self.pages) |*p| p.deinit();
        if (self.pages.len > 0) self.gpa.free(self.pages);
        self.* = undefined;
    }

    /// Flat list of every published content-local output path (views into bundles).
    pub fn collectOutputPaths(self: *const SiteAssetInventory, gpa: std.mem.Allocator) ![]const []const u8 {
        var n: usize = 0;
        for (self.pages) |p| n += p.entries.len;
        var out = try gpa.alloc([]const u8, n);
        var i: usize = 0;
        for (self.pages) |p| {
            for (p.entries) |e| {
                out[i] = e.output_rel;
                i += 1;
            }
        }
        return out;
    }
};

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = dir.openFile(io, path, .{}) catch return error.ReadFailed;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .unlimited) catch return error.ReadFailed;
}

/// Source-path stem with page extension stripped (`guides/intro.md` → `guides/intro`).
pub fn sourceStem(source_path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, source_path, ".mdx")) return source_path[0 .. source_path.len - 4];
    if (std.mem.endsWith(u8, source_path, ".md")) return source_path[0 .. source_path.len - 3];
    if (std.mem.endsWith(u8, source_path, ".textile")) return source_path[0 .. source_path.len - 8];
    return source_path;
}

/// Content-root-relative sibling asset root for a page source path.
pub fn assetRootForSource(source_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const stem = sourceStem(source_path);
    return try std.fmt.allocPrint(gpa, "{s}.assets", .{stem});
}

/// Target-root-relative published asset path for an entity id + within-tree path.
pub fn outputRelFor(entity_id: []const u8, within_tree: []const u8, gpa: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{s}.assets/{s}", .{ entity_id, within_tree });
}

/// Conservative ASCII path segments under a page asset tree (`A–Z a–z 0–9 . _ -` only).
pub fn validateWithinTreePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var start: usize = 0;
    while (start <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const seg = path[start..slash];
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |c| {
            const ok = (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or
                c == '.' or c == '_' or c == '-';
            if (!ok) return false;
        }
        if (slash >= path.len) break;
        start = slash + 1;
    }
    return true;
}

/// True when `dest` is a non-local URL scheme Boris does not rewrite or fetch.
pub fn isPassthroughImageDest(dest: []const u8) bool {
    if (dest.len == 0) return false;
    if (std.mem.startsWith(u8, dest, "https://")) return true;
    if (std.mem.startsWith(u8, dest, "http://")) return true;
    if (std.mem.startsWith(u8, dest, "//")) return true;
    if (std.mem.startsWith(u8, dest, "data:")) return true;
    if (std.mem.startsWith(u8, dest, "mailto:")) return true;
    return false;
}

/// Strip a single leading `./` from a relative destination.
pub fn stripDotSlash(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

/// Join content-root page directory with a relative image destination.
pub fn resolveAgainstSourceDir(source_path: []const u8, dest: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const cleaned = stripDotSlash(dest);
    const dir = std.fs.path.dirnamePosix(source_path) orelse "";
    if (dir.len == 0) return try gpa.dupe(u8, cleaned);
    return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, cleaned });
}

/// When `resolved` is under `asset_root/`, return the within-tree suffix; else null.
pub fn withinTreeOf(resolved: []const u8, asset_root: []const u8) ?[]const u8 {
    if (resolved.len <= asset_root.len + 1) return null;
    if (!std.mem.startsWith(u8, resolved, asset_root)) return null;
    if (resolved[asset_root.len] != '/') return null;
    return resolved[asset_root.len + 1 ..];
}

fn rejectSymlinkAlongRel(io: Io, dir: Io.Dir, rel_path: []const u8) !void {
    var start: usize = 0;
    while (start < rel_path.len) {
        if (rel_path[start] == '/') {
            start += 1;
            continue;
        }
        const slash = std.mem.indexOfScalarPos(u8, rel_path, start, '/') orelse rel_path.len;
        const progressive = rel_path[0..slash];
        if (progressive.len > 0) {
            if (dir.statFile(io, progressive, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link) return error.AssetSymlink;
            } else |_| {}
        }
        if (slash >= rel_path.len) break;
        start = slash + 1;
    }
}

/// Discover regular files under the exact sibling `<stem>.assets/` tree.
/// Missing asset root → empty bundle (not an error).
pub fn loadPageAssets(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    source_path: []const u8,
    entity_id: []const u8,
) !PageAssetBundle {
    var bundle: PageAssetBundle = .{
        .gpa = gpa,
        .source_path = source_path,
        .entity_id = entity_id,
    };
    errdefer bundle.deinit();

    const asset_root = try assetRootForSource(source_path, gpa);
    bundle.source_asset_root = asset_root;

    const st = content_dir.statFile(io, asset_root, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            // Keep empty root string ownership for consistent deinit; free path.
            gpa.free(bundle.source_asset_root);
            bundle.source_asset_root = "";
            return bundle;
        },
        else => |e| return e,
    };
    if (st.kind == .sym_link) return error.AssetSymlink;
    if (st.kind != .directory) return error.AssetNotFile;

    try rejectSymlinkAlongRel(io, content_dir, asset_root);

    var assets_dir = try content_dir.openDir(io, asset_root, .{ .iterate = true });
    defer assets_dir.close(io);

    var list: std.ArrayList(AssetEntry) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.within_tree);
            gpa.free(e.source_rel);
            gpa.free(e.output_rel);
            gpa.free(e.bytes);
        }
        list.deinit(gpa);
    }

    var walker = try assets_dir.walkSelectively(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind == .sym_link) return error.AssetSymlink;
        if (entry.kind != .file) continue;

        // Normalize separators from the walk.
        const within_buf = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(within_buf);
        for (within_buf) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        if (!validateWithinTreePath(within_buf)) return error.AssetPath;

        const source_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ asset_root, within_buf });
        errdefer gpa.free(source_rel);
        try rejectSymlinkAlongRel(io, content_dir, source_rel);

        // Confirm leaf is a regular file without following a final symlink.
        const leaf_st = content_dir.statFile(io, source_rel, .{ .follow_symlinks = false }) catch return error.AssetMissing;
        if (leaf_st.kind == .sym_link) return error.AssetSymlink;
        if (leaf_st.kind != .file) return error.AssetNotFile;

        const bytes = try readFileAlloc(io, content_dir, source_rel, gpa);
        errdefer gpa.free(bytes);
        const output_rel = try outputRelFor(entity_id, within_buf, gpa);
        errdefer gpa.free(output_rel);

        try list.append(gpa, .{
            .within_tree = within_buf,
            .source_rel = source_rel,
            .output_rel = output_rel,
            .bytes = bytes,
        });
    }

    std.mem.sort(AssetEntry, list.items, {}, struct {
        fn less(_: void, a: AssetEntry, b: AssetEntry) bool {
            return std.mem.order(u8, a.within_tree, b.within_tree) == .lt;
        }
    }.less);

    bundle.entries = try list.toOwnedSlice(gpa);
    return bundle;
}

/// Load sibling assets for every page (PageDb order).
pub fn loadSiteAssets(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    source_paths: []const []const u8,
    entity_ids: []const []const u8,
) !SiteAssetInventory {
    std.debug.assert(source_paths.len == entity_ids.len);
    var inv: SiteAssetInventory = .{ .gpa = gpa };
    errdefer inv.deinit();

    inv.pages = try gpa.alloc(PageAssetBundle, source_paths.len);
    // Initialize empty so partial failure can deinit cleanly.
    for (inv.pages) |*p| p.* = .{ .gpa = gpa };
    var filled: usize = 0;
    errdefer {
        // deinit only fully constructed bundles; zero out the rest.
        for (inv.pages[filled..]) |*p| p.* = .{ .gpa = gpa };
    }

    for (source_paths, entity_ids, 0..) |sp, eid, i| {
        inv.pages[i] = try loadPageAssets(io, gpa, content_dir, sp, eid);
        filled = i + 1;
    }
    return inv;
}

/// Fail when a content-local asset path collides with a page HTML path or theme asset.
pub fn checkCollisions(
    content_outputs: []const []const u8,
    page_outputs: []const []const u8,
    theme_outputs: []const []const u8,
) AssetError!void {
    for (content_outputs) |c| {
        for (page_outputs) |p| {
            if (std.mem.eql(u8, c, p)) return error.AssetCollision;
        }
        for (theme_outputs) |t| {
            if (std.mem.eql(u8, c, t)) return error.AssetCollision;
        }
    }
    // Content-local paths must also be unique across pages.
    var i: usize = 0;
    while (i < content_outputs.len) : (i += 1) {
        var j = i + 1;
        while (j < content_outputs.len) : (j += 1) {
            if (std.mem.eql(u8, content_outputs[i], content_outputs[j])) return error.AssetCollision;
        }
    }
}

/// Copy inventoried content-local assets into `out_dir` (deterministic order).
pub fn copyAssetsToOutput(io: Io, out_dir: Io.Dir, inv: *const SiteAssetInventory) !void {
    for (inv.pages) |page| {
        for (page.entries) |e| {
            if (std.fs.path.dirname(e.output_rel)) |parent| {
                if (parent.len > 0) {
                    try out_dir.createDirPath(io, parent);
                }
            }
            try out_dir.writeFile(io, .{ .sub_path = e.output_rel, .data = e.bytes });
        }
    }
}

/// True when a published relative path is under a content-local `*.assets/` tree.
pub fn isContentLocalOutputPath(rel: []const u8) bool {
    if (rel.len == 0) return false;
    var start: usize = 0;
    while (start <= rel.len) {
        const slash = std.mem.indexOfScalarPos(u8, rel, start, '/') orelse rel.len;
        const seg = rel[start..slash];
        if (std.mem.endsWith(u8, seg, ".assets")) {
            // Must have a file under the tree, not the directory alone.
            return slash < rel.len;
        }
        if (slash >= rel.len) break;
        start = slash + 1;
    }
    return false;
}

/// Remove published content-local assets that are no longer in the live inventory.
/// Theme-owned `assets/` is never touched. Errors while deleting are swallowed.
pub fn scrubOrphanContentAssets(
    io: Io,
    out_dir: Io.Dir,
    gpa: std.mem.Allocator,
    inv: *const SiteAssetInventory,
) void {
    scrubOrphanContentAssetsInner(io, out_dir, gpa, inv) catch {};
}

fn scrubOrphanContentAssetsInner(
    io: Io,
    out_dir: Io.Dir,
    gpa: std.mem.Allocator,
    inv: *const SiteAssetInventory,
) !void {
    var live: std.StringHashMapUnmanaged(void) = .{};
    defer live.deinit(gpa);
    for (inv.pages) |page| {
        for (page.entries) |e| {
            try live.put(gpa, e.output_rel, {});
        }
    }

    var orphans: std.ArrayList([]u8) = .empty;
    defer {
        for (orphans.items) |p| gpa.free(p);
        orphans.deinit(gpa);
    }

    var walker = try out_dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;

        const rel = try gpa.dupe(u8, entry.path);
        for (rel) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        if (!isContentLocalOutputPath(rel)) {
            gpa.free(rel);
            continue;
        }
        if (live.contains(rel)) {
            gpa.free(rel);
            continue;
        }
        try orphans.append(gpa, rel);
    }

    for (orphans.items) |rel| {
        out_dir.deleteFile(io, rel) catch {};
        var parent_opt = std.fs.path.dirname(rel);
        while (parent_opt) |parent| {
            if (parent.len == 0) break;
            // Stop at the `*.assets` directory root after attempting to remove it
            // when empty; never climb into unrelated trees.
            const base = std.fs.path.basenamePosix(parent);
            out_dir.deleteDir(io, parent) catch break;
            if (std.mem.endsWith(u8, base, ".assets")) break;
            parent_opt = std.fs.path.dirname(parent);
        }
    }
}

// ---------------------------------------------------------------------------
// Markdown image rewrite (pre-Apex, fence-aware)
// ---------------------------------------------------------------------------

fn atLineStart(body: []const u8, i: usize) bool {
    if (i == 0) return true;
    return body[i - 1] == '\n';
}

fn lineEndIndex(body: []const u8, i: usize) usize {
    var j = i;
    while (j < body.len and body[j] != '\n') : (j += 1) {}
    return j;
}

fn fenceAtLineStart(body: []const u8, i: usize) ?struct { u8, usize } {
    if (i >= body.len) return null;
    const ch = body[i];
    if (ch != '`' and ch != '~') return null;
    var run: usize = 0;
    var j = i;
    while (j < body.len and body[j] == ch) : (j += 1) run += 1;
    if (run < 3) return null;
    return .{ ch, run };
}

const ImageHit = struct {
    /// Destination slice view into body (inside the parens, not including titles).
    dest: []const u8,
    dest_start: usize,
    dest_end: usize,
    /// Full `![...](...)` span.
    offset: usize,
    end: usize,
    line: u32,
    column: u32,
    /// True when dest was written as `<path>`.
    angle: bool,
};

fn setFail(fail_out: ?*FailInfo, body: []const u8, offset: usize, detail: []const u8, locus: []const u8) void {
    if (fail_out) |f| {
        f.setAt(body, offset, detail, locus);
    }
}

/// Scan for inline Markdown images outside fenced code. Views into `body`.
fn scanImages(
    body: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ImageHit),
) !void {
    var i: usize = 0;
    var fence_ch: u8 = 0;
    var fence_run: usize = 0;

    while (i < body.len) {
        if (atLineStart(body, i)) {
            if (fenceAtLineStart(body, i)) |f| {
                const ch = f[0];
                const run = f[1];
                if (fence_ch == 0) {
                    fence_ch = ch;
                    fence_run = run;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                } else if (ch == fence_ch and run >= fence_run) {
                    fence_ch = 0;
                    fence_run = 0;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                }
            }
        }

        if (fence_ch != 0) {
            i += 1;
            continue;
        }

        if (i + 2 < body.len and body[i] == '!' and body[i + 1] == '[') {
            const start = i;
            i += 2;
            // Alt text with balanced brackets.
            var depth: usize = 1;
            while (i < body.len and depth > 0) {
                if (body[i] == '\\' and i + 1 < body.len) {
                    i += 2;
                    continue;
                }
                if (body[i] == '[') depth += 1;
                if (body[i] == ']') depth -= 1;
                i += 1;
            }
            if (depth != 0) {
                // Unclosed alt — leave literal, continue after '!'.
                i = start + 1;
                continue;
            }
            if (i >= body.len or body[i] != '(') {
                // Reference-style or not an image link — leave literal.
                continue;
            }
            i += 1; // past '('
            while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n')) : (i += 1) {}
            if (i >= body.len) continue;

            var angle = false;
            var dest_start: usize = i;
            var dest_end: usize = i;
            if (body[i] == '<') {
                angle = true;
                i += 1;
                dest_start = i;
                while (i < body.len and body[i] != '>') : (i += 1) {
                    if (body[i] == '\n') break;
                }
                if (i >= body.len or body[i] != '>') {
                    i = start + 1;
                    continue;
                }
                dest_end = i;
                i += 1; // past '>'
            } else {
                while (i < body.len) : (i += 1) {
                    const c = body[i];
                    if (c == ')' or c == ' ' or c == '\t' or c == '\n' or c == '"') break;
                }
                dest_end = i;
            }

            // Optional title then closing paren.
            while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n')) : (i += 1) {}
            if (i < body.len and (body[i] == '"' or body[i] == '\'')) {
                const q = body[i];
                i += 1;
                while (i < body.len and body[i] != q) : (i += 1) {
                    if (body[i] == '\\' and i + 1 < body.len) i += 1;
                }
                if (i < body.len and body[i] == q) i += 1;
                while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n')) : (i += 1) {}
            }
            if (i >= body.len or body[i] != ')') {
                i = start + 1;
                continue;
            }
            i += 1; // past ')'

            const dest = body[dest_start..dest_end];
            if (dest.len == 0) {
                // Empty dest — leave for Apex / later validation if local.
                continue;
            }
            const lc = include_mod.lineColAt(body, start);
            try out.append(allocator, .{
                .dest = dest,
                .dest_start = dest_start,
                .dest_end = dest_end,
                .offset = start,
                .end = i,
                .line = lc.line,
                .column = lc.column,
                .angle = angle,
            });
            continue;
        }
        i += 1;
    }
}

/// Rewrite safe local Markdown image destinations for one page.
///
/// Passthrough schemes (`http(s)`, `//`, `data:`, `mailto:`) are left unchanged.
/// Every other destination must resolve into this page's sibling asset tree and
/// exist as a regular inventoried file. Returns a new body (arena/allocator owned).
pub fn rewriteImageLinks(
    allocator: std.mem.Allocator,
    body: []const u8,
    bundle: *const PageAssetBundle,
    output_path: []const u8,
    fail_out: ?*FailInfo,
) AssetError![]const u8 {
    var hits: std.ArrayList(ImageHit) = .empty;
    defer hits.deinit(allocator);
    try scanImages(body, allocator, &hits);
    if (hits.items.len == 0) return body;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, body.len + 64);

    var cursor: usize = 0;
    for (hits.items) |hit| {
        try out.appendSlice(allocator, body[cursor..hit.dest_start]);

        if (isPassthroughImageDest(hit.dest)) {
            try out.appendSlice(allocator, hit.dest);
            cursor = hit.dest_end;
            continue;
        }

        // Local relative only from here.
        if (std.mem.indexOfScalar(u8, hit.dest, '\\') != null) {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetPath;
        }
        if (hit.dest[0] == '/' or (hit.dest.len >= 2 and hit.dest[1] == ':')) {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetPath;
        }
        // Reject any `..` or empty segments before resolve.
        {
            var start: usize = 0;
            const cleaned = stripDotSlash(hit.dest);
            if (cleaned.len == 0) {
                setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
                return error.AssetPath;
            }
            while (start <= cleaned.len) {
                const slash = std.mem.indexOfScalarPos(u8, cleaned, start, '/') orelse cleaned.len;
                const seg = cleaned[start..slash];
                if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                    setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
                    return error.AssetPath;
                }
                if (slash >= cleaned.len) break;
                start = slash + 1;
            }
        }

        if (bundle.source_asset_root.len == 0) {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetMissing;
        }

        const resolved = try resolveAgainstSourceDir(bundle.source_path, hit.dest, allocator);
        defer allocator.free(resolved);

        const within = withinTreeOf(resolved, bundle.source_asset_root) orelse {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetPath;
        };
        if (!validateWithinTreePath(within)) {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetPath;
        }

        const entry = bundle.findWithin(within) orelse {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetMissing;
        };

        const href = identity.relativeHref(allocator, output_path, entry.output_rel) catch {
            setFail(fail_out, body, hit.offset, hit.dest, bundle.source_path);
            return error.AssetPath;
        };
        defer allocator.free(href);

        if (hit.angle) {
            // Preserve angle-bracket form when the author used it.
            // Our href is always a safe relative path without spaces.
            try out.appendSlice(allocator, href);
        } else {
            try out.appendSlice(allocator, href);
        }
        cursor = hit.dest_end;
    }
    try out.appendSlice(allocator, body[cursor..]);
    return try out.toOwnedSlice(allocator);
}

pub fn printDiagnostic(gpa: std.mem.Allocator, err: AssetError, source_path: []const u8, fail: FailInfo) void {
    const code: diag.Code = switch (err) {
        error.AssetPath => .EASSET,
        error.AssetMissing => .EASSET,
        error.AssetSymlink => .EASSET,
        error.AssetNotFile => .EASSET,
        error.AssetCollision => .EASSET,
        else => .EIO,
    };
    const message: []const u8 = switch (err) {
        error.AssetPath => "invalid or out-of-tree content-local image path",
        error.AssetMissing => "content-local image asset not found in page sibling tree",
        error.AssetSymlink => "content-local asset path rejects symlinks",
        error.AssetNotFile => "content-local asset must be a regular file",
        error.AssetCollision => "content-local asset path collides with page or theme output",
        else => "content-local asset I/O failure",
    };
    const remediation: []const u8 = switch (err) {
        error.AssetPath => "Use a relative path under this page's <stem>.assets/ tree; no absolute paths, .., or backslashes",
        error.AssetMissing => "Place the file under the page's sibling <stem>.assets/ directory",
        error.AssetSymlink => "Replace symlinks with regular files under <stem>.assets/",
        error.AssetNotFile => "Publish only regular files under <stem>.assets/",
        error.AssetCollision => "Rename the asset or page so published paths do not collide",
        else => "Check content-local asset files are readable regular files",
    };
    const locus = if (fail.locus().len > 0) fail.locus() else source_path;
    const detail = fail.detail();
    const msg = if (detail.len > 0)
        std.fmt.allocPrint(gpa, "{s}: {s}", .{ message, detail }) catch message
    else
        message;
    defer if (detail.len > 0 and msg.ptr != message.ptr) gpa.free(msg);

    const d = diag.Diagnostic{
        .severity = .error_,
        .code = code,
        .message = msg,
        .remediation = remediation,
        .source_path = locus,
        .line = fail.line,
        .column = fail.column,
    };
    if (diag.formatText(d, gpa)) |line| {
        defer gpa.free(line);
        std.debug.print("{s}\n", .{line});
    } else |_| {
        std.debug.print("error: {s}: {s}\n", .{ code.name(), message });
    }
}

// =============================================================================
// Tests
// =============================================================================

fn writeTreeFile(io: Io, root: []const u8, rel: []const u8, data: []const u8) !void {
    const gpa = std.testing.allocator;
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel });
    defer gpa.free(path);
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        try cwd.createDirPath(io, parent);
    }
    try cwd.writeFile(io, .{ .sub_path = path, .data = data });
}

test "sourceStem and assetRootForSource" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("guides/intro", sourceStem("guides/intro.md"));
    try std.testing.expectEqualStrings("a/b", sourceStem("a/b.mdx"));
    const root = try assetRootForSource("guides/intro.md", gpa);
    defer gpa.free(root);
    try std.testing.expectEqualStrings("guides/intro.assets", root);
}

test "validateWithinTreePath rejects traversal and backslash" {
    try std.testing.expect(validateWithinTreePath("diagram.svg"));
    try std.testing.expect(validateWithinTreePath("nested/x.png"));
    try std.testing.expect(!validateWithinTreePath("../x.svg"));
    try std.testing.expect(!validateWithinTreePath("a/../b.svg"));
    try std.testing.expect(!validateWithinTreePath("a\\b.svg"));
    try std.testing.expect(!validateWithinTreePath("/abs.svg"));
    try std.testing.expect(!validateWithinTreePath("has space.svg"));
}

test "isPassthroughImageDest" {
    try std.testing.expect(isPassthroughImageDest("https://example.com/x.png"));
    try std.testing.expect(isPassthroughImageDest("http://example.com/x.png"));
    try std.testing.expect(isPassthroughImageDest("//cdn/x.png"));
    try std.testing.expect(isPassthroughImageDest("data:image/png;base64,xx"));
    try std.testing.expect(!isPassthroughImageDest("intro.assets/x.svg"));
    try std.testing.expect(!isPassthroughImageDest("/abs.svg"));
}

test "isContentLocalOutputPath" {
    try std.testing.expect(isContentLocalOutputPath("guides/intro.assets/diagram.svg"));
    try std.testing.expect(isContentLocalOutputPath("index.assets/x.png"));
    try std.testing.expect(!isContentLocalOutputPath("assets/css/docs.css"));
    try std.testing.expect(!isContentLocalOutputPath("guides/intro.html"));
    try std.testing.expect(!isContentLocalOutputPath("guides/intro.assets"));
}

test "loadPageAssets discovers nested files sorted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ca-discover", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md", "# hi\n");
    try writeTreeFile(io, work, "content/guides/intro.assets/z.svg", "z");
    try writeTreeFile(io, work, "content/guides/intro.assets/nested/a.png", "a");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    var content_dir = try cwd.openDir(io, content_path, .{});
    defer content_dir.close(io);

    var bundle = try loadPageAssets(io, gpa, content_dir, "guides/intro.md", "guides/intro");
    defer bundle.deinit();

    try std.testing.expectEqual(@as(usize, 2), bundle.entries.len);
    try std.testing.expectEqualStrings("nested/a.png", bundle.entries[0].within_tree);
    try std.testing.expectEqualStrings("z.svg", bundle.entries[1].within_tree);
    try std.testing.expectEqualStrings("guides/intro.assets/z.svg", bundle.entries[1].source_rel);
    try std.testing.expectEqualStrings("guides/intro.assets/z.svg", bundle.entries[1].output_rel);
}

test "rewriteImageLinks rewrites sibling asset and leaves remote" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ca-rewrite", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md", "x");
    try writeTreeFile(io, work, "content/guides/intro.assets/diagram.svg", "<svg/>");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    var content_dir = try cwd.openDir(io, content_path, .{});
    defer content_dir.close(io);

    var bundle = try loadPageAssets(io, gpa, content_dir, "guides/intro.md", "guides/intro");
    defer bundle.deinit();

    const body =
        \\![d](intro.assets/diagram.svg)
        \\
        \\![r](https://example.com/r.png)
        \\
    ;
    const out = try rewriteImageLinks(gpa, body, &bundle, "guides/intro.html", null);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "intro.assets/diagram.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/r.png") != null);
}

test "rewriteImageLinks rejects traversal absolute backslash and outside tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ca-reject", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md", "x");
    try writeTreeFile(io, work, "content/guides/intro.assets/ok.svg", "ok");
    try writeTreeFile(io, work, "content/guides/secret.png", "nope");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    var content_dir = try cwd.openDir(io, content_path, .{});
    defer content_dir.close(io);

    var bundle = try loadPageAssets(io, gpa, content_dir, "guides/intro.md", "guides/intro");
    defer bundle.deinit();

    try std.testing.expectError(error.AssetPath, rewriteImageLinks(gpa, "![x](../secret.png)\n", &bundle, "guides/intro.html", null));
    try std.testing.expectError(error.AssetPath, rewriteImageLinks(gpa, "![x](/abs.svg)\n", &bundle, "guides/intro.html", null));
    try std.testing.expectError(error.AssetPath, rewriteImageLinks(gpa, "![x](intro.assets\\ok.svg)\n", &bundle, "guides/intro.html", null));
    try std.testing.expectError(error.AssetPath, rewriteImageLinks(gpa, "![x](other.assets/ok.svg)\n", &bundle, "guides/intro.html", null));
    try std.testing.expectError(error.AssetMissing, rewriteImageLinks(gpa, "![x](intro.assets/missing.svg)\n", &bundle, "guides/intro.html", null));
}

test "rewrite skips fenced image-looking text" {
    const gpa = std.testing.allocator;
    var bundle: PageAssetBundle = .{ .gpa = gpa, .source_path = "guides/intro.md", .entity_id = "guides/intro" };
    defer bundle.deinit();
    const body =
        \\```
        \\![x](../escape.svg)
        \\```
        \\
    ;
    const out = try rewriteImageLinks(gpa, body, &bundle, "guides/intro.html", null);
    // body unchanged (same slice or equal)
    try std.testing.expectEqualStrings(body, out);
}

test "copyAssetsToOutput and scrub orphans" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ca-copy-scrub", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md", "# h\n");
    try writeTreeFile(io, work, "content/index.assets/keep.svg", "keep-v1");
    try writeTreeFile(io, work, "content/index.assets/drop.svg", "drop");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    var content_dir = try cwd.openDir(io, content_path, .{});
    defer content_dir.close(io);

    var inv = try loadSiteAssets(io, gpa, content_dir, &.{"index.md"}, &.{"index"});
    defer inv.deinit();

    const out_rel = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(out_rel);
    try cwd.createDirPath(io, out_rel);
    var out_dir = try cwd.openDir(io, out_rel, .{ .iterate = true });
    defer out_dir.close(io);

    try copyAssetsToOutput(io, out_dir, &inv);
    // Stale file from a previous publish
    try out_dir.writeFile(io, .{ .sub_path = "index.assets/stale.svg", .data = "old" });
    // Theme asset must not be scrubbed
    try out_dir.createDirPath(io, "assets/css");
    try out_dir.writeFile(io, .{ .sub_path = "assets/css/docs.css", .data = "theme" });

    // Remove drop.svg from source and reload
    const drop_src = try std.fmt.allocPrint(gpa, "{s}/content/index.assets/drop.svg", .{work});
    defer gpa.free(drop_src);
    try cwd.deleteFile(io, drop_src);

    inv.deinit();
    inv = try loadSiteAssets(io, gpa, content_dir, &.{"index.md"}, &.{"index"});

    try copyAssetsToOutput(io, out_dir, &inv);
    scrubOrphanContentAssets(io, out_dir, gpa, &inv);

    const keep = try readFileAlloc(io, out_dir, "index.assets/keep.svg", gpa);
    defer gpa.free(keep);
    try std.testing.expectEqualStrings("keep-v1", keep);
    try std.testing.expectError(error.FileNotFound, out_dir.access(io, "index.assets/drop.svg", .{}));
    try std.testing.expectError(error.FileNotFound, out_dir.access(io, "index.assets/stale.svg", .{}));
    const theme = try readFileAlloc(io, out_dir, "assets/css/docs.css", gpa);
    defer gpa.free(theme);
    try std.testing.expectEqualStrings("theme", theme);
}

test "checkCollisions detects page and theme clashes" {
    try std.testing.expectError(
        error.AssetCollision,
        checkCollisions(&.{"index.assets/x.svg"}, &.{"index.assets/x.svg"}, &.{}),
    );
    try std.testing.expectError(
        error.AssetCollision,
        checkCollisions(&.{"assets/css/docs.css"}, &.{}, &.{"assets/css/docs.css"}),
    );
    try checkCollisions(&.{"index.assets/x.svg"}, &.{"index.html"}, &.{"assets/css/docs.css"});
}

test "id override rewrites to entity-scoped asset URL" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ca-id", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md", "x");
    try writeTreeFile(io, work, "content/guides/intro.assets/d.svg", "d");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    var content_dir = try cwd.openDir(io, content_path, .{});
    defer content_dir.close(io);

    var bundle = try loadPageAssets(io, gpa, content_dir, "guides/intro.md", "custom");
    defer bundle.deinit();
    try std.testing.expectEqualStrings("custom.assets/d.svg", bundle.entries[0].output_rel);

    const out = try rewriteImageLinks(gpa, "![d](intro.assets/d.svg)\n", &bundle, "custom.html", null);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "custom.assets/d.svg") != null);
}
