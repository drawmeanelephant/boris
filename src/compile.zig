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
const static_files = @import("static_files.zig");
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

pub fn writePublicationChecksFailure(
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
    /// Project-relative static passthrough directory (#804). When set, its
    /// contents are copied byte-identically into the target root and declared
    /// as `static-file` inventory records. Null disables the projection.
    static_dir: ?[]const u8 = null,
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
    /// Additive build provenance (#781): the opaque VCS revision token this
    /// binary was compiled from ("" when undetected). Carried only into the
    /// Proof Pack presentation pair; never into any evidence report.
    vcs_revision: []const u8 = "",
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

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
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
    // Diagnostic parity with the native path below (#909): a missing or
    // broken layout is an ordinary, author-fixable content fault, so it is
    // mapped into the collector here instead of surfacing as an opaque
    // embed ABI error.
    const layout = loadLayoutForOptions(io, Io.Dir.cwd(), options, layout_arena.allocator()) catch |err| {
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

    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    var db = PageDb.init(gpa, retain_arena.allocator());
    defer db.deinit();
    try loadAndPromoteFromProvider(io, gpa, &db, sources, options.input_format, options.timings, options.diagnostics);

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
    return loadAndPromoteFormat(io, gpa, db, content_root, .markdown, null, null);
}

pub fn loadAndPromoteFormat(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    content_root: []const u8,
    input_format: identity.InputFormat,
    recorder: ?*timings.Recorder,
    /// Optional HTML-path diagnostic collector: parse-category failures are
    /// appended here in addition to stderr so `--report` never degrades to a
    /// bare `EIO: ParseFailed` fallback (#829).
    diagnostics: ?*diag.Collector,
) !void {
    var scan_list = page_mod.PageList.init(gpa, db.retain);
    defer scan_list.deinit();

    if (recorder) |t| t.start(.scan);
    scanner.scan(io, .{ .content_root = content_root, .input_format = input_format }, &scan_list) catch |err| switch (err) {
        error.ContentDirMissing => return error.ContentDirMissing,
        error.InvalidPath => {
            // The scanner records the offending walk path on the page list
            // (#851); name the file instead of failing with a bare
            // InvalidPath that leaves the author bisecting the content tree.
            if (!diag.text_suppressed.load(.unordered)) {
                if (scan_list.invalid_path) |p| {
                    std.debug.print("error: {s}: {s}/{s}: not a valid page path [{s}]\n", .{
                        diag.Code.EINVALIDPATH.name(),
                        content_root,
                        p,
                        "Rename the file; page paths cannot contain spaces, '..', or absolute segments",
                    });
                } else {
                    std.debug.print("error: {s}: {s} [{s}]\n", .{
                        diag.Code.EINVALIDPATH.name(),
                        "content path or entity id cannot be canonicalized",
                        "Rename paths so they have no empty, ., or .. segments",
                    });
                }
            }
            if (diagnostics) |collector| {
                collector.append(.{
                    .severity = .error_,
                    .code = .EINVALIDPATH,
                    .message = if (scan_list.invalid_path) |p|
                        try std.fmt.allocPrint(gpa, "{s}/{s}: not a valid page path", .{ content_root, p })
                    else
                        try gpa.dupe(u8, "content path or entity id cannot be canonicalized"),
                    .remediation = try gpa.dupe(u8, "Rename the file; page paths cannot contain spaces, '..', or absolute segments"),
                    .source_path = if (scan_list.invalid_path) |p| p else content_root,
                });
            }
            return error.InvalidPath;
        },
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

    return promoteScannedPages(io, gpa, db, content_root, input_format, recorder, &scan_list, null, diagnostics);
}

fn loadAndPromoteFromProvider(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    sources: source_provider.Provider,
    input_format: identity.InputFormat,
    recorder: ?*timings.Recorder,
    diagnostics: ?*diag.Collector,
) !void {
    var scan_list = page_mod.PageList.init(gpa, db.retain);
    defer scan_list.deinit();
    if (recorder) |t| t.start(.scan);
    try sources.scan(&scan_list);
    if (recorder) |t| t.stop(.scan);
    return promoteScannedPages(io, gpa, db, "", input_format, recorder, &scan_list, sources, diagnostics);
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
    diagnostics: ?*diag.Collector,
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
            // The structured parse diagnostic must reach the optional HTML-path
            // collector as well as stderr: a content-only failure must not
            // reduce `--report` to a bare `EIO: ParseFailed` fallback (#829).
            const d: diag.Diagnostic = .{
                .severity = .error_,
                .code = diag.parserCategoryToCode(pd.category),
                .message = pd.message,
                .remediation = if (pd.remediation.len > 0) pd.remediation else "Fix the frontmatter or encoding for this file",
                .source_path = disc.source_path,
                .line = pd.line,
                .column = pd.column,
            };
            diag.printText(d, gpa);
            if (diagnostics) |sink| sink.append(d);
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
/// A content root that scans to zero pages still publishes a valid target
/// (proof, search, and theme assets) and exits 0 (#775). That success is easy
/// to misread as a populated site — most visibly when a `--timings` report
/// shows every counter at zero — so say it loudly on stderr. Mirrors the
/// publication-evidence warnings that also print under `--quiet`.
fn warnZeroPages(content_root: []const u8) void {
    if (!diag.text_suppressed.load(.unordered)) {
        std.debug.print("warning: no pages found under '{s}'; published output contains proof/search assets only\n", .{content_root});
    }
}

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
        try loadAndPromoteFromProvider(io, gpa, &db, sources, options.input_format, options.timings, options.diagnostics);
    } else {
        try loadAndPromoteFormat(io, gpa, &db, options.content_root, options.input_format, options.timings, options.diagnostics);
    }
    if (db.len() == 0) warnZeroPages(options.content_root);

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

    try loadAndPromoteFormat(io, gpa, &db, base_options.content_root, base_options.input_format, base_options.timings, base_options.diagnostics);
    if (db.len() == 0) warnZeroPages(base_options.content_root);

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
                err == error.SitemapSiteUrlWithoutOutput or err == error.AmbiguousSitemapTargets or
                err == error.StaticDirMissing or err == error.StaticDirNotDirectory or
                err == error.StaticSymlink or err == error.StaticPathUnsafe or
                err == error.StaticPathCollision)
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

pub const HEADING_HARVEST_FORMAT = compile_heading.HEADING_HARVEST_FORMAT;
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

pub fn publishPathsEqual(left: []const u8, right: []const u8) bool {
    // Delegated to compile_stage's internal helper; kept for any direct callers.
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (left_byte == right_byte) continue;
        if ((left_byte == '/' and right_byte == '\\') or (left_byte == '\\' and right_byte == '/')) continue;
        return false;
    }
    return true;
}

pub fn publishStageTree(
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
pub fn layoutCodeFor(err: anyerror) diag.Code {
    return switch (err) {
        error.AssetBackslashName => .EASSET,
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
    var theme_bundle = try theme_mod.loadThemeBundle(io, gpa, cwd, theme_root, options.diagnostics);
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

/// Located EASSET diagnostic for a published-path collision (#868): names the
/// shared output path and the page/entity (or theme asset) it collides with.
/// `fail` carries the colliding path recorded by checkCollisions.
fn reportPublishedPathCollision(
    gpa: std.mem.Allocator,
    db: *const PageDb,
    content_assets: *const content_asset.SiteAssetInventory,
    theme_outs: []const []const u8,
    fail: *content_asset.FailInfo,
    sink: ?*diag.Collector,
) void {
    const path = fail.detail();
    if (path.len == 0) {
        content_asset.printDiagnostic(gpa, error.AssetCollision, "", fail.*, sink);
        return;
    }
    var asset_owner: []const u8 = "";
    for (content_assets.pages) |bundle| {
        for (bundle.entries) |e| {
            if (std.mem.eql(u8, e.output_rel, path)) {
                asset_owner = bundle.source_path;
                break;
            }
        }
        if (asset_owner.len > 0) break;
    }
    var buf: [2048]u8 = undefined;
    for (db.items()) |p| {
        if (std.mem.eql(u8, p.output_path, path)) {
            const detail = std.fmt.bufPrint(&buf, "\"{s}\" from \"{s}\" collides with page \"{s}\" ({s})", .{ path, asset_owner, p.entity_id, p.source_path }) catch path;
            fail.set(1, 1, detail, p.source_path);
            content_asset.printDiagnostic(gpa, error.AssetCollision, "", fail.*, sink);
            return;
        }
    }
    for (theme_outs) |t| {
        if (std.mem.eql(u8, t, path)) {
            const detail = std.fmt.bufPrint(&buf, "\"{s}\" from \"{s}\" collides with theme output", .{ path, asset_owner }) catch path;
            fail.set(1, 1, detail, asset_owner);
            content_asset.printDiagnostic(gpa, error.AssetCollision, "", fail.*, sink);
            return;
        }
    }
    const detail = std.fmt.bufPrint(&buf, "\"{s}\" from \"{s}\" collides with another content-local asset", .{ path, asset_owner }) catch path;
    fail.set(1, 1, detail, asset_owner);
    content_asset.printDiagnostic(gpa, error.AssetCollision, "", fail.*, sink);
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
        var collision_fail: content_asset.FailInfo = .{};
        content_asset.checkCollisions(content_outs, page_outs.items, theme_outs.items, &collision_fail) catch |err| {
            if (err == error.AssetCollision) {
                reportPublishedPathCollision(gpa, db, &content_assets, theme_outs.items, &collision_fail, options.diagnostics);
            }
            return err;
        };

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

/// Static passthrough discovery (#804): load the declared directory's file
/// inventory and fail loudly on missing dir, symlinks, unsafe paths, or any
/// collision with compiler-owned output paths. Runs before any page render so
/// validation (`validation_only`) covers the same prepublication boundary.
fn discoverStaticFiles(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    db: *const PageDb,
    options: CompileOptions,
    theme_bundle: *const theme_mod.ThemeBundle,
    content_assets: *const content_asset.SiteAssetInventory,
) static_files.Error![]static_files.Entry {
    const dir_rel = options.static_dir orelse return &.{};
    const entries = try static_files.loadInventory(io, gpa, cwd, dir_rel);
    errdefer static_files.freeInventory(gpa, entries);

    var page_outs: std.ArrayList([]const u8) = .empty;
    defer page_outs.deinit(gpa);
    try page_outs.ensureTotalCapacity(gpa, db.len());
    for (db.items()) |p| try page_outs.append(gpa, p.output_path);

    var theme_outs: std.ArrayList([]const u8) = .empty;
    defer theme_outs.deinit(gpa);
    try theme_outs.ensureTotalCapacity(gpa, theme_bundle.assets.len);
    for (theme_bundle.assets) |a| try theme_outs.append(gpa, a.rel_path);

    const content_outs = try content_assets.collectOutputPaths(gpa);
    defer gpa.free(content_outs);

    try static_files.checkCollisions(
        entries,
        page_outs.items,
        theme_outs.items,
        content_outs,
        search_index.output_path,
        options.sitemap_path,
    );
    return entries;
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
        .vcs_revision = options.vcs_revision,
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
    static_entries: []const static_files.Entry,
) !void {
    var inventory_specs: std.ArrayList(artifact_inventory.Spec) = .empty;
    defer inventory_specs.deinit(gpa);
    try inventory_specs.ensureTotalCapacity(
        gpa,
        db.len() + theme_bundle.assets.len + content_assets.pages.len + static_entries.len + 2,
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
    for (static_entries) |entry| {
        try inventory_specs.append(gpa, .{
            .path = entry.rel_path,
            .kind = .static_file,
            .producer = "static-files",
            .required = true,
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
    static_entries: []const static_files.Entry,
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
        // Skip currently-declared static passthrough files (e.g. a root-level
        // `.html` embed): they are committed generations, not stale page
        // outputs. Stale (no-longer-declared) static files are already
        // removed by scrubStaleStaticFiles before this walker runs.
        var static_html_paths: std.StringHashMapUnmanaged(void) = .{};
        defer static_html_paths.deinit(gpa);
        for (static_entries) |entry| {
            if (std.mem.endsWith(u8, entry.rel_path, ".html")) {
                try static_html_paths.put(gpa, entry.rel_path, {});
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
            if (static_html_paths.contains(entry.path)) continue;
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
    const static_entries = try discoverStaticFiles(io, gpa, cwd, db, options, &theme_bundle, &content_assets);
    defer static_files.freeInventory(gpa, static_entries);
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
    if (static_entries.len > 0) {
        try static_files.copyToStage(io, cwd, stage_dir, options.static_dir.?, static_entries);
    }

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
    try writeInventoryOverlay(io, gpa, db, options, stage_dir, dist_dir, &theme_bundle, &content_assets, static_entries);

    // Prior static-file ownership is read from the committed inventory before
    // the swap so stale passthrough files can be scrubbed after a successful
    // commit (#804). An unreadable inventory declares no static ownership.
    const prior_static_paths = try static_files.readPriorStaticPaths(io, gpa, dist_dir, options.target_name);
    defer static_files.freePriorStaticPaths(gpa, prior_static_paths);

    try commitStagedTree(io, gpa, cwd, stage_dir, dist_dir, prior_sitemap.path, options.sitemap_path, options.dist_dir);

    static_files.scrubStaleStaticFiles(io, dist_dir, prior_static_paths, static_entries);

    // Standard.site verification evidence, derived from the exact committed
    // bytes and written post-commit like the other proof artifacts.
    if (options.standard_site_verification) |ctx| {
        try publishStandardSiteReport(io, gpa, db, dist_dir, page_layouts, ctx, &site_overlay.wke.?, site_overlay.prior_emitted);
    }

    try cleanupStaleOutputs(io, gpa, dist_dir, db, options, &theme_bundle, &content_assets, theme_root, cache_state.parsed_manifest, static_entries);

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

// Test region moved verbatim to compile_test_kit.zig and the
// compile_*_test.zig siblings (pure move; see PR for the move audit).
// This file remains the test root, so the siblings run under `test-compile`.
test {
    _ = @import("compile_test_kit.zig");
    _ = @import("compile_site_core_test.zig");
    _ = @import("compile_failures_parallel_test.zig");
    _ = @import("compile_wikilinks_includes_test.zig");
    _ = @import("compile_incremental_test.zig");
    _ = @import("compile_multi_target_test.zig");
    _ = @import("compile_search_sitemap_test.zig");
    _ = @import("compile_assets_themes_test.zig");
    _ = @import("compile_static_files_test.zig");
    _ = @import("compile_publication_evidence_test.zig");
    _ = @import("compile_standard_site_test.zig");
}
