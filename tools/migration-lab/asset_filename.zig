//! Asset filename compatibility laboratory.
//!
//! Boris core content-local assets accept only ASCII path segments
//! `[A-Za-z0-9._-]+` (see `docs/contracts/content-local-assets.md`). Real
//! Astro/Starlight trees often use spaces, Unicode, or percent-encoded names.
//!
//! This lab (not the product compiler):
//! - invents a Boris-safe destination name for each source asset under
//!   sibling `{stem}.assets/` trees
//! - rewrites Markdown image/link destinations to the sanitized path
//! - records original path, destination, reason, and SHA-256
//! - never mutates the source tree; never fetches remotes; never runs JS
//! - never silently overwrites on destination collision
//!
//! Format id: boris-asset-filename-lab · schema 1

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-asset-filename-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const Options = struct {
    /// Source content tree root (read-only). May be a `content/` dir or a parent
    /// that contains `content/`.
    root_dir: []const u8,
    /// Output directory (must differ from root). Receives sanitized `content/`,
    /// manifests, and reports.
    out_dir: []const u8,
    quiet: bool = false,
};

pub const LabError = error{
    OutputInsideSource,
    SourceNotFound,
    OutOfMemory,
    IoFailure,
    Collision,
};

// ---------------------------------------------------------------------------
// Path grammar (mirrors Boris core; do not import src/)
// ---------------------------------------------------------------------------

/// True when `path` is a within-tree asset path Boris would accept.
pub fn isBorisSafeWithinTree(path: []const u8) bool {
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

fn isSafeChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-';
}

fn hexNibble(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Decode `%XX` sequences in a path segment; leaves invalid sequences literal.
pub fn urlDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexNibble(input[i + 1]);
            const lo = hexNibble(input[i + 2]);
            if (hi != null and lo != null) {
                try out.append(allocator, (hi.? << 4) | lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// Classify why a within-tree path is not Boris-safe (deterministic priority).
pub fn unsafeReason(path: []const u8) []const u8 {
    if (path.len == 0) return "empty";
    if (path[0] == '/' or path[0] == '\\') return "absolute";
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return "backslash";

    var start: usize = 0;
    var has_space = false;
    var has_percent = false;
    var has_unicode = false;
    var has_other = false;
    var has_dotdot = false;

    while (start <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const seg = path[start..slash];
        if (seg.len == 0) return "empty_segment";
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
            has_dotdot = true;
        } else {
            for (seg) |c| {
                if (isSafeChar(c)) continue;
                if (c == ' ' or c == '\t') {
                    has_space = true;
                } else if (c == '%') {
                    has_percent = true;
                } else if (c >= 0x80) {
                    has_unicode = true;
                } else {
                    has_other = true;
                }
            }
        }
        if (slash >= path.len) break;
        start = slash + 1;
    }

    if (has_dotdot) return "traversal";
    if (has_space) return "spaces";
    if (has_percent) return "percent_encoding";
    if (has_unicode) return "unicode";
    if (has_other) return "unsafe_chars";
    return "unsafe";
}

/// Sanitize one path segment into Boris-safe form (preserves extension dots).
/// URL-decodes first so `diagram%20copy` becomes `diagram-copy`.
pub fn sanitizeSegment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    const decoded = try urlDecodeAlloc(allocator, segment);
    defer allocator.free(decoded);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try raw.ensureTotalCapacity(allocator, decoded.len);

    var prev_dash = false;
    for (decoded) |c| {
        if (isSafeChar(c)) {
            try raw.append(allocator, c);
            prev_dash = c == '-';
        } else {
            // spaces, unicode, punctuation → single dash boundary
            if (!prev_dash and raw.items.len > 0) {
                try raw.append(allocator, '-');
                prev_dash = true;
            }
        }
    }
    // Drop dashes adjacent to dots: "caf-.png" → "caf.png"
    var cleaned: std.ArrayList(u8) = .empty;
    errdefer cleaned.deinit(allocator);
    for (raw.items, 0..) |c, i| {
        if (c == '-') {
            const prev = if (i > 0) raw.items[i - 1] else 0;
            const next = if (i + 1 < raw.items.len) raw.items[i + 1] else 0;
            if (prev == '.' or next == '.') continue;
            if (cleaned.items.len == 0) continue;
        }
        try cleaned.append(allocator, c);
    }
    while (cleaned.items.len > 0 and cleaned.items[cleaned.items.len - 1] == '-') {
        _ = cleaned.pop();
    }
    if (cleaned.items.len == 0) {
        try cleaned.appendSlice(allocator, "asset");
    }
    if (std.mem.eql(u8, cleaned.items, ".") or std.mem.eql(u8, cleaned.items, "..")) {
        cleaned.clearRetainingCapacity();
        try cleaned.appendSlice(allocator, "asset");
    }
    return try cleaned.toOwnedSlice(allocator);
}

/// Sanitize a within-tree path, preserving nested directory structure.
pub fn sanitizeWithinTree(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return try allocator.dupe(u8, "asset");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var start: usize = 0;
    var first = true;
    while (start <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const seg = path[start..slash];
        // Traversal / empty segments: fold to "asset" rather than emit `..`
        const use_seg = if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, ".."))
            "asset"
        else
            seg;
        const clean = try sanitizeSegment(allocator, use_seg);
        defer allocator.free(clean);
        if (!first) try out.append(allocator, '/');
        try out.appendSlice(allocator, clean);
        first = false;
        if (slash >= path.len) break;
        start = slash + 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// ASCII lowercase for case-insensitive collision keys.
pub fn asciiLowerAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Inventory types
// ---------------------------------------------------------------------------

pub const AssetAction = enum {
    unchanged,
    rewritten,
    rejected,

    pub fn jsonName(self: AssetAction) []const u8 {
        return switch (self) {
            .unchanged => "unchanged",
            .rewritten => "rewritten",
            .rejected => "rejected",
        };
    }
};

pub const AssetRecord = struct {
    /// Content-root-relative source path (e.g. `spaces.assets/hello world.png`).
    source_path: []const u8,
    /// Within-tree path under the page `.assets/` root.
    within_tree_source: []const u8,
    /// Page stem that owns this asset (`spaces` for `spaces.md` / `spaces.assets/`).
    page_stem: []const u8,
    /// Destination within-tree path (Boris-safe) or empty when rejected.
    within_tree_dest: []const u8 = "",
    /// Content-root-relative destination (`spaces.assets/hello-world.png`).
    dest_path: []const u8 = "",
    action: AssetAction,
    reason: []const u8,
    sha256_hex: []const u8 = "",
    bytes: usize = 0,
};

pub const RewriteRecord = struct {
    page_path: []const u8,
    original_dest: []const u8,
    rewritten_dest: []const u8,
    reason: []const u8,
};

pub const RejectRecord = struct {
    source_path: []const u8,
    reason: []const u8,
    detail: []const u8,
};

// ---------------------------------------------------------------------------
// Helpers
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

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = try a.alloc(u8, 64);
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = charset[byte >> 4];
        hex[i * 2 + 1] = charset[byte & 0xf];
    }
    return hex;
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const piece = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(a, piece);
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

fn appendUsize(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: usize) !void {
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
    try buf.appendSlice(a, s);
}

fn appendBool(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(a, if (v) "true" else "false");
}

fn isSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, ".boris") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".obsidian");
}

fn isMarkdownName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".mdx");
}

fn pageStemFromName(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".mdx")) return name[0 .. name.len - 4];
    if (std.mem.endsWith(u8, name, ".md")) return name[0 .. name.len - 3];
    return null;
}

fn endsWithAssets(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".assets");
}

fn stripAssetsSuffix(name: []const u8) []const u8 {
    if (endsWithAssets(name)) return name[0 .. name.len - ".assets".len];
    return name;
}

/// Refuse writing reports/outputs inside the source tree.
pub fn refuseOutputInsideSource(source: []const u8, out: []const u8) !void {
    if (std.mem.eql(u8, source, out)) return error.OutputInsideSource;
    // Prefix check with separator boundary
    if (source.len < out.len and std.mem.startsWith(u8, out, source)) {
        const next = out[source.len];
        if (next == '/' or next == '\\') return error.OutputInsideSource;
    }
    if (out.len < source.len and std.mem.startsWith(u8, source, out)) {
        const next = source[out.len];
        if (next == '/' or next == '\\') return error.OutputInsideSource;
    }
}

fn isSymlink(io: Io, dir: Io.Dir, rel: []const u8) bool {
    // Prefer lstat-style check: open without following when available.
    // Zig 0.16 Dir.statFile may follow; try readLink as positive signal.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = dir.readLink(io, rel, &buf) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

const PageEntry = struct {
    /// Content-relative path (`spaces.md`, `guides/intro.md`).
    path: []const u8,
    /// Stem path without extension (`spaces`, `guides/intro`).
    stem: []const u8,
    /// Sibling asset root content-relative (`spaces.assets`).
    asset_root: []const u8,
};

const RawAsset = struct {
    source_path: []const u8,
    within_tree: []const u8,
    page_stem: []const u8,
    asset_root: []const u8,
    is_symlink: bool,
};

fn joinRel(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return try a.dupe(u8, name);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

fn walkContent(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_dir: []const u8,
    pages: *std.ArrayList(PageEntry),
    assets: *std.ArrayList(RawAsset),
) !void {
    var dir = root.openDir(io, if (rel_dir.len == 0) "." else rel_dir, .{ .iterate = true }) catch |err| {
        if (rel_dir.len == 0) return err;
        return;
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    for (names.items) |name| {
        if (name.len == 0 or name[0] == '.') continue;
        if (isSkipDir(name)) continue;
        const child_rel = try joinRel(a, rel_dir, name);
        // Keep child_rel in arena-style retain (caller arena); do not free.

        // Stat via open attempts
        var child_dir = root.openDir(io, child_rel, .{ .iterate = true }) catch {
            // file
            if (isMarkdownName(name)) {
                const stem_name = pageStemFromName(name).?;
                const stem = try joinRel(a, rel_dir, stem_name);
                const asset_root = try std.fmt.allocPrint(a, "{s}.assets", .{stem});
                try pages.append(a, .{
                    .path = child_rel,
                    .stem = stem,
                    .asset_root = asset_root,
                });
            }
            continue;
        };
        defer child_dir.close(io);

        if (endsWithAssets(name)) {
            const page_stem = try joinRel(a, rel_dir, stripAssetsSuffix(name));
            try walkAssetTree(io, a, root, child_rel, "", page_stem, child_rel, assets);
        } else {
            try walkContent(io, a, root, child_rel, pages, assets);
        }
    }
}

fn walkAssetTree(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    asset_root: []const u8,
    within: []const u8,
    page_stem: []const u8,
    abs_rel: []const u8,
    assets: *std.ArrayList(RawAsset),
) !void {
    var dir = root.openDir(io, abs_rel, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    for (names.items) |name| {
        if (name.len == 0 or name[0] == '.') continue;
        const child_within = if (within.len == 0) try a.dupe(u8, name) else try joinRel(a, within, name);
        const child_abs = try joinRel(a, abs_rel, name);

        const symlink = isSymlink(io, root, child_abs);

        var sub = root.openDir(io, child_abs, .{ .iterate = true }) catch {
            try assets.append(a, .{
                .source_path = child_abs,
                .within_tree = child_within,
                .page_stem = page_stem,
                .asset_root = asset_root,
                .is_symlink = symlink,
            });
            continue;
        };
        defer sub.close(io);

        if (symlink) {
            // Directory symlink: reject the tree root as a single rejection entry.
            try assets.append(a, .{
                .source_path = child_abs,
                .within_tree = child_within,
                .page_stem = page_stem,
                .asset_root = asset_root,
                .is_symlink = true,
            });
            continue;
        }
        try walkAssetTree(io, a, root, asset_root, child_within, page_stem, child_abs, assets);
    }
}

// ---------------------------------------------------------------------------
// Planning (sanitize + collisions)
// ---------------------------------------------------------------------------

const DestClaim = struct {
    source_path: []const u8,
    dest_path: []const u8,
};

/// Plan destination paths; first source path (sorted) wins on collision.
pub fn planAssets(
    a: std.mem.Allocator,
    raw: []const RawAsset,
    /// pre-read bytes + hashes keyed by source_path (optional empty sha)
    hash_of: *const std.StringHashMapUnmanaged([]const u8),
    bytes_of: *const std.StringHashMapUnmanaged(usize),
) ![]AssetRecord {
    // Sort raw by source_path for deterministic first-wins.
    const order = try a.alloc(usize, raw.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, raw, struct {
        fn less(rs: []const RawAsset, x: usize, y: usize) bool {
            return std.mem.order(u8, rs[x].source_path, rs[y].source_path) == .lt;
        }
    }.less);

    var claimed_exact: std.StringHashMapUnmanaged([]const u8) = .empty; // dest -> source
    var claimed_case: std.StringHashMapUnmanaged([]const u8) = .empty; // lower(dest) -> source

    var out: std.ArrayList(AssetRecord) = .empty;

    for (order) |idx| {
        const r = raw[idx];
        const sha = hash_of.get(r.source_path) orelse "";
        const nbytes = bytes_of.get(r.source_path) orelse 0;

        if (r.is_symlink) {
            try out.append(a, .{
                .source_path = r.source_path,
                .within_tree_source = r.within_tree,
                .page_stem = r.page_stem,
                .action = .rejected,
                .reason = "symlink",
                .sha256_hex = sha,
                .bytes = nbytes,
            });
            continue;
        }

        // Reject traversal / absolute within-tree as non-copyable
        if (std.mem.indexOf(u8, r.within_tree, "..") != null or
            r.within_tree.len == 0 or
            r.within_tree[0] == '/' or
            std.mem.indexOfScalar(u8, r.within_tree, '\\') != null)
        {
            try out.append(a, .{
                .source_path = r.source_path,
                .within_tree_source = r.within_tree,
                .page_stem = r.page_stem,
                .action = .rejected,
                .reason = "traversal",
                .sha256_hex = sha,
                .bytes = nbytes,
            });
            continue;
        }

        const safe = isBorisSafeWithinTree(r.within_tree);
        const dest_within = if (safe)
            try a.dupe(u8, r.within_tree)
        else
            try sanitizeWithinTree(a, r.within_tree);

        const dest_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ r.asset_root, dest_within });
        const dest_lower = try asciiLowerAlloc(a, dest_path);

        if (claimed_exact.get(dest_path)) |owner| {
            if (!std.mem.eql(u8, owner, r.source_path)) {
                try out.append(a, .{
                    .source_path = r.source_path,
                    .within_tree_source = r.within_tree,
                    .page_stem = r.page_stem,
                    .within_tree_dest = dest_within,
                    .dest_path = dest_path,
                    .action = .rejected,
                    .reason = "destination_collision",
                    .sha256_hex = sha,
                    .bytes = nbytes,
                });
                continue;
            }
        }
        if (claimed_case.get(dest_lower)) |owner| {
            if (!std.mem.eql(u8, owner, r.source_path)) {
                // Different source claims a case-variant of the same dest.
                try out.append(a, .{
                    .source_path = r.source_path,
                    .within_tree_source = r.within_tree,
                    .page_stem = r.page_stem,
                    .within_tree_dest = dest_within,
                    .dest_path = dest_path,
                    .action = .rejected,
                    .reason = "case_collision",
                    .sha256_hex = sha,
                    .bytes = nbytes,
                });
                continue;
            }
        }

        try claimed_exact.put(a, dest_path, r.source_path);
        try claimed_case.put(a, dest_lower, r.source_path);

        if (safe) {
            try out.append(a, .{
                .source_path = r.source_path,
                .within_tree_source = r.within_tree,
                .page_stem = r.page_stem,
                .within_tree_dest = dest_within,
                .dest_path = dest_path,
                .action = .unchanged,
                .reason = "already_safe",
                .sha256_hex = sha,
                .bytes = nbytes,
            });
        } else {
            try out.append(a, .{
                .source_path = r.source_path,
                .within_tree_source = r.within_tree,
                .page_stem = r.page_stem,
                .within_tree_dest = dest_within,
                .dest_path = dest_path,
                .action = .rewritten,
                .reason = unsafeReason(r.within_tree),
                .sha256_hex = sha,
                .bytes = nbytes,
            });
        }
    }

    // Stable output order by source_path
    std.mem.sort(AssetRecord, out.items, {}, struct {
        fn less(_: void, x: AssetRecord, y: AssetRecord) bool {
            return std.mem.order(u8, x.source_path, y.source_path) == .lt;
        }
    }.less);
    return try out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Markdown rewrite (fence-aware image + link destinations)
// ---------------------------------------------------------------------------

const DestMap = std.StringHashMapUnmanaged([]const u8); // original ref form → rewritten dest

fn percentEncodePath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (path) |c| {
        if (isSafeChar(c) or c == '/') {
            try out.append(a, c);
        } else if (c == ' ') {
            try out.appendSlice(a, "%20");
        } else {
            var tmp: [3]u8 = undefined;
            const piece = try std.fmt.bufPrint(&tmp, "%{X:0>2}", .{c});
            try out.appendSlice(a, piece);
        }
    }
    return try out.toOwnedSlice(a);
}

/// Build lookup of reference strings → sanitized relative dest for one page.
fn buildPageDestMap(
    a: std.mem.Allocator,
    page: PageEntry,
    records: []const AssetRecord,
    map: *DestMap,
) !void {
    const asset_prefix = try std.fmt.allocPrint(a, "{s}/", .{page.asset_root});
    // Also basename-only forms: `already-ok.png` is not used; Boris uses full sibling path.

    for (records) |rec| {
        if (rec.action == .rejected) continue;
        if (!std.mem.eql(u8, rec.page_stem, page.stem)) continue;

        const new_ref = try std.fmt.allocPrint(a, "{s}/{s}", .{ page.asset_root, rec.within_tree_dest });

        // Map original within-tree with asset root prefix
        const old_ref = try std.fmt.allocPrint(a, "{s}/{s}", .{ page.asset_root, rec.within_tree_source });
        try map.put(a, old_ref, new_ref);

        // URL-encoded form of original (spaces → %20 etc.)
        const enc = try percentEncodePath(a, old_ref);
        try map.put(a, enc, new_ref);

        // Also map if old_ref had decoded form already handled
        _ = asset_prefix;
    }
}

fn isFenceLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return false;
    return line[i] == '`';
}

/// Rewrite Markdown image and link destinations using `map`. Fence-aware.
pub fn rewriteMarkdown(
    a: std.mem.Allocator,
    body: []const u8,
    map: *const DestMap,
    page_path: []const u8,
    rewrites: *std.ArrayList(RewriteRecord),
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var in_fence = false;
    var line_start: usize = 0;
    while (line_start <= body.len) {
        if (line_start > body.len) break;
        const line_end = if (line_start >= body.len) body.len else std.mem.indexOfScalarPos(u8, body, line_start, '\n') orelse body.len;
        const line = if (line_start >= body.len) body[0..0] else body[line_start..line_end];
        const has_nl = line_end < body.len and body[line_end] == '\n';

        var t: usize = 0;
        while (t < line.len and (line[t] == ' ' or line[t] == '\t')) : (t += 1) {}
        const fence_here = t + 2 < line.len and
            line[t] == '`' and line[t + 1] == '`' and line[t + 2] == '`';

        if (fence_here) {
            in_fence = !in_fence;
            try out.appendSlice(a, line);
            if (has_nl) try out.append(a, '\n');
        } else if (in_fence) {
            try out.appendSlice(a, line);
            if (has_nl) try out.append(a, '\n');
        } else {
            const rewritten = try rewriteLineDests(a, line, map, page_path, rewrites);
            defer a.free(rewritten);
            try out.appendSlice(a, rewritten);
            if (has_nl) try out.append(a, '\n');
        }

        if (line_end >= body.len) break;
        line_start = line_end + 1;
    }
    return try out.toOwnedSlice(a);
}

fn rewriteLineDests(
    a: std.mem.Allocator,
    line: []const u8,
    map: *const DestMap,
    page_path: []const u8,
    rewrites: *std.ArrayList(RewriteRecord),
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < line.len) {
        // Optional image bang; then [label](dest)
        var start = i;
        if (line[i] == '!' and i + 1 < line.len and line[i + 1] == '[') {
            start = i; // include '!'
            // parse from '['
            const bracket = i + 1;
            if (try emitLinkLike(a, line, start, bracket, map, page_path, rewrites, &out)) |next| {
                i = next;
                continue;
            }
        } else if (line[i] == '[') {
            if (try emitLinkLike(a, line, start, i, map, page_path, rewrites, &out)) |next| {
                i = next;
                continue;
            }
        }
        try out.append(a, line[i]);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

/// Parse `[label](dest)` starting at `bracket_idx` (`[`); `emit_from` is where to copy prefix (`!` or `[`).
/// Returns next index after the closing `)` on success.
fn emitLinkLike(
    a: std.mem.Allocator,
    line: []const u8,
    emit_from: usize,
    bracket_idx: usize,
    map: *const DestMap,
    page_path: []const u8,
    rewrites: *std.ArrayList(RewriteRecord),
    out: *std.ArrayList(u8),
) !?usize {
    const cb = findMatchingBracket(line, bracket_idx) orelse return null;
    if (cb + 1 >= line.len or line[cb + 1] != '(') return null;
    const dest_start = cb + 2;
    if (dest_start > line.len) return null;

    // Find closing ')' first (lenient: destinations may contain spaces).
    var close_paren = dest_start;
    while (close_paren < line.len and line[close_paren] != ')') : (close_paren += 1) {}
    if (close_paren >= line.len) return null;

    const inside = line[dest_start..close_paren];
    var dest: []const u8 = undefined;
    var title_suffix: []const u8 = "";
    var open_angle = false;

    if (inside.len > 0 and inside[0] == '<') {
        open_angle = true;
        const gt = std.mem.indexOfScalar(u8, inside, '>') orelse return null;
        dest = inside[1..gt];
        title_suffix = inside[gt + 1 ..];
    } else if (std.mem.indexOfScalar(u8, inside, '"')) |q| {
        // url "title" — title starts at first "
        // Prefer last-space-before-quote split when present.
        var split = q;
        while (split > 0 and inside[split - 1] == ' ') : (split -= 1) {}
        dest = std.mem.trimEnd(u8, inside[0..split], " \t");
        title_suffix = inside[split..];
    } else {
        // Whole interior is the destination (spaces allowed for migration sources).
        dest = std.mem.trim(u8, inside, " \t");
        title_suffix = "";
    }

    // Emit prefix through start of destination (including optional `<`)
    try out.appendSlice(a, line[emit_from..dest_start]);
    if (open_angle) try out.append(a, '<');

    const mapped = lookupDest(map, dest);
    if (mapped) |m| {
        if (!std.mem.eql(u8, m, dest)) {
            try rewrites.append(a, .{
                .page_path = page_path,
                .original_dest = try a.dupe(u8, dest),
                .rewritten_dest = try a.dupe(u8, m),
                .reason = "image_or_link_dest",
            });
        }
        try out.appendSlice(a, m);
    } else {
        try out.appendSlice(a, dest);
    }

    if (open_angle) try out.append(a, '>');
    try out.appendSlice(a, title_suffix);
    try out.append(a, ')');
    return close_paren + 1;
}

fn findMatchingBracket(s: []const u8, open_idx: usize) ?usize {
    if (open_idx >= s.len or s[open_idx] != '[') return null;
    var depth: usize = 0;
    var i = open_idx;
    while (i < s.len) : (i += 1) {
        if (s[i] == '[') depth += 1;
        if (s[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn lookupDest(map: *const DestMap, dest: []const u8) ?[]const u8 {
    if (map.get(dest)) |m| return m;
    // strip leading ./
    if (std.mem.startsWith(u8, dest, "./")) {
        if (map.get(dest[2..])) |m| return m;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Emit manifests + reports
// ---------------------------------------------------------------------------

fn emitAssetManifest(a: std.mem.Allocator, records: []const AssetRecord) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": \"");
    try buf.appendSlice(a, format_id);
    try buf.appendSlice(a, "\",\n  \"schema_version\": ");
    try appendUsize(&buf, a, schema_version);
    try buf.appendSlice(a, ",\n  \"policy\": \"Sanitize content-local asset filenames to Boris ASCII path grammar. Source tree is never modified. Collisions are rejected, never silent overwrites. Remote assets are not fetched.\",\n  \"assets\": [\n");

    for (records, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, r.source_path);
        try buf.appendSlice(a, ", \"within_tree_source\": ");
        try appendJson(&buf, a, r.within_tree_source);
        try buf.appendSlice(a, ", \"page_stem\": ");
        try appendJson(&buf, a, r.page_stem);
        try buf.appendSlice(a, ", \"within_tree_dest\": ");
        try appendJson(&buf, a, r.within_tree_dest);
        try buf.appendSlice(a, ", \"dest_path\": ");
        try appendJson(&buf, a, r.dest_path);
        try buf.appendSlice(a, ", \"action\": ");
        try appendJson(&buf, a, r.action.jsonName());
        try buf.appendSlice(a, ", \"reason\": ");
        try appendJson(&buf, a, r.reason);
        try buf.appendSlice(a, ", \"sha256\": ");
        if (r.sha256_hex.len > 0) try appendJson(&buf, a, r.sha256_hex) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"bytes\": ");
        try appendUsize(&buf, a, r.bytes);
        try buf.appendSlice(a, " }");
        if (i + 1 < records.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitRewriteManifest(a: std.mem.Allocator, rewrites: []const RewriteRecord) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": \"boris-asset-filename-rewrites\",\n  \"schema_version\": 1,\n  \"rewrites\": [\n");
    // sort for determinism
    const sorted = try a.dupe(RewriteRecord, rewrites);
    defer a.free(sorted);
    std.mem.sort(RewriteRecord, sorted, {}, struct {
        fn less(_: void, x: RewriteRecord, y: RewriteRecord) bool {
            const p = std.mem.order(u8, x.page_path, y.page_path);
            if (p != .eq) return p == .lt;
            const o = std.mem.order(u8, x.original_dest, y.original_dest);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, x.rewritten_dest, y.rewritten_dest) == .lt;
        }
    }.less);
    for (sorted, 0..) |r, i| {
        try buf.appendSlice(a, "    { \"page_path\": ");
        try appendJson(&buf, a, r.page_path);
        try buf.appendSlice(a, ", \"original_dest\": ");
        try appendJson(&buf, a, r.original_dest);
        try buf.appendSlice(a, ", \"rewritten_dest\": ");
        try appendJson(&buf, a, r.rewritten_dest);
        try buf.appendSlice(a, ", \"reason\": ");
        try appendJson(&buf, a, r.reason);
        try buf.appendSlice(a, " }");
        if (i + 1 < sorted.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportJson(
    a: std.mem.Allocator,
    source_root: []const u8,
    records: []const AssetRecord,
    rewrites: []const RewriteRecord,
) ![]u8 {
    var n_unchanged: usize = 0;
    var n_rewritten: usize = 0;
    var n_rejected: usize = 0;
    for (records) |r| {
        switch (r.action) {
            .unchanged => n_unchanged += 1,
            .rewritten => n_rewritten += 1,
            .rejected => n_rejected += 1,
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": \"");
    try buf.appendSlice(a, format_id);
    try buf.appendSlice(a, "\",\n  \"schema_version\": ");
    try appendUsize(&buf, a, schema_version);
    try buf.appendSlice(a, ",\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, source_root);
    try buf.appendSlice(a, ",\n  \"counts\": {\n    \"assets\": ");
    try appendUsize(&buf, a, records.len);
    try buf.appendSlice(a, ",\n    \"unchanged\": ");
    try appendUsize(&buf, a, n_unchanged);
    try buf.appendSlice(a, ",\n    \"rewritten\": ");
    try appendUsize(&buf, a, n_rewritten);
    try buf.appendSlice(a, ",\n    \"rejected\": ");
    try appendUsize(&buf, a, n_rejected);
    try buf.appendSlice(a, ",\n    \"markdown_rewrites\": ");
    try appendUsize(&buf, a, rewrites.len);
    try buf.appendSlice(a, "\n  },\n  \"policy\": {\n    \"source_readonly\": ");
    try appendBool(&buf, a, true);
    try buf.appendSlice(a, ",\n    \"remote_fetch\": ");
    try appendBool(&buf, a, false);
    try buf.appendSlice(a, ",\n    \"execute_js\": ");
    try appendBool(&buf, a, false);
    try buf.appendSlice(a, ",\n    \"silent_overwrite\": ");
    try appendBool(&buf, a, false);
    try buf.appendSlice(a, ",\n    \"boris_core_unchanged\": ");
    try appendBool(&buf, a, true);
    try buf.appendSlice(a, "\n  }\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportMd(
    a: std.mem.Allocator,
    records: []const AssetRecord,
    rewrites: []const RewriteRecord,
) ![]u8 {
    var n_unchanged: usize = 0;
    var n_rewritten: usize = 0;
    var n_rejected: usize = 0;
    for (records) |r| {
        switch (r.action) {
            .unchanged => n_unchanged += 1,
            .rewritten => n_rewritten += 1,
            .rejected => n_rejected += 1,
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a,
        \\# Asset filename compatibility report
        \\
        \\Migration laboratory only. Boris core still requires ASCII content-local
        \\asset path segments (`[A-Za-z0-9._-]+`). This lab rewrites unsafe source
        \\names into that grammar without changing the product contract.
        \\
        \\| metric | count |
        \\|---|---:|
        \\
    );
    try buf.appendSlice(a, "| assets | ");
    try appendUsize(&buf, a, records.len);
    try buf.appendSlice(a, " |\n| unchanged | ");
    try appendUsize(&buf, a, n_unchanged);
    try buf.appendSlice(a, " |\n| rewritten | ");
    try appendUsize(&buf, a, n_rewritten);
    try buf.appendSlice(a, " |\n| rejected | ");
    try appendUsize(&buf, a, n_rejected);
    try buf.appendSlice(a, " |\n| markdown rewrites | ");
    try appendUsize(&buf, a, rewrites.len);
    try buf.appendSlice(a, " |\n\n## Assets\n\n");
    for (records) |r| {
        try buf.appendSlice(a, "- `");
        try buf.appendSlice(a, r.source_path);
        try buf.appendSlice(a, "` → `");
        try buf.appendSlice(a, if (r.dest_path.len > 0) r.dest_path else "(rejected)");
        try buf.appendSlice(a, "` (");
        try buf.appendSlice(a, r.action.jsonName());
        try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, r.reason);
        try buf.appendSlice(a, ")");
        if (r.sha256_hex.len > 0) {
            try buf.appendSlice(a, " sha256=`");
            try buf.appendSlice(a, r.sha256_hex);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, "\n");
    }
    try buf.appendSlice(a, "\n## Markdown rewrites\n\n");
    if (rewrites.len == 0) {
        try buf.appendSlice(a, "_none_\n");
    } else {
        for (rewrites) |r| {
            try buf.appendSlice(a, "- `");
            try buf.appendSlice(a, r.page_path);
            try buf.appendSlice(a, "`: `");
            try buf.appendSlice(a, r.original_dest);
            try buf.appendSlice(a, "` → `");
            try buf.appendSlice(a, r.rewritten_dest);
            try buf.appendSlice(a, "`\n");
        }
    }
    try buf.appendSlice(a,
        \\
        \\Machine-readable twins: `asset_filename_manifest.json`, `rewrite_manifest.json`, `report.json`.
        \\
    );
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    try refuseOutputInsideSource(opts.root_dir, opts.out_dir);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{}) catch return error.SourceNotFound;
    defer root.close(io);

    // Prefer nested content/ when present.
    const content_rel: []const u8 = blk: {
        var probe = root.openDir(io, "content", .{}) catch break :blk "";
        probe.close(io);
        break :blk "content";
    };

    var content_dir = if (content_rel.len == 0)
        try root.openDir(io, ".", .{})
    else
        try root.openDir(io, content_rel, .{});
    defer content_dir.close(io);

    var pages: std.ArrayList(PageEntry) = .empty;
    var raw_assets: std.ArrayList(RawAsset) = .empty;
    try walkContent(io, a, content_dir, "", &pages, &raw_assets);

    std.mem.sort(PageEntry, pages.items, {}, struct {
        fn less(_: void, x: PageEntry, y: PageEntry) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);
    std.mem.sort(RawAsset, raw_assets.items, {}, struct {
        fn less(_: void, x: RawAsset, y: RawAsset) bool {
            return std.mem.order(u8, x.source_path, y.source_path) == .lt;
        }
    }.less);

    // Hash regular (non-symlink) assets
    var hash_of: std.StringHashMapUnmanaged([]const u8) = .empty;
    var bytes_of: std.StringHashMapUnmanaged(usize) = .empty;
    for (raw_assets.items) |r| {
        if (r.is_symlink) continue;
        const data = readFileAlloc(io, content_dir, r.source_path, a) catch continue;
        const hex = try sha256Hex(a, data);
        try hash_of.put(a, r.source_path, hex);
        try bytes_of.put(a, r.source_path, data.len);
    }

    const records = try planAssets(a, raw_assets.items, &hash_of, &bytes_of);

    // Prepare output
    Io.Dir.cwd().createDirPath(io, opts.out_dir) catch return error.IoFailure;
    var out_root = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out_root.close(io);
    try out_root.createDirPath(io, "content");
    var out_content = try out_root.openDir(io, "content", .{});
    defer out_content.close(io);

    // Copy accepted assets
    for (records) |r| {
        if (r.action == .rejected) continue;
        if (r.dest_path.len == 0) continue;
        // Refuse overwrite: if dest already exists with different source, plan should have rejected.
        // Still never overwrite: skip write if file exists (byte-identical re-run is OK if same bytes).
        const data = try readFileAlloc(io, content_dir, r.source_path, a);
        // If dest exists, compare bytes — identical is fine; different is collision error.
        if (readFileAlloc(io, out_content, r.dest_path, a)) |existing| {
            if (!std.mem.eql(u8, existing, data)) return error.Collision;
            // same bytes: leave
        } else |_| {
            try writeBytes(io, out_content, r.dest_path, data);
        }
    }

    // Rewrite + write pages
    var all_rewrites: std.ArrayList(RewriteRecord) = .empty;
    for (pages.items) |page| {
        const body = try readFileAlloc(io, content_dir, page.path, a);
        var map: DestMap = .empty;
        try buildPageDestMap(a, page, records, &map);
        const new_body = try rewriteMarkdown(a, body, &map, page.path, &all_rewrites);
        try writeBytes(io, out_content, page.path, new_body);
    }

    // Manifests
    const man = try emitAssetManifest(a, records);
    try writeBytes(io, out_root, "asset_filename_manifest.json", man);
    const rew = try emitRewriteManifest(a, all_rewrites.items);
    try writeBytes(io, out_root, "rewrite_manifest.json", rew);
    const report = try emitReportJson(a, opts.root_dir, records, all_rewrites.items);
    try writeBytes(io, out_root, "report.json", report);
    const md = try emitReportMd(a, records, all_rewrites.items);
    try writeBytes(io, out_root, "REPORT.md", md);

    if (!opts.quiet) {
        std.debug.print(
            "asset-filename-lab: wrote {s}/content/, asset_filename_manifest.json, rewrite_manifest.json, report.json, REPORT.md\n",
            .{opts.out_dir},
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isBorisSafeWithinTree mirrors core grammar" {
    try std.testing.expect(isBorisSafeWithinTree("diagram.svg"));
    try std.testing.expect(isBorisSafeWithinTree("nested/x.png"));
    try std.testing.expect(isBorisSafeWithinTree("already-ok.png"));
    try std.testing.expect(!isBorisSafeWithinTree("hello world.png"));
    try std.testing.expect(!isBorisSafeWithinTree("café.png"));
    try std.testing.expect(!isBorisSafeWithinTree("diagram%20copy.png"));
    try std.testing.expect(!isBorisSafeWithinTree("../x.svg"));
    try std.testing.expect(!isBorisSafeWithinTree("a/../b.svg"));
    try std.testing.expect(!isBorisSafeWithinTree("a\\b.svg"));
    try std.testing.expect(!isBorisSafeWithinTree("/abs.svg"));
}

test "sanitizeSegment: spaces, unicode, percent" {
    const gpa = std.testing.allocator;
    const s1 = try sanitizeSegment(gpa, "hello world.png");
    defer gpa.free(s1);
    try std.testing.expectEqualStrings("hello-world.png", s1);

    const s2 = try sanitizeSegment(gpa, "café.png");
    defer gpa.free(s2);
    try std.testing.expectEqualStrings("caf.png", s2);

    const s3 = try sanitizeSegment(gpa, "diagram%20copy.png");
    defer gpa.free(s3);
    try std.testing.expectEqualStrings("diagram-copy.png", s3);

    const s4 = try sanitizeSegment(gpa, "already-ok.png");
    defer gpa.free(s4);
    try std.testing.expectEqualStrings("already-ok.png", s4);
}

test "sanitizeWithinTree preserves nesting" {
    const gpa = std.testing.allocator;
    const p = try sanitizeWithinTree(gpa, "deep/sub dir/shot.png");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("deep/sub-dir/shot.png", p);
}

test "sanitizeWithinTree: percent and unicode segments" {
    const gpa = std.testing.allocator;
    const p = try sanitizeWithinTree(gpa, "diagram%20copy.png");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("diagram-copy.png", p);
}

test "planAssets: sanitized-name collision rejects second" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = [_]RawAsset{
        .{
            .source_path = "sc.assets/foo bar.png",
            .within_tree = "foo bar.png",
            .page_stem = "sc",
            .asset_root = "sc.assets",
            .is_symlink = false,
        },
        .{
            .source_path = "sc.assets/foo-bar.png",
            .within_tree = "foo-bar.png",
            .page_stem = "sc",
            .asset_root = "sc.assets",
            .is_symlink = false,
        },
    };
    var hash: std.StringHashMapUnmanaged([]const u8) = .empty;
    var bytes: std.StringHashMapUnmanaged(usize) = .empty;
    try hash.put(a, raw[0].source_path, "aa");
    try hash.put(a, raw[1].source_path, "bb");
    try bytes.put(a, raw[0].source_path, 1);
    try bytes.put(a, raw[1].source_path, 1);

    const planned = try planAssets(a, &raw, &hash, &bytes);
    try std.testing.expect(planned.len == 2);
    var rejected: usize = 0;
    var accepted: usize = 0;
    for (planned) |r| {
        if (r.action == .rejected and std.mem.eql(u8, r.reason, "destination_collision")) rejected += 1;
        if (r.action != .rejected) accepted += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rejected);
    try std.testing.expectEqual(@as(usize, 1), accepted);
}

test "planAssets: case collision rejects second" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Foo Bar.png → Foo-Bar.png; foo-bar.png → foo-bar.png; case-insensitive same.
    const raw = [_]RawAsset{
        .{
            .source_path = "c.assets/Foo Bar.png",
            .within_tree = "Foo Bar.png",
            .page_stem = "c",
            .asset_root = "c.assets",
            .is_symlink = false,
        },
        .{
            .source_path = "c.assets/foo-bar.png",
            .within_tree = "foo-bar.png",
            .page_stem = "c",
            .asset_root = "c.assets",
            .is_symlink = false,
        },
    };
    var hash: std.StringHashMapUnmanaged([]const u8) = .empty;
    var bytes: std.StringHashMapUnmanaged(usize) = .empty;
    try hash.put(a, raw[0].source_path, "aa");
    try hash.put(a, raw[1].source_path, "bb");
    try bytes.put(a, raw[0].source_path, 1);
    try bytes.put(a, raw[1].source_path, 1);

    const planned = try planAssets(a, &raw, &hash, &bytes);
    var case_rej: usize = 0;
    for (planned) |r| {
        if (r.action == .rejected and std.mem.eql(u8, r.reason, "case_collision")) case_rej += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), case_rej);
}

test "planAssets: symlink rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = [_]RawAsset{
        .{
            .source_path = "s.assets/alias.png",
            .within_tree = "alias.png",
            .page_stem = "s",
            .asset_root = "s.assets",
            .is_symlink = true,
        },
    };
    var hash: std.StringHashMapUnmanaged([]const u8) = .empty;
    var bytes: std.StringHashMapUnmanaged(usize) = .empty;
    const planned = try planAssets(a, &raw, &hash, &bytes);
    try std.testing.expect(planned.len == 1);
    try std.testing.expect(planned[0].action == .rejected);
    try std.testing.expectEqualStrings("symlink", planned[0].reason);
}

test "rewriteMarkdown: rewrites image dest and leaves fences" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var map: DestMap = .empty;
    try map.put(a, "spaces.assets/hello world.png", "spaces.assets/hello-world.png");
    try map.put(a, "spaces.assets/hello%20world.png", "spaces.assets/hello-world.png");

    const body =
        \\![a](spaces.assets/hello world.png)
        \\
        \\```
        \\![b](spaces.assets/hello world.png)
        \\```
        \\
        \\![c](spaces.assets/hello%20world.png)
        \\
    ;
    var rewrites: std.ArrayList(RewriteRecord) = .empty;
    const out = try rewriteMarkdown(a, body, &map, "spaces.md", &rewrites);
    try std.testing.expect(std.mem.indexOf(u8, out, "spaces.assets/hello-world.png") != null);
    // fence content preserved
    try std.testing.expect(std.mem.indexOf(u8, out, "```\n![b](spaces.assets/hello world.png)\n```") != null);
    try std.testing.expect(rewrites.items.len >= 2);
}

test "refuseOutputInsideSource" {
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("/tmp/src", "/tmp/src"));
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("/tmp/src", "/tmp/src/out"));
    try refuseOutputInsideSource("/tmp/src", "/tmp/other");
}

test "fixture: hostile-asset-filenames is deterministic and preserves source" {
    const io = std.testing.io;
    const a_out = "fixtures/.test-asset-filename-a";
    const b_out = "fixtures/.test-asset-filename-b";
    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/hostile-asset-filenames", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "content/spaces.md", std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{
        .root_dir = "fixtures/hostile-asset-filenames",
        .out_dir = a_out,
        .quiet = true,
    });
    try run(io, std.testing.allocator, .{
        .root_dir = "fixtures/hostile-asset-filenames",
        .out_dir = b_out,
        .quiet = true,
    });

    var ao = try Io.Dir.cwd().openDir(io, a_out, .{});
    defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, b_out, .{});
    defer bo.close(io);

    const compare = [_][]const u8{
        "asset_filename_manifest.json",
        "rewrite_manifest.json",
        "report.json",
        "REPORT.md",
        "content/spaces.md",
        "content/safe.md",
        "content/nested.md",
        "content/safe.assets/already-ok.png",
        "content/spaces.assets/hello-world.png",
        "content/nested.assets/deep/sub-dir/shot.png",
    };
    for (compare) |name| {
        const xa = try readFileAlloc(io, ao, name, std.testing.allocator);
        defer std.testing.allocator.free(xa);
        const xb = try readFileAlloc(io, bo, name, std.testing.allocator);
        defer std.testing.allocator.free(xb);
        try std.testing.expectEqualStrings(xa, xb);
    }

    const man = try readFileAlloc(io, ao, "asset_filename_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(man);
    try std.testing.expect(std.mem.indexOf(u8, man, format_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "hello world.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "hello-world.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "spaces") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "unicode") != null or std.mem.indexOf(u8, man, "caf") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "percent_encoding") != null or std.mem.indexOf(u8, man, "diagram") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "destination_collision") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "case_collision") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "symlink") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "already_safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, man, "sha256") != null);

    const spaces_page = try readFileAlloc(io, ao, "content/spaces.md", std.testing.allocator);
    defer std.testing.allocator.free(spaces_page);
    try std.testing.expect(std.mem.indexOf(u8, spaces_page, "spaces.assets/hello-world.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, spaces_page, "hello world.png") == null);

    const nested_page = try readFileAlloc(io, ao, "content/nested.md", std.testing.allocator);
    defer std.testing.allocator.free(nested_page);
    try std.testing.expect(std.mem.indexOf(u8, nested_page, "nested.assets/deep/sub-dir/shot.png") != null);

    // Source immutability
    const after = try readFileAlloc(io, fixture, "content/spaces.md", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    // Symlink not copied
    var symlink_dest_exists = true;
    _ = ao.access(io, "content/symlink.assets/alias.png", .{}) catch {
        symlink_dest_exists = false;
    };
    try std.testing.expect(!symlink_dest_exists);
    // real.png is safe and should be copied
    const real = try readFileAlloc(io, ao, "content/symlink.assets/real.png", std.testing.allocator);
    defer std.testing.allocator.free(real);
    try std.testing.expect(real.len > 0);

    Io.Dir.cwd().deleteTree(io, a_out) catch {};
    Io.Dir.cwd().deleteTree(io, b_out) catch {};
}
