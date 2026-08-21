const std = @import("std");
const Io = std.Io;
const page_mod = @import("page.zig");
const wikilink = @import("wikilink.zig");
const include_mod = @import("include.zig");
const json_out = @import("json_out.zig");
const cache_mod = @import("cache.zig");
const html_body = @import("html_body.zig");
const html_toc = @import("html_toc.zig");
const source_io = @import("source_io.zig");
const timings = @import("timings.zig");
const diag = @import("diag.zig");
const identity = @import("identity.zig");
const textile = @import("textile.zig");
const cooklang_seam = @import("cooklang_seam.zig");

const DurablePage = page_mod.DurablePage;

/// Side-cache format for heading harvest (separate from page manifest so we
/// do not force a fingerprint-format bump). See #58.
pub const HEADING_HARVEST_FORMAT = "boris-heading-harvest-v1";

pub const ParsedHeadingHarvestEntry = struct {
    entity_id: []const u8 = "",
    harvest_key: []const u8 = "",
    ids: []const []const u8 = &.{},
};

pub const ParsedHeadingHarvest = struct {
    format: []const u8 = "",
    entries: []ParsedHeadingHarvestEntry = &.{},
};

pub const HeadingHarvestWriteEntry = struct {
    entity_id: []u8,
    harvest_key: []u8,
    ids: [][]u8,
};

pub const HeadingHarvestSnapshot = struct {
    /// Owned entry records for the just-built index (needed pages only).
    entries: []HeadingHarvestWriteEntry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *HeadingHarvestSnapshot) void {
        for (self.entries) |*e| {
            self.gpa.free(e.entity_id);
            self.gpa.free(e.harvest_key);
            for (e.ids) |id| self.gpa.free(id);
            self.gpa.free(e.ids);
        }
        self.gpa.free(self.entries);
        self.* = undefined;
    }
};

/// Cache-key material identifying which body adapter produced a page's
/// Markdown. Empty for Markdown input so existing fingerprints do not move.
fn adapterIdentity(input_format: identity.InputFormat) []const u8 {
    return switch (input_format) {
        .markdown => "",
        .textile => textile.adapter_identity,
        .cook => cooklang_seam.adapter_identity,
    };
}

/// Collect owned entity ids that are targets of any `[[entity#heading]]` in the site
/// (page bodies + transitive include bodies). Empty when no fragment links exist.
pub fn collectFragmentTargetSet(
    gpa: std.mem.Allocator,
    pages: []const DurablePage,
    source_bytes: [][]u8,
    include_bytes: [][][]u8,
    include_paths: [][][]u8,
) !std.StringHashMapUnmanaged(void) {
    var targets: std.StringHashMapUnmanaged(void) = .{};
    errdefer {
        var it = targets.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        targets.deinit(gpa);
    }

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(gpa);
    var raw_ids: std.ArrayList([]const u8) = .empty;
    defer raw_ids.deinit(gpa);

    for (pages, 0..) |page, page_idx| {
        raw_ids.clearRetainingCapacity();
        seen.clearRetainingCapacity();

        const body = include_mod.bodyOfSource(source_bytes[page_idx]);
        var fail: wikilink.FailInfo = .{ .line_base = include_mod.lineBaseOfSource(source_bytes[page_idx]) };
        try wikilink.collectFragmentTargetIds(body, gpa, &raw_ids, &seen, &fail, page.source_path);

        const inc_owned = include_bytes[page_idx];
        const inc_paths = include_paths[page_idx];
        for (inc_owned, 0..) |inc_file, j| {
            const inc_body = include_mod.bodyOfSource(inc_file);
            try wikilink.collectFragmentTargetIds(inc_body, gpa, &raw_ids, &seen, &fail, inc_paths[j]);
        }

        for (raw_ids.items) |id| {
            // Dupe before insert: `id` is a view into source/include bytes, not
            // gpa-owned. Inserting it first and duping after would leave a
            // non-owned key in the map if the dupe fails, and the errdefer above
            // frees every key — an invalid free on the OOM path.
            if (targets.contains(id)) continue;
            const owned = try gpa.dupe(u8, id);
            errdefer gpa.free(owned);
            try targets.put(gpa, owned, {});
        }
    }
    return targets;
}

/// Content-addressed key for a page's harvested heading ids: source + transitive
/// include bodies + input adapter identity. Unchanged key ⇒ reusable ids without rendering.
pub fn headingHarvestKey(
    entity_id: []const u8,
    source_bytes: []const u8,
    include_bytes: []const []const u8,
    input_material: []const u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var len_buf: [8]u8 = undefined;
    const updateLen = struct {
        fn go(h: *std.crypto.hash.sha2.Sha256, len: u64, buf: *[8]u8) void {
            std.mem.writeInt(u64, buf, len, .little);
            h.update(buf);
        }
    }.go;
    updateLen(&hasher, entity_id.len, &len_buf);
    hasher.update(entity_id);
    updateLen(&hasher, source_bytes.len, &len_buf);
    hasher.update(source_bytes);
    updateLen(&hasher, include_bytes.len, &len_buf);
    for (include_bytes) |b| {
        updateLen(&hasher, b.len, &len_buf);
        hasher.update(b);
    }
    updateLen(&hasher, input_material.len, &len_buf);
    hasher.update(input_material);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn writeHeadingHarvestCache(allocator: std.mem.Allocator, writer: anytype, entries: []const HeadingHarvestWriteEntry) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n  \"format\": ");
    try json_out.writeString(&buf, allocator, HEADING_HARVEST_FORMAT);
    try buf.appendSlice(allocator, ",\n  \"entries\": [\n");
    for (entries, 0..) |e, i| {
        try buf.appendSlice(allocator, "    {\n      \"entity_id\": ");
        try json_out.writeString(&buf, allocator, e.entity_id);
        try buf.appendSlice(allocator, ",\n      \"harvest_key\": ");
        try json_out.writeString(&buf, allocator, e.harvest_key);
        try buf.appendSlice(allocator, ",\n      \"ids\": [");
        for (e.ids, 0..) |id, j| {
            try json_out.writeString(&buf, allocator, id);
            if (j + 1 < e.ids.len) try buf.appendSlice(allocator, ", ");
        }
        try buf.appendSlice(allocator, "]\n    }");
        if (i + 1 < entries.len) try buf.appendSlice(allocator, ",\n") else try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "  ]\n}\n");
    try writer.writeAll(buf.items);
}

/// Harvest Oliver-rendered heading ids for pages that are wiki-fragment targets.
/// Reuses the same pre-render + Oliver body pipeline as publish (no second slugger).
/// Wiki fragments are emitted but not validated here (index bootstrapping).
/// When no fragment links exist, returns an empty index (no render work).
///
/// When `prior_harvest` is non-null (incremental) and a page's harvest key
/// matches a prior entry, Oliver is skipped for that page (#58). Callers may
/// write the returned harvest snapshot under `.boris-cache/heading-harvest.json`.
pub fn buildSiteHeadingIndex(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    pages: []const DurablePage,
    nodes: []const @import("graph.zig").Node,
    source_bytes: [][]u8,
    include_bytes: [][][]u8,
    include_paths: [][][]u8,
    input_format: identity.InputFormat,
    prior_harvest: ?*const ParsedHeadingHarvest,
    recorder: ?*timings.Recorder,
    sink: ?*diag.Collector,
) !struct { wikilink.HeadingIndex, HeadingHarvestSnapshot } {
    var index: wikilink.HeadingIndex = .{};
    errdefer index.deinit(gpa);

    var needed = try collectFragmentTargetSet(gpa, pages, source_bytes, include_bytes, include_paths);
    defer {
        var it = needed.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        needed.deinit(gpa);
    }

    var snapshot: HeadingHarvestSnapshot = .{ .entries = &.{}, .gpa = gpa };
    errdefer snapshot.deinit();

    if (needed.count() == 0) return .{ index, snapshot };

    // entity_id → prior entry
    var prior_map: std.StringHashMapUnmanaged(*const ParsedHeadingHarvestEntry) = .{};
    defer prior_map.deinit(gpa);
    if (prior_harvest) |ph| {
        if (std.mem.eql(u8, ph.format, HEADING_HARVEST_FORMAT)) {
            for (ph.entries) |*e| {
                if (e.entity_id.len == 0 or e.harvest_key.len == 0) continue;
                try prior_map.put(gpa, e.entity_id, e);
            }
        }
    }

    var write_list: std.ArrayList(HeadingHarvestWriteEntry) = .empty;
    errdefer {
        for (write_list.items) |*e| {
            gpa.free(e.entity_id);
            gpa.free(e.harvest_key);
            for (e.ids) |id| gpa.free(id);
            gpa.free(e.ids);
        }
        write_list.deinit(gpa);
    }

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    // The adapter identity is part of a page's cache key: changing which
    // language produced the Markdown must invalidate the fingerprint.
    const input_material: []const u8 = adapterIdentity(input_format);

    for (pages, 0..) |page, page_idx| {
        if (!needed.contains(page.entity_id)) continue;

        const inc_owned = include_bytes[page_idx];
        const inc_views = try gpa.alloc([]const u8, inc_owned.len);
        defer gpa.free(inc_views);
        for (inc_owned, 0..) |b, j| inc_views[j] = b;

        const key_bytes = headingHarvestKey(
            page.entity_id,
            source_bytes[page_idx],
            inc_views,
            input_material,
        );
        const key_hex = cache_mod.hexDigest(key_bytes);

        // Cache hit: reuse prior ids (no re-render).
        if (prior_map.get(page.entity_id)) |prior| {
            if (std.mem.eql(u8, prior.harvest_key, &key_hex)) {
                if (recorder) |t| t.bump(.fast_path_hits, 1);
                try index.putOwned(gpa, page.entity_id, prior.ids);
                const ent_id = try gpa.dupe(u8, page.entity_id);
                errdefer gpa.free(ent_id);
                const hk = try gpa.dupe(u8, &key_hex);
                errdefer gpa.free(hk);
                const ids_owned = try gpa.alloc([]u8, prior.ids.len);
                errdefer {
                    for (ids_owned) |id| gpa.free(id);
                    gpa.free(ids_owned);
                }
                for (prior.ids, 0..) |id, i| ids_owned[i] = try gpa.dupe(u8, id);
                try write_list.append(gpa, .{
                    .entity_id = ent_id,
                    .harvest_key = hk,
                    .ids = ids_owned,
                });
                continue;
            }
        }

        _ = doc_arena.reset(.free_all);
        const arena = doc_arena.allocator();
        const source = try source_io.readPageAlloc(io, content_dir, page.source_path, arena);
        if (recorder) |t| t.bump(.page_reads, 1);
        const html = try html_body.renderSource(io, gpa, content_dir, &doc_arena, source, page.source_path, page.output_path, .{
            .input_format = input_format,
            .nodes = nodes,
            // Do not validate fragments while building the index they depend on.
            .diagnostics = sink,
        });

        var ids: std.ArrayList([]const u8) = .empty;
        defer {
            for (ids.items) |id| gpa.free(id);
            ids.deinit(gpa);
        }
        // collectHeadingIds allocates id copies on gpa (not the page arena).
        try html_toc.collectHeadingIds(gpa, html, &ids);
        try index.putOwned(gpa, page.entity_id, ids.items);

        const ent_id = try gpa.dupe(u8, page.entity_id);
        errdefer gpa.free(ent_id);
        const hk = try gpa.dupe(u8, &key_hex);
        errdefer gpa.free(hk);
        const ids_owned = try gpa.alloc([]u8, ids.items.len);
        errdefer {
            for (ids_owned) |id| gpa.free(id);
            gpa.free(ids_owned);
        }
        for (ids.items, 0..) |id, i| ids_owned[i] = try gpa.dupe(u8, id);
        try write_list.append(gpa, .{
            .entity_id = ent_id,
            .harvest_key = hk,
            .ids = ids_owned,
        });
    }

    // Deterministic entry order for the cache file.
    std.mem.sort(HeadingHarvestWriteEntry, write_list.items, {}, struct {
        fn less(_: void, a: HeadingHarvestWriteEntry, b: HeadingHarvestWriteEntry) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);

    snapshot.entries = try write_list.toOwnedSlice(gpa);
    return .{ index, snapshot };
}
