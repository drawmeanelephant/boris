//! Boris-mediated wiki-links (`[[entity-id]]` / `[[entity-id|label]]` /
//! `[[entity-id#heading]]` / `[[entity-id#heading|label]]`).
//!
//! Resolved against the frozen page graph by entity id **before** Apex.
//! Optional heading fragments match Apex-rendered `id` attributes on the
//! target page (see `docs/contracts/heading-ids.md`). Fence-aware: links
//! inside fenced code stay literal.
//!
//! Normative: `docs/contracts/includes-and-wiki-links.md`,
//! `docs/contracts/heading-ids.md`.

const std = @import("std");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");
const diag = @import("diag.zig");
const include_mod = @import("include.zig");

pub const WikiError = error{
    ReferenceSyntax,
    ReferenceMissing,
    OutOfMemory,
    PathError,
};

/// Same owned-buffer FailInfo as includes (detail + optional locus path).
pub const FailInfo = include_mod.FailInfo;

pub const WikiHit = struct {
    entity_id: []const u8,
    /// Exact rendered heading `id` when `[[entity#fragment]]`; null for page-only.
    fragment: ?[]const u8,
    label: ?[]const u8,
    offset: usize,
    end: usize,
    line: u32,
    column: u32,
};

/// Per-entity set of Apex-rendered heading ids (views or owned — caller owns lifetime).
pub const HeadingIndex = struct {
    /// entity_id → list of unique heading id strings for that page.
    map: std.StringHashMapUnmanaged([]const []const u8) = .{},

    pub fn deinit(self: *HeadingIndex, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            // Keys and id slices are owned when built by compile helpers.
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |id| allocator.free(id);
            allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(allocator);
        self.* = .{};
    }

    pub fn putOwned(
        self: *HeadingIndex,
        allocator: std.mem.Allocator,
        entity_id: []const u8,
        ids: []const []const u8,
    ) !void {
        const key = try allocator.dupe(u8, entity_id);
        errdefer allocator.free(key);
        const owned_ids = try allocator.alloc([]const u8, ids.len);
        errdefer allocator.free(owned_ids);
        var filled: usize = 0;
        errdefer {
            for (owned_ids[0..filled]) |id| allocator.free(id);
        }
        for (ids, 0..) |id, i| {
            owned_ids[i] = try allocator.dupe(u8, id);
            filled = i + 1;
        }
        const gop = try self.map.getOrPut(allocator, key);
        if (gop.found_existing) {
            // Replace previous set.
            allocator.free(gop.key_ptr.*);
            for (gop.value_ptr.*) |old| allocator.free(old);
            allocator.free(gop.value_ptr.*);
            gop.key_ptr.* = key;
            gop.value_ptr.* = owned_ids;
        } else {
            gop.key_ptr.* = key;
            gop.value_ptr.* = owned_ids;
        }
    }

    /// Outcome of a fragment membership probe. Distinguishes "this page is not
    /// in the index at all" from "the page is indexed but has no such heading",
    /// so diagnostics can name the right thing (see `checkFragment`).
    pub const Lookup = enum { ok, unknown_entity, unknown_fragment };

    pub fn lookup(self: *const HeadingIndex, entity_id: []const u8, fragment: []const u8) Lookup {
        const ids = self.map.get(entity_id) orelse return .unknown_entity;
        for (ids) |id| {
            if (std.mem.eql(u8, id, fragment)) return .ok;
        }
        return .unknown_fragment;
    }

    pub fn has(self: *const HeadingIndex, entity_id: []const u8, fragment: []const u8) bool {
        return self.lookup(entity_id, fragment) == .ok;
    }
};

fn atLineStart(body: []const u8, i: usize) bool {
    if (i == 0) return true;
    return body[i - 1] == '\n';
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

fn lineEndIndex(body: []const u8, i: usize) usize {
    var j = i;
    while (j < body.len and body[j] != '\n') : (j += 1) {}
    return j;
}

fn isEntityIdChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '/' or c == '_' or c == '-' or c == '.';
}

fn setFail(fail_out: ?*FailInfo, body: []const u8, offset: usize, detail_s: []const u8, locus_s: []const u8) void {
    if (fail_out) |f| f.setAt(body, offset, detail_s, locus_s);
}

fn hexNibble(n: u4) u8 {
    return "0123456789ABCDEF"[n];
}

/// Percent-encode a fragment for a Markdown link destination (RFC 3986 unreserved stay plain).
pub fn encodeFragment(allocator: std.mem.Allocator, fragment: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (fragment) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hexNibble(@intCast(c >> 4)));
            try out.append(allocator, hexNibble(@intCast(c & 0xf)));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Scan body for wiki-links outside fences. Views into `body`.
/// On syntax errors, fills `fail_out` when provided.
/// `locus_path` is the content-root path of this body (page or include fragment).
pub fn scanWikiLinks(
    body: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(WikiHit),
    fail_out: ?*FailInfo,
    locus_path: []const u8,
) WikiError!void {
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

        if (i + 3 <= body.len and body[i] == '[' and body[i + 1] == '[') {
            const start = i;
            i += 2;
            const id_start = i;
            while (i < body.len and isEntityIdChar(body[i])) : (i += 1) {}
            if (i == id_start) {
                setFail(fail_out, body, start, "", locus_path);
                return error.ReferenceSyntax;
            }
            const entity_id = body[id_start..i];
            if (!identity.validateEntityId(entity_id)) {
                setFail(fail_out, body, start, entity_id, locus_path);
                return error.ReferenceSyntax;
            }

            var fragment: ?[]const u8 = null;
            if (i < body.len and body[i] == '#') {
                i += 1;
                const frag_start = i;
                while (i < body.len) : (i += 1) {
                    const c = body[i];
                    if (c == '|' or (c == ']' and i + 1 < body.len and body[i + 1] == ']')) break;
                    if (c == '\n' or c == '\r' or c == ']') {
                        setFail(fail_out, body, start, entity_id, locus_path);
                        return error.ReferenceSyntax;
                    }
                }
                if (i == frag_start) {
                    // Empty fragment: [[entity#]] or [[entity#|label]]
                    setFail(fail_out, body, start, entity_id, locus_path);
                    return error.ReferenceSyntax;
                }
                fragment = body[frag_start..i];
            }

            var label: ?[]const u8 = null;
            if (i < body.len and body[i] == '|') {
                i += 1;
                const lab_start = i;
                while (i < body.len and !(body[i] == ']' and i + 1 < body.len and body[i + 1] == ']')) : (i += 1) {
                    if (body[i] == '\n' or body[i] == '\r') {
                        setFail(fail_out, body, start, entity_id, locus_path);
                        return error.ReferenceSyntax;
                    }
                }
                if (i == lab_start) {
                    setFail(fail_out, body, start, entity_id, locus_path);
                    return error.ReferenceSyntax;
                }
                label = body[lab_start..i];
            }

            if (i + 1 >= body.len or body[i] != ']' or body[i + 1] != ']') {
                setFail(fail_out, body, start, entity_id, locus_path);
                return error.ReferenceSyntax;
            }
            i += 2;
            const lc = include_mod.lineColAt(body, start);
            try out.append(allocator, .{
                .entity_id = entity_id,
                .fragment = fragment,
                .label = label,
                .offset = start,
                .end = i,
                .line = lc.line,
                .column = lc.column,
            });
            continue;
        }
        i += 1;
    }
}

fn buildNodeMap(allocator: std.mem.Allocator, nodes: []const graph_mod.Node) !std.StringHashMapUnmanaged(graph_mod.Node) {
    var map: std.StringHashMapUnmanaged(graph_mod.Node) = .{};
    errdefer map.deinit(allocator);
    try map.ensureTotalCapacity(allocator, @intCast(nodes.len));
    for (nodes) |n| {
        const gop = try map.getOrPut(allocator, n.id);
        if (!gop.found_existing) gop.value_ptr.* = n;
    }
    return map;
}

fn findNodeMap(map: *const std.StringHashMapUnmanaged(graph_mod.Node), id: []const u8) ?graph_mod.Node {
    return map.get(id);
}

fn appendUniqueIdLocHashed(
    locs: *std.ArrayList(IdLoc),
    seen: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
    loc: IdLoc,
) !void {
    const gop = try seen.getOrPut(allocator, loc.id);
    if (gop.found_existing) return;
    try locs.append(allocator, loc);
}

fn escapeMdLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    // Minimal: escape `]` and `\` in link text.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (label) |c| {
        if (c == '\\' or c == ']') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

/// Options for wiki rewrite / reference validation.
pub const ResolveOptions = struct {
    /// When non-null, used to validate fragment membership.
    /// When null and `validate_fragments` is true, any fragment fails closed.
    heading_index: ?*const HeadingIndex = null,
    /// When true, fragments require a heading index + membership (fail closed).
    /// Set false only while bootstrapping the heading index (emit, do not check).
    validate_fragments: bool = true,
};

fn failFragmentDetail(
    fail_out: ?*FailInfo,
    line: u32,
    column: u32,
    entity_id: []const u8,
    frag: []const u8,
    locus: []const u8,
) void {
    if (fail_out) |f| {
        var detail_buf: [include_mod.max_fail_str]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s}#{s}", .{ entity_id, frag }) catch entity_id;
        f.set(line, column, detail, locus);
    }
}

fn checkFragment(
    opts: ResolveOptions,
    entity_id: []const u8,
    frag: []const u8,
    line: u32,
    column: u32,
    locus: []const u8,
    fail_out: ?*FailInfo,
) WikiError!void {
    if (!opts.validate_fragments) return;
    const idx = opts.heading_index orelse {
        failFragmentDetail(fail_out, line, column, entity_id, frag, locus);
        return error.ReferenceMissing;
    };
    switch (idx.lookup(entity_id, frag)) {
        .ok => {},
        .unknown_fragment => {
            failFragmentDetail(fail_out, line, column, entity_id, frag, locus);
            return error.ReferenceMissing;
        },
        .unknown_entity => {
            // The page itself is absent from the index, which (every indexed
            // fragment target being a real PageDb page) means the entity does
            // not exist. Report the missing ENTITY, not a missing heading on a
            // page that was never there. Detail without '#' selects the
            // page-graph message in `messageFor`, matching the render path.
            if (fail_out) |f| f.set(line, column, entity_id, locus);
            return error.ReferenceMissing;
        },
    }
}

/// Rewrite wiki-links to Markdown links using frozen graph nodes.
/// `current_output_path` is the including page's HTML path (e.g. `guides/a.html`).
pub fn rewriteWikiLinks(
    allocator: std.mem.Allocator,
    body: []const u8,
    nodes: []const graph_mod.Node,
    current_output_path: []const u8,
    fail_out: ?*FailInfo,
) WikiError![]u8 {
    return rewriteWikiLinksOpts(allocator, body, nodes, current_output_path, fail_out, .{});
}

pub fn rewriteWikiLinksOpts(
    allocator: std.mem.Allocator,
    body: []const u8,
    nodes: []const graph_mod.Node,
    current_output_path: []const u8,
    fail_out: ?*FailInfo,
    opts: ResolveOptions,
) WikiError![]u8 {
    var hits: std.ArrayList(WikiHit) = .empty;
    defer hits.deinit(allocator);
    try scanWikiLinks(body, allocator, &hits, fail_out, "");

    if (hits.items.len == 0) {
        return try allocator.dupe(u8, body);
    }

    var node_map = try buildNodeMap(allocator, nodes);
    defer node_map.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var copy_from: usize = 0;

    for (hits.items) |hit| {
        const node = findNodeMap(&node_map, hit.entity_id) orelse {
            if (fail_out) |f| f.set(hit.line, hit.column, hit.entity_id, "");
            return error.ReferenceMissing;
        };

        if (hit.fragment) |frag| {
            try checkFragment(opts, hit.entity_id, frag, hit.line, hit.column, "", fail_out);
        }

        try out.appendSlice(allocator, body[copy_from..hit.offset]);

        const to_out = identity.htmlOutputPath(allocator, node.id) catch {
            if (fail_out) |f| f.set(hit.line, hit.column, hit.entity_id, "");
            return error.PathError;
        };
        defer allocator.free(to_out);
        const href = identity.relativeHref(allocator, current_output_path, to_out) catch {
            if (fail_out) |f| f.set(hit.line, hit.column, hit.entity_id, "");
            return error.PathError;
        };
        defer allocator.free(href);

        const raw_label = hit.label orelse (node.title orelse node.id);
        const label = try escapeMdLabel(allocator, raw_label);
        defer allocator.free(label);

        try out.append(allocator, '[');
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, "](");
        try out.appendSlice(allocator, href);
        if (hit.fragment) |frag| {
            try out.append(allocator, '#');
            const enc = try encodeFragment(allocator, frag);
            defer allocator.free(enc);
            try out.appendSlice(allocator, enc);
        }
        try out.append(allocator, ')');

        copy_from = hit.end;
    }
    try out.appendSlice(allocator, body[copy_from..]);
    return try out.toOwnedSlice(allocator);
}

/// First-seen location of a wiki entity id (for fingerprint diagnostics).
const IdLoc = struct {
    id: []const u8,
    line: u32,
    column: u32,
    /// Content-root path of the body that contained this hit (may be empty).
    locus: []const u8,
    /// Optional fragment for validation only (not part of fingerprint material).
    fragment: ?[]const u8 = null,
};

fn collectIdsFromBody(
    body: []const u8,
    body_path: []const u8,
    allocator: std.mem.Allocator,
    locs: *std.ArrayList(IdLoc),
    seen: *std.StringHashMapUnmanaged(void),
    fail_out: ?*FailInfo,
    opts: ResolveOptions,
) WikiError!void {
    var hits: std.ArrayList(WikiHit) = .empty;
    defer hits.deinit(allocator);
    try scanWikiLinks(body, allocator, &hits, fail_out, body_path);
    for (hits.items) |h| {
        if (h.fragment) |frag| {
            try checkFragment(opts, h.entity_id, frag, h.line, h.column, body_path, fail_out);
        }
        try appendUniqueIdLocHashed(locs, seen, allocator, .{
            .id = h.entity_id,
            .line = h.line,
            .column = h.column,
            .locus = body_path,
            .fragment = h.fragment,
        });
    }
}

/// Collect unique entity ids that appear as wiki fragment targets in `body`.
/// Views into hits (entity_id slices view `body`); caller may need to dupe for long life.
pub fn collectFragmentTargetIds(
    body: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    fail_out: ?*FailInfo,
    locus_path: []const u8,
) WikiError!void {
    var hits: std.ArrayList(WikiHit) = .empty;
    defer hits.deinit(allocator);
    try scanWikiLinks(body, allocator, &hits, fail_out, locus_path);
    for (hits.items) |h| {
        if (h.fragment == null) continue;
        const gop = try seen.getOrPut(allocator, h.entity_id);
        if (gop.found_existing) continue;
        try out.append(allocator, h.entity_id);
    }
}

fn materialFromIdLocs(
    allocator: std.mem.Allocator,
    locs: []const IdLoc,
    nodes: []const graph_mod.Node,
    fail_out: ?*FailInfo,
) WikiError![]u8 {
    if (locs.len == 0) return try allocator.dupe(u8, "");

    const sorted = try allocator.alloc(IdLoc, locs.len);
    defer allocator.free(sorted);
    @memcpy(sorted, locs);
    std.mem.sort(IdLoc, sorted, {}, struct {
        fn less(_: void, a: IdLoc, b: IdLoc) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);

    var node_map = try buildNodeMap(allocator, nodes);
    defer node_map.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (sorted) |loc| {
        const node = findNodeMap(&node_map, loc.id) orelse {
            if (fail_out) |f| f.set(loc.line, loc.column, loc.id, loc.locus);
            return error.ReferenceMissing;
        };
        const out_path = identity.htmlOutputPath(allocator, node.id) catch {
            if (fail_out) |f| f.set(loc.line, loc.column, loc.id, loc.locus);
            return error.PathError;
        };
        defer allocator.free(out_path);
        try out.appendSlice(allocator, loc.id);
        try out.append(allocator, 0);
        try out.appendSlice(allocator, out_path);
        try out.append(allocator, 0);
        if (node.title) |t| try out.appendSlice(allocator, t);
        try out.append(allocator, 0);
    }
    return try out.toOwnedSlice(allocator);
}

/// Stable fingerprint material for referenced entities in one body (sorted by id).
pub fn referenceMaterial(
    allocator: std.mem.Allocator,
    body: []const u8,
    nodes: []const graph_mod.Node,
) WikiError![]u8 {
    return referenceMaterialMulti(allocator, &.{body}, null, nodes, null, .{});
}

/// Union wiki targets from multiple bodies (page + transitive include fragments).
/// Title/path renames of targets linked only via includes still dirty the parent.
///
/// `body_paths` is optional and, when non-null, must match `bodies.len`. Each path
/// is the content-root path of that body (page source or include fragment) so
/// missing-target diagnostics report the correct file + line/column.
pub fn referenceMaterialMulti(
    allocator: std.mem.Allocator,
    bodies: []const []const u8,
    body_paths: ?[]const []const u8,
    nodes: []const graph_mod.Node,
    fail_out: ?*FailInfo,
    opts: ResolveOptions,
) WikiError![]u8 {
    if (body_paths) |paths| {
        if (paths.len != bodies.len) return error.PathError;
    }
    var locs: std.ArrayList(IdLoc) = .empty;
    defer locs.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);
    for (bodies, 0..) |body, i| {
        const path = if (body_paths) |paths| paths[i] else "";
        try collectIdsFromBody(body, path, allocator, &locs, &seen, fail_out, opts);
    }
    return materialFromIdLocs(allocator, locs.items, nodes, fail_out);
}

pub fn errorCode(err: WikiError) diag.Code {
    return switch (err) {
        error.ReferenceSyntax => .EREFERENCESYNTAX,
        error.ReferenceMissing => .EREFERENCEMISSING,
        error.OutOfMemory => .EIO,
        error.PathError => .EINVALIDPATH,
    };
}

pub fn remediationFor(code: diag.Code) []const u8 {
    return switch (code) {
        .EREFERENCESYNTAX => "Use [[entity-id]], [[entity-id|label]], [[entity-id#heading-id]], or [[entity-id#heading-id|label]]; heading-id must be non-empty",
        .EREFERENCEMISSING => "Point the wiki-link at an existing page entity id, and if using #heading-id match a rendered heading id on that page",
        .EINVALIDPATH => "Fix the target entity id so its output path is valid",
        .EIO => "Check memory and path spelling",
        else => "Fix the wiki-link",
    };
}

fn messageFor(retain: std.mem.Allocator, err: WikiError, fail: *const FailInfo) ![]const u8 {
    const det = fail.detail();
    return switch (err) {
        error.ReferenceSyntax => if (det.len > 0)
            try std.fmt.allocPrint(retain, "malformed wiki-link near \"{s}\"", .{det})
        else
            try retain.dupe(u8, "malformed [[…]] wiki-link"),
        error.ReferenceMissing => blk: {
            if (det.len > 0) {
                if (std.mem.indexOfScalar(u8, det, '#')) |_| {
                    break :blk try std.fmt.allocPrint(retain, "wiki-link heading target \"{s}\" not found on the page", .{det});
                }
                break :blk try std.fmt.allocPrint(retain, "wiki-link target \"{s}\" not found in the page graph", .{det});
            }
            break :blk try retain.dupe(u8, "wiki-link target not found in the page graph");
        },
        error.OutOfMemory => try retain.dupe(u8, "out of memory while resolving wiki-links"),
        error.PathError => if (det.len > 0)
            try std.fmt.allocPrint(retain, "cannot build output path for wiki target \"{s}\"", .{det})
        else
            try retain.dupe(u8, "cannot build output path for wiki target"),
    };
}

/// Build a retain-owned diagnostic for a wiki-link failure.
/// When `fail.locus()` is non-empty (include fragment body), it is used as `source_path`.
pub fn makeDiagnostic(
    retain: std.mem.Allocator,
    err: WikiError,
    source_path: []const u8,
    fail: FailInfo,
) !diag.Diagnostic {
    const code = errorCode(err);
    const path = if (fail.locus().len > 0) fail.locus() else source_path;
    const det = fail.detail();
    return .{
        .severity = .error_,
        .code = code,
        .message = try messageFor(retain, err, &fail),
        .remediation = try retain.dupe(u8, remediationFor(code)),
        .source_path = try retain.dupe(u8, path),
        .line = fail.line,
        .column = fail.column,
        .id = if (det.len > 0) try retain.dupe(u8, det) else "",
    };
}

/// Print one structured wiki-link diagnostic to stderr via `diag.formatText`.
pub fn printDiagnostic(
    gpa: std.mem.Allocator,
    err: WikiError,
    source_path: []const u8,
    fail: FailInfo,
) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const d = makeDiagnostic(arena.allocator(), err, source_path, fail) catch return;
    const line = diag.formatText(d, gpa) catch return;
    defer gpa.free(line);
    std.debug.print("{s}\n", .{line});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "scanWikiLinks basic and fence skip" {
    const body =
        \\See [[guides/overview]] and [[guides/overview|Overview]].
        \\```
        \\[[fenced/skip]]
        \\```
        \\
    ;
    var list: std.ArrayList(WikiHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try scanWikiLinks(body, std.testing.allocator, &list, null, "");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("guides/overview", list.items[0].entity_id);
    try std.testing.expect(list.items[0].label == null);
    try std.testing.expect(list.items[0].fragment == null);
    try std.testing.expectEqualStrings("Overview", list.items[1].label.?);
}

test "scanWikiLinks skips tilde fences" {
    const body =
        \\[[guides/a]]
        \\~~~md
        \\[[fenced/skip]]
        \\~~~
        \\[[guides/b]]
        \\
    ;
    var list: std.ArrayList(WikiHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try scanWikiLinks(body, std.testing.allocator, &list, null, "");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("guides/a", list.items[0].entity_id);
    try std.testing.expectEqualStrings("guides/b", list.items[1].entity_id);
}

test "scanWikiLinks fragment and label" {
    const body = "See [[guides/a#section-one]] and [[guides/a#code-x-y|Code]].";
    var list: std.ArrayList(WikiHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try scanWikiLinks(body, std.testing.allocator, &list, null, "");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("guides/a", list.items[0].entity_id);
    try std.testing.expectEqualStrings("section-one", list.items[0].fragment.?);
    try std.testing.expectEqualStrings("code-x-y", list.items[1].fragment.?);
    try std.testing.expectEqualStrings("Code", list.items[1].label.?);
}

test "scanWikiLinks empty fragment is syntax" {
    var list: std.ArrayList(WikiHit) = .empty;
    defer list.deinit(std.testing.allocator);
    var fail: FailInfo = .{};
    try std.testing.expectError(
        error.ReferenceSyntax,
        scanWikiLinks("bad [[guides/a#]]", std.testing.allocator, &list, &fail, "page.md"),
    );
}

test "scanWikiLinks syntax FailInfo" {
    var list: std.ArrayList(WikiHit) = .empty;
    defer list.deinit(std.testing.allocator);
    var fail: FailInfo = .{};
    try std.testing.expectError(
        error.ReferenceSyntax,
        scanWikiLinks("bad [[#only-hash]]", std.testing.allocator, &list, &fail, "page.md"),
    );
    // Empty id before # → syntax at the [[
    try std.testing.expectEqual(@as(u32, 1), fail.line);
    try std.testing.expectEqualStrings("page.md", fail.locus());
}

test "rewriteWikiLinks relative href" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "guides/overview",
            .source_path = "guides/overview.md",
            .title = "Content Model",
            .role = .trunk,
            .index = 0,
        },
        .{
            .id = "getting-started",
            .source_path = "getting-started.md",
            .title = "Getting Started",
            .role = .trunk,
            .index = 1,
        },
    };
    const body = "Go to [[guides/overview]] please.";
    const out = try rewriteWikiLinks(gpa, body, &nodes, "getting-started.html", null);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Content Model](guides/overview.html)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[[") == null);
}

test "rewriteWikiLinks with validated fragment" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "guides/overview",
            .source_path = "guides/overview.md",
            .title = "Content Model",
            .role = .trunk,
            .index = 0,
        },
        .{
            .id = "getting-started",
            .source_path = "getting-started.md",
            .title = "Getting Started",
            .role = .trunk,
            .index = 1,
        },
    };
    var idx: HeadingIndex = .{};
    defer idx.deinit(gpa);
    try idx.putOwned(gpa, "guides/overview", &.{"section-one"});

    const body = "Go to [[guides/overview#section-one]] please.";
    const out = try rewriteWikiLinksOpts(gpa, body, &nodes, "getting-started.html", null, .{
        .heading_index = &idx,
        .validate_fragments = true,
    });
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Content Model](guides/overview.html#section-one)") != null);
}

test "rewriteWikiLinks missing fragment fails loud" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "guides/overview",
            .source_path = "guides/overview.md",
            .title = "Content Model",
            .role = .trunk,
            .index = 0,
        },
    };
    var idx: HeadingIndex = .{};
    defer idx.deinit(gpa);
    try idx.putOwned(gpa, "guides/overview", &.{"section-one"});

    var fail: FailInfo = .{};
    try std.testing.expectError(error.ReferenceMissing, rewriteWikiLinksOpts(
        gpa,
        "See [[guides/overview#nope]]",
        &nodes,
        "index.html",
        &fail,
        .{ .heading_index = &idx, .validate_fragments = true },
    ));
    try std.testing.expect(std.mem.indexOf(u8, fail.detail(), "nope") != null);
}

test "rewriteWikiLinks fail-closed without heading index" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "guides/overview",
            .source_path = "guides/overview.md",
            .title = "Content Model",
            .role = .trunk,
            .index = 0,
        },
    };
    var fail: FailInfo = .{};
    // Default opts validate_fragments=true with null index → fail closed.
    try std.testing.expectError(
        error.ReferenceMissing,
        rewriteWikiLinks(gpa, "See [[guides/overview#section-one]]", &nodes, "index.html", &fail),
    );
    try std.testing.expect(std.mem.indexOf(u8, fail.detail(), "#") != null);
}

test "rewriteWikiLinks bootstrap mode emits fragment without validation" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "guides/overview",
            .source_path = "guides/overview.md",
            .title = "Content Model",
            .role = .trunk,
            .index = 0,
        },
    };
    const out = try rewriteWikiLinksOpts(
        gpa,
        "See [[guides/overview#anything]]",
        &nodes,
        "index.html",
        null,
        .{ .heading_index = null, .validate_fragments = false },
    );
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "guides/overview.html#anything") != null);
}

test "scanWikiLinks fragment inside fence is skipped" {
    const body =
        \\[[guides/a#live]]
        \\```
        \\[[guides/a#fenced]]
        \\```
        \\
    ;
    var list: std.ArrayList(WikiHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try scanWikiLinks(body, std.testing.allocator, &list, null, "");
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("live", list.items[0].fragment.?);
}

test "HeadingIndex lookup distinguishes unknown entity from unknown fragment" {
    const gpa = std.testing.allocator;
    var idx: HeadingIndex = .{};
    defer idx.deinit(gpa);
    try idx.putOwned(gpa, "p", &.{"sec"});
    try std.testing.expectEqual(HeadingIndex.Lookup.ok, idx.lookup("p", "sec"));
    try std.testing.expectEqual(HeadingIndex.Lookup.unknown_fragment, idx.lookup("p", "nope"));
    try std.testing.expectEqual(HeadingIndex.Lookup.unknown_entity, idx.lookup("gone", "sec"));
}

test "plan path reports missing entity, not missing heading, for [[typo#frag]]" {
    const gpa = std.testing.allocator;
    var idx: HeadingIndex = .{};
    defer idx.deinit(gpa);
    // A real, indexed page. The linked entity below does not exist at all.
    try idx.putOwned(gpa, "guides/overview", &.{"section-one"});

    const nodes = [_]graph_mod.Node{.{
        .id = "guides/overview",
        .source_path = "guides/overview.md",
        .title = "Content Model",
        .role = .trunk,
        .index = 0,
    }};

    var fail: FailInfo = .{};
    const bodies = [_][]const u8{"See [[guides/typo#section-one]]"};
    try std.testing.expectError(error.ReferenceMissing, referenceMaterialMulti(
        gpa,
        &bodies,
        null,
        &nodes,
        &fail,
        .{ .heading_index = &idx, .validate_fragments = true },
    ));
    // Detail must name the ENTITY with no '#', so messageFor emits "not found in
    // the page graph" instead of blaming a heading on a page that never existed.
    try std.testing.expect(std.mem.indexOfScalar(u8, fail.detail(), '#') == null);
    try std.testing.expectEqualStrings("guides/typo", fail.detail());
}

test "plan path still reports missing heading on an existing page" {
    const gpa = std.testing.allocator;
    var idx: HeadingIndex = .{};
    defer idx.deinit(gpa);
    try idx.putOwned(gpa, "guides/overview", &.{"section-one"});

    const nodes = [_]graph_mod.Node{.{
        .id = "guides/overview",
        .source_path = "guides/overview.md",
        .title = "Content Model",
        .role = .trunk,
        .index = 0,
    }};

    var fail: FailInfo = .{};
    const bodies = [_][]const u8{"See [[guides/overview#nope]]"};
    try std.testing.expectError(error.ReferenceMissing, referenceMaterialMulti(
        gpa,
        &bodies,
        null,
        &nodes,
        &fail,
        .{ .heading_index = &idx, .validate_fragments = true },
    ));
    // Real page, bad heading → still the fragment form (entity#frag).
    try std.testing.expect(std.mem.indexOfScalar(u8, fail.detail(), '#') != null);
}

test "HeadingIndex duplicate ids are set membership" {
    const gpa = std.testing.allocator;
    var idx: HeadingIndex = .{};
    defer idx.deinit(gpa);
    // putOwned stores unique list as provided; has is membership.
    try idx.putOwned(gpa, "p", &.{ "dup", "other" });
    try std.testing.expect(idx.has("p", "dup"));
    try std.testing.expect(idx.has("p", "other"));
    try std.testing.expect(!idx.has("p", "missing"));
    try std.testing.expect(!idx.has("nope", "dup"));
}

test "rewriteWikiLinks missing target with FailInfo" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{};
    var fail: FailInfo = .{};
    try std.testing.expectError(
        error.ReferenceMissing,
        rewriteWikiLinks(gpa, "See [[missing/page]] here", &nodes, "index.html", &fail),
    );
    try std.testing.expectEqualStrings("missing/page", fail.detail());
    try std.testing.expectEqual(@as(u32, 1), fail.line);
}

test "encodeFragment leaves unreserved plain" {
    const gpa = std.testing.allocator;
    const a = try encodeFragment(gpa, "section-one");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("section-one", a);
    const b = try encodeFragment(gpa, "has/slash");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("has%2Fslash", b);
}

test "makeDiagnostic maps ReferenceMissing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var fail: FailInfo = .{};
    fail.set(2, 4, "missing/id", "");
    const d = try makeDiagnostic(arena.allocator(), error.ReferenceMissing, "a.md", fail);
    try std.testing.expect(d.code == .EREFERENCEMISSING);
    const line = try diag.formatText(d, gpa);
    defer gpa.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "EREFERENCEMISSING") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "a.md:2:4") != null);
}

test "makeDiagnostic maps missing heading fragment" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var fail: FailInfo = .{};
    fail.set(1, 1, "guides/a#missing", "");
    const d = try makeDiagnostic(arena.allocator(), error.ReferenceMissing, "a.md", fail);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "heading target") != null);
}

test "referenceMaterialMulti unions page and include bodies" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "alpha",
            .source_path = "alpha.md",
            .title = "Alpha",
            .role = .trunk,
            .index = 0,
        },
        .{
            .id = "beta",
            .source_path = "beta.md",
            .title = "Beta",
            .role = .trunk,
            .index = 1,
        },
    };
    const page_body = "Page links [[alpha]] only.";
    const include_body = "Fragment links [[beta]] only.";
    const multi = try referenceMaterialMulti(gpa, &.{ page_body, include_body }, null, &nodes, null, .{});
    defer gpa.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "beta") != null);

    const page_only = try referenceMaterial(gpa, page_body, &nodes);
    defer gpa.free(page_only);
    try std.testing.expect(std.mem.indexOf(u8, page_only, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_only, "beta") == null);
}

test "referenceMaterialMulti missing target keeps include locus" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{
        .{
            .id = "alpha",
            .source_path = "alpha.md",
            .title = "Alpha",
            .role = .trunk,
            .index = 0,
        },
    };
    const page_body = "No wiki here.";
    const include_body = "Line1\nSee [[missing/id]] please.";
    const paths = [_][]const u8{ "alpha.md", "includes/blurb.md" };
    var fail: FailInfo = .{};
    try std.testing.expectError(
        error.ReferenceMissing,
        referenceMaterialMulti(gpa, &.{ page_body, include_body }, &paths, &nodes, &fail, .{}),
    );
    try std.testing.expectEqualStrings("missing/id", fail.detail());
    try std.testing.expectEqualStrings("includes/blurb.md", fail.locus());
    try std.testing.expectEqual(@as(u32, 2), fail.line);
}
