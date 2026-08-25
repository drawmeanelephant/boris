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
//!    source buffers, parser views, rendered HTML, or writer buffers.
//! 2. **Whiteboard** — per-page `std.heap.ArenaAllocator`. Source bytes, parse
//!    scratch, and rendered HTML live only here.
//! 3. After each page (success **or** error): `arena.reset(.free_all)`, but
//!    **only after**:
//!    - Oliver has returned;
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
const render = @import("render.zig");
const assemble = @import("assemble.zig");
const scanner = @import("scanner.zig");
const identity = @import("identity.zig");
const cache = @import("cache.zig");
const dependency = @import("dependency.zig");
const target_mod = @import("target.zig");
const graph_mod = @import("graph.zig");
const diag = @import("diag.zig");
const html_nav = @import("html_nav.zig");
const html_relations = @import("html_relations.zig");
const html_toc = @import("html_toc.zig");
const html_body = @import("html_body.zig");
const include_mod = @import("include.zig");
const wikilink = @import("wikilink.zig");
const doclink = @import("doclink.zig");
const json_out = @import("json_out.zig");
const pipeline = @import("pipeline.zig");
const theme_mod = @import("theme.zig");
const layout_select = @import("layout_select.zig");
const textile = @import("textile.zig");
const cooklang_seam = @import("cooklang_seam.zig");
const content_asset = @import("content_asset.zig");
const source_io = @import("source_io.zig");
const source_provider = @import("source_provider.zig");
const artifact_sink = @import("artifact_sink.zig");
const search_index = @import("search_index.zig");
const site_url = @import("site_url.zig");
const github_pages = @import("github_pages.zig");
const sitemap = @import("sitemap.zig");
const standard_site = @import("standard_site.zig");
const standard_site_emit = @import("standard_site_emit.zig");
const nostr_emit = @import("nostr_emit.zig");
const link_audit = @import("link_audit.zig");
const publication_location = @import("publication_location.zig");
const artifact_inventory = @import("artifact_inventory.zig");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");
const publication_evidence_state = @import("publication_evidence_state.zig");
const publication_proof_pack = @import("publication_proof_pack.zig");
const timings = @import("timings.zig");
const compile_stage = @import("compile_stage.zig");
const compile_cache = @import("compile_cache.zig");
const compile_heading = @import("compile_heading.zig");

pub const PageDb = page_mod.PageDb;
pub const DurablePage = page_mod.DurablePage;

/// Long-lived frozen graph + nav for one HTML site compile (Feature 6).
/// Nodes view retain-owned PageDb strings; edges/nav owned by `gpa`.
pub const FrozenSite = struct {
    gpa: std.mem.Allocator,
    nodes: []graph_mod.Node,
    edges: []graph_mod.Edge,
    nav: []graph_mod.NavEntry,
    /// Site-nav fingerprint digest (GPA-owned): the fixed-size SHA-256 of the
    /// raw `(id, title, parent, role)` material, computed once per build
    /// (#727) so graph-chrome pages hash 32 bytes instead of O(pages) bytes.
    /// Empty when layout has no graph chrome.
    site_nav_digest: []const u8 = "",

    pub fn deinit(self: *FrozenSite) void {
        if (self.site_nav_digest.len > 0) self.gpa.free(self.site_nav_digest);
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

fn writePublicationChecksFailure(
    writer: *Io.Writer,
    target_name: []const u8,
    err: anyerror,
) !void {
    try writer.print(
        "error: publication committed for target '{s}', but publication-check evidence was not refreshed: {s}\n",
        .{ target_name, @errorName(err) },
    );
}

fn writePublicationClaimsFailure(
    writer: *Io.Writer,
    target_name: []const u8,
    err: anyerror,
) !void {
    try writer.print(
        "error: publication committed for target '{s}', but publication-claims evidence was not refreshed: {s}\n",
        .{ target_name, @errorName(err) },
    );
}

fn writePublicationTouchesFailure(
    writer: *Io.Writer,
    target_name: []const u8,
    err: anyerror,
) !void {
    try writer.print(
        "error: publication committed for target '{s}', but the Touch Atlas was not refreshed: {s}\n",
        .{ target_name, @errorName(err) },
    );
}

fn writePublicationProofPackFailure(
    writer: *Io.Writer,
    target_name: []const u8,
    err: anyerror,
) !void {
    // A rollback that fails either to restore a preserved file or to remove a
    // newly installed file leaves the current pair possibly split or absent,
    // so both restore and remove errors classify as recovery failed.
    const name = @errorName(err);
    const recovery_failed = std.mem.eql(u8, name, "RestoreHtmlFailed") or
        std.mem.eql(u8, name, "RestoreJsonFailed") or
        std.mem.eql(u8, name, "RemoveHtmlFailed") or
        std.mem.eql(u8, name, "RemoveJsonFailed");
    if (recovery_failed) {
        try writer.print(
            "error: publication committed for target '{s}', but Proof Pack presentation recovery failed; the current pair may be split or absent: {s}\n",
            .{ target_name, @errorName(err) },
        );
    } else {
        try writer.print(
            "error: publication committed for target '{s}', but Proof Pack presentation was not refreshed: {s}\n",
            .{ target_name, @errorName(err) },
        );
    }
}

/// Build graph nodes from PageDb, validate, freeze, and buildNav.
/// On graph errors returns `error.GraphValidationFailed` after printing diags
/// when `quiet` is false.
pub fn freezeSiteFromPageDb(
    gpa: std.mem.Allocator,
    db: *PageDb,
    quiet: bool,
    include_nav_material: bool,
    recorder: ?*timings.Recorder,
    sink: ?*diag.Collector,
) !FrozenSite {
    if (recorder) |t| t.start(.graph_validate);
    const pages = db.items();
    const nodes = try gpa.alloc(graph_mod.Node, pages.len);
    errdefer gpa.free(nodes);

    for (pages, 0..) |p, i| {
        nodes[i] = .{
            .id = p.entity_id,
            .source_path = p.source_path,
            .id_explicit = p.id_explicit,
            .output_path = p.output_path,
            .title = p.title,
            .parent = p.parent,
            .status = if (p.status) |s| s.name() else null,
            .tags = p.tags,
            .body_offset = p.body_offset,
            .semantic_relations = p.relations,
        };
    }

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    // Diagnostic message/remediation strings live on a short-lived arena.
    var diag_arena = std.heap.ArenaAllocator.init(gpa);
    defer diag_arena.deinit();
    try graph_mod.validate(gpa, diag_arena.allocator(), nodes, &diags);
    if (diag.countErrors(diags.items) == 0) {
        try graph_mod.validateSemanticRelations(gpa, diag_arena.allocator(), nodes, &diags);
    }
    diag.sortDiagnostics(diags.items);
    if (diag.countErrors(diags.items) > 0) {
        // Errors always reach stderr. `--quiet` suppresses progress, success
        // output, and sub-error diagnostics — never the explanation for a
        // nonzero exit.
        if (sink) |s| for (diags.items) |d| s.append(d);
        for (diags.items) |d| {
            if (quiet and d.severity != .error_) continue;
            diag.printText(d, gpa);
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

    var site_nav_digest: []const u8 = "";
    if (include_nav_material) {
        const material = try html_nav.siteNavMaterial(gpa, g.nodes);
        defer gpa.free(material);
        const digest = try gpa.alloc(u8, cache.hashBytes(material).len);
        @memcpy(digest, &cache.hashBytes(material));
        site_nav_digest = digest;
    }
    if (recorder) |t| t.stop(.graph_validate);

    return .{
        .gpa = gpa,
        .nodes = g.nodes,
        .edges = g.edges,
        .nav = nav,
        .site_nav_digest = site_nav_digest,
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
    layout_path: []const u8 = "themes/boris/layouts/main.html",
    /// Target-owned layout rules (`--layout-rule`). Empty → one layout for all pages.
    layout_rules: []const layout_select.LayoutRule = &.{},
    quiet: bool = true,
    /// Run the canonical HTML prepublication phases and return before creating
    /// an output/staging tree. Product callers should use
    /// `validateHtmlSiteMulti` rather than setting this directly.
    validation_only: bool = false,
    /// When set, force a render failure after promoting page `N` (0-based)
    /// without publishing — used to prove error-path Whiteboard reset + no
    /// final file. Production callers leave this `null`.
    test_fail_render_at: ?usize = null,
    /// When set, inject `assemble` publish failure for page `N` after a prior
    /// successful write of that path (caller should seed the final first).
    test_fail_publish_at: ?usize = null,
    /// Opt-in to fast incremental rendering.
    incremental: bool = false,
    /// Force full publication-evidence re-derivation even when the committed
    /// artifact set is byte-identical to what on-disk evidence describes (#728).
    refresh_evidence: bool = false,
    /// When set, inject failure before publishing cache manifest to test rollback.
    test_fail_cache_publish: bool = false,
    /// Bounded parallel rendering worker count.
    jobs: usize = 1,
    /// Optional thread-safe collector for the HTML-path diagnostics report
    /// (`build`/`validate --report PATH`). When set, every HTML-path
    /// diagnostic is appended here in addition to the existing stderr text.
    /// Safe under the bounded parallel renderer (`jobs > 1`).
    diagnostics: ?*diag.Collector = null,
    /// Whole-tree authoring format. Markdown is the byte-compatible default.
    input_format: identity.InputFormat = .markdown,
    /// When set, page/include/layout reads go through this provider.
    sources: ?source_provider.Provider = null,
    /// When set, HTML pages are emitted here instead of a host `dist_dir`.
    sink: ?artifact_sink.Sink = null,
    /// Oliver serialization profile for this target's page bodies (#448).
    /// `.html` is the byte-identical default; `.xhtml` fails closed on
    /// verbatim raw HTML. The XHTML *document* wrapper (XML declaration +
    /// `xmlns`) is the layout template's responsibility.
    output_profile: render.OutputProfile = .html,
    /// Target-root-relative sitemap output path; null disables the projection.
    sitemap_path: ?[]const u8 = null,
    /// Strict public HTTP(S) base URL, required when `sitemap_path` is set.
    site_url: ?[]const u8 = null,
    /// Normalized publication identity used to audit Pages base paths and
    /// public metadata. The caller owns the pointed-to location.
    publication_location: ?*const publication_location.Location = null,
    /// Opt-in Standard.site verification emission (#475). When set, eligible
    /// pages emit deterministic `site.standard.document` head links into the
    /// compiler-owned `{{head}}` slot, the well-known file is emitted (or
    /// recorded as `limited` for base-path sites), and a verification report
    /// distinguishes `emitted`, `limited`, and `not verified`. The caller
    /// owns the pointed-to projection and surfaces, which must outlive the
    /// compile run.
    standard_site_verification: ?*const standard_site_emit.VerificationContext = null,
    /// Opt-in Nostr `nostr:naddr` alternate links (#571). When set, eligible
    /// allowlisted pages emit one link into the compiler-owned `{{head}}`
    /// slot. The caller owns the pointed-to config for the compile run.
    nostr_head: ?*const nostr_emit.HeadConfig = null,
    /// Allow the output link audit to accept literal `.md`/`.mdx` hrefs that the
    /// pre-render rewriter deliberately leaves in place (see
    /// docs/contracts/documentation-links.md). Off by default; suppresses only
    /// EROUTEMISSING for those extensions, never EROUTEESCAPE.
    allow_markdown_literals: bool = false,
    /// Test-only failure after sitemap staging and before target commit.
    test_fail_after_sitemap_stage: bool = false,
    /// Test-only failure before the artifact inventory writer runs.
    test_fail_before_inventory_write: bool = false,
    /// Test-only post-commit checker execution failure. Production callers
    /// leave both publication-check fault injections false.
    test_fail_publication_checks: bool = false,
    /// Test-only atomic checks-report write failure.
    test_fail_publication_checks_write: bool = false,
    /// Test-only post-checks claims derivation failure. Production callers
    /// leave both publication-claims fault injections false.
    test_fail_publication_claims: bool = false,
    /// Test-only atomic claims-report write failure.
    test_fail_publication_claims_write: bool = false,
    /// Test-only capture: when set, the post-commit claims diagnostic is
    /// written here instead of the process stderr, so tests can assert the
    /// line is emitted even under `--quiet`.
    publication_claims_failure_writer: ?*Io.Writer = null,
    /// Test-only post-claims Touch Atlas derivation failure. Production
    /// callers leave both publication-touches fault injections false.
    test_fail_publication_touches: bool = false,
    /// Test-only atomic touches-report write failure.
    test_fail_publication_touches_write: bool = false,
    /// Test-only capture: when set, the post-commit Touch Atlas diagnostic
    /// is written here instead of the process stderr, so tests can assert the
    /// line is emitted even under `--quiet`.
    publication_touches_failure_writer: ?*Io.Writer = null,
    /// Test-only post-touches Proof Pack derivation failure. Production
    /// callers leave every publication-proof-pack fault injection false.
    test_fail_publication_proof_pack: bool = false,
    /// Test-only Proof Pack JSON temporary write failure.
    test_fail_proof_pack_json_tmp_write: bool = false,
    /// Test-only Proof Pack HTML temporary write failure.
    test_fail_proof_pack_html_tmp_write: bool = false,
    /// Test-only Proof Pack prior-pair preservation failure.
    test_fail_proof_pack_preserve_prior: bool = false,
    /// Test-only Proof Pack HTML install failure.
    test_fail_proof_pack_install_html: bool = false,
    /// Test-only Proof Pack JSON install failure.
    test_fail_proof_pack_install_json: bool = false,
    /// Test-only Proof Pack HTML restore failure.
    test_fail_proof_pack_restore_html: bool = false,
    /// Test-only Proof Pack JSON restore failure.
    test_fail_proof_pack_restore_json: bool = false,
    /// Test-only capture: when set, the post-commit Proof Pack diagnostic
    /// is written here instead of the process stderr, so tests can assert the
    /// line is emitted even under `--quiet`.
    publication_proof_pack_failure_writer: ?*Io.Writer = null,
    /// Opt-in phase timing/counter recorder (`--timings`); null by default.
    timings: ?*timings.Recorder = null,
};

fn validateSitemapConfig(gpa: std.mem.Allocator, options: CompileOptions) !void {
    if (options.publication_location) |location| {
        if (options.site_url) |raw_url| {
            publication_location.validateSiteUrl(gpa, location, raw_url) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.PublicationLocationMismatch,
            };
        }
    }
    if (options.sitemap_path) |path| {
        try sitemap.validateOutputPath(path);
        const raw_url = options.site_url orelse return error.SitemapSiteUrlRequired;
        const normalized = try site_url.normalized(gpa, raw_url);
        gpa.free(normalized);
    } else if (options.site_url != null) {
        return error.SitemapSiteUrlWithoutOutput;
    }
}

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
        error.InvalidNavMarker => return error.LayoutInvalidNavMarker,
        error.TooManyLayoutSegments => return error.LayoutTooManySegments,
        error.InvalidAssetUrl => return error.LayoutInvalidAssetUrl,
        error.TooManyAssetUrls => return error.LayoutTooManyAssetUrls,
        error.InvalidUtf8 => return error.LayoutInvalidUtf8,
        else => |e| return e,
    };
}

fn loadLayoutForOptions(
    io: Io,
    dir: Io.Dir,
    options: CompileOptions,
    layout_arena: std.mem.Allocator,
) !assemble.Layout {
    if (options.sources) |sources| {
        const raw = try sources.readPage(options.layout_path, layout_arena);
        return assemble.loadLayoutFromBytes(raw) catch |err| switch (err) {
            error.MissingContentMarker => return error.LayoutMissingMarker,
            error.DuplicateContentMarker => return error.LayoutDuplicateMarker,
            error.DuplicateLayoutMarker => return error.LayoutDuplicateMarker,
            error.UnknownLayoutMarker => return error.LayoutUnknownMarker,
            error.InvalidNavMarker => return error.LayoutInvalidNavMarker,
            error.TooManyLayoutSegments => return error.LayoutTooManySegments,
            error.InvalidAssetUrl => return error.LayoutInvalidAssetUrl,
            error.TooManyAssetUrls => return error.LayoutTooManyAssetUrls,
            error.InvalidUtf8 => return error.LayoutInvalidUtf8,
            else => |e| return e,
        };
    }
    return loadLayoutOnce(io, dir, options.layout_path, layout_arena);
}

/// Sequential HTML compile into an artifact sink. Single-threaded; no staging
/// directory, incremental cache, sitemap, or --jobs.
pub fn compileHtmlToSink(
    io: Io,
    gpa: std.mem.Allocator,
    options: CompileOptions,
) !CompileStats {
    const sources = options.sources orelse return error.MissingSourceProvider;
    const sink = options.sink orelse return error.MissingArtifactSink;
    if (options.jobs != 1) return error.EmbedJobsUnsupported;

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutForOptions(io, Io.Dir.cwd(), options, layout_arena.allocator());

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromoteFromProvider(io, gpa, &db, sources, options.input_format, options.timings);

    var site = try freezeSiteFromPageDb(
        gpa,
        &db,
        options.quiet,
        layout.has_nav or layout.has_breadcrumb or layout.has_title or layout.has_children or layout.has_relations or layout.has_backlinks or options.layout_rules.len != 0,
        options.timings,
        options.diagnostics,
    );
    defer site.deinit();

    var stats: CompileStats = .{};
    const dummy_dir: Io.Dir = .{ .handle = 0 };
    for (db.items(), 0..) |*page, page_index| {
        var doc_arena = std.heap.ArenaAllocator.init(gpa);
        defer doc_arena.deinit();
        const slots = try renderPageSlots(
            io,
            gpa,
            dummy_dir,
            page,
            layout,
            &doc_arena,
            options,
            page_index,
            .{ .site = &site },
        );
        const html = try assemble.renderPageAlloc(gpa, layout, slots);
        defer gpa.free(html);
        try sink.emit(page.output_path, "text/html; charset=utf-8", html);
        stats.pages_written += 1;
        stats.pages_attempted += 1;
    }
    if (sources == .memory) {
        const mem = sources.memory;
        for (mem.paths, mem.bytes) |path, bytes| {
            if (!source_provider.isUnderAssetsTree(path) and !isThemeAssetPath(path)) continue;
            try sink.emit(path, mediaTypeForPath(path), bytes);
        }
    }
    return stats;
}

fn isThemeAssetPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/assets/") != null or std.mem.startsWith(u8, path, "assets/");
}

fn mediaTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript";
    return "application/octet-stream";
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

/// Cache-key material identifying which body adapter produced a page's
/// Markdown. Empty for Markdown input so existing fingerprints do not move.
fn adapterIdentity(input_format: identity.InputFormat) []const u8 {
    return switch (input_format) {
        .markdown => "",
        .textile => textile.adapter_identity,
        .cook => cooklang_seam.adapter_identity,
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
    return loadAndPromoteFormat(io, gpa, db, content_root, .markdown, null);
}

pub fn loadAndPromoteFormat(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    content_root: []const u8,
    input_format: identity.InputFormat,
    recorder: ?*timings.Recorder,
) !void {
    var scan_list = page_mod.PageList.init(gpa, db.retain);
    defer scan_list.deinit();

    if (recorder) |t| t.start(.scan);
    scanner.scan(io, .{ .content_root = content_root, .input_format = input_format }, &scan_list) catch |err| switch (err) {
        error.ContentDirMissing => return error.ContentDirMissing,
        error.InputFormatMismatch => {
            if (!diag.text_suppressed.load(.unordered)) {
                // Name the offending family so the fix (--cooklang /
                // --textile) is visible without trial and error (#744); the
                // code follows the offending family per
                // docs/contracts/scanner.md. Falls back to the requested-mode
                // wording when the tree cannot be re-probed.
                const offender: ?identity.ContentKind = blk: {
                    const root_dir = Io.Dir.cwd().openDir(io, content_root, .{ .iterate = true }) catch break :blk null;
                    defer root_dir.close(io);
                    break :blk scanner.probeForeignFamily(io, root_dir, input_format);
                };
                const guidance = scanner.modeMismatchGuidance(input_format, offender);
                std.debug.print("error: {s}: {s} [{s}]\n", .{ guidance.code.name(), guidance.message, guidance.remediation });
            }
            return error.InputFormatMismatch;
        },
        else => |e| return e,
    };

    if (recorder) |t| t.stop(.scan);

    return promoteScannedPages(io, gpa, db, content_root, input_format, recorder, &scan_list, null);
}

fn loadAndPromoteFromProvider(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    sources: source_provider.Provider,
    input_format: identity.InputFormat,
    recorder: ?*timings.Recorder,
) !void {
    var scan_list = page_mod.PageList.init(gpa, db.retain);
    defer scan_list.deinit();
    if (recorder) |t| t.start(.scan);
    try sources.scan(&scan_list);
    if (recorder) |t| t.stop(.scan);
    return promoteScannedPages(io, gpa, db, "", input_format, recorder, &scan_list, sources);
}

fn promoteScannedPages(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    content_root: []const u8,
    input_format: identity.InputFormat,
    recorder: ?*timings.Recorder,
    scan_list: *page_mod.PageList,
    sources: ?source_provider.Provider,
) !void {
    const cwd = Io.Dir.cwd();
    var opened_dir: ?Io.Dir = null;
    defer if (opened_dir) |*d| d.close(io);
    var content_dir: Io.Dir = undefined;
    if (sources == null) {
        opened_dir = try cwd.openDir(io, content_root, .{});
        content_dir = opened_dir.?;
    }

    if (recorder) |t| t.start(.parse);
    for (scan_list.items()) |disc| {
        const source = if (sources) |s|
            try s.readPage(disc.source_path, gpa)
        else
            try source_io.readPageAlloc(io, content_dir, disc.source_path, gpa);
        defer gpa.free(source);
        if (recorder) |t| t.bump(.page_reads, 1);

        const parsed = parser.parse(source);
        if (parsed.diagnostic) |pd| {
            diag.printText(.{
                .severity = .error_,
                .code = diag.parserCategoryToCode(pd.category),
                .message = pd.message,
                .remediation = if (pd.remediation.len > 0) pd.remediation else "Fix the frontmatter or encoding for this file",
                .source_path = disc.source_path,
                .line = pd.line,
                .column = pd.column,
            }, gpa);
            return error.ParseFailed;
        }
        // Validates the adapter subset for this page; the adapted body is
        // discarded because rendering adapts again per target.
        //
        // The recipe is discarded too, and deliberately: the HTML path has no
        // consumer for it — only the IR path in `pipeline.zig` promotes and
        // emits it. Adapting into `db.retain` to fill an unread field would pin
        // a second copy of every recipe body for the whole build.
        //
        // This is the one pass that prints degraded-structure warnings: it
        // runs once per build and always covers every page, including the
        // cache-reused pages an incremental build skips at render time. The
        // render and heading-harvest passes pass `print_warnings = false`, so
        // each warning surfaces exactly once.
        var body_arena = std.heap.ArenaAllocator.init(gpa);
        defer body_arena.deinit();
        _ = try html_body.bodyForInput(body_arena.allocator(), input_format, source, parsed.doc.body, parsed.doc.body_offset, disc.source_path, true);

        const final_id: []const u8 = if (parsed.doc.meta.id) |override| override else disc.entity_id;
        try db.promote(disc, final_id, parsed.doc.meta.id != null, parsed.doc.meta, parsed.doc.body_offset, .{});
    }
    if (recorder) |t| t.stop(.parse);
}

/// Optional rendering inputs for `renderAndPublishPage`. Defaults keep the
/// minimal path (no graph chrome, headings, theme, or page assets).
pub const RenderOptions = struct {
    site: ?*const FrozenSite = null,
    heading_index: ?*const wikilink.HeadingIndex = null,
    /// Prebuilt wiki id→node map covering `site.?.nodes`, shared across the
    /// page loop (#726). When null, each wiki-linked page builds its own.
    shared_node_map: ?*const wikilink.NodeMap = null,
    /// Prebuilt source_path→node map covering `site.?.nodes` for the
    /// documentation-link rewrite (#726). Same sharing contract.
    shared_doclink_map: ?*const doclink.SourceNodeMap = null,
    theme: ?*const theme_mod.ThemeBundle = null,
    page_assets: ?*const content_asset.PageAssetBundle = null,
    /// Standard.site verification surfaces for the compiler-owned `{{head}}`
    /// slot. Set automatically from `CompileOptions.standard_site_verification`
    /// by `renderAndPublishPage`; the validation path sets it explicitly.
    verification: ?*const standard_site.VerificationSurfaces = null,
    /// Nostr head config for the same slot. Composed after Standard.site.
    nostr_head: ?*const nostr_emit.HeadConfig = null,
    /// Build-scoped include expansion memo (#760); shared across pages and
    /// safe for concurrent workers. Null keeps per-call expansion caching.
    include_cache: ?*include_mod.IncludeCache = null,
};

/// Build the per-pass shared node maps (#726): wiki rewrite keys by entity id,
/// documentation-link rewrite by source_path. Null members let every page fall
/// back to its own per-page map exactly as before.
fn buildSharedWikiNodeMap(gpa: std.mem.Allocator, site: ?*const FrozenSite) !?wikilink.NodeMap {
    const s = site orelse return null;
    if (s.nodes.len == 0) return null;
    return try wikilink.buildNodeMap(gpa, s.nodes);
}

fn buildSharedDoclinkNodeMap(gpa: std.mem.Allocator, site: ?*const FrozenSite) !?doclink.SourceNodeMap {
    const s = site orelse return null;
    if (s.nodes.len == 0) return null;
    return try doclink.buildSourceNodeMap(gpa, s.nodes);
}

/// Render one page through the canonical prepublication body and layout-slot
/// preparation path. Returned slices live on `doc_arena`; callers must keep
/// the arena alive until they either publish or deliberately discard them.
///
/// **Caller owns Whiteboard lifecycle:** must `reset(.free_all)` only after
/// this function returns (success or error). This function never resets the
/// arena; it only allocates into it.
///
/// PageDb metadata must already be durable (from `loadAndPromote`). This
/// function re-reads source for the body only — parse views stay on the
/// Whiteboard until return.
///
/// `{{toc}}` is built from rendered body HTML (page-local; no graph required).
fn renderPageSlots(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    page: *const DurablePage,
    layout: assemble.Layout,
    doc_arena: *std.heap.ArenaAllocator,
    options: CompileOptions,
    page_index: usize,
    render_opts: RenderOptions,
) !assemble.SlotValues {
    const arena = doc_arena.allocator();

    const source = if (options.sources) |sources|
        try sources.readPage(page.source_path, arena)
    else
        try source_io.readPageAlloc(io, content_dir, page.source_path, arena);
    if (options.test_fail_render_at) |idx| {
        if (idx == page_index) return error.TestInjectedRenderFailure;
    }
    const html = try html_body.renderSource(io, gpa, content_dir, doc_arena, source, page.source_path, page.output_path, .{
        .input_format = options.input_format,
        .nodes = if (render_opts.site) |s| s.nodes else &.{},
        .shared_node_map = render_opts.shared_node_map,
        .shared_doclink_map = render_opts.shared_doclink_map,
        .heading_index = render_opts.heading_index,
        .page_assets = render_opts.page_assets,
        .diagnostics = options.diagnostics,
        .output_profile = options.output_profile,
        .sources = options.sources,
        .include_cache = render_opts.include_cache,
    });

    var slots: assemble.SlotValues = .{ .content = html };

    if (layout.has_toc) {
        slots.toc = try html_toc.renderToc(arena, html);
    }
    if (layout.has_metadata) {
        slots.metadata = try renderMetadata(arena, page);
    }
    if (layout.has_footer) {
        slots.footer = if (render_opts.theme) |t| t.footer() else "";
    }
    if (layout.has_asset_url) {
        const paths = layout.assetPaths();
        var hrefs = try arena.alloc([]const u8, paths.len);
        for (paths, 0..) |ap, i| {
            hrefs[i] = try identity.relativeHref(arena, page.output_path, ap);
        }
        slots.asset_hrefs = hrefs;
    }

    if (render_opts.site) |s| {
        const gi = s.indexOf(page.entity_id) orelse return error.GraphValidationFailed;
        const node = s.nodes[gi];
        if (layout.has_nav) {
            slots.nav = try html_nav.renderNav(arena, s.nodes, s.nav, gi, page.output_path, layout.nav_depth);
        }
        if (layout.has_breadcrumb) {
            slots.breadcrumb = try html_nav.renderBreadcrumb(arena, s.nodes, s.nav, gi, page.output_path);
        }
        if (layout.has_title) {
            slots.title = try html_nav.renderTitle(arena, node);
        }
        if (layout.has_children) {
            slots.children = try html_nav.renderChildren(arena, s.nodes, s.nav, gi, page.output_path);
        }
        if (layout.has_relations) {
            slots.relations = try html_relations.renderRelations(arena, s.nodes, gi, page.output_path);
        }
        if (layout.has_backlinks) {
            slots.backlinks = try html_relations.renderBacklinks(arena, s.nodes, gi, page.output_path);
        }
    } else if (layout.has_nav or layout.has_breadcrumb or layout.has_title or layout.has_children or layout.has_relations or layout.has_backlinks) {
        // Layout requests graph chrome but no frozen site — treat as internal error.
        return error.GraphValidationFailed;
    }

    // Compiler-owned head output. The layout opts in via the closed `{{head}}`
    // slot; absence (or an ineligible page) leaves the slot empty so nothing
    // silently claims document verification. Standard.site and Nostr compose
    // when both are configured.
    if (layout.has_head) {
        const ss = if (render_opts.verification) |surfaces|
            try standard_site_emit.documentHeadFragment(arena, surfaces, page.entity_id)
        else
            "";
        const nostr_bytes = if (render_opts.nostr_head) |cfg|
            try nostr_emit.pageHeadFragment(arena, cfg, page)
        else
            "";
        if (ss.len == 0) {
            slots.head = nostr_bytes;
        } else if (nostr_bytes.len == 0) {
            slots.head = ss;
        } else {
            slots.head = try std.fmt.allocPrint(arena, "{s}{s}", .{ ss, nostr_bytes });
        }
    }

    return slots;
}

/// Render one page body through Oliver into the Whiteboard and publish HTML.
///
/// Publication is deliberately a thin wrapper over `renderPageSlots` so the
/// no-publication validator and normal HTML compiler cannot drift on source,
/// component, link, graph-chrome, TOC, metadata, footer, or asset-url rules.
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
    render_opts_in: RenderOptions,
) !void {
    // The compiler-owned {{head}} slot always mirrors the configured Standard.site
    // verification, so every production render path agrees with the report.
    var render_opts = render_opts_in;
    if (options.standard_site_verification) |ctx| {
        render_opts.verification = ctx.surfaces;
    }
    if (options.nostr_head) |cfg| {
        render_opts.nostr_head = cfg;
    }
    const slots = try renderPageSlots(
        io,
        gpa,
        content_dir,
        page,
        layout,
        doc_arena,
        options,
        page_index,
        render_opts,
    );

    const fail_publish = if (options.test_fail_publish_at) |idx| idx == page_index else false;
    try assemble.writePageWithSlotsOpts(io, dist_dir, page.output_path, layout, slots, .{
        .fail_before_publish = fail_publish,
    });
}

pub const CacheEntry = compile_cache.CacheEntry;
pub const CacheManifest = compile_cache.CacheManifest;
pub const ParsedCacheEntry = compile_cache.ParsedCacheEntry;
pub const ParsedCacheManifest = compile_cache.ParsedCacheManifest;

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
    return compile_cache.collectTransitIncludes(gpa, source, dep_index, list, visited);
}

fn writeCacheManifest(allocator: std.mem.Allocator, writer: anytype, manifest: CacheManifest) !void {
    return compile_cache.writeCacheManifest(allocator, writer, manifest);
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

    try validateSitemapConfig(gpa, options);

    // 0. Lexical layout-path grammar before any open (no .. / absolute escapes).
    layout_select.validateLayoutPath(options.layout_path) catch |err| {
        const msg = try std.fmt.allocPrint(gpa, "invalid layout path {s}: {s}", .{ options.layout_path, @errorName(err) });
        defer gpa.free(msg);
        appendHtmlDiagnostic(&options, .{
            .severity = .error_,
            .code = .ELAYOUTPATH,
            .message = msg,
            .remediation = diag.Code.remediationForLayout(.ELAYOUTPATH),
            .source_path = options.layout_path,
        });
        return err;
    };
    for (options.layout_rules) |rule| {
        try layout_select.validateLayoutPath(rule.layout_path);
    }

    // 1. Layout first — hard fail before any content walk on bad marker.
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = loadLayoutForOptions(io, cwd, options, layout_arena.allocator()) catch |err| {
        const msg = try std.fmt.allocPrint(gpa, "failed to load layout {s}: {s}", .{ options.layout_path, @errorName(err) });
        defer gpa.free(msg);
        appendHtmlDiagnostic(&options, .{
            .severity = .error_,
            .code = layoutCodeFor(err),
            .message = msg,
            .remediation = diag.Code.remediationForLayout(layoutCodeFor(err)),
            .source_path = options.layout_path,
        });
        return err;
    };

    // 2. Long-lived PageDb (retain arena for promoted metadata only).
    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();

    if (options.sources) |sources| {
        try loadAndPromoteFromProvider(io, gpa, &db, sources, options.input_format, options.timings);
    } else {
        try loadAndPromoteFormat(io, gpa, &db, options.content_root, options.input_format, options.timings);
    }

    // 3. Graph validate + freeze (shared rules with IR/RAG; Feature 6 nav).
    // Rules may select graph chrome even when the fallback layout has none.
    var site = try freezeSiteFromPageDb(gpa, &db, options.quiet, layout.has_nav or layout.has_breadcrumb or layout.has_title or layout.has_children or layout.has_relations or layout.has_backlinks or options.layout_rules.len != 0, options.timings, options.diagnostics);
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
    /// Per-page transitive include contents in stable sorted path order. The
    /// byte buffers are **views** into `include_memo` (#760): each unique
    /// fragment is read once per build and shared across consumer pages.
    /// Only the outer per-page slices are individually GPA-owned.
    include_bytes: [][][]u8,
    /// Paths parallel to `include_bytes` (GPA-owned strings; same order).
    include_paths: [][][]u8,
    /// Unique transitive include bytes read once per build (#760); keys live
    /// on `path_arena`, values are GPA-owned.
    include_memo: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(self: *SharedCompileState) void {
        for (self.include_bytes) |list| self.gpa.free(list);
        self.gpa.free(self.include_bytes);
        for (self.include_paths) |list| {
            for (list) |p| self.gpa.free(p);
            self.gpa.free(list);
        }
        self.gpa.free(self.include_paths);
        var memo_it = self.include_memo.iterator();
        while (memo_it.next()) |entry| self.gpa.free(entry.value_ptr.*);
        self.include_memo.deinit(self.gpa);
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
        input_format: identity.InputFormat,
        recorder: ?*timings.Recorder,
        sink: ?*diag.Collector,
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
            const src = try source_io.readPageAlloc(io, content_dir, p.source_path, gpa);
            source_bytes[i] = src;
            sources_filled = i + 1;
            if (recorder) |t| t.bump(.page_reads, 1);
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
        if (recorder) |t| t.start(.dependency_resolve);
        try pipeline.populateDependencyIndexFormat(io, gpa, inc_alloc, content_root, dep_nodes, quiet, input_format, &dep_index, sink);
        if (recorder) |t| t.stop(.dependency_resolve);

        const include_bytes = try gpa.alloc([][]u8, db.len());
        const include_paths = try gpa.alloc([][]u8, db.len());
        var includes_filled: usize = 0;
        errdefer {
            for (include_bytes[0..includes_filled]) |list| {
                // Byte buffers are shared memo views; only the containers are owned here.
                gpa.free(list);
            }
            gpa.free(include_bytes);
            for (include_paths[0..includes_filled]) |list| {
                for (list) |p| gpa.free(p);
                gpa.free(list);
            }
            gpa.free(include_paths);
        }

        // Memoize unique include reads per build (#760): a fragment consumed
        // by many pages is read once, and every consumer shares the bytes.
        var include_memo: std.StringHashMapUnmanaged([]u8) = .empty;
        errdefer {
            var memo_it = include_memo.iterator();
            while (memo_it.next()) |entry| gpa.free(entry.value_ptr.*);
            include_memo.deinit(gpa);
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
                // Byte views are memo-owned; only free the containers.
                gpa.free(list);
                for (path_list[0..j]) |p| gpa.free(p);
                gpa.free(path_list);
            }
            while (j < transit_includes.items.len) : (j += 1) {
                const inc_path = transit_includes.items[j];
                const bytes = blk: {
                    if (include_memo.get(inc_path)) |hit| break :blk hit;
                    const fresh = try readFileAlloc(io, content_dir, inc_path, gpa);
                    errdefer gpa.free(fresh);
                    const key = try inc_alloc.dupe(u8, inc_path);
                    try include_memo.put(gpa, key, fresh);
                    if (recorder) |t| t.bump(.include_reads, 1);
                    break :blk fresh;
                };
                list[j] = bytes;
                path_list[j] = try gpa.dupe(u8, inc_path);
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
            .include_memo = include_memo,
        };
    }
};

const CachedLayout = struct {
    layout: assemble.Layout,
    bytes: []u8,
    /// Theme fingerprint material for this layout (footer + its asset-url refs).
    theme_material: []u8 = &.{},
};

pub fn isContentCompileFailure(err: anyerror) bool {
    return switch (err) {
        error.GraphValidationFailed,
        error.IncludeFailed,
        error.ReferenceFailed,
        error.ParseFailed,
        error.ComponentFailed,
        error.TextileFailed,
        error.InputFormatMismatch,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.LayoutUnknownMarker,
        error.LayoutInvalidNavMarker,
        error.LayoutTooManySegments,
        error.LayoutInvalidAssetUrl,
        error.LayoutTooManyAssetUrls,
        error.LayoutInvalidUtf8,
        error.AssetNotFound,
        error.AssetCollision,
        error.AssetSymlink,
        error.AssetPathEscape,
        error.AssetFailed,
        error.AssetPath,
        error.AssetMissing,
        error.AssetNotFile,
        error.AssetUnsafeSvg,
        error.LinkAuditFailed,
        error.ThemeRootMissing,
        error.InvalidThemePath,
        error.ThemeSymlink,
        error.FooterSymlink,
        error.FooterInvalidUtf8,
        error.SitemapDuplicateUrl,
        error.SitemapUrlLimitExceeded,
        error.SitemapSizeLimitExceeded,
        => true,
        // Layout-rule selection failures are usage (exit 2), not content.
        error.AmbiguousGlob,
        error.MixedThemeRoots,
        error.DuplicateSelector,
        error.InvalidLayoutPath,
        error.LayoutSelectionFailed,
        error.InvalidSiteUrl,
        error.InvalidSitemapPath,
        error.SitemapOutputCollision,
        error.SitemapSiteUrlRequired,
        error.SitemapSiteUrlWithoutOutput,
        error.AmbiguousSitemapTargets,
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
) !CompileStats {
    if (base_options.sitemap_path != null and targets.len > 1) return error.AmbiguousSitemapTargets;
    try validateSitemapConfig(gpa, base_options);

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

    try loadAndPromoteFormat(io, gpa, &db, base_options.content_root, base_options.input_format, base_options.timings);

    // Shared graph freeze once for all targets (Feature 6). Always compute nav
    // material; fingerprint mixes it in only when a layout has `{{nav}}`.
    var site = try freezeSiteFromPageDb(gpa, &db, base_options.quiet, true, base_options.timings, base_options.diagnostics);
    defer site.deinit();

    // Shared content/include fingerprint inputs once for all targets.
    var shared = try SharedCompileState.init(io, gpa, &db, base_options.content_root, base_options.quiet, base_options.input_format, base_options.timings, base_options.diagnostics);
    defer shared.deinit();

    try preflightValidateLayouts(gpa, plans, &db, base_options);

    // Layout templates cached by path (per-target layouts share the same arena).
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    var layout_cache: std.StringHashMapUnmanaged(CachedLayout) = .{};
    defer layout_cache.deinit(gpa);

    var any_failed = false;
    var any_io_failed = false;
    var any_usage_failed = false;
    // Aggregate page statistics across targets (watch `--watch-json` reports
    // the total written for the initial build; rebuild values are optional).
    var total_stats: CompileStats = .{};
    for (plans) |plan| {
        const load_failed = try loadLayoutsForPlan(io, gpa, plan, &layout_cache, layout_arena.allocator(), &base_options, &any_failed, &any_io_failed);
        if (load_failed) continue;

        if (compileOneTarget(io, gpa, &db, plan, base_options, &shared, &site, &layout_cache)) |st| {
            total_stats.pages_written += st.pages_written;
            total_stats.pages_attempted += st.pages_attempted;
            if (st.peak_whiteboard_capacity > total_stats.peak_whiteboard_capacity) {
                total_stats.peak_whiteboard_capacity = st.peak_whiteboard_capacity;
            }
            if (st.last_reset_capacity > total_stats.last_reset_capacity) {
                total_stats.last_reset_capacity = st.last_reset_capacity;
            }
        } else |err| {
            if (err != error.IncludeFailed and err != error.ReferenceFailed and
                err != error.ComponentFailed and err != error.GraphValidationFailed and err != error.AmbiguousGlob and
                err != error.MixedThemeRoots and err != error.LayoutSelectionFailed)
            {
                if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: target '{s}' compilation failed: {s}\n", .{ plan.name, @errorName(err) });
                const msg = try std.fmt.allocPrint(gpa, "target '{s}' compilation failed: {s}", .{ plan.name, @errorName(err) });
                defer gpa.free(msg);
                appendHtmlDiagnostic(&base_options, .{
                    .severity = .error_,
                    .code = layoutCodeFor(err),
                    .message = msg,
                    .remediation = diag.Code.remediationForLayout(layoutCodeFor(err)),
                    .source_path = plan.layout_path,
                });
            }
            any_failed = true;
            if (err == error.AmbiguousGlob or err == error.MixedThemeRoots or
                err == error.DuplicateSelector or err == error.LayoutSelectionFailed or
                err == error.InvalidSiteUrl or err == error.InvalidSitemapPath or
                err == error.SitemapOutputCollision or err == error.SitemapSiteUrlRequired or
                err == error.SitemapSiteUrlWithoutOutput or err == error.AmbiguousSitemapTargets)
            {
                any_usage_failed = true;
            } else {
                any_io_failed = any_io_failed or !isContentCompileFailure(err);
            }
            if (base_options.timings) |t| t.stopAll();
            continue;
        }
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
    return total_stats;
}

fn preflightValidateLayouts(
    gpa: std.mem.Allocator,
    plans: []const target_mod.TargetPlan,
    db: *const PageDb,
    base_options: CompileOptions,
) !void {
    for (plans) |plan| {
        target_mod.rejectMixedThemeRoots(plan.layout_path, plan.layout_rules) catch |err| {
            if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: target '{s}' mixed theme roots in layout rules: {s}\n", .{ plan.name, @errorName(err) });
            const msg = try std.fmt.allocPrint(gpa, "target '{s}' mixed theme roots in layout rules: {s}", .{ plan.name, @errorName(err) });
            defer gpa.free(msg);
            appendHtmlDiagnostic(&base_options, .{
                .severity = .error_,
                .code = .ELAYOUTRULE,
                .message = msg,
                .remediation = diag.Code.remediationForLayout(.ELAYOUTRULE),
                .source_path = plan.layout_path,
            });
            return error.MixedThemeRoots;
        };
        for (db.items()) |page| {
            _ = layout_select.selectLayout(page.entity_id, page.role, plan.layout_rules, plan.layout_path) catch |err| {
                if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: target '{s}' layout selection failed for '{s}': {s}\n", .{
                    plan.name,
                    page.entity_id,
                    @errorName(err),
                });
                const msg = try std.fmt.allocPrint(gpa, "layout selection failed for '{s}': {s}", .{ page.entity_id, @errorName(err) });
                defer gpa.free(msg);
                appendHtmlDiagnostic(&base_options, .{
                    .severity = .error_,
                    .code = layoutCodeFor(err),
                    .message = msg,
                    .remediation = diag.Code.remediationForLayout(layoutCodeFor(err)),
                    .source_path = plan.layout_path,
                    .id = page.entity_id,
                });
                return switch (err) {
                    error.AmbiguousGlob => error.AmbiguousGlob,
                    error.DuplicateSelector => error.DuplicateSelector,
                    else => error.LayoutSelectionFailed,
                };
            };
        }
    }
}

fn loadLayoutsForPlan(
    io: Io,
    gpa: std.mem.Allocator,
    plan: target_mod.TargetPlan,
    layout_cache: *std.StringHashMapUnmanaged(CachedLayout),
    layout_arena: std.mem.Allocator,
    base_options: *const CompileOptions,
    any_failed: *bool,
    any_io_failed: *bool,
) !bool {
    const declared = layout_select.collectDeclaredLayouts(gpa, plan.layout_path, plan.layout_rules) catch {
        any_failed.* = true;
        any_io_failed.* = true;
        return true;
    };
    defer gpa.free(declared);

    for (declared) |lp| {
        const gop = try layout_cache.getOrPut(gpa, lp);
        if (gop.found_existing) continue;
        const layout = loadLayoutOnce(io, Io.Dir.cwd(), lp, layout_arena) catch |err| {
            if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: target '{s}' failed to load layout {s}: {s} [{s}]\n", .{ plan.name, lp, @errorName(err), diag.Code.remediationForLayout(layoutCodeFor(err)) });
            const msg = try std.fmt.allocPrint(gpa, "failed to load layout {s}: {s}", .{ lp, @errorName(err) });
            defer gpa.free(msg);
            appendHtmlDiagnostic(base_options, .{
                .severity = .error_,
                .code = layoutCodeFor(err),
                .message = msg,
                .remediation = diag.Code.remediationForLayout(layoutCodeFor(err)),
                .source_path = lp,
            });
            any_failed.* = true;
            any_io_failed.* = any_io_failed.* or !isContentCompileFailure(err);
            _ = layout_cache.remove(lp);
            return true;
        };
        const bytes = readFileAlloc(io, Io.Dir.cwd(), lp, gpa) catch |err| {
            if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: target '{s}' failed to read layout {s}: {s}\n", .{ plan.name, lp, @errorName(err) });
            const msg = try std.fmt.allocPrint(gpa, "failed to read layout {s}: {s}", .{ lp, @errorName(err) });
            defer gpa.free(msg);
            appendHtmlDiagnostic(base_options, .{
                .severity = .error_,
                .code = .EIO,
                .message = msg,
                .remediation = "Check the layout path spelling and file permissions",
                .source_path = lp,
            });
            any_failed.* = true;
            any_io_failed.* = true;
            _ = layout_cache.remove(lp);
            return true;
        };
        gop.value_ptr.* = .{ .layout = layout, .bytes = bytes };
    }
    return false;
}

fn compileOneTarget(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    plan: target_mod.TargetPlan,
    base_options: CompileOptions,
    shared: *const SharedCompileState,
    site: *const FrozenSite,
    layout_cache: *std.StringHashMapUnmanaged(CachedLayout),
) !CompileStats {
    const cached = layout_cache.get(plan.layout_path).?;
    var target_options = base_options;
    target_options.target_name = plan.name;
    target_options.dist_dir = plan.output_dir;
    target_options.layout_path = plan.layout_path;
    target_options.layout_rules = plan.layout_rules;
    target_options.output_profile = plan.html_profile orelse base_options.output_profile;
    return try compilePagesWithSharedAndSite(io, gpa, db, cached.layout, target_options, shared, cached.bytes, site);
}

/// Run the canonical HTML source/target prepublication phases without writing
/// a site, stage tree, cache, structured projection, or publication evidence.
/// Target path isolation still observes the selected output paths so a later
/// build cannot disagree about configuration safety.
pub fn validateHtmlSiteMulti(
    io: Io,
    gpa: std.mem.Allocator,
    targets: []const target_mod.TargetSpec,
    base_options: CompileOptions,
) !void {
    var validation_options = base_options;
    validation_options.validation_only = true;
    validation_options.incremental = false;
    validation_options.jobs = 1;
    _ = compileHtmlSiteMulti(io, gpa, targets, validation_options) catch |err| return err;
}

test "multi-target failure classification keeps I/O distinct from content" {
    try std.testing.expect(isContentCompileFailure(error.ParseFailed));
    try std.testing.expect(isContentCompileFailure(error.LayoutMissingMarker));
    try std.testing.expect(isContentCompileFailure(error.LayoutInvalidNavMarker));
    try std.testing.expect(isContentCompileFailure(error.AssetUnsafeSvg));
    try std.testing.expect(isContentCompileFailure(error.LinkAuditFailed));
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
    /// Immutable after workers start; concurrent read-only map access is safe.
    shared_node_map: ?*const wikilink.NodeMap = null,
    shared_doclink_map: ?*const doclink.SourceNodeMap = null,
    heading_index: ?*const wikilink.HeadingIndex,
    theme: ?*const theme_mod.ThemeBundle,
    content_assets: ?*const content_asset.SiteAssetInventory = null,
    /// Build-scoped include expansion memo (#760); internally locked, so
    /// concurrent workers may share it for the whole parallel pass.
    include_cache: ?*include_mod.IncludeCache = null,

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
            const page_assets: ?*const content_asset.PageAssetBundle = if (ctx.content_assets) |inv|
                &inv.pages[page_index]
            else
                null;
            renderAndPublishPage(
                ctx.io,
                ctx.gpa,
                ctx.content_dir,
                ctx.dist_dir,
                page,
                ctx.page_layouts[page_index],
                &doc_arena,
                ctx.options,
                page_index,
                .{
                    .site = ctx.site,
                    .shared_node_map = ctx.shared_node_map,
                    .shared_doclink_map = ctx.shared_doclink_map,
                    .heading_index = ctx.heading_index,
                    .theme = ctx.theme,
                    .page_assets = page_assets,
                    .include_cache = ctx.include_cache,
                },
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
    // Rules may select graph chrome even when the fallback layout has none.
    var site = try freezeSiteFromPageDb(gpa, db, options.quiet, layout.has_nav or layout.has_breadcrumb or layout.has_title or layout.has_children or layout.has_relations or layout.has_backlinks or options.layout_rules.len != 0, options.timings, options.diagnostics);
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
    // Rules may select graph chrome even when the fallback layout has none.
    var site = try freezeSiteFromPageDb(gpa, db, options.quiet, layout.has_nav or layout.has_breadcrumb or layout.has_title or layout.has_children or layout.has_relations or layout.has_backlinks or options.layout_rules.len != 0, options.timings, options.diagnostics);
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
    return compile_cache.fingerprintHex(fp_bytes, gpa);
}

const HEADING_HARVEST_FORMAT = compile_heading.HEADING_HARVEST_FORMAT;
const ParsedHeadingHarvestEntry = compile_heading.ParsedHeadingHarvestEntry;
const ParsedHeadingHarvest = compile_heading.ParsedHeadingHarvest;
const HeadingHarvestWriteEntry = compile_heading.HeadingHarvestWriteEntry;
const HeadingHarvestSnapshot = compile_heading.HeadingHarvestSnapshot;

fn collectFragmentTargetSet(
    gpa: std.mem.Allocator,
    db: *const PageDb,
    shared: *const SharedCompileState,
) !std.StringHashMapUnmanaged(void) {
    return compile_heading.collectFragmentTargetSet(gpa, db.items(), shared.source_bytes, shared.include_bytes, shared.include_paths);
}

fn headingHarvestKey(
    entity_id: []const u8,
    source_bytes: []const u8,
    include_bytes: []const []const u8,
    input_material: []const u8,
) [32]u8 {
    return compile_heading.headingHarvestKey(entity_id, source_bytes, include_bytes, input_material);
}

fn writeHeadingHarvestCache(allocator: std.mem.Allocator, writer: anytype, entries: []const HeadingHarvestWriteEntry) !void {
    return compile_heading.writeHeadingHarvestCache(allocator, writer, entries);
}

/// Harvest Oliver-rendered heading ids for pages that are wiki-fragment targets.
/// Reuses the same pre-render + Oliver body pipeline as publish (no second slugger).
/// Wiki fragments are emitted but not validated here (index bootstrapping).
/// When no fragment links exist, returns an empty index (no render work).
///
/// When `prior_harvest` is non-null (incremental) and a page's harvest key
/// matches a prior entry, Oliver is skipped for that page (#58). Callers may
/// write the returned harvest snapshot under `.boris-cache/heading-harvest.json`.
fn buildSiteHeadingIndex(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    db: *const PageDb,
    site: *const FrozenSite,
    shared: *const SharedCompileState,
    input_format: identity.InputFormat,
    prior_harvest: ?*const ParsedHeadingHarvest,
    recorder: ?*timings.Recorder,
    sink: ?*diag.Collector,
    include_cache: ?*include_mod.IncludeCache,
) !struct { wikilink.HeadingIndex, HeadingHarvestSnapshot } {
    return compile_heading.buildSiteHeadingIndex(io, gpa, content_dir, db.items(), site.nodes, shared.source_bytes, shared.include_bytes, shared.include_paths, input_format, prior_harvest, recorder, sink, include_cache);
}

fn expandDirtySet(
    gpa: std.mem.Allocator,
    is_dirty: []bool,
    pages: []const DurablePage,
    nodes: []const graph_mod.Node,
    dep_index: *const dependency.DependencyIndex,
) !void {
    return compile_cache.expandDirtySet(gpa, is_dirty, pages, nodes, dep_index);
}

/// Sibling staging directory for a target: `{dist_dir}.boris-stage`.
fn stageRelForDist(gpa: std.mem.Allocator, dist_dir: []const u8) ![]u8 {
    return compile_cache.stageRelForDist(gpa, dist_dir);
}

const sitemap_ownership_path = compile_cache.sitemap_ownership_path;

const PriorSitemapOwnership = compile_cache.PriorSitemapOwnership;

fn readPriorSitemapOwnership(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
) !PriorSitemapOwnership {
    return compile_cache.readPriorSitemapOwnership(io, gpa, dist_dir);
}

fn stageSitemapOwnership(
    io: Io,
    stage_dir: Io.Dir,
    current_path: ?[]const u8,
) !void {
    return compile_cache.stageSitemapOwnership(io, stage_dir, current_path);
}

fn ensureValidParentDirs(io: Io, final_dir: Io.Dir, parent_rel: []const u8) !void {
    return compile_stage.ensureValidParentDirs(io, final_dir, parent_rel);
}

fn publishStageFile(
    io: Io,
    source_dir: Io.Dir,
    source_path: []const u8,
    final_dir: Io.Dir,
    final_path: []const u8,
) !void {
    return compile_stage.publishStageFile(io, source_dir, source_path, final_dir, final_path);
}

fn publishPathsEqual(left: []const u8, right: []const u8) bool {
    // Delegated to compile_stage's internal helper; kept for any direct callers.
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (left_byte == right_byte) continue;
        if ((left_byte == '/' and right_byte == '\\') or (left_byte == '\\' and right_byte == '/')) continue;
        return false;
    }
    return true;
}

fn publishStageTree(
    io: Io,
    gpa: std.mem.Allocator,
    stage_dir: Io.Dir,
    final_dir: Io.Dir,
    deferred_path: ?[]const u8,
) !void {
    return compile_stage.publishStageTree(io, gpa, stage_dir, final_dir, deferred_path);
}

/// Complete the source/compiler validity work for one selected HTML target
/// without creating or mutating its output tree.
///
/// Every operation here is also an existing normal-compile operation: heading
/// harvest and page rendering use the same body/Oliver path, while layout slots,
/// graph chrome, theme assets, content-local assets, and sitemap bytes use the
/// same typed helpers as publication. Rendered bytes are deliberately
/// discarded; search, output link audit, inventories, checks, claims, Touch
/// Atlas, and Proof Pack remain publication phases.
/// Report link-audit findings on stderr and fail the pipeline. Shared by the
/// publish path (staged/live overlay audit) and the validation path (in-memory
/// audit) so the two diagnostics cannot drift.
/// Append `d` to the optional HTML-path diagnostic collector (OOM-safe).
fn appendHtmlDiagnostic(options: *const CompileOptions, d: diag.Diagnostic) void {
    if (options.diagnostics) |sink| sink.append(d);
}

/// Stable diagnostic code for layout/theme load failures.
fn layoutCodeFor(err: anyerror) diag.Code {
    return switch (err) {
        error.LayoutMissingMarker => .ELAYOUTMISSINGMARKER,
        error.LayoutUnknownMarker => .ELAYOUTUNKNOWNMARKER,
        error.LayoutInvalidNavMarker, error.InvalidNavMarker => .ELAYOUTNAVDEPTH,
        error.LayoutDuplicateMarker => .ELAYOUTDUPLICATEMARKER,
        error.LayoutInvalidAssetUrl => .ELAYOUTASSET,
        error.LayoutTooManyAssetUrls => .ELAYOUTASSET,
        error.InvalidLayoutPath => .ELAYOUTPATH,
        error.AmbiguousGlob,
        error.DuplicateSelector,
        error.EmptySelector,
        error.InvalidSelector,
        error.UnknownSelectorKind,
        error.RuleLimitExceeded,
        error.LayoutSelectionFailed,
        error.MixedThemeRoots,
        => .ELAYOUTRULE,
        else => .ELAYOUT,
    };
}

fn reportLinkAuditFindings(sink: ?*diag.Collector, findings: []const link_audit.Finding) error{LinkAuditFailed} {
    for (findings) |f| {
        const detail = switch (f.code) {
            .EROUTEESCAPE => "climbs above the output root and can never be served [point it at a published output, or drop the reference]",
            .EPUBLICATIONLOCATION => "does not match the declared publication origin/base path [use a target-relative URL or include the Pages base path]",
            else => "does not resolve to a published output [fix the path, or publish the file it names]",
        };
        if (!diag.text_suppressed.load(.unordered)) {
            std.debug.print("error: {s}: {s}:{d}: {s}=\"{s}\" {s}\n", .{
                f.code.name(),
                f.source,
                f.line,
                f.attribute,
                f.target,
                detail,
            });
        }
        if (sink) |s| s.append(.{
            .severity = .error_,
            .code = f.code,
            .message = detail,
            .remediation = "Fix the path, or publish the file it names",
            .source_path = f.source,
            .line = f.line,
        });
    }
    return error.LinkAuditFailed;
}

fn validatePrepublicationTarget(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    db: *PageDb,
    page_layouts: []const assemble.Layout,
    options: CompileOptions,
    shared: *const SharedCompileState,
    site: *const FrozenSite,
    theme_bundle: *const theme_mod.ThemeBundle,
    content_assets: *const content_asset.SiteAssetInventory,
    include_cache: ?*include_mod.IncludeCache,
) !CompileStats {
    if (options.timings) |t| t.start(.heading_harvest);
    const heading_built = try buildSiteHeadingIndex(
        io,
        gpa,
        content_dir,
        db,
        site,
        shared,
        options.input_format,
        null,
        options.timings,
        options.diagnostics,
        include_cache,
    );
    if (options.timings) |t| t.stop(.heading_harvest);
    var heading_index = heading_built[0];
    defer heading_index.deinit(gpa);
    var heading_snapshot = heading_built[1];
    defer heading_snapshot.deinit();

    // Output link audit, in memory. `validate` writes nothing, so instead of
    // the publish path's staged/live overlay it audits the exact assembled
    // page bytes (same render helper + layout splice as `writePageWithSlots`)
    // against the intended output set: every page plus published content,
    // theme, and sitemap assets. This keeps validate authoritative for
    // EROUTEMISSING / EROUTEESCAPE / EPUBLICATIONLOCATION without ever
    // creating a target or stage directory.
    var audit_assets: std.ArrayList([]const u8) = .empty;
    defer audit_assets.deinit(gpa);
    const audit_content_outs = try content_assets.collectOutputPaths(gpa);
    defer gpa.free(audit_content_outs);
    try audit_assets.appendSlice(gpa, audit_content_outs);
    for (theme_bundle.assets) |a| try audit_assets.append(gpa, a.rel_path);
    if (options.sitemap_path) |path| try audit_assets.append(gpa, path);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    for (db.items()) |page| try intended.put(gpa, page.output_path, {});
    for (audit_assets.items) |path| try intended.put(gpa, path, {});

    var findings: std.ArrayList(link_audit.Finding) = .empty;
    defer link_audit.freeFindings(gpa, &findings);
    var link_audit_opts = link_audit.Options{
        .publication_location = options.publication_location,
        .allow_markdown_literals = options.allow_markdown_literals,
    };
    if (options.timings) |t| {
        link_audit_opts.resolution_counter = t.counterPtr(.link_resolutions);
        link_audit_opts.fast_path_counter = t.counterPtr(.fast_path_hits);
    }

    var stats: CompileStats = .{};
    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    if (options.timings) |t| t.start(.render);
    for (db.items(), 0..) |*page, page_index| {
        defer {
            _ = doc_arena.reset(.free_all);
            stats.last_reset_capacity = doc_arena.queryCapacity();
        }

        const slots = try renderPageSlots(
            io,
            gpa,
            content_dir,
            page,
            page_layouts[page_index],
            &doc_arena,
            options,
            page_index,
            .{
                .site = site,
                .heading_index = &heading_index,
                .theme = theme_bundle,
                .page_assets = &content_assets.pages[page_index],
                .verification = if (options.standard_site_verification) |ctx| ctx.surfaces else null,
                .nostr_head = options.nostr_head,
                .include_cache = include_cache,
            },
        );

        // Assemble the exact published bytes in memory (same splice ordering
        // as `writePageWithSlotsOpts`) and audit them while the arena is live.
        if (options.timings) |t| t.start(.link_audit);
        var sink = assemble.HoldUntilFlush.init(gpa);
        defer sink.deinit();
        try assemble.spliceToHoldSlots(page_layouts[page_index], slots, &sink);
        try link_audit.auditDocumentWithOptions(
            gpa,
            &intended,
            page.output_path,
            sink.materialized.?,
            link_audit_opts,
            &findings,
        );
        if (options.timings) |t| t.stop(.link_audit);

        if (options.timings) |t| t.bump(.page_reads, 1);
        stats.pages_attempted += 1;
        const cap = doc_arena.queryCapacity();
        if (cap > stats.peak_whiteboard_capacity) stats.peak_whiteboard_capacity = cap;
    }
    if (options.timings) |t| t.stop(.render);
    if (findings.items.len != 0) return reportLinkAuditFindings(options.diagnostics, findings.items);

    // Sitemap configuration is source/target validity, but sitemap publication
    // is not. Render its deterministic bytes in memory to exercise the exact
    // URL, duplicate, count, and size rules, then discard them.
    if (options.sitemap_path != null) {
        var page_paths: std.ArrayList([]const u8) = .empty;
        defer page_paths.deinit(gpa);
        for (db.items()) |page| {
            if (page.status == .draft) continue;
            try page_paths.append(gpa, page.output_path);
        }
        const sitemap_bytes = if (options.publication_location) |location|
            try sitemap.renderForLocation(gpa, location, page_paths.items)
        else
            try sitemap.render(gpa, options.site_url.?, page_paths.items);
        gpa.free(sitemap_bytes);
    }

    return stats;
}

const PageLayoutSelection = struct {
    layouts_by_path: std.StringHashMapUnmanaged(CachedLayout),
    page_sel_paths: []const []const u8,
    page_layouts: []assemble.Layout,
    page_layout_bytes: []const []const u8,

    fn deinit(self: *PageLayoutSelection, gpa: std.mem.Allocator, fallback_bytes: []const u8) void {
        var it = self.layouts_by_path.iterator();
        while (it.next()) |e| {
            // Fallback bytes may be borrowed from the caller; only free owned.
            if (e.value_ptr.bytes.ptr != fallback_bytes.ptr) {
                gpa.free(e.value_ptr.bytes);
            }
            if (e.value_ptr.theme_material.len > 0) gpa.free(e.value_ptr.theme_material);
        }
        self.layouts_by_path.deinit(gpa);
        gpa.free(self.page_sel_paths);
        gpa.free(self.page_layouts);
        gpa.free(self.page_layout_bytes);
    }
};

fn preparePageLayouts(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    db: *const PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
    layout_bytes: []const u8,
    layout_arena: std.mem.Allocator,
) !PageLayoutSelection {
    // Layout selection: load every declared layout (fallback + rules), select per page.
    try layout_select.validateLayoutPath(options.layout_path);
    for (options.layout_rules) |rule| {
        try layout_select.validateLayoutPath(rule.layout_path);
    }
    try target_mod.rejectMixedThemeRoots(options.layout_path, options.layout_rules);
    const declared = try layout_select.collectDeclaredLayouts(gpa, options.layout_path, options.layout_rules);
    defer gpa.free(declared);

    var layouts_by_path: std.StringHashMapUnmanaged(CachedLayout) = .{};
    errdefer {
        var it = layouts_by_path.iterator();
        while (it.next()) |e| {
            // Fallback bytes may be borrowed from the caller; only free owned.
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
        const loaded = try loadLayoutOnce(io, cwd, lp, layout_arena);
        const bytes = try readFileAlloc(io, cwd, lp, gpa);
        try layouts_by_path.put(gpa, lp, .{ .layout = loaded, .bytes = bytes });
    }

    const page_sel_paths = try gpa.alloc([]const u8, db.len());
    errdefer gpa.free(page_sel_paths);
    const page_layouts = try gpa.alloc(assemble.Layout, db.len());
    errdefer gpa.free(page_layouts);
    const page_layout_bytes = try gpa.alloc([]const u8, db.len());
    errdefer gpa.free(page_layout_bytes);

    for (db.items(), 0..) |page, i| {
        const sel = layout_select.selectLayout(page.entity_id, page.role, options.layout_rules, options.layout_path) catch |err| {
            if (!diag.text_suppressed.load(.unordered)) std.debug.print("error: layout selection failed for target '{s}' page '{s}': {s}\n", .{
                options.target_name,
                page.entity_id,
                @errorName(err),
            });
            const msg = try std.fmt.allocPrint(gpa, "layout selection failed for '{s}': {s}", .{ page.entity_id, @errorName(err) });
            defer gpa.free(msg);
            appendHtmlDiagnostic(&options, .{
                .severity = .error_,
                .code = layoutCodeFor(err),
                .message = msg,
                .remediation = diag.Code.remediationForLayout(layoutCodeFor(err)),
                .source_path = options.layout_path,
                .id = page.entity_id,
            });
            return switch (err) {
                error.AmbiguousGlob => error.AmbiguousGlob,
                error.DuplicateSelector => error.DuplicateSelector,
                else => error.LayoutSelectionFailed,
            };
        };
        // #395 / #557: record which layout won and why. Informational —
        // never affects exit codes or errorCount. Fallback winners emit
        // only when the target has rules, so a rule-less site stays silent.
        if (sel.kind != .fallback or options.layout_rules.len > 0) {
            const msg = if (sel.kind == .fallback)
                try std.fmt.allocPrint(gpa, "layout fallback selected {s}", .{sel.layout_path})
            else blk: {
                const rule = options.layout_rules[sel.rule_index orelse return error.LayoutSelectionFailed];
                break :blk try std.fmt.allocPrint(gpa, "layout rule {s}:{s} selected {s}", .{
                    @tagName(rule.kind),
                    rule.value,
                    sel.layout_path,
                });
            };
            defer gpa.free(msg);
            appendHtmlDiagnostic(&options, .{
                .severity = .info,
                .code = .ILAYOUTSELECTED,
                .message = msg,
                .source_path = page.source_path,
                .id = page.entity_id,
            });
        }
        page_sel_paths[i] = sel.layout_path;
        const cached = layouts_by_path.get(sel.layout_path) orelse return error.LayoutSelectionFailed;
        page_layouts[i] = cached.layout;
        page_layout_bytes[i] = cached.bytes;
    }

    return .{
        .layouts_by_path = layouts_by_path,
        .page_sel_paths = page_sel_paths,
        .page_layouts = page_layouts,
        .page_layout_bytes = page_layout_bytes,
    };
}

fn validateVerificationSurfaces(
    gpa: std.mem.Allocator,
    db: *const PageDb,
    page_layouts: []const assemble.Layout,
    page_sel_paths: []const []const u8,
    options: CompileOptions,
) !void {
    // Standard.site verification is opt-in and cross-checks the offline
    // projection against the live page set before any publication: every
    // planned document record must resolve to the same canonical URL as the
    // rendered page (fail closed). Layouts that omit the compiler-owned
    // {{head}} slot are reported as a warning so absence never silently
    // claims verification; the report artifact still records those pages as
    // `not_verified`. Runs for both the publish and validation paths.
    if (options.standard_site_verification) |ctx| {
        var page_paths: std.ArrayList(standard_site_emit.PagePath) = .empty;
        defer page_paths.deinit(gpa);
        for (db.items()) |p| try page_paths.append(gpa, .{
            .entity_id = p.entity_id,
            .output_path = p.output_path,
        });
        try standard_site_emit.validateProjection(gpa, ctx, page_paths.items);

        for (db.items(), 0..) |p, i| {
            if (page_layouts[i].has_head) continue;
            if (standard_site_emit.documentAtUri(gpa, ctx.surfaces, p.entity_id) == null) continue;
            const msg = try std.fmt.allocPrint(
                gpa,
                "Standard.site verification configured but selected layout omits the compiler-owned {{head}} slot; page '{s}' cannot emit its document AT-URI link (recorded as not verified)",
                .{p.entity_id},
            );
            defer gpa.free(msg);
            appendHtmlDiagnostic(&options, .{
                .severity = .warning,
                .code = .EVERIFICATIONHEAD,
                .message = msg,
                .remediation = "Add {{head}} inside the layout <head> so eligible pages can emit site.standard.document links",
                .source_path = page_sel_paths[i],
                .id = p.entity_id,
            });
        }
    }

    if (options.nostr_head) |cfg| {
        for (db.items(), 0..) |p, i| {
            if (page_layouts[i].has_head) continue;
            if (!nostr_emit.pageEligible(cfg, &p)) continue;
            const msg = try std.fmt.allocPrint(
                gpa,
                "Nostr publication is configured but selected layout omits the compiler-owned {{head}} slot; page '{s}' cannot emit its nostr:naddr alternate link",
                .{p.entity_id},
            );
            defer gpa.free(msg);
            appendHtmlDiagnostic(&options, .{
                .severity = .warning,
                .code = .ENOSTRHEAD,
                .message = msg,
                .remediation = "Add {{head}} inside the layout <head> so eligible Nostr articles can emit their naddr link",
                .source_path = page_sel_paths[i],
                .id = p.entity_id,
            });
        }
    }
}

fn prepareThemeBundle(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    db: *const PageDb,
    options: CompileOptions,
    layouts_by_path: *const std.StringHashMapUnmanaged(CachedLayout),
) !theme_mod.ThemeBundle {
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
    errdefer theme_bundle.deinit();
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
    return theme_bundle;
}

fn discoverContentAssets(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    db: *const PageDb,
    options: CompileOptions,
    theme_bundle: *const theme_mod.ThemeBundle,
) !content_asset.SiteAssetInventory {
    // Content-local sibling assets: discover and collide-check before any asset
    // bytes are staged. Theme + content assets publish together below.
    var source_paths = try gpa.alloc([]const u8, db.len());
    defer gpa.free(source_paths);
    var entity_ids = try gpa.alloc([]const u8, db.len());
    defer gpa.free(entity_ids);
    for (db.items(), 0..) |p, i| {
        source_paths[i] = p.source_path;
        entity_ids[i] = p.entity_id;
    }
    var asset_discovery_fail: content_asset.FailInfo = .{};
    var content_assets = content_asset.loadSiteAssets(io, gpa, content_dir, source_paths, entity_ids, &asset_discovery_fail) catch |err| {
        if (err == error.AssetUnsafeSvg) {
            content_asset.printDiagnostic(gpa, error.AssetUnsafeSvg, "", asset_discovery_fail, options.diagnostics);
        } else if (!diag.text_suppressed.load(.unordered)) {
            std.debug.print("error: content-local asset discovery failed: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    errdefer content_assets.deinit();
    {
        const content_outs = try content_assets.collectOutputPaths(gpa);
        defer gpa.free(content_outs);
        var page_outs: std.ArrayList([]const u8) = .empty;
        defer page_outs.deinit(gpa);
        try page_outs.ensureTotalCapacity(gpa, db.len());
        for (db.items()) |p| try page_outs.append(gpa, p.output_path);
        var theme_outs: std.ArrayList([]const u8) = .empty;
        defer theme_outs.deinit(gpa);
        try theme_outs.ensureTotalCapacity(gpa, theme_bundle.assets.len);
        for (theme_bundle.assets) |a| try theme_outs.append(gpa, a.rel_path);
        try content_asset.checkCollisions(content_outs, page_outs.items, theme_outs.items);

        var inventory_owned_paths: std.ArrayList([]const u8) = .empty;
        defer inventory_owned_paths.deinit(gpa);
        try inventory_owned_paths.ensureTotalCapacity(
            gpa,
            page_outs.items.len + theme_outs.items.len + content_outs.len + 2,
        );
        try inventory_owned_paths.appendSlice(gpa, page_outs.items);
        try inventory_owned_paths.appendSlice(gpa, theme_outs.items);
        try inventory_owned_paths.appendSlice(gpa, content_outs);
        try inventory_owned_paths.append(gpa, search_index.output_path);
        if (options.sitemap_path) |sitemap_path| try inventory_owned_paths.append(gpa, sitemap_path);
        try artifact_inventory.rejectOutputCollision(artifact_inventory.output_path, inventory_owned_paths.items);
        try artifact_inventory.rejectOutputCollision(publication_checks.output_path, inventory_owned_paths.items);
        try artifact_inventory.rejectOutputCollision(publication_claims.output_path, inventory_owned_paths.items);
        try artifact_inventory.rejectOutputCollision(publication_touches.output_path, inventory_owned_paths.items);

        if (options.sitemap_path) |sitemap_path| {
            var owned_paths: std.ArrayList([]const u8) = .empty;
            defer owned_paths.deinit(gpa);
            try owned_paths.ensureTotalCapacity(
                gpa,
                page_outs.items.len + theme_outs.items.len + content_outs.len + 1,
            );
            try owned_paths.appendSlice(gpa, page_outs.items);
            try owned_paths.appendSlice(gpa, theme_outs.items);
            try owned_paths.appendSlice(gpa, content_outs);
            try owned_paths.append(gpa, search_index.output_path);
            try owned_paths.append(gpa, artifact_inventory.output_path);
            try sitemap.rejectOutputCollisions(sitemap_path, owned_paths.items);
        }
    }
    return content_assets;
}

fn prepareThemeMaterial(
    gpa: std.mem.Allocator,
    db: *const PageDb,
    layouts_by_path: *const std.StringHashMapUnmanaged(CachedLayout),
    theme_bundle: *const theme_mod.ThemeBundle,
    page_sel_paths: []const []const u8,
) ![][]const u8 {
    // Per-layout theme fingerprint material (footer + that layout's asset-url refs).
    {
        var it = layouts_by_path.iterator();
        while (it.next()) |e| {
            e.value_ptr.theme_material = try theme_mod.referencedAssetMaterial(
                gpa,
                theme_bundle,
                e.value_ptr.layout.assetPaths(),
                e.value_ptr.layout.has_footer,
            );
        }
    }
    const page_theme_material = try gpa.alloc([]const u8, db.len());
    errdefer gpa.free(page_theme_material);
    for (page_sel_paths, 0..) |lp, i| {
        page_theme_material[i] = layouts_by_path.get(lp).?.theme_material;
    }
    return page_theme_material;
}

const IncrementalCacheState = struct {
    manifest_bytes: ?[]u8 = null,
    parsed_manifest: ?std.json.Parsed(ParsedCacheManifest) = null,
    heading_harvest_bytes: ?[]u8 = null,
    parsed_heading_harvest: ?std.json.Parsed(ParsedHeadingHarvest) = null,

    fn deinit(self: *IncrementalCacheState, gpa: std.mem.Allocator) void {
        if (self.parsed_heading_harvest) |ph| ph.deinit();
        if (self.heading_harvest_bytes) |hb| gpa.free(hb);
        if (self.parsed_manifest) |pm| pm.deinit();
        if (self.manifest_bytes) |mb| gpa.free(mb);
    }
};

fn loadIncrementalCacheState(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
    incremental: bool,
) IncrementalCacheState {
    var state: IncrementalCacheState = .{};
    if (!incremental) return state;
    if (readFileAlloc(io, dist_dir, ".boris-cache/manifest.json", gpa)) |bytes| {
        state.manifest_bytes = bytes;
        if (std.json.parseFromSlice(ParsedCacheManifest, gpa, bytes, .{ .ignore_unknown_fields = true })) |pm| {
            // Reject pre-P3.3 or foreign manifests so fingerprints cannot be misread.
            if (std.mem.eql(u8, pm.value.format_version, cache.CACHE_FORMAT_VERSION)) {
                state.parsed_manifest = pm;
            } else {
                pm.deinit();
            }
        } else |_| {}
    } else |_| {}
    if (readFileAlloc(io, dist_dir, ".boris-cache/heading-harvest.json", gpa)) |bytes| {
        state.heading_harvest_bytes = bytes;
        if (std.json.parseFromSlice(ParsedHeadingHarvest, gpa, bytes, .{ .ignore_unknown_fields = true })) |ph| {
            if (std.mem.eql(u8, ph.value.format, HEADING_HARVEST_FORMAT)) {
                state.parsed_heading_harvest = ph;
            } else {
                ph.deinit();
            }
        } else |_| {}
    } else |_| {}
    return state;
}

fn publishEvidenceReports(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
    options: CompileOptions,
) !void {
    // Evidence reuse (Option A, #728): when the committed artifact set is
    // byte-identical to the set the on-disk evidence was derived from — and
    // every derived report still hashes to its recorded digest — the fully
    // deterministic chain below would rewrite identical bytes. Skip it.
    // `--refresh-evidence` always derives; any mismatch falls back to the
    // full chain, so reuse is an optimization and never an authority.
    if (!options.refresh_evidence and
        publication_evidence_state.reuseValid(io, dist_dir, gpa, options.target_name, pipeline.compiler_id))
    {
        if (options.timings) |t| {
            t.start(.checks);
            t.stop(.checks);
            t.start(.claims);
            t.stop(.claims);
            t.start(.touches);
            t.stop(.touches);
            t.start(.proof_pack);
            t.stop(.proof_pack);
        }
        return;
    }

    // The payload transaction, including artifacts.json as its deferred last
    // file, is complete before checks read the target. Checks are a separate
    // atomic report publication and never participate in that transaction.
    if (options.timings) |t| t.start(.checks);
    var check_outcomes: std.ArrayList(publication_checks.Outcome) = .empty;
    defer check_outcomes.deinit(gpa);
    publication_checks.writeAfterCommit(io, gpa, dist_dir, options.target_name, .{
        .test_fail_execution = options.test_fail_publication_checks,
        .test_fail_write = options.test_fail_publication_checks_write,
        .outcomes_out = &check_outcomes,
    }) catch |err| {
        // Prose suppression is active under --watch-json and in unit-test
        // binaries (#768): the same failure still fails the compile and
        // reaches collectors/writer-injected assertions.
        if (!diag.text_suppressed.load(.unordered)) {
            const stderr = std.debug.lockStderr(&.{});
            defer std.debug.unlockStderr();
            writePublicationChecksFailure(&stderr.file_writer.interface, options.target_name, err) catch {};
        }
        return error.PublicationChecksFailed;
    };
    if (options.timings) |t| t.stop(.checks);

    // A failed check never fails the committed target by design
    // (docs/contracts/publication-checks.md), but it must not be invisible:
    // surface every non-passing verdict even under --quiet, with the pointer
    // to its per-finding evidence (#740, #741). The prose form is skipped
    // where text diagnostics are suppressed (--watch-json, unit tests).
    for (check_outcomes.items) |outcome| {
        if (outcome.status == .passed or outcome.status == .not_applicable) continue;
        if (diag.text_suppressed.load(.unordered)) continue;
        const stderr = std.debug.lockStderr(&.{});
        defer std.debug.unlockStderr();
        stderr.file_writer.interface.print(
            "warning: publication check '{s}' for target '{s}' reported status '{s}'; per-finding detail lives in _boris/proof/checks.json findings[] and the claim mirrors it in _boris/proof/claims.json\n",
            .{ outcome.id, options.target_name, outcome.status.name() },
        ) catch {};
    }

    // Claims are derived from the exact committed artifacts and checks bytes.
    // A derivation, stale-binding, parser, I/O, or atomic-write failure keeps
    // the committed target, inventory, and checks and leaves any prior claims
    // report untouched; the diagnostic is emitted even under --quiet.
    if (options.timings) |t| t.start(.claims);
    publication_claims.writeAfterChecks(io, gpa, dist_dir, options.target_name, .{
        .test_fail_execution = options.test_fail_publication_claims,
        .test_fail_write = options.test_fail_publication_claims_write,
    }) catch |err| {
        if (options.publication_claims_failure_writer) |writer| {
            writePublicationClaimsFailure(writer, options.target_name, err) catch {};
        } else if (!diag.text_suppressed.load(.unordered)) {
            const stderr = std.debug.lockStderr(&.{});
            defer std.debug.unlockStderr();
            writePublicationClaimsFailure(&stderr.file_writer.interface, options.target_name, err) catch {};
        }
        return error.PublicationClaimsFailed;
    };
    if (options.timings) |t| t.stop(.claims);

    // The Touch Atlas is derived from the exact committed artifacts, checks,
    // and claims bytes. A derivation, stale-binding, parser, I/O, or
    // atomic-write failure keeps the committed target, inventory, checks, and
    // claims and leaves any prior touches report untouched; the diagnostic is
    // emitted even under --quiet.
    if (options.timings) |t| t.start(.touches);
    publication_touches.writeAfterClaims(io, gpa, dist_dir, options.target_name, .{
        .test_fail_execution = options.test_fail_publication_touches,
        .test_fail_write = options.test_fail_publication_touches_write,
    }) catch |err| {
        if (options.publication_touches_failure_writer) |writer| {
            writePublicationTouchesFailure(writer, options.target_name, err) catch {};
        } else if (!diag.text_suppressed.load(.unordered)) {
            const stderr = std.debug.lockStderr(&.{});
            defer std.debug.unlockStderr();
            writePublicationTouchesFailure(&stderr.file_writer.interface, options.target_name, err) catch {};
        }
        return error.PublicationTouchesFailed;
    };
    if (options.timings) |t| t.stop(.touches);

    // The Proof Pack is the final presentation layer, derived exclusively
    // from the exact committed artifacts, checks, claims, and touches bytes.
    // A derivation, stale-binding, parser, render, I/O, or transaction
    // failure keeps the committed target and all four evidence reports and
    // restores (or explicitly reports) the prior presentation pair; the
    // diagnostic is emitted even under --quiet.
    if (options.timings) |t| t.start(.proof_pack);
    publication_proof_pack.writeAfterTouches(io, gpa, dist_dir, options.target_name, .{
        .test_fail_execution = options.test_fail_publication_proof_pack,
        .test_fail_json_tmp_write = options.test_fail_proof_pack_json_tmp_write,
        .test_fail_html_tmp_write = options.test_fail_proof_pack_html_tmp_write,
        .test_fail_preserve_prior = options.test_fail_proof_pack_preserve_prior,
        .test_fail_install_html = options.test_fail_proof_pack_install_html,
        .test_fail_install_json = options.test_fail_proof_pack_install_json,
        .test_fail_restore_html = options.test_fail_proof_pack_restore_html,
        .test_fail_restore_json = options.test_fail_proof_pack_restore_json,
    }) catch |err| {
        if (options.publication_proof_pack_failure_writer) |writer| {
            writePublicationProofPackFailure(writer, options.target_name, err) catch {};
        } else if (!diag.text_suppressed.load(.unordered)) {
            const stderr = std.debug.lockStderr(&.{});
            defer std.debug.unlockStderr();
            writePublicationProofPackFailure(&stderr.file_writer.interface, options.target_name, err) catch {};
        }
        return error.PublicationProofPackFailed;
    };
    if (options.timings) |t| t.stop(.proof_pack);

    // Persist reuse state so a later unchanged incremental build can skip the
    // chain above. Incremental-only, mirroring the .boris-cache write rule;
    // best-effort — no state simply means the next build re-derives.
    if (options.incremental) {
        publication_evidence_state.record(io, dist_dir, gpa, options.target_name, pipeline.compiler_id);
    }
}

const FingerprintPlan = struct {
    fingerprints: [][]const u8,
    is_dirty: []bool,

    fn deinit(self: *FingerprintPlan, gpa: std.mem.Allocator) void {
        for (self.fingerprints) |fp| {
            if (fp.len > 0) gpa.free(fp);
        }
        gpa.free(self.fingerprints);
        gpa.free(self.is_dirty);
    }
};

const PageFingerprint = struct {
    hex: []u8,
    hashed: u64,
};

fn fingerprintPage(
    gpa: std.mem.Allocator,
    page: DurablePage,
    page_idx: usize,
    options: CompileOptions,
    shared: *const SharedCompileState,
    page_layouts: []const assemble.Layout,
    page_sel_paths: []const []const u8,
    page_layout_bytes: []const []const u8,
    page_theme_material: []const []const u8,
    site: *const FrozenSite,
    heading_index: *wikilink.HeadingIndex,
    content_assets: *const content_asset.SiteAssetInventory,
    ref_node_map: *const wikilink.NodeMap,
) !PageFingerprint {
    // Convert owned []u8 include lists to []const u8 views for the hasher.
    const inc_owned = shared.include_bytes[page_idx];
    const inc_views = try gpa.alloc([]const u8, inc_owned.len);
    defer gpa.free(inc_views);
    for (inc_owned, 0..) |b, j| inc_views[j] = b;

    const page_layout = page_layouts[page_idx];
    // Graph chrome (nav, breadcrumb, title, children) depends on the frozen site.
    // `children` uses the same complete graph digest conservatively: it keeps
    // add/remove/rename/title changes correct across incremental runs.
    const needs_site_material = page_layout.has_nav or page_layout.has_breadcrumb or page_layout.has_title or page_layout.has_children;
    const nav_material: []const u8 = if (needs_site_material) site.site_nav_digest else "";
    var relation_material: []u8 = &.{};
    if (page_layout.has_relations or page_layout.has_backlinks) {
        const relation_index = site.indexOf(page.entity_id) orelse return error.GraphValidationFailed;
        relation_material = try html_relations.relationMaterial(
            gpa,
            site.nodes,
            relation_index,
            page_layout.has_relations,
            page_layout.has_backlinks,
        );
    }
    defer if (relation_material.len > 0) gpa.free(relation_material);
    // Wiki reference material from page body + transitive include fragment bodies
    // so title/path renames dirty parents that only wiki-link via includes.
    const body_for_wiki = include_mod.bodyOfSource(shared.source_bytes[page_idx]);
    // Scanners measure offsets in the body; the diagnostics contract
    // specifies the full-source line. Shift by the frontmatter.
    const fail_line_base = include_mod.lineBaseOfSource(shared.source_bytes[page_idx]);
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
    var wiki_fail: wikilink.FailInfo = .{ .line_base = fail_line_base };
    const ref_material = wikilink.referenceMaterialMultiWithMap(
        gpa,
        wiki_bodies,
        wiki_paths,
        ref_node_map,
        &wiki_fail,
        .{ .heading_index = heading_index, .validate_fragments = true },
    ) catch |err| {
        if (err == error.ReferenceMissing or err == error.ReferenceSyntax or err == error.PathError) {
            wikilink.printDiagnostic(gpa, err, page.source_path, wiki_fail, options.diagnostics);
            return error.ReferenceFailed;
        }
        return err;
    };
    defer gpa.free(ref_material);

    // Validate content-local Markdown images every build (even when HTML is
    // cached). Asset *bytes* are not fingerprint inputs: a byte-only change
    // republishes the file without re-rendering HTML.
    {
        var asset_fail: content_asset.FailInfo = .{ .line_base = fail_line_base };
        const rewritten = content_asset.rewriteImageLinks(
            gpa,
            body_for_wiki,
            &content_assets.pages[page_idx],
            page.output_path,
            &asset_fail,
            null,
        ) catch |err| {
            content_asset.printDiagnostic(gpa, err, page.source_path, asset_fail, options.diagnostics);
            return error.AssetFailed;
        };
        if (rewritten.ptr != body_for_wiki.ptr) gpa.free(rewritten);
    }

    var inc_with_ref = try gpa.alloc([]const u8, inc_views.len +
        (if (ref_material.len > 0) @as(usize, 1) else 0) +
        (if (relation_material.len > 0) @as(usize, 1) else 0));
    defer gpa.free(inc_with_ref);
    @memcpy(inc_with_ref[0..inc_views.len], inc_views);
    var inc_with_ref_count = inc_views.len;
    if (ref_material.len > 0) {
        inc_with_ref[inc_with_ref_count] = ref_material;
        inc_with_ref_count += 1;
    }
    if (relation_material.len > 0) {
        inc_with_ref[inc_with_ref_count] = relation_material;
    }

    // Fingerprint uses the effective selected layout identity and bytes.
    var fp_hashed: u64 = 0;
    const fp_bytes = cache.computePageFingerprintThemeInputCounted(
        options.target_name,
        page_sel_paths[page_idx],
        page.entity_id,
        shared.source_bytes[page_idx],
        inc_with_ref,
        page_layout_bytes[page_idx],
        nav_material,
        page_theme_material[page_idx],
        adapterIdentity(options.input_format),
        &fp_hashed,
    );
    const hex = try fingerprintHex(fp_bytes, gpa);
    return .{ .hex = hex, .hashed = fp_hashed };
}

fn pageOutputIsFresh(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
    page: DurablePage,
    options: CompileOptions,
    fingerprint: []const u8,
    selected_layout: []const u8,
    parsed_manifest: ?std.json.Parsed(ParsedCacheManifest),
) bool {
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
                    std.mem.eql(u8, entry.fingerprint, fingerprint) and
                    (entry.selected_layout.len == 0 or std.mem.eql(u8, entry.selected_layout, selected_layout)))
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
    return skip_render;
}

fn computeFingerprintsAndDirty(
    io: Io,
    gpa: std.mem.Allocator,
    db: *const PageDb,
    options: CompileOptions,
    shared: *const SharedCompileState,
    page_layouts: []const assemble.Layout,
    page_sel_paths: []const []const u8,
    page_layout_bytes: []const []const u8,
    page_theme_material: []const []const u8,
    site: *const FrozenSite,
    heading_index: *wikilink.HeadingIndex,
    content_assets: *const content_asset.SiteAssetInventory,
    dist_dir: Io.Dir,
    parsed_manifest: ?std.json.Parsed(ParsedCacheManifest),
) !FingerprintPlan {
    const fingerprints = try gpa.alloc([]const u8, db.len());
    for (fingerprints) |*fp| fp.* = &.{};
    errdefer {
        for (fingerprints) |fp| {
            if (fp.len > 0) gpa.free(fp);
        }
        gpa.free(fingerprints);
    }

    const is_dirty = try gpa.alloc(bool, db.len());
    @memset(is_dirty, false);
    errdefer gpa.free(is_dirty);

    if (options.timings) |t| t.start(.fingerprint);

    // One shared wiki id→node map for every page fingerprint (#727); the
    // per-page reference-material pass reuses it instead of rebuilding.
    var ref_node_map = try wikilink.buildNodeMap(gpa, site.nodes);
    defer ref_node_map.deinit(gpa);

    for (db.items(), 0..) |page, page_idx| {
        const fp = try fingerprintPage(
            gpa,
            page,
            page_idx,
            options,
            shared,
            page_layouts,
            page_sel_paths,
            page_layout_bytes,
            page_theme_material,
            site,
            heading_index,
            content_assets,
            &ref_node_map,
        );
        fingerprints[page_idx] = fp.hex;
        if (options.timings) |t| {
            // Exact payload bytes fed to the fingerprint hasher, including the
            // framed length prefixes and the Textile adapter marker, reported
            // by the counted cache variant so accounting cannot drift.
            t.bump(.hash_bytes, fp.hashed);
        }

        const skip_render = pageOutputIsFresh(
            io,
            gpa,
            dist_dir,
            page,
            options,
            fingerprints[page_idx],
            page_sel_paths[page_idx],
            parsed_manifest,
        );
        is_dirty[page_idx] = !skip_render;
        if (skip_render) {
            if (options.timings) |t| t.bump(.fast_path_hits, 1);
        }
    }
    if (options.timings) |t| t.stop(.fingerprint);

    // Fingerprints identify changed page inputs; the shared frozen reverse
    // dependency story expands those seeds to parent/reference dependents.
    // This happens before workers and mutates only coordinator-owned state.
    if (options.incremental) {
        try expandDirtySet(gpa, is_dirty, db.items(), site.nodes, &shared.dep_index);
    }

    return .{ .fingerprints = fingerprints, .is_dirty = is_dirty };
}

fn renderPages(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    stage_dir: Io.Dir,
    db: *PageDb,
    options: CompileOptions,
    page_layouts: []const assemble.Layout,
    is_dirty: []const bool,
    site: *const FrozenSite,
    heading_index: *wikilink.HeadingIndex,
    theme_bundle: *theme_mod.ThemeBundle,
    content_assets: *content_asset.SiteAssetInventory,
    include_cache: ?*include_mod.IncludeCache,
) !CompileStats {
    var stats: CompileStats = .{};

    if (options.timings) |t| t.start(.render);
    // Per-pass shared node maps (#726): workers/serial pages reuse them
    // read-only instead of rebuilding maps on every page.
    var shared_wiki_map = try buildSharedWikiNodeMap(gpa, site);
    defer if (shared_wiki_map) |*m| m.deinit(gpa);
    var shared_doclink_map = try buildSharedDoclinkNodeMap(gpa, site);
    defer if (shared_doclink_map) |*m| m.deinit(gpa);
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
            .shared_node_map = if (shared_wiki_map) |*m| m else null,
            .shared_doclink_map = if (shared_doclink_map) |*m| m else null,
            .heading_index = heading_index,
            .theme = theme_bundle,
            .content_assets = content_assets,
            .include_cache = include_cache,
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
                try renderAndPublishPage(
                    io,
                    gpa,
                    content_dir,
                    stage_dir,
                    page,
                    page_layouts[page_index],
                    &doc_arena,
                    options,
                    page_index,
                    .{
                        .site = site,
                        .shared_node_map = if (shared_wiki_map) |*m| m else null,
                        .shared_doclink_map = if (shared_doclink_map) |*m| m else null,
                        .heading_index = heading_index,
                        .theme = theme_bundle,
                        .page_assets = &content_assets.pages[page_index],
                        .include_cache = include_cache,
                    },
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
    if (options.timings) |t| {
        t.stop(.render);
        // Each rendered (dirty) page is read once by renderAndPublishPage.
        var rendered_reads: u64 = 0;
        for (is_dirty) |dirty| {
            if (dirty) rendered_reads += 1;
        }
        if (rendered_reads > 0) t.bump(.page_reads, rendered_reads);
    }

    return stats;
}

fn writeIncrementalCaches(
    io: Io,
    gpa: std.mem.Allocator,
    db: *const PageDb,
    options: CompileOptions,
    stage_dir: Io.Dir,
    dist_dir: Io.Dir,
    fingerprints: []const []const u8,
    page_sel_paths: []const []const u8,
    heading_snapshot: *const HeadingHarvestSnapshot,
) !void {
    if (!options.incremental) return;
    if (options.test_fail_cache_publish) return error.TestInjectedCachePublishFailure;

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
        else |_| if (readFileAlloc(io, dist_dir, page.output_path, gpa)) |b| b else |_| null;
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
    try writeCacheManifest(gpa, &m_writer.interface, .{
        .format_version = cache.CACHE_FORMAT_VERSION,
        .entries = cache_entries,
    });
    try m_writer.flush();

    try atomic_manifest.replace(io);

    // Persist heading harvest for the next incremental run (#58).
    {
        var atomic_hh = try stage_dir.createFileAtomic(io, ".boris-cache/heading-harvest.json", .{
            .replace = true,
            .make_path = true,
        });
        defer atomic_hh.deinit(io);
        var hh_buf: [4096]u8 = undefined;
        var hh_writer = atomic_hh.file.writer(io, &hh_buf);
        try writeHeadingHarvestCache(gpa, &hh_writer.interface, heading_snapshot.entries);
        try hh_writer.flush();
        try atomic_hh.replace(io);
    }
}

const SiteOverlay = struct {
    live_page_paths: [][]const u8,
    wke: ?standard_site_emit.WellKnownEmission,
    prior_emitted: bool,

    fn deinit(self: *SiteOverlay, gpa: std.mem.Allocator) void {
        gpa.free(self.live_page_paths);
        if (self.wke) |*w| w.deinit(gpa);
    }
};

fn writeSearchSitemapAndStandardSite(
    io: Io,
    gpa: std.mem.Allocator,
    db: *const PageDb,
    options: CompileOptions,
    stage_dir: Io.Dir,
    dist_dir: Io.Dir,
    prior_sitemap_marker_present: bool,
) !SiteOverlay {
    var live_page_paths = try gpa.alloc([]const u8, db.len());
    errdefer gpa.free(live_page_paths);
    for (db.items(), 0..) |page, page_idx| live_page_paths[page_idx] = page.output_path;

    // Search is public surface, so it obeys the same publication rule as the
    // sitemap below: a `status: draft` page is not advertised. It gets its own
    // slice rather than filtering `live_page_paths`, because the link audit
    // needs the *complete* output set.
    var search_page_paths: std.ArrayList([]const u8) = .empty;
    defer search_page_paths.deinit(gpa);
    try search_page_paths.ensureTotalCapacity(gpa, live_page_paths.len);
    for (db.items()) |page| {
        if (page.status == .draft) continue;
        search_page_paths.appendAssumeCapacity(page.output_path);
    }
    if (options.timings) |t| t.start(.search);
    try search_index.writeOverlay(io, gpa, stage_dir, dist_dir, search_page_paths.items, false);
    if (options.timings) |t| t.stop(.search);

    var sitemap_page_paths: std.ArrayList([]const u8) = .empty;
    defer sitemap_page_paths.deinit(gpa);
    if (options.sitemap_path) |sitemap_path| {
        for (db.items()) |page| {
            if (page.status == .draft) continue;
            try sitemap_page_paths.append(gpa, page.output_path);
        }
        try sitemap.writeOverlay(
            io,
            gpa,
            stage_dir,
            dist_dir,
            sitemap_path,
            options.site_url.?,
            sitemap_page_paths.items,
        );
        if (options.test_fail_after_sitemap_stage) return error.TestInjectedSitemapFailure;
    }
    if (options.sitemap_path != null or prior_sitemap_marker_present) {
        try stageSitemapOwnership(io, stage_dir, options.sitemap_path);
    }

    var wke: ?standard_site_emit.WellKnownEmission = null;
    errdefer if (wke) |*w| w.deinit(gpa);
    var prior_emitted = false;
    if (options.standard_site_verification) |ctx| {
        prior_emitted = (try standard_site_emit.readPriorOwnership(io, gpa, dist_dir)).emitted;
        wke = try standard_site_emit.writeWellKnownOverlay(io, gpa, stage_dir, ctx.surfaces);
        try standard_site_emit.stageOwnership(io, stage_dir, ctx.surfaces.well_known.emittable);
    }

    return .{ .live_page_paths = live_page_paths, .wke = wke, .prior_emitted = prior_emitted };
}

fn auditOutputLinks(
    io: Io,
    gpa: std.mem.Allocator,
    options: CompileOptions,
    stage_dir: Io.Dir,
    dist_dir: Io.Dir,
    live_page_paths: []const []const u8,
    theme_bundle: *const theme_mod.ThemeBundle,
    content_assets: *const content_asset.SiteAssetInventory,
) !void {
    var audit_assets: std.ArrayList([]const u8) = .empty;
    defer audit_assets.deinit(gpa);
    const audit_content_outs = try content_assets.collectOutputPaths(gpa);
    defer gpa.free(audit_content_outs);
    try audit_assets.appendSlice(gpa, audit_content_outs);
    for (theme_bundle.assets) |a| try audit_assets.append(gpa, a.rel_path);
    if (options.sitemap_path) |path| try audit_assets.append(gpa, path);

    var findings: std.ArrayList(link_audit.Finding) = .empty;
    defer link_audit.freeFindings(gpa, &findings);
    var link_audit_opts = link_audit.Options{
        .publication_location = options.publication_location,
        .allow_markdown_literals = options.allow_markdown_literals,
    };
    if (options.timings) |t| {
        link_audit_opts.resolution_counter = t.counterPtr(.link_resolutions);
        link_audit_opts.fast_path_counter = t.counterPtr(.fast_path_hits);
    }
    if (options.timings) |t| t.start(.link_audit);
    try link_audit.audit(io, gpa, stage_dir, dist_dir, live_page_paths, audit_assets.items, link_audit_opts, &findings);
    if (options.timings) |t| t.stop(.link_audit);
    if (findings.items.len != 0) return reportLinkAuditFindings(options.diagnostics, findings.items);
}

fn writeInventoryOverlay(
    io: Io,
    gpa: std.mem.Allocator,
    db: *const PageDb,
    options: CompileOptions,
    stage_dir: Io.Dir,
    dist_dir: Io.Dir,
    theme_bundle: *const theme_mod.ThemeBundle,
    content_assets: *const content_asset.SiteAssetInventory,
) !void {
    var inventory_specs: std.ArrayList(artifact_inventory.Spec) = .empty;
    defer inventory_specs.deinit(gpa);
    try inventory_specs.ensureTotalCapacity(
        gpa,
        db.len() + theme_bundle.assets.len + content_assets.pages.len + 2,
    );
    for (db.items()) |page| {
        try inventory_specs.append(gpa, .{
            .path = page.output_path,
            .kind = .html_page,
            .producer = "html-render",
            .required = true,
            .allow_live = true,
            // #752: a draft page is emitted but deliberately unadvertised.
            // The rendered-search check consumes this so its eligible subject
            // set mirrors the search producer's own filtered slice.
            .advertised = page.status != .draft,
        });
    }
    for (theme_bundle.assets) |asset| {
        try inventory_specs.append(gpa, .{
            .path = asset.rel_path,
            .kind = .theme_asset,
            .producer = "theme-assets",
            .required = true,
        });
    }
    for (content_assets.pages) |page_assets| {
        for (page_assets.entries) |asset| {
            try inventory_specs.append(gpa, .{
                .path = asset.output_rel,
                .kind = .content_asset,
                .producer = "content-assets",
                .required = true,
            });
        }
    }
    try inventory_specs.append(gpa, .{
        .path = search_index.output_path,
        .kind = .rendered_search,
        .producer = "rendered-search",
        .required = true,
        .format_version = "1",
    });
    if (options.sitemap_path) |sitemap_path| {
        try inventory_specs.append(gpa, .{
            .path = sitemap_path,
            .kind = .sitemap,
            .producer = "sitemap",
            .required = true,
            .format_version = "1",
        });
    }
    if (options.test_fail_before_inventory_write) return error.TestInjectedInventoryWriteFailure;
    if (options.timings) |t| t.start(.inventory);
    try artifact_inventory.writeOverlay(
        io,
        gpa,
        stage_dir,
        dist_dir,
        options.target_name,
        inventory_specs.items,
    );
    if (options.timings) |t| t.stop(.inventory);
}

fn commitStagedTree(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    stage_dir: Io.Dir,
    dist_dir: Io.Dir,
    prior_sitemap_path: ?[]const u8,
    sitemap_path: ?[]const u8,
    dist_dir_rel: []const u8,
) !void {
    // Move an obsolete compiler-owned sitemap aside immediately before commit.
    // A failed commit restores it; a successful commit removes the backup with
    // checked I/O rather than leaving best-effort post-commit debris.
    const sitemap_backup_rel = try std.fmt.allocPrint(gpa, "{s}.boris-sitemap-prev", .{dist_dir_rel});
    defer gpa.free(sitemap_backup_rel);
    var sitemap_backed_up = false;
    const sitemap_changed = if (prior_sitemap_path) |old|
        sitemap_path == null or !std.mem.eql(u8, old, sitemap_path.?)
    else
        false;
    if (sitemap_changed) {
        cwd.deleteFile(io, sitemap_backup_rel) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (dist_dir.statFile(io, prior_sitemap_path.?, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .sym_link) return error.TargetOutputSymlink;
            if (stat.kind != .file) return error.SitemapOwnershipCorrupt;
            try dist_dir.rename(prior_sitemap_path.?, cwd, sitemap_backup_rel, io);
            sitemap_backed_up = true;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    // Search, sitemap, and ownership metadata are members of the same staged
    // target commit as HTML.
    publishStageTree(io, gpa, stage_dir, dist_dir, artifact_inventory.output_path) catch |err| {
        if (sitemap_backed_up) {
            try cwd.rename(sitemap_backup_rel, dist_dir, prior_sitemap_path.?, io);
        }
        return err;
    };
    if (sitemap_backed_up) try cwd.deleteFile(io, sitemap_backup_rel);
}

fn publishStandardSiteReport(
    io: Io,
    gpa: std.mem.Allocator,
    db: *const PageDb,
    dist_dir: Io.Dir,
    page_layouts: []const assemble.Layout,
    ctx: *const standard_site_emit.VerificationContext,
    wke: *const standard_site_emit.WellKnownEmission,
    prior_emitted: bool,
) !void {
    if (prior_emitted and !ctx.surfaces.well_known.emittable) {
        dist_dir.deleteFile(io, standard_site.well_known_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    var doc_emissions: std.ArrayList(standard_site_emit.DocumentEmission) = .empty;
    defer {
        for (doc_emissions.items) |d| d.deinit(gpa);
        doc_emissions.deinit(gpa);
    }
    for (db.items(), 0..) |p, i| {
        const at_uri = standard_site_emit.documentAtUri(gpa, ctx.surfaces, p.entity_id) orelse continue;
        try doc_emissions.append(gpa, .{
            .entity_id = try gpa.dupe(u8, p.entity_id),
            .at_uri = try gpa.dupe(u8, at_uri),
            .status = if (page_layouts[i].has_head) .emitted else .not_verified,
        });
    }
    const report_json = try standard_site_emit.renderReport(gpa, wke, doc_emissions.items);
    defer gpa.free(report_json);
    try standard_site_emit.writeReport(io, dist_dir, report_json);
}

fn cleanupStaleOutputs(
    io: Io,
    gpa: std.mem.Allocator,
    dist_dir: Io.Dir,
    db: *const PageDb,
    options: CompileOptions,
    theme_bundle: *const theme_mod.ThemeBundle,
    content_assets: *const content_asset.SiteAssetInventory,
    theme_root: []const u8,
    parsed_manifest: ?std.json.Parsed(ParsedCacheManifest),
) !void {
    // Live page-output set for this build. Shared by stale cleanup AND the theme
    // scrub below, so a page published under `assets/` is never mistaken for an
    // orphan theme asset.
    var live_paths: std.StringHashMapUnmanaged(void) = .{};
    defer live_paths.deinit(gpa);
    for (db.items()) |p| {
        try live_paths.put(gpa, p.output_path, {});
    }
    if (options.sitemap_path) |path| try live_paths.put(gpa, path, {});

    if (parsed_manifest) |pm| {
        for (pm.value.entries) |entry| {
            if (!live_paths.contains(entry.output_path)) {
                dist_dir.deleteFile(io, entry.output_path) catch {};
            }
        }
    } else if (!options.incremental) {
        // Full rebuild: remove html outputs under dist that are not in this build.
        // Skip live theme-owned assets (e.g. assets/embed.html): copyAssetsToOutput
        // publishes them into dist/, and they are not page outputs. Orphan theme
        // assets are handled by scrubOrphanThemeAssets below (#61).
        // Skip content-local `*.assets/**` files (including .html embeds).
        var theme_html_assets: std.StringHashMapUnmanaged(void) = .{};
        defer theme_html_assets.deinit(gpa);
        for (theme_bundle.assets) |a| {
            if (std.mem.endsWith(u8, a.rel_path, ".html")) {
                try theme_html_assets.put(gpa, a.rel_path, {});
            }
        }
        var content_html_assets: std.StringHashMapUnmanaged(void) = .{};
        defer content_html_assets.deinit(gpa);
        for (content_assets.pages) |page_bundle| {
            for (page_bundle.entries) |e| {
                if (std.mem.endsWith(u8, e.output_rel, ".html")) {
                    try content_html_assets.put(gpa, e.output_rel, {});
                }
            }
        }
        var walker = try dist_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".html")) continue;
            if (std.mem.startsWith(u8, entry.path, ".boris-cache")) continue;
            if (theme_html_assets.contains(entry.path)) continue;
            if (content_html_assets.contains(entry.path)) continue;
            if (content_asset.isContentLocalOutputPath(entry.path)) continue;
            // The Proof Pack presentation pair is a committed generation,
            // not a stale page output: the pair transaction snapshots the
            // exact prior state and restores it on failure, so the walker
            // must never delete `index.html` out from under it.
            if (std.mem.eql(u8, entry.path, artifact_inventory.proof_index_output_path)) continue;
            if (!live_paths.contains(entry.path)) {
                dist_dir.deleteFile(io, entry.path) catch {};
            }
        }
    }

    // F9.2: when a managed theme owns `assets/`, drop files removed or renamed
    // in the theme inventory so prior dist does not retain orphans — but never a
    // live page output published under assets/.
    if (theme_root.len > 0) {
        theme_mod.scrubOrphanThemeAssets(io, dist_dir, gpa, theme_bundle.assets, &live_paths);
    }

    // Content-local sibling assets: drop removed/renamed files under `*.assets/`.
    // Theme-owned `assets/` is never touched.
    content_asset.scrubOrphanContentAssets(io, dist_dir, gpa, content_assets);
}

const HeadingIndexes = struct {
    index: wikilink.HeadingIndex,
    snapshot: HeadingHarvestSnapshot,

    fn deinit(self: *HeadingIndexes, gpa: std.mem.Allocator) void {
        self.index.deinit(gpa);
        self.snapshot.deinit();
    }
};

fn runHeadingHarvest(
    io: Io,
    gpa: std.mem.Allocator,
    content_dir: Io.Dir,
    db: *const PageDb,
    options: CompileOptions,
    shared: *const SharedCompileState,
    site: *const FrozenSite,
    parsed_heading_harvest: ?std.json.Parsed(ParsedHeadingHarvest),
    include_cache: ?*include_mod.IncludeCache,
) !HeadingIndexes {
    // Heading id index for wiki `[[entity#heading]]` (Oliver-rendered ids only;
    // only pages that are fragment targets are rendered for the index).
    // Incremental: reuse harvest-cache hits so no-op builds skip rendering (#58).
    const prior_harvest: ?*const ParsedHeadingHarvest = if (parsed_heading_harvest) |*ph| &ph.value else null;
    if (options.timings) |t| t.start(.heading_harvest);
    const heading_built = try buildSiteHeadingIndex(
        io,
        gpa,
        content_dir,
        db,
        site,
        shared,
        options.input_format,
        prior_harvest,
        options.timings,
        options.diagnostics,
        include_cache,
    );
    if (options.timings) |t| t.stop(.heading_harvest);
    return .{ .index = heading_built[0], .snapshot = heading_built[1] };
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

    var layout_arena_local = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena_local.deinit();
    var layouts = try preparePageLayouts(io, gpa, cwd, db, layout, options, layout_bytes, layout_arena_local.allocator());
    defer layouts.deinit(gpa, layout_bytes);

    const layouts_by_path = &layouts.layouts_by_path;
    const page_sel_paths = layouts.page_sel_paths;
    const page_layouts = layouts.page_layouts;
    const page_layout_bytes = layouts.page_layout_bytes;

    try validateVerificationSurfaces(gpa, db, layouts.page_layouts, layouts.page_sel_paths, options);

    var theme_bundle = try prepareThemeBundle(io, gpa, cwd, db, options, layouts_by_path);
    defer theme_bundle.deinit();
    var content_assets = try discoverContentAssets(io, gpa, content_dir, db, options, &theme_bundle);
    defer content_assets.deinit();
    const page_theme_material = try prepareThemeMaterial(gpa, db, layouts_by_path, &theme_bundle, page_sel_paths);
    defer gpa.free(page_theme_material);
    const theme_root = theme_mod.themeRootFromLayoutPath(options.layout_path) orelse "";

    // Own shared state when the caller did not supply one (single-target).
    var local_shared: ?SharedCompileState = null;
    defer if (local_shared) |*s| s.deinit();
    const shared: *const SharedCompileState = if (shared_opt) |s| s else blk: {
        local_shared = try SharedCompileState.init(io, gpa, db, options.content_root, options.quiet, options.input_format, options.timings, options.diagnostics);
        break :blk &(local_shared.?);
    };

    // One include expansion memo per target compile (#760): heading harvest,
    // validation, and render workers share it so each unique fragment is read
    // and expanded once. Safe for concurrent workers (internal locking); it
    // must outlive every page render below.
    var include_cache = include_mod.IncludeCache.init(gpa);
    defer include_cache.deinit();

    if (options.validation_only) {
        return validatePrepublicationTarget(
            io,
            gpa,
            content_dir,
            db,
            page_layouts,
            options,
            shared,
            site,
            &theme_bundle,
            &content_assets,
            &include_cache,
        );
    }

    // Publication begins here. No code above this boundary creates, removes,
    // or mutates the selected target or sibling staging tree.
    try cwd.createDirPath(io, options.dist_dir);
    // Re-check for symlink swap after validation (TOCTOU shrink — issue #11).
    try target_mod.rejectSymlinkAlongPath(io, cwd, gpa, options.dist_dir);
    var dist_dir = try cwd.openDir(io, options.dist_dir, .{ .iterate = true });
    defer dist_dir.close(io);

    var prior_sitemap = try readPriorSitemapOwnership(io, gpa, dist_dir);
    defer prior_sitemap.deinit(gpa);

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

    // Assets are target-owned members of the same staging transaction.
    try theme_mod.copyAssetsToOutput(io, stage_dir, theme_bundle.assets);
    try content_asset.copyAssetsToOutput(io, stage_dir, &content_assets);

    var cache_state = loadIncrementalCacheState(io, gpa, dist_dir, options.incremental);
    defer cache_state.deinit(gpa);

    var heading_indexes = try runHeadingHarvest(io, gpa, content_dir, db, options, shared, site, cache_state.parsed_heading_harvest, &include_cache);
    defer heading_indexes.deinit(gpa);

    // Precreate output directories under staging
    {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(gpa);
        try paths.ensureTotalCapacity(gpa, db.len());
        for (db.items()) |p| try paths.append(gpa, p.output_path);
        try assemble.precreateOutputDirs(io, stage_dir, gpa, paths.items);
    }

    var fp_plan = try computeFingerprintsAndDirty(
        io,
        gpa,
        db,
        options,
        shared,
        page_layouts,
        page_sel_paths,
        page_layout_bytes,
        page_theme_material,
        site,
        &heading_indexes.index,
        &content_assets,
        dist_dir,
        cache_state.parsed_manifest,
    );
    defer fp_plan.deinit(gpa);
    const fingerprints = fp_plan.fingerprints;
    const is_dirty = fp_plan.is_dirty;

    const stats = try renderPages(
        io,
        gpa,
        content_dir,
        stage_dir,
        db,
        options,
        page_layouts,
        is_dirty,
        site,
        &heading_indexes.index,
        &theme_bundle,
        &content_assets,
        &include_cache,
    );

    try writeIncrementalCaches(
        io,
        gpa,
        db,
        options,
        stage_dir,
        dist_dir,
        fingerprints,
        page_sel_paths,
        &heading_indexes.snapshot,
    );

    var site_overlay = try writeSearchSitemapAndStandardSite(io, gpa, db, options, stage_dir, dist_dir, prior_sitemap.marker_present);
    defer site_overlay.deinit(gpa);
    try auditOutputLinks(io, gpa, options, stage_dir, dist_dir, site_overlay.live_page_paths, &theme_bundle, &content_assets);
    try writeInventoryOverlay(io, gpa, db, options, stage_dir, dist_dir, &theme_bundle, &content_assets);

    try commitStagedTree(io, gpa, cwd, stage_dir, dist_dir, prior_sitemap.path, options.sitemap_path, options.dist_dir);

    // Standard.site verification evidence, derived from the exact committed
    // bytes and written post-commit like the other proof artifacts.
    if (options.standard_site_verification) |ctx| {
        try publishStandardSiteReport(io, gpa, db, dist_dir, page_layouts, ctx, &site_overlay.wke.?, site_overlay.prior_emitted);
    }

    try cleanupStaleOutputs(io, gpa, dist_dir, db, options, &theme_bundle, &content_assets, theme_root, cache_state.parsed_manifest);

    // Drop staging tree (errdefer also cleans on earlier failure).
    cwd.deleteTree(io, stage_rel) catch {};

    try publishEvidenceReports(io, gpa, dist_dir, options);

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
        _ = try render.render(md, &arena);
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
        _ = try render.render(md.items, &arena);
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

fn readArtifactInventory(io: Io, gpa: std.mem.Allocator, dist_dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_dir, artifact_inventory.output_path });
    defer gpa.free(path);
    return readFileAlloc(io, Io.Dir.cwd(), path, gpa);
}

fn readTargetPayload(io: Io, gpa: std.mem.Allocator, dist_dir: []const u8, path: []const u8) ![]u8 {
    const full_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_dir, path });
    defer gpa.free(full_path);
    return readFileAlloc(io, Io.Dir.cwd(), full_path, gpa);
}

fn findArtifactRecord(root: std.json.Value, path: []const u8) ?std.json.Value {
    const artifacts = root.object.get("artifacts") orelse return null;
    for (artifacts.array.items) |record| {
        if (std.mem.eql(u8, record.object.get("path").?.string, path)) return record;
    }
    return null;
}

fn expectArtifactRecord(
    root: std.json.Value,
    path: []const u8,
    kind: []const u8,
    producer: []const u8,
    payload: []const u8,
) !void {
    const record = findArtifactRecord(root, path) orelse return error.MissingArtifactRecord;
    const object = record.object;
    try std.testing.expectEqualStrings(kind, object.get("kind").?.string);
    try std.testing.expectEqualStrings(producer, object.get("producer").?.string);
    try std.testing.expect(object.get("required").?.bool);
    try std.testing.expectEqualStrings("committed", object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), object.get("bytes").?.integer);
    const digest = cache.hexDigest(cache.hashBytes(payload));
    try std.testing.expectEqualStrings(&digest, object.get("sha256").?.string);
}

fn expectArtifactInventoryShape(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    target: []const u8,
    expected_paths: []const []const u8,
    absent_paths: []const []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(artifact_inventory.artifact_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, artifact_inventory.schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings(target, root.get("target").?.string);
    const artifacts = root.get("artifacts").?.array;
    try std.testing.expectEqual(expected_paths.len, artifacts.items.len);
    for (expected_paths) |path| try std.testing.expect(findArtifactRecord(parsed.value, path) != null);
    for (absent_paths) |path| try std.testing.expect(findArtifactRecord(parsed.value, path) == null);
    for (artifacts.items, 0..) |record, index| {
        try std.testing.expect(std.mem.indexOf(u8, record.object.get("path").?.string, ".boris-stage") == null);
        if (index > 0) {
            const previous = artifacts.items[index - 1].object.get("path").?.string;
            const current = record.object.get("path").?.string;
            try std.testing.expect(std.mem.order(u8, previous, current) != .gt);
        }
    }
}

fn expectPublicationChecksShape(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    target: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(publication_checks.report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, publication_checks.schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings(target, root.get("target").?.string);
    const checks = root.get("checks").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), checks.len);
    try std.testing.expectEqualStrings("artifact-integrity", checks[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("rendered-html", checks[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("rendered-search", checks[2].object.get("id").?.string);
    for (checks) |check| {
        try std.testing.expectEqualStrings("passed", check.object.get("status").?.string);
        try std.testing.expectEqualStrings("complete", check.object.get("coverage").?.string);
    }
    try std.testing.expectEqual(@as(usize, 0), root.get("findings").?.array.items.len);
}

test "experimental flag is true (HTML path not default product)" {
    try std.testing.expect(experimental);
}

test "Textile adapter feeds the existing Oliver HTML path deterministically" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    try writeTreeFile(io, root, "layout.html", "<!doctype html><main>{{content}}</main>\n");
    const layout = try std.fmt.allocPrint(gpa, "{s}/layout.html", .{root});
    defer gpa.free(layout);
    const sequential = try std.fmt.allocPrint(gpa, "{s}/sequential", .{root});
    defer gpa.free(sequential);
    const parallel = try std.fmt.allocPrint(gpa, "{s}/parallel", .{root});
    defer gpa.free(parallel);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .jobs = 1,
        .incremental = true,
        .input_format = .textile,
    });
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .dist_dir = parallel,
        .layout_path = layout,
        .quiet = true,
        .jobs = 2,
        .input_format = .textile,
    });

    var sequential_dir = try Io.Dir.cwd().openDir(io, sequential, .{});
    defer sequential_dir.close(io);
    var parallel_dir = try Io.Dir.cwd().openDir(io, parallel, .{});
    defer parallel_dir.close(io);
    const html = try readAllFile(io, sequential_dir, "index.html", gpa);
    defer gpa.free(html);
    const html_parallel = try readAllFile(io, parallel_dir, "index.html", gpa);
    defer gpa.free(html_parallel);
    try std.testing.expectEqualStrings(html, html_parallel);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>strong</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ins>inserted</ins>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<blockquote>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ol") != null);

    const no_op = try compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .jobs = 1,
        .incremental = true,
        .input_format = .textile,
    });
    try std.testing.expectEqual(@as(usize, 0), no_op.pages_written);

    try std.testing.expectError(error.TextileFailed, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/invalid/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .input_format = .textile,
    }));
    try std.testing.expectError(error.InputFormatMismatch, compileHtmlSite(io, gpa, .{
        .content_root = "docs/contracts/fixtures/textile-compatibility/mixed/content",
        .dist_dir = sequential,
        .layout_path = layout,
        .quiet = true,
        .input_format = .textile,
    }));
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

test "#421: broken layout surfaces a structured ELAYOUTDUPLICATEMARKER diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-421-layout", .{tmp.sub_path});
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

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    try std.testing.expectError(error.LayoutDuplicateMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    }));

    try std.testing.expectEqual(@as(usize, 1), collector.list.items.len);
    const d = collector.list.items[0];
    try std.testing.expectEqual(diag.Code.ELAYOUTDUPLICATEMARKER, d.code);
    try std.testing.expectEqual(diag.Severity.error_, d.severity);
    try std.testing.expectEqualStrings(layout_path, d.source_path);
    try std.testing.expect(d.line == null);
}

test "#737: unknown layout marker enumerates the closed slot set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-737-layout", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<a>{{nosuchslot}}</a>{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    try std.testing.expectError(error.LayoutUnknownMarker, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    }));

    try std.testing.expectEqual(@as(usize, 1), collector.list.items.len);
    const d = collector.list.items[0];
    try std.testing.expectEqual(diag.Code.ELAYOUTUNKNOWNMARKER, d.code);
    // Every accepted marker is named so the valid set is discoverable (#737).
    inline for (.{ "{{content}}", "{{nav}}", "{{breadcrumb}}", "{{title}}", "{{toc}}", "{{children}}", "{{metadata}}", "{{relations}}", "{{backlinks}}", "{{footer}}", "{{head}}", "{{asset-url" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, d.remediation, marker) != null);
    }
}

test "#421: content failures are collected with source path and position" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-421-content", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n\n{{include missing.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    try std.testing.expectError(error.IncludeFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    }));

    try std.testing.expectEqual(@as(usize, 1), diag.countErrors(collector.list.items));
    const d = for (collector.list.items) |item| {
        if (item.code == .EINCLUDEMISSING) break item;
    } else return error.TestExpectedEqual;
    // Source paths are content-root-relative (the stderr contract).
    try std.testing.expectEqualStrings("index.md", d.source_path);
    try std.testing.expect(d.line != null);
    try std.testing.expect(d.column != null);
}

test "#395: rule-selected layout emits an info ILAYOUTSELECTED outcome finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-395-layout-outcome", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "layouts/home.html", "HOME-{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Hi\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const home_path = try std.fmt.allocPrint(gpa, "{s}/layouts/home.html", .{work});
    defer gpa.free(home_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &.{
            .{ .kind = .id, .value = "index", .layout_path = home_path },
        },
        .quiet = true,
        .diagnostics = &collector,
    });

    // Exactly one finding: the rule-selected page. This fixture has no fallback page.
    try std.testing.expectEqual(@as(usize, 1), collector.list.items.len);
    const d = collector.list.items[0];
    try std.testing.expectEqual(diag.Code.ILAYOUTSELECTED, d.code);
    try std.testing.expectEqual(diag.Severity.info, d.severity);
    try std.testing.expectEqualStrings("index.md", d.source_path);
    try std.testing.expectEqualStrings("index", d.id);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "id:index") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "layouts/home.html") != null);
}

test "#557: fallback layout winners emit ILAYOUTSELECTED" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-557-layout-fallback", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "layouts/home.html", "HOME-{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    try writeTreeFile(io, work, "content/about.md", "---\nid: about\n---\n# About\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const home_path = try std.fmt.allocPrint(gpa, "{s}/layouts/home.html", .{work});
    defer gpa.free(home_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &.{
            .{ .kind = .id, .value = "index", .layout_path = home_path },
        },
        .quiet = true,
        .diagnostics = &collector,
    });

    try std.testing.expectEqual(@as(usize, 2), collector.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(collector.list.items));
    try std.testing.expectEqual(diag.Code.ILAYOUTSELECTED, collector.list.items[0].code);
    try std.testing.expectEqual(diag.Code.ILAYOUTSELECTED, collector.list.items[1].code);
    try std.testing.expectEqual(diag.Severity.info, collector.list.items[0].severity);
    var saw_rule = false;
    var saw_fallback = false;
    for (collector.list.items) |d| {
        if (std.mem.eql(u8, d.source_path, "index.md")) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "id:index") != null);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "layouts/home.html") != null);
            saw_rule = true;
        } else if (std.mem.eql(u8, d.source_path, "about.md")) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "layout fallback selected") != null);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "layouts/main.html") != null);
            try std.testing.expectEqualStrings("about", d.id);
            saw_fallback = true;
        }
    }
    try std.testing.expect(saw_rule);
    try std.testing.expect(saw_fallback);
}

test "#557: rule-less sites emit no ILAYOUTSELECTED" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-557-layout-ruleless", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "{{content}}");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    try writeTreeFile(io, work, "content/about.md", "---\nid: about\n---\n# About\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .diagnostics = &collector,
    });

    try std.testing.expectEqual(@as(usize, 0), collector.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(collector.list.items));
}

test "#448: xhtml target emits a well-formed document and fails closed on raw HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-448-xhtml", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const xhtml_layout =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<html xmlns="http://www.w3.org/1999/xhtml"><head><title>X</title></head><body>{{content}}</body></html>
    ;
    try writeTreeFile(io, work, "layouts/xhtml.html", xhtml_layout);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nHello **world**.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/xhtml.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // 1. Happy path: XHTML profile + declaration-bearing layout → document starts
    // with the XML declaration and carries the xmlns wrapper.
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .output_profile = .xhtml,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const got = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "<?xml version=\"1.0\" encoding=\"utf-8\"?>"));
    try std.testing.expect(std.mem.indexOf(u8, got, "xmlns=\"http://www.w3.org/1999/xhtml\"") != null);
    // Fragment body: heading ids are plain XML-legal attributes, list items
    // are well-formed block elements.
    try std.testing.expect(std.mem.indexOf(u8, got, "<h1 id=\"home\">Home</h1>") != null);

    // 2. Fail closed: verbatim raw HTML on an XHTML target is a hard error.
    try writeTreeFile(io, work, "content/raw.md", "before <em>raw</em> after\n");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\n[[raw]]\n");
    try std.testing.expectError(error.RawHtmlNotXmlWellFormed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .output_profile = .xhtml,
        .quiet = true,
    }));

    // 3. The same raw content renders under the default HTML profile.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
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
    // Expected = prefix + Oliver(body) + suffix (no mega-string in product path;
    // test builds the oracle the same way for equality only).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body_html = try render.render("# Home\n\nHello **world**.\n", &arena);
    const expected = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ layout.prefix, body_html.bytes, layout.suffix });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, got);
}

test "--timings recorder observes HTML publication phases" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-timings-html", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Timed\n\nPage **body**.\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var recorder = timings.Recorder.init(io);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .timings = &recorder,
    });

    // Every HTML publication phase ran and recorded elapsed time.
    const phases = [_]timings.Phase{
        .scan,            .parse,       .graph_validate, .dependency_resolve,
        .heading_harvest, .fingerprint, .render,         .search,
        .link_audit,      .inventory,   .checks,         .claims,
        .touches,         .proof_pack,
    };
    for (phases) |phase| {
        try std.testing.expect(
            recorder.phase_ns[@intFromEnum(phase)] > 0,
        );
    }
    // One page: load/parse read, shared-state read, render read.
    try std.testing.expect(recorder.counters[@intFromEnum(timings.Counter.page_reads)] >= 3);
    try std.testing.expect(recorder.counters[@intFromEnum(timings.Counter.hash_bytes)] > 0);
}

test "--timings include_reads counts each unique fragment once per build (#760)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-include-memo", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/includes/shared.md", "SHARED_FRAGMENT\n");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\n{{include includes/shared.md}}\n");
    try writeTreeFile(io, work, "content/guides/a.md", "# A\n\n{{include includes/shared.md}}\n");
    try writeTreeFile(io, work, "content/guides/b.md", "# B\n\n{{include includes/shared.md}}\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    var recorder = timings.Recorder.init(io);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .timings = &recorder,
    });

    // Three consumer pages share one fragment: exactly one read (#760), and
    // every rendered page still carries the expanded fragment bytes.
    try std.testing.expectEqual(@as(u64, 1), recorder.counters[@intFromEnum(timings.Counter.include_reads)]);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    for ([_][]const u8{ "index.html", "guides/a.html", "guides/b.html" }) |out| {
        const page = try readAllFile(io, dist_dir, out, gpa);
        defer gpa.free(page);
        try std.testing.expect(std.mem.indexOf(u8, page, "SHARED_FRAGMENT") != null);
    }
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
    }, 0, .{});
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

test "B-02 regression: failed rebuild preserves prior assets/0123456789abcdef and assets/worker.tmp" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-b02-rebuild-preserve-assets", .{tmp.sub_path});
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

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });

    try writeTreeFile(io, work, "dist/assets/0123456789abcdef", "legitimate-asset-hex-data");
    try writeTreeFile(io, work, "dist/assets/worker.tmp", "legitimate-asset-tmp-data");

    // Second build fails (injected publish failure).
    try std.testing.expectError(error.TestInjectedWriteFailure, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .test_fail_publish_at = 0,
    }));

    var dist_dir = try cwd.openDir(io, dist, .{ .iterate = true });
    defer dist_dir.close(io);

    const hex_asset = try readAllFile(io, dist_dir, "assets/0123456789abcdef", gpa);
    defer gpa.free(hex_asset);
    try std.testing.expectEqualStrings("legitimate-asset-hex-data", hex_asset);

    const tmp_asset = try readAllFile(io, dist_dir, "assets/worker.tmp", gpa);
    defer gpa.free(tmp_asset);
    try std.testing.expectEqualStrings("legitimate-asset-tmp-data", tmp_asset);
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

test "HTML path emits deterministic escaped direct children with selected layouts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-children-slot", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<main data-layout=\"fallback\">{{content}}</main>");
    try writeTreeFile(io, work, "layouts/trunk.html", "<main data-layout=\"trunk\">{{children}}{{content}}</main>");
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Parent\n---\n\n# Parent\n");
    // Discovery order is deliberately opposite canonical entity-id order.
    try writeTreeFile(io, work, "content/zeta.md", "---\nparent: index\n---\n\n# Zeta\n");
    try writeTreeFile(io, work, "content/alpha.md", "---\ntitle: A & <Alpha>\nparent: index\n---\n\n# Alpha\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const trunk_layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/trunk.html", .{work});
    defer gpa.free(trunk_layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const rules = [_]layout_select.LayoutRule{.{ .kind = .role, .value = "trunk", .layout_path = trunk_layout_path }};

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const parent = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(parent);
    const alpha = try readAllFile(io, dist_dir, "alpha.html", gpa);
    defer gpa.free(alpha);
    const zeta = try readAllFile(io, dist_dir, "zeta.html", gpa);
    defer gpa.free(zeta);

    try std.testing.expect(std.mem.indexOf(u8, parent, "data-layout=\"trunk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "page-children") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "href=\"alpha.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "A &amp; &lt;Alpha&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "href=\"zeta.html\">zeta") != null);
    const alpha_at = std.mem.indexOf(u8, parent, "alpha.html").?;
    const zeta_at = std.mem.indexOf(u8, parent, "zeta.html").?;
    try std.testing.expect(alpha_at < zeta_at);
    // Satellites select the fallback layout and never receive a children fragment.
    try std.testing.expect(std.mem.indexOf(u8, alpha, "data-layout=\"fallback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "page-children") == null);
    try std.testing.expect(std.mem.indexOf(u8, zeta, "page-children") == null);

    // A child label change must re-render its parent slot. The existing frozen
    // reverse-dependency expansion is deliberately conservative for graph edits.
    try writeTreeFile(io, work, "content/alpha.md", "---\ntitle: Alpha Updated\nparent: index\n---\n\n# Alpha\n");
    const incremental = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), incremental.pages_written);
    const updated_parent = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(updated_parent);
    try std.testing.expect(std.mem.indexOf(u8, updated_parent, "Alpha Updated") != null);
}

test "HTML semantic relation and backlink slots use canonical nested hrefs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-semantic-html", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "theme/layouts/main.html", "<main>{{content}}</main>");
    try writeTreeFile(io, work, "theme/layouts/relations.html", "<main>{{relations}}{{backlinks}}{{content}}</main>");
    try writeTreeFile(io, work, "content/guides/source.md", "---\ntitle: Source\nrelations: [supersedes=reference/spec, verified_by=reference/spec]\n---\n\n# Source\n");
    try writeTreeFile(io, work, "content/reference/spec.md", "---\ntitle: Specification\n---\n\n# Spec\n");
    try writeTreeFile(io, work, "content/control.md", "---\ntitle: Control\n---\n\n# Control\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const relation_layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/relations.html", .{work});
    defer gpa.free(relation_layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "guides/source", .layout_path = relation_layout_path },
        .{ .kind = .id, .value = "reference/spec", .layout_path = relation_layout_path },
    };

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const source = try readAllFile(io, dist_dir, "guides/source.html", gpa);
    defer gpa.free(source);
    const spec = try readAllFile(io, dist_dir, "reference/spec.html", gpa);
    defer gpa.free(spec);
    const control = try readAllFile(io, dist_dir, "control.html", gpa);
    defer gpa.free(control);
    try std.testing.expect(std.mem.indexOf(u8, source, "semantic-relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-relation-kind=\"supersedes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "href=\"../reference/spec.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "semantic-backlinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "data-relation-kind=\"verified_by\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "href=\"../guides/source.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, control, "semantic-relations") == null);
    try std.testing.expect(std.mem.indexOf(u8, control, "semantic-backlinks") == null);
}

test "incremental semantic backlink material dirties only affected relation pages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-semantic-fp", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "theme/layouts/main.html", "<main>{{content}}</main>");
    try writeTreeFile(io, work, "theme/layouts/relations.html", "<main>{{relations}}{{backlinks}}{{content}}</main>");
    try writeTreeFile(io, work, "content/guides/source.md", "---\ntitle: Source\nrelations: [verified_by=reference/spec]\n---\n\n# Source\n");
    try writeTreeFile(io, work, "content/reference/spec.md", "---\ntitle: Specification\n---\n\n# Spec\n");
    try writeTreeFile(io, work, "content/control.md", "---\ntitle: Control\n---\n\n# Control\n");

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const relation_layout_path = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/relations.html", .{work});
    defer gpa.free(relation_layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "guides/source", .layout_path = relation_layout_path },
        .{ .kind = .id, .value = "reference/spec", .layout_path = relation_layout_path },
    };
    const options: CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .layout_rules = &rules,
        .incremental = true,
        .quiet = true,
    };

    try std.testing.expectEqual(@as(usize, 3), (try compileHtmlSite(io, gpa, options)).pages_written);
    try std.testing.expectEqual(@as(usize, 0), (try compileHtmlSite(io, gpa, options)).pages_written);
    try writeTreeFile(io, work, "content/guides/source.md", "---\ntitle: Source\nrelations: [validated_by=reference/spec]\n---\n\n# Source\n");
    try std.testing.expectEqual(@as(usize, 2), (try compileHtmlSite(io, gpa, options)).pages_written);
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

test "html fixture golden: documentation links and local assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-doc-links-golden", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const first_dist = try std.fmt.allocPrint(gpa, "{s}/first", .{work});
    defer gpa.free(first_dist);
    const second_dist = try std.fmt.allocPrint(gpa, "{s}/second", .{work});
    defer gpa.free(second_dist);
    const content = "test/fixtures/doc-links/content";
    const layout = "test/fixtures/doc-links/layouts/main.html";
    const expected = "test/fixtures/doc-links/expected";
    const expected_files = [_][]const u8{
        "index.html",
        "reference.html",
        "guides/start.html",
        "guides/start.assets/diagram.svg",
    };

    const first_stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = first_dist,
        .layout_path = layout,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), first_stats.pages_written);

    const second_stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = second_dist,
        .layout_path = layout,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), second_stats.pages_written);

    var first_dir = try cwd.openDir(io, first_dist, .{});
    defer first_dir.close(io);
    var second_dir = try cwd.openDir(io, second_dist, .{});
    defer second_dir.close(io);
    var expected_dir = try cwd.openDir(io, expected, .{});
    defer expected_dir.close(io);

    for (expected_files) |rel| {
        const got_first = try readAllFile(io, first_dir, rel, gpa);
        defer gpa.free(got_first);
        const got_second = try readAllFile(io, second_dir, rel, gpa);
        defer gpa.free(got_second);
        const want = try readAllFile(io, expected_dir, rel, gpa);
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, got_first);
        try std.testing.expectEqualStrings(got_first, got_second);
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
    // Wiki rewrite → Markdown link → Oliver <a href="…">
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

test "Feature 7 HTML: fenced and inline-code include and wiki stay literal" {
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
        \\Inline `{{include includes/secret.md}}` and `[[fenced/wiki]]` remain literal.
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
    // Oliver emits header ids: <h1 id="...">
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

// D4 product-path smoke: rich pages under `--jobs` must match sequential
// HTML and two parallel runs must be byte-identical. Distinctive markers detect
// cross-talk if concurrent Oliver renders share mutable state.
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

test "validateHtmlSiteMulti shares prepublication semantics without output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-validate-no-output-test", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\---
        \\# Home
        \\
        \\{{include includes/blurb.md}}
        \\
        \\See [[guides/note#details]].
        \\
        \\<Aside kind="tip" id="validation-tip">
        \\Shared component validation.
        \\</Aside>
        \\
    );
    try writeTreeFile(io, work, "content/guides/note.md",
        \\---
        \\title: Note
        \\parent: index
        \\status: published
        \\---
        \\# Note
        \\
        \\## Details
        \\
    );
    try writeTreeFile(io, work, "content/includes/blurb.md", "Included through the canonical dependency resolver.\n");

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist});
    defer gpa.free(stage);
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const sitemap_path = try std.fmt.allocPrint(gpa, "{s}/sitemap.xml", .{dist});
    defer gpa.free(sitemap_path);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "default", .output_dir = dist },
    };
    const options: CompileOptions = .{
        .content_root = content_path,
        .layout_path = layout_path,
        .sitemap_path = "sitemap.xml",
        .site_url = "https://example.test/docs/",
        .quiet = true,
    };

    // Repeated validation exercises the full shared render preflight while
    // leaving neither the final target nor its sibling stage behind.
    try validateHtmlSiteMulti(io, gpa, &targets, options);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));
    try validateHtmlSiteMulti(io, gpa, &targets, options);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));

    // Passing validation does not alter normal publication semantics.
    _ = try compileHtmlSiteMulti(io, gpa, &targets, options);
    try cwd.access(io, index_path, .{});
    try cwd.access(io, sitemap_path, .{});
}

test "validateHtmlSiteMulti runs the output link audit in memory" {
    // Regression for #430: `boris validate` must reject the same two poison
    // classes the publish path rejects — a root-relative URL escaping the
    // declared publication base path (EPUBLICATIONLOCATION) and a local
    // reference resolving to no published output (EROUTEMISSING) — without
    // writing a target or stage directory.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-validate-link-audit-test", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\---
        \\# Home
        \\
    );
    // Poison A: a project-site root-relative URL that omits the base path.
    try writeTreeFile(io, work, "content/escape.md",
        \\---
        \\title: Escape
        \\status: published
        \\---
        \\# Escape
        \\
        \\[outside](/outside-boris)
        \\
    );
    // Poison B: a local reference that resolves to no published output.
    try writeTreeFile(io, work, "content/broken.md",
        \\---
        \\title: Broken
        \\status: published
        \\---
        \\# Broken
        \\
        \\[missing](./no-such-page.md)
        \\
    );
    try writeTreeFile(io, work, "content/ok.md",
        \\---
        \\title: Ok
        \\status: published
        \\---
        \\# Ok
        \\
        \\[home](./index.html)
        \\
    );

    const content_path = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content_path);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist});
    defer gpa.free(stage);

    var location = try github_pages.parse(
        gpa,
        "https://drawmeanelephant.github.io/boris/",
        "https://drawmeanelephant.github.io",
        "/boris",
    );
    defer location.deinit(gpa);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "default", .output_dir = dist },
    };
    const options: CompileOptions = .{
        .content_root = content_path,
        .layout_path = layout_path,
        .publication_location = &location,
        .quiet = true,
    };

    // Both poison classes fail validation as content failures (the multi-target
    // wrapper aggregates LinkAuditFailed into MultiTargetCompilationFailed, the
    // same exit-1 class the CLI maps), and neither the target nor its stage
    // appears. The diagnostics above are emitted by the shared reporter, so the
    // find text must show both the EPUBLICATIONLOCATION and EROUTEMISSING poisons.
    try std.testing.expectError(error.MultiTargetCompilationFailed, validateHtmlSiteMulti(io, gpa, &targets, options));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));

    // A second run re-reads source, so fixing the poisons must flip the result.
    try writeTreeFile(io, work, "content/escape.md",
        \\---
        \\title: Escape
        \\status: published
        \\---
        \\# Escape
        \\
        \\[home](/boris/index.html)
        \\
    );
    try writeTreeFile(io, work, "content/broken.md",
        \\---
        \\title: Broken
        \\status: published
        \\---
        \\# Broken
        \\
        \\[home](./index.html)
        \\
    );
    try validateHtmlSiteMulti(io, gpa, &targets, options);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));
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

        _ = try compileHtmlSiteMulti(io, gpa, &targets, .{
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

        const multi_inventory_paths = [_][]const u8{
            "_boris/search/search-index.json",
            "alpha.html",
            "beta.html",
        };
        const inventory_a = try readAllFile(io, dir_a, artifact_inventory.output_path, gpa);
        defer gpa.free(inventory_a);
        const inventory_b = try readAllFile(io, dir_b, artifact_inventory.output_path, gpa);
        defer gpa.free(inventory_b);
        try expectArtifactInventoryShape(gpa, inventory_a, "target_a", &multi_inventory_paths, &.{});
        try expectArtifactInventoryShape(gpa, inventory_b, "target_b", &multi_inventory_paths, &.{});
        var parsed_a = try std.json.parseFromSlice(std.json.Value, gpa, inventory_a, .{});
        defer parsed_a.deinit();
        var parsed_b = try std.json.parseFromSlice(std.json.Value, gpa, inventory_b, .{});
        defer parsed_b.deinit();
        for (multi_inventory_paths) |path| {
            const record_a = findArtifactRecord(parsed_a.value, path) orelse return error.MissingArtifactRecord;
            const record_b = findArtifactRecord(parsed_b.value, path) orelse return error.MissingArtifactRecord;
            try std.testing.expectEqual(record_a.object.get("bytes").?.integer, record_b.object.get("bytes").?.integer);
            try std.testing.expectEqualStrings(
                record_a.object.get("sha256").?.string,
                record_b.object.get("sha256").?.string,
            );
        }

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

test "artifact inventory replacement is last during a failed target commit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "stage/_boris/proof");
    try tmp.dir.createDirPath(io, "final/_boris/proof");
    try tmp.dir.createDirPath(io, "final/index.html/block");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.html", .data = "new page" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/_boris/proof/artifacts.json", .data = "new inventory" });
    try tmp.dir.writeFile(io, .{ .sub_path = "final/_boris/proof/artifacts.json", .data = "old inventory" });
    try tmp.dir.writeFile(io, .{ .sub_path = "final/index.html/block/keep.txt", .data = "keep" });

    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);
    var final = try tmp.dir.openDir(io, "final", .{ .iterate = true });
    defer final.close(io);

    var failed = false;
    publishStageTree(io, gpa, stage, final, artifact_inventory.output_path) catch {
        failed = true;
    };
    try std.testing.expect(failed);

    const inventory = try readAllFile(io, final, artifact_inventory.output_path, gpa);
    defer gpa.free(inventory);
    try std.testing.expectEqualStrings("old inventory", inventory);
    const staged_inventory = try readAllFile(io, stage, artifact_inventory.output_path, gpa);
    defer gpa.free(staged_inventory);
    try std.testing.expectEqualStrings("new inventory", staged_inventory);
}

test "deferred publication paths compare across host separators" {
    try std.testing.expect(publishPathsEqual(
        "_boris/proof/artifacts.json",
        "_boris/proof/artifacts.json",
    ));
    try std.testing.expect(publishPathsEqual(
        "_boris\\proof\\artifacts.json",
        "_boris/proof/artifacts.json",
    ));
    try std.testing.expect(!publishPathsEqual(
        "_boris/proof/other.json",
        "_boris/proof/artifacts.json",
    ));
}

test "incremental evidence reuse skips derivation and --refresh-evidence forces it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/evidence-reuse", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "themes/docs/layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nStable body.\n");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/themes/docs/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const state_path = publication_evidence_state.state_dir_sub_path ++ "/default.json";
    const canonical_checks = blk: {
        const base: CompileOptions = .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout,
            .incremental = true,
            .quiet = true,
        };
        _ = try compileHtmlSite(io, gpa, base);
        break :blk try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    };
    defer gpa.free(canonical_checks);

    // State was recorded by the first incremental build.
    const state_bytes = try readTargetPayload(io, gpa, dist, state_path);
    gpa.free(state_bytes);

    const expectChecksEqual = struct {
        fn go(g: std.mem.Allocator, io_l: std.Io, d: []const u8, want: []const u8) !void {
            const got = try readTargetPayload(io_l, g, d, publication_checks.output_path);
            defer g.free(got);
            try std.testing.expectEqualStrings(want, got);
        }
    }.go;

    // Unchanged tree + injected checks failure still succeeds: reuse skipped
    // the derivation entirely.
    var reuse_options: CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
        .test_fail_publication_checks = true,
    };
    _ = try compileHtmlSite(io, gpa, reuse_options);
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // The same injection with --refresh-evidence must fail loud.
    reuse_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, reuse_options));
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // A corrupt state file falls back to full derivation (injection fires).
    reuse_options.refresh_evidence = false;
    try writeTreeFile(io, work, "dist/.boris-cache/evidence-state/default.json", "{ broken");
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, reuse_options));
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // A state file with a different compiler_id forces re-derivation: an
    // upgraded binary must not silently reuse stale evidence.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    const fake_json =
        \\{"format":"boris-evidence-state-v1","compiler_id":"boris/0.9.9","target":"default","artifacts_sha256":"0000000000000000000000000000000000000000000000000000000000000000","reports":[]}
    ;
    try writeTreeFile(io, work, "dist/.boris-cache/evidence-state/default.json", fake_json);
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
        .test_fail_publication_checks = true,
    }));
    try expectChecksEqual(gpa, io, dist, canonical_checks);

    // A tampered report digest also forces re-derivation, which restores the
    // canonical bytes.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    try writeTreeFile(io, work, "dist/_boris/proof/checks.json", "{\"tampered\":true}\n");
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    try expectChecksEqual(gpa, io, dist, canonical_checks);
}

test "HTML publication artifact inventory is complete, deterministic, isolated, and transactional" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-artifacts", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "themes/docs/layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "themes/docs/assets/css/site.css", "body{color:red}");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "content/guides/child.md", "# Child\n\nNested page.\n");
    try writeTreeFile(io, work, "content/index.assets/diagram.txt", "diagram-v1");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/themes/docs/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const parallel_dist = try std.fmt.allocPrint(gpa, "{s}/parallel", .{work});
    defer gpa.free(parallel_dist);
    const plain_dist = try std.fmt.allocPrint(gpa, "{s}/plain", .{work});
    defer gpa.free(plain_dist);

    const deployment_owned = try std.fmt.allocPrint(gpa, "{s}/deployment-owned.txt", .{dist});
    defer gpa.free(deployment_owned);
    try writeTreeFile(io, work, "dist/deployment-owned.txt", "deployment-owned");

    const child_source = try std.fmt.allocPrint(gpa, "{s}/guides/child.md", .{content});
    defer gpa.free(child_source);
    const asset_source = try std.fmt.allocPrint(gpa, "{s}/index.assets/diagram.txt", .{content});
    defer gpa.free(asset_source);
    const stale_child = try std.fmt.allocPrint(gpa, "{s}/guides/child.html", .{dist});
    defer gpa.free(stale_child);
    const stale_asset = try std.fmt.allocPrint(gpa, "{s}/index.assets/diagram.txt", .{dist});
    defer gpa.free(stale_asset);

    const with_sitemap = [_][]const u8{
        "assets/css/site.css",
        "guides/child.html",
        "index.assets/diagram.txt",
        "index.html",
        "_boris/search/search-index.json",
        "meta/discovery.xml",
    };
    const without_sitemap = [_][]const u8{
        "assets/css/site.css",
        "index.html",
        "_boris/search/search-index.json",
    };
    const no_absent_paths = [_][]const u8{};

    const base_options: CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
        .sitemap_path = "meta/discovery.xml",
        .site_url = "https://example.test/docs",
    };
    _ = try compileHtmlSite(io, gpa, base_options);

    var inventory_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(inventory_bytes);
    try expectArtifactInventoryShape(gpa, inventory_bytes, "default", &with_sitemap, &no_absent_paths);
    try std.testing.expect(std.mem.indexOf(u8, inventory_bytes, artifact_inventory.output_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, inventory_bytes, work) == null);

    var checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    try expectPublicationChecksShape(gpa, checks_bytes, "default");
    const first_checks = try gpa.dupe(u8, checks_bytes);
    defer gpa.free(first_checks);

    var checks_failure_options = base_options;
    checks_failure_options.test_fail_publication_checks = true;
    checks_failure_options.refresh_evidence = true;
    try std.testing.expectError(
        error.PublicationChecksFailed,
        compileHtmlSite(io, gpa, checks_failure_options),
    );
    const after_checks_failure = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(after_checks_failure);
    try std.testing.expectEqualStrings(first_checks, after_checks_failure);

    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inventory_bytes, .{});
        defer parsed.deinit();
        const page = try readTargetPayload(io, gpa, dist, "index.html");
        defer gpa.free(page);
        try expectArtifactRecord(parsed.value, "index.html", "html-page", "html-render", page);
        const child = try readTargetPayload(io, gpa, dist, "guides/child.html");
        defer gpa.free(child);
        try expectArtifactRecord(parsed.value, "guides/child.html", "html-page", "html-render", child);
        const theme = try readTargetPayload(io, gpa, dist, "assets/css/site.css");
        defer gpa.free(theme);
        try expectArtifactRecord(parsed.value, "assets/css/site.css", "theme-asset", "theme-assets", theme);
        const content_asset_bytes = try readTargetPayload(io, gpa, dist, "index.assets/diagram.txt");
        defer gpa.free(content_asset_bytes);
        try expectArtifactRecord(parsed.value, "index.assets/diagram.txt", "content-asset", "content-assets", content_asset_bytes);
        const search = try readTargetPayload(io, gpa, dist, search_index.output_path);
        defer gpa.free(search);
        try expectArtifactRecord(parsed.value, search_index.output_path, "rendered-search", "rendered-search", search);
        const sitemap_bytes = try readTargetPayload(io, gpa, dist, "meta/discovery.xml");
        defer gpa.free(sitemap_bytes);
        try expectArtifactRecord(parsed.value, "meta/discovery.xml", "sitemap", "sitemap", sitemap_bytes);
    }

    const first_inventory = try gpa.dupe(u8, inventory_bytes);
    defer gpa.free(first_inventory);
    _ = try compileHtmlSite(io, gpa, base_options);
    const repeat_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(repeat_inventory);
    try std.testing.expectEqualStrings(first_inventory, repeat_inventory);
    gpa.free(checks_bytes);
    checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    try std.testing.expectEqualStrings(first_checks, checks_bytes);

    var parallel_options = base_options;
    parallel_options.dist_dir = parallel_dist;
    parallel_options.jobs = 4;
    _ = try compileHtmlSite(io, gpa, parallel_options);
    const parallel_inventory = try readArtifactInventory(io, gpa, parallel_dist);
    defer gpa.free(parallel_inventory);
    try std.testing.expectEqualStrings(first_inventory, parallel_inventory);
    const parallel_checks = try readTargetPayload(io, gpa, parallel_dist, publication_checks.output_path);
    defer gpa.free(parallel_checks);
    try std.testing.expectEqualStrings(first_checks, parallel_checks);

    var old_index_digest: [64]u8 = undefined;
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inventory_bytes, .{});
        defer parsed.deinit();
        const old_record = findArtifactRecord(parsed.value, "index.html") orelse return error.MissingArtifactRecord;
        const old_digest = old_record.object.get("sha256").?.string;
        try std.testing.expectEqual(@as(usize, 64), old_digest.len);
        @memcpy(old_index_digest[0..], old_digest);
    }

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged body.\n");
    _ = try compileHtmlSite(io, gpa, base_options);
    const changed_inventory = try readArtifactInventory(io, gpa, dist);
    try expectArtifactInventoryShape(gpa, changed_inventory, "default", &with_sitemap, &no_absent_paths);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, changed_inventory, .{});
        defer parsed.deinit();
        const changed_record = findArtifactRecord(parsed.value, "index.html") orelse return error.MissingArtifactRecord;
        try std.testing.expect(!std.mem.eql(u8, &old_index_digest, changed_record.object.get("sha256").?.string));
        const child = try readTargetPayload(io, gpa, dist, "guides/child.html");
        defer gpa.free(child);
        try expectArtifactRecord(parsed.value, "guides/child.html", "html-page", "html-render", child);
        const theme = try readTargetPayload(io, gpa, dist, "assets/css/site.css");
        defer gpa.free(theme);
        try expectArtifactRecord(parsed.value, "assets/css/site.css", "theme-asset", "theme-assets", theme);
        const content_asset_bytes = try readTargetPayload(io, gpa, dist, "index.assets/diagram.txt");
        defer gpa.free(content_asset_bytes);
        try expectArtifactRecord(parsed.value, "index.assets/diagram.txt", "content-asset", "content-assets", content_asset_bytes);
    }
    gpa.free(inventory_bytes);
    inventory_bytes = changed_inventory;

    const before_failure = try gpa.dupe(u8, inventory_bytes);
    defer gpa.free(before_failure);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nFailed transaction body.\n");
    var inventory_failure_options = base_options;
    inventory_failure_options.test_fail_before_inventory_write = true;
    try std.testing.expectError(
        error.TestInjectedInventoryWriteFailure,
        compileHtmlSite(io, gpa, inventory_failure_options),
    );
    const after_inventory_failure = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(after_inventory_failure);
    try std.testing.expectEqualStrings(before_failure, after_inventory_failure);

    var sitemap_failure_options = base_options;
    sitemap_failure_options.test_fail_after_sitemap_stage = true;
    try std.testing.expectError(
        error.TestInjectedSitemapFailure,
        compileHtmlSite(io, gpa, sitemap_failure_options),
    );
    const after_sitemap_failure = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(after_sitemap_failure);
    try std.testing.expectEqualStrings(before_failure, after_sitemap_failure);

    try cwd.deleteFile(io, child_source);
    try cwd.deleteFile(io, asset_source);
    _ = try compileHtmlSite(io, gpa, base_options);
    const pruned_inventory = try readArtifactInventory(io, gpa, dist);
    try expectArtifactInventoryShape(
        gpa,
        pruned_inventory,
        "default",
        &[_][]const u8{
            "assets/css/site.css",
            "index.html",
            "_boris/search/search-index.json",
            "meta/discovery.xml",
        },
        &[_][]const u8{ "guides/child.html", "index.assets/diagram.txt" },
    );
    gpa.free(inventory_bytes);
    inventory_bytes = pruned_inventory;
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_child, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_asset, .{}));
    try cwd.access(io, deployment_owned, .{});

    var plain_options = base_options;
    plain_options.dist_dir = plain_dist;
    plain_options.sitemap_path = null;
    plain_options.site_url = null;
    _ = try compileHtmlSite(io, gpa, plain_options);
    const plain_inventory = try readArtifactInventory(io, gpa, plain_dist);
    defer gpa.free(plain_inventory);
    try expectArtifactInventoryShape(
        gpa,
        plain_inventory,
        "default",
        &without_sitemap,
        &[_][]const u8{"meta/discovery.xml"},
    );
}

test "HTML publish produces search from live overlay and removes stale pages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/search-compile", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged on rebuild.\n");
    try writeTreeFile(io, work, "content/guides/child.md", "# Child\n\nNested page.\n");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });

    // Change only the root page. The nested page is cached in dist and must be
    // overlaid into the newly staged search artifact.
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged again.\n");
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });

    const search_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist, search_index.output_path });
    defer gpa.free(search_path);
    var search_json = try readFileAlloc(io, cwd, search_path, gpa);
    defer gpa.free(search_json);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "\"path\": \"index.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "\"path\": \"guides/child.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "Changed again.") != null);

    // Remove the nested source page. HTML stale cleanup and search publication
    // must agree on the current PageDb live set.
    const child_source = try std.fmt.allocPrint(gpa, "{s}/guides/child.md", .{content});
    defer gpa.free(child_source);
    try cwd.deleteFile(io, child_source);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    gpa.free(search_json);
    search_json = try readFileAlloc(io, cwd, search_path, gpa);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "guides/child.html") == null);

    // An empty content tree still publishes a valid empty artifact rather than
    // leaving the previous index as a stale target-owned file.
    const index_source = try std.fmt.allocPrint(gpa, "{s}/index.md", .{content});
    defer gpa.free(index_source);
    try cwd.deleteFile(io, index_source);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .incremental = true,
        .quiet = true,
    });
    gpa.free(search_json);
    search_json = try readFileAlloc(io, cwd, search_path, gpa);
    try std.testing.expectEqualStrings(
        "{\n  \"format\": \"boris-rendered-search-index\",\n  \"schema_version\": 1,\n  \"documents\": [\n  ]\n}\n",
        search_json,
    );
}

test "search publication excludes draft pages while the link audit still resolves them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/search-draft", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    // The published page links to the draft. A draft still renders to HTML, so
    // that link must keep resolving: search exclusion is a publication-surface
    // rule, not a removal from the output set.
    try writeTreeFile(
        io,
        work,
        "content/index.md",
        "# Home\n\nBody token PUBLISHEDBODYTOKEN here.\n\n[draft](secret.html)\n",
    );
    try writeTreeFile(
        io,
        work,
        "content/secret.md",
        "---\nstatus: draft\n---\n\n# Secret\n\nBody token DRAFTBODYTOKEN here.\n",
    );

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // A LinkAuditFailed here would mean the draft was dropped from the audit's
    // intended output set, not merely from search.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    // The draft rendered: it is published HTML, just not advertised.
    const draft_html = try std.fmt.allocPrint(gpa, "{s}/secret.html", .{dist});
    defer gpa.free(draft_html);
    const draft_bytes = try readFileAlloc(io, cwd, draft_html, gpa);
    defer gpa.free(draft_bytes);
    try std.testing.expect(std.mem.indexOf(u8, draft_bytes, "DRAFTBODYTOKEN") != null);

    const search_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist, search_index.output_path });
    defer gpa.free(search_path);
    const search_json = try readFileAlloc(io, cwd, search_path, gpa);
    defer gpa.free(search_json);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "DRAFTBODYTOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "\"path\": \"secret.html\"") == null);
    // Positive control: an exclusion that emptied the index would pass the two
    // assertions above without publishing anything searchable.
    try std.testing.expect(std.mem.indexOf(u8, search_json, "PUBLISHEDBODYTOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "\"path\": \"index.html\"") != null);

    // #752: the inventory records advertisement per page, and the rendered-
    // search check treats the unadvertised draft as ineligible instead of
    // reporting a missing search document for intended state.
    const artifacts_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist, artifact_inventory.output_path });
    defer gpa.free(artifacts_path);
    const artifacts_json = try readFileAlloc(io, cwd, artifacts_path, gpa);
    defer gpa.free(artifacts_json);
    const secret_record = try std.fmt.allocPrint(
        gpa,
        "{{\n      \"path\": \"secret.html\",\n      \"kind\": \"html-page\",\n      \"producer\": \"html-render\",\n      \"required\": true,\n      \"status\": \"committed\",\n      \"bytes\": {d},",
        .{draft_bytes.len},
    );
    defer gpa.free(secret_record);
    try std.testing.expect(std.mem.indexOf(u8, artifacts_json, secret_record) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifacts_json, "\"advertised\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifacts_json, "\"advertised\": true") != null);

    const checks_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist, publication_checks.output_path });
    defer gpa.free(checks_path);
    const checks_json = try readFileAlloc(io, cwd, checks_path, gpa);
    defer gpa.free(checks_json);
    try std.testing.expect(std.mem.indexOf(u8, checks_json, "SEARCH_DOCUMENT_MISSING") == null);
    const rendered_search_row = try std.fmt.allocPrint(
        gpa,
        "{{\n      \"id\": \"rendered-search\",\n      \"eligible\": true,\n      \"ran\": true,\n      \"status\": \"{s}\",",
        .{publication_checks.Status.passed.name()},
    );
    defer gpa.free(rendered_search_row);
    try std.testing.expect(std.mem.indexOf(u8, checks_json, rendered_search_row) != null);
}

test "default target emits draft pages but prunes them from nav and children (#738)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/nav-draft", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body><nav>NAV<{{nav}}>ENDNAV</nav>BREAD<{{breadcrumb}}>ENDBREAD{{content}}KIDS<{{children}}>ENDKIDS</body></html>");
    // The published home page links to the draft; the link audit must keep
    // resolving it because a draft still renders to HTML.
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: Home\n---\n# Home\n\n[draft](secret.html)\n");
    try writeTreeFile(io, work, "content/guides/a.md", "---\ntitle: Guide A\nparent: index\n---\n# A\n");
    try writeTreeFile(io, work, "content/secret.md", "---\ntitle: Secret\nstatus: draft\n---\n# SECRETBODYTOKEN\n");
    // A published satellite under the drafted trunk: emitted, but its nav
    // subtree is pruned until the trunk publishes.
    try writeTreeFile(io, work, "content/secret/kid.md", "---\ntitle: Kid\nparent: secret\n---\n# Kid\n");
    // Archived stays advertised (consistent with Standard.site / Nostr).
    try writeTreeFile(io, work, "content/archived.md", "---\ntitle: Archived\nstatus: archived\n---\n# Archived\n");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });

    // Emitted but unadvertised.
    const secret_html = try std.fmt.allocPrint(gpa, "{s}/secret.html", .{dist});
    defer gpa.free(secret_html);
    const secret_bytes = try readFileAlloc(io, cwd, secret_html, gpa);
    defer gpa.free(secret_bytes);
    try std.testing.expect(std.mem.indexOf(u8, secret_bytes, "SECRETBODYTOKEN") != null);
    // The draft trunk's own nav prunes itself and its subtree; its own
    // {{children}} still lists the published kid (per-page context).
    const secret_nav = navSegment(secret_bytes);
    try std.testing.expect(std.mem.indexOf(u8, secret_nav, "secret.html") == null);
    try std.testing.expect(std.mem.indexOf(u8, secret_nav, ">Kid</a>") == null);

    const kid_html = try std.fmt.allocPrint(gpa, "{s}/secret/kid.html", .{dist});
    defer gpa.free(kid_html);
    const kid_bytes = try readFileAlloc(io, cwd, kid_html, gpa);
    defer gpa.free(kid_bytes);
    // Breadcrumb context is not advertising: the drafted parent stays a crumb.
    const kid_crumb = crumbSegment(kid_bytes);
    try std.testing.expect(std.mem.indexOf(u8, kid_crumb, ">Secret</a>") != null);

    const index_html = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_html);
    var home_bytes = try readFileAlloc(io, cwd, index_html, gpa);
    defer gpa.free(home_bytes);
    var home_nav = navSegment(home_bytes);
    try std.testing.expect(std.mem.indexOf(u8, home_nav, ">Secret</a>") == null);
    try std.testing.expect(std.mem.indexOf(u8, home_nav, ">Guide A</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_nav, ">Archived</a>") != null);

    // The draft remains a graph/cache member: the manifest still lists it.
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/.boris-cache/manifest.json", .{dist});
    defer gpa.free(manifest_path);
    const manifest_bytes = try readFileAlloc(io, cwd, manifest_path, gpa);
    defer gpa.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"entity_id\": \"secret\"") != null);

    // Publishing the draft dirties chrome through the status-aware nav
    // material: an incremental rebuild must start advertising it.
    try writeTreeFile(io, work, "content/secret.md", "---\ntitle: Secret\nstatus: published\n---\n# SECRETBODYTOKEN\n");
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    gpa.free(home_bytes);
    home_bytes = try readFileAlloc(io, cwd, index_html, gpa);
    home_nav = navSegment(home_bytes);
    try std.testing.expect(std.mem.indexOf(u8, home_nav, ">Secret</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, home_nav, ">Kid</a>") != null);
}

/// Slice the `NAV<…>ENDNAV` segment of the test layout's output.
fn navSegment(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "NAV<") orelse return "";
    const end = std.mem.indexOf(u8, bytes, ">ENDNAV") orelse return "";
    if (end < start) return "";
    return bytes[start + 4 .. end];
}

/// Slice the `BREAD<…>ENDBREAD` segment of the test layout's output.
fn crumbSegment(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "BREAD<") orelse return "";
    const end = std.mem.indexOf(u8, bytes, ">ENDBREAD") orelse return "";
    if (end < start) return "";
    return bytes[start + 6 .. end];
}

test "{{nav depth=N}} caps the rendered forest while every page still builds (#744)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/nav-depth", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    // Deep chain: index → a → b → c → d (five rendered levels unbounded).
    try writeTreeFile(io, work, "layouts/bounded.html", "<html><body>NAV<{{nav depth=2}}>ENDNAV{{content}}</body></html>");
    try writeTreeFile(io, work, "layouts/full.html", "<html><body>NAV<{{nav}}>ENDNAV{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "---\ntitle: L1\n---\n# L1\n");
    try writeTreeFile(io, work, "content/a.md", "---\ntitle: L2\nparent: index\n---\n# L2\n");
    try writeTreeFile(io, work, "content/b.md", "---\ntitle: L3\nparent: a\n---\n# L3\n");
    try writeTreeFile(io, work, "content/c.md", "---\ntitle: L4\nparent: b\n---\n# L4\n");
    try writeTreeFile(io, work, "content/d.md", "---\ntitle: L5\nparent: c\n---\n# L5\n");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const bounded_layout = try std.fmt.allocPrint(gpa, "{s}/layouts/bounded.html", .{work});
    defer gpa.free(bounded_layout);
    const full_layout = try std.fmt.allocPrint(gpa, "{s}/layouts/full.html", .{work});
    defer gpa.free(full_layout);
    const bounded_dist = try std.fmt.allocPrint(gpa, "{s}/bounded", .{work});
    defer gpa.free(bounded_dist);
    const full_dist = try std.fmt.allocPrint(gpa, "{s}/full", .{work});
    defer gpa.free(full_dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = bounded_dist,
        .layout_path = bounded_layout,
        .quiet = true,
    });
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = full_dist,
        .layout_path = full_layout,
        .quiet = true,
    });

    // Every page builds under both layouts.
    for ([_][]const u8{ "index.html", "a.html", "b.html", "c.html", "d.html" }) |page| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bounded_dist, page });
        defer gpa.free(p);
        const bp = try readFileAlloc(io, cwd, p, gpa);
        defer gpa.free(bp);
        const q = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ full_dist, page });
        defer gpa.free(q);
        const bq = try readFileAlloc(io, cwd, q, gpa);
        defer gpa.free(bq);
    }

    // Bounded: level cap 2 renders trunks + direct children only; deeper
    // titles never appear in any nav, including from the deep pages
    // themselves.
    const bounded_index = try std.fmt.allocPrint(gpa, "{s}/index.html", .{bounded_dist});
    defer gpa.free(bounded_index);
    const bi_bytes = try readFileAlloc(io, cwd, bounded_index, gpa);
    defer gpa.free(bi_bytes);
    const bi_nav = navSegmentForDepthTest(bi_bytes);
    try std.testing.expect(std.mem.indexOf(u8, bi_nav, ">L1</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bi_nav, ">L2</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bi_nav, ">L3</a>") == null);

    const bounded_deep = try std.fmt.allocPrint(gpa, "{s}/d.html", .{bounded_dist});
    defer gpa.free(bounded_deep);
    const bd_bytes = try readFileAlloc(io, cwd, bounded_deep, gpa);
    defer gpa.free(bd_bytes);
    const bd_nav = navSegmentForDepthTest(bd_bytes);
    try std.testing.expect(std.mem.indexOf(u8, bd_nav, ">L2</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bd_nav, ">L5</a>") == null);
    try std.testing.expect(std.mem.indexOf(u8, bd_nav, ">L4</a>") == null);

    // Unbounded control on the same tree: the deepest title is present and
    // the bounded nav is strictly smaller.
    const full_deep = try std.fmt.allocPrint(gpa, "{s}/d.html", .{full_dist});
    defer gpa.free(full_deep);
    const fd_bytes = try readFileAlloc(io, cwd, full_deep, gpa);
    defer gpa.free(fd_bytes);
    const fd_nav = navSegmentForDepthTest(fd_bytes);
    try std.testing.expect(std.mem.indexOf(u8, fd_nav, ">L5</a>") != null);
    try std.testing.expect(bd_nav.len < fd_nav.len);
}

/// Slice the `NAV<…>ENDNAV` segment of this test's layout output.
fn navSegmentForDepthTest(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "NAV<") orelse return "";
    const end = std.mem.indexOf(u8, bytes, ">ENDNAV") orelse return "";
    if (end < start) return "";
    return bytes[start + 4 .. end];
}
test "HTML sitemap uses the staged live overlay and is deterministic across clean incremental and parallel builds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sitemap-compile", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\published_at: 2020-01-01T00:00:00Z
        \\summary: Home summary
        \\---
        \\# Home
        \\
        \\Welcome.
        \\
    );
    try writeTreeFile(io, work, "content/guide.md", "# Guide\n");
    try writeTreeFile(io, work, "content/guides/child.md", "# Child\n");
    try writeTreeFile(io, work, "content/café.md", "# Café\n");
    try writeTreeFile(io, work, "content/draft.md",
        \\---
        \\status: draft
        \\---
        \\# Draft
        \\
    );
    try writeTreeFile(io, work, "content/guide.assets/note.txt", "asset, not a page");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const clean_dist = try std.fmt.allocPrint(gpa, "{s}/clean", .{work});
    defer gpa.free(clean_dist);
    const parallel_dist = try std.fmt.allocPrint(gpa, "{s}/parallel", .{work});
    defer gpa.free(parallel_dist);
    const sitemap_path = "meta/discovery.xml";
    const public_url = "https://example.test/docs&guides/";

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = clean_dist,
        .layout_path = layout,
        .quiet = true,
        .jobs = 1,
        .sitemap_path = sitemap_path,
        .site_url = public_url,
    });
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
        .sitemap_path = sitemap_path,
        .site_url = public_url,
    });

    const clean_sitemap_full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ clean_dist, sitemap_path });
    defer gpa.free(clean_sitemap_full);
    const parallel_sitemap_full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parallel_dist, sitemap_path });
    defer gpa.free(parallel_sitemap_full);
    const clean_bytes = try readFileAlloc(io, cwd, clean_sitemap_full, gpa);
    defer gpa.free(clean_bytes);
    var parallel_bytes = try readFileAlloc(io, cwd, parallel_sitemap_full, gpa);
    defer gpa.free(parallel_bytes);
    try std.testing.expectEqualStrings(clean_bytes, parallel_bytes);

    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "https://example.test/docs&amp;guides/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "guides/child.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "caf%C3%A9.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "draft.html") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "guide.assets/note.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, search_index.output_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "published_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean_bytes, "lastmod") == null);

    var loc_count: usize = 0;
    var loc_at: usize = 0;
    while (std.mem.indexOfPos(u8, clean_bytes, loc_at, "<loc>")) |at| {
        loc_count += 1;
        loc_at = at + "<loc>".len;
    }
    try std.testing.expectEqual(@as(usize, 4), loc_count);
    for ([_][]const u8{ "index.html", "guide.html", "guides/child.html", "café.html" }) |path| {
        const published = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ clean_dist, path });
        defer gpa.free(published);
        try cwd.access(io, published, .{});
    }

    // A repeated incremental+parallel run is byte-identical. Changing
    // publication date metadata also cannot affect a timestamp-free sitemap.
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
        .sitemap_path = sitemap_path,
        .site_url = public_url,
    });
    gpa.free(parallel_bytes);
    parallel_bytes = try readFileAlloc(io, cwd, parallel_sitemap_full, gpa);
    try std.testing.expectEqualStrings(clean_bytes, parallel_bytes);
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\published_at: 2040-12-31T23:59:59Z
        \\summary: Home summary
        \\---
        \\# Home
        \\
        \\Welcome.
        \\
    );
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
        .sitemap_path = sitemap_path,
        .site_url = public_url,
    });
    gpa.free(parallel_bytes);
    parallel_bytes = try readFileAlloc(io, cwd, parallel_sitemap_full, gpa);
    try std.testing.expectEqualStrings(clean_bytes, parallel_bytes);

    // Removing a source removes both the published HTML and the obsolete URL.
    const child_source = try std.fmt.allocPrint(gpa, "{s}/guides/child.md", .{content});
    defer gpa.free(child_source);
    try cwd.deleteFile(io, child_source);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
        .sitemap_path = sitemap_path,
        .site_url = public_url,
    });
    gpa.free(parallel_bytes);
    parallel_bytes = try readFileAlloc(io, cwd, parallel_sitemap_full, gpa);
    try std.testing.expect(std.mem.indexOf(u8, parallel_bytes, "guides/child.html") == null);
    const stale_child = try std.fmt.allocPrint(gpa, "{s}/guides/child.html", .{parallel_dist});
    defer gpa.free(stale_child);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_child, .{}));

    // A failure after sitemap staging preserves the prior published sitemap
    // and HTML transaction.
    const before_failure = try gpa.dupe(u8, parallel_bytes);
    defer gpa.free(before_failure);
    try std.testing.expectError(error.TestInjectedSitemapFailure, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
        .sitemap_path = sitemap_path,
        .site_url = public_url,
        .test_fail_after_sitemap_stage = true,
    }));
    gpa.free(parallel_bytes);
    parallel_bytes = try readFileAlloc(io, cwd, parallel_sitemap_full, gpa);
    try std.testing.expectEqualStrings(before_failure, parallel_bytes);

    // Changing and then disabling the projection removes the prior
    // compiler-owned file through the checked publication transaction.
    const replacement_path = "sitemap-next.xml";
    const replacement_full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parallel_dist, replacement_path });
    defer gpa.free(replacement_full);
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
        .sitemap_path = replacement_path,
        .site_url = public_url,
    });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, parallel_sitemap_full, .{}));
    try cwd.access(io, replacement_full, .{});
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = parallel_dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
        .jobs = 4,
    });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, replacement_full, .{}));
}

test "HTML sitemap rejects output ownership collisions and ambiguous multi-target URLs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sitemap-collisions", .{tmp.sub_path});
    defer gpa.free(work);
    try writeTreeFile(io, work, "layout.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    try writeTreeFile(io, work, "content/index.assets/note.xml", "asset");
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layout.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.SitemapOutputCollision, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .sitemap_path = "index.html",
        .site_url = "https://example.test",
    }));
    try std.testing.expectError(error.SitemapOutputCollision, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .sitemap_path = "index.assets/note.xml",
        .site_url = "https://example.test",
    }));
    try std.testing.expectError(error.SitemapOutputCollision, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .sitemap_path = search_index.output_path,
        .site_url = "https://example.test",
    }));

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "public", .output_dir = dist },
        .{ .name = "preview", .output_dir = try std.fmt.allocPrint(gpa, "{s}/preview", .{work}) },
    };
    defer gpa.free(targets[1].output_dir);
    try std.testing.expectError(error.AmbiguousSitemapTargets, compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
        .sitemap_path = "sitemap.xml",
        .site_url = "https://example.test",
    }));
}

test "Pages publication location mismatches fail before target replacement" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/pages-location-gate", .{tmp.sub_path});
    defer gpa.free(work);
    try writeTreeFile(io, work, "layout.html", "<html><head><link rel=\"canonical\" href=\"/boris/index.html\"></head><body><a href=\"/assets/theme.css\">asset</a>{{content}}</body></html>");
    try writeTreeFile(io, work, "content/index.md", "# Home\n");
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layout.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    try writeTreeFile(io, work, "dist/sentinel.txt", "previous target");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    try std.testing.expectError(error.LinkAuditFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .publication_location = &location,
    }));
    const sentinel_after_link_failure = try readTargetPayload(io, gpa, dist, "sentinel.txt");
    defer gpa.free(sentinel_after_link_failure);
    try std.testing.expectEqualStrings("previous target", sentinel_after_link_failure);
    try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, "index.html"));

    try std.testing.expectError(error.PublicationLocationMismatch, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .sitemap_path = "sitemap.xml",
        .site_url = "https://owner.github.io",
        .publication_location = &location,
    }));
    const sentinel_after_sitemap_failure = try readTargetPayload(io, gpa, dist, "sentinel.txt");
    defer gpa.free(sentinel_after_sitemap_failure);
    try std.testing.expectEqualStrings("previous target", sentinel_after_sitemap_failure);
    try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, "index.html"));
}

test "Pages publication location fixture covers all site shapes and poisoned metadata" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixture = "docs/contracts/fixtures/publication-location";
    const content = "docs/contracts/fixtures/publication-location/content";
    const layout = "docs/contracts/fixtures/publication-location/theme/layouts/main.html";
    const shapes = [_]struct {
        base_url: []const u8,
        origin: []const u8,
        base_path: []const u8,
    }{
        .{ .base_url = "https://owner.github.io/boris", .origin = "https://owner.github.io", .base_path = "/boris" },
        .{ .base_url = "https://owner.github.io", .origin = "https://owner.github.io", .base_path = "" },
        .{ .base_url = "https://docs.example.com", .origin = "https://docs.example.com", .base_path = "" },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (shapes, 0..) |shape, index| {
        const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/valid-{d}", .{ tmp.sub_path, index });
        defer gpa.free(dist);
        var location = try github_pages.parse(gpa, shape.base_url, shape.origin, shape.base_path);
        defer location.deinit(gpa);
        _ = try compileHtmlSite(io, gpa, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = layout,
            .quiet = true,
            .sitemap_path = "sitemap.xml",
            .site_url = shape.base_url,
            .publication_location = &location,
        });

        const index_html = try readTargetPayload(io, gpa, dist, "index.html");
        defer gpa.free(index_html);
        const nested_html = try readTargetPayload(io, gpa, dist, "guides/start.html");
        defer gpa.free(nested_html);
        const sitemap_bytes = try readTargetPayload(io, gpa, dist, "sitemap.xml");
        defer gpa.free(sitemap_bytes);
        const search_bytes = try readTargetPayload(io, gpa, dist, "_boris/search/search-index.json");
        defer gpa.free(search_bytes);
        const expected_index = try std.fmt.allocPrint(gpa, "<loc>{s}/index.html</loc>", .{shape.base_url});
        defer gpa.free(expected_index);
        const expected_nested = try std.fmt.allocPrint(gpa, "<loc>{s}/guides/start.html</loc>", .{shape.base_url});
        defer gpa.free(expected_nested);

        try std.testing.expect(std.mem.indexOf(u8, index_html, "index.assets/logo.svg") != null);
        try std.testing.expect(std.mem.indexOf(u8, nested_html, "../assets/css/site.css") != null);
        try std.testing.expect(std.mem.indexOf(u8, nested_html, "start.assets/diagram.svg") != null);
        try std.testing.expect(std.mem.indexOf(u8, sitemap_bytes, expected_index) != null);
        try std.testing.expect(std.mem.indexOf(u8, sitemap_bytes, expected_nested) != null);
        try std.testing.expect(std.mem.indexOf(u8, search_bytes, "guides/start.html") != null);
        try std.testing.expect(std.mem.indexOf(u8, sitemap_bytes, "index.assets") == null);
    }

    const poisoned = [_]struct {
        layout_path: []const u8,
        base_url: []const u8,
        origin: []const u8,
        base_path: []const u8,
    }{
        .{
            .layout_path = fixture ++ "/poisoned/project-root-relative.html",
            .base_url = "https://owner.github.io/boris",
            .origin = "https://owner.github.io",
            .base_path = "/boris",
        },
        .{
            .layout_path = fixture ++ "/poisoned/wrong-origin.html",
            .base_url = "https://owner.github.io/boris",
            .origin = "https://owner.github.io",
            .base_path = "/boris",
        },
        .{
            .layout_path = fixture ++ "/poisoned/stale-root-prefix.html",
            .base_url = "https://owner.github.io",
            .origin = "https://owner.github.io",
            .base_path = "",
        },
        .{
            .layout_path = fixture ++ "/poisoned/custom-github-origin.html",
            .base_url = "https://docs.example.com",
            .origin = "https://docs.example.com",
            .base_path = "",
        },
    };
    for (poisoned, 0..) |case, index| {
        const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/poisoned-{d}", .{ tmp.sub_path, index });
        defer gpa.free(work);
        const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
        defer gpa.free(dist);
        try writeTreeFile(io, work, "dist/sentinel.txt", "previous target");
        var location = try github_pages.parse(gpa, case.base_url, case.origin, case.base_path);
        defer location.deinit(gpa);
        try std.testing.expectError(error.LinkAuditFailed, compileHtmlSite(io, gpa, .{
            .content_root = content,
            .dist_dir = dist,
            .layout_path = case.layout_path,
            .quiet = true,
            .publication_location = &location,
        }));
        const sentinel = try readTargetPayload(io, gpa, dist, "sentinel.txt");
        defer gpa.free(sentinel);
        try std.testing.expectEqualStrings("previous target", sentinel);
        try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, "index.html"));
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

test "Feature 9 incremental: heading harvest cache skips rendering on no-op (#58)" {
    // Sites with [[entity#heading]] must not re-render every fragment target on a
    // no-op incremental build. Cold build writes heading-harvest.json; warm
    // no-op reuses harvest keys and still emits correct fragment hrefs.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f9-heading-harvest", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: guides
        \\---
        \\
        \\# Section One
        \\
        \\Body.
        \\
    );
    try writeTreeFile(io, work, "content/guides.md",
        \\---
        \\title: Guides
        \\---
        \\
        \\# Guides
        \\
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\See [[guides/target#section-one]].
        \\
    );

    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Cold incremental: harvest + publish.
    const stats_cold = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expect(stats_cold.pages_written >= 1);

    const harvest_path = try std.fmt.allocPrint(gpa, "{s}/.boris-cache/heading-harvest.json", .{dist});
    defer gpa.free(harvest_path);
    const harvest1 = try readFileAlloc(io, cwd, harvest_path, gpa);
    defer gpa.free(harvest1);
    try std.testing.expect(std.mem.indexOf(u8, harvest1, HEADING_HARVEST_FORMAT) != null);
    try std.testing.expect(std.mem.indexOf(u8, harvest1, "guides/target") != null);
    try std.testing.expect(std.mem.indexOf(u8, harvest1, "section-one") != null);

    var dist_dir = try cwd.openDir(io, dist, .{});
    defer dist_dir.close(io);
    const index_html = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "guides/target.html#section-one") != null);

    // No-op warm: zero pages written; harvest file stable; HTML unchanged.
    const stats_warm = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats_warm.pages_written);

    const harvest2 = try readFileAlloc(io, cwd, harvest_path, gpa);
    defer gpa.free(harvest2);
    try std.testing.expectEqualStrings(harvest1, harvest2);

    const index_warm = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_warm);
    try std.testing.expectEqualStrings(index_html, index_warm);

    // Change only non-heading body text on the target → harvest key changes,
    // fragment id `section-one` still valid, rebuild succeeds and harvest updates.
    try writeTreeFile(io, work, "content/guides/target.md",
        \\---
        \\title: Target
        \\parent: guides
        \\---
        \\
        \\# Section One
        \\
        \\Body changed.
        \\
    );
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .incremental = true,
        .quiet = true,
    });
    const harvest3 = try readFileAlloc(io, cwd, harvest_path, gpa);
    defer gpa.free(harvest3);
    try std.testing.expect(std.mem.indexOf(u8, harvest3, "section-one") != null);
    // Harvest key must have changed (source bytes changed).
    try std.testing.expect(!std.mem.eql(u8, harvest1, harvest3));

    const index_after = try readAllFile(io, dist_dir, "index.html", gpa);
    defer gpa.free(index_after);
    try std.testing.expect(std.mem.indexOf(u8, index_after, "guides/target.html#section-one") != null);
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

test "Feature 9 HTML: no fragment links skips heading-index render work path" {
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

    _ = try compileHtmlSiteMulti(io, gpa, &.{
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

test "F9.1 default managed Boris theme publishes its stylesheet" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-f91-legacy", .{tmp.sub_path});
    defer gpa.free(dist);

    // Use real sample content + the product default managed theme.
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "content",
        .dist_dir = dist,
        .layout_path = "themes/boris/layouts/main.html",
        .quiet = true,
    });
    try std.testing.expect(stats.pages_written > 0);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-boris-search-root") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "skip-link") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"assets/css/boris.css\"") != null);
    const css_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/boris.css", .{dist});
    defer gpa.free(css_path);
    const css = try readFileAlloc(io, cwd, css_path, gpa);
    defer gpa.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".site-sidebar") != null);
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
    try cwd.createDirPath(io, "layouts");
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

test "F9.2 non-incremental stale-HTML sweep preserves theme-owned .html assets" {
    // #61: full (non-incremental) stale cleanup walks dist/**/*.html and deletes
    // anything not in the live page set. Theme assets like assets/embed.html are
    // published into dist/ by copyAssetsToOutput and must survive that prune.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f92-stale-html-theme-asset", .{tmp.sub_path});
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
        \\<html><a href="{{asset-url assets/embed.html}}">{{content}}</a></html>
    );
    try writeTreeFile(io, work, "theme/assets/embed.html", "<div id=\"embed\">ok</div>\n");
    try writeTreeFile(io, work, "theme/assets/css/a.css", "body{}\n");

    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    // Explicit non-incremental full build (the buggy path).
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = false,
    });

    const embed_path = try std.fmt.allocPrint(gpa, "{s}/assets/embed.html", .{dist});
    defer gpa.free(embed_path);
    const embed = try readFileAlloc(io, cwd, embed_path, gpa);
    defer gpa.free(embed);
    try std.testing.expectEqualStrings("<div id=\"embed\">ok</div>\n", embed);

    // Page output still published; theme asset is not mistaken for a page.
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    try cwd.access(io, index_path, .{});

    // Second full build must keep the theme .html asset (re-publish + sweep).
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = false,
    });
    const embed2 = try readFileAlloc(io, cwd, embed_path, gpa);
    defer gpa.free(embed2);
    try std.testing.expectEqualStrings("<div id=\"embed\">ok</div>\n", embed2);

    // True stale page html still gets pruned.
    const stale_path = try std.fmt.allocPrint(gpa, "{s}/gone.html", .{dist});
    defer gpa.free(stale_path);
    try writeTreeFile(io, dist, "gone.html", "<html>stale</html>\n");
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = false,
    });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stale_path, .{}));
    // Theme asset still present after pruning a real stale page.
    const embed3 = try readFileAlloc(io, cwd, embed_path, gpa);
    defer gpa.free(embed3);
    try std.testing.expectEqualStrings("<div id=\"embed\">ok</div>\n", embed3);
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
    _ = try compileHtmlSiteMulti(io, gpa, &.{
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

// =============================================================================
// Content-local page assets (post-v0.5.0)
// =============================================================================

test "content-local assets: happy path rewrite and copy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-happy2", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md",
        \\---
        \\title: Intro
        \\---
        \\
        \\# Intro
        \\
        \\![diagram](intro.assets/diagram.svg)
        \\
    );
    try writeTreeFile(io, work, "content/guides/intro.assets/diagram.svg", "<svg id=\"v1\"/>");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    const html_path = try std.fmt.allocPrint(gpa, "{s}/guides/intro.html", .{dist});
    defer gpa.free(html_path);
    const html = try readFileAlloc(io, cwd, html_path, gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "intro.assets/diagram.svg") != null);

    const asset_path = try std.fmt.allocPrint(gpa, "{s}/guides/intro.assets/diagram.svg", .{dist});
    defer gpa.free(asset_path);
    const asset = try readFileAlloc(io, cwd, asset_path, gpa);
    defer gpa.free(asset);
    try std.testing.expectEqualStrings("<svg id=\"v1\"/>", asset);
}

test "content-local assets: active SVG fails before HTML publish" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-active-svg", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\![logo](index.assets/logo.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/logo.svg", "<svg><script>fetch('https://attacker.example')</script></svg>");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetUnsafeSvg, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-stage", .{dist});
    defer gpa.free(stage);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, dist, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, stage, .{}));
}

test "content-local assets: byte change does not re-render HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-bytes", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\![d](index.assets/d.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/d.svg", "v1");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    const html_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(html_path);
    const html_before = try readFileAlloc(io, cwd, html_path, gpa);
    defer gpa.free(html_before);

    try writeTreeFile(io, work, "content/index.assets/d.svg", "v2-bytes-changed");
    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
        .incremental = true,
    });
    try std.testing.expectEqual(@as(usize, 0), stats.pages_written);

    const html_after = try readFileAlloc(io, cwd, html_path, gpa);
    defer gpa.free(html_after);
    try std.testing.expectEqualStrings(html_before, html_after);

    const asset_path = try std.fmt.allocPrint(gpa, "{s}/index.assets/d.svg", .{dist});
    defer gpa.free(asset_path);
    const asset = try readFileAlloc(io, cwd, asset_path, gpa);
    defer gpa.free(asset);
    try std.testing.expectEqualStrings("v2-bytes-changed", asset);
}

test "content-local assets: rejects traversal outside tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-hostile", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/guides/intro.md",
        \\---
        \\title: Intro
        \\---
        \\
        \\![x](../secret.png)
        \\
    );
    try writeTreeFile(io, work, "content/secret.png", "nope");
    try writeTreeFile(io, work, "content/guides/intro.assets/ok.svg", "ok");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: rejects absolute and backslash destinations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-abs", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");
    try writeTreeFile(io, work, "content/index.assets/x.svg", "x");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![x](/etc/passwd)
        \\
    );
    try std.testing.expectError(error.AssetFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![x](index.assets\x.svg)
        \\
    );
    try std.testing.expectError(error.AssetFailed, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: rejects symlink leaf when host allows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-symlink", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![x](index.assets/link.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/real.svg", "real");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const assets_dir = try std.fmt.allocPrint(gpa, "{s}/content/index.assets", .{work});
    defer gpa.free(assets_dir);
    var adir = try cwd.openDir(io, assets_dir, .{});
    defer adir.close(io);
    adir.symLink(io, "real.svg", "link.svg", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    try std.testing.expectError(error.AssetSymlink, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    }));
}

test "content-local assets: stale cleanup and theme isolation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-stale", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![a](index.assets/keep.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/keep.svg", "keep");
    try writeTreeFile(io, work, "content/index.assets/drop.svg", "drop");
    try writeTreeFile(io, work, "theme/layouts/main.html",
        \\<html><link href="{{asset-url assets/css/docs.css}}">{{content}}</html>
    );
    try writeTreeFile(io, work, "theme/assets/css/docs.css", "theme-css");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/theme/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    const drop_src = try std.fmt.allocPrint(gpa, "{s}/content/index.assets/drop.svg", .{work});
    defer gpa.free(drop_src);
    try cwd.deleteFile(io, drop_src);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });

    const drop_out = try std.fmt.allocPrint(gpa, "{s}/index.assets/drop.svg", .{dist});
    defer gpa.free(drop_out);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, drop_out, .{}));

    const theme_path = try std.fmt.allocPrint(gpa, "{s}/assets/css/docs.css", .{dist});
    defer gpa.free(theme_path);
    const theme_bytes = try readFileAlloc(io, cwd, theme_path, gpa);
    defer gpa.free(theme_bytes);
    try std.testing.expectEqualStrings("theme-css", theme_bytes);

    const keep_path = try std.fmt.allocPrint(gpa, "{s}/index.assets/keep.svg", .{dist});
    defer gpa.free(keep_path);
    const keep = try readFileAlloc(io, cwd, keep_path, gpa);
    defer gpa.free(keep);
    try std.testing.expectEqualStrings("keep", keep);
}

test "content-local assets: multi-target isolation and deterministic bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-mt", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![d](index.assets/d.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/d.svg", "payload");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist_a = try std.fmt.allocPrint(gpa, "{s}/out-a", .{work});
    defer gpa.free(dist_a);
    const dist_b = try std.fmt.allocPrint(gpa, "{s}/out-b", .{work});
    defer gpa.free(dist_b);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "a", .output_dir = dist_a, .layout_path = layout },
        .{ .name = "b", .output_dir = dist_b, .layout_path = layout },
    };
    _ = try compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
    });

    const path_a = try std.fmt.allocPrint(gpa, "{s}/index.assets/d.svg", .{dist_a});
    defer gpa.free(path_a);
    const path_b = try std.fmt.allocPrint(gpa, "{s}/index.assets/d.svg", .{dist_b});
    defer gpa.free(path_b);
    const a = try readFileAlloc(io, cwd, path_a, gpa);
    defer gpa.free(a);
    const b = try readFileAlloc(io, cwd, path_b, gpa);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("payload", a);
    try std.testing.expectEqualStrings(a, b);

    try cwd.writeFile(io, .{ .sub_path = path_a, .data = "mutated-a" });
    const b2 = try readFileAlloc(io, cwd, path_b, gpa);
    defer gpa.free(b2);
    try std.testing.expectEqualStrings("payload", b2);
}

test "content-local assets: two builds are byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cla-det", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: H
        \\---
        \\![d](index.assets/z.svg)
        \\![d2](index.assets/a.svg)
        \\
    );
    try writeTreeFile(io, work, "content/index.assets/z.svg", "z");
    try writeTreeFile(io, work, "content/index.assets/a.svg", "a");
    try writeTreeFile(io, work, "layouts/main.html", "<html>{{content}}</html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist1 = try std.fmt.allocPrint(gpa, "{s}/d1", .{work});
    defer gpa.free(dist1);
    const dist2 = try std.fmt.allocPrint(gpa, "{s}/d2", .{work});
    defer gpa.free(dist2);

    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist1, .layout_path = layout, .quiet = true });
    _ = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist2, .layout_path = layout, .quiet = true });

    const html1_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist1});
    defer gpa.free(html1_path);
    const html2_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist2});
    defer gpa.free(html2_path);
    const html1 = try readFileAlloc(io, cwd, html1_path, gpa);
    defer gpa.free(html1);
    const html2 = try readFileAlloc(io, cwd, html2_path, gpa);
    defer gpa.free(html2);
    try std.testing.expectEqualStrings(html1, html2);

    const a1p = try std.fmt.allocPrint(gpa, "{s}/index.assets/a.svg", .{dist1});
    defer gpa.free(a1p);
    const a2p = try std.fmt.allocPrint(gpa, "{s}/index.assets/a.svg", .{dist2});
    defer gpa.free(a2p);
    const a1 = try readFileAlloc(io, cwd, a1p, gpa);
    defer gpa.free(a1);
    const a2 = try readFileAlloc(io, cwd, a2p, gpa);
    defer gpa.free(a2);
    try std.testing.expectEqualStrings(a1, a2);
}

// =============================================================================
// Optional example: reference theme (themes/reference + examples/reference-site)
// =============================================================================

test "example reference-theme: layouts, components, page-local assets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-example-reference-theme", .{tmp.sub_path});
    defer gpa.free(dist);

    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = "themes/reference/layouts/home.html" },
        .{ .kind = .role, .value = "trunk", .layout_path = "themes/reference/layouts/section.html" },
    };

    const stats = try compileHtmlSite(io, gpa, .{
        .content_root = "examples/reference-site/content",
        .dist_dir = dist,
        .layout_path = "themes/reference/layouts/main.html",
        .layout_rules = &rules,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 6), stats.pages_written);

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{dist});
    defer gpa.free(index_path);
    const index_html = try readFileAlloc(io, cwd, index_path, gpa);
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "data-layout=\"home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "href=\"assets/css/reference.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "index.assets/rhythm-diagram.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "site-nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "admonition--tip") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "http://") == null);

    const guides_path = try std.fmt.allocPrint(gpa, "{s}/guides.html", .{dist});
    defer gpa.free(guides_path);
    const guides_html = try readFileAlloc(io, cwd, guides_path, gpa);
    defer gpa.free(guides_html);
    try std.testing.expect(std.mem.indexOf(u8, guides_html, "data-layout=\"section\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, guides_html, "page-children") != null);

    const components_path = try std.fmt.allocPrint(gpa, "{s}/guides/components.html", .{dist});
    defer gpa.free(components_path);
    const components_html = try readFileAlloc(io, cwd, components_path, gpa);
    defer gpa.free(components_html);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "data-layout=\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "page-toc") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "class=\"details\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "components.assets/component-flow.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, components_html, "href=\"../assets/css/reference.css\"") != null);

    const theme_css_out = try std.fmt.allocPrint(gpa, "{s}/assets/css/reference.css", .{dist});
    defer gpa.free(theme_css_out);
    const copied_css = try readFileAlloc(io, cwd, theme_css_out, gpa);
    defer gpa.free(copied_css);
    const theme_css = try readFileAlloc(io, cwd, "themes/reference/assets/css/reference.css", gpa);
    defer gpa.free(theme_css);
    try std.testing.expectEqualStrings(theme_css, copied_css);

    const local_asset = try std.fmt.allocPrint(gpa, "{s}/index.assets/rhythm-diagram.svg", .{dist});
    defer gpa.free(local_asset);
    const local_bytes = try readFileAlloc(io, cwd, local_asset, gpa);
    defer gpa.free(local_bytes);
    try std.testing.expect(local_bytes.len > 0);
}

test "quiet publication-check failure diagnostic is captured with the committed-target wording" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePublicationChecksFailure(&output.writer, "public", error.CheckerExecutionFailed);
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'public', but publication-check evidence was not refreshed: CheckerExecutionFailed\n",
        output.writer.buffered(),
    );
}

test "ordinary Doctor findings do not fail HTML publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ordinary-publication-finding", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nOrdinary content finding.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body><div id=duplicate></div><span id=duplicate></span>{{content}}</body></html>");
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);

    const stats = try compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);
    const inventory_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(inventory_bytes);
    const page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(page);
    var inventory = try std.json.parseFromSlice(std.json.Value, gpa, inventory_bytes, .{});
    defer inventory.deinit();
    try expectArtifactRecord(inventory.value, "index.html", "html-page", "html-render", page);

    const checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    var checks = try std.json.parseFromSlice(std.json.Value, gpa, checks_bytes, .{});
    defer checks.deinit();
    const root = checks.value.object;
    const check_list = root.get("checks").?.array.items;
    try std.testing.expectEqualStrings("failed", check_list[1].object.get("status").?.string);
    try std.testing.expectEqualStrings("complete", check_list[1].object.get("coverage").?.string);
    var found_duplicate = false;
    for (root.get("findings").?.array.items) |finding| {
        if (std.mem.eql(u8, finding.object.get("code").?.string, "HTML_DUPLICATE_ID")) found_duplicate = true;
    }
    try std.testing.expect(found_duplicate);
}

test "post-commit checker failure preserves stale checks while exposing changed payload and inventory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/stale-publication-checks", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(old_page);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");
    var failure_options = options;
    failure_options.test_fail_publication_checks = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationChecksFailed, compileHtmlSite(io, gpa, failure_options));

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(new_page);
    try std.testing.expectEqualStrings(old_checks, new_checks);
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_page, new_page));
    var old_report = try std.json.parseFromSlice(std.json.Value, gpa, old_checks, .{});
    defer old_report.deinit();
    const old_binding = old_report.value.object.get("artifact_inventory").?.object.get("sha256").?.string;
    const new_digest = cache.hexDigest(cache.hashBytes(new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_binding, &new_digest));
}

// ---------------------------------------------------------------------------
// Publication claims integration.
// ---------------------------------------------------------------------------

fn expectPublicationClaimsShape(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    target: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(publication_claims.report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, publication_claims.schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings(target, root.get("target").?.string);
    try std.testing.expectEqualStrings(publication_claims.claim_ids[0], root.get("claims").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqualStrings(publication_claims.claim_ids[1], root.get("claims").?.array.items[1].object.get("id").?.string);
    try std.testing.expectEqualStrings(publication_claims.claim_ids[2], root.get("claims").?.array.items[2].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 6), root.get("limitations").?.array.items.len);
    for (root.get("claims").?.array.items) |claim| {
        try std.testing.expectEqualStrings("verified", claim.object.get("status").?.string);
        const evidence = claim.object.get("evidence").?.object;
        try std.testing.expectEqualStrings("passed", evidence.get("check_status").?.string);
        try std.testing.expectEqualStrings("complete", evidence.get("coverage").?.string);
        try std.testing.expectEqualStrings(
            root.get("publication_checks").?.object.get("sha256").?.string,
            evidence.get("checks_report_sha256").?.string,
        );
    }
}

test "claims evidence follows checks on every committed publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-fresh", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const claims_bytes = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(claims_bytes);
    try expectPublicationClaimsShape(gpa, claims_bytes, "default");

    const checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    const checks_digest = cache.hexDigest(cache.hashBytes(checks_bytes));
    var claims = try std.json.parseFromSlice(std.json.Value, gpa, claims_bytes, .{});
    defer claims.deinit();
    try std.testing.expectEqualStrings(
        &checks_digest,
        claims.value.object.get("publication_checks").?.object.get("sha256").?.string,
    );
    try std.testing.expectEqual(@as(i64, 3), claims.value.object.get("publication_checks").?.object.get("check_count").?.integer);

    const artifacts_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(artifacts_bytes);
    const artifacts_digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    try std.testing.expectEqualStrings(
        &artifacts_digest,
        claims.value.object.get("artifact_inventory").?.object.get("sha256").?.string,
    );

    _ = try compileHtmlSite(io, gpa, options);
    const repeat_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(repeat_claims);
    try std.testing.expectEqualStrings(claims_bytes, repeat_claims);
}

test "claims failure preserves committed payloads, inventory, checks, and prior claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(old_page);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");
    var failure_options = options;
    failure_options.test_fail_publication_claims = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationClaimsFailed, compileHtmlSite(io, gpa, failure_options));

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(new_page);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expectEqualStrings(old_claims, new_claims);
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_checks, new_checks));
    try std.testing.expect(!std.mem.eql(u8, old_page, new_page));
    var stale_claims = try std.json.parseFromSlice(std.json.Value, gpa, new_claims, .{});
    defer stale_claims.deinit();
    const stale_binding = stale_claims.value.object.get("publication_checks").?.object.get("sha256").?.string;
    const fresh_checks_digest = cache.hexDigest(cache.hashBytes(new_checks));
    try std.testing.expect(!std.mem.eql(u8, stale_binding, &fresh_checks_digest));
}

test "claims write failure preserves the prior claims report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-write-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    var failure_options = options;
    failure_options.test_fail_publication_claims_write = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationClaimsFailed, compileHtmlSite(io, gpa, failure_options));
    const after = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(old_claims, after);
}

test "quiet claims failure emits the captured diagnostic and preserves prior claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-captured-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");

    // The diagnostic is emitted even under --quiet; capture it instead of the
    // process stderr and prove the exact committed-target wording.
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_publication_claims = true;
    failure_options.refresh_evidence = true;
    failure_options.publication_claims_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationClaimsFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but publication-claims evidence was not refreshed: InvalidChecksReport\n",
        output.writer.buffered(),
    );

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_checks, new_checks));
    try std.testing.expectEqualStrings(old_claims, new_claims);
}

test "multi-target publication derives claims per target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-claims-multi", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist_a = try std.fmt.allocPrint(gpa, "{s}/dist_a", .{work});
    defer gpa.free(dist_a);
    const dist_b = try std.fmt.allocPrint(gpa, "{s}/dist_b", .{work});
    defer gpa.free(dist_b);

    const targets = [_]target_mod.TargetSpec{
        .{ .name = "alpha", .output_dir = dist_a },
        .{ .name = "beta", .output_dir = dist_b },
    };
    _ = try compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .layout_path = layout,
        .quiet = true,
    });

    const claims_a = try readTargetPayload(io, gpa, dist_a, publication_claims.output_path);
    defer gpa.free(claims_a);
    const claims_b = try readTargetPayload(io, gpa, dist_b, publication_claims.output_path);
    defer gpa.free(claims_b);
    try expectPublicationClaimsShape(gpa, claims_a, "alpha");
    try expectPublicationClaimsShape(gpa, claims_b, "beta");
    var parsed_a = try std.json.parseFromSlice(std.json.Value, gpa, claims_a, .{});
    defer parsed_a.deinit();
    var parsed_b = try std.json.parseFromSlice(std.json.Value, gpa, claims_b, .{});
    defer parsed_b.deinit();
    try std.testing.expect(!std.mem.eql(
        u8,
        parsed_a.value.object.get("publication_checks").?.object.get("sha256").?.string,
        parsed_b.value.object.get("publication_checks").?.object.get("sha256").?.string,
    ));
}

test "touches evidence follows claims on every committed publication" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-fresh", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const touches_bytes = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(touches_bytes);
    var touches = try std.json.parseFromSlice(std.json.Value, gpa, touches_bytes, .{});
    defer touches.deinit();
    try std.testing.expectEqualStrings(publication_touches.report_format, touches.value.object.get("format").?.string);
    try std.testing.expectEqual(@as(i64, publication_touches.schema_version), touches.value.object.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("default", touches.value.object.get("target").?.string);
    // The clean single-page site still carries the fixed registries: 1 target
    // + artifacts + 3 checks + 3 claims + 6 limitations.
    const node_count = touches.value.object.get("nodes").?.array.items.len;
    try std.testing.expect(node_count >= 1 + 3 + 3 + 6);

    const checks_bytes = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    const checks_digest = cache.hexDigest(cache.hashBytes(checks_bytes));
    try std.testing.expectEqualStrings(
        &checks_digest,
        touches.value.object.get("inputs").?.object.get("checks").?.object.get("sha256").?.string,
    );

    const artifacts_bytes = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(artifacts_bytes);
    const artifacts_digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    try std.testing.expectEqualStrings(
        &artifacts_digest,
        touches.value.object.get("inputs").?.object.get("artifacts").?.object.get("sha256").?.string,
    );

    _ = try compileHtmlSite(io, gpa, options);
    const repeat_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(repeat_touches);
    try std.testing.expectEqualStrings(touches_bytes, repeat_touches);
}

test "touches failure preserves committed payloads, inventory, checks, claims, and prior touches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);
    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(old_page);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");
    var failure_options = options;
    failure_options.test_fail_publication_touches = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationTouchesFailed, compileHtmlSite(io, gpa, failure_options));

    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    const new_page = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(new_page);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    // Payloads, inventory, checks, and claims all advanced; the prior touches
    // report is preserved byte-for-byte.
    try std.testing.expect(!std.mem.eql(u8, old_inventory, new_inventory));
    try std.testing.expect(!std.mem.eql(u8, old_checks, new_checks));
    try std.testing.expect(!std.mem.eql(u8, old_page, new_page));
    try std.testing.expect(!std.mem.eql(u8, old_claims, new_claims));
    try std.testing.expectEqualStrings(old_touches, new_touches);
}

test "touches write failure preserves the prior touches report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-write-failure", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);
    var failure_options = options;
    failure_options.test_fail_publication_touches_write = true;
    failure_options.refresh_evidence = true;
    try std.testing.expectError(error.PublicationTouchesFailed, compileHtmlSite(io, gpa, failure_options));
    const after = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(old_touches, after);
}

test "quiet touches failure emits the captured diagnostic and preserves prior touches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-touches-captured-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .incremental = true, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);

    try writeTreeFile(io, work, "content/index.md", "# Home\n\nChanged source body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>changed layout</footer></body></html>");

    // The diagnostic is emitted even under --quiet; capture it instead of the
    // process stderr and prove the exact committed-target wording.
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_publication_touches = true;
    failure_options.refresh_evidence = true;
    failure_options.publication_touches_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationTouchesFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but the Touch Atlas was not refreshed: InvalidClaimsReport\n",
        output.writer.buffered(),
    );

    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    try std.testing.expectEqualStrings(old_touches, new_touches);
}

test "quiet proof-pack failure emits the captured not-refreshed diagnostic and preserves all four evidence reports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-proof-pack-captured-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nBody.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}</body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);
    const old_json = try readTargetPayload(io, gpa, dist, publication_proof_pack.output_path);
    defer gpa.free(old_json);
    const old_html = try readTargetPayload(io, gpa, dist, publication_proof_pack.index_output_path);
    defer gpa.free(old_html);

    // The diagnostic is emitted even under --quiet; capture it instead of the
    // process stderr and prove the exact committed-target wording. main.zig's
    // mapHtmlError maps PublicationProofPackFailed to exit 3 (io_error).
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_publication_proof_pack = true;
    failure_options.refresh_evidence = true;
    failure_options.publication_proof_pack_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationProofPackFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but Proof Pack presentation was not refreshed: InvalidTouchesReport\n",
        output.writer.buffered(),
    );

    // The execution fault fires before any presentation write, so all four
    // evidence reports and the prior pair are byte-unchanged.
    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    try std.testing.expectEqualStrings(old_inventory, new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    try std.testing.expectEqualStrings(old_checks, new_checks);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expectEqualStrings(old_claims, new_claims);
    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    try std.testing.expectEqualStrings(old_touches, new_touches);
    const new_json = try readTargetPayload(io, gpa, dist, publication_proof_pack.output_path);
    defer gpa.free(new_json);
    try std.testing.expectEqualStrings(old_json, new_json);
    const new_html = try readTargetPayload(io, gpa, dist, publication_proof_pack.index_output_path);
    defer gpa.free(new_html);
    try std.testing.expectEqualStrings(old_html, new_html);
}

test "proof-pack restore failure surfaces the recovery-failed diagnostic and preserves all four evidence reports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/publication-proof-pack-restore-stderr", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    try writeTreeFile(io, work, "content/index.md", "# Home\n\nInitial body.\n");
    try writeTreeFile(io, work, "layouts/main.html", "<html><body>{{content}}<footer>initial</footer></body></html>");

    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const options: CompileOptions = .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true };
    _ = try compileHtmlSite(io, gpa, options);

    const old_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(old_inventory);
    const old_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(old_checks);
    const old_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(old_claims);
    const old_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(old_touches);

    // Install HTML first, then fail its restoration: the rollback cannot
    // restore the preserved HTML, so RestoreHtmlFailed propagates and the
    // contract's recovery-failed diagnostic is emitted (even under --quiet).
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var failure_options = options;
    failure_options.test_fail_proof_pack_install_html = true;
    failure_options.test_fail_proof_pack_restore_html = true;
    failure_options.publication_proof_pack_failure_writer = &output.writer;
    try std.testing.expectError(error.PublicationProofPackFailed, compileHtmlSite(io, gpa, failure_options));
    try std.testing.expectEqualStrings(
        "error: publication committed for target 'default', but Proof Pack presentation recovery failed; the current pair may be split or absent: RestoreHtmlFailed\n",
        output.writer.buffered(),
    );

    // Even when rollback itself fails, the four evidence reports committed
    // before the presentation transaction are byte-unchanged.
    const new_inventory = try readArtifactInventory(io, gpa, dist);
    defer gpa.free(new_inventory);
    try std.testing.expectEqualStrings(old_inventory, new_inventory);
    const new_checks = try readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(new_checks);
    try std.testing.expectEqualStrings(old_checks, new_checks);
    const new_claims = try readTargetPayload(io, gpa, dist, publication_claims.output_path);
    defer gpa.free(new_claims);
    try std.testing.expectEqualStrings(old_claims, new_claims);
    const new_touches = try readTargetPayload(io, gpa, dist, publication_touches.output_path);
    defer gpa.free(new_touches);
    try std.testing.expectEqualStrings(old_touches, new_touches);
}

test "standard-site verification emits head links, well-known file, and report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-standard-site-emit", .{tmp.sub_path});
    defer gpa.free(work);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    try writeTreeFile(io, work, "layouts/main.html",
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <title>{{title}}</title>
        \\  {{head}}
        \\</head>
        \\<body>{{content}}</body>
        \\</html>
        \\
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\published_at: 2026-08-15T00:00:00Z
        \\summary: The front page.
        \\---
        \\# Home
        \\
    );
    try writeTreeFile(io, work, "content/guide.md",
        \\---
        \\title: Guide
        \\published_at: 2026-08-15T00:00:00Z
        \\summary: The guide.
        \\---
        \\# Guide
        \\
    );
    try writeTreeFile(io, work, "content/draft.md",
        \\---
        \\title: Draft
        \\status: draft
        \\---
        \\# Draft
        \\
    );

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
    try std.testing.expect(layout.has_head);

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    var page_inputs: std.ArrayList(standard_site.PageInput) = .empty;
    defer page_inputs.deinit(gpa);
    for (db.items()) |p| {
        try page_inputs.append(gpa, .{
            .entity_id = p.entity_id,
            .output_path = p.output_path,
            .title = p.title,
            .status = if (p.status) |s| switch (s) {
                .published => .published,
                .archived => .archived,
                .draft => .draft,
            } else .none,
            .published_at = p.published_at,
            .summary = p.summary,
            .tags = p.tags,
        });
    }

    var config: standard_site.TargetConfig = .{
        .location = try standard_site.parseLocation(gpa, "https://example.com/", "https://example.com", ""),
        .did = try gpa.dupe(u8, "did:plc:testtesttesttesttest"),
    };
    defer config.deinit(gpa);
    var projection = try standard_site.project(gpa, .{
        .config = &config,
        .site_title = "Boris",
        .pages = page_inputs.items,
    });
    defer projection.deinit(gpa);
    const surfaces = try standard_site.verificationSurfaces(gpa, &config, &projection);
    defer {
        gpa.free(surfaces.well_known.content);
        gpa.free(surfaces.well_known.required_public_url);
        if (surfaces.well_known.project_path) |path| gpa.free(path);
        for (surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(surfaces.document_links);
    }
    const vctx: standard_site_emit.VerificationContext = .{ .surfaces = &surfaces, .projection = &projection };

    const stats = try compilePages(io, gpa, &db, layout, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .standard_site_verification = &vctx,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.pages_written);

    // Eligible pages carry the exact document AT-URI in <head>, never the body.
    const index_html = try readTargetPayload(io, gpa, dist, "index.html");
    defer gpa.free(index_html);
    const index_at_uri = standard_site_emit.documentAtUri(gpa, &surfaces, "index").?;
    try std.testing.expect(std.mem.indexOf(u8, index_html, index_at_uri) != null);
    const head_open = std.mem.indexOf(u8, index_html, "<head>").?;
    const body_open = std.mem.indexOf(u8, index_html, "<body>").?;
    const link_pos = std.mem.indexOf(u8, index_html, "site.standard.document").?;
    try std.testing.expect(link_pos > head_open and link_pos < body_open);

    // The well-known file matches the configured publication location.
    const well_known_bytes = try readTargetPayload(io, gpa, dist, standard_site.well_known_path);
    defer gpa.free(well_known_bytes);
    try std.testing.expectEqualStrings(projection.publication.at_uri, well_known_bytes);

    // The report records emitted documents (never ineligible drafts).
    const report_json = try readTargetPayload(io, gpa, dist, standard_site_emit.report_output_path);
    defer gpa.free(report_json);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"emitted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"draft\"") == null);
}

test "standard-site base-path build records limited and reports missing head slots" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-standard-site-limited", .{tmp.sub_path});
    defer gpa.free(work);
    const content = try std.fmt.allocPrint(gpa, "{s}/content", .{work});
    defer gpa.free(content);
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist", .{work});
    defer gpa.free(dist);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{work});
    defer gpa.free(layout_path);

    // Layout deliberately omits the compiler-owned {{head}} slot.
    try writeTreeFile(io, work, "layouts/main.html",
        \\<html>
        \\<head><title>{{title}}</title></head>
        \\<body>{{content}}</body>
        \\</html>
        \\
    );
    try writeTreeFile(io, work, "content/index.md",
        \\---
        \\title: Home
        \\published_at: 2026-08-15T00:00:00Z
        \\summary: The front page.
        \\---
        \\# Home
        \\
    );

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try loadLayoutOnce(io, cwd, layout_path, layout_arena.allocator());
    try std.testing.expect(!layout.has_head);

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromote(io, gpa, &db, content);

    var page_inputs: std.ArrayList(standard_site.PageInput) = .empty;
    defer page_inputs.deinit(gpa);
    for (db.items()) |p| {
        try page_inputs.append(gpa, .{
            .entity_id = p.entity_id,
            .output_path = p.output_path,
            .title = p.title,
            .status = if (p.status) |s| switch (s) {
                .published => .published,
                .archived => .archived,
                .draft => .draft,
            } else .none,
            .published_at = p.published_at,
            .summary = p.summary,
            .tags = p.tags,
        });
    }

    var config: standard_site.TargetConfig = .{
        .location = try standard_site.parseLocation(gpa, "https://example.com/repo/", "https://example.com", "/repo"),
        .did = try gpa.dupe(u8, "did:plc:testtesttesttesttest"),
    };
    defer config.deinit(gpa);
    var projection = try standard_site.project(gpa, .{
        .config = &config,
        .site_title = "Boris",
        .pages = page_inputs.items,
    });
    defer projection.deinit(gpa);
    const surfaces = try standard_site.verificationSurfaces(gpa, &config, &projection);
    defer {
        gpa.free(surfaces.well_known.content);
        gpa.free(surfaces.well_known.required_public_url);
        if (surfaces.well_known.project_path) |path| gpa.free(path);
        for (surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(surfaces.document_links);
    }
    const vctx: standard_site_emit.VerificationContext = .{ .surfaces = &surfaces, .projection = &projection };

    var collector = diag.Collector.init(gpa, io);
    defer collector.deinit();

    const stats = try compilePages(io, gpa, &db, layout, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
        .standard_site_verification = &vctx,
        .diagnostics = &collector,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);

    // The base-path limitation is explicit: no plausible public well-known
    // file, the exact bytes preserved as a sideband artifact, and the
    // report records `limited` plus the missing-head `not_verified` page.
    try std.testing.expectError(error.FileNotFound, readTargetPayload(io, gpa, dist, standard_site.well_known_path));
    const sideband = try readTargetPayload(io, gpa, dist, standard_site_emit.sideband_output_path);
    defer gpa.free(sideband);
    try std.testing.expectEqualStrings(projection.publication.at_uri, sideband);

    const report_json = try readTargetPayload(io, gpa, dist, standard_site_emit.report_output_path);
    defer gpa.free(report_json);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"limited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_json, "\"not_verified\"") != null);

    // Layouts that omit {{head}} are reported so absence is never silent.
    var saw_head_warning = false;
    for (collector.list.items) |d| {
        if (d.code == .EVERIFICATIONHEAD and d.severity == .warning) saw_head_warning = true;
    }
    try std.testing.expect(saw_head_warning);
}
