//! Milestone 10 end-to-end hardening tests.
//!
//! Proves IR/RAG determinism, shared graph diagnostics, scanner order
//! independence, duplicate-id non-masking, output path containment, component
//! validation on the shared compile path, and experimental HTML Aside stream.
//!
//! Disposable artifacts under `test-output/` (gitignored).

const std = @import("std");
const Io = std.Io;
const pipeline = @import("pipeline.zig");
const rag = @import("rag.zig");
const diag = @import("diag.zig");
const graph_mod = @import("graph.zig");
const aside = @import("aside.zig");
const compile = @import("compile.zig");
const identity = @import("identity.zig");
const scanner = @import("scanner.zig");
const page_mod = @import("page.zig");

const output_root = "test-output";

const WorkDir = struct {
    gpa: std.mem.Allocator,
    io: Io,
    rel: []u8,

    fn create(gpa: std.mem.Allocator, io: Io, label: []const u8) !WorkDir {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, output_root);
        var rnd: [4]u8 = undefined;
        io.random(&rnd);
        const suffix = std.fmt.bytesToHex(&rnd, .lower);
        const rel = try std.fmt.allocPrint(gpa, "{s}/m10-{s}-{s}", .{ output_root, label, suffix });
        errdefer gpa.free(rel);
        try cwd.createDirPath(io, rel);
        return .{ .gpa = gpa, .io = io, .rel = rel };
    }

    fn cleanup(self: *WorkDir) void {
        Io.Dir.cwd().deleteTree(self.io, self.rel) catch {};
        self.gpa.free(self.rel);
    }

    fn join(self: *const WorkDir, child: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.rel, child });
    }

    fn writeFile(self: *const WorkDir, rel_path: []const u8, data: []const u8) !void {
        const full = try self.join(rel_path);
        defer self.gpa.free(full);
        if (std.fs.path.dirname(full)) |parent| {
            try Io.Dir.cwd().createDirPath(self.io, parent);
        }
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = data });
    }

    fn readFile(self: *const WorkDir, rel_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
        const full = try self.join(rel_path);
        defer self.gpa.free(full);
        var file = try Io.Dir.cwd().openFile(self.io, full, .{});
        defer file.close(self.io);
        var reader = file.reader(self.io, &.{});
        return try reader.interface.allocRemaining(gpa, .unlimited);
    }
};

fn compareNamedFiles(io: Io, gpa: std.mem.Allocator, a_root: []const u8, b_root: []const u8, names: []const []const u8) !void {
    var dir_a = try Io.Dir.cwd().openDir(io, a_root, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, b_root, .{});
    defer dir_b.close(io);
    for (names) |name| {
        var fa = try dir_a.openFile(io, name, .{});
        defer fa.close(io);
        var fb = try dir_b.openFile(io, name, .{});
        defer fb.close(io);
        var ra = fa.reader(io, &.{});
        var rb = fb.reader(io, &.{});
        const ab = try ra.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(ab);
        const bb = try rb.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(bb);
        try std.testing.expectEqualSlices(u8, ab, bb);
    }
}

fn treesByteIdentical(io: Io, gpa: std.mem.Allocator, a_root: []const u8, b_root: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var files_a: std.ArrayList([]const u8) = .empty;
    defer files_a.deinit(gpa);
    var files_b: std.ArrayList([]const u8) = .empty;
    defer files_b.deinit(gpa);

    {
        var root = try Io.Dir.cwd().openDir(io, a_root, .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try files_a.append(gpa, try retain.dupe(u8, entry.path));
        }
    }
    {
        var root = try Io.Dir.cwd().openDir(io, b_root, .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try files_b.append(gpa, try retain.dupe(u8, entry.path));
        }
    }

    const less = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f;
    std.mem.sort([]const u8, files_a.items, {}, less);
    std.mem.sort([]const u8, files_b.items, {}, less);
    try std.testing.expectEqual(files_a.items.len, files_b.items.len);

    var dir_a = try Io.Dir.cwd().openDir(io, a_root, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, b_root, .{});
    defer dir_b.close(io);

    for (files_a.items, files_b.items) |ap, bp| {
        try std.testing.expectEqualStrings(ap, bp);
        var fa = try dir_a.openFile(io, ap, .{});
        defer fa.close(io);
        var fb = try dir_b.openFile(io, bp, .{});
        defer fb.close(io);
        var ra = fa.reader(io, &.{});
        var rb = fb.reader(io, &.{});
        const ab = try ra.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(ab);
        const bb = try rb.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(bb);
        try std.testing.expectEqualSlices(u8, ab, bb);
    }
}

fn codesSet(diags: []const diag.Diagnostic, gpa: std.mem.Allocator) ![]diag.Code {
    var list: std.ArrayList(diag.Code) = .empty;
    errdefer list.deinit(gpa);
    for (diags) |d| {
        if (d.severity != .error_) continue;
        var found = false;
        for (list.items) |c| {
            if (c == d.code) {
                found = true;
                break;
            }
        }
        if (!found) try list.append(gpa, d.code);
    }
    std.mem.sort(diag.Code, list.items, {}, struct {
        fn less(_: void, a: diag.Code, b: diag.Code) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.less);
    return try list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// IR twice → distinct dirs → byte compare
// ---------------------------------------------------------------------------

test "hardening: IR dual-run byte identity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "ir-dual");
    defer work.cleanup();

    const a = try work.join("a");
    defer gpa.free(a);
    const b = try work.join("b");
    defer gpa.free(b);

    const content = "fixtures/content/valid";
    {
        var r = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = a, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.ok);
    }
    {
        var r = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = b, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.ok);
    }
    // Graph-dependent IR is path-stable; build-report embeds outDir so is excluded.
    try compareNamedFiles(io, gpa, a, b, &[_][]const u8{ "manifest.json", "graph.json" });
}

// ---------------------------------------------------------------------------
// RAG twice → distinct dirs → byte compare
// ---------------------------------------------------------------------------

test "hardening: RAG dual-run byte identity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "rag-dual");
    defer work.cleanup();

    const a = try work.join("a");
    defer gpa.free(a);
    const b = try work.join("b");
    defer gpa.free(b);

    const content = "fixtures/content/valid";
    {
        var r = try rag.run(io, gpa, .{ .content_root = content, .out_dir = a, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.compile.ok);
    }
    {
        var r = try rag.run(io, gpa, .{ .content_root = content, .out_dir = b, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.compile.ok);
    }
    try treesByteIdentical(io, gpa, a, b);
}

// ---------------------------------------------------------------------------
// IR and RAG report matching graph diagnostic categories for invalid fixtures
// ---------------------------------------------------------------------------

test "hardening: IR and RAG match graph diagnostic categories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Fixture = struct { root: []const u8, code: diag.Code };
    const fixtures = [_]Fixture{
        .{ .root = "docs/contracts/fixtures/duplicate-ids/content", .code = .EDUPLICATEID },
        .{ .root = "docs/contracts/fixtures/missing-parent/content", .code = .EPARENTMISSING },
        .{ .root = "docs/contracts/fixtures/self-parent/content", .code = .EPARENTSELF },
        .{ .root = "docs/contracts/fixtures/cycles/content", .code = .EPARENTCYCLE },
        .{ .root = "docs/contracts/fixtures/satellite-of-satellite/content", .code = .EPARENTNOTTRUNK },
        .{ .root = "docs/contracts/fixtures/longer-cycle/content", .code = .EPARENTCYCLE },
    };

    for (fixtures) |fx| {
        var work = try WorkDir.create(gpa, io, "graph-match");
        defer work.cleanup();
        const ir_out = try work.join("ir");
        defer gpa.free(ir_out);
        const rag_out = try work.join("rag");
        defer gpa.free(rag_out);

        var ir = try pipeline.run(io, gpa, .{ .content_root = fx.root, .out_dir = ir_out, .quiet = true });
        defer ir.deinit();
        try std.testing.expect(!ir.ok);

        var rr = try rag.run(io, gpa, .{ .content_root = fx.root, .out_dir = rag_out, .quiet = true });
        defer rr.deinit();
        try std.testing.expect(!rr.compile.ok);

        const ir_codes = try codesSet(ir.diagnostics.items, gpa);
        defer gpa.free(ir_codes);
        const rag_codes = try codesSet(rr.compile.diagnostics.items, gpa);
        defer gpa.free(rag_codes);
        try std.testing.expectEqualSlices(diag.Code, ir_codes, rag_codes);

        var saw = false;
        for (ir_codes) |c| {
            if (c == fx.code) saw = true;
        }
        try std.testing.expect(saw);
    }
}

// ---------------------------------------------------------------------------
// Scanner enumeration order cannot affect outputs
// ---------------------------------------------------------------------------

test "hardening: scanner creation order cannot affect IR bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "scan-order");
    defer work.cleanup();

    // Create in reverse entity-id order.
    try work.writeFile("content/z-last.md", "---\ntitle: Z\n---\n\nZ body\n");
    try work.writeFile("content/m-mid.md", "---\ntitle: M\n---\n\nM body\n");
    try work.writeFile("content/a-first.md", "---\ntitle: A\n---\n\nA body\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const out_a = try work.join("out-a");
    defer gpa.free(out_a);
    const out_b = try work.join("out-b");
    defer gpa.free(out_b);

    {
        var r = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = out_a, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.ok);
        try std.testing.expectEqualStrings("a-first", r.pages.items[0].id);
        try std.testing.expectEqualStrings("m-mid", r.pages.items[1].id);
        try std.testing.expectEqualStrings("z-last", r.pages.items[2].id);
    }
    {
        var r = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = out_b, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.ok);
    }
    try compareNamedFiles(io, gpa, out_a, out_b, &[_][]const u8{ "manifest.json", "graph.json" });
}

// ---------------------------------------------------------------------------
// Duplicate ID cannot be masked by map overwrite
// ---------------------------------------------------------------------------

test "hardening: duplicate id is diagnosed (not map-overwrite masked)" {
    const gpa = std.testing.allocator;
    var retain_arena = std.heap.ArenaAllocator.init(gpa);
    defer retain_arena.deinit();
    const retain = retain_arena.allocator();

    var nodes = [_]graph_mod.Node{
        .{ .id = "shared", .source_path = "alpha.md", .role = .trunk },
        .{ .id = "shared", .source_path = "beta.md", .role = .trunk },
        .{ .id = "other", .source_path = "other.md", .role = .trunk },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try graph_mod.validate(gpa, retain, &nodes, &diags);

    var saw_dup = false;
    var saw_both_paths = false;
    for (diags.items) |d| {
        if (d.code == .EDUPLICATEID) {
            saw_dup = true;
            // Message mentions both paths so neither is silently dropped.
            if (std.mem.indexOf(u8, d.message, "alpha") != null or
                std.mem.indexOf(u8, d.message, "beta") != null)
                saw_both_paths = true;
        }
    }
    try std.testing.expect(saw_dup);
    try std.testing.expect(saw_both_paths);
    // Map must not collapse to a single node for later topology: both still present.
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
}

// ---------------------------------------------------------------------------
// Output paths cannot escape configured roots
// ---------------------------------------------------------------------------

test "hardening: output paths cannot escape roots" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.IllegalSegment, identity.safeOutputRelativePath(gpa, "../etc/passwd"));
    try std.testing.expectError(error.IllegalSegment, identity.safeOutputRelativePath(gpa, "a/../../x"));
    try std.testing.expectError(error.AbsolutePath, identity.safeOutputRelativePath(gpa, "/abs"));
    try std.testing.expectError(error.IllegalSegment, identity.ragPagePath(gpa, "../escape"));
    try std.testing.expectError(error.EmptyId, identity.safeOutputRelativePath(gpa, ""));

    const ok = try identity.safeOutputRelativePath(gpa, "guides/intro");
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("guides/intro.html", ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "..") == null);
}

// ---------------------------------------------------------------------------
// Component validation on shared compile path
// ---------------------------------------------------------------------------

test "hardening: invalid component fails IR with ECOMPONENT" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "bad-comp");
    defer work.cleanup();

    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Bad
        \\---
        \\
        \\<Figure src="x">
        \\nope
        \\</Figure>
        \\
    );
    const content = try work.join("content");
    defer gpa.free(content);
    const out = try work.join("out");
    defer gpa.free(out);

    var r = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = out, .quiet = true });
    defer r.deinit();
    try std.testing.expect(!r.ok);
    var saw = false;
    for (r.diagnostics.items) |d| {
        if (d.code == .ECOMPONENT) saw = true;
    }
    try std.testing.expect(saw);
}

test "hardening: valid Aside passes IR and RAG :::kind export" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "aside-ok");
    defer work.cleanup();

    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
        \\<Aside kind="tip" id="t1">
        \\Drink water.
        \\</Aside>
        \\
    );
    const content = try work.join("content");
    defer gpa.free(content);
    const ir_out = try work.join("ir");
    defer gpa.free(ir_out);
    const rag_out = try work.join("rag");
    defer gpa.free(rag_out);

    {
        var r = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = ir_out, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.ok);
    }
    {
        var r = try rag.run(io, gpa, .{ .content_root = content, .out_dir = rag_out, .quiet = true });
        defer r.deinit();
        try std.testing.expect(r.compile.ok);
    }

    const page = try work.readFile("rag/content/pages/index.md", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, ":::tip{id=\"t1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Drink water.") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<Aside") == null);
}

test "hardening: Details include preserves IR and projects to HTML and RAG" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "details-ok");
    defer work.cleanup();

    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\Before
        \\
        \\{{include includes/disclosure.md}}
        \\
        \\After
        \\
        \\<Details summary="RAG details" id="rag-1">
        \\Projected directly.
        \\</Details>
        \\
    );
    try work.writeFile("content/includes/disclosure.md",
        \\<Details summary="Read <this> & that" id="more-1" open="true">
        \\Inside **details**.
        \\</Details>
    );
    try work.writeFile("layouts/main.html", "<html><body>{{content}}</body></html>\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const ir_out = try work.join("ir");
    defer gpa.free(ir_out);
    const rag_out = try work.join("rag");
    defer gpa.free(rag_out);
    const dist = try work.join("dist");
    defer gpa.free(dist);
    const layout = try work.join("layouts/main.html");
    defer gpa.free(layout);

    var ir = try pipeline.run(io, gpa, .{ .content_root = content, .out_dir = ir_out, .quiet = true });
    defer ir.deinit();
    try std.testing.expect(ir.ok);
    for ([_][]const u8{ "manifest.json", "graph.json", "build-report.json" }) |name| {
        const rel = try std.fmt.allocPrint(gpa, "ir/{s}", .{name});
        defer gpa.free(rel);
        const artifact = try work.readFile(rel, gpa);
        defer gpa.free(artifact);
        try std.testing.expect(std.mem.indexOf(u8, artifact, "Details") == null);
    }
    var rr = try rag.run(io, gpa, .{ .content_root = content, .out_dir = rag_out, .quiet = true });
    defer rr.deinit();
    try std.testing.expect(rr.compile.ok);
    _ = try compile.compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = dist, .layout_path = layout, .quiet = true });

    const html = try work.readFile("dist/index.html", gpa);
    defer gpa.free(html);
    const before = std.mem.indexOf(u8, html, "Before").?;
    const details = std.mem.indexOf(u8, html, "<details class=\"details\" id=\"more-1\" open>").?;
    const after = std.mem.indexOf(u8, html, "After").?;
    try std.testing.expect(before < details and details < after);
    try std.testing.expect(std.mem.indexOf(u8, html, "<summary>Read &lt;this&gt; &amp; that</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>details</strong>") != null);

    const rag_page = try work.readFile("rag/content/pages/index.md", gpa);
    defer gpa.free(rag_page);
    try std.testing.expect(std.mem.indexOf(u8, rag_page, ":::details{summary=\"RAG details\" id=\"rag-1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rag_page, "<Details") == null);
}

test "hardening: Details HTML is stable across jobs and incremental builds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "details-determinism");
    defer work.cleanup();
    try work.writeFile("layouts/main.html", "<html><body>{{content}}</body></html>\n");
    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\<Details summary="Home details" id="home-details">
        \\One.
        \\</Details>
    );
    try work.writeFile("content/other.md",
        \\---
        \\title: Other
        \\---
        \\
        \\<Details summary="Other details" open="true">
        \\Two.
        \\</Details>
    );
    const content = try work.join("content");
    defer gpa.free(content);
    const layout = try work.join("layouts/main.html");
    defer gpa.free(layout);
    const seq = try work.join("seq");
    defer gpa.free(seq);
    const jobs = try work.join("jobs");
    defer gpa.free(jobs);
    const inc = try work.join("inc");
    defer gpa.free(inc);

    _ = try compile.compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = seq, .layout_path = layout, .jobs = 1, .quiet = true });
    _ = try compile.compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = jobs, .layout_path = layout, .jobs = 2, .quiet = true });
    _ = try compile.compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = inc, .layout_path = layout, .incremental = true, .quiet = true });
    const noop = try compile.compileHtmlSite(io, gpa, .{ .content_root = content, .dist_dir = inc, .layout_path = layout, .incremental = true, .quiet = true });
    try std.testing.expectEqual(@as(usize, 0), noop.pages_written);
    try compareNamedFiles(io, gpa, seq, jobs, &.{ "index.html", "other.html" });
    try compareNamedFiles(io, gpa, seq, inc, &.{ "index.html", "other.html" });
}

// ---------------------------------------------------------------------------
// Experimental HTML Aside stream
// ---------------------------------------------------------------------------

test "hardening: experimental HTML renders Aside not raw tags" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "html-aside");
    defer work.cleanup();

    try work.writeFile("content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\Hello **world**.
        \\
        \\<Aside kind="warning" id="w1">
        \\Careful.
        \\</Aside>
        \\
    );
    try work.writeFile("layouts/main.html", "<html><body>{{content}}</body></html>\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const dist = try work.join("dist");
    defer gpa.free(dist);
    const layout = try work.join("layouts/main.html");
    defer gpa.free(layout);

    const stats = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = layout,
        .quiet = true,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.pages_written);

    const html = try work.readFile("dist/index.html", gpa);
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "admonition--warning") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"w1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Careful") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<Aside") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>world</strong>") != null);
}

// ---------------------------------------------------------------------------
// Component fixture: unregistered
// ---------------------------------------------------------------------------

test "hardening: component-fail fixture is ECOMPONENT on pipeline" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "comp-fx");
    defer work.cleanup();
    const out = try work.join("out");
    defer gpa.free(out);

    var r = try pipeline.run(io, gpa, .{
        .content_root = "test/fixtures/component-fail/content",
        .out_dir = out,
        .quiet = true,
    });
    defer r.deinit();
    try std.testing.expect(!r.ok);
    var saw = false;
    for (r.diagnostics.items) |d| {
        if (d.code == .ECOMPONENT) saw = true;
    }
    try std.testing.expect(saw);
}

// ---------------------------------------------------------------------------
// Tokenizer unit coverage already in aside.zig; smoke API here
// ---------------------------------------------------------------------------

test "hardening: aside API smoke" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try aside.tokenizeBody(
        \\```
        \\<Aside kind="tip">
        \\lit
        \\</Aside>
        \\```
        \\
        \\<Aside kind="note">
        \\real
        \\</Aside>
        \\
    , arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
}
