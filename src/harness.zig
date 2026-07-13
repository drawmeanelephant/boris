//! Historical harness sketch (not on the m10 build graph).
//!
//! **Superseded by** `src/hardening_test.zig` + module tests (`aside`, `pipeline`,
//! `rag`, `compile`, `fuzz`). This file is retained as a reference for older
//! API experiments and is **not** compiled by `zig build test`.
//!
//! Active integration coverage:
//! - `zig build test` (includes hardening + fuzz)
//! - `zig build test-harness` → hardening subset only
//!
//! See `test/README.md` and `docs/AUDIT-v0.1.md`.

const std = @import("std");
const Io = std.Io;
const pipeline = @import("pipeline.zig");
const graph_mod = @import("graph.zig");
const diag = @import("diag.zig");
const frontmatter = @import("frontmatter.zig");
const parser = @import("parser.zig");
const apex = @import("apex.zig");
const aside = @import("aside.zig");
const assemble = @import("assemble.zig");
const compile = @import("compile.zig");
const scanner = @import("scanner.zig");
const page_mod = @import("page.zig");
const rag = @import("rag.zig");

/// Disposable root for all harness-generated output (gitignored).
pub const output_root = "test-output";

// ---------------------------------------------------------------------------
// WorkDir — unique path under test-output/, cleaned on deinit
// ---------------------------------------------------------------------------

pub const WorkDir = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Relative path from process cwd, e.g. `test-output/harness-abc123`.
    rel: []u8,
    cleaned: bool = false,

    /// Create `test-output/<label>-<hex>/` and return an owning handle.
    pub fn create(gpa: std.mem.Allocator, io: Io, label: []const u8) !WorkDir {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, output_root);

        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const suffix = std.fmt.bytesToHex(&rnd, .lower);
        const rel = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}", .{ output_root, label, suffix });
        errdefer gpa.free(rel);

        try cwd.createDirPath(io, rel);
        return .{ .gpa = gpa, .io = io, .rel = rel };
    }

    pub fn path(self: *const WorkDir) []const u8 {
        return self.rel;
    }

    /// Join a relative child under this work dir (caller frees).
    pub fn join(self: *const WorkDir, child: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.rel, child });
    }

    pub fn createSubPath(self: *const WorkDir, child: []const u8) ![]u8 {
        const p = try self.join(child);
        errdefer self.gpa.free(p);
        try Io.Dir.cwd().createDirPath(self.io, p);
        return p;
    }

    pub fn writeFile(self: *const WorkDir, rel_path: []const u8, data: []const u8) !void {
        const full = try self.join(rel_path);
        defer self.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            try Io.Dir.cwd().createDirPath(self.io, parent);
        }
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = data });
    }

    pub fn readFile(self: *const WorkDir, rel_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
        const full = try self.join(rel_path);
        defer self.gpa.free(full);
        var file = try Io.Dir.cwd().openFile(self.io, full, .{});
        defer file.close(self.io);
        var reader = file.reader(self.io, &.{});
        return try reader.interface.allocRemaining(gpa, .unlimited);
    }

    /// Best-effort recursive delete; safe to call multiple times.
    pub fn cleanup(self: *WorkDir) void {
        if (self.cleaned) return;
        self.cleaned = true;
        Io.Dir.cwd().deleteTree(self.io, self.rel) catch {};
        self.gpa.free(self.rel);
        self.rel = &.{};
    }
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn hasCode(diags: []const diag.Diagnostic, code: diag.Code) bool {
    for (diags) |d| {
        if (d.code == code) return true;
    }
    return false;
}

fn expectCode(diags: []const diag.Diagnostic, code: diag.Code) !void {
    if (!hasCode(diags, code)) return error.TestExpectedDiagnostic;
}

/// Collect file paths under `root_rel` sorted by relative path (stable, no dir order).
fn collectRelFilesSorted(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    root_rel: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var root = try Io.Dir.cwd().openDir(io, root_rel, .{ .iterate = true });
    defer root.close(io);
    try walkCollect(io, gpa, retain, root, "", out);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

fn walkCollect(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_rel = if (prefix.len == 0)
            try retain.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .file => try out.append(gpa, child_rel),
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try walkCollect(io, gpa, retain, sub, child_rel, out);
            },
            else => {},
        }
    }
}

fn expectDirsByteIdentical(io: Io, gpa: std.mem.Allocator, a_rel: []const u8, b_rel: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var files_a: std.ArrayList([]const u8) = .empty;
    defer files_a.deinit(gpa);
    var files_b: std.ArrayList([]const u8) = .empty;
    defer files_b.deinit(gpa);

    try collectRelFilesSorted(io, gpa, retain, a_rel, &files_a);
    try collectRelFilesSorted(io, gpa, retain, b_rel, &files_b);
    try std.testing.expectEqual(files_a.items.len, files_b.items.len);

    var dir_a = try Io.Dir.cwd().openDir(io, a_rel, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, b_rel, .{});
    defer dir_b.close(io);

    for (files_a.items, files_b.items) |pa, pb| {
        try std.testing.expectEqualStrings(pa, pb);
        var fa = try dir_a.openFile(io, pa, .{});
        defer fa.close(io);
        var ra = fa.reader(io, &.{});
        const ba = try ra.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(ba);
        var fb = try dir_b.openFile(io, pb, .{});
        defer fb.close(io);
        var rb = fb.reader(io, &.{});
        const bb = try rb.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(bb);
        try std.testing.expectEqualStrings(ba, bb);
    }
}

fn writeValidMultiPageSite(work: *const WorkDir) !void {
    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Home
        \\status: published
        \\tags: [site]
        \\---
        \\
        \\# Home
        \\
        \\Welcome to the harness site.
        \\
    );
    try work.writeFile(
        "content/guides/intro.md",
        \\---
        \\title: Intro
        \\status: published
        \\tags: [guide]
        \\---
        \\
        \\# Intro
        \\
        \\Trunk page with **bold** text.
        \\
        \\<Aside kind="tip" id="intro-tip">
        \\Drink water while reading.
        \\</Aside>
        \\
        \\End of intro.
        \\
    );
    try work.writeFile(
        "content/guides/intro-tips.md",
        \\---
        \\title: Intro Tips
        \\parent: guides/intro
        \\status: draft
        \\tags: [guide, tips]
        \\---
        \\
        \\# Intro Tips
        \\
        \\Satellite of guides/intro.
        \\
    );
}

fn writeLayout(work: *const WorkDir, body: []const u8) !void {
    try work.writeFile("layouts/main.html", body);
}

// ---------------------------------------------------------------------------
// Valid multi-page Trunk/Satellite site (IR)
// ---------------------------------------------------------------------------

test "harness: valid multi-page trunk/satellite IR build" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "valid-site");
    defer work.cleanup();

    try writeValidMultiPageSite(&work);
    const content = try work.join("content");
    defer gpa.free(content);
    const out = try work.createSubPath("out-ir");
    defer gpa.free(out);

    var result = try pipeline.run(io, gpa, .{
        .content_root = content,
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expect(result.graph_frozen);
    try std.testing.expectEqual(@as(usize, 3), result.pages.items.len);

    // Freeze sorts by id — never assert by discovery order.
    try std.testing.expectEqualStrings("guides/intro", result.pages.items[0].id);
    try std.testing.expect(result.pages.items[0].role == .trunk);
    try std.testing.expectEqualStrings("guides/intro-tips", result.pages.items[1].id);
    try std.testing.expect(result.pages.items[1].role == .satellite);
    try std.testing.expectEqualStrings("guides/intro", result.pages.items[1].parent.?);
    try std.testing.expectEqualStrings("index", result.pages.items[2].id);
    try std.testing.expect(result.pages.items[2].role == .trunk);

    // Artifacts present.
    const manifest = try work.readFile("out-ir/manifest.json", gpa);
    defer gpa.free(manifest);
    const graph_json = try work.readFile("out-ir/graph.json", gpa);
    defer gpa.free(graph_json);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"schemaVersion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_json, "\"edges\"") != null);
}

// ---------------------------------------------------------------------------
// Invalid graph cases (dedicated fixtures + contract fixtures)
// ---------------------------------------------------------------------------

test "harness: invalid graph diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Case = struct {
        name: []const u8,
        /// When set, use contract fixture content root; else write from `pages`.
        fixture: ?[]const u8 = null,
        code: diag.Code,
    };
    const cases = [_]Case{
        .{ .name = "dup-id", .fixture = "docs/contracts/fixtures/duplicate-ids/content", .code = .E_DUP_ID },
        .{ .name = "missing-parent", .fixture = "docs/contracts/fixtures/missing-parent/content", .code = .E_PARENT_MISSING },
        .{ .name = "self-parent", .fixture = "docs/contracts/fixtures/self-parent/content", .code = .E_PARENT_SELF },
        .{ .name = "cycle", .fixture = "docs/contracts/fixtures/cycles/content", .code = .E_PARENT_CYCLE },
        .{ .name = "sat-of-sat", .fixture = "docs/contracts/fixtures/satellite-of-satellite/content", .code = .E_PARENT_NOT_TRUNK },
    };

    for (cases) |c| {
        var work = try WorkDir.create(gpa, io, c.name);
        defer work.cleanup();
        const out = try work.createSubPath("out");
        defer gpa.free(out);

        var result = try pipeline.run(io, gpa, .{
            .content_root = c.fixture.?,
            .out_dir = out,
            .quiet = true,
        });
        defer result.deinit();
        try std.testing.expect(!result.ok);
        try expectCode(result.diagnostics.items, c.code);
    }
}

// ---------------------------------------------------------------------------
// Frontmatter syntax + UTF-8 failures
// ---------------------------------------------------------------------------

test "harness: frontmatter syntax and UTF-8 failures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    // Unclosed fence.
    {
        diags.clearRetainingCapacity();
        _ = try frontmatter.parse("---\ntitle: X\n", "t.md", retain, gpa, &diags);
        try expectCode(diags.items, .E_FRONTMATTER);
    }
    // Unknown key.
    {
        diags.clearRetainingCapacity();
        _ = try frontmatter.parse("---\nfoo: bar\n---\n", "t.md", retain, gpa, &diags);
        try expectCode(diags.items, .E_FRONTMATTER);
    }
    // Bad tags.
    {
        diags.clearRetainingCapacity();
        _ = try frontmatter.parse("---\ntags: not-a-list\n---\n", "t.md", retain, gpa, &diags);
        try expectCode(diags.items, .E_FRONTMATTER_VALUE);
    }
    // UTF-8 BOM.
    {
        diags.clearRetainingCapacity();
        const bom = [_]u8{ 0xEF, 0xBB, 0xBF, '-', '-', '-', '\n', '-', '-', '-', '\n' };
        _ = try frontmatter.parse(&bom, "t.md", retain, gpa, &diags);
        try expectCode(diags.items, .E_ENCODING);
    }
    // Invalid UTF-8.
    {
        diags.clearRetainingCapacity();
        const bad = [_]u8{ '-', '-', '-', '\n', 0xFF, 0xFE, '\n', '-', '-', '-', '\n' };
        _ = try frontmatter.parse(&bad, "t.md", retain, gpa, &diags);
        try expectCode(diags.items, .E_ENCODING);
    }

    // Parser path mirrors encoding gates (HTML/RAG).
    try std.testing.expectError(error.Utf8Bom, parser.parsePageSource(&[_]u8{ 0xEF, 0xBB, 0xBF, 'a' }, retain));
    try std.testing.expectError(error.InvalidUtf8, parser.parsePageSource(&[_]u8{ 0x80 }, retain));
}

// ---------------------------------------------------------------------------
// Component tokenizer failures + valid rendering
// ---------------------------------------------------------------------------

test "harness: component tokenizer failures and valid rendering" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Valid Aside → segments + HTML.
    {
        const body =
            \\Hello **world**.
            \\
            \\<Aside kind="warning" id="w1">
            \\Careful.
            \\</Aside>
            \\
            \\Done.
        ;
        const parsed = try parser.parseBodySegmentsSimple(body, a);
        try std.testing.expect(!parsed.hasErrors());
        try std.testing.expectEqual(@as(usize, 1), parsed.asides.len);

        // Render via Apex + aside (same stream model as compile).
        var html: std.ArrayList(u8) = .empty;
        for (parsed.segments) |seg| {
            switch (seg) {
                .markdown => |md| {
                    if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                    const h = try apex.render(md, &arena);
                    try html.appendSlice(a, h.bytes);
                },
                .aside => |c| {
                    const h = try aside.renderHtml(c, &arena);
                    try html.appendSlice(a, h);
                },
            }
        }
        try std.testing.expect(std.mem.indexOf(u8, html.items, "<strong>world</strong>") != null);
        try std.testing.expect(std.mem.indexOf(u8, html.items, "admonition--warning") != null);
        try std.testing.expect(std.mem.indexOf(u8, html.items, "id=\"w1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, html.items, "Careful") != null);
        try std.testing.expect(std.mem.indexOf(u8, html.items, "<Aside") == null);
    }

    // Unregistered component.
    {
        const bad = try parser.parseBodySegmentsSimple("<Figure src=\"x\">y</Figure>\n", a);
        try std.testing.expect(bad.hasErrors());
        var saw = false;
        for (bad.diagnostics) |d| {
            if (d.kind == .unregistered_component) saw = true;
        }
        try std.testing.expect(saw);
    }

    // Unterminated Aside.
    {
        const bad = try parser.parseBodySegmentsSimple("<Aside kind=\"tip\">\nno close\n", a);
        try std.testing.expect(bad.hasErrors());
        var saw = false;
        for (bad.diagnostics) |d| {
            if (d.kind == .unterminated_component) saw = true;
        }
        try std.testing.expect(saw);
    }

    // Invalid kind.
    {
        const bad = try parser.parseBodySegmentsSimple(
            \\<Aside kind="banana">
            \\x
            \\</Aside>
            \\
        , a);
        try std.testing.expect(bad.hasErrors());
        var saw = false;
        for (bad.diagnostics) |d| {
            if (d.kind == .invalid_kind) saw = true;
        }
        try std.testing.expect(saw);
    }
}

// ---------------------------------------------------------------------------
// Empty page + large-but-bounded page
// ---------------------------------------------------------------------------

test "harness: empty page and large-but-bounded page" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Empty is valid.
    {
        const empty = try parser.parsePageSource("", a);
        try std.testing.expect(!empty.hasErrors());
        try std.testing.expectEqual(@as(usize, 0), empty.body_md.len);
        const html = try apex.render("", &arena);
        try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
    }

    // Large markdown within Apex test bound.
    {
        var md: std.ArrayList(u8) = .empty;
        defer md.deinit(gpa);
        const line = "## Section\n\nParagraph with **bold** and *em*.\n\n";
        while (md.items.len < apex.test_large_md_bytes / 2) {
            try md.appendSlice(gpa, line);
        }
        const html = try apex.render(md.items, &arena);
        try std.testing.expect(html.bytes.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h2>") != null);
    }
}

// ---------------------------------------------------------------------------
// Layout missing / duplicate marker
// ---------------------------------------------------------------------------

test "harness: layout missing and duplicate content marker" {
    try std.testing.expectError(
        error.MissingContentMarker,
        assemble.Layout.split("<html><body>no marker</body></html>"),
    );
    try std.testing.expectError(
        error.DuplicateContentMarker,
        assemble.Layout.split("<html>{{content}} and {{content}}</html>"),
    );

    const ok = try assemble.Layout.split("<html>{{content}}</html>");
    try std.testing.expectEqualStrings("<html>", ok.prefix);
    try std.testing.expectEqualStrings("</html>", ok.suffix);
}

// ---------------------------------------------------------------------------
// RAG-only vs normal IR build
// ---------------------------------------------------------------------------

test "harness: RAG-only and normal build behavior" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "rag-vs-ir");
    defer work.cleanup();

    try writeValidMultiPageSite(&work);
    // Minimal system seeds for RAG.
    try work.writeFile("docs/system/00-overview.md", "# Overview\n\nHarness seed.\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const system = try work.join("docs/system");
    defer gpa.free(system);
    const ir_out = try work.createSubPath("ir");
    defer gpa.free(ir_out);
    const rag_out = try work.createSubPath("rag-out");
    defer gpa.free(rag_out);

    // --- Normal IR path ---
    var ir = try pipeline.run(io, gpa, .{
        .content_root = content,
        .out_dir = ir_out,
        .quiet = true,
    });
    defer ir.deinit();
    try std.testing.expect(ir.ok);
    // IR writes JSON; does not create RAG catalog.
    const manifest = try work.readFile("ir/manifest.json", gpa);
    defer gpa.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "pageCount") != null);

    // --- RAG-only path ---
    var db = page_mod.PageDb.init(gpa);
    defer db.deinit();
    try scanner.scanFromCwd(io, &db, content);
    const stats = try rag.exportAll(io, gpa, &db, .{
        .out_dir = rag_out,
        .content_dir = content,
        .system_docs_dir = system,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 3), stats.content_pages);
    try std.testing.expectEqual(@as(usize, 1), stats.system_docs);

    const catalog_meta = try work.readFile("rag-out/catalog_meta.json", gpa);
    defer gpa.free(catalog_meta);
    try std.testing.expect(std.mem.indexOf(u8, catalog_meta, "boris-rag") != null);

    // RAG-only must not have written IR artifacts into rag_out.
    // (catalog_meta is RAG; manifest is IR-only.)
    {
        var dir = try Io.Dir.cwd().openDir(io, rag_out, .{ .iterate = true });
        defer dir.close(io);
        var saw_manifest = false;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, "manifest.json")) saw_manifest = true;
        }
        try std.testing.expect(!saw_manifest);
    }
}

// ---------------------------------------------------------------------------
// Reproducible HTML, graph, RAG across two runs
// ---------------------------------------------------------------------------

test "harness: reproducible graph and RAG across two runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "repro");
    defer work.cleanup();

    try writeValidMultiPageSite(&work);
    try work.writeFile("docs/system/00-overview.md", "# Overview\n\nSeed.\n");
    try writeLayout(&work, "<!doctype html><html><body>{{content}}</body></html>\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const system = try work.join("docs/system");
    defer gpa.free(system);

    // Graph JSON identical across two IR runs.
    const ir_a = try work.createSubPath("ir-a");
    defer gpa.free(ir_a);
    const ir_b = try work.createSubPath("ir-b");
    defer gpa.free(ir_b);

    var r1 = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = ir_a, .quiet = true });
    defer r1.deinit();
    var r2 = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = ir_b, .quiet = true });
    defer r2.deinit();
    try std.testing.expect(r1.ok and r2.ok);

    const g1 = try work.readFile("ir-a/graph.json", gpa);
    defer gpa.free(g1);
    const g2 = try work.readFile("ir-b/graph.json", gpa);
    defer gpa.free(g2);
    try std.testing.expectEqualStrings(g1, g2);

    const m1 = try work.readFile("ir-a/manifest.json", gpa);
    defer gpa.free(m1);
    const m2 = try work.readFile("ir-b/manifest.json", gpa);
    defer gpa.free(m2);
    try std.testing.expectEqualStrings(m1, m2);

    // RAG corpus byte-identical across two export roots.
    const rag_a = try work.createSubPath("rag-a");
    defer gpa.free(rag_a);
    const rag_b = try work.createSubPath("rag-b");
    defer gpa.free(rag_b);

    var db = page_mod.PageDb.init(gpa);
    defer db.deinit();
    try scanner.scanFromCwd(io, &db, content);
    _ = try rag.exportAll(io, gpa, &db, .{
        .out_dir = rag_a,
        .content_dir = content,
        .system_docs_dir = system,
        .quiet = true,
    });
    _ = try rag.exportAll(io, gpa, &db, .{
        .out_dir = rag_b,
        .content_dir = content,
        .system_docs_dir = system,
        .quiet = true,
    });
    try expectDirsByteIdentical(io, gpa, rag_a, rag_b);

    // HTML path: two full site compiles produce identical dist trees.
    const dist_a = try work.createSubPath("dist-a");
    defer gpa.free(dist_a);
    const dist_b = try work.createSubPath("dist-b");
    defer gpa.free(dist_b);
    const layout_path = try work.join("layouts/main.html");
    defer gpa.free(layout_path);

    _ = try compile.compileSiteFromCwd(io, gpa, .{
        .content_dir_name = content,
        .dist_dir_name = dist_a,
        .layout_path = layout_path,
        .verbose_memory = false,
        .quiet = true,
    });
    _ = try compile.compileSiteFromCwd(io, gpa, .{
        .content_dir_name = content,
        .dist_dir_name = dist_b,
        .layout_path = layout_path,
        .verbose_memory = false,
        .quiet = true,
    });
    try expectDirsByteIdentical(io, gpa, dist_a, dist_b);
}

// ---------------------------------------------------------------------------
// Page-by-page Whiteboard reset: no cross-page buffer reuse
// ---------------------------------------------------------------------------

test "harness: whiteboard reset isolates pages (no metadata/body reuse)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "whiteboard");
    defer work.cleanup();

    // Three pages with unique, non-overlapping markers.
    const pages = [_]struct { rel: []const u8, title: []const u8, marker: []const u8 }{
        .{ .rel = "content/alpha.md", .title = "TITLE_ALPHA_UNIQUE_7f3a", .marker = "BODY_MARKER_ALPHA_9c2e" },
        .{ .rel = "content/beta.md", .title = "TITLE_BETA_UNIQUE_4b81", .marker = "BODY_MARKER_BETA_1d0f" },
        .{ .rel = "content/gamma.md", .title = "TITLE_GAMMA_UNIQUE_e55c", .marker = "BODY_MARKER_GAMMA_88aa" },
    };

    for (pages) |p| {
        const src = try std.fmt.allocPrint(gpa,
            \\---
            \\title: {s}
            \\---
            \\
            \\# {s}
            \\
            \\{s}
            \\
        , .{ p.title, p.title, p.marker });
        defer gpa.free(src);
        try work.writeFile(p.rel, src);
    }
    try writeLayout(&work, "<html><body>{{content}}</body></html>");

    const content = try work.join("content");
    defer gpa.free(content);
    const dist = try work.createSubPath("dist");
    defer gpa.free(dist);
    const layout_path = try work.join("layouts/main.html");
    defer gpa.free(layout_path);

    // Long-lived PageDb (must outlive free_all).
    var db = page_mod.PageDb.init(gpa);
    defer db.deinit();
    try scanner.scanFromCwd(io, &db, content);

    // Sort pages by entity_id so the loop order is deterministic (not dir order).
    std.mem.sort(page_mod.Page, db.pages.items, {}, struct {
        fn less(_: void, a: page_mod.Page, b: page_mod.Page) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);

    var layout_arena = std.heap.ArenaAllocator.init(gpa);
    defer layout_arena.deinit();
    const layout = try assemble.loadLayout(io, Io.Dir.cwd(), layout_path, layout_arena.allocator());

    var content_dir = try Io.Dir.cwd().openDir(io, content, .{});
    defer content_dir.close(io);
    var dist_dir = try Io.Dir.cwd().openDir(io, dist, .{});
    defer dist_dir.close(io);

    {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(gpa);
        for (db.pages.items) |pg| try paths.append(gpa, pg.output_path);
        try assemble.precreateOutputDirs(io, dist_dir, gpa, paths.items);
    }

    // Shared whiteboard arena — reset after every page (production model).
    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    defer doc_arena.deinit();

    // Capture promoted titles (PageDb-owned) after each promote.
    var promoted_titles: [3]?[]const u8 = .{ null, null, null };

    for (db.pages.items, 0..) |*p, pi| {
        defer {
            _ = doc_arena.reset(.free_all);
        }
        const arena = doc_arena.allocator();

        var file = try content_dir.openFile(io, p.source_path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const source = try reader.interface.allocRemaining(arena, .unlimited);

        const parsed = try parser.parsePageSource(source, arena);
        try std.testing.expect(!parsed.hasErrors());

        // Promote: dupe into PageDb (never store arena slices).
        const title_dupe: ?[]const u8 = if (parsed.frontmatter.title) |t|
            try db.allocator().dupe(u8, t)
        else
            null;
        p.frontmatter = .{
            .title = title_dupe,
            .parent_entry = if (parsed.frontmatter.parent_entry) |pe|
                try db.allocator().dupe(u8, pe)
            else
                null,
        };
        promoted_titles[pi] = title_dupe;

        // Render body stream into arena HTML.
        var html: std.ArrayList(u8) = .empty;
        for (parsed.segments) |seg| {
            switch (seg) {
                .markdown => |md| {
                    if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                    const h = try apex.render(md, &doc_arena);
                    try html.appendSlice(arena, h.bytes);
                },
                .aside => |c| {
                    const h = try aside.renderHtml(c, &doc_arena);
                    try html.appendSlice(arena, h);
                },
            }
        }
        const page_html = try html.toOwnedSlice(arena);

        // Flush-before-reset: write fully completes before defer free_all.
        try assemble.writePage(io, dist_dir, p.output_path, layout, page_html);
    }

    // After all free_all cycles: PageDb titles still match the originals.
    try std.testing.expectEqualStrings("TITLE_ALPHA_UNIQUE_7f3a", promoted_titles[0].?);
    try std.testing.expectEqualStrings("TITLE_BETA_UNIQUE_4b81", promoted_titles[1].?);
    try std.testing.expectEqualStrings("TITLE_GAMMA_UNIQUE_e55c", promoted_titles[2].?);

    // Also check via PageDb (survives free_all).
    try std.testing.expectEqualStrings("TITLE_ALPHA_UNIQUE_7f3a", db.pages.items[0].frontmatter.title.?);
    try std.testing.expectEqualStrings("TITLE_BETA_UNIQUE_4b81", db.pages.items[1].frontmatter.title.?);
    try std.testing.expectEqualStrings("TITLE_GAMMA_UNIQUE_e55c", db.pages.items[2].frontmatter.title.?);

    // Published HTML: each file has only its own marker, not siblings'.
    const expected = [_]struct { out: []const u8, own: []const u8, foreign: [2][]const u8 }{
        .{ .out = "alpha.html", .own = "BODY_MARKER_ALPHA_9c2e", .foreign = .{ "BODY_MARKER_BETA_1d0f", "BODY_MARKER_GAMMA_88aa" } },
        .{ .out = "beta.html", .own = "BODY_MARKER_BETA_1d0f", .foreign = .{ "BODY_MARKER_ALPHA_9c2e", "BODY_MARKER_GAMMA_88aa" } },
        .{ .out = "gamma.html", .own = "BODY_MARKER_GAMMA_88aa", .foreign = .{ "BODY_MARKER_ALPHA_9c2e", "BODY_MARKER_BETA_1d0f" } },
    };
    for (expected) |e| {
        var f = try dist_dir.openFile(io, e.out, .{});
        defer f.close(io);
        var r = f.reader(io, &.{});
        const bytes = try r.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, e.own) != null);
        for (e.foreign) |bad| {
            try std.testing.expect(std.mem.indexOf(u8, bytes, bad) == null);
        }
        // Title isolation in HTML.
        try std.testing.expect(std.mem.indexOf(u8, bytes, e.own[0..11]) != null);
    }

    // Arena fully reclaimed after last reset.
    try std.testing.expectEqual(@as(usize, 0), doc_arena.queryCapacity());
}

// ---------------------------------------------------------------------------
// Fixture tree under test/fixtures (static suite)
// ---------------------------------------------------------------------------

test "harness: static fixture suite under test/fixtures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "static-fx");
    defer work.cleanup();
    const out = try work.createSubPath("out");
    defer gpa.free(out);

    // Valid site from committed fixtures.
    {
        var result = try pipeline.run(io, gpa, .{
            .content_root = "test/fixtures/valid-site/content",
            .out_dir = out,
            .quiet = true,
        });
        defer result.deinit();
        try std.testing.expect(result.ok);
        try std.testing.expectEqual(@as(usize, 3), result.pages.items.len);
    }

    // Empty page fixture.
    {
        const out2 = try work.createSubPath("out-empty");
        defer gpa.free(out2);
        var result = try pipeline.run(io, gpa, .{
            .content_root = "test/fixtures/empty-page/content",
            .out_dir = out2,
            .quiet = true,
        });
        defer result.deinit();
        try std.testing.expect(result.ok);
        try std.testing.expectEqual(@as(usize, 1), result.pages.items.len);
    }
}

// ---------------------------------------------------------------------------
// Path discovery: sort independence (create files in reverse id order)
// ---------------------------------------------------------------------------

test "harness: discovery sort independent of creation order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "discover-order");
    defer work.cleanup();

    // Create in reverse alphabetical entity-id order.
    try work.writeFile("content/z-last.md", "---\ntitle: Z\n---\n\nZ\n");
    try work.writeFile("content/m-mid.md", "---\ntitle: M\n---\n\nM\n");
    try work.writeFile("content/a-first.md", "---\ntitle: A\n---\n\nA\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const out = try work.createSubPath("out");
    defer gpa.free(out);

    var result = try pipeline.run(io, gpa, .{
        .content_root = content,
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);
    // Frozen id order is alphabetical, not creation order.
    try std.testing.expectEqualStrings("a-first", result.pages.items[0].id);
    try std.testing.expectEqualStrings("m-mid", result.pages.items[1].id);
    try std.testing.expectEqualStrings("z-last", result.pages.items[2].id);
}

// ---------------------------------------------------------------------------
// Layout load via compile path fails fast
// ---------------------------------------------------------------------------

test "harness: compile aborts on bad layout before content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "bad-layout");
    defer work.cleanup();

    try work.writeFile("content/index.md", "---\ntitle: X\n---\n\nHi\n");
    try writeLayout(&work, "<html>missing marker</html>");

    const content = try work.join("content");
    defer gpa.free(content);
    const dist = try work.createSubPath("dist");
    defer gpa.free(dist);
    const layout_path = try work.join("layouts/main.html");
    defer gpa.free(layout_path);

    try std.testing.expectError(error.MissingContentMarker, compile.compileSiteFromCwd(io, gpa, .{
        .content_dir_name = content,
        .dist_dir_name = dist,
        .layout_path = layout_path,
        .verbose_memory = false,
        .quiet = true,
    }));
}

test "harness: static layout fixtures missing and duplicate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var missing = try cwd.openFile(io, "test/fixtures/layouts/missing-marker.html", .{});
    defer missing.close(io);
    var mr = missing.reader(io, &.{});
    const missing_raw = try mr.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(missing_raw);
    try std.testing.expectError(error.MissingContentMarker, assemble.Layout.split(missing_raw));

    var dup = try cwd.openFile(io, "test/fixtures/layouts/duplicate-marker.html", .{});
    defer dup.close(io);
    var dr = dup.reader(io, &.{});
    const dup_raw = try dr.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(dup_raw);
    try std.testing.expectError(error.DuplicateContentMarker, assemble.Layout.split(dup_raw));

    var ok = try cwd.openFile(io, "test/fixtures/layouts/ok.html", .{});
    defer ok.close(io);
    var or_ = ok.reader(io, &.{});
    const ok_raw = try or_.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(ok_raw);
    const layout = try assemble.Layout.split(ok_raw);
    try std.testing.expect(layout.prefix.len > 0);
    try std.testing.expect(layout.suffix.len > 0);
}

test "harness: utf8-bom fixture rejected on compiler frontmatter path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "bom-fx");
    defer work.cleanup();
    const out = try work.createSubPath("out");
    defer gpa.free(out);

    var result = try pipeline.run(io, gpa, .{
        .content_root = "test/fixtures/utf8-bom/content",
        .out_dir = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(!result.ok);
    try expectCode(result.diagnostics.items, .E_ENCODING);
}

test "harness: component-fail fixture parse has unregistered diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, "test/fixtures/component-fail/content/bad-component.md", .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const source = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(source);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = try parser.parsePageSource(source, arena.allocator());
    try std.testing.expect(parsed.hasErrors());
    var saw = false;
    for (parsed.diagnostics) |d| {
        if (d.kind == .unregistered_component) saw = true;
    }
    try std.testing.expect(saw);
}
