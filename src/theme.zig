//! F9.1 theme root helpers: asset inventory, collision checks, target-owned copy.
//!
//! A theme owns trusted layout files, optional `footer.html`, and opaque bytes
//! under `assets/`. Boris copies those assets into each target output; it never
//! fetches remote stylesheets. Path grammar matches the closed template plan in
//! `assemble.zig` (ASCII-only under `assets/`, no `..`, no symlinks).

const std = @import("std");
const Io = std.Io;
const assemble = @import("assemble.zig");

pub const ThemeError = error{
    ThemeRootMissing,
    ThemeSymlink,
    AssetNotFound,
    AssetSymlink,
    AssetPathEscape,
    AssetCollision,
    InvalidThemePath,
    FooterSymlink,
} || assemble.LayoutError || std.mem.Allocator.Error;

/// Derive theme root from a layout path when it ends with `…/layouts/<file>.html`.
///
/// - `experimental-theme/layouts/main.html` → `experimental-theme`
/// - `layouts/main.html` (legacy repo layout) → `null` (no managed theme assets)
/// - bare `main.html` → `null`
///
/// Returned slice is a view into `layout_path` (or a static `"."` is never used).
pub fn themeRootFromLayoutPath(layout_path: []const u8) ?[]const u8 {
    if (layout_path.len == 0) return null;
    // Normalize only for matching; do not allocate.
    const layouts_marker = "/layouts/";
    if (std.mem.indexOf(u8, layout_path, layouts_marker)) |idx| {
        // Require a file name after layouts/ (no trailing slash alone).
        const after = layout_path[idx + layouts_marker.len ..];
        if (after.len == 0 or std.mem.indexOfScalar(u8, after, '/') != null) return null;
        if (idx == 0) return null; // "/layouts/x" absolute-ish
        return layout_path[0..idx];
    }
    // Leading `layouts/file` without parent → legacy default, no theme root.
    if (std.mem.startsWith(u8, layout_path, "layouts/")) {
        const after = layout_path["layouts/".len..];
        if (after.len > 0 and std.mem.indexOfScalar(u8, after, '/') == null) {
            return null;
        }
    }
    return null;
}

/// True when `path` is a single relative theme root segment list without escape.
pub fn validateThemeRootPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidThemePath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidThemePath;
    if (path.len >= 2 and path[1] == ':') return error.InvalidThemePath;
    var start: usize = 0;
    while (start <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const seg = path[start..slash];
        if (seg.len == 0) return error.InvalidThemePath;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidThemePath;
        if (slash >= path.len) break;
        start = slash + 1;
    }
}

/// One inventoried theme asset (theme-relative path under `assets/`).
pub const AssetEntry = struct {
    /// Theme-relative path with `/` separators (e.g. `assets/css/docs.css`).
    rel_path: []const u8,
    /// File bytes (owned by ThemeBundle gpa).
    bytes: []u8,
};

/// Loaded theme materials for one target plan.
pub const ThemeBundle = struct {
    gpa: std.mem.Allocator,
    /// Theme root path as passed (not owned), or empty when no theme.
    theme_root: []const u8 = "",
    /// Optional footer fragment bytes (owned); empty when absent.
    footer_bytes: []u8 = &.{},
    /// Sorted asset inventory (owned paths + bytes).
    assets: []AssetEntry = &.{},
    /// Deterministic fingerprint material: footer + sorted (path, bytes).
    fingerprint_material: []u8 = &.{},

    pub fn deinit(self: *ThemeBundle) void {
        if (self.footer_bytes.len > 0) self.gpa.free(self.footer_bytes);
        for (self.assets) |a| {
            self.gpa.free(a.rel_path);
            self.gpa.free(a.bytes);
        }
        if (self.assets.len > 0) self.gpa.free(self.assets);
        if (self.fingerprint_material.len > 0) self.gpa.free(self.fingerprint_material);
        self.* = undefined;
    }

    pub fn footer(self: *const ThemeBundle) []const u8 {
        return self.footer_bytes;
    }

    /// Bytes for a theme-relative asset path, or null when not inventoried.
    pub fn assetBytes(self: *const ThemeBundle, rel_path: []const u8) ?[]const u8 {
        for (self.assets) |a| {
            if (std.mem.eql(u8, a.rel_path, rel_path)) return a.bytes;
        }
        return null;
    }
};

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

fn rejectIfSymlink(io: Io, dir: Io.Dir, rel: []const u8) !void {
    const st = dir.statFile(io, rel, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (st.kind == .sym_link) return error.ThemeSymlink;
}

/// Load optional footer + full `assets/` tree for `theme_root`.
/// When `theme_root` is empty, returns an empty bundle (legacy layouts).
pub fn loadThemeBundle(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    theme_root: []const u8,
) !ThemeBundle {
    var bundle: ThemeBundle = .{ .gpa = gpa, .theme_root = theme_root };
    errdefer bundle.deinit();

    if (theme_root.len == 0) {
        bundle.fingerprint_material = try buildFingerprintMaterial(gpa, &.{}, &.{});
        return bundle;
    }

    try validateThemeRootPath(theme_root);
    try rejectIfSymlink(io, cwd, theme_root);

    // Footer (optional)
    const footer_rel = try std.fmt.allocPrint(gpa, "{s}/footer.html", .{theme_root});
    defer gpa.free(footer_rel);
    if (cwd.statFile(io, footer_rel, .{ .follow_symlinks = false })) |st| {
        if (st.kind == .sym_link) return error.FooterSymlink;
        if (st.kind == .file) {
            bundle.footer_bytes = try readFileAlloc(io, cwd, footer_rel, gpa);
        }
    } else |_| {}

    // Assets directory (optional when layout has no asset-url; still inventory if present)
    const assets_root = try std.fmt.allocPrint(gpa, "{s}/assets", .{theme_root});
    defer gpa.free(assets_root);

    if (cwd.statFile(io, assets_root, .{ .follow_symlinks = false })) |st| {
        if (st.kind == .sym_link) return error.AssetSymlink;
        if (st.kind != .directory) return error.InvalidThemePath;

        var assets_dir = try cwd.openDir(io, assets_root, .{ .iterate = true });
        defer assets_dir.close(io);

        var list: std.ArrayList(AssetEntry) = .empty;
        errdefer {
            for (list.items) |a| {
                gpa.free(a.rel_path);
                gpa.free(a.bytes);
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

            // entry.path is relative to assets/; prefix with assets/
            const rel = try std.fmt.allocPrint(gpa, "assets/{s}", .{entry.path});
            errdefer gpa.free(rel);
            // Normalize backslashes if any
            for (rel) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            try assemble.validateAssetUrlPath(rel);

            // Reject symlink along progressive path under theme root
            const full_under_theme = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ theme_root, rel });
            defer gpa.free(full_under_theme);
            try rejectSymlinkAlongRel(io, cwd, full_under_theme);

            const bytes = try readFileAlloc(io, cwd, full_under_theme, gpa);
            errdefer gpa.free(bytes);
            try list.append(gpa, .{ .rel_path = rel, .bytes = bytes });
        }

        std.mem.sort(AssetEntry, list.items, {}, struct {
            fn less(_: void, a: AssetEntry, b: AssetEntry) bool {
                return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
            }
        }.less);

        bundle.assets = try list.toOwnedSlice(gpa);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }

    bundle.fingerprint_material = try buildFingerprintMaterial(gpa, bundle.footer_bytes, bundle.assets);
    return bundle;
}

fn rejectSymlinkAlongRel(io: Io, cwd: Io.Dir, rel_path: []const u8) !void {
    var start: usize = 0;
    while (start < rel_path.len) {
        if (rel_path[start] == '/') {
            start += 1;
            continue;
        }
        const slash = std.mem.indexOfScalarPos(u8, rel_path, start, '/') orelse rel_path.len;
        const progressive = rel_path[0..slash];
        if (progressive.len > 0) {
            if (cwd.statFile(io, progressive, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link) return error.AssetSymlink;
            } else |_| {}
        }
        if (slash >= rel_path.len) break;
        start = slash + 1;
    }
}

fn buildFingerprintMaterial(
    gpa: std.mem.Allocator,
    footer_bytes: []const u8,
    assets: []const AssetEntry,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    // footer\0 then each path\0 bytes with length-delimited stability via explicit lens
    try appendLenPrefixed(&buf, gpa, footer_bytes);
    for (assets) |a| {
        try appendLenPrefixed(&buf, gpa, a.rel_path);
        try appendLenPrefixed(&buf, gpa, a.bytes);
    }
    return try buf.toOwnedSlice(gpa);
}

fn appendLenPrefixed(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .little);
    try buf.appendSlice(gpa, &len_buf);
    try buf.appendSlice(gpa, bytes);
}

/// Fingerprint material for pages that use footer and/or asset-url slots.
/// Unreferenced inventory changes do not dirty HTML. Empty result when neither
/// footer nor referenced assets are requested (preserves legacy digests).
pub fn referencedAssetMaterial(
    gpa: std.mem.Allocator,
    bundle: *const ThemeBundle,
    referenced_paths: []const []const u8,
    include_footer: bool,
) ![]u8 {
    if (!include_footer and referenced_paths.len == 0) return try gpa.dupe(u8, "");

    // Unique + sort referenced paths
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    for (referenced_paths) |p| {
        var found = false;
        for (list.items) |e| {
            if (std.mem.eql(u8, e, p)) {
                found = true;
                break;
            }
        }
        if (!found) try list.append(gpa, p);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    if (include_footer) {
        try appendLenPrefixed(&buf, gpa, bundle.footer_bytes);
    }
    for (list.items) |p| {
        const bytes = bundle.assetBytes(p) orelse return error.AssetNotFound;
        try appendLenPrefixed(&buf, gpa, p);
        try appendLenPrefixed(&buf, gpa, bytes);
    }
    return try buf.toOwnedSlice(gpa);
}

/// Ensure every layout-referenced asset path exists in the bundle.
pub fn requireReferencedAssets(bundle: *const ThemeBundle, referenced_paths: []const []const u8) !void {
    for (referenced_paths) |p| {
        try assemble.validateAssetUrlPath(p);
        if (bundle.assetBytes(p) == null) return error.AssetNotFound;
    }
}

/// Fail when any page output path equals a theme asset path (preflight).
pub fn checkAssetPageCollisions(
    assets: []const AssetEntry,
    page_output_paths: []const []const u8,
) !void {
    for (assets) |a| {
        for (page_output_paths) |out| {
            if (std.mem.eql(u8, a.rel_path, out)) return error.AssetCollision;
        }
    }
}

/// Copy inventoried assets into `out_dir` preserving theme-relative paths.
/// Deterministic order (already sorted). Overwrites existing files in place.
pub fn copyAssetsToOutput(
    io: Io,
    out_dir: Io.Dir,
    assets: []const AssetEntry,
) !void {
    for (assets) |a| {
        if (std.fs.path.dirname(a.rel_path)) |parent| {
            if (parent.len > 0) {
                try out_dir.createDirPath(io, parent);
            }
        }
        try out_dir.writeFile(io, .{ .sub_path = a.rel_path, .data = a.bytes });
    }
}

// =============================================================================
// Tests
// =============================================================================

test "themeRootFromLayoutPath derives parent of layouts/" {
    try std.testing.expectEqualStrings(
        "experimental-theme",
        themeRootFromLayoutPath("experimental-theme/layouts/main.html").?,
    );
    try std.testing.expectEqualStrings(
        "themes/docs",
        themeRootFromLayoutPath("themes/docs/layouts/home.html").?,
    );
    try std.testing.expect(themeRootFromLayoutPath("layouts/main.html") == null);
    try std.testing.expect(themeRootFromLayoutPath("main.html") == null);
    try std.testing.expect(themeRootFromLayoutPath("layouts/nested/main.html") == null);
}

test "validateAssetUrlPath rejects escapes and non-ASCII" {
    try assemble.validateAssetUrlPath("assets/css/docs.css");
    try std.testing.expectError(error.InvalidAssetUrl, assemble.validateAssetUrlPath("../assets/x.css"));
    try std.testing.expectError(error.InvalidAssetUrl, assemble.validateAssetUrlPath("assets/../x.css"));
    try std.testing.expectError(error.InvalidAssetUrl, assemble.validateAssetUrlPath("assets/foo bar.css"));
    try std.testing.expectError(error.InvalidAssetUrl, assemble.validateAssetUrlPath("assets/caf\xc3\xa9.css"));
}

test "loadThemeBundle and copy with collision detection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-theme-copy", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const assets_css = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css", .{work});
    defer gpa.free(assets_css);
    try cwd.createDirPath(io, assets_css);

    const css_path = try std.fmt.allocPrint(gpa, "{s}/docs.css", .{assets_css});
    defer gpa.free(css_path);
    try cwd.writeFile(io, .{ .sub_path = css_path, .data = "body{color:red}" });

    const footer_path = try std.fmt.allocPrint(gpa, "{s}/theme/footer.html", .{work});
    defer gpa.free(footer_path);
    try cwd.writeFile(io, .{ .sub_path = footer_path, .data = "<p>foot</p>" });

    const theme_root = try std.fmt.allocPrint(gpa, "{s}/theme", .{work});
    defer gpa.free(theme_root);

    var bundle = try loadThemeBundle(io, gpa, cwd, theme_root);
    defer bundle.deinit();

    try std.testing.expectEqualStrings("<p>foot</p>", bundle.footer());
    try std.testing.expectEqual(@as(usize, 1), bundle.assets.len);
    try std.testing.expectEqualStrings("assets/css/docs.css", bundle.assets[0].rel_path);
    try std.testing.expectEqualStrings("body{color:red}", bundle.assets[0].bytes);

    try requireReferencedAssets(&bundle, &.{"assets/css/docs.css"});
    try std.testing.expectError(error.AssetNotFound, requireReferencedAssets(&bundle, &.{"assets/missing.css"}));

    try checkAssetPageCollisions(bundle.assets, &.{"index.html"});
    try std.testing.expectError(
        error.AssetCollision,
        checkAssetPageCollisions(bundle.assets, &.{"assets/css/docs.css"}),
    );

    const out_rel = try std.fmt.allocPrint(gpa, "{s}/out", .{work});
    defer gpa.free(out_rel);
    try cwd.createDirPath(io, out_rel);
    var out_dir = try cwd.openDir(io, out_rel, .{});
    defer out_dir.close(io);
    try copyAssetsToOutput(io, out_dir, bundle.assets);

    const copied = try readFileAlloc(io, out_dir, "assets/css/docs.css", gpa);
    defer gpa.free(copied);
    try std.testing.expectEqualStrings("body{color:red}", copied);

    const mat = try referencedAssetMaterial(gpa, &bundle, &.{"assets/css/docs.css"}, true);
    defer gpa.free(mat);
    try std.testing.expect(mat.len > 0);

    const empty_mat = try referencedAssetMaterial(gpa, &bundle, &.{}, false);
    defer gpa.free(empty_mat);
    try std.testing.expectEqual(@as(usize, 0), empty_mat.len);
}

test "empty theme root yields empty bundle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var bundle = try loadThemeBundle(io, gpa, cwd, "");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 0), bundle.assets.len);
    try std.testing.expectEqual(@as(usize, 0), bundle.footer().len);
}
