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

    {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(gpa);
        try paths.ensureTotalCapacity(gpa, db.len());
        for (db.items()) |p| try paths.append(gpa, p.output_path);
        try assemble.precreateOutputDirs(io, dist_dir, gpa, paths.items);
    }

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    var stats: CompileStats = .{};

    for (db.items(), 0..) |*page, page_index| {
        // Always wipe Whiteboard after this iteration — success or error.
        // Reset runs only after renderAndPublishPage returns (flush+publish
        // finished, no live Whiteboard slice needed by caller).
        defer {
            _ = doc_arena.reset(.free_all);
            stats.last_reset_capacity = doc_arena.queryCapacity();
        }

        stats.pages_attempted += 1;

        renderAndPublishPage(io, content_dir, dist_dir, page, layout, &doc_arena, options, page_index) catch |err| {
            // defer still resets the Whiteboard.
            return err;
        };

        const cap = doc_arena.queryCapacity();
        if (cap > stats.peak_whiteboard_capacity) stats.peak_whiteboard_capacity = cap;

        stats.pages_written += 1;
        if (!options.quiet) {
            std.debug.print("  wrote {s}/{s}\n", .{ options.dist_dir, page.output_path });
        }
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
