//! Whiteboard Strategy — document-local ArenaAllocator compile loop.
//!
//! Startup order (site entry `compileSiteFromCwd`):
//!   1. **Load layout** — missing/duplicate `{{content}}` aborts before scan
//!   2. Scan `content/` into PageDb
//!   3. Pre-create `dist/` parent directories (batch)
//!   4. Per-page whiteboard compile + atomic write
//!
//! For each page:
//!   1. arena ready
//!   2. read → UTF-8 check → parse → Apex
//!   3. promote title/parent_entry into PageDb (dupe before free_all)
//!   4. re-splice Aside HTML callouts into the body stream in order
//!   5. zero-copy layout write to dist/ (**flush completes before return**)
//!   6. arena.reset(.free_all) — only after writePage returns
//!
//! ## Cross-cutting invariant: flush-before-reset
//!
//! `assemble.writePage` fully flushes and publishes (`Atomic.replace`) before
//! returning. The per-page `defer arena.reset(.free_all)` therefore cannot run
//! while `html_body` bytes are still needed for I/O.
//!
//! `layout.prefix` / `layout.suffix` are `[]const u8` views into a `Layout`
//! whose arena outlives the entire compile loop (loaded once before scan).

const std = @import("std");
const Io = std.Io;
const page_mod = @import("page.zig");
const parser = @import("parser.zig");
const apex = @import("apex.zig");
const aside = @import("aside.zig");
const assemble = @import("assemble.zig");
const scanner = @import("scanner.zig");
const PageDb = page_mod.PageDb;

pub const CompileStats = struct {
    pages_written: usize = 0,
    asides_found: usize = 0,
    peak_arena_bytes: usize = 0,
    last_reset_capacity: usize = 0,
};

pub const CompileOptions = struct {
    content_dir_name: []const u8 = "content",
    dist_dir_name: []const u8 = "dist",
    layout_path: []const u8 = "layouts/main.html",
    verbose_memory: bool = true,
    /// When true, suppress per-page progress prints (harness / quiet CI).
    quiet: bool = false,
};

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// True when a markdown segment is only whitespace (no prose for Apex).
fn isBlankMarkdown(md: []const u8) bool {
    return std.mem.trim(u8, md, " \t\r\n").len == 0;
}

/// Walk the ordered segment stream and emit one continuous HTML body.
///
/// Control flow (document order, no reordering):
///   for each segment in parser order:
///     .markdown → pure prose span → apex.render(slice, doc_arena)
///     .aside    → registered component → aside.renderHtml(...)
///   each fragment is appended to the Whiteboard-backed buffer in sequence
///
/// Pure markdown never runs through the component path; Aside tags never
/// reach Apex on the main prose path (the parser already tokenized them out).
/// Apex HTML is allocated on the document arena via zigAlloc; we then splice
/// those bytes into the page stream so layout write sees prefix | body | suffix.
fn renderSegments(segments: []const parser.Segment, doc_arena: *std.heap.ArenaAllocator) ![]const u8 {
    const arena = doc_arena.allocator();
    var html: std.ArrayList(u8) = .empty;

    for (segments) |seg| {
        switch (seg) {
            // --- Pure markdown segment ---------------------------------
            // Detected by Segment tag `.markdown`. Payload is a zero-copy
            // slice of the page source between component boundaries.
            .markdown => |md_slice| {
                if (isBlankMarkdown(md_slice)) continue;

                // Hand the caller's slice to Apex (md.ptr + md.len, no dupe).
                // Rendered HTML lands on the document arena (Whiteboard).
                const apex_html = try apex.render(md_slice, doc_arena);

                // Keep stream order: previous segments first, then this HTML.
                try html.appendSlice(arena, apex_html.bytes);
            },

            // --- Registered component (Aside admonition, …) ------------
            // Stays between surrounding markdown segments; never a separate
            // page or graph node. Inner body may call Apex itself.
            .aside => |component| {
                const component_html = try aside.renderHtml(component, doc_arena);
                try html.appendSlice(arena, component_html);
            },
        }
    }

    return try html.toOwnedSlice(arena);
}

/// Copy relational frontmatter into the long-lived PageDb arena.
///
/// Parse-time `title` / `parent_entry` are slices into document-arena source.
/// Storing those pointers on `Page` without duping would dangle after free_all.
///
/// Length bounds are enforced at parse time; this is a last-line guard so an
/// oversized string never enters the PageDb arena even if a caller bypasses
/// the parser checks.
fn promoteFrontmatter(db: *PageDb, parsed: page_mod.Frontmatter) !page_mod.Frontmatter {
    if (parsed.title) |t| {
        if (t.len > page_mod.max_title_bytes) return error.FrontmatterValueTooLong;
    }
    if (parsed.parent_entry) |pe| {
        if (pe.len > page_mod.max_entity_id_bytes) return error.FrontmatterValueTooLong;
    }
    return .{
        .title = if (parsed.title) |t| try db.allocator().dupe(u8, t) else null,
        .parent_entry = if (parsed.parent_entry) |pe| try db.allocator().dupe(u8, pe) else null,
        // extras are parse-time only; do not promote raw source slices.
        .extras = &.{},
    };
}

/// Site compile entry: layout load **before** content scan (fast fail on bad template).
pub fn compileSiteFromCwd(
    io: Io,
    gpa: std.mem.Allocator,
    options: CompileOptions,
) !CompileStats {
    const cwd = Io.Dir.cwd();

    // 1. Layout first — missing/duplicate {{content}} aborts with no content walk.
    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try assemble.loadLayout(io, cwd, options.layout_path, layout_arena.allocator());

    // 2. Scan content into long-lived PageDb.
    var db = PageDb.init(gpa);
    defer db.deinit();
    try scanner.scanFromCwd(io, &db, options.content_dir_name);

    // 3–4. Precreate dist dirs + whiteboard compile loop.
    return try compileAll(io, gpa, &db, layout, options);
}

pub fn compileAll(
    io: Io,
    gpa: std.mem.Allocator,
    db: *PageDb,
    layout: assemble.Layout,
    options: CompileOptions,
) !CompileStats {
    const cwd = Io.Dir.cwd();

    var content_dir = try cwd.openDir(io, options.content_dir_name, .{});
    defer content_dir.close(io);

    try cwd.createDirPath(io, options.dist_dir_name);
    var dist_dir = try cwd.openDir(io, options.dist_dir_name, .{});
    defer dist_dir.close(io);

    // Batch directory creation once paths are known (not per-page in the hot loop).
    {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(gpa);
        try paths.ensureTotalCapacity(gpa, db.pages.items.len);
        for (db.pages.items) |p| try paths.append(gpa, p.output_path);
        try assemble.precreateOutputDirs(io, dist_dir, gpa, paths.items);
    }

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    var stats: CompileStats = .{};

    for (db.pages.items) |*p| {
        // Always wipe document scratch at end of this iteration — success or
        // error — so the next page never aliases partially filled arena blocks.
        // writePage flushes + renames before it returns; reset runs only after that.
        defer {
            _ = doc_arena.reset(.free_all);
            stats.last_reset_capacity = doc_arena.queryCapacity();
            if (options.verbose_memory and !options.quiet) {
                std.debug.print(
                    "  [whiteboard] after reset capacity = {d} bytes\n",
                    .{stats.last_reset_capacity},
                );
            }
        }

        const arena = doc_arena.allocator();

        const source = try readFileAlloc(io, content_dir, p.source_path, arena);
        // UTF-8 / empty / unclosed FM / components handled inside parsePageSource.
        const parsed = try parser.parsePageSource(source, arena);

        // Hard component errors: path/line/col + name (no silent HTML leak).
        if (parsed.hasErrors()) {
            for (parsed.diagnostics) |d| {
                var line_buf: std.ArrayList(u8) = .empty;
                defer line_buf.deinit(arena);
                try parser.formatDiag(d, p.source_path, &line_buf, arena);
                std.debug.print("{s}\n", .{line_buf.items});
            }
            return error.ComponentParseFailed;
        }

        // Promote before free_all (defer): dupe into PageDb, never store arena slices.
        p.frontmatter = try promoteFrontmatter(db, parsed.frontmatter);

        // Ordered segment stream → Apex (markdown) + components, all on arena.
        const page_html = try renderSegments(parsed.segments, &doc_arena);
        stats.asides_found += parsed.asides.len;

        if (options.verbose_memory and !options.quiet) {
            const cap = doc_arena.queryCapacity();
            if (cap > stats.peak_arena_bytes) stats.peak_arena_bytes = cap;
            std.debug.print(
                "  [whiteboard] {s}: arena={d}B asides={d} segments={d}\n",
                .{ p.entity_id, cap, parsed.asides.len, parsed.segments.len },
            );
        } else if (options.verbose_memory) {
            const cap = doc_arena.queryCapacity();
            if (cap > stats.peak_arena_bytes) stats.peak_arena_bytes = cap;
        }

        // INVARIANT flush-before-reset: writePage returns only after flush+rename.
        // The loop `defer` free_all runs after this statement completes.
        try assemble.writePage(io, dist_dir, p.output_path, layout, page_html);
        stats.pages_written += 1;

        if (!options.quiet) {
            std.debug.print("  wrote dist/{s}  ({s}", .{ p.output_path, p.role() });
            if (p.frontmatter.parent_entry) |pe| {
                std.debug.print(" of {s}", .{pe});
            }
            std.debug.print(")\n", .{});
        }
    }

    return stats;
}

pub fn proveFlatFootprint(gpa: std.mem.Allocator, iterations: usize) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var after_reset_caps: [3]usize = .{ 0, 0, 0 };
    const sample = @min(iterations, after_reset_caps.len);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const a = arena.allocator();
        const buf = try a.alloc(u8, 4096 + i * 128);
        @memset(buf, @truncate(i));
        _ = try apex.render("# doc\n\nbody text\n", &arena);
        _ = arena.reset(.free_all);
        if (i < sample) after_reset_caps[i] = arena.queryCapacity();
    }

    for (after_reset_caps[0..sample]) |cap| {
        if (cap != 0) return error.ArenaDidNotFreeAll;
    }
}

test "whiteboard free_all keeps flat capacity" {
    try proveFlatFootprint(std.testing.allocator, 8);
}

test "renderSegments inserts aside admonition" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\Hello **world**.
        \\
        \\<Aside kind="tip" id="t1">
        \\Drink water.
        \\</Aside>
        \\
        \\Bye.
    ;
    const parsed = try parser.parseBodySegmentsSimple(body, a);
    try std.testing.expect(!parsed.hasErrors());
    const html = try renderSegments(parsed.segments, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>world</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"admonition admonition--tip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Drink water") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<Aside") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "</Aside>") == null);
}

test "renderSegments pure markdown goes through Apex in order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Explicit stream: md | aside | md — Apex only on pure markdown arms.
    const segments = [_]parser.Segment{
        .{ .markdown = "# Open\n\nAlpha **one**.\n" },
        .{ .aside = .{
            .kind = "note",
            .id = "n1",
            .body = "Middle callout.",
            .raw_span = "",
        } },
        .{ .markdown = "Omega *two*.\n" },
    };

    const html = try renderSegments(&segments, &arena);

    const i_alpha = std.mem.indexOf(u8, html, "<strong>one</strong>");
    const i_aside = std.mem.indexOf(u8, html, "class=\"admonition admonition--note\"");
    const i_omega = std.mem.indexOf(u8, html, "<em>two</em>");
    try std.testing.expect(i_alpha != null);
    try std.testing.expect(i_aside != null);
    try std.testing.expect(i_omega != null);

    // Document order: leading markdown HTML, then component, then trailing markdown.
    try std.testing.expect(i_alpha.? < i_aside.?);
    try std.testing.expect(i_aside.? < i_omega.?);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>") != null);
}

test "promoteFrontmatter dupes into PageDb not document arena" {
    const gpa = std.testing.allocator;
    var db = PageDb.init(gpa);
    defer db.deinit();

    var doc = std.heap.ArenaAllocator.init(gpa);
    defer doc.deinit();
    const scratch = doc.allocator();

    const title = try scratch.dupe(u8, "Scratch Title");
    const parent = try scratch.dupe(u8, "guides/intro");
    const promoted = try promoteFrontmatter(&db, .{
        .title = title,
        .parent_entry = parent,
    });

    // Wipe document arena — promoted strings must still be valid.
    _ = doc.reset(.free_all);
    try std.testing.expectEqualStrings("Scratch Title", promoted.title.?);
    try std.testing.expectEqualStrings("guides/intro", promoted.parent_entry.?);
}

// Explicit flush-before-reset invariant: after writePage returns, free_all may
// wipe the arena-owned body while the published file remains complete.
test "flush-before-reset: free_all after writePage leaves complete file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-flush-test";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    var out = try cwd.openDir(io, work, .{ .iterate = true });
    defer out.close(io);

    const layout = try assemble.Layout.split("<html>{{content}}</html>");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try a.dupe(u8, "<p>arena body</p>");

    try assemble.writePage(io, out, "page.html", layout, body);

    // Wipe whiteboard — body slice is now invalid; file must already be durable.
    _ = arena.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());

    var file = try out.openFile(io, "page.html", .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const got = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<html><p>arena body</p></html>", got);

    // createFileAtomic temps use unique hex names; none should remain after publish.
    {
        var it = out.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // Successful publish leaves only the final file.
            try std.testing.expectEqualStrings("page.html", entry.name);
        }
    }
}
