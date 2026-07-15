//! Boris-mediated wiki-links (`[[entity-id]]` / `[[entity-id|label]]`).
//!
//! Resolved against the frozen page graph by entity id **before** Apex.
//! Fence-aware: links inside fenced code stay literal.
//!
//! Normative: `docs/contracts/includes-and-wiki-links.md`.

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

pub const WikiHit = struct {
    entity_id: []const u8,
    label: ?[]const u8,
    offset: usize,
    end: usize,
    line: u32,
    column: u32,
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

/// Scan body for wiki-links outside fences. Views into `body`.
pub fn scanWikiLinks(body: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(WikiHit)) WikiError!void {
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
            if (i == id_start) return error.ReferenceSyntax;
            const entity_id = body[id_start..i];
            if (!identity.validateEntityId(entity_id)) return error.ReferenceSyntax;

            // No section anchors in MVP
            if (i < body.len and body[i] == '#') return error.ReferenceSyntax;

            var label: ?[]const u8 = null;
            if (i < body.len and body[i] == '|') {
                i += 1;
                const lab_start = i;
                while (i < body.len and !(body[i] == ']' and i + 1 < body.len and body[i + 1] == ']')) : (i += 1) {
                    if (body[i] == '\n' or body[i] == '\r') return error.ReferenceSyntax;
                }
                if (i == lab_start) return error.ReferenceSyntax;
                label = body[lab_start..i];
            }

            if (i + 1 >= body.len or body[i] != ']' or body[i + 1] != ']') {
                return error.ReferenceSyntax;
            }
            i += 2;
            const lc = include_mod.lineColAt(body, start);
            try out.append(allocator, .{
                .entity_id = entity_id,
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

fn findNode(nodes: []const graph_mod.Node, id: []const u8) ?graph_mod.Node {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, id)) return n;
    }
    return null;
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

/// Rewrite wiki-links to Markdown links using frozen graph nodes.
/// `current_output_path` is the including page's HTML path (e.g. `guides/a.html`).
pub fn rewriteWikiLinks(
    allocator: std.mem.Allocator,
    body: []const u8,
    nodes: []const graph_mod.Node,
    current_output_path: []const u8,
) WikiError![]u8 {
    var hits: std.ArrayList(WikiHit) = .empty;
    defer hits.deinit(allocator);
    try scanWikiLinks(body, allocator, &hits);

    if (hits.items.len == 0) {
        return try allocator.dupe(u8, body);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var copy_from: usize = 0;

    for (hits.items) |hit| {
        const node = findNode(nodes, hit.entity_id) orelse return error.ReferenceMissing;
        try out.appendSlice(allocator, body[copy_from..hit.offset]);

        const to_out = identity.htmlOutputPath(allocator, node.id) catch return error.PathError;
        defer allocator.free(to_out);
        const href = identity.relativeHref(allocator, current_output_path, to_out) catch return error.PathError;
        defer allocator.free(href);

        const raw_label = hit.label orelse (node.title orelse node.id);
        const label = try escapeMdLabel(allocator, raw_label);
        defer allocator.free(label);

        try out.append(allocator, '[');
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, "](");
        try out.appendSlice(allocator, href);
        try out.append(allocator, ')');

        copy_from = hit.end;
    }
    try out.appendSlice(allocator, body[copy_from..]);
    return try out.toOwnedSlice(allocator);
}

/// Stable fingerprint material for referenced entities (sorted by id).
pub fn referenceMaterial(
    allocator: std.mem.Allocator,
    body: []const u8,
    nodes: []const graph_mod.Node,
) WikiError![]u8 {
    var hits: std.ArrayList(WikiHit) = .empty;
    defer hits.deinit(allocator);
    try scanWikiLinks(body, allocator, &hits);
    if (hits.items.len == 0) return try allocator.dupe(u8, "");

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);
    for (hits.items) |h| {
        var exists = false;
        for (ids.items) |id| {
            if (std.mem.eql(u8, id, h.entity_id)) {
                exists = true;
                break;
            }
        }
        if (!exists) try ids.append(allocator, h.entity_id);
    }
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (ids.items) |id| {
        const node = findNode(nodes, id) orelse return error.ReferenceMissing;
        const out_path = identity.htmlOutputPath(allocator, node.id) catch return error.PathError;
        defer allocator.free(out_path);
        try out.appendSlice(allocator, id);
        try out.append(allocator, 0);
        try out.appendSlice(allocator, out_path);
        try out.append(allocator, 0);
        if (node.title) |t| try out.appendSlice(allocator, t);
        try out.append(allocator, 0);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn errorCode(err: WikiError) diag.Code {
    return switch (err) {
        error.ReferenceSyntax => .EREFERENCESYNTAX,
        error.ReferenceMissing => .EREFERENCEMISSING,
        error.OutOfMemory => .EIO,
        error.PathError => .EINVALIDPATH,
    };
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
    try scanWikiLinks(body, std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("guides/overview", list.items[0].entity_id);
    try std.testing.expect(list.items[0].label == null);
    try std.testing.expectEqualStrings("Overview", list.items[1].label.?);
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
    const out = try rewriteWikiLinks(gpa, body, &nodes, "getting-started.html");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Content Model](guides/overview.html)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[[") == null);
}

test "rewriteWikiLinks missing target" {
    const gpa = std.testing.allocator;
    const nodes = [_]graph_mod.Node{};
    try std.testing.expectError(
        error.ReferenceMissing,
        rewriteWikiLinks(gpa, "[[missing/page]]", &nodes, "index.html"),
    );
}
