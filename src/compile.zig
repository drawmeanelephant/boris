//! HTML site rendering path (default CLI surface + P2/P3 extensions).
//!
//! Bare `boris` builds under `dist/`. Explicit IR uses `--out` / `--no-rag`; RAG
//! uses `--rag` / `--rag-dir`. Also wired via `--html` / `--html-dir` /
//! `--target`. Coordinator phases are sequential; independent page render may
//! use bounded `--jobs` workers with thread-local Whiteboards (see
//! `docs/contracts/parallel-rendering.md`).
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
const graph_mod = @import("graph.zig");
const diag = @import("diag.zig");
const html_nav = @import("html_nav.zig");
const html_toc = @import("html_toc.zig");
const include_mod = @import("include.zig");
const wikilink = @import("wikilink.zig");
const json_out = @import("json_out.zig");
const pipeline = @import("pipeline.zig");

pub const PageDb = page_mod.PageDb;
pub const DurablePage = page_mod.DurablePage;

/// Long-lived frozen graph + nav for one HTML site compile (Feature 6).
/// Nodes view retain-owned PageDb strings; edges/nav owned by `gpa`.
pub const FrozenSite = struct {
    gpa: std.mem.Allocator,
    nodes: []graph_mod.Node,
    edges: []graph_mod.Edge,
    nav: []graph_mod.NavEntry,
    /// Site-nav fingerprint material (GPA-owned); empty when layout has no `{{nav}}`.
    site_nav_material: []const u8 = "",

    pub fn deinit(self: *FrozenSite) void {
        if (self.site_nav_material.len > 0) self.gpa.free(self.site_nav_material);
        graph_mod.freeNav(self.gpa, self.nav);
        self.gpa.free(self.edges);
        self.gpa.free(self.nodes);
        self.* = undefined;
    }

    pub fn indexOf(self: *const FrozenSite, entity_id: []const u8) ?u32 {
        for (self.nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n.id, entity_id)) return @intCast(i);
        }
        return null;
    }
};

/// Build graph nodes from PageDb, validate, freeze, and buildNav.
/// On graph errors returns `error.GraphValidationFailed` after printing diags
/// when `quiet` is false.
pub fn freezeSiteFromPageDb(
    gpa: std.mem.Allocator,
    db: *PageDb,
    quiet: bool,
    include_nav_material: bool,
) !FrozenSite {
    const pages = db.items();
    const nodes = try gpa.alloc(graph_mod.Node, pages.len);
    errdefer gpa.free(nodes);

    for (pages, 0..) |p, i| {
        nodes[i] = .{
            .id = p.entity_id,
            .source_path = p.source_path,
            .title = p.title,
            .parent = p.parent,
            .status = if (p.status) |s| s.name() else null,
            .tags = p.tags,
            .body_offset = p.body_offset,
        };
    }

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    // Diagnostic message/remediation strings live on a short-lived arena.
    var diag_arena = std.heap.ArenaAllocator.init(gpa);
    defer diag_arena.deinit();
    try graph_mod.validate(gpa, diag_arena.allocator(), nodes, &diags);
    if (diag.countErrors(diags.items) > 0) {
        if (!quiet) {
            for (diags.items) |d| {
                const line = diag.formatText(d, gpa) catch continue;
                defer gpa.free(line);
                std.debug.print("{s}\n", .{line});
            }
        }
        return error.GraphValidationFailed;
    }

    const g = try graph_mod.freeze(gpa, nodes, null);
    errdefer gpa.free(g.edges);

    const nav = try graph_mod.buildNav(gpa, g.nodes);
    errdefer graph_mod.freeNav(gpa, nav);

    // Sync durable graph fields onto PageDb by entity id.
    for (db.itemsMut()) |*p| {
        if (findNodeById(g.nodes, p.entity_id)) |n| {
            p.role = switch (n.role) {
                .trunk => .trunk,
                .satellite => .satellite,
            };
            p.index = n.index;
            p.parent_index = n.parent_index;
        }
    }

    var material: []const u8 = "";
    if (include_nav_material) {
        material = try html_nav.siteNavMaterial(gpa, g.nodes);
    }

    return .{
        .gpa = gpa,
        .nodes = g.nodes,
        .edges = g.edges,
        .nav = nav,
        .site_nav_material = material,
    };
}

fn findNodeById(nodes: []const graph_mod.Node, id: []const u8) ?graph_mod.Node {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, id)) return n;
    }
    return null;
}

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
        error.DuplicateLayoutMarker => return error.LayoutDuplicateMarker,
        error.UnknownLayoutMarker => return error.LayoutUnknownMarker,
        error.TooManyLayoutSegments => return error.LayoutUnknownMarker,
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
///
/// When `site` is non-null and the layout has nav/breadcrumb/title slots, those
/// fragments are rendered from the frozen graph on the Whiteboard.
/// `{{toc}}` is built from rendered body HTML (page-local; no graph required).
pub fn renderAndPublishPage(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    dist_dir: Io.Dir,
    page: *const DurablePage,
    layout: assemble.Layout,
    doc_arena: *std.heap.ArenaAllocator,
    options: CompileOptions,
    page_index: usize,
) !void {
    return renderAndPublishPageWithSite(io, gpa, content_dir, dist_dir, page, layout, doc_arena, options, page_index, null);
}

pub fn renderAndPublishPageWithSite(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    dist_dir: Io.Dir,
    page: *const DurablePage,
    layout: assemble.Layout,
    doc_arena: *std.heap.ArenaAllocator,
    options: CompileOptions,
    page_index: usize,
    site: ?*const FrozenSite,
) !void {
    const arena = doc_arena.allocator();

    const source = try readFileAlloc(io, content_dir, page.source_path, arena);
    const parsed = parser.parse(source);
    if (parsed.diagnostic != null) return error.ParseFailed;

    if (options.test_fail_render_at) |idx| {
        if (idx == page_index) return error.TestInjectedRenderFailure;
    }

    // Pre-Apex: expand {{include}} then rewrite [[wiki]] (Boris-mediated; Apex FS off).
    // File I/O buffers use real gpa (not page_allocator); expanded markdown is arena-owned.
    var include_fail: include_mod.FailInfo = .{};
    const expanded = include_mod.expandIncludes(
        io,
        content_dir,
        gpa,
        arena,
        parsed.doc.body,
        page.source_path,
        &include_fail,
    ) catch |err| {
        if (!options.quiet) {
            include_mod.printDiagnostic(gpa, err, page.source_path, include_fail);
        }
        return error.IncludeFailed;
    };

    const nodes: []const graph_mod.Node = if (site) |s| s.nodes else &.{};
    var wiki_fail: wikilink.FailInfo = .{};
    const with_wiki = wikilink.rewriteWikiLinks(arena, expanded, nodes, page.output_path, &wiki_fail) catch |err| {
        if (!options.quiet) {
            wikilink.printDiagnostic(gpa, err, page.source_path, wiki_fail);
        }
        return error.ReferenceFailed;
    };

    // Body stream: markdown segments via Apex, Aside via aside.renderHtml.
    // Document order preserved; all HTML lives on the Whiteboard only.
    const tok = try aside.tokenizeBody(with_wiki, arena);
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

    var slots: assemble.SlotValues = .{ .content = html };

    if (layout.has_toc) {
        slots.toc = try html_toc.renderToc(arena, html);
    }

    if (site) |s| {
        const gi = s.indexOf(page.entity_id) orelse return error.GraphValidationFailed;
        const node = s.nodes[gi];
        if (layout.has_nav) {
            slots.nav = try html_nav.renderNav(arena, s.nodes, s.nav, gi, page.output_path);
        }
        if (layout.has_breadcrumb) {
            slots.breadcrumb = try html_nav.renderBreadcrumb(arena, s.nodes, s.nav, gi, page.output_path);
        }
        if (layout.has_title) {
            slots.title = try html_nav.renderTitle(arena, node);
        }
    } else if (layout.has_nav or layout.has_breadcrumb or layout.has_title) {
        // Layout requests graph chrome but no frozen site — treat as internal error.
        return error.GraphValidationFailed;
    }

    const fail_publish = if (options.test_fail_publish_at) |idx| idx == page_index else false;
    try assemble.writePageWithSlotsOpts(io, dist_dir, page.output_path, layout, slots, .{
        .fail_before_publish = fail_publish,
    });
}

pub const CacheEntry = struct {
    entity_id: []const u8,
    fingerprint: []const u8,
    output_path: []const u8,
    /// On-disk output size at last successful publish; used for incremental freshness.
    output_size: u64 = 0,
};

pub const CacheManifest = struct {
    format_version: []const u8 = cache.CACHE_FORMAT_VERSION,
    entries: []const CacheEntry,
};

pub const ParsedCacheEntry = struct {
    entity_id: []const u8,
    fingerprint: []const u8,
    output_path: []const u8,
    /// Optional for older manifests; missing/zero forces re-render when paired with size check.
    output_size: u64 = 0,
};

pub const ParsedCacheManifest = struct {
    format_version: []const u8,
    entries: []ParsedCacheEntry,
};

fn compareStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
    // Buffer via ArrayList so entity_id / paths / fingerprints go through json_out escaping.
    const gpa = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n  \"format_version\": ");
    try json_out.writeString(&buf, gpa, manifest.format_version);
    try buf.appendSlice(gpa, ",\n  \"entries\": [\n");
    for (manifest.entries, 0..) |entry, i| {
        try buf.appendSlice(gpa, "    {\n      \"entity_id\": ");
        try json_out.writeString(&buf, gpa, entry.entity_id);
        try buf.appendSlice(gpa, ",\n      \"fingerprint\": ");
        try json_out.writeString(&buf, gpa, entry.fingerprint);
        try buf.appendSlice(gpa, ",\n      \"output_path\": ");
        try json_out.writeString(&buf, gpa, entry.output_path);
        try buf.appendSlice(gpa, ",\n      \"output_size\": ");
        try json_out.writeUsize(&buf, gpa, @intCast(entry.output_size));
        try buf.appendSlice(gpa, "\n    }");
        if (i + 1 < manifest.entries.len) {
            try buf.appendSlice(gpa, ",\n");
        } else {
            try buf.append(gpa, '\n');
        }
    }
    try buf.appendSlice(gpa, "  ]\n}\n");
    try writer.writeAll(buf.items);
}

/// Site compile: layout → promote PageDb → graph freeze → whiteboard loop → dist/.
///
/// Single-threaded when `jobs == 1`. Does not mutate IR emit semantics.
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

    // 3. Graph validate + freeze (shared rules with IR/RAG; Feature 6 nav).
    var site = try freezeSiteFromPageDb(gpa, &db, options.quiet, layout.has_nav or layout.has_breadcrumb or layout.has_title);
    defer site.deinit();

    return try compilePagesWithSite(io, gpa, &db, layout, options, &site);
}

/// Shared, layout-independent fingerprint inputs built once for multi-target runs.
/// Layout path/bytes are applied per target (supports per-target layouts).
/// Owns all buffers; `dep_index` path strings live on `path_arena`.
const SharedCompileState = struct {
    gpa: std.mem.Allocator,
    path_arena: std.heap.ArenaAllocator,
    dep_index: dependency.DependencyIndex,
    /// Per-page source bytes (GPA-owned).
    source_bytes: [][]u8,
    /// Per-page transitive include file contents in stable sorted path order (GPA-owned).
    include_bytes: [][][]u8,
    /// Paths parallel to `include_bytes` (GPA-owned strings; same order).
    include_paths: [][][]u8,

    fn deinit(self: *SharedCompileState) void {
        for (self.include_bytes) |list| {
            for (list) |b| self.gpa.free(b);
            self.gpa.free(list);
        }
        self.gpa.free(self.include_bytes);
        for (self.include_paths) |list| {
            for (list) |p| self.gpa.free(p);
            self.gpa.free(list);
        }
        self.gpa.free(self.include_paths);
        for (self.source_bytes) |b| self.gpa.free(b);
        self.gpa.free(self.source_bytes);
        self.dep_index.deinit();
        self.path_arena.deinit();
    }

    fn init(
        io: Io,
        gpa: std.mem.Allocator,
        db: *PageDb,
        content_root: []const u8,
        quiet: bool,
    ) !SharedCompileState {
        const cwd = Io.Dir.cwd();
        _ = cwd;
        var content_dir = try Io.Dir.cwd().openDir(io, content_root, .{});
        defer content_dir.close(io);

        var path_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer path_arena.deinit();
        const inc_alloc = path_arena.allocator();

        var dep_index = dependency.DependencyIndex.init(gpa);
        errdefer dep_index.deinit();

        const source_bytes = try gpa.alloc([]u8, db.len());
        var sources_filled: usize = 0;
        errdefer {
            for (source_bytes[0..sources_filled]) |s| gpa.free(s);
            gpa.free(source_bytes);
        }

        for (db.items(), 0..) |p, i| {
            const src = try readFileAlloc(io, content_dir, p.source_path, gpa);
            source_bytes[i] = src;
            sources_filled = i + 1;
        }

        // F8.3: use the IR 0.2 resolver for direct parent/include/reference
        // edges. Forward include walks below derive transitive fingerprint input;
        // reverse walks later derive the affected page set.
        var dep_nodes = try gpa.alloc(graph_mod.Node, db.len());
        defer gpa.free(dep_nodes);
        for (db.items(), 0..) |p, i| {
            dep_nodes[i] = .{
                .id = p.entity_id,
                .source_path = p.source_path,
                .title = p.title,
                .parent = p.parent,
                .status = if (p.status) |s| s.name() else null,
                .tags = p.tags,
                .body_offset = p.body_offset,
            };
        }
        try pipeline.populateDependencyIndex(io, gpa, inc_alloc, content_root, dep_nodes, quiet, &dep_index);

        const include_bytes = try gpa.alloc([][]u8, db.len());
        const include_paths = try gpa.alloc([][]u8, db.len());
        var includes_filled: usize = 0;
        errdefer {
            for (include_bytes[0..includes_filled]) |list| {
                for (list) |b| gpa.free(b);
                gpa.free(list);
            }
            gpa.free(include_bytes);
            for (include_paths[0..includes_filled]) |list| {
                for (list) |p| gpa.free(p);
                gpa.free(list);
            }
            gpa.free(include_paths);
        }

        for (db.items(), 0..) |page, page_idx| {
            var transit_includes = std.ArrayList([]const u8).empty;
            defer {
                for (transit_includes.items) |inc| gpa.free(inc);
                transit_includes.deinit(gpa);
            }
            var visited_transit = std.StringHashMapUnmanaged(void).empty;
            defer visited_transit.deinit(gpa);

            try collectTransitIncludes(gpa, page.entity_id, &dep_index, &transit_includes, &visited_transit);
            std.mem.sort([]const u8, transit_includes.items, {}, compareStrings);

            var list = try gpa.alloc([]u8, transit_includes.items.len);
            var path_list = try gpa.alloc([]u8, transit_includes.items.len);
            var j: usize = 0;
            errdefer {
                for (list[0..j]) |b| gpa.free(b);
                gpa.free(list);
                for (path_list[0..j]) |p| gpa.free(p);
                gpa.free(path_list);
            }
            while (j < transit_includes.items.len) : (j += 1) {
                list[j] = try readFileAlloc(io, content_dir, transit_includes.items[j], gpa);
                path_list[j] = try gpa.dupe(u8, transit_includes.items[j]);
            }
            include_bytes[page_idx] = list;
            include_paths[page_idx] = path_list;
            includes_filled = page_idx + 1;
        }

        return .{
            .gpa = gpa,
            .path_arena = path_arena,
            .dep_index = dep_index,
            .source_bytes = source_bytes,
            .include_bytes = include_bytes,
            .include_paths = include_paths,
        };
    }
};

const CachedLayout = struct {
    layout: assemble.Layout,
    bytes: []u8,
};

fn isContentCompileFailure(err: anyerror) bool {
    return switch (err) {
        error.GraphValidationFailed,
        error.IncludeFailed,
        error.ReferenceFailed,
        error.ParseFailed,
        error.ComponentFailed,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.LayoutUnknownMarker,
        => true,
        else => false,
    };
}

/// Orchestrate multiple HTML build targets with complete isolation and sorted sequence.
/// Enforces validate-all-first, single discovery, then sequential rendering.
/// Returns a content or I/O sentinel matching the aggregate target failures.
///
/// `targets` may be a subset (watch selective fan-out). `base_options.layout_path` is the
/// global default used when a target has no layout override.
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

    // Shared graph freeze once for all targets (Feature 6). Always compute nav
    // material; fingerprint mixes it in only when a layout has `{{nav}}`.
    var site = try freezeSiteFromPageDb(gpa, &db, base_options.quiet, true);
    defer site.deinit();

    // Shared content/include fingerprint inputs once for all targets.
    var shared = try SharedCompileState.init(io, gpa, &db, base_options.content_root, base_options.quiet);
    defer shared.deinit();

    // Layout templates cached by path (per-target layouts share the same arena).
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    var layout_cache: std.StringHashMapUnmanaged(CachedLayout) = .{};
    defer layout_cache.deinit(gpa);

    var any_failed = false;
    var any_io_failed = false;
    for (plans) |plan| {
        var target_options = base_options;
        target_options.target_name = plan.name;
        target_options.dist_dir = plan.output_dir;
        target_options.layout_path = plan.layout_path;

        const gop = try layout_cache.getOrPut(gpa, plan.layout_path);
        if (!gop.found_existing) {
            const layout = loadLayoutOnce(io, Io.Dir.cwd(), plan.layout_path, layout_arena.allocator()) catch |err| {
                if (!base_options.quiet) {
                    std.debug.print("error: target '{s}' failed to load layout: {s}\n", .{ plan.name, @errorName(err) });
                }
                any_failed = true;
                any_io_failed = any_io_failed or !isContentCompileFailure(err);
                _ = layout_cache.remove(plan.layout_path);
                continue;
            };
            const bytes = readFileAlloc(io, Io.Dir.cwd(), plan.layout_path, gpa) catch |err| {
                if (!base_options.quiet) {
                    std.debug.print("error: target '{s}' failed to read layout: {s}\n", .{ plan.name, @errorName(err) });
                }
                any_failed = true;
                any_io_failed = true;
                _ = layout_cache.remove(plan.layout_path);
                continue;
            };
            gop.value_ptr.* = .{ .layout = layout, .bytes = bytes };
        }

        const cached = layout_cache.get(plan.layout_path).?;
        _ = compilePagesWithSharedAndSite(io, gpa, &db, cached.layout, target_options, &shared, cached.bytes, &site) catch |err| {
            // Include/wiki/graph already printed structured diags; skip duplicate @errorName.
            if (!base_options.quiet and err != error.IncludeFailed and err != error.ReferenceFailed and
                err != error.GraphValidationFailed)
            {
                std.debug.print("error: target '{s}' compilation failed: {s}\n", .{ plan.name, @errorName(err) });
            }
            any_failed = true;
            any_io_failed = any_io_failed or !isContentCompileFailure(err);
            continue;
        };
    }

    // Free layout bytes (arena owns Layout views into raw; bytes are GPA).
    var it = layout_cache.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.value_ptr.bytes);
    }

    if (any_failed) {
        if (any_io_failed) return error.MultiTargetIoFailed;
        return error.MultiTargetCompilationFailed;
    }
}

test "multi-target failure classification keeps I/O distinct from content" {
    try std.testing.expect(isContentCompileFailure(error.ParseFailed));
    try std.testing.expect(isContentCompileFailure(error.LayoutMissingMarker));
    try std.testing.expect(!isContentCompileFailure(error.AccessDenied));
    try std.testing.expect(!isContentCompileFailure(error.OutOfMemory));
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
    site: ?*const FrozenSite,

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
            renderAndPublishPageWithSite(
                ctx.io,
                ctx.gpa,
                ctx.content_dir,
                ctx.dist_dir,
                page,
                ctx.layout,
                &doc_arena,
                ctx.options,
                page_index,
                ctx.site,
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
/// Builds fingerprint inputs locally (single-target path).
/// Prefer `compilePagesWithSite` when a frozen graph is available.
pub fn compilePages(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
) !CompileStats {
    // Content-only layouts can compile without graph chrome; still freeze so
    // invalid parents fail loud on the HTML path.
    var site = try freezeSiteFromPageDb(gpa, db, options.quiet, layout.has_nav or layout.has_breadcrumb or layout.has_title);
    defer site.deinit();
    return compilePagesWithSite(io, gpa, db, layout, options, &site);
}

pub fn compilePagesWithSite(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
    site: *const FrozenSite,
) !CompileStats {
    const layout_bytes = try readFileAlloc(io, Io.Dir.cwd(), options.layout_path, gpa);
    defer gpa.free(layout_bytes);
    return compilePagesInner(io, gpa, db, layout, options, null, layout_bytes, site);
}

/// Like `compilePages` but reuses shared content/include fingerprint inputs
/// (multi-target path: prepare once, render each target with its layout bytes).
pub fn compilePagesWithShared(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
    shared: *const SharedCompileState,
    layout_bytes: []const u8,
) !CompileStats {
    var site = try freezeSiteFromPageDb(gpa, db, options.quiet, layout.has_nav or layout.has_breadcrumb or layout.has_title);
    defer site.deinit();
    return compilePagesInner(io, gpa, db, layout, options, shared, layout_bytes, &site);
}

pub fn compilePagesWithSharedAndSite(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
    shared: *const SharedCompileState,
    layout_bytes: []const u8,
    site: *const FrozenSite,
) !CompileStats {
    return compilePagesInner(io, gpa, db, layout, options, shared, layout_bytes, site);
}

fn fingerprintHex(fp_bytes: [32]u8, gpa: std.mem.Allocator) ![]u8 {
    var fp_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (fp_bytes, 0..) |b, i| {
        fp_hex[i * 2] = hex_chars[b >> 4];
        fp_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return try gpa.dupe(u8, &fp_hex);
}

fn expandDirtySet(
    gpa: std.mem.Allocator,
    is_dirty: []bool,
    pages: []const DurablePage,
    nodes: []const graph_mod.Node,
    dep_index: *const dependency.DependencyIndex,
) !void {
    for (pages, 0..) |page, page_idx| {
        if (!is_dirty[page_idx]) continue;
        const affected = try cache.getAffectedPages(gpa, page.source_path, nodes, dep_index);
        defer {
            for (affected) |id| gpa.free(id);
            gpa.free(affected);
        }
        for (affected) |id| {
            for (pages, 0..) |candidate, candidate_idx| {
                if (std.mem.eql(u8, candidate.entity_id, id)) {
                    is_dirty[candidate_idx] = true;
                    break;
                }
            }
        }
    }
}

/// Sibling staging directory for a target: `{dist_dir}.boris-stage`.
fn stageRelForDist(gpa: std.mem.Allocator, dist_dir: []const u8) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist_dir});
}

/// Publish all files under `stage_dir` into `final_dir` via same-parent rename.
/// Creates intermediate directories under `final_dir` as needed.
///
/// Prefer rename (atomic-ish on same filesystem). On `error.CrossDevice` (and
/// only that), fall back to `copyFile` + delete source. Cross-volume **atomic**
/// replace is still not claimed — the fallback is best-effort completeness.
fn publishStageTree(
    io: Io,
    gpa: std.mem.Allocator,
    stage_dir: Io.Dir,
    final_dir: Io.Dir,
) !void {
    var walker = try stage_dir.walkSelectively(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;

        if (std.fs.path.dirname(entry.path)) |parent| {
            if (parent.len > 0) {
                final_dir.createDirPath(io, parent) catch {};
            }
        }
        entry.dir.rename(entry.basename, final_dir, entry.path, io) catch |err| switch (err) {
            error.CrossDevice => {
                try entry.dir.copyFile(entry.basename, final_dir, entry.path, io, .{
                    .make_path = true,
                    .replace = true,
                });
                entry.dir.deleteFile(io, entry.basename) catch {};
            },
            else => return err,
        };
    }
}

fn compilePagesInner(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
    shared_opt: ?*const SharedCompileState,
    layout_bytes: []const u8,
    site: *const FrozenSite,
) !CompileStats {
    const cwd = Io.Dir.cwd();

    var content_dir = try cwd.openDir(io, options.content_root, .{});
    defer content_dir.close(io);

    try cwd.createDirPath(io, options.dist_dir);
    // Re-check for symlink swap after validation (TOCTOU shrink — issue #11).
    try target_mod.rejectSymlinkAlongPath(io, cwd, gpa, options.dist_dir);
    var dist_dir = try cwd.openDir(io, options.dist_dir, .{ .iterate = true });
    defer dist_dir.close(io);

    // Best-effort: remove orphan createFileAtomic temps left by interrupted runs.
    assemble.scrubStaleAtomicTemps(io, dist_dir, gpa);

    // Sibling staging: render dirty pages here; commit only after full target success.
    const stage_rel = try stageRelForDist(gpa, options.dist_dir);
    defer gpa.free(stage_rel);
    cwd.deleteTree(io, stage_rel) catch {};
    try cwd.createDirPath(io, stage_rel);
    errdefer cwd.deleteTree(io, stage_rel) catch {};
    try target_mod.rejectSymlinkAlongPath(io, cwd, gpa, stage_rel);

    var stage_dir = try cwd.openDir(io, stage_rel, .{ .iterate = true });
    defer stage_dir.close(io);

    // Own shared state when the caller did not supply one (single-target).
    var local_shared: ?SharedCompileState = null;
    defer if (local_shared) |*s| s.deinit();
    const shared: *const SharedCompileState = if (shared_opt) |s| s else blk: {
        local_shared = try SharedCompileState.init(io, gpa, db, options.content_root, options.quiet);
        break :blk &(local_shared.?);
    };

    // Load and parse prior manifest if in incremental mode (from final dist).
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

    // Precreate output directories under staging
    {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(gpa);
        try paths.ensureTotalCapacity(gpa, db.len());
        for (db.items()) |p| try paths.append(gpa, p.output_path);
        try assemble.precreateOutputDirs(io, stage_dir, gpa, paths.items);
    }

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
        // Convert owned []u8 include lists to []const u8 views for the hasher.
        const inc_owned = shared.include_bytes[page_idx];
        const inc_views = try gpa.alloc([]const u8, inc_owned.len);
        defer gpa.free(inc_views);
        for (inc_owned, 0..) |b, j| inc_views[j] = b;

        // Graph chrome (nav, breadcrumb, title) all depend on frozen site material.
        const needs_site_material = layout.has_nav or layout.has_breadcrumb or layout.has_title;
        const nav_material: []const u8 = if (needs_site_material) site.site_nav_material else "";
        // Wiki reference material from page body + transitive include fragment bodies
        // so title/path renames dirty parents that only wiki-link via includes.
        const body_for_wiki = include_mod.bodyOfSource(shared.source_bytes[page_idx]);
        const inc_paths = shared.include_paths[page_idx];
        var wiki_bodies = try gpa.alloc([]const u8, 1 + inc_owned.len);
        defer gpa.free(wiki_bodies);
        var wiki_paths = try gpa.alloc([]const u8, 1 + inc_owned.len);
        defer gpa.free(wiki_paths);
        wiki_bodies[0] = body_for_wiki;
        wiki_paths[0] = page.source_path;
        for (inc_owned, 0..) |inc_file, j| {
            wiki_bodies[1 + j] = include_mod.bodyOfSource(inc_file);
            wiki_paths[1 + j] = inc_paths[j];
        }
        var wiki_fail: wikilink.FailInfo = .{};
        const ref_material = wikilink.referenceMaterialMulti(gpa, wiki_bodies, wiki_paths, site.nodes, &wiki_fail) catch |err| {
            if (err == error.ReferenceMissing or err == error.ReferenceSyntax or err == error.PathError) {
                if (!options.quiet) {
                    wikilink.printDiagnostic(gpa, err, page.source_path, wiki_fail);
                }
                return error.ReferenceFailed;
            }
            return err;
        };
        defer gpa.free(ref_material);

        var inc_with_ref = try gpa.alloc([]const u8, inc_views.len + if (ref_material.len > 0) @as(usize, 1) else 0);
        defer gpa.free(inc_with_ref);
        @memcpy(inc_with_ref[0..inc_views.len], inc_views);
        if (ref_material.len > 0) {
            inc_with_ref[inc_views.len] = ref_material;
        }

        const fp_bytes = cache.computePageFingerprint(
            options.target_name,
            options.layout_path,
            page.entity_id,
            shared.source_bytes[page_idx],
            inc_with_ref,
            layout_bytes,
            nav_material,
        );
        fingerprints[page_idx] = try fingerprintHex(fp_bytes, gpa);

        var output_size: u64 = 0;
        var output_exists = false;
        if (dist_dir.openFile(io, page.output_path, .{})) |file| {
            if (file.stat(io)) |st| {
                if (st.size > 0) {
                    output_exists = true;
                    output_size = st.size;
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
                        // Freshness requires non-empty output whose size matches
                        // the size recorded at last publish (guards truncated/corrupt files).
                        if (output_exists and entry.output_size > 0 and entry.output_size == output_size) {
                            skip_render = true;
                            break;
                        }
                    }
                }
            }
        }
        is_dirty[page_idx] = !skip_render;
    }

    // Fingerprints identify changed page inputs; the shared frozen reverse
    // dependency story expands those seeds to parent/reference dependents.
    // This happens before workers and mutates only coordinator-owned state.
    if (options.incremental) {
        try expandDirtySet(gpa, is_dirty, db.items(), site.nodes, &shared.dep_index);
    }

    // Compile loop — dirty pages write into staging only
    var stats: CompileStats = .{};

    if (options.jobs > 1) {
        var ctx = ParallelContext{
            .gpa = gpa,
            .io = io,
            .content_dir = content_dir,
            .dist_dir = stage_dir,
            .db = db,
            .layout = layout,
            .options = options,
            .is_dirty = is_dirty,
            .site = site,
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
                try renderAndPublishPageWithSite(io, gpa, content_dir, stage_dir, page, layout, &doc_arena, options, page_index, site);
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

    // Write cache manifest into staging (committed with the rest of the target).
    if (options.incremental) {
        if (options.test_fail_cache_publish) {
            return error.TestInjectedCachePublishFailure;
        }

        var cache_entries = try gpa.alloc(CacheEntry, db.len());
        defer gpa.free(cache_entries);
        for (db.items(), 0..) |page, page_idx| {
            var out_size: u64 = 0;
            // Prefer staged (just-written) size; fall back to final dist for cached pages.
            if (stage_dir.openFile(io, page.output_path, .{})) |file| {
                if (file.stat(io)) |st| out_size = st.size else |_| {}
                file.close(io);
            } else |_| {
                if (dist_dir.openFile(io, page.output_path, .{})) |file| {
                    if (file.stat(io)) |st| out_size = st.size else |_| {}
                    file.close(io);
                } else |_| {}
            }
            cache_entries[page_idx] = .{
                .entity_id = page.entity_id,
                .fingerprint = fingerprints[page_idx],
                .output_path = page.output_path,
                .output_size = out_size,
            };
        }

        var atomic_manifest = try stage_dir.createFileAtomic(io, ".boris-cache/manifest.json", .{
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

    // Commit: rename staged files into final dist (final untouched until this point).
    try publishStageTree(io, gpa, stage_dir, dist_dir);

    // Stale cleanup: drop published HTML for pages no longer in PageDb.
    // Prefer prior incremental manifest when present; otherwise scan dist/*.html
    // against current output_path set so --watch without --incremental still prunes.
    {
        var live_paths: std.StringHashMapUnmanaged(void) = .{};
        defer live_paths.deinit(gpa);
        for (db.items()) |p| {
            try live_paths.put(gpa, p.output_path, {});
        }

        if (parsed_manifest) |pm| {
            for (pm.value.entries) |entry| {
                if (!live_paths.contains(entry.output_path)) {
                    dist_dir.deleteFile(io, entry.output_path) catch {};
                }
            }
        } else if (!options.incremental) {
            // Full rebuild: remove html outputs under dist that are not in this build.
            var walker = try dist_dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
                if (std.mem.startsWith(u8, entry.path, ".boris-cache")) continue;
                if (!live_paths.contains(entry.path)) {
                    dist_dir.deleteFile(io, entry.path) catch {};
                }
            }
        }
    }

    // Drop staging tree (errdefer also cleans on earlier failure).
    cwd.deleteTree(io, stage_rel) catch {};

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-missing-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-dup-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-splice", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-render-fail", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    const result = renderAndPublishPage(io, gpa, content_dir, dist_dir, page, layout, &doc_arena, .{
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-write-fail", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-pagedb", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-paths", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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

test "HTML path rejects invalid parent (graph gate)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f6-graph-gate", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html>{{nav}}{{content}}</html>");
    try writeTreeFile(io, work, "content/orphan.md", "---\ntitle: Orphan\nparent: missing-trunk\n---\n\n# Orphan\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.GraphValidationFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "HTML path emits site nav and breadcrumb for forest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f6-nav-emit", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html",
        \\<html><title>{{title}}</title>{{nav}}{{breadcrumb}}{{content}}</html>
    );
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n\n# Home\n");
    try writeTreeFile(io, work, "content/guides/child.md", "---\ntitle: Child\nparent: index\n---\n\n# Child\n");

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
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const child = try readAllFile(io, dist_dir, "guides/child.html", gpa);
    defer gpa.free(child);
    try std.testing.expect(std.mem.indexOf(u8, child, "site-nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "site-nav__satellite is-current") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "../index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "breadcrumb") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "<title>Child</title>") != null);
}

test "HTML path emits page toc from body headings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f6-toc-emit", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html",
        \\<html>{{toc}}<main>{{content}}</main></html>
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Outline
        \\---
        \\
        \\# Top Level
        \\
        \\Intro paragraph.
        \\
        \\## Section One
        \\
        \\### Nested
        \\
        \\## Section Two
        \\
        \\#### Skipped depth
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

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "page-toc") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "aria-label=\"On this page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#top-level\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#section-one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"#section-two\"") != null);
    // h4 is not in toc.
    try std.testing.expect(std.mem.indexOf(u8, page, "skipped-depth") == null or
        std.mem.indexOf(u8, page, "href=\"#skipped-depth\"") == null);
    // Body still has the h4 id for in-page anchors.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"skipped-depth\"") != null);
    // TOC anchors match body heading ids.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"section-one\"") != null);
}

test "html fixture golden: expected/ matches compile output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-golden", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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

test "Feature 7 HTML: include expands and wiki becomes relative href" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-include-wiki-ok", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\# Home
        \\
        \\{{include includes/blurb.md}}
        \\
        \\See [[guides/note]] for more.
        \\
    );
    try writeTreeFile(io, work, "content/guides/note.md",
        \\---
        \\title: Note
        \\parent: index
        \\---
        \\# Note
        \\
        \\Satellite page.
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "INCLUDED_BLURB and [[guides/note|Note link]].\n");

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
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "INCLUDED_BLURB") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "{{include") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "[[") == null);
    // Wiki rewrite → Markdown link → Apex <a href="…">
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"guides/note.html\"") != null);
}

test "Feature 7 HTML: fail-loud missing include" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-missing-include", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\{{include includes/does-not-exist.md}}
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: fail-loud include cycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-include-cycle", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\{{include includes/c1.md}}
        \\
    );
    try writeTreeFile(io, work, "content/includes/c1.md", "{{include includes/c2.md}}\n");
    try writeTreeFile(io, work, "content/includes/c2.md", "{{include includes/c1.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: nested include missing reports fragment locus" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-nested-locus", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\{{include includes/outer.md}}
        \\
    );
    try writeTreeFile(io, work, "content/includes/outer.md", "line1\n{{include includes/nope.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Plan-time collect fails; FailInfo locus is the outer fragment (unit-tested).
    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: fail-loud missing wiki target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-missing-wiki", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\See [[no/such/page]] please.
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.ReferenceFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "Feature 7 HTML: fenced include and wiki stay literal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-fences", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\# Home
        \\
        \\```
        \\{{include includes/secret.md}}
        \\[[fenced/wiki]]
        \\```
        \\
        \\~~~
        \\{{include includes/secret.md}}
        \\[[fenced/wiki]]
        \\~~~
        \\
        \\Live text.
        \\
    );
    // If fences were broken, missing include / missing wiki would fail loud.
    try writeTreeFile(io, work, "content/includes/secret.md", "SHOULD_NOT_APPEAR\n");

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

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "SHOULD_NOT_APPEAR") == null);
    // Literal directive text survives inside code blocks (HTML-escaped or raw).
    try std.testing.expect(
        std.mem.indexOf(u8, page, "{{include") != null or
            std.mem.indexOf(u8, page, "{{include includes/secret.md}}") != null or
            std.mem.indexOf(u8, page, "include includes/secret") != null,
    );
}

test "flush-before-reset: compile defers free_all only after writePage" {
    // Structural proof via HoldUntilFlush sink (see assemble tests) plus
    // end-to-end: after compileHtmlSite, Whiteboard capacity is 0 and files
    // are complete (publication finished before last free_all).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-m9-flush-order", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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
    // Real Apex emits header ids: <h1 id="...">
    try std.testing.expect(std.mem.indexOf(u8, got, "<h1") != null);
}

test "Feature 7 incremental: title rename dirties parent that only wiki-links via include" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f7-wiki-via-include", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    // alpha: wiki only via include (no direct [[beta]])
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha
        \\---
        \\# Alpha
        \\
        \\{{include includes/blurb.md}}
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Original
        \\---
        \\# Beta
        \\
    );
    // gamma: control page — must stay cached when only beta title changes
    try writeTreeFile(io, work, "content/gamma.md",
        \\---
        \\title: Gamma
        \\---
        \\# Gamma independent
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "See [[beta]] from include.\n");

    // Cold build
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
        try std.testing.expectEqual(@as(usize, 3), stats.pages_written);
    }

    // Unchanged → zero writes
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
    }

    // Rename beta title only — beta source dirty + alpha via multi-body wiki material.
    // gamma must remain cached.
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta Renamed
        \\---
        \\# Beta
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
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 3), stats.pages_attempted);
    }

    // alpha HTML should show the new wiki label from the renamed title
    {
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        const alpha_html = try readAllFile(io, dist_dir, "alpha.html", gpa);
        defer gpa.free(alpha_html);
        try std.testing.expect(std.mem.indexOf(u8, alpha_html, "Beta Renamed") != null);
        try std.testing.expect(std.mem.indexOf(u8, alpha_html, "href=\"beta.html\"") != null);
    }
}

test "F8.3 incremental: changed page expands through parent and reference reverse edges" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f8-3-page-reverse", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n\n# Home\nOriginal body.\n");
    try writeTreeFile(io, work, "content/child.md", "---\ntitle: Child\nparent: index\n---\n\n# Child\nSee [[index]].\n");
    try writeTreeFile(io, work, "content/control.md", "---\ntitle: Control\n---\n\n# Control\nIndependent.\n");

    // Cold build and unchanged control run establish a valid cache.
    for ([_]usize{ 3, 0 }) |expected_writes| {
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
        try std.testing.expectEqual(expected_writes, stats.pages_written);
    }

    // Body-only target change does not alter the child's own fingerprint
    // material. The frozen reverse parent/reference edges must still dirty it;
    // the unrelated control remains cached.
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n\n# Home\nEdited body only.\n");
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
        try std.testing.expectEqual(@as(usize, 3), stats.pages_attempted);
    }
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
    const full_dist = try std.fmt.allocPrint(gpa, "{s}/dist-full", .{work});
    defer gpa.free(full_dist);

    // Write initial layouts and content files
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha Page
        \\---
        \\# Alpha
        \\
        \\{{include includes/sidebar.md}}
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
    try writeTreeFile(io, work, "content/includes/sidebar.md", "Sidebar {{include includes/widget.md}} content.");
    try writeTreeFile(io, work, "content/includes/widget.md", "Widget nested content.");

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

    // A cold incremental build must be byte-equivalent to a full build.
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
            .dist_dir = full_dist,
            .layout_path = layout_path,
            .incremental = false,
            .quiet = true,
        });
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
    }
    {
        var inc_dir = try cwd.openDir(io, dist, .{});
        defer inc_dir.close(io);
        var full_dir = try cwd.openDir(io, full_dist, .{});
        defer full_dir.close(io);
        for ([_][]const u8{ "alpha.html", "beta.html" }) |path| {
            const incremental = try readAllFile(io, inc_dir, path, gpa);
            defer gpa.free(incremental);
            const full = try readAllFile(io, full_dir, path, gpa);
            defer gpa.free(full);
            try std.testing.expectEqualSlices(u8, full, incremental);
        }
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
    // Edit content/includes/widget.md.
    // Since alpha.md depends on includes/sidebar.md which depends on includes/widget.md,
    // editing widget.md should trigger a re-render of alpha.md but NOT beta.md!
    try writeTreeFile(io, work, "content/includes/widget.md", "Widget nested content edited!");

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

// D4 product-path smoke: Unified-rich pages under `--jobs` must match sequential
// HTML and two parallel runs must be byte-identical. Distinctive markers detect
// cross-talk if concurrent Apex renders share mutable engine state.
test "compilePages: parallel Unified constructs stable under jobs (D4)" {
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
    const dist_par_a = try std.fmt.allocPrint(gpa, "{s}/dist-par-a", .{work});
    defer gpa.free(dist_par_a);
    const dist_par_b = try std.fmt.allocPrint(gpa, "{s}/dist-par-b", .{work});
    defer gpa.free(dist_par_b);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    try writeTreeFile(io, work, "content/table.md",
        \\---
        \\title: Table
        \\---
        \\| a | b |
        \\|---|---|
        \\| TBL-PAGE | 2 |
        \\
    );
    try writeTreeFile(io, work, "content/footnote.md",
        \\---
        \\title: Footnote
        \\---
        \\Hi[^1] FOOT-PAGE.
        \\
        \\[^1]: note body FOOT-PAGE
        \\
    );
    try writeTreeFile(io, work, "content/math.md",
        \\---
        \\title: Math
        \\---
        \\Inline $x$ MATH-PAGE
        \\
        \\$$
        \\y
        \\$$
        \\
    );
    try writeTreeFile(io, work, "content/callout.md",
        \\---
        \\title: Callout
        \\---
        \\> [!NOTE]
        \\> callout body CALL-PAGE
        \\
    );
    try writeTreeFile(io, work, "content/lists.md",
        \\---
        \\title: Lists
        \\---
        \\- item LIST-PAGE
        \\  - nested LIST-PAGE
        \\
        \\```c
        \\int CODE_PAGE = 1 < 2;
        \\```
        \\
    );
    try writeTreeFile(io, work, "content/deflist.md",
        \\---
        \\title: DefList
        \\---
        \\Term DL-PAGE
        \\: Definition DL-PAGE
        \\
        \\~~strike STRIKE-PAGE~~
        \\
    );

    const out_files = [_][]const u8{
        "table.html",
        "footnote.html",
        "math.html",
        "callout.html",
        "lists.html",
        "deflist.html",
    };
    const markers = [_][]const u8{
        "TBL-PAGE",
        "FOOT-PAGE",
        "MATH-PAGE",
        "CALL-PAGE",
        "LIST-PAGE",
        "DL-PAGE",
    };

    const runOnce = struct {
        fn go(
            io_: Io,
            gpa_: std.mem.Allocator,
            content_: []const u8,
            dist: []const u8,
            layout_path_: []const u8,
            jobs: usize,
        ) !void {
            const cwd_ = Io.Dir.cwd();
            var layout_arena = std.heap.ArenaAllocator.init(gpa_);
            defer layout_arena.deinit();
            const layout = try loadLayoutOnce(io_, cwd_, layout_path_, layout_arena.allocator());

            var retain_arena = std.heap.ArenaAllocator.init(gpa_);
            defer retain_arena.deinit();
            var db = PageDb.init(gpa_, retain_arena.allocator());
            defer db.deinit();
            try loadAndPromote(io_, gpa_, &db, content_);

            const stats = try compilePages(io_, gpa_, &db, layout, .{
                .content_root = content_,
                .dist_dir = dist,
                .layout_path = layout_path_,
                .jobs = jobs,
                .quiet = true,
            });
            try std.testing.expectEqual(@as(usize, 6), stats.pages_written);
        }
    }.go;

    try runOnce(io, gpa, content, dist_seq, layout_path, 1);
    try runOnce(io, gpa, content, dist_par_a, layout_path, 8);
    try runOnce(io, gpa, content, dist_par_b, layout_path, 8);

    for (out_files, 0..) |f, fi| {
        const path_seq = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_seq, f });
        defer gpa.free(path_seq);
        const path_a = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_par_a, f });
        defer gpa.free(path_a);
        const path_b = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_par_b, f });
        defer gpa.free(path_b);

        const bytes_seq = try readFileAlloc(io, cwd, path_seq, gpa);
        defer gpa.free(bytes_seq);
        const bytes_a = try readFileAlloc(io, cwd, path_a, gpa);
        defer gpa.free(bytes_a);
        const bytes_b = try readFileAlloc(io, cwd, path_b, gpa);
        defer gpa.free(bytes_b);

        try std.testing.expectEqualStrings(bytes_seq, bytes_a);
        try std.testing.expectEqualStrings(bytes_a, bytes_b);
        try std.testing.expect(std.mem.indexOf(u8, bytes_a, markers[fi]) != null);

        // Foreign markers must not appear (cross-talk).
        for (markers, 0..) |tok, mi| {
            if (mi == fi) continue;
            try std.testing.expect(std.mem.indexOf(u8, bytes_a, tok) == null);
        }
    }
}

test "compileHtmlSiteMulti - success, validation, and isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-multi-compile-test", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

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

        try std.testing.expectEqualStrings("L<h1 id=\"alpha\">Alpha</h1>\n", alpha_a);
        try std.testing.expectEqualStrings("L<h1 id=\"alpha\">Alpha</h1>\n", alpha_b);

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
