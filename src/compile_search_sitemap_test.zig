//! Tests moved verbatim from compile.zig's test region (6 tests).
//! Wiring: trailing import block in compile.zig (the `test-compile` root).

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

// Byte-identity aliases: bodies below call these bare, exactly as they
// did when they lived inside compile.zig.
const compile = @import("compile.zig");
const PageDb = compile.PageDb;
const compileHtmlSite = compile.compileHtmlSite;
const compileHtmlSiteMulti = compile.compileHtmlSiteMulti;
const readFileAlloc = compile.readFileAlloc;

const kit = @import("compile_test_kit.zig");

const crumbSegment = kit.crumbSegment;
const navSegment = kit.navSegment;
const navSegmentForDepthTest = kit.navSegmentForDepthTest;
const writeTreeFile = kit.writeTreeFile;

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
