const std = @import("std");
const graph_mod = @import("graph.zig");
const dependency = @import("dependency.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Fixed renderer/cache format version constant.
///
/// Bumped only when fingerprint inputs or manifest discriminator semantics
/// change. Adding optional manifest fields (e.g. `output_digest`) does not
/// require a bump when missing values force a safe re-render.
pub const CACHE_FORMAT_VERSION = "boris-cache-v1-multitarget";

/// Hash a u64 length prefix in fixed little-endian (host-independent).
fn updateLen(hasher: *Sha256, len: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, len, .little);
    hasher.update(&buf);
}

/// SHA-256 of published HTML (or any) bytes for content-addressed output freshness.
pub fn hashBytes(bytes: []const u8) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Lowercase hex encoding of a 32-byte digest (stable, deterministic).
pub fn hexDigest(digest: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// Compute a deterministic fingerprint for an HTML page from:
/// - a fixed renderer/cache format version constant
/// - target configuration identity (name and layout path)
/// - normalized page identity (entity_id)
/// - source bytes
/// - resolved include dependency bytes, in stable dependency order
/// - resolved layout bytes
/// - optional site-nav material (when layout has graph chrome; empty otherwise)
///
/// Ensures no timestamps, absolute paths, hostnames, pointer addresses,
/// random values, or unstable map iterations are factored in.
/// Length prefixes are little-endian u64 so digests match across endianness.
pub fn computePageFingerprint(
    target_name: []const u8,
    layout_path: []const u8,
    entity_id: []const u8,
    source_bytes: []const u8,
    include_deps: []const []const u8,
    layout_bytes: []const u8,
    site_nav_material: []const u8,
) [32]u8 {
    var hasher = Sha256.init(.{});

    // 1. Format version
    hasher.update(CACHE_FORMAT_VERSION);

    // 1.5. Target configuration identity
    updateLen(&hasher, target_name.len);
    hasher.update(target_name);

    updateLen(&hasher, layout_path.len);
    hasher.update(layout_path);

    // 2. Normalized page identity (entity_id)
    updateLen(&hasher, entity_id.len);
    hasher.update(entity_id);

    // 3. Source bytes
    updateLen(&hasher, source_bytes.len);
    hasher.update(source_bytes);

    // 4. Resolved includes in stable dependency order
    for (include_deps) |inc_bytes| {
        updateLen(&hasher, inc_bytes.len);
        hasher.update(inc_bytes);
    }

    // 5. Layout bytes
    updateLen(&hasher, layout_bytes.len);
    hasher.update(layout_bytes);

    // 6. Site nav material (Feature 6) — only when non-empty so content-only
    // layouts keep prior fingerprint inputs.
    if (site_nav_material.len > 0) {
        updateLen(&hasher, site_nav_material.len);
        hasher.update(site_nav_material);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Calculate the page IDs affected by a changed source/layout/include path.
/// Build an affected-set query using the frozen reverse dependency index:
///   - changed page source -> that page and transitive reverse dependents
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
            // Continue reverse walk so page→page (parent/reference) edges propagate.
            if (dep_index.reverse.get(page_id)) |dep_list| {
                for (dep_list.items) |dep| {
                    try stack.append(allocator, dep.path);
                }
            }
            // Also walk reverse keyed by source path when deps used path form.
            if (!std.mem.eql(u8, page_id, curr)) {
                if (dep_index.reverse.get(curr)) |dep_list| {
                    for (dep_list.items) |dep| {
                        try stack.append(allocator, dep.path);
                    }
                }
            }
        } else {
            if (dep_index.reverse.get(curr)) |dep_list| {
                for (dep_list.items) |dep| {
                    try stack.append(allocator, dep.path);
                }
            }
        }
    }

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var it = affected_ids.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }

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
    const key1 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "source data", &.{ "inc1", "inc2" }, "layout content", "");
    const key2 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "source data", &.{ "inc1", "inc2" }, "layout content", "");
    try std.testing.expectEqualSlices(u8, &key1, &key2);
}

test "fingerprint length prefixes are little-endian fixed" {
    // Smoke: non-empty inputs still stable; endianness fixed via writeInt(.little).
    const key = computePageFingerprint("t", "l", "id", "s", &.{}, "L", "n");
    const key2 = computePageFingerprint("t", "l", "id", "s", &.{}, "L", "n");
    try std.testing.expectEqualSlices(u8, &key, &key2);
}

test "output digest helpers are deterministic and content-sensitive" {
    const a = hashBytes("hello");
    const b = hashBytes("hello");
    const c = hashBytes("hallo");
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));

    const ha = hexDigest(a);
    const hb = hexDigest(b);
    try std.testing.expectEqualSlices(u8, &ha, &hb);
    try std.testing.expectEqual(@as(usize, 64), ha.len);
    const hc = hexDigest(c);
    try std.testing.expect(!std.mem.eql(u8, &ha, &hc));
}

test "Source change changes only that page's key" {
    const key1 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "source data", &.{ "inc1", "inc2" }, "layout content", "");
    const key2 = computePageFingerprint("default", "layouts/main.html", "guides/intro", "modified source", &.{ "inc1", "inc2" }, "layout content", "");

    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));

    const key3 = computePageFingerprint("default", "layouts/main.html", "guides/outro", "source data", &.{ "inc1", "inc2" }, "layout content", "");
    try std.testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "Target configuration changes isolate page keys" {
    const key_prod = computePageFingerprint("prod", "layouts/main.html", "guides/intro", "source data", &.{ "inc1", "inc2" }, "layout content", "");
    const key_stage = computePageFingerprint("stage", "layouts/main.html", "guides/intro", "source data", &.{ "inc1", "inc2" }, "layout content", "");
    const key_ref = computePageFingerprint("prod", "layouts/ref.html", "guides/intro", "source data", &.{ "inc1", "inc2" }, "layout content", "");

    try std.testing.expect(!std.mem.eql(u8, &key_prod, &key_stage));
    try std.testing.expect(!std.mem.eql(u8, &key_prod, &key_ref));
}

test "Affected pages query scenarios" {
    const gpa = std.testing.allocator;

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

    var dep_index = dependency.DependencyIndex.init(gpa);
    defer dep_index.deinit();

    try dep_index.addDependency("guides/intro", "layouts/main.html", .layout);
    try dep_index.addDependency("guides/intro", "includes/sidebar.html", .include);

    try dep_index.addDependency("guides/outro", "layouts/main.html", .layout);
    try dep_index.addDependency("guides/outro", "includes/sidebar.html", .include);

    try dep_index.addDependency("reference/index", "layouts/ref.html", .layout);

    try dep_index.addDependency("includes/sidebar.html", "includes/widget.html", .include);

    // page→page reference: intro references install-style id "guides/outro"
    try dep_index.addDependency("guides/intro", "guides/outro", .reference);

    {
        const affected = try getAffectedPages(gpa, "content/guides/intro.md", &nodes, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 1), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
    }

    // Editing the reference *target* dirties the referrer (page→page reverse).
    {
        const affected = try getAffectedPages(gpa, "content/guides/outro.md", &nodes, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 2), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
        try std.testing.expectEqualStrings("guides/outro", affected[1]);
    }

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
