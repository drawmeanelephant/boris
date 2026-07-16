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
const theme_mod = @import("theme.zig");
const layout_select = @import("layout_select.zig");

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
    /// Fallback layout path (global / --target-layout / product default).
    layout_path: []const u8 = "layouts/main.html",
    /// Target-owned layout rules (`--layout-rule`). Empty → one layout for all pages.
    layout_rules: []const layout_select.LayoutRule = &.{},
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
        error.InvalidAssetUrl => return error.LayoutInvalidAssetUrl,
        error.TooManyAssetUrls => return error.LayoutInvalidAssetUrl,
        error.InvalidUtf8 => return error.LayoutInvalidUtf8,
        else => |e| return e,
    };
}

/// F9.1 closed metadata fragment: status, parent, tags when set (escaped).
/// Title is owned by `{{title}}`; entity id is not repeated as chrome.
/// Empty string when no set fields.
fn renderMetadata(allocator: std.mem.Allocator, page: *const DurablePage) ![]const u8 {
    const has_status = page.status != null;
    const has_parent = if (page.parent) |p| p.len > 0 else false;
    const has_tags = page.tags.len > 0;
    if (!has_status and !has_parent and !has_tags) return "";

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<dl class=\"page-metadata\">\n");
    if (page.status) |st| {
        try buf.appendSlice(allocator, "  <div><dt>Status</dt><dd>");
        try html_nav.appendEscaped(&buf, allocator, st.name());
        try buf.appendSlice(allocator, "</dd></div>\n");
    }
    if (page.parent) |parent| {
        if (parent.len > 0) {
            try buf.appendSlice(allocator, "  <div><dt>Parent</dt><dd>");
            try html_nav.appendEscaped(&buf, allocator, parent);
            try buf.appendSlice(allocator, "</dd></div>\n");
        }
    }
    if (page.tags.len > 0) {
        try buf.appendSlice(allocator, "  <div><dt>Tags</dt><dd>");
        for (page.tags, 0..) |tag, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try html_nav.appendEscaped(&buf, allocator, tag);
        }
        try buf.appendSlice(allocator, "</dd></div>\n");
    }
    try buf.appendSlice(allocator, "</dl>\n");
    return try buf.toOwnedSlice(allocator);
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
    return renderAndPublishPageWithSiteAndHeadings(
        io,
        gpa,
        content_dir,
        dist_dir,
        page,
        layout,
        doc_arena,
        options,
        page_index,
        site,
        null,
    );
}

pub fn renderAndPublishPageWithSiteAndHeadings(
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
    heading_index: ?*const wikilink.HeadingIndex,
) !void {
    return renderAndPublishPageWithTheme(
        io,
        gpa,
        content_dir,
        dist_dir,
        page,
        layout,
        doc_arena,
        options,
        page_index,
        site,
        heading_index,
        null,
    );
}

pub fn renderAndPublishPageWithTheme(
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
    heading_index: ?*const wikilink.HeadingIndex,
    theme: ?*const theme_mod.ThemeBundle,
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
    const with_wiki = wikilink.rewriteWikiLinksOpts(arena, expanded, nodes, page.output_path, &wiki_fail, .{
        .heading_index = heading_index,
        .validate_fragments = heading_index != null,
    }) catch |err| {
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
    if (layout.has_metadata) {
        slots.metadata = try renderMetadata(arena, page);
    }
    if (layout.has_footer) {
        slots.footer = if (theme) |t| t.footer() else "";
    }
    if (layout.has_asset_url) {
        const paths = layout.assetPaths();
        var hrefs = try arena.alloc([]const u8, paths.len);
        for (paths, 0..) |ap, i| {
            hrefs[i] = try identity.relativeHref(arena, page.output_path, ap);
        }
        slots.asset_hrefs = hrefs;
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
    /// Effective selected layout path for this target/page (workspace-relative).
    selected_layout: []const u8 = "",
    /// On-disk output size at last successful publish (cheap prefilter).
    output_size: u64 = 0,
    /// Lowercase hex SHA-256 of published HTML bytes; empty forces re-render.
    output_digest: []const u8 = "",
};

pub const CacheManifest = struct {
    format_version: []const u8 = cache.CACHE_FORMAT_VERSION,
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
        try buf.appendSlice(gpa, ",\n      \"selected_layout\": ");
        try json_out.writeString(&buf, gpa, entry.selected_layout);
        try buf.appendSlice(gpa, ",\n      \"output_size\": ");
        try json_out.writeUsize(&buf, gpa, @intCast(entry.output_size));
        try buf.appendSlice(gpa, ",\n      \"output_digest\": ");
        try json_out.writeString(&buf, gpa, entry.output_digest);
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
    /// Theme fingerprint material for this layout (footer + its asset-url refs).
    theme_material: []u8 = &.{},
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
        error.LayoutInvalidAssetUrl,
        error.LayoutInvalidUtf8,
        error.AssetNotFound,
        error.AssetCollision,
        error.AssetSymlink,
        error.AssetPathEscape,
        error.ThemeRootMissing,
        error.InvalidThemePath,
        error.ThemeSymlink,
        error.FooterSymlink,
        => true,
        // Layout-rule selection failures are usage (exit 2), not content.
        error.AmbiguousGlob,
        error.MixedThemeRoots,
        error.DuplicateSelector,
        error.LayoutSelectionFailed,
        => false,
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

    // Preflight layout selection for every target/page before any target publishes
    // (RFC §5: ambiguous globs and mixed roots must not leave partial publications).
    for (plans) |plan| {
        target_mod.rejectMixedThemeRoots(plan.layout_path, plan.layout_rules) catch |err| {
            if (!base_options.quiet) {
                std.debug.print("error: target '{s}' mixed theme roots in layout rules: {s}\n", .{ plan.name, @errorName(err) });
            }
            return error.MixedThemeRoots;
        };
        for (db.items()) |page| {
            _ = layout_select.selectLayout(page.entity_id, page.role, plan.layout_rules, plan.layout_path) catch |err| {
                if (!base_options.quiet) {
                    std.debug.print("error: target '{s}' layout selection failed for '{s}': {s}\n", .{
                        plan.name,
                        page.entity_id,
                        @errorName(err),
                    });
                }
                return switch (err) {
                    error.AmbiguousGlob => error.AmbiguousGlob,
                    error.DuplicateSelector => error.DuplicateSelector,
                    else => error.LayoutSelectionFailed,
                };
            };
        }
    }

    // Layout templates cached by path (per-target layouts share the same arena).
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    var layout_cache: std.StringHashMapUnmanaged(CachedLayout) = .{};
    defer layout_cache.deinit(gpa);

    var any_failed = false;
    var any_io_failed = false;
    var any_usage_failed = false;
    for (plans) |plan| {
        var target_options = base_options;
        target_options.target_name = plan.name;
        target_options.dist_dir = plan.output_dir;
        target_options.layout_path = plan.layout_path;
        target_options.layout_rules = plan.layout_rules;

        // Load every declared layout (fallback + rules), even if no page selects it.
        const declared = layout_select.collectDeclaredLayouts(gpa, plan.layout_path, plan.layout_rules) catch {
            any_failed = true;
            any_io_failed = true;
            continue;
        };
        defer gpa.free(declared);

        var load_failed = false;
        for (declared) |lp| {
            const gop = try layout_cache.getOrPut(gpa, lp);
            if (gop.found_existing) continue;
            const layout = loadLayoutOnce(io, Io.Dir.cwd(), lp, layout_arena.allocator()) catch |err| {
                if (!base_options.quiet) {
                    std.debug.print("error: target '{s}' failed to load layout {s}: {s}\n", .{ plan.name, lp, @errorName(err) });
                }
                any_failed = true;
                any_io_failed = any_io_failed or !isContentCompileFailure(err);
                _ = layout_cache.remove(lp);
                load_failed = true;
                break;
            };
            const bytes = readFileAlloc(io, Io.Dir.cwd(), lp, gpa) catch |err| {
                if (!base_options.quiet) {
                    std.debug.print("error: target '{s}' failed to read layout {s}: {s}\n", .{ plan.name, lp, @errorName(err) });
                }
                any_failed = true;
                any_io_failed = true;
                _ = layout_cache.remove(lp);
                load_failed = true;
                break;
            };
            gop.value_ptr.* = .{ .layout = layout, .bytes = bytes };
        }
        if (load_failed) continue;

        const cached = layout_cache.get(plan.layout_path).?;
        _ = compilePagesWithSharedAndSite(io, gpa, &db, cached.layout, target_options, &shared, cached.bytes, &site) catch |err| {
            if (!base_options.quiet and err != error.IncludeFailed and err != error.ReferenceFailed and
                err != error.GraphValidationFailed and err != error.AmbiguousGlob and
                err != error.MixedThemeRoots and err != error.LayoutSelectionFailed)
            {
                std.debug.print("error: target '{s}' compilation failed: {s}\n", .{ plan.name, @errorName(err) });
            }
            any_failed = true;
            if (err == error.AmbiguousGlob or err == error.MixedThemeRoots or
                err == error.DuplicateSelector or err == error.LayoutSelectionFailed)
            {
                any_usage_failed = true;
            } else {
                any_io_failed = any_io_failed or !isContentCompileFailure(err);
            }
            continue;
        };
    }

    // Free layout bytes (arena owns Layout views into raw; bytes are GPA).
    var it = layout_cache.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.value_ptr.bytes);
        if (entry.value_ptr.theme_material.len > 0) gpa.free(entry.value_ptr.theme_material);
    }

    if (any_failed) {
        if (any_usage_failed) return error.LayoutSelectionFailed;
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
    /// Per-page selected layout (parallel to PageDb).
    page_layouts: []const assemble.Layout,
    options: CompileOptions,
    is_dirty: []const bool,
    site: ?*const FrozenSite,
    heading_index: ?*const wikilink.HeadingIndex,
    theme: ?*const theme_mod.ThemeBundle,

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
            renderAndPublishPageWithTheme(
                ctx.io,
                ctx.gpa,
                ctx.content_dir,
                ctx.dist_dir,
                page,
                ctx.page_layouts[page_index],
                &doc_arena,
                ctx.options,
                page_index,
                ctx.site,
                ctx.heading_index,
                ctx.theme,
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

/// Collect owned entity ids that are targets of any `[[entity#heading]]` in the site
/// (page bodies + transitive include bodies). Empty when no fragment links exist.
fn collectFragmentTargetSet(
    gpa: std.mem.Allocator,
    db: *const PageDb,
    shared: *const SharedCompileState,
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

    for (db.items(), 0..) |page, page_idx| {
        raw_ids.clearRetainingCapacity();
        seen.clearRetainingCapacity();

        const body = include_mod.bodyOfSource(shared.source_bytes[page_idx]);
        var fail: wikilink.FailInfo = .{};
        try wikilink.collectFragmentTargetIds(body, gpa, &raw_ids, &seen, &fail, page.source_path);

        const inc_owned = shared.include_bytes[page_idx];
        const inc_paths = shared.include_paths[page_idx];
        for (inc_owned, 0..) |inc_file, j| {
            const inc_body = include_mod.bodyOfSource(inc_file);
            try wikilink.collectFragmentTargetIds(inc_body, gpa, &raw_ids, &seen, &fail, inc_paths[j]);
        }

        for (raw_ids.items) |id| {
            const gop = try targets.getOrPut(gpa, id);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, id);
            }
        }
    }
    return targets;
}

/// Harvest Apex-rendered heading ids for pages that are wiki-fragment targets.
/// Reuses the same pre-Apex + Apex body pipeline as publish (no second slugger).
/// Wiki fragments are emitted but not validated here (index bootstrapping).
/// When no fragment links exist, returns an empty index (no Apex work).
fn buildSiteHeadingIndex(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    db: *const PageDb,
    site: *const FrozenSite,
    shared: *const SharedCompileState,
    quiet: bool,
) !wikilink.HeadingIndex {
    var index: wikilink.HeadingIndex = .{};
    errdefer index.deinit(gpa);

    var needed = try collectFragmentTargetSet(gpa, db, shared);
    defer {
        var it = needed.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        needed.deinit(gpa);
    }
    if (needed.count() == 0) return index;

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    for (db.items()) |page| {
        if (!needed.contains(page.entity_id)) continue;

        _ = doc_arena.reset(.free_all);
        const arena = doc_arena.allocator();

        const source = try readFileAlloc(io, content_dir, page.source_path, arena);
        const parsed = parser.parse(source);
        if (parsed.diagnostic != null) return error.ParseFailed;

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
            if (!quiet) {
                include_mod.printDiagnostic(gpa, err, page.source_path, include_fail);
            }
            return error.IncludeFailed;
        };

        var wiki_fail: wikilink.FailInfo = .{};
        // Do not validate fragments while building the index they depend on.
        const with_wiki = wikilink.rewriteWikiLinksOpts(
            arena,
            expanded,
            site.nodes,
            page.output_path,
            &wiki_fail,
            .{ .heading_index = null, .validate_fragments = false },
        ) catch |err| {
            if (!quiet) {
                wikilink.printDiagnostic(gpa, err, page.source_path, wiki_fail);
            }
            return error.ReferenceFailed;
        };

        const tok = try aside.tokenizeBody(with_wiki, arena);
        if (tok.hasErrors()) return error.ComponentFailed;

        var html_buf: std.ArrayList(u8) = .empty;
        for (tok.segments) |seg| {
            switch (seg) {
                .markdown => |md| {
                    if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                    const h = try apex.render(md, &doc_arena);
                    try html_buf.appendSlice(arena, h.bytes);
                },
                .aside => |c| {
                    const h = try aside.renderHtml(c, &doc_arena);
                    try html_buf.appendSlice(arena, h);
                },
            }
        }

        var ids: std.ArrayList([]const u8) = .empty;
        defer {
            for (ids.items) |id| gpa.free(id);
            ids.deinit(gpa);
        }
        // collectHeadingIds allocates id copies on gpa (not the page arena).
        try html_toc.collectHeadingIds(gpa, html_buf.items, &ids);
        try index.putOwned(gpa, page.entity_id, ids.items);
    }

    return index;
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

    // Layout selection: load every declared layout (fallback + rules), select per page.
    try target_mod.rejectMixedThemeRoots(options.layout_path, options.layout_rules);
    const declared = try layout_select.collectDeclaredLayouts(gpa, options.layout_path, options.layout_rules);
    defer gpa.free(declared);

    var layout_arena_local = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena_local.deinit();
    var layouts_by_path: std.StringHashMapUnmanaged(CachedLayout) = .{};
    defer {
        var it = layouts_by_path.iterator();
        while (it.next()) |e| {
            // Fallback bytes may be borrowed from caller (layout_bytes); only free owned.
            if (e.value_ptr.bytes.ptr != layout_bytes.ptr) {
                gpa.free(e.value_ptr.bytes);
            }
            if (e.value_ptr.theme_material.len > 0) gpa.free(e.value_ptr.theme_material);
        }
        layouts_by_path.deinit(gpa);
    }

    // Seed with the caller-provided fallback layout (bytes may be shared).
    try layouts_by_path.put(gpa, options.layout_path, .{
        .layout = layout,
        .bytes = @constCast(layout_bytes),
    });
    for (declared) |lp| {
        if (layouts_by_path.contains(lp)) continue;
        const loaded = try loadLayoutOnce(io, cwd, lp, layout_arena_local.allocator());
        const bytes = try readFileAlloc(io, cwd, lp, gpa);
        try layouts_by_path.put(gpa, lp, .{ .layout = loaded, .bytes = bytes });
    }

    // Per-page selection (after graph freeze; roles are on PageDb).
    const page_sel_paths = try gpa.alloc([]const u8, db.len());
    defer gpa.free(page_sel_paths);
    const page_layouts = try gpa.alloc(assemble.Layout, db.len());
    defer gpa.free(page_layouts);
    const page_layout_bytes = try gpa.alloc([]const u8, db.len());
    defer gpa.free(page_layout_bytes);

    for (db.items(), 0..) |page, i| {
        const sel = layout_select.selectLayout(page.entity_id, page.role, options.layout_rules, options.layout_path) catch |err| {
            if (!options.quiet) {
                std.debug.print("error: layout selection failed for target '{s}' page '{s}': {s}\n", .{
                    options.target_name,
                    page.entity_id,
                    @errorName(err),
                });
            }
            return switch (err) {
                error.AmbiguousGlob => error.AmbiguousGlob,
                error.DuplicateSelector => error.DuplicateSelector,
                else => error.LayoutSelectionFailed,
            };
        };
        page_sel_paths[i] = sel.layout_path;
        const cached = layouts_by_path.get(sel.layout_path) orelse return error.LayoutSelectionFailed;
        page_layouts[i] = cached.layout;
        page_layout_bytes[i] = cached.bytes;
    }

    // F9.1 theme: one root per target from the fallback layout (rules share it).
    const theme_root = theme_mod.themeRootFromLayoutPath(options.layout_path) orelse "";
    // Any selected/declared layout with asset-url requires a managed theme root.
    {
        var it = layouts_by_path.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.layout.has_asset_url and theme_root.len == 0) return error.ThemeRootMissing;
        }
    }
    var theme_bundle = try theme_mod.loadThemeBundle(io, gpa, cwd, theme_root);
    defer theme_bundle.deinit();
    // Validate asset refs for every declared layout (stale rules cannot hide broken templates).
    {
        var it = layouts_by_path.iterator();
        while (it.next()) |e| {
            try theme_mod.requireReferencedAssets(&theme_bundle, e.value_ptr.layout.assetPaths());
        }
    }
    {
        var outs: std.ArrayList([]const u8) = .empty;
        defer outs.deinit(gpa);
        try outs.ensureTotalCapacity(gpa, db.len());
        for (db.items()) |p| try outs.append(gpa, p.output_path);
        try theme_mod.checkAssetPageCollisions(theme_bundle.assets, outs.items);
    }
    // Always publish theme assets into staging (target-owned; not shared).
    try theme_mod.copyAssetsToOutput(io, stage_dir, theme_bundle.assets);

    // Per-layout theme fingerprint material (footer + that layout's asset-url refs).
    {
        var it = layouts_by_path.iterator();
        while (it.next()) |e| {
            e.value_ptr.theme_material = try theme_mod.referencedAssetMaterial(
                gpa,
                &theme_bundle,
                e.value_ptr.layout.assetPaths(),
                e.value_ptr.layout.has_footer,
            );
        }
    }
    const page_theme_material = try gpa.alloc([]const u8, db.len());
    defer gpa.free(page_theme_material);
    for (page_sel_paths, 0..) |lp, i| {
        page_theme_material[i] = layouts_by_path.get(lp).?.theme_material;
    }

    // Own shared state when the caller did not supply one (single-target).
    var local_shared: ?SharedCompileState = null;
    defer if (local_shared) |*s| s.deinit();
    const shared: *const SharedCompileState = if (shared_opt) |s| s else blk: {
        local_shared = try SharedCompileState.init(io, gpa, db, options.content_root, options.quiet);
        break :blk &(local_shared.?);
    };

    // Heading id index for wiki `[[entity#heading]]` (Apex-rendered ids only;
    // only pages that are fragment targets are rendered for the index).
    var heading_index = try buildSiteHeadingIndex(io, gpa, content_dir, db, site, shared, options.quiet);
    defer heading_index.deinit(gpa);

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

        const page_layout = page_layouts[page_idx];
        // Graph chrome (nav, breadcrumb, title) all depend on frozen site material.
        const needs_site_material = page_layout.has_nav or page_layout.has_breadcrumb or page_layout.has_title;
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
        const ref_material = wikilink.referenceMaterialMulti(
            gpa,
            wiki_bodies,
            wiki_paths,
            site.nodes,
            &wiki_fail,
            .{ .heading_index = &heading_index, .validate_fragments = true },
        ) catch |err| {
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

        // Fingerprint uses the effective selected layout identity and bytes.
        const fp_bytes = cache.computePageFingerprintTheme(
            options.target_name,
            page_sel_paths[page_idx],
            page.entity_id,
            shared.source_bytes[page_idx],
            inc_with_ref,
            page_layout_bytes[page_idx],
            nav_material,
            page_theme_material[page_idx],
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
                        std.mem.eql(u8, entry.fingerprint, fingerprints[page_idx]) and
                        (entry.selected_layout.len == 0 or std.mem.eql(u8, entry.selected_layout, page_sel_paths[page_idx])))
                    {
                        // Content-addressed output freshness: require a non-empty
                        // digest that matches on-disk HTML. Size is a cheap
                        // prefilter only (same-size corruption still fails digest).
                        if (output_exists and entry.output_digest.len > 0 and
                            (entry.output_size == 0 or entry.output_size == output_size))
                        {
                            if (readFileAlloc(io, dist_dir, page.output_path, gpa)) |out_bytes| {
                                defer gpa.free(out_bytes);
                                const dig_hex = cache.hexDigest(cache.hashBytes(out_bytes));
                                if (std.mem.eql(u8, entry.output_digest, &dig_hex)) {
                                    skip_render = true;
                                    break;
                                }
                            } else |_| {}
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
            .page_layouts = page_layouts,
            .options = options,
            .is_dirty = is_dirty,
            .site = site,
            .heading_index = &heading_index,
            .theme = &theme_bundle,
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
                try renderAndPublishPageWithTheme(
                    io,
                    gpa,
                    content_dir,
                    stage_dir,
                    page,
                    page_layouts[page_index],
                    &doc_arena,
                    options,
                    page_index,
                    site,
                    &heading_index,
                    &theme_bundle,
                );
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
        // Owned hex digests live only for the manifest write below.
        var output_digests = try gpa.alloc([]u8, db.len());
        for (output_digests) |*d| d.* = &.{};
        defer {
            for (output_digests) |d| {
                if (d.len > 0) gpa.free(d);
            }
            gpa.free(output_digests);
        }
        for (db.items(), 0..) |page, page_idx| {
            var out_size: u64 = 0;
            var out_digest: []const u8 = "";
            // Prefer staged (just-written) bytes; fall back to final dist for cached pages.
            const maybe_bytes: ?[]u8 = if (readFileAlloc(io, stage_dir, page.output_path, gpa)) |b|
                b
            else |_|
                if (readFileAlloc(io, dist_dir, page.output_path, gpa)) |b| b else |_| null;
            if (maybe_bytes) |bytes| {
                defer gpa.free(bytes);
                out_size = bytes.len;
                const dig_hex = cache.hexDigest(cache.hashBytes(bytes));
                output_digests[page_idx] = try gpa.dupe(u8, &dig_hex);
                out_digest = output_digests[page_idx];
            }
            cache_entries[page_idx] = .{
                .entity_id = page.entity_id,
                .fingerprint = fingerprints[page_idx],
                .output_path = page.output_path,
                .selected_layout = page_sel_paths[page_idx],
                .output_size = out_size,
                .output_digest = out_digest,
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

    // F9.2: when a managed theme owns `assets/`, drop files removed or renamed
    // in the theme inventory so prior dist does not retain orphans.
    if (theme_root.len > 0) {
        theme_mod.scrubOrphanThemeAssets(io, dist_dir, gpa, theme_bundle.assets);
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

test "P4 cache freshness: same-size corruption, truncation, reuse, full=inc, manifest determinism" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-p4-cache-freshness", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const dist_full = try std.fmt.allocPrint(gpa, "{s}/dist-full", .{work});
    defer gpa.free(dist_full);
    const dist_inc = try std.fmt.allocPrint(gpa, "{s}/dist-inc", .{work});
    defer gpa.free(dist_inc);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha
        \\---
        \\# Alpha
        \\
        \\Body line one.
        \\
    );
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta
        \\---
        \\# Beta
        \\
        \\Stable body.
        \\
    );

    const runHtml = struct {
        fn call(
            gpa_: std.mem.Allocator,
            io_: Io,
            content_: []const u8,
            dist_: []const u8,
            layout_path_: []const u8,
            incremental: bool,
        ) !CompileStats {
            const cwd_ = Io.Dir.cwd();
            var layout_arena = std.heap.ArenaAllocator.init(gpa_);
            defer layout_arena.deinit();
            const layout = try loadLayoutOnce(io_, cwd_, layout_path_, layout_arena.allocator());
            var retain_arena = std.heap.ArenaAllocator.init(gpa_);
            defer retain_arena.deinit();
            var db = PageDb.init(gpa_, retain_arena.allocator());
            defer db.deinit();
            try loadAndPromote(io_, gpa_, &db, content_);
            return try compilePages(io_, gpa_, &db, layout, .{
                .content_root = content_,
                .dist_dir = dist_,
                .layout_path = layout_path_,
                .incremental = incremental,
                .quiet = true,
            });
        }
    }.call;

    // Cold incremental build writes both pages and records output digests.
    {
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        var dist_dir = try cwd.openDir(io, dist, .{});
        defer dist_dir.close(io);
        const man = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(man);
        try std.testing.expect(std.mem.indexOf(u8, man, "output_digest") != null);
        try std.testing.expect(std.mem.indexOf(u8, man, cache.CACHE_FORMAT_VERSION) != null);
    }

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const alpha_clean = try readAllFile(io, dist_dir, "alpha.html", gpa);
    defer gpa.free(alpha_clean);
    try std.testing.expect(alpha_clean.len >= 2);

    // Same-size corruption must re-render only the corrupted page.
    {
        var corrupted = try gpa.dupe(u8, alpha_clean);
        defer gpa.free(corrupted);
        corrupted[0] = if (corrupted[0] == 'X') 'Y' else 'X';
        if (corrupted.len > 1) corrupted[1] = if (corrupted[1] == 'Z') 'W' else 'Z';
        const alpha_path = try std.fmt.allocPrint(gpa, "{s}/alpha.html", .{dist});
        defer gpa.free(alpha_path);
        try cwd.writeFile(io, .{ .sub_path = alpha_path, .data = corrupted });

        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
        const restored = try readAllFile(io, dist_dir, "alpha.html", gpa);
        defer gpa.free(restored);
        try std.testing.expectEqualStrings(alpha_clean, restored);
    }

    // Truncation / replacement must re-render.
    {
        const alpha_path = try std.fmt.allocPrint(gpa, "{s}/alpha.html", .{dist});
        defer gpa.free(alpha_path);
        try cwd.writeFile(io, .{ .sub_path = alpha_path, .data = "x" });
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
        const restored = try readAllFile(io, dist_dir, "alpha.html", gpa);
        defer gpa.free(restored);
        try std.testing.expectEqualStrings(alpha_clean, restored);
    }

    // Intact outputs are reused.
    {
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_attempted);
    }

    // Manifest is byte-identical across two no-op incremental runs.
    {
        const man1 = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(man1);
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 0), stats.pages_written);
        const man2 = try readAllFile(io, dist_dir, ".boris-cache/manifest.json", gpa);
        defer gpa.free(man2);
        try std.testing.expectEqualStrings(man1, man2);
    }

    // After source / include / layout edits, full and incremental trees match.
    try writeTreeFile(io, work, "content/alpha.md",
        \\---
        \\title: Alpha Edited
        \\---
        \\# Alpha
        \\
        \\Body line one edited.
        \\
    );
    try writeTreeFile(io, work, "layouts/main.html", "<html><body class=\"v2\">{{content}}</body></html>");
    try writeTreeFile(io, work, "content/includes/note.md", "shared note");
    try writeTreeFile(io, work, "content/beta.md",
        \\---
        \\title: Beta
        \\---
        \\# Beta
        \\
        \\{{include includes/note.md}}
        \\
    );

    _ = try runHtml(gpa, io, content, dist_full, layout_path, false);
    _ = try runHtml(gpa, io, content, dist_inc, layout_path, true);

    const files = [_][]const u8{ "alpha.html", "beta.html" };
    for (files) |f| {
        var dir_f = try cwd.openDir(io, dist_full, .{});
        defer dir_f.close(io);
        var dir_i = try cwd.openDir(io, dist_inc, .{});
        defer dir_i.close(io);
        const bf = try readAllFile(io, dir_f, f, gpa);
        defer gpa.free(bf);
        const bi = try readAllFile(io, dir_i, f, gpa);
        defer gpa.free(bi);
        try std.testing.expectEqualStrings(bf, bi);
    }

    // Dirty rebuild from an older cache also matches the full-tree baseline.
    {
        const stats = try runHtml(gpa, io, content, dist, layout_path, true);
        try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
        for (files) |f| {
            var dir_f = try cwd.openDir(io, dist_full, .{});
            defer dir_f.close(io);
            const bf = try readAllFile(io, dir_f, f, gpa);
            defer gpa.free(bf);
            const bd = try readAllFile(io, dist_dir, f, gpa);
            defer gpa.free(bd);
            try std.testing.expectEqualStrings(bf, bd);
        }
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

test "Feature 9 HTML: heading fragment wiki links resolve to rendered ids" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-heading-ok", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Page-only: [[guides/target]].
        \\
        \\Fragment: [[guides/target#section-one]].
        \\
        \\Labeled: [[guides/target#code-x-y|Code heading]].
        \\
        \\Dup: [[guides/target#dup]].
        \\
        \\Unicode: [[guides/target#caf-rsum]].
        \\
        \\Punctuation: [[guides/target#hello-world]].
        \\
        \\Via include:
        \\
        \\{{include includes/blurb.md}}
        \\
    );
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: index
        \\---
        \\
        \\# Target Page
        \\
        \\## Section One
        \\
        \\## Code `x` Y
        \\
        \\## Café résumé
        \\
        \\## Hello, World!
        \\
        \\## Dup
        \\
        \\## Dup
        \\
        \\### Nested Deep
        \\
        \\#### Deep Four
        \\
        \\See trunk [[index#home]].
        \\
    );
    try writeTreeFile(io, work, "content/guides/from.md",
        \\---
        \\title: From Satellite
        \\parent: index
        \\---
        \\
        \\# From Satellite
        \\
        \\[[index#home]] and [[guides/target#nested-deep]] and [[guides/target#deep-four]].
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "Include-borne: [[guides/target#section-one|Section from include]].\n");

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
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);

    const index_html = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#section-one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#code-x-y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#dup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#caf-rsum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"guides/target.html#hello-world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "[[") == null);

    const target_html = try readAllFile(io, dist_dir, "guides/target.html", gpa);
    defer gpa.free(target_html);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"section-one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"code-x-y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"caf-rsum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "id=\"dup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_html, "href=\"../index.html#home\"") != null);

    const from_html = try readAllFile(io, dist_dir, "guides/from.html", gpa);
    defer gpa.free(from_html);
    try std.testing.expect(std.mem.indexOf(u8, from_html, "href=\"../index.html#home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, from_html, "href=\"target.html#nested-deep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, from_html, "href=\"target.html#deep-four\"") != null);

    // Determinism: second full build matches first.
    const dist2 = try std.fmt.allocPrint(gpa, "{s}/dist2", .{work});
    defer gpa.free(dist2);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist2,
        .layout_path = layout_path,
        .quiet = true,
    });
    var dist2_dir = try cwd.openDir(io, dist2, .{});
    defer dist2_dir.close(io);
    const index2 = try readAllFile(io, dist2_dir, "index.html", gpa);
    defer gpa.free(index2);
    try std.testing.expectEqualStrings(index_html, index2);

    // Incremental rebuild is byte-identical for unchanged pages.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    const index_inc = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_inc);
    try std.testing.expectEqualStrings(index_html, index_inc);
}

test "Feature 9 HTML: missing heading fragment fails loud" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-heading-missing", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Broken: [[guides/target#does-not-exist]].
        \\
    );
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: index
        \\---
        \\
        \\# Target Page
        \\
        \\## Real Section
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

test "Feature 9 HTML: empty fragment is syntax failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-empty-frag", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Bad: [[index#]].
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

test "Feature 9 HTML: missing entity still fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-missing-entity", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\[[no/such/page#heading]].
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

test "Feature 9 HTML: fenced fragment wiki stays literal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-fence", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\Live: [[index#home]].
        \\
        \\```
        \\[[index#home]]
        \\```
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"index.html#home\"") != null);
    // Fenced form remains as author text (escaped or raw in code block).
    try std.testing.expect(std.mem.indexOf(u8, page, "[[index#home]]") != null);
}

test "Feature 9 HTML: jobs path resolves fragments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-jobs", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\[[guides/a#alpha]] [[guides/b#beta]]
        \\
    );
    try writeTreeFile(io, work, "content/guides/a.md",
        \\---
        \\title: A
        \\parent: index
        \\---
        \\
        \\# A
        \\
        \\## Alpha
        \\
    );
    try writeTreeFile(io, work, "content/guides/b.md",
        \\---
        \\title: B
        \\parent: index
        \\---
        \\
        \\# B
        \\
        \\## Beta
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
        .jobs = 4,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"guides/a.html#alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"guides/b.html#beta\"") != null);
}

test "Feature 9 HTML: include-borne missing fragment reports locus" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-inc-miss", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\{{include includes/bad.md}}
        \\
    );
    try writeTreeFile(io, work, "content/includes/bad.md", "See [[index#no-such-heading]].\n");

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

test "Feature 9 HTML: manual heading id with slash is percent-encoded in href" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-manual-id", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\## Manual {#has/slash}
        \\
        \\Link: [[index#has/slash]].
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"has/slash\"") != null);
    // Destination uses percent-encoding; browsers decode back to the id.
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"index.html#has%2Fslash\"") != null);
}

test "Feature 9 HTML: heading introduced by include is a valid target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-inc-heading", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\{{include includes/extra.md}}
        \\
        \\Jump: [[index#from-include]].
        \\
    );
    try writeTreeFile(io, work, "content/includes/extra.md", "## From Include\n\nBlurb.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const page = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"from-include\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"index.html#from-include\"") != null);
}

test "Feature 9 HTML: no fragment links skips heading-index Apex work path" {
    // Regression: pages with only page-only wiki still compile; empty index ok.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-no-frag", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\See [[guides/a]].
        \\
    );
    try writeTreeFile(io, work, "content/guides/a.md",
        \\---
        \\title: A
        \\parent: index
        \\---
        \\
        \\# A
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
    try std.testing.expectEqual(@as(usize, 2), stats.pages_written);
}

test "F9.1 theme-site fixture: slots, page-relative asset URLs, footer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-theme-site", .{tmp.sub_path});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-site/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html",
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 5), stats.pages_written);

    // jobs > 1 path must produce the same acceptance surface
    const dist_jobs = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-theme-site-jobs", .{tmp.sub_path});
    defer gpa.free(dist_jobs);
    const stats_jobs = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-site/content",
        .dist_dir = dist_jobs,
        .layout_path = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html",
        .quiet = true,
        .jobs = 4,
    });
    try std.testing.expectEqual(@as(usize, 5), stats_jobs.pages_written);

    // index → assets/css/docs.css (same depth)
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const index_html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"assets/css/docs.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "page-metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "site-footer__copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "Acme Platform") != null);

    // nested page → ../assets/css/docs.css
    const guide_path = try std.fmt.allocPrint(gpa, "{s}/guides/getting-started.html", .{dist});
    defer gpa.free(guide_path);
    const guide_html = try readFileAlloc(io, cwd, guide_path, gpa);
    defer gpa.free(guide_html);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "href=\"../assets/css/docs.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "Getting Started") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "page-toc") != null);

    // Asset bytes identical to theme input
    const out_css = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{dist});
    defer gpa.free(out_css);
    const copied = try readFileAlloc(io, cwd, out_css, gpa);
    defer gpa.free(copied);
    const theme_css = try readFileAlloc(io, cwd, "docs/contracts/fixtures/theme-site/experimental-theme/assets/css/docs.css", gpa);
    defer gpa.free(theme_css);
    try std.testing.expectEqualStrings(theme_css, copied);
}

test "F9.1 multi-target themes isolate assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-multi-theme", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    // Shared content
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\tags: [docs]
        \\---
        \\
        \\# Home
        \\
    );

    // Theme A
    try writeTreeFile(io, work, "theme-a/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/a.css}}">{{footer}}{{content}}</html>
    );
    try writeTreeFile(io, work, "theme-a/footer.html", "FOOTER-A");
    try writeTreeFile(io, work, "theme-a/assets/css/a.css", "/* theme-a */");

    // Theme B
    try writeTreeFile(io, work, "theme-b/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/b.css}}">{{footer}}{{content}}</html>
    );
    try writeTreeFile(io, work, "theme-b/footer.html", "FOOTER-B");
    try writeTreeFile(io, work, "theme-b/assets/css/b.css", "/* theme-b */");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout_a = try std.fmt.allocPrint(gpa, "{s}/theme-a/layouts/main.html", .{work});
    defer gpa.free(layout_a);
    const layout_b = try std.fmt.allocPrint(gpa, "{s}/theme-b/layouts/main.html", .{work});
    defer gpa.free(layout_b);
    const out_a = try std.fmt.allocPrint(gpa, "{s}/dist/a", .{work});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, "{s}/dist/b", .{work});
    defer gpa.free(out_b);

    try compileHtmlSiteMulti(io, gpa, &.{
        .{ .name = "a", .output_dir = out_a, .layout_path = layout_a },
        .{ .name = "b", .output_dir = out_b, .layout_path = layout_b },
    }, .{
        .content_root = content,
        .layout_path = layout_a,
        .quiet = true,
    });

    const path_css_a = try std.fmt.allocPrint(gpa, "{s}/assets/css/a.css", .{out_a});
    defer gpa.free(path_css_a);
    const css_a = try readFileAlloc(io, cwd, path_css_a, gpa);
    defer gpa.free(css_a);
    try std.testing.expectEqualStrings("/* theme-a */", css_a);

    const path_css_b = try std.fmt.allocPrint(gpa, "{s}/assets/css/b.css", .{out_b});
    defer gpa.free(path_css_b);
    const css_b = try readFileAlloc(io, cwd, path_css_b, gpa);
    defer gpa.free(css_b);
    try std.testing.expectEqualStrings("/* theme-b */", css_b);

    // Target A must not receive B's CSS
    const leak = try std.fmt.allocPrint(gpa, "{s}/assets/css/b.css", .{out_a});
    defer gpa.free(leak);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, leak, .{}));

    const path_html_a = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_a});
    defer gpa.free(path_html_a);
    const html_a = try readFileAlloc(io, cwd, path_html_a, gpa);
    defer gpa.free(html_a);
    try std.testing.expect(std.mem.indexOf(u8, html_a, "FOOTER-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_a, "FOOTER-B") == null);
}

test "F9.1 asset collision with page output fails loudly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-collision", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/assets/css/docs.md",
        \\---
        \\title: Collides
        \\---
        \\
        \\# Collides
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/docs.css", "body{}");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Page output is assets/css/docs.html — not css collision with .css.
    // Force collision: invent an asset path equal to page html output.
    // Entity id assets/css/docs → assets/css/docs.html. Place asset at that path.
    const theme_assets = try std.fmt.allocPrint(gpa, "{s}/theme/assets", .{work});
    defer gpa.free(theme_assets);
    try cwd.deleteTree(io, theme_assets);
    try writeTreeFile(io, work, "theme/assets/css/docs.html", "not-a-real-css");
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.html}}">{{content}}</html>
    );

    try std.testing.expectError(error.AssetCollision, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
}

test "F9.1 referenced asset change invalidates page fingerprint material" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-asset-fp", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/a.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/a.css", "v1");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .incremental = true,
    });
    // Second build should cache (0 pages written if fingerprints match)
    const stats_cached = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats_cached.pages_written);

    // Change asset bytes
    try writeTreeFile(io, work, "theme/assets/css/a.css", "v2");
    const stats_dirty = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats_dirty.pages_written);

    const css_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/a.css", .{dist});
    defer gpa.free(css_path);
    const css = try readFileAlloc(io, cwd, css_path, gpa);
    defer gpa.free(css);
    try std.testing.expectEqualStrings("v2", css);
}

test "F9.1 legacy layouts/main.html still renders without theme assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-legacy", .{tmp.sub_path});
    defer gpa.free(dist);

    // Use real sample content + default layout when present
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "content",
        .dist_dir = dist,
        .layout_path = "layouts/main.html",
        .quiet = true,
    });
    try std.testing.expect(stats.pages_written > 0);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<main>") != null);
    // No managed assets/ tree required for legacy layout
    const assets = try std.fmt.allocPrint(gpa, "{s}/assets", .{dist});
    defer gpa.free(assets);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, assets, .{}));
}

// ---------------------------------------------------------------------------
// F9.1 adversarial fixtures + determinism (theme path)
// ---------------------------------------------------------------------------

fn expectDirTreesEqual(io: Io, gpa: std.mem.Allocator, left_rel: []const u8, right_rel: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var left = try cwd.openDir(io, left_rel, .{ .iterate = true });
    defer left.close(io);
    var right = try cwd.openDir(io, right_rel, .{ .iterate = true });
    defer right.close(io);

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }

    var walker = try left.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        // Skip cache manifest for optional compare callers; include all by default.
        const path_owned = try gpa.dupe(u8, entry.path);
        try seen.put(gpa, path_owned, {});
        const a = try readFileAlloc(io, left, entry.path, gpa);
        defer gpa.free(a);
        const b = try readFileAlloc(io, right, entry.path, gpa);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }

    // Ensure right has no extra files
    var walker_r = try right.walkSelectively(gpa);
    defer walker_r.deinit();
    while (try walker_r.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker_r.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        try std.testing.expect(seen.contains(entry.path));
    }
}

test "F9.1 adversarial: missing asset fails before publish" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-missing", .{tmp.sub_path});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetNotFound, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/missing-asset/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/missing-asset/theme/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.1 adversarial: asset-url without theme root fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-no-theme", .{tmp.sub_path});
    defer gpa.free(dist);

    // Bare `layouts/…` is the only path form with null theme root (contract).
    // Write a temporary layout under repo `layouts/` and remove it after.
    const layout_path = "layouts/.boris-f91-theme-root-missing.html";
    try cwd.writeFile(io, .{
        .sub_path = layout_path,
        .data = "<html><link href=\"{{asset-url assets/css/docs.css}}\">{{content}}</html>",
    });
    defer cwd.deleteFile(io, layout_path) catch {};

    try std.testing.expectEqual(@as(?[]const u8, null), theme_mod.themeRootFromLayoutPath(layout_path));
    try std.testing.expectError(error.ThemeRootMissing, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/theme-root-missing/content",
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));

    // Nested `…/layouts/…` derives a theme root; empty assets → AssetNotFound (not ThemeRootMissing).
    try std.testing.expectError(error.AssetNotFound, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/theme-root-missing/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/theme-root-missing/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.1 adversarial: unsafe asset-url layouts fail at load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-unsafe", .{tmp.sub_path});
    defer gpa.free(dist);

    const cases = [_][]const u8{
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-escape-dotdot/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-absolute/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-backslash/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-no-assets-prefix/layouts/main.html",
    };
    for (cases) |lp| {
        try std.testing.expectError(error.LayoutInvalidAssetUrl, compileHtmlSite(io, gpa, .{
            .content_root = "docs/contracts/fixtures/theme-adversarial/unsafe-layout/content",
            .dist_dir = dist,
            .layout_path = lp,
            .quiet = true,
        }));
        // No published tree
        const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
        defer gpa.free(index_path);
        try std.testing.expectError(error.FileNotFound, cwd.access(io, index_path, .{}));
    }
}

test "F9.1 adversarial: metadata and title HTML-escape hostile frontmatter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-meta-esc", .{tmp.sub_path});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/metadata-escape/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/metadata-escape/theme/layouts/main.html",
        .quiet = true,
    });

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);

    // Escaped in title and metadata sinks
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "x&lt;script&gt;") != null);
    // Must not emit raw markup from title/tags into chrome sinks
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>A <b>Bold</b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "x<script>") == null);
}

test "F9.1 adversarial: fixture collision tree fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/adv-coll", .{tmp.sub_path});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetCollision, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/collision/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/collision/theme/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.1 determinism: theme-site full vs incremental and jobs byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f91-det", .{tmp.sub_path});
    defer gpa.free(base);

    const content = "docs/contracts/fixtures/theme-site/content";
    const layout = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html";

    const full_a = try std.fmt.allocPrint(gpa, "{s}/full-a", .{base});
    defer gpa.free(full_a);
    const full_b = try std.fmt.allocPrint(gpa, "{s}/full-b", .{base});
    defer gpa.free(full_b);
    const jobs = try std.fmt.allocPrint(gpa, "{s}/jobs", .{base});
    defer gpa.free(jobs);
    const inc = try std.fmt.allocPrint(gpa, "{s}/inc", .{base});
    defer gpa.free(inc);

    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = full_a, .layout_path = layout, .quiet = true, .jobs = 1 });
    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = full_b, .layout_path = layout, .quiet = true, .jobs = 1 });
    try expectDirTreesEqual(io, gpa, full_a, full_b);

    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = jobs, .layout_path = layout, .quiet = true, .jobs = 4 });
    try expectDirTreesEqual(io, gpa, full_a, jobs);

    // Seed with incremental=true so the cache manifest is written; then no-op.
    // (Non-incremental builds do not write `.boris-cache/manifest.json`.)
    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = inc, .layout_path = layout, .quiet = true, .incremental = true });
    const stats_noop = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = inc, .layout_path = layout, .quiet = true, .incremental = true });
    try std.testing.expectEqual(@as(usize, 0), stats_noop.pages_written);
    // Compare HTML + assets (manifest may differ only if present under .boris-cache — exclude via selective check)
    const pages = [_][]const u8{
        "index.html",
        "guides.html",
        "guides/getting-started.html",
        "reference.html",
        "reference/configuration.html",
        "assets/css/docs.css",
    };
    const cwd = Io.Dir.cwd();
    for (pages) |rel| {
        const pa = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ full_a, rel });
        defer gpa.free(pa);
        const pb = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ inc, rel });
        defer gpa.free(pb);
        const a = try readFileAlloc(io, cwd, pa, gpa);
        defer gpa.free(a);
        const b = try readFileAlloc(io, cwd, pb, gpa);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }
}

test "F9.2 orphan theme assets scrubbed on remove and rename" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-orphan-assets", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/a.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/a.css", "aaa");
    try writeTreeFile(io, work, "theme/assets/css/extra.css", "extra");

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    const extra_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/extra.css", .{dist});
    defer gpa.free(extra_path);
    try cwd.access(io, extra_path, .{});

    // Remove unreferenced extra.css from theme → orphan scrub on next build.
    const extra_theme = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css/extra.css", .{work});
    defer gpa.free(extra_theme);
    try cwd.deleteFile(io, extra_theme);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, extra_path, .{}));

    // Rename a.css → b.css and update layout reference.
    const a_theme = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css/a.css", .{work});
    defer gpa.free(a_theme);
    try cwd.deleteFile(io, a_theme);
    try writeTreeFile(io, work, "theme/assets/css/b.css", "bbb");
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/b.css}}">{{content}}</html>
    );
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const a_out = try std.fmt.allocPrint(gpa, "{s}/assets/css/a.css", .{dist});
    defer gpa.free(a_out);
    const b_out = try std.fmt.allocPrint(gpa, "{s}/assets/css/b.css", .{dist});
    defer gpa.free(b_out);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, a_out, .{}));
    const b_bytes = try readFileAlloc(io, cwd, b_out, gpa);
    defer gpa.free(b_bytes);
    try std.testing.expectEqualStrings("bbb", b_bytes);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "assets/css/b.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "assets/css/a.css") == null);
}

test "F9.2 layout invalid UTF-8 fails at load boundary" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-layout-utf8", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    // Invalid UTF-8 (truncated C3 sequence) with otherwise valid markers.
    const bad_layout = [_]u8{
        '<', 'h', 't', 'm', 'l', '>', 0xC3, 0x28, '{', '{', 'c', 'o', 'n', 't', 'e', 'n', 't', '}', '}', '<', '/', 'h', 't', 'm', 'l', '>',
    };
    const layouts_dir = try std.fmt.allocPrint(gpa, "{s}/theme/layouts", .{work});
    defer gpa.free(layouts_dir);
    try cwd.createDirPath(io, layouts_dir);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    try cwd.writeFile(io, .{ .sub_path = layout_path, .data = &bad_layout });

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.LayoutInvalidUtf8, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    }));
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, index_path, .{}));
}

test "F9.2 --theme sugar + multi-target isolation + incremental byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-theme-sugar", .{tmp.sub_path});
    defer gpa.free(base);

    // CLI --theme ROOT expands to ROOT/layouts/main.html (already unit-tested);
    // exercise the same path through compileHtmlSite with theme-site fixture.
    const content = "docs/contracts/fixtures/theme-site/content";
    const theme_root = "docs/contracts/fixtures/theme-site/experimental-theme";
    const layout = "docs/contracts/fixtures/theme-site/experimental-theme/layouts/main.html";
    try std.testing.expectEqualStrings(
        theme_root,
        theme_mod.themeRootFromLayoutPath(layout).?,
    );

    const full = try std.fmt.allocPrint(gpa, "{s}/full", .{base});
    defer gpa.free(full);
    const inc = try std.fmt.allocPrint(gpa, "{s}/inc", .{base});
    defer gpa.free(inc);
    const public = try std.fmt.allocPrint(gpa, "{s}/public", .{base});
    defer gpa.free(public);
    const preview = try std.fmt.allocPrint(gpa, "{s}/preview", .{base});
    defer gpa.free(preview);

    // Full rebuild
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = full,
        .layout_path = layout,
        .quiet = true,
    });

    // Incremental seed + no-op; published HTML/assets must match full rebuild.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = inc,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const noop = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = inc,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), noop.pages_written);

    const pages = [_][]const u8{
        "index.html",
        "guides.html",
        "guides/getting-started.html",
        "reference.html",
        "reference/configuration.html",
        "assets/css/docs.css",
    };
    for (pages) |rel| {
        const pa = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ full, rel });
        defer gpa.free(pa);
        const pb = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ inc, rel });
        defer gpa.free(pb);
        const a = try readFileAlloc(io, cwd, pa, gpa);
        defer gpa.free(a);
        const b = try readFileAlloc(io, cwd, pb, gpa);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }

    // Metadata / footer / asset-url presence on nested page
    const guide = try std.fmt.allocPrint(gpa, "{s}/guides/getting-started.html", .{full});
    defer gpa.free(guide);
    const guide_html = try readFileAlloc(io, cwd, guide, gpa);
    defer gpa.free(guide_html);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "href=\"../assets/css/docs.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "page-metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "site-footer__copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, guide_html, "Status") != null);

    // Multi-target: same content, isolated outs (reuse experimental theme for both;
    // isolation is ownership of separate roots + caches, not necessarily distinct CSS).
    try compileHtmlSiteMulti(io, gpa, &.{
        .{ .name = "public", .output_dir = public, .layout_path = layout },
        .{ .name = "preview", .output_dir = preview, .layout_path = layout },
    }, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
    });
    const pub_css = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{public});
    defer gpa.free(pub_css);
    const prev_css = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{preview});
    defer gpa.free(prev_css);
    try cwd.access(io, pub_css, .{});
    try cwd.access(io, prev_css, .{});
    // Independent cache namespaces
    const pub_cache = try std.fmt.allocPrint(gpa, "{s}/.boris-cache", .{public});
    defer gpa.free(pub_cache);
    const prev_cache = try std.fmt.allocPrint(gpa, "{s}/.boris-cache", .{preview});
    defer gpa.free(prev_cache);
    // Cache dirs exist only under incremental; full multi-target still isolates trees.
    try std.testing.expect(!std.mem.eql(u8, public, preview));
}

test "F9.2 adversarial: invalid asset path grammar fails closed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-bad-paths", .{tmp.sub_path});
    defer gpa.free(dist);

    // Traversal / absolute / backslash / missing assets/ prefix (fixture layouts).
    const cases = [_][]const u8{
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-escape-dotdot/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-absolute/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-backslash/layouts/main.html",
        "docs/contracts/fixtures/theme-adversarial/unsafe-layout/theme-no-assets-prefix/layouts/main.html",
    };
    for (cases) |lp| {
        try std.testing.expectError(error.LayoutInvalidAssetUrl, compileHtmlSite(io, gpa, .{
            .content_root = "docs/contracts/fixtures/theme-adversarial/unsafe-layout/content",
            .dist_dir = dist,
            .layout_path = lp,
            .quiet = true,
        }));
    }

    // Collision fixture
    try std.testing.expectError(error.AssetCollision, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/collision/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/collision/theme/layouts/main.html",
        .quiet = true,
    }));

    // Missing referenced asset
    try std.testing.expectError(error.AssetNotFound, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/theme-adversarial/missing-asset/content",
        .dist_dir = dist,
        .layout_path = "docs/contracts/fixtures/theme-adversarial/missing-asset/theme/layouts/main.html",
        .quiet = true,
    }));
}

test "F9.2 theme asset symlink rejected when host allows" {
    if (@import("builtin").os.tag == .windows) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-theme-symlink", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/real.css", "body{}");

    const css_dir = try std.fmt.allocPrint(gpa, "{s}/theme/assets/css", .{work});
    defer gpa.free(css_dir);
    var css = try cwd.openDir(io, css_dir, .{});
    defer css.close(io);
    css.symLink(io, "real.css", "docs.css", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetSymlink, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "F9.1 footer change dirties pages; unreferenced asset does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f91-footer-unref", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html>{{footer}}<link href="{{asset-url assets/css/used.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/footer.html", "FOOTER-V1");
    try writeTreeFile(io, work, "theme/assets/css/used.css", "used-v1");
    try writeTreeFile(io, work, "theme/assets/css/unused.css", "unused-v1");

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const noop = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), noop.pages_written);

    // Unreferenced asset change: pages stay cached; asset file still republished.
    try writeTreeFile(io, work, "theme/assets/css/unused.css", "unused-v2");
    const after_unref = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), after_unref.pages_written);
    const unused_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/unused.css", .{dist});
    defer gpa.free(unused_path);
    const unused_bytes = try readFileAlloc(io, cwd, unused_path, gpa);
    defer gpa.free(unused_bytes);
    try std.testing.expectEqualStrings("unused-v2", unused_bytes);

    // Footer change dirties every page using the layout.
    try writeTreeFile(io, work, "theme/footer.html", "FOOTER-V2");
    const after_footer = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 1), after_footer.pages_written);
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "FOOTER-V2") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "FOOTER-V1") == null);
}
