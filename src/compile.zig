//! Experimental single-threaded HTML rendering path (milestone 9).
//!
//! **Not** the default v0.1 CLI surface (IR under `.boris/`, optional RAG).
//! This module is opt-in / test-driven until a documented CLI contract extends
//! it deliberately. No concurrency.
//!
//! ## Memory model
//!
//! 1. **PageDb** — long-lived retain arena for narrowly promoted metadata only
//!    (`entity_id`, `title`, `parent`, paths, tags, …). Never stores slices into
//!    source buffers, parser views, Apex HTML, or writer buffers.
//! 2. **Whiteboard** — per-page `std.heap.ArenaAllocator`. Source bytes, parse
//!    scratch, and Apex HTML live only here.
//! 3. After each page (success **or** error): `arena.reset(.free_all)`, but
//!    **only after**:
//!    - Apex has returned;
//!    - buffered writes are flushed;
//!    - temp output is closed/finalized;
//!    - publication attempt has finished;
//!    - no caller-owned object retains a Whiteboard slice.
//!
//! ## Layout + assembly
//!
//! Layout is loaded once (long-lived). Final pages stream
//! `prefix | html | suffix` via `assemble.writePage` — no mega-string.
//! Output paths use `identity.safeOutputRelativePath` (via discovery/PageDb).
//!
//! ## Flat-RSS claims
//!
//! Tests observe document-arena `queryCapacity()` after `free_all`. Process
//! RSS is **not** claimed.

const std = @import("std");
const Io = std.Io;
const page_mod = @import("page.zig");
const parser = @import("parser.zig");
const aside = @import("aside.zig");
const apex = @import("apex.zig");
const assemble = @import("assemble.zig");
const scanner = @import("scanner.zig");
const identity = @import("identity.zig");
const cache = @import("cache.zig");
const dependency = @import("dependency.zig");
const target_mod = @import("target.zig");

pub const PageDb = page_mod.PageDb;
pub const DurablePage = page_mod.DurablePage;

/// Experimental path marker — keep CLI default off this surface.
pub const experimental: bool = true;

pub const CompileStats = struct {
    pages_written: usize = 0,
    pages_attempted: usize = 0,
    peak_whiteboard_capacity: usize = 0,
    last_reset_capacity: usize = 0,
};

pub const CompileOptions = struct {
    target_name: []const u8 = "default",
    content_root: []const u8 = "content",
    dist_dir: []const u8 = "dist",
    layout_path: []const u8 = "layouts/main.html",
    quiet: bool = true,
    /// When set, force a render failure after promoting page `N` (0-based)
    /// without publishing — used to prove error-path Whiteboard reset + no
    /// final file. Production callers leave this `null`.
    test_fail_render_at: ?usize = null,
    /// When set, inject `assemble` publish failure for page `N` after a prior
    /// successful write of that path (caller should seed the final first).
    test_fail_publish_at: ?usize = null,
    /// Opt-in to fast incremental rendering.
    incremental: bool = false,
    /// When set, inject failure before publishing cache manifest to test rollback.
    test_fail_cache_publish: bool = false,
    /// Bounded parallel rendering worker count.
    jobs: usize = 1,
};

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// Load layout once into long-lived `layout_arena` ownership.
/// Missing/duplicate `{{content}}` hard-fails **before** content compilation.
///
/// Layout errors are remapped to `LayoutMissingMarker` / `LayoutDuplicateMarker`
/// so call sites can distinguish template faults from I/O.
pub fn loadLayoutOnce(
    io: Io,
    dir: Io.Dir,
    layout_path: []const u8,
    layout_arena: std.mem.Allocator,
) !assemble.Layout {
    return assemble.loadLayout(io, dir, layout_path, layout_arena) catch |err| switch (err) {
        error.MissingContentMarker => return error.LayoutMissingMarker,
        error.DuplicateContentMarker => return error.LayoutDuplicateMarker,
        else => |e| return e,
    };
}

/// Discover pages and promote durable frontmatter into `db` (PageDb retain).
///
/// Transient source buffers are GPA-owned and freed after each promote — no
/// parser slice is retained on PageDb.
pub fn loadAndPromote(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    content_root: []const u8,
) !void {
    var scan_list = page_mod.PageList.init(gpa, db.retain);
    defer scan_list.deinit();

    scanner.scan(io, .{ .content_root = content_root }, &scan_list) catch |err| switch (err) {
        error.ContentDirMissing => return error.ContentDirMissing,
        else => |e| return e,
    };

    const cwd = Io.Dir.cwd();
    var content_dir = try cwd.openDir(io, content_root, .{});
    defer content_dir.close(io);

    for (scan_list.items()) |disc| {
        const source = try readFileAlloc(io, content_dir, disc.source_path, gpa);
        defer gpa.free(source);

        const parsed = parser.parse(source);
        if (parsed.diagnostic != null) return error.ParseFailed;

        const final_id: []const u8 = if (parsed.doc.meta.id) |override| override else disc.entity_id;
        try db.promote(disc, final_id, parsed.doc.meta, parsed.doc.body_offset);
    }
}

/// Render one page body through Apex into the Whiteboard and publish HTML.
///
/// **Caller owns Whiteboard lifecycle:** must `reset(.free_all)` only after
/// this function returns (success or error). This function never resets the
/// arena; it only allocates into it.
///
/// PageDb metadata must already be durable (from `loadAndPromote`). This
/// function re-reads source for the body only — parse views stay on the
/// Whiteboard until return.
pub fn renderAndPublishPage(
    io: Io,
    content_dir: Io.Dir,
    dist_dir: Io.Dir,
    page: *const DurablePage,
    layout: assemble.Layout,
    doc_arena: *std.heap.ArenaAllocator,
    options: CompileOptions,
    page_index: usize,
) !void {
    const arena = doc_arena.allocator();

    const source = try readFileAlloc(io, content_dir, page.source_path, arena);
    const parsed = parser.parse(source);
    if (parsed.diagnostic != null) return error.ParseFailed;

    if (options.test_fail_render_at) |idx| {
        if (idx == page_index) return error.TestInjectedRenderFailure;
    }

    // Body stream: markdown segments via Apex, Aside via aside.renderHtml.
    // Document order preserved; all HTML lives on the Whiteboard only.
    const tok = try aside.tokenizeBody(parsed.doc.body, arena);
    if (tok.hasErrors()) return error.ComponentFailed;

    var html_buf: std.ArrayList(u8) = .empty;
    for (tok.segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                const h = try apex.render(md, doc_arena);
                try html_buf.appendSlice(arena, h.bytes);
            },
            .aside => |c| {
                const h = try aside.renderHtml(c, doc_arena);
                try html_buf.appendSlice(arena, h);
            },
        }
    }
    const html = html_buf.items;

    const fail_publish = if (options.test_fail_publish_at) |idx| idx == page_index else false;
    try assemble.writePageOpts(io, dist_dir, page.output_path, layout, html, .{
        .fail_before_publish = fail_publish,
    });
}

pub const CacheEntry = struct {
    entity_id: []const u8,
    fingerprint: []const u8,
    output_path: []const u8,
};

pub const CacheManifest = struct {
    format_version: []const u8 = cache.CACHE_FORMAT_VERSION,
    entries: []const CacheEntry,
};

pub const ParsedCacheEntry = struct {
    entity_id: []const u8,
    fingerprint: []const u8,
    output_path: []const u8,
};

pub const ParsedCacheManifest = struct {
    format_version: []const u8,
    entries: []ParsedCacheEntry,
};

fn compareStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn scanIncludes(allocator: std.mem.Allocator, bytes: []const u8, list: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const prefix = "includes/";
        if (std.mem.startsWith(u8, bytes[i..], prefix)) {
            var j = i + prefix.len;
            while (j < bytes.len) {
                const c = bytes[j];
                if (std.ascii.isAlphanumeric(c) or c == '.' or c == '/' or c == '_' or c == '-') {
                    j += 1;
                } else {
                    break;
                }
            }
            if (j > i + prefix.len) {
                const path = bytes[i..j];
                var exists = false;
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing, path)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    try list.append(allocator, try allocator.dupe(u8, path));
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
}

fn scanIncludesRecursively(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    include_path: []const u8,
    dep_index: *dependency.DependencyIndex,
    visited: *std.StringHashMapUnmanaged(void),
    inc_alloc: std.mem.Allocator,
) !void {
    if (visited.contains(include_path)) return;
    try visited.put(gpa, include_path, {});

    const inc_bytes = readFileAlloc(io, content_dir, include_path, gpa) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer gpa.free(inc_bytes);

    var sub_includes: std.ArrayList([]const u8) = .empty;
    defer {
        for (sub_includes.items) |sub| gpa.free(sub);
        sub_includes.deinit(gpa);
    }
    try scanIncludes(gpa, inc_bytes, &sub_includes);

    for (sub_includes.items) |sub_path| {
        const owned_inc = try inc_alloc.dupe(u8, include_path);
        const owned_sub = try inc_alloc.dupe(u8, sub_path);
        try dep_index.addDependency(owned_inc, owned_sub, .include);
        try scanIncludesRecursively(io, gpa, content_dir, owned_sub, dep_index, visited, inc_alloc);
    }
}

fn collectTransitIncludes(
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

fn writeCacheManifest(writer: anytype, manifest: CacheManifest) !void {
    try writer.print("{{\n  \"format_version\": \"{s}\",\n  \"entries\": [\n", .{manifest.format_version});
    for (manifest.entries, 0..) |entry, i| {
        try writer.print("    {{\n      \"entity_id\": \"{s}\",\n      \"fingerprint\": \"{s}\",\n      \"output_path\": \"{s}\"\n    }}", .{
            entry.entity_id,
            entry.fingerprint,
            entry.output_path,
        });
        if (i + 1 < manifest.entries.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("  ]\n}\n");
}

/// Experimental site compile: layout → promote PageDb → whiteboard loop → dist/.
///
/// Single-threaded. Does not mutate default IR semantics.
pub fn compileHtmlSite(
    io: Io,
    gpa: std.mem.Allocator,
    options: CompileOptions,
) !CompileStats {
    const cwd = Io.Dir.cwd();

    // 1. Layout first — hard fail before any content walk on bad marker.
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, options.layout_path, layout_arena.allocator());

    // 2. Long-lived PageDb (retain arena for promoted metadata only).
    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();

    try loadAndPromote(io, gpa, &db, options.content_root);

    return try compilePages(io, gpa, &db, layout, options);
}

/// Orchestrate multiple HTML build targets with complete isolation and sorted sequence.
/// Enforces validate-all-first, single discovery, then sequential rendering.
/// Returns error.MultiTargetCompilationFailed if any target fails.
pub fn compileHtmlSiteMulti(
    io: Io,
    gpa: std.mem.Allocator,
    targets: []const target_mod.TargetSpec,
    base_options: CompileOptions,
) !void {
    const plans = try target_mod.validateTargets(io, gpa, targets, .{
        .content_root = base_options.content_root,
        .layout_path = base_options.layout_path,
    });
    defer {
        for (plans) |plan| gpa.free(plan.resolved_output_dir);
        gpa.free(plans);
    }

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();

    try loadAndPromote(io, gpa, &db, base_options.content_root);

    var any_failed = false;
    for (plans) |plan| {
        var target_options = base_options;
        target_options.target_name = plan.name;
        target_options.dist_dir = plan.output_dir;

        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = loadLayoutOnce(io, Io.Dir.cwd(), target_options.layout_path, layout_arena.allocator()) catch |err| {
            if (!base_options.quiet) {
                std.debug.print("error: target '{s}' failed to load layout: {s}\n", .{ plan.name, @errorName(err) });
            }
            any_failed = true;
            continue;
        };

        _ = compilePages(io, gpa, &db, layout, target_options) catch |err| {
            if (!base_options.quiet) {
                std.debug.print("error: target '{s}' compilation failed: {s}\n", .{ plan.name, @errorName(err) });
            }
            any_failed = true;
            continue;
        };
    }

    if (any_failed) {
        return error.MultiTargetCompilationFailed;
    }
}

const ParallelContext = struct {
    gpa: std.mem.Allocator,
    io: Io,
    content_dir: Io.Dir,
    dist_dir: Io.Dir,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
    is_dirty: []const bool,

    // Thread coordination
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    next_page_index: usize = 0,
    shared_error: ?anyerror = null,

    // Statistics (mutex-protected)
    pages_written: usize = 0,
    peak_whiteboard_capacity: usize = 0,
};

fn parallelWorker(ctx: *ParallelContext) void {
    var doc_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer doc_arena.deinit();

    while (true) {
        ctx.mutex.lockUncancelable(ctx.io);
        if (ctx.shared_error != null) {
            ctx.mutex.unlock(ctx.io);
            break;
        }

        if (ctx.next_page_index >= ctx.db.len()) {
            ctx.mutex.unlock(ctx.io);
            break;
        }

        const page_index = ctx.next_page_index;
        ctx.next_page_index += 1;
        ctx.mutex.unlock(ctx.io);

        if (ctx.is_dirty[page_index]) {
            const page = &ctx.db.items()[page_index];
            renderAndPublishPage(
                ctx.io,
                ctx.content_dir,
                ctx.dist_dir,
                page,
                ctx.layout,
                &doc_arena,
                ctx.options,
                page_index,
            ) catch |err| {
                ctx.mutex.lockUncancelable(ctx.io);
                if (ctx.shared_error == null) {
                    ctx.shared_error = err;
                }
                ctx.mutex.unlock(ctx.io);
                _ = doc_arena.reset(.free_all);
                break;
            };

            const cap = doc_arena.queryCapacity();
            ctx.mutex.lockUncancelable(ctx.io);
            ctx.pages_written += 1;
            if (cap > ctx.peak_whiteboard_capacity) {
                ctx.peak_whiteboard_capacity = cap;
            }
            ctx.mutex.unlock(ctx.io);
        }

        _ = doc_arena.reset(.free_all);
    }
}

/// Compile already-promoted PageDb pages to HTML under `options.dist_dir`.
///
/// `db` strings must outlive this call (retain arena). Whiteboard is local.
pub fn compilePages(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
) !CompileStats {
    const cwd = Io.Dir.cwd();

    var content_dir = try cwd.openDir(io, options.content_root, .{});
    defer content_dir.close(io);

    try cwd.createDirPath(io, options.dist_dir);
    var dist_dir = try cwd.openDir(io, options.dist_dir, .{});
    defer dist_dir.close(io);

    // Load and parse prior manifest if in incremental mode
    var manifest_bytes: ?[]u8 = null;
    defer {
        if (manifest_bytes) |mb| gpa.free(mb);
    }
    var parsed_manifest: ?std.json.Parsed(ParsedCacheManifest) = null;
    defer {
        if (parsed_manifest) |pm| pm.deinit();
    }

    if (options.incremental) {
        if (readFileAlloc(io, dist_dir, ".boris-cache/manifest.json", gpa)) |bytes| {
            manifest_bytes = bytes;
            if (std.json.parseFromSlice(ParsedCacheManifest, gpa, bytes, .{ .ignore_unknown_fields = true })) |pm| {
                // Reject pre-P3.3 or foreign manifests so fingerprints cannot be misread.
                if (std.mem.eql(u8, pm.value.format_version, cache.CACHE_FORMAT_VERSION)) {
                    parsed_manifest = pm;
                } else {
                    pm.deinit();
                }
            } else |_| {}
        } else |_| {}
    }

    // Precreate output directories
    {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(gpa);
        try paths.ensureTotalCapacity(gpa, db.len());
        for (db.items()) |p| try paths.append(gpa, p.output_path);
        try assemble.precreateOutputDirs(io, dist_dir, gpa, paths.items);
    }

    // Build the DependencyIndex and scan includes
    var include_path_arena = std.heap.ArenaAllocator.init(gpa);
    defer include_path_arena.deinit();
    const inc_alloc = include_path_arena.allocator();

    var dep_index = dependency.DependencyIndex.init(gpa);
    defer dep_index.deinit();

    var visited_includes = std.StringHashMapUnmanaged(void).empty;
    defer visited_includes.deinit(gpa);

    for (db.items()) |p| {
        try dep_index.addDependency(p.source_path, options.layout_path, .layout);

        const src_bytes = try readFileAlloc(io, content_dir, p.source_path, gpa);
        defer gpa.free(src_bytes);

        var page_includes = std.ArrayList([]const u8).empty;
        defer {
            for (page_includes.items) |inc| gpa.free(inc);
            page_includes.deinit(gpa);
        }
        try scanIncludes(gpa, src_bytes, &page_includes);

        for (page_includes.items) |inc_path| {
            const owned_src = try inc_alloc.dupe(u8, p.source_path);
            const owned_inc = try inc_alloc.dupe(u8, inc_path);
            try dep_index.addDependency(owned_src, owned_inc, .include);
            try scanIncludesRecursively(io, gpa, content_dir, owned_inc, &dep_index, &visited_includes, inc_alloc);
        }
    }

    // Read layout bytes once for fingerprinting
    const layout_bytes = try readFileAlloc(io, cwd, options.layout_path, gpa);
    defer gpa.free(layout_bytes);

    // Compute fingerprints and determine which pages are dirty
    const fingerprints = try gpa.alloc([]const u8, db.len());
    for (fingerprints) |*fp| fp.* = &.{};
    defer {
        for (fingerprints) |fp| {
            if (fp.len > 0) gpa.free(fp);
        }
        gpa.free(fingerprints);
    }

    const is_dirty = try gpa.alloc(bool, db.len());
    @memset(is_dirty, false);
    defer gpa.free(is_dirty);

    for (db.items(), 0..) |page, page_idx| {
        const src_bytes = try readFileAlloc(io, content_dir, page.source_path, gpa);
        defer gpa.free(src_bytes);

        var transit_includes = std.ArrayList([]const u8).empty;
        defer {
            for (transit_includes.items) |inc| gpa.free(inc);
            transit_includes.deinit(gpa);
        }
        var visited_transit = std.StringHashMapUnmanaged(void).empty;
        defer visited_transit.deinit(gpa);

        try collectTransitIncludes(gpa, page.source_path, &dep_index, &transit_includes, &visited_transit);
        std.mem.sort([]const u8, transit_includes.items, {}, compareStrings);

        var include_bytes_list = std.ArrayList([]const u8).empty;
        defer {
            for (include_bytes_list.items) |bytes| gpa.free(bytes);
            include_bytes_list.deinit(gpa);
        }
        for (transit_includes.items) |inc_path| {
            const bytes = try readFileAlloc(io, content_dir, inc_path, gpa);
            try include_bytes_list.append(gpa, bytes);
        }

        const fp_bytes = cache.computePageFingerprint(options.target_name, options.layout_path, page.entity_id, src_bytes, include_bytes_list.items, layout_bytes);
        var fp_hex: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (fp_bytes, 0..) |b, i| {
            fp_hex[i * 2] = hex_chars[b >> 4];
            fp_hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        fingerprints[page_idx] = try gpa.dupe(u8, &fp_hex);

        var output_exists = false;
        if (dist_dir.openFile(io, page.output_path, .{})) |file| {
            if (file.stat(io)) |st| {
                if (st.size > 0) {
                    output_exists = true;
                }
            } else |_| {}
            file.close(io);
        } else |_| {}

        var skip_render = false;
        if (options.incremental) {
            if (parsed_manifest) |pm| {
                for (pm.value.entries) |entry| {
                    if (std.mem.eql(u8, entry.entity_id, page.entity_id) and
                        std.mem.eql(u8, entry.output_path, page.output_path) and
                        std.mem.eql(u8, entry.fingerprint, fingerprints[page_idx]))
                    {
                        if (output_exists) {
                            skip_render = true;
                            break;
                        }
                    }
                }
            }
        }
        is_dirty[page_idx] = !skip_render;
    }

    // Delete stale files
    if (options.incremental) {
        if (parsed_manifest) |pm| {
            for (pm.value.entries) |entry| {
                var still_exists = false;
                for (db.items()) |p| {
                    if (std.mem.eql(u8, p.entity_id, entry.entity_id)) {
                        still_exists = true;
                        break;
                    }
                }
                if (!still_exists) {
                    dist_dir.deleteFile(io, entry.output_path) catch {};
                }
            }
        }
    }

    // Compile loop
    var stats: CompileStats = .{};

    if (options.jobs > 1) {
        var ctx = ParallelContext{
            .gpa = gpa,
            .io = io,
            .content_dir = content_dir,
            .dist_dir = dist_dir,
            .db = db,
            .layout = layout,
            .options = options,
            .is_dirty = is_dirty,
        };

        const num_workers = @min(options.jobs, db.len());
        var threads = try gpa.alloc(std.Thread, num_workers);
        defer gpa.free(threads);

        var spawned_count: usize = 0;
        errdefer {
            ctx.mutex.lockUncancelable(io);
            ctx.shared_error = error.ThreadSpawnFailed;
            ctx.mutex.unlock(io);
            for (threads[0..spawned_count]) |t| {
                t.join();
            }
        }

        for (threads[0..num_workers]) |*t| {
            t.* = try std.Thread.spawn(.{}, parallelWorker, .{&ctx});
            spawned_count += 1;
        }

        const spawned_threads = threads[0..spawned_count];
        spawned_count = 0; // Disable errdefer joining

        for (spawned_threads) |t| {
            t.join();
        }

        if (ctx.shared_error) |err| {
            return err;
        }

        stats.pages_attempted = db.len();
        stats.pages_written = ctx.pages_written;
        stats.peak_whiteboard_capacity = ctx.peak_whiteboard_capacity;
        stats.last_reset_capacity = 0;

        for (db.items(), 0..) |page, page_idx| {
            if (is_dirty[page_idx]) {
                if (!options.quiet) {
                    std.debug.print("  wrote {s}/{s}\n", .{ options.dist_dir, page.output_path });
                }
            } else {
                if (!options.quiet) {
                    std.debug.print("  cached {s}/{s}\n", .{ options.dist_dir, page.output_path });
                }
            }
        }
    } else {
        var doc_arena = std.heap.ArenaAllocator.init(gpa);
        defer doc_arena.deinit();

        for (db.items(), 0..) |*page, page_index| {
            defer {
                _ = doc_arena.reset(.free_all);
                stats.last_reset_capacity = doc_arena.queryCapacity();
            }

            stats.pages_attempted += 1;

            if (is_dirty[page_index]) {
                try renderAndPublishPage(io, content_dir, dist_dir, page, layout, &doc_arena, options, page_index);
                stats.pages_written += 1;
                if (!options.quiet) {
                    std.debug.print("  wrote {s}/{s}\n", .{ options.dist_dir, page.output_path });
                }
            } else {
                if (!options.quiet) {
                    std.debug.print("  cached {s}/{s}\n", .{ options.dist_dir, page.output_path });
                }
            }

            const cap = doc_arena.queryCapacity();
            if (cap > stats.peak_whiteboard_capacity) stats.peak_whiteboard_capacity = cap;
        }
    }

    // Write Cache manifest atomically on success if in incremental mode
    if (options.incremental) {
        if (options.test_fail_cache_publish) {
            return error.TestInjectedCachePublishFailure;
        }

        var dpath_buf: [256]u8 = undefined;
        const cache_dir_path = std.fmt.bufPrint(&dpath_buf, "{s}/.boris-cache", .{options.dist_dir}) catch unreachable;
        cwd.createDirPath(io, cache_dir_path) catch {};

        var cache_entries = try gpa.alloc(CacheEntry, db.len());
        defer gpa.free(cache_entries);
        for (db.items(), 0..) |page, page_idx| {
            cache_entries[page_idx] = .{
                .entity_id = page.entity_id,
                .fingerprint = fingerprints[page_idx],
                .output_path = page.output_path,
            };
        }

        var atomic_manifest = try dist_dir.createFileAtomic(io, ".boris-cache/manifest.json", .{
            .replace = true,
            .make_path = true,
        });
        defer atomic_manifest.deinit(io);

        var m_buf: [4096]u8 = undefined;
        var m_writer = atomic_manifest.file.writer(io, &m_buf);
        try writeCacheManifest(&m_writer.interface, .{
            .format_version = cache.CACHE_FORMAT_VERSION,
            .entries = cache_entries,
        });
        try m_writer.flush();

        try atomic_manifest.replace(io);
    }

    return stats;
}

/// Allocator lifecycle probe: many small pages then one large page.
/// Observes Whiteboard capacity after each `free_all` only — not process RSS.
pub fn observeWhiteboardLifecycle(
    gpa: std.mem.Allocator,
    small_pages: usize,
    large_body_bytes: usize,
) !struct { after_small_reset: usize, after_large_reset: usize, peak_large: usize } {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var i: usize = 0;
    while (i < small_pages) : (i += 1) {
        const a = arena.allocator();
        const md = try std.fmt.allocPrint(a, "# p{d}\n\nsmall body {d}\n", .{ i, i });
        _ = try apex.render(md, &arena);
        _ = arena.reset(.free_all);
    }
    const after_small = arena.queryCapacity();

    {
        const a = arena.allocator();
        var md: std.ArrayList(u8) = .empty;
        try md.appendSlice(a, "# Large\n\n");
        var filled: usize = 0;
        const line = "word **bold** paragraph filler line\n";
        while (filled < large_body_bytes) : (filled += line.len) {
            try md.appendSlice(a, line);
        }
        _ = try apex.render(md.items, &arena);
    }
    const peak_large = arena.queryCapacity();
    _ = arena.reset(.free_all);
    const after_large = arena.queryCapacity();

    return .{
        .after_small_reset = after_small,
        .after_large_reset = after_large,
        .peak_large = peak_large,
    };
}

// =============================================================================
// Tests
// =============================================================================

fn readAllFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

fn writeTreeFile(io: Io, root_rel: []const u8, rel: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const full = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root_rel, rel });
    defer std.testing.allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| {
        try cwd.createDirPath(io, parent);
    }
    try cwd.writeFile(io, .{ .sub_path = full, .data = data });
}

test "experimental flag is true (HTML path not default product)" {
    try std.testing.expect(experimental);
}

test "layout missing marker aborts before content compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-missing-layout";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "<html>no marker</html>");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.LayoutMissingMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));

    // Layout fails before content compile — no published page.
    const index_out = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_out);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, index_out, .{}));
}

test "layout duplicate marker aborts before content compile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-dup-layout";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "<a>{{content}}</a>{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.LayoutDuplicateMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "valid layout output equals prefix + rendered html + suffix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-splice";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const layout_raw = "PRE-{{content}}-SUF";
    try writeTreeFile(io, work, "layouts/main.html", layout_raw);
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Hello **world**.
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
    try std.testing.expectEqual(@as(usize, 0), stats.last_reset_capacity);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(got);

    const layout = try assemble.Layout.split(layout_raw);
    // Expected = prefix + Apex(body) + suffix (no mega-string in product path;
    // test builds the oracle the same way for equality only).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body_html = try apex.render("# Home\n\nHello **world**.\n", &arena);
    const expected = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ layout.prefix, body_html.bytes, layout.suffix });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, got);
}

test "render failure: whiteboard resets and no final output published" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-render-fail";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/index.md", "# Never published\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Manual loop so we can observe the arena after the error path.
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    try cwd.createDirPath(io, dist);
    var content_dir = try cwd.openDir(io, content, .{});
    defer content_dir.close(io);
    var dist_dir = try cwd.openDir(io, dist, .{ .iterate = true });
    defer dist_dir.close(io);

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    // Warm the whiteboard so free_all is observable.
    _ = try doc_arena.allocator().alloc(u8, 256);

    const page = &db.items()[0];
    const result = renderAndPublishPage(io, content_dir, dist_dir, page, layout, &doc_arena, .{
        .test_fail_render_at = 0,
    }, 0);
    try std.testing.expectError(error.TestInjectedRenderFailure, result);

    // Production loop always resets after return — do so here.
    _ = doc_arena.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), doc_arena.queryCapacity());

    // No final HTML published.
    var it = dist_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            try std.testing.expect(false); // unexpected file
        }
    }
}

test "write failure: prior final remains and temp cleaned" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-write-fail";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "<x>{{content}}</x>");
    try writeTreeFile(io, work, "content/index.md", "# Page\n\nbody text\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // First successful publish.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{ .iterate = true });
    defer dist_dir.close(io);
    const prior = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(prior);
    try std.testing.expect(prior.len > 0);

    // Second attempt fails at publish; prior must remain.
    try std.testing.expectError(error.TestInjectedWriteFailure, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .test_fail_publish_at = 0,
    }));

    const after = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(prior, after);

    // No leftover createFileAtomic hex temps.
    var it = dist_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try std.testing.expectEqualStrings("index.html", entry.name);
    }
}

test "success publish then whiteboard reset; PageDb metadata intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-pagedb";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: TITLE_ALPHA_UNIQUE
        \\status: draft
        \\tags: [a, one]
        \\---
        \\
        \\# Alpha
        \\
        \\BODY_MARKER_ALPHA
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: TITLE_BETA_UNIQUE
        \\parent: alpha
        \\---
        \\
        \\# Beta
        \\
        \\BODY_MARKER_BETA
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);
    try std.testing.expectEqual(@as(usize, 2), db.len());

    // Capture promoted metadata pointers before any whiteboard activity.
    const t0 = db.items()[0].title.?;
    const t1 = db.items()[1].title.?;
    const p1 = db.items()[1].parent.?;
    const tags0 = db.items()[0].tags;

    const stats = try compilePages(io, gpa, &db, layout, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
    try std.testing.expectEqual(@as(usize, 0), stats.last_reset_capacity);

    // PageDb still valid after every free_all.
    try std.testing.expectEqualStrings("TITLE_ALPHA_UNIQUE", t0);
    try std.testing.expectEqualStrings("TITLE_BETA_UNIQUE", t1);
    try std.testing.expectEqualStrings("alpha", p1);
    try std.testing.expectEqual(@as(usize, 2), tags0.len);
    try std.testing.expectEqualStrings("a", tags0[0]);
    try std.testing.expectEqualStrings("TITLE_ALPHA_UNIQUE", db.items()[0].title.?);
    try std.testing.expectEqualStrings("TITLE_BETA_UNIQUE", db.items()[1].title.?);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const a_html = try readAllFile(io, dist_dir, "alpha.html", gpa);
    defer gpa.free(a_html);
    const b_html = try readAllFile(io, dist_dir, "beta.html", gpa);
    defer gpa.free(b_html);
    try std.testing.expect(std.mem.indexOf(u8, a_html, "BODY_MARKER_ALPHA") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_html, "BODY_MARKER_BETA") == null);
    try std.testing.expect(std.mem.indexOf(u8, b_html, "BODY_MARKER_BETA") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_html, "BODY_MARKER_ALPHA") == null);
}

test "whiteboard lifecycle: many small + one large (allocator observation only)" {
    const gpa = std.testing.allocator;
    const obs = try observeWhiteboardLifecycle(gpa, 12, 32 * 1024);
    // free_all returns capacity to 0 for this ArenaAllocator model.
    try std.testing.expectEqual(@as(usize, 0), obs.after_small_reset);
    try std.testing.expectEqual(@as(usize, 0), obs.after_large_reset);
    // Large page required non-trivial capacity before reset.
    try std.testing.expect(obs.peak_large > 1024);
    // Deliberately no process-RSS assertion.
}

test "output paths use identity.safeOutputRelativePath (via PageDb)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-paths";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "content/nested/deep/page.md", "# Deep\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    try std.testing.expectEqual(@as(usize, 1), db.len());
    const expected = try identity.safeOutputRelativePath(gpa, "nested/deep/page");
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, db.items()[0].output_path);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, expected, gpa);
    defer gpa.free(got);
    try std.testing.expect(got.len > 0);
}

test "html fixture golden: expected/ matches compile output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-golden";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "test/fixtures/html/content",
        .dist_dir = dist,
        .layout_path = "test/fixtures/html/layouts/main.html",
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);

    const expected_files = [_][]const u8{ "index.html", "guides/note.html" };
    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    var exp_dir = try cwd.openDir(io, "test/fixtures/html/expected", .{});
    defer exp_dir.close(io);

    for (expected_files) |rel| {
        const got = try readAllFile(io, dist_dir, rel, gpa);
        defer gpa.free(got);
        const exp = try readAllFile(io, exp_dir, rel, gpa);
        defer gpa.free(exp);
        try std.testing.expectEqualStrings(exp, got);
    }
}

test "flush-before-reset: compile defers free_all only after writePage" {
    // Structural proof via HoldUntilFlush sink (see assemble tests) plus
    // end-to-end: after compileHtmlSite, Whiteboard capacity is 0 and files
    // are complete (publication finished before last free_all).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-m9-flush-order";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "H{{content}}T");
    try writeTreeFile(io, work, "content/p.md", "# Title\n\nParagraph.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats.last_reset_capacity);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, "p.html", gpa);
    defer gpa.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "H"));
    try std.testing.expect(std.mem.endsWith(u8, got, "T"));
    try std.testing.expect(std.mem.indexOf(u8, got, "<h1>") != null);
}

test "incremental HTML build mode - full verification suite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-incremental-suite", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Write initial layouts and content files
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha Page
        \\---
        \\# Alpha
        \\
        \\This page includes includes/sidebar.html
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Page
        \\---
        \\# Beta
        \\
        \\No includes here.
        \\
    );
    try writeTreeFile(io, work, "content/includes/sidebar.html", "Sidebar includes includes/widget.html content.");
    try writeTreeFile(io, work, "content/includes/widget.html", "Widget nested content.");

    // ---- 1. Cold cache / first run ----
    // This is the first incremental run: must render all pages (2) and write manifest.json
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // Verify manifest was written
    {
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        const manifest_bytes = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(manifest_bytes);
        try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, cache.CACHE_FORMAT_VERSION) != null);
    }

    // ---- 2. Subsequent unchanged run ----
    // No files have changed, output exists, so zero pages should be rendered.
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 3. Modifying one page source ----
    // Edit beta.md. Only beta.md should re-render.
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Page Edited
        \\---
        \\# Beta
        \\
        \\No includes here. Some edited content!
        \\
    );

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 4. Modifying a transitive include file ----
    // Edit content/includes/widget.html.
    // Since alpha.md depends on includes/sidebar.html which depends on includes/widget.html,
    // editing widget.html should trigger a re-render of alpha.md but NOT beta.md!
    try writeTreeFile(io, work, "content/includes/widget.html", "Widget nested content edited!");

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 5. Modifying the layout template ----
    // Changing layouts/main.html. All layout-dependent pages (both alpha and beta) must re-render.
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>Layout changed! {{content}}</body></html>");

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // ---- 6. Page deletion cleans up output file and cache entry ----
    // Delete content/beta.md. The output file beta.html and its cache entry should be removed.
    {
        var content_dir = try cwd.openDir(io, content, .{});
        defer content_dir.close(io);
        try content_dir.deleteFile(io, "beta.md");
    }

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);
        try std.testing.expectEqual(@as(usize, 1), db.len());

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_attempted);

        // Verify beta.html output file is deleted
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        try std.testing.expectError(error.FileNotFound, dist_dir.openFile(io, "beta.html", .{}));
    }

    // ---- 7. Malformed cache metadata fallback ----
    // Corrupt the manifest.json file. Run again. It should safely fall back and re-render everything (1 page left).
    {
        try writeTreeFile(io, dist, ".boris-cache/manifest.json", "{ malformed json }");
    }

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const stats = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });
        // Falls back to cold build, so it re-renders alpha.md (1 page)
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_attempted);
    }

    // ---- 8. Fault injection: compile failure leaves manifest/output intact ----
    // Modify alpha.md to trigger a compilation error, and inject test_fail_cache_publish.
    // Verify that the failure does NOT save/publish the manifest.
    try writeTreeFile(io, work, "content/alpha.md", "Modified again!");

    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const res = compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout_path,
            .incremental = true,
            .test_fail_cache_publish = true,
            .quiet = true,
        });
        try std.testing.expectError(error.TestInjectedCachePublishFailure, res);
    }
}

test "compilePages: parallel rendering success, determinism, and error paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist_seq = try std.fmt.allocPrint(gpa, "{s}/dist-seq", .{work});
    defer gpa.free(dist_seq);
    const dist_par = try std.fmt.allocPrint(gpa, "{s}/dist-par", .{work});
    defer gpa.free(dist_par);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    // Write a set of pages to render
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha
        \\---
        \\# Alpha page content
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta
        \\---
        \\# Beta page content
    );
    try writeTreeFile(io, work, "content/gamma.md",
        \\---
        \\title: Gamma
        \\---
        \\# Gamma page content
    );

    // Run sequential build
    var stats_seq: CompileStats = undefined;
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        stats_seq = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist_seq,
            .layout_path = layout_path,
            .jobs = 1,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 3), stats_seq.pages_written);
    }

    // Run parallel build
    var stats_par: CompileStats = undefined;
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        stats_par = try compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist_par,
            .layout_path = layout_path,
            .jobs = 4,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 3), stats_par.pages_written);
    }

    // Verify output determinism and byte-for-byte correctness
    const files = [_][]const u8{ "alpha.html", "beta.html", "gamma.html" };
    for (files) |f| {
        const path_seq = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_seq, f });
        defer gpa.free(path_seq);
        const path_par = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_par, f });
        defer gpa.free(path_par);

        const bytes_seq = try readFileAlloc(io, cwd, path_seq, gpa);
        defer gpa.free(bytes_seq);
        const bytes_par = try readFileAlloc(io, cwd, path_par, gpa);
        defer gpa.free(bytes_par);

        try std.testing.expectEqualStrings(bytes_seq, bytes_par);
    }

    // Run parallel build with injected render failure
    {
        var layout_arena = std.heap.ArenaAllocator.init(gpa);
        defer layout_arena.deinit();
        const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());

        var retain_arena = std.heap.ArenaAllocator.init(gpa);
        defer retain_arena.deinit();
        var db = PageDb.init(gpa, retain_arena.allocator());
        defer db.deinit();
        try loadAndPromote(io, gpa, &db, content);

        const res = compilePages(io, gpa, &db, layout, .{
            .content_root = content,
            .dist_dir = dist_par,
            .layout_path = layout_path,
            .jobs = 4,
            .test_fail_render_at = 1,
            .quiet = true,
        });
        try std.testing.expectError(error.TestInjectedRenderFailure, res);
    }
}

test "compileHtmlSiteMulti - success, validation, and isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-multi-compile-test";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try writeTreeFile(io, work, "layouts/main.html", "L{{content}}");
    try writeTreeFile(io, work, "content/alpha.md", "# Alpha\n");
    try writeTreeFile(io, work, "content/beta.md", "# Beta\n");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    const dist_a = try std.fmt.allocPrint(gpa, "{s}/dist_a", .{work});
    defer gpa.free(dist_a);
    const dist_b = try std.fmt.allocPrint(gpa, "{s}/dist_b", .{work});
    defer gpa.free(dist_b);

    // 1. Success case: compile target_a and target_b sequentially
    {
        const targets = [_]target_mod.TargetSpec{
            .{ .name = "target_b", .output_dir = dist_b },
            .{ .name = "target_a", .output_dir = dist_a },
        };

        try compileHtmlSiteMulti(io, gpa, &targets, .{
            .content_root = content_path,
            .layout_path = layout_path,
            .incremental = true,
            .quiet = true,
        });

        // Verify outputs in both directories
        var dir_a = try cwd.openDir(io, dist_a, .{});
        defer dir_a.close(io);
        var dir_b = try cwd.openDir(io, dist_b, .{});
        defer dir_b.close(io);

        const alpha_a = try readAllFile(io, dir_a, "alpha.html", gpa);
        defer gpa.free(alpha_a);
        const alpha_b = try readAllFile(io, dir_b, "alpha.html", gpa);
        defer gpa.free(alpha_b);

        try std.testing.expectEqualStrings("L<h1>Alpha</h1>\n", alpha_a);
        try std.testing.expectEqualStrings("L<h1>Alpha</h1>\n", alpha_b);

        // Verify separate cache namespaces
        if (dir_a.openFile(io, ".boris-cache/manifest.json", .{})) |file| {
            file.close(io);
        } else |_| {
            try std.testing.expect(false);
        }
        if (dir_b.openFile(io, ".boris-cache/manifest.json", .{})) |file| {
            file.close(io);
        } else |_| {
            try std.testing.expect(false);
        }
    }

    // 2. Validation failure: target collision
    {
        const targets = [_]target_mod.TargetSpec{
            .{ .name = "target_a", .output_dir = dist_a },
            .{ .name = "target_b", .output_dir = dist_a }, // duplicate out dir
        };

        const res = compileHtmlSiteMulti(io, gpa, &targets, .{
            .content_root = content_path,
            .layout_path = layout_path,
            .quiet = true,
        });
        try std.testing.expectError(error.TargetOutputCollision, res);
    }
}


