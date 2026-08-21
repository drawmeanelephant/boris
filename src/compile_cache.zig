const std = @import("std");
const Io = std.Io;
const dependency = @import("dependency.zig");
const json_out = @import("json_out.zig");
const cache_mod = @import("cache.zig");
const graph_mod = @import("graph.zig");
const sitemap = @import("sitemap.zig");
const page_mod = @import("page.zig");

const DurablePage = page_mod.DurablePage;

pub const CacheEntry = struct {
    entity_id: []const u8,
    fingerprint: []const u8,
    output_path: []const u8,
    /// Effective selected layout path for this target/page (workspace-relative).
    selected_layout: []const u8 = "",
    /// On-disk output size at last successful publish (cheap prefilter).
    output_size: u64 = 0,
    /// Lowercase hex SHA-256 of published HTML bytes; empty forces re-render.
    output_digest: []const u8 = "",
};

pub const CacheManifest = struct {
    format_version: []const u8 = cache_mod.CACHE_FORMAT_VERSION,
    entries: []const CacheEntry,
};

pub const ParsedCacheEntry = struct {
    entity_id: []const u8,
    fingerprint: []const u8,
    output_path: []const u8,
    /// Effective selected layout; missing on older manifests forces re-render via format bump.
    selected_layout: []const u8 = "",
    /// Optional for older manifests; missing/zero is a cheap prefilter only.
    output_size: u64 = 0,
    /// Optional for older manifests; missing/empty forces re-render.
    output_digest: []const u8 = "",
};

pub const ParsedCacheManifest = struct {
    format_version: []const u8,
    entries: []ParsedCacheEntry,
};

fn compareStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn collectTransitIncludes(
    gpa: std.mem.Allocator,
    source: []const u8,
    dep_index: *const dependency.DependencyIndex,
    list: *std.ArrayList([]const u8),
    visited: *std.StringHashMapUnmanaged(void),
) !void {
    if (visited.contains(source)) return;
    try visited.put(gpa, source, {});

    if (dep_index.forward.get(source)) |deps| {
        for (deps.items) |dep| {
            if (dep.kind == .include) {
                var exists = false;
                for (list.items) |item| {
                    if (std.mem.eql(u8, item, dep.path)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    try list.append(gpa, try gpa.dupe(u8, dep.path));
                }
                try collectTransitIncludes(gpa, dep.path, dep_index, list, visited);
            }
        }
    }
}

pub fn writeCacheManifest(allocator: std.mem.Allocator, writer: anytype, manifest: CacheManifest) !void {
    // Buffer via ArrayList so entity_id / paths / fingerprints go through json_out escaping.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"format_version\": ");
    try json_out.writeString(&buf, allocator, manifest.format_version);
    try buf.appendSlice(allocator, ",\n  \"entries\": [\n");
    for (manifest.entries, 0..) |entry, i| {
        try buf.appendSlice(allocator, "    {\n      \"entity_id\": ");
        try json_out.writeString(&buf, allocator, entry.entity_id);
        try buf.appendSlice(allocator, ",\n      \"fingerprint\": ");
        try json_out.writeString(&buf, allocator, entry.fingerprint);
        try buf.appendSlice(allocator, ",\n      \"output_path\": ");
        try json_out.writeString(&buf, allocator, entry.output_path);
        try buf.appendSlice(allocator, ",\n      \"selected_layout\": ");
        try json_out.writeString(&buf, allocator, entry.selected_layout);
        try buf.appendSlice(allocator, ",\n      \"output_size\": ");
        try json_out.writeUsize(&buf, allocator, @intCast(entry.output_size));
        try buf.appendSlice(allocator, ",\n      \"output_digest\": ");
        try json_out.writeString(&buf, allocator, entry.output_digest);
        try buf.appendSlice(allocator, "\n    }");
        if (i + 1 < manifest.entries.len) {
            try buf.appendSlice(allocator, ",\n");
        } else {
            try buf.append(allocator, '\n');
        }
    }
    try buf.appendSlice(allocator, "  ]\n}\n");
    try writer.writeAll(buf.items);
}

pub fn fingerprintHex(fp_bytes: [32]u8, gpa: std.mem.Allocator) ![]u8 {
    var fp_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (fp_bytes, 0..) |b, i| {
        fp_hex[i * 2] = hex_chars[b >> 4];
        fp_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return try gpa.dupe(u8, &fp_hex);
}

pub fn expandDirtySet(
    gpa: std.mem.Allocator,
    is_dirty: []bool,
    pages: []const DurablePage,
    nodes: []const graph_mod.Node,
    dep_index: *const dependency.DependencyIndex,
) !void {
    // Both lookups are built once. Previously the node scan inside
    // getAffectedPages and the entity-id scan below were linear, and both ran
    // once per dirty page — quadratic in page count on a cold incremental
    // build, where every page is dirty.
    var lookup = try cache_mod.NodeLookup.init(gpa, nodes);
    defer lookup.deinit();

    var by_entity_id: std.StringHashMapUnmanaged(usize) = .{};
    defer by_entity_id.deinit(gpa);
    try by_entity_id.ensureTotalCapacity(gpa, @intCast(pages.len));
    for (pages, 0..) |page, idx| {
        // First writer wins, matching the previous scan's `break` on first match.
        if (!by_entity_id.contains(page.entity_id)) {
            by_entity_id.putAssumeCapacity(page.entity_id, idx);
        }
    }

    for (pages, 0..) |page, page_idx| {
        if (!is_dirty[page_idx]) continue;
        const affected = try cache_mod.getAffectedPagesIndexed(gpa, page.source_path, &lookup, dep_index);
        defer {
            for (affected) |id| gpa.free(id);
            gpa.free(affected);
        }
        for (affected) |id| {
            if (by_entity_id.get(id)) |candidate_idx| is_dirty[candidate_idx] = true;
        }
    }
}

/// Sibling staging directory for a target: `{dist_dir}.boris-stage`.
pub fn stageRelForDist(gpa: std.mem.Allocator, dist_dir: []const u8) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist_dir});
}

pub const sitemap_ownership_path = ".boris-cache/sitemap-output-path";

pub const PriorSitemapOwnership = struct {
    marker_present: bool = false,
    path: ?[]u8 = null,

    pub fn deinit(self: *PriorSitemapOwnership, gpa: std.mem.Allocator) void {
        if (self.path) |path| gpa.free(path);
        self.* = undefined;
    }
};

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn readPriorSitemapOwnership(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
) !PriorSitemapOwnership {
    const bytes = readFileAlloc(io, dist_dir, sitemap_ownership_path, gpa) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.SitemapOwnershipCorrupt;
    const value = std.mem.trimEnd(u8, bytes, "\r\n");
    if (value.len == 0) return .{ .marker_present = true };
    sitemap.validateOutputPath(value) catch return error.SitemapOwnershipCorrupt;
    return .{
        .marker_present = true,
        .path = try gpa.dupe(u8, value),
    };
}

pub fn stageSitemapOwnership(
    io: Io,
    stage_dir: Io.Dir,
    current_path: ?[]const u8,
) !void {
    var atomic = try stage_dir.createFileAtomic(io, sitemap_ownership_path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic.deinit(io);
    var buffer: [1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    if (current_path) |path| try writer.interface.writeAll(path);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
    try atomic.replace(io);
}
