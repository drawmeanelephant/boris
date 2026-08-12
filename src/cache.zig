const std = @import("std");
const graph_mod = @import("graph.zig");
const dependency = @import("dependency.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Fixed renderer/cache format version constant.
///
/// Bumped only when fingerprint inputs or manifest discriminator semantics
/// change. v3 mixes fixed-size digests of build-constant inputs (site-nav
/// material, layout bytes, theme material) into each page fingerprint so
/// constant material is hashed once per build instead of once per page
/// (`boris-cache-v3-constant-digests`). Older manifests force a cold rebuild.
pub const CACHE_FORMAT_VERSION = "boris-cache-v3-constant-digests";

/// Hash a u64 length prefix in fixed little-endian (host-independent).
fn updateLen(hasher: *Sha256, len: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, len, .little);
    hasher.update(&buf);
}

/// SHA-256 of a build-constant fingerprint input (site-nav material, layout
/// bytes, theme material). The domain marker plus a u64 little-endian length
/// prefix keep equal bytes in different roles (or at different lengths)
/// unambiguous across the fingerprint scheme (PERF-009).
pub fn constantDigest(comptime domain: []const u8, bytes: []const u8) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(domain);
    updateLen(&hasher, bytes.len);
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Mix a precomputed build-constant digest into a page fingerprint hasher.
/// The domain marker plus a fixed u64 length prefix keep the composition
/// explicit: a 32-byte digest is never confused with raw input bytes.
fn updateConstantDigest(hasher: *Sha256, comptime domain: []const u8, digest: [32]u8) void {
    hasher.update(domain);
    updateLen(hasher, 32);
    hasher.update(&digest);
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
/// - optional theme material (footer + referenced asset path/bytes; F9.1)
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
    return computePageFingerprintTheme(
        target_name,
        layout_path,
        entity_id,
        source_bytes,
        include_deps,
        layout_bytes,
        site_nav_material,
        "",
    );
}

/// Same as `computePageFingerprint` plus optional theme material (footer and
/// referenced asset bytes). Empty `theme_material` preserves prior digests for
/// layouts without managed theme inputs.
pub fn computePageFingerprintTheme(
    target_name: []const u8,
    layout_path: []const u8,
    entity_id: []const u8,
    source_bytes: []const u8,
    include_deps: []const []const u8,
    layout_bytes: []const u8,
    site_nav_material: []const u8,
    theme_material: []const u8,
) [32]u8 {
    return computePageFingerprintThemeInput(
        target_name,
        layout_path,
        entity_id,
        source_bytes,
        include_deps,
        layout_bytes,
        site_nav_material,
        theme_material,
        "",
    );
}

/// Same as `computePageFingerprintThemeInput`, but accepts precomputed digests
/// for the build-constant inputs (layout bytes, site-nav material, theme
/// material) so a multi-page build hashes that material exactly once per
/// build instead of once per page (PERF-009). `layout_digest` is always mixed;
/// `site_nav_digest` / `theme_digest` are mixed only when non-null, mirroring
/// the previous non-empty gating.
pub fn computePageFingerprintDigests(
    target_name: []const u8,
    layout_path: []const u8,
    entity_id: []const u8,
    source_bytes: []const u8,
    include_deps: []const []const u8,
    layout_digest: [32]u8,
    site_nav_digest: ?[32]u8,
    theme_digest: ?[32]u8,
    input_material: []const u8,
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

    // 5. Layout bytes digest (build-constant; hashed once per build)
    updateConstantDigest(&hasher, "boris-const:layout", layout_digest);

    // 6. Site nav material digest (Feature 6) — only when present so
    // content-only layouts keep the same input set.
    if (site_nav_digest) |d| updateConstantDigest(&hasher, "boris-const:nav", d);

    // 7. Theme material digest (F9.1) — footer + referenced assets.
    if (theme_digest) |d| updateConstantDigest(&hasher, "boris-const:theme", d);

    if (input_material.len > 0) {
        hasher.update("boris-input-adapter\x00");
        updateLen(&hasher, input_material.len);
        hasher.update(input_material);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Fingerprint with an optional input-adapter identity. Empty input material
/// preserves every Markdown-mode digest produced before Textile support.
pub fn computePageFingerprintThemeInput(
    target_name: []const u8,
    layout_path: []const u8,
    entity_id: []const u8,
    source_bytes: []const u8,
    include_deps: []const []const u8,
    layout_bytes: []const u8,
    site_nav_material: []const u8,
    theme_material: []const u8,
    input_material: []const u8,
) [32]u8 {
    return computePageFingerprintDigests(
        target_name,
        layout_path,
        entity_id,
        source_bytes,
        include_deps,
        constantDigest("boris-const:layout", layout_bytes),
        if (site_nav_material.len > 0) constantDigest("boris-const:nav", site_nav_material) else null,
        if (theme_material.len > 0) constantDigest("boris-const:theme", theme_material) else null,
        input_material,
    );
}

/// Calculate the page IDs affected by a changed source/layout/include path.
/// Build an affected-set query using the frozen reverse dependency index:
///   - changed page source -> that page and transitive reverse dependents
///   - changed include/layout path -> every transitive dependent page
///   - return sorted entity IDs with duplicates removed
///
/// The returned slice is owned by the caller and allocated using the provided allocator.
/// `node_by_key` maps every frozen node's `id` and `source_path` to the node,
/// built once per build by the caller (PERF-032): the reverse walk previously
/// scanned all nodes per visited key, making incremental dirty expansion
/// quadratic in graph size.
pub fn getAffectedPages(
    allocator: std.mem.Allocator,
    changed_path: []const u8,
    node_by_key: *const std.StringHashMapUnmanaged(*const graph_mod.Node),
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

        if (node_by_key.get(curr)) |node| {
            try affected_ids.put(allocator, node.id, {});
            // Continue reverse walk so page→page (parent/reference) edges propagate.
            if (dep_index.reverse.get(node.id)) |dep_list| {
                for (dep_list.items) |dep| {
                    try stack.append(allocator, dep.path);
                }
            }
            // Also walk reverse keyed by source path when deps used path form.
            if (!std.mem.eql(u8, node.id, curr)) {
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

test "input adapter identity invalidates only explicit adapted fingerprints" {
    const legacy = computePageFingerprintTheme("default", "layout", "index", "source", &.{}, "layout bytes", "", "");
    const empty = computePageFingerprintThemeInput("default", "layout", "index", "source", &.{}, "layout bytes", "", "", "");
    const textile_v1 = computePageFingerprintThemeInput("default", "layout", "index", "source", &.{}, "layout bytes", "", "", "boris-textile-adapter-v1");
    try std.testing.expectEqualSlices(u8, &legacy, &empty);
    try std.testing.expect(!std.mem.eql(u8, &legacy, &textile_v1));
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

test "theme material changes page fingerprint when present" {
    const base = computePageFingerprintTheme("default", "layouts/main.html", "index", "src", &.{}, "layout", "", "");
    const with_theme = computePageFingerprintTheme("default", "layouts/main.html", "index", "src", &.{}, "layout", "", "footer\x00assets");
    const same_empty = computePageFingerprint("default", "layouts/main.html", "index", "src", &.{}, "layout", "");
    try std.testing.expectEqualSlices(u8, &base, &same_empty);
    try std.testing.expect(!std.mem.eql(u8, &base, &with_theme));
}

test "nav and layout byte changes invalidate fingerprints (PERF-009)" {
    const base = computePageFingerprint("t", "l", "id", "s", &.{}, "layout bytes", "nav bytes");
    const other_nav = computePageFingerprint("t", "l", "id", "s", &.{}, "layout bytes", "nav bytes changed");
    const other_layout = computePageFingerprint("t", "l", "id", "s", &.{}, "layout bytes changed", "nav bytes");
    try std.testing.expect(!std.mem.eql(u8, &base, &other_nav));
    try std.testing.expect(!std.mem.eql(u8, &base, &other_layout));
}

test "fingerprint composition mixes precomputed constant digests (PERF-009)" {
    // The raw-bytes wrapper and the digest-core path must agree exactly.
    const raw = computePageFingerprintThemeInput("t", "l", "id", "s", &.{}, "layout bytes", "nav material", "theme material", "");
    const dig = computePageFingerprintDigests(
        "t",
        "l",
        "id",
        "s",
        &.{},
        constantDigest("boris-const:layout", "layout bytes"),
        constantDigest("boris-const:nav", "nav material"),
        constantDigest("boris-const:theme", "theme material"),
        "",
    );
    try std.testing.expectEqualSlices(u8, &raw, &dig);

    // Domain markers separate identical bytes in different constant roles.
    const shared = "shared bytes";
    const as_nav = computePageFingerprintDigests(
        "t", "l", "id", "s", &.{},
        constantDigest("boris-const:layout", "layout bytes"),
        constantDigest("boris-const:nav", shared),
        constantDigest("boris-const:theme", "theme material"),
        "",
    );
    const as_theme = computePageFingerprintDigests(
        "t", "l", "id", "s", &.{},
        constantDigest("boris-const:layout", "layout bytes"),
        constantDigest("boris-const:nav", "nav material"),
        constantDigest("boris-const:theme", shared),
        "",
    );
    try std.testing.expect(!std.mem.eql(u8, &as_nav, &as_theme));

    // Non-null vs null constant digest changes the fingerprint (gating parity).
    const no_nav = computePageFingerprintDigests(
        "t", "l", "id", "s", &.{},
        constantDigest("boris-const:layout", "layout bytes"),
        null,
        null,
        "",
    );
    try std.testing.expect(!std.mem.eql(u8, &no_nav, &dig));
}

fn buildNodeKeyMap(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
) !std.StringHashMapUnmanaged(*const graph_mod.Node) {
    var map: std.StringHashMapUnmanaged(*const graph_mod.Node) = .empty;
    errdefer map.deinit(allocator);
    try map.ensureTotalCapacity(allocator, @intCast(2 * nodes.len));
    for (nodes) |*node| {
        const g1 = map.getOrPutAssumeCapacity(node.id);
        if (!g1.found_existing) g1.value_ptr.* = node;
        const g2 = map.getOrPutAssumeCapacity(node.source_path);
        if (!g2.found_existing) g2.value_ptr.* = node;
    }
    return map;
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

    var node_by_key = try buildNodeKeyMap(gpa, &nodes);
    defer node_by_key.deinit(gpa);

    {
        const affected = try getAffectedPages(gpa, "content/guides/intro.md", &node_by_key, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 1), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
    }

    // Editing the reference *target* dirties the referrer (page→page reverse).
    {
        const affected = try getAffectedPages(gpa, "content/guides/outro.md", &node_by_key, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 2), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
        try std.testing.expectEqualStrings("guides/outro", affected[1]);
    }

    {
        const affected = try getAffectedPages(gpa, "includes/widget.html", &node_by_key, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 2), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
        try std.testing.expectEqualStrings("guides/outro", affected[1]);
    }

    {
        const affected = try getAffectedPages(gpa, "layouts/main.html", &node_by_key, &dep_index);
        defer {
            for (affected) |item| gpa.free(item);
            gpa.free(affected);
        }
        try std.testing.expectEqual(@as(usize, 2), affected.len);
        try std.testing.expectEqualStrings("guides/intro", affected[0]);
        try std.testing.expectEqualStrings("guides/outro", affected[1]);
    }

    {
        const affected = try getAffectedPages(gpa, "layouts/ref.html", &node_by_key, &dep_index);
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

    var node_by_key = try buildNodeKeyMap(gpa, &nodes);
    defer node_by_key.deinit(gpa);

    const affected = try getAffectedPages(gpa, "layouts/main.html", &node_by_key, &dep_index);
    defer {
        for (affected) |item| gpa.free(item);
        gpa.free(affected);
    }

    try std.testing.expectEqual(@as(usize, 3), affected.len);
    try std.testing.expectEqualStrings("a", affected[0]);
    try std.testing.expectEqualStrings("m", affected[1]);
    try std.testing.expectEqualStrings("z", affected[2]);
}
