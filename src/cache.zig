const std = @import("std");
const graph_mod = @import("graph.zig");
const dependency = @import("dependency.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Fixed renderer/cache format version constant.
pub const CACHE_FORMAT_VERSION = "boris-cache-v1-multitarget";

/// Compute a deterministic fingerprint for an HTML page from:
/// - a fixed renderer/cache format version constant
/// - target configuration identity (name and layout path)
/// - normalized page identity (entity_id)
/// - source bytes
/// - resolved include dependency bytes, in stable dependency order
/// - resolved layout bytes
///
/// Ensures no timestamps, absolute paths, hostnames, pointer addresses,
/// random values, or unstable map iterations are factored in.
pub fn computePageFingerprint(
    target_name: []const u8,
    layout_path: []const u8,
    entity_id: []const u8,
    source_bytes: []const u8,
    include_deps: []const []const u8,
    layout_bytes: []const u8,
) [32]u8 {
    var hasher = Sha256.init(.{});

    // 1. Format version
    hasher.update(CACHE_FORMAT_VERSION);

    // 1.5. Target configuration identity
    const target_len: u64 = target_name.len;
    hasher.update(std.mem.asBytes(&target_len));
    hasher.update(target_name);

    const path_len: u64 = layout_path.len;
    hasher.update(std.mem.asBytes(&path_len));
    hasher.update(layout_path);

    // 2. Normalized page identity (entity_id)
    const id_len: u64 = entity_id.len;
    hasher.update(std.mem.asBytes(&id_len));
    hasher.update(entity_id);

    // 3. Source bytes
    const src_len: u64 = source_bytes.len;
    hasher.update(std.mem.asBytes(&src_len));
    hasher.update(source_bytes);

    // 4. Resolved includes in stable dependency order
    for (include_deps) |inc_bytes| {
        const inc_len: u64 = inc_bytes.len;
        hasher.update(std.mem.asBytes(&inc_len));
        hasher.update(inc_bytes);
    }

    // 5. Layout bytes
    const layout_len: u64 = layout_bytes.len;
    hasher.update(std.mem.asBytes(&layout_len));
    hasher.update(layout_bytes);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Calculate the page IDs affected by a changed source/layout/include path.
/// Build an affected-set query using the frozen reverse dependency index:
///   - changed page source -> that page
///   - changed include/layout path -> every transitive dependent page
///   - return sorted entity IDs with duplicates removed
///
/// The returned slice is owned by the caller and allocated using the provided allocator.
pub fn getAffectedPages(
    allocator: std.mem.Allocator,
    changed_path: []const u8,
    nodes: []const graph_mod.Node,
    dep_index: *const dependency.DependencyIndex,
) ![]const []const u8 {
    // 1. Check if changed_path is a direct page source path or page ID.
    // If we find a node in the graph matching node.source_path or node.id,
    // that page itself is affected.
    for (nodes) |node| {
        if (std.mem.eql(u8, node.source_path, changed_path) or std.mem.eql(u8, node.id, changed_path)) {
            const result = try allocator.alloc([]const u8, 1);
            result[0] = try allocator.dupe(u8, node.id);
            return result;
        }
    }

    // 2. Otherwise, treat changed_path as an include/layout path and traverse reverse dependencies.
    var affected_ids: std.StringHashMapUnmanaged(void) = .{};
    defer affected_ids.deinit(allocator);

    var visited: std.StringHashMapUnmanaged(void) = .{};
    defer visited.deinit(allocator);

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);

    try stack.append(allocator, changed_path);

    while (stack.items.len > 0) {
        const curr = stack.pop().?;
        if (visited.contains(curr)) continue;
        try visited.put(allocator, curr, {});

        // Check if `curr` is a page (by checking nodes).
        var is_page = false;
        var page_id: []const u8 = "";
        for (nodes) |node| {
            if (std.mem.eql(u8, node.id, curr) or std.mem.eql(u8, node.source_path, curr)) {
                is_page = true;
                page_id = node.id;
                break;
            }
        }

        if (is_page) {
            try affected_ids.put(allocator, page_id, {});
        } else {
            // Traverse reverse dependencies if not a page.
            if (dep_index.reverse.get(curr)) |dep_list| {
                for (dep_list.items) |dep| {
                    try stack.append(allocator, dep.path);
                }
            }
        }
    }

    // 3. Collect unique page entity IDs into a list.
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var it = affected_ids.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }

    // 4. Sort alphabetically to ensure stable ordering.
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Same inputs produce the same key across runs" {
    const key1 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "source data", &.{"inc1", "inc2"}, "layout content");
    const key2 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "source data", &.{"inc1", "inc2"}, "layout content");
    try std.testing.expectEqualSlices(u8, &key1, &key2);
}

test "Source change changes only that page's key" {
    const key1 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "source data", &.{"inc1", "inc2"}, "layout content");
    const key2 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "modified source", &.{"inc1", "inc2"}, "layout content");

    // Changing source changes the key
    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));

    // Changing page ID changes the key
    const key3 = computePageFingerprint("default", "layouts/main.html", "guides/outro", "source data", &.{"inc1", "inc2"}, "layout content");
    try std.testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "Target configuration changes isolate page keys" {
    const key_prod = computePageFingerprint("prod", "layouts/main.html", "guides/intro", "source data", &.{"inc1", "inc2"}, "layout content");
    const key_stage = computePageFingerprint("stage", "layouts/main.html", "guides/intro", "source data", &.{"inc1", "inc2"}, "layout content");
    const key_ref = computePageFingerprint("prod", "layouts/ref.html", "guides/intro", "source data", &.{"inc1", "inc2"}, "layout content");

    // Different target name produces different key
    try std.testing.expect(!std.mem.eql(u8, &key_prod, &key_stage));

    // Different layout path produces different key
    try std.testing.expect(!std.mem.eql(u8, &key_prod, &key_ref));
}

test "Affected pages query scenarios" {
    const gpa = std.testing.allocator;

    // Create a mock frozen graph with nodes
    var nodes = [_]graph_mod.Node{
        .{
            .index = 0,
            .id = "guides/intro",
            .source_path = "content/guides/intro.md",
        },
        .{
            .index = 1,
            .id = "guides/outro",
            .source_path = "content/guides/outro.md",
        },
        .{
            .index = 2,
            .id = "reference/index",
            .source_path = "content/reference/index.md",
        },
    };

    // Populate a dependency index
    var dep_index = dependency.DependencyIndex.init(gpa);
    defer dep_index.deinit();

    // Setup relationships:
    // - intro and outro use "layouts/main.html"
    // - intro uses "includes/sidebar.html"
    // - outro uses "includes/sidebar.html"
    // - reference/index uses "layouts/ref.html"
    // - sidebar.html uses "includes/widget.html"
    try dep_index.addDependency("guides/intro", "layouts/main.html", .layout);
    try dep_index.addDependency("guides/intro", "includes/sidebar.html", .include);

    try dep_index.addDependency("guides/outro", "layouts/main.html", .layout);
    try dep_index.addDependency("guides/outro", "includes/sidebar.html", .include);

    try dep_index.addDependency("reference/index", "layouts/ref.html", .layout);

    try dep_index.addDependency("includes/sidebar.html", "includes/widget.html", .include);

    // Test Scenario: Source change changes only that page's key (direct query)
    {
        const affected = try getAffectedPages(gpa, "content/guides/intro.md", &nodes, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 1), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
    }

    // Test Scenario: Shared include change affects all dependent pages transitively
    {
        const affected = try getAffectedPages(gpa, "includes/widget.html", &nodes, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 2), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
        try std.testing.expectEqualStrings("guides/outro", affected[1]);
    }

    // Test Scenario: Layout change affects all pages using that layout
    {
        const affected = try getAffectedPages(gpa, "layouts/main.html", &nodes, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 2), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
        try std.testing.expectEqualStrings("guides/outro", affected[1]);
    }

    // Test Scenario: Unrelated page change does not affect unrelated pages
    {
        const affected = try getAffectedPages(gpa, "layouts/ref.html", &nodes, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 1), affected.len);
        try std.testing.expectEqualStrings("reference/index", affected[0]);
    }
}

test "Output ordering is stable" {
    const gpa = std.testing.allocator;

    var nodes = [_]graph_mod.Node{
        .{ .index = 0, .id = "z", .source_path = "content/z.md" },
        .{ .index = 1, .id = "a", .source_path = "content/a.md" },
        .{ .index = 2, .id = "m", .source_path = "content/m.md" },
    };

    var dep_index = dependency.DependencyIndex.init(gpa);
    defer dep_index.deinit();

    try dep_index.addDependency("z", "layouts/main.html", .layout);
    try dep_index.addDependency("a", "layouts/main.html", .layout);
    try dep_index.addDependency("m", "layouts/main.html", .layout);

    // Run query. Output must be sorted alphabetically: "a", "m", "z"
    const affected = try getAffectedPages(gpa, "layouts/main.html", &nodes, &dep_index);
    defer {
        for (affected) |item| gpa.free(item);
        gpa.free(affected);
    }

    try std.testing.expectEqual(@as(usize, 3), affected.len);
    try std.testing.expectEqualStrings("a", affected[0]);
    try std.testing.expectEqualStrings("m", affected[1]);
    try std.testing.expectEqualStrings("z", affected[2]);
}
