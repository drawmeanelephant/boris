//! Shared graph projection and deterministic Markdown partitioning for product
//! RAG/context exports. The pipeline remains the sole parser/validator.

const std = @import("std");
const graph = @import("graph.zig");

pub const Error = error{ InvalidScope, OversizedBlock };

pub fn selectPages(allocator: std.mem.Allocator, pages: []const graph.Node, scope: ?[]const u8) ![]const graph.Node {
    var included = try allocator.alloc(bool, pages.len);
    defer allocator.free(included);
    @memset(included, scope == null);
    var selected_seed = try allocator.alloc(bool, pages.len);
    defer allocator.free(selected_seed);
    @memset(selected_seed, false);

    if (scope) |wanted| {
        if (wanted.len == 0 or wanted[0] == '/' or std.mem.indexOf(u8, wanted, "..") != null or std.mem.indexOfScalar(u8, wanted, '\\') != null)
            return error.InvalidScope;
        var found = false;
        for (pages, 0..) |page, i| {
            if (std.mem.eql(u8, page.id, wanted) or
                (std.mem.startsWith(u8, page.id, wanted) and page.id.len > wanted.len and page.id[wanted.len] == '/'))
            {
                included[i] = true;
                selected_seed[i] = true;
                found = true;
            }
        }
        if (!found) return error.InvalidScope;

        // Semantic closure is one hop from the requested projection. Parent
        // closure is then applied to every selected neighbor as well.
        for (pages, 0..) |page, i| {
            if (!selected_seed[i]) continue;
            for (page.semantic_relations) |relation| {
                for (pages, 0..) |candidate, j| {
                    if (std.mem.eql(u8, candidate.id, relation.target)) included[j] = true;
                }
            }
        }
    }

    // Structural closure is transitive and deliberately runs after relation
    // projection, so a related satellite also carries its trunk chain.
    var changed = true;
    while (changed) {
        changed = false;
        for (pages, 0..) |page, i| {
            if (!included[i]) continue;
            if (page.parent) |parent| {
                for (pages, 0..) |candidate, j| {
                    if (!included[j] and std.mem.eql(u8, candidate.id, parent)) {
                        included[j] = true;
                        changed = true;
                    }
                }
            }
        }
    }

    var selected: std.ArrayList(graph.Node) = .empty;
    errdefer selected.deinit(allocator);
    for (pages, 0..) |page, i| if (included[i]) try selected.append(allocator, page);
    return try selected.toOwnedSlice(allocator);
}

pub fn isFenceLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 3) return false;
    return (trimmed[0] == '`' and trimmed[1] == '`' and trimmed[2] == '`') or
        (trimmed[0] == '~' and trimmed[1] == '~' and trimmed[2] == '~');
}

fn fenceLine(line: []const u8) ?struct { char: u8, length: usize } {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 3 or (trimmed[0] != '`' and trimmed[0] != '~')) return null;
    const char = trimmed[0];
    var length: usize = 0;
    while (length < trimmed.len and trimmed[length] == char) : (length += 1) {}
    if (length < 3) return null;
    return .{ .char = char, .length = length };
}

/// Split only at blank-line or heading boundaries outside fenced code. The
/// caller supplies the body budget after reserving its deterministic header.
pub fn partitionMarkdown(allocator: std.mem.Allocator, body: []const u8, max_body: usize) ![]const []const u8 {
    if (body.len <= max_body) {
        const one = try allocator.alloc([]const u8, 1);
        one[0] = body;
        return one;
    }
    if (max_body == 0) return error.OversizedBlock;

    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var start: usize = 0;
    while (start < body.len) {
        if (body.len - start <= max_body) {
            try parts.append(allocator, body[start..]);
            break;
        }
        const limit = @min(body.len, start + max_body);
        var cursor = start;
        var last_boundary: ?usize = null;
        var fence_char: u8 = 0;
        var fence_length: usize = 0;
        while (cursor < limit) {
            var end = cursor;
            while (end < body.len and body[end] != '\n') : (end += 1) {}
            const line_end = if (end < body.len) end + 1 else end;
            const line = body[cursor..end];
            if (fenceLine(line)) |fence| {
                if (fence_char == 0) {
                    fence_char = fence.char;
                    fence_length = fence.length;
                } else if (fence.char == fence_char and fence.length >= fence_length) {
                    fence_char = 0;
                    fence_length = 0;
                }
            }
            if (fence_char == 0 and line_end <= limit) {
                const blank = std.mem.trim(u8, line, " \t\r").len == 0;
                const heading = std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#");
                if (blank or heading) last_boundary = if (heading) cursor else line_end;
            }
            cursor = line_end;
        }
        const boundary = last_boundary orelse return error.OversizedBlock;
        if (boundary <= start) return error.OversizedBlock;
        try parts.append(allocator, body[start..boundary]);
        start = boundary;
    }
    return try parts.toOwnedSlice(allocator);
}

test "scope selects collection and closes parents plus semantic neighbors" {
    const relation = @import("page.zig").SemanticRelation{ .kind = .relates_to, .target = "other" };
    const transitive_relation = @import("page.zig").SemanticRelation{ .kind = .relates_to, .target = "transitive" };
    const pages = [_]graph.Node{
        .{ .id = "mascots", .source_path = "mascots.md", .role = .trunk },
        .{ .id = "mascots/child", .source_path = "child.md", .parent = "mascots", .role = .satellite, .semantic_relations = &.{relation} },
        .{ .id = "other", .source_path = "other.md", .role = .trunk, .semantic_relations = &.{transitive_relation} },
        .{ .id = "transitive", .source_path = "transitive.md", .role = .trunk },
    };
    const selected = try selectPages(std.testing.allocator, &pages, "mascots/child");
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    try std.testing.expect(std.mem.eql(u8, selected[0].id, "mascots"));
    try std.testing.expect(std.mem.eql(u8, selected[1].id, "mascots/child"));
    try std.testing.expect(std.mem.eql(u8, selected[2].id, "other"));
}

test "scope rejects empty and traversal selectors" {
    const pages = [_]graph.Node{.{ .id = "mascots", .source_path = "mascots.md" }};
    try std.testing.expectError(error.InvalidScope, selectPages(std.testing.allocator, &pages, ""));
    try std.testing.expectError(error.InvalidScope, selectPages(std.testing.allocator, &pages, "../mascots"));
    try std.testing.expectError(error.InvalidScope, selectPages(std.testing.allocator, &pages, "missing"));
}

test "partition preserves fenced code and reports indivisible blocks" {
    const body = "# One\n\ntext\n\n```\nlarge\n```\n\n# Two\n\nmore\n";
    const parts = try partitionMarkdown(std.testing.allocator, body, 24);
    defer std.testing.allocator.free(parts);
    try std.testing.expect(parts.len > 1);
    for (parts) |part| try std.testing.expect(std.mem.count(u8, part, "```") == 0 or std.mem.count(u8, part, "```") == 2);
    try std.testing.expectError(error.OversizedBlock, partitionMarkdown(std.testing.allocator, "a very long paragraph without a safe boundary", 8));
}

test "partition splits paragraphs and headings without cutting a fence" {
    const body = "# One\n\nfirst paragraph with words.\n\n```zig\nconst value = 1;\nconst other = 2;\n```\n\n# Two\n\nsecond paragraph.\n";
    const parts = try partitionMarkdown(std.testing.allocator, body, 55);
    defer std.testing.allocator.free(parts);
    try std.testing.expect(parts.len > 1);
    for (parts) |part| {
        try std.testing.expect(part.len <= 55);
        try std.testing.expectEqual(@as(usize, 0), @mod(std.mem.count(u8, part, "```"), 2));
    }
}
