//! Hostile integration coverage for page layout selection (PR #50).
//!
//! Does **not** patch product modules. Probes contract edges and records
//! failures as test errors for the audit report.
//!
//! Built via `zig build test` and `zig build test-layout-hostile`.
//! Fixtures: `docs/contracts/fixtures/layout-rules/hostile/`.

const std = @import("std");
const Io = std.Io;
const layout_select = @import("layout_select.zig");
const compile = @import("compile.zig");
const target_mod = @import("target.zig");
const page_mod = @import("page.zig");
const cli = @import("cli.zig");

const fixture_root = "docs/contracts/fixtures/layout-rules/hostile";
const content_root = fixture_root ++ "/content";
const theme_alpha = fixture_root ++ "/themes/alpha";
const theme_beta = fixture_root ++ "/themes/beta";
const layout_main = theme_alpha ++ "/layouts/main.html";
const layout_home = theme_alpha ++ "/layouts/home.html";
const layout_ref = theme_alpha ++ "/layouts/reference.html";
const layout_section = theme_alpha ++ "/layouts/section.html";
const layout_alt = theme_alpha ++ "/layouts/alt.html";
const layout_beta_main = theme_beta ++ "/layouts/main.html";
const product_default_layout = "layouts/main.html";

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

// ---------------------------------------------------------------------------
// Workdir helpers (disposable under test-output/)
// ---------------------------------------------------------------------------

const WorkDir = struct {
    gpa: std.mem.Allocator,
    io: Io,
    rel: []u8,

    fn create(gpa: std.mem.Allocator, io: Io, label: []const u8) !WorkDir {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, "test-output");
        var rnd: [4]u8 = undefined;
        io.random(&rnd);
        const suffix = std.fmt.bytesToHex(&rnd, .lower);
        const rel = try std.fmt.allocPrint(gpa, "test-output/layout-hostile-{s}-{s}", .{ label, suffix });
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

    fn fileExists(self: *const WorkDir, rel_path: []const u8) bool {
        const full = self.join(rel_path) catch return false;
        defer self.gpa.free(full);
        Io.Dir.cwd().access(self.io, full, .{}) catch return false;
        return true;
    }
};

fn markerOf(html: []const u8) ?[]const u8 {
    const key = "data-layout=\"";
    const start = std.mem.indexOf(u8, html, key) orelse return null;
    const from = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, html, from, '"') orelse return null;
    return html[from..end];
}

fn expectMarker(html: []const u8, want: []const u8) !void {
    const got = markerOf(html) orelse {
        std.debug.print("error: no data-layout marker in html ({d} bytes)\n", .{html.len});
        return error.TestExpectedEqual;
    };
    try expectEqualStrings(want, got);
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
            // Compare published site only; cache namespaces may differ by path.
            if (std.mem.startsWith(u8, entry.path, ".boris-cache")) continue;
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
            if (std.mem.startsWith(u8, entry.path, ".boris-cache")) continue;
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
    try expectEqual(files_a.items.len, files_b.items.len);

    var dir_a = try Io.Dir.cwd().openDir(io, a_root, .{});
    defer dir_a.close(io);
    var dir_b = try Io.Dir.cwd().openDir(io, b_root, .{});
    defer dir_b.close(io);

    for (files_a.items, files_b.items) |ap, bp| {
        try expectEqualStrings(ap, bp);
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
        try expectEqualSlices(u8, ab, bb);
    }
}

const expectEqualSlices = std.testing.expectEqualSlices;

fn standardRules() [3]layout_select.LayoutRule {
    return .{
        .{ .kind = .id, .value = "index", .layout_path = layout_home },
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .role, .value = "trunk", .layout_path = layout_section },
    };
}

fn compileWithRules(
    io: Io,
    gpa: std.mem.Allocator,
    dist: []const u8,
    rules: []const layout_select.LayoutRule,
    fallback: []const u8,
    incremental: bool,
) !compile.CompileStats {
    return compile.compileHtmlSite(io, gpa, .{
        .content_root = content_root,
        .dist_dir = dist,
        .layout_path = fallback,
        .layout_rules = rules,
        .incremental = incremental,
        .quiet = true,
    });
}

// ---------------------------------------------------------------------------
// H1 — exact > glob > role > fallback (pure + HTML markers)
// ---------------------------------------------------------------------------

test "H1 pure: exact id beats glob beats role beats fallback" {
    const rules = standardRules();
    {
        const s = try layout_select.selectLayout("index", .trunk, &rules, layout_main);
        try expectEqual(.exact, s.kind);
        try expectEqualStrings(layout_home, s.layout_path);
    }
    {
        const s = try layout_select.selectLayout("reference/configuration", .satellite, &rules, layout_main);
        try expectEqual(.glob, s.kind);
        try expectEqualStrings(layout_ref, s.layout_path);
    }
    {
        const s = try layout_select.selectLayout("guides", .trunk, &rules, layout_main);
        try expectEqual(.role, s.kind);
        try expectEqualStrings(layout_section, s.layout_path);
    }
    {
        const s = try layout_select.selectLayout("guides/getting-started", .satellite, &rules, layout_main);
        try expectEqual(.fallback, s.kind);
        try expectEqualStrings(layout_main, s.layout_path);
    }
}

test "H1 html: data-layout markers match precedence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h1-markers");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);

    const rules = standardRules();
    const stats = try compileWithRules(io, gpa, dist, &rules, layout_main, false);
    try expect(stats.pages_written >= 5);

    const index = try work.readFile("dist/index.html", gpa);
    defer gpa.free(index);
    try expectMarker(index, "home");

    const guides = try work.readFile("dist/guides.html", gpa);
    defer gpa.free(guides);
    try expectMarker(guides, "section");

    const gs = try work.readFile("dist/guides/getting-started.html", gpa);
    defer gpa.free(gs);
    try expectMarker(gs, "main");

    const ref = try work.readFile("dist/reference.html", gpa);
    defer gpa.free(ref);
    try expectMarker(ref, "section");

    const cfg = try work.readFile("dist/reference/configuration.html", gpa);
    defer gpa.free(cfg);
    try expectMarker(cfg, "reference");
}

// ---------------------------------------------------------------------------
// H2 — equal-specificity glob ambiguity
// ---------------------------------------------------------------------------

test "H2 pure: equal-specificity globs are AmbiguousGlob even with same path" {
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .glob, .value = "*/configuration", .layout_path = layout_main },
    };
    try expectError(
        error.AmbiguousGlob,
        layout_select.selectLayout("reference/configuration", .satellite, &rules, layout_main),
    );

    const same_path = [_]layout_select.LayoutRule{
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .glob, .value = "*/configuration", .layout_path = layout_ref },
    };
    try expectError(
        error.AmbiguousGlob,
        layout_select.selectLayout("reference/configuration", .satellite, &same_path, layout_main),
    );
}

test "H2 html: ambiguous globs fail without publishing HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h2-ambig");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);

    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .glob, .value = "*/configuration", .layout_path = layout_main },
    };
    try expectError(error.AmbiguousGlob, compileWithRules(io, gpa, dist, &rules, layout_main, false));

    // No successful page HTML under dist (cache-only noise is still a fail).
    if (work.fileExists("dist/index.html") or
        work.fileExists("dist/reference/configuration.html"))
    {
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// H3 — rule-order permutation determinism
// ---------------------------------------------------------------------------

test "H3 pure + html: argv/rule order does not change selection or HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const a = [_]layout_select.LayoutRule{
        .{ .kind = .role, .value = "trunk", .layout_path = layout_section },
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .id, .value = "index", .layout_path = layout_home },
    };
    const b = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = layout_home },
        .{ .kind = .role, .value = "trunk", .layout_path = layout_section },
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
    };
    const c = [_]layout_select.LayoutRule{
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .id, .value = "index", .layout_path = layout_home },
        .{ .kind = .role, .value = "trunk", .layout_path = layout_section },
    };

    const ids = [_]struct { id: []const u8, role: page_mod.Role }{
        .{ .id = "index", .role = .trunk },
        .{ .id = "reference/configuration", .role = .satellite },
        .{ .id = "guides", .role = .trunk },
        .{ .id = "guides/getting-started", .role = .satellite },
    };
    for (ids) |page| {
        const sa = try layout_select.selectLayout(page.id, page.role, &a, layout_main);
        const sb = try layout_select.selectLayout(page.id, page.role, &b, layout_main);
        const sc = try layout_select.selectLayout(page.id, page.role, &c, layout_main);
        try expectEqualStrings(sa.layout_path, sb.layout_path);
        try expectEqualStrings(sa.layout_path, sc.layout_path);
        try expectEqual(sa.kind, sb.kind);
        try expectEqual(sa.kind, sc.kind);
    }

    // Digest material is declaration-order independent.
    const da = try layout_select.ruleTableDigestMaterial(gpa, "default", &a, layout_main);
    defer gpa.free(da);
    const db = try layout_select.ruleTableDigestMaterial(gpa, "default", &b, layout_main);
    defer gpa.free(db);
    const dc = try layout_select.ruleTableDigestMaterial(gpa, "default", &c, layout_main);
    defer gpa.free(dc);
    try expectEqualStrings(da, db);
    try expectEqualStrings(da, dc);

    // HTML trees byte-identical across permutations.
    var work = try WorkDir.create(gpa, io, "h3-order");
    defer work.cleanup();
    const dist_a = try work.join("a");
    defer gpa.free(dist_a);
    const dist_b = try work.join("b");
    defer gpa.free(dist_b);
    const dist_c = try work.join("c");
    defer gpa.free(dist_c);

    _ = try compileWithRules(io, gpa, dist_a, &a, layout_main, false);
    _ = try compileWithRules(io, gpa, dist_b, &b, layout_main, false);
    _ = try compileWithRules(io, gpa, dist_c, &c, layout_main, false);
    try treesByteIdentical(io, gpa, dist_a, dist_b);
    try treesByteIdentical(io, gpa, dist_a, dist_c);
}

// ---------------------------------------------------------------------------
// H4 — fallback chain: target-layout → html-layout/theme → product default
// ---------------------------------------------------------------------------

test "H4 fallback: target-layout beats global html-layout beats product default" {
    // Pure effectiveLayout chain (CLI resolution surface).
    const with_target: target_mod.TargetSpec = .{
        .name = "prod",
        .output_dir = "dist-prod",
        .layout_path = layout_section,
    };
    try expectEqualStrings(layout_section, target_mod.effectiveLayout(with_target, layout_main));

    const no_target: target_mod.TargetSpec = .{
        .name = "default",
        .output_dir = "dist",
        .layout_path = null,
    };
    try expectEqualStrings(layout_main, target_mod.effectiveLayout(no_target, layout_main));
    try expectEqualStrings(product_default_layout, target_mod.effectiveLayout(no_target, product_default_layout));

    // CLI: --theme synthesizes html_layout = ROOT/layouts/main.html
    {
        var o = try cli.parseOptions(std.testing.allocator, &.{
            "boris",
            "--input", content_root,
            "--theme", theme_alpha,
            "--html-dir", "dist-theme",
        });
        defer o.deinit(std.testing.allocator);
        try expectEqualStrings(layout_main, o.html_layout);
        try expect(o.targets.items.len == 1);
        try expectEqualStrings("default", o.targets.items[0].name);
        // No --target-layout → effective is theme main.
        try expectEqualStrings(
            layout_main,
            target_mod.effectiveLayout(o.targets.items[0], o.html_layout),
        );
    }

    // CLI: --target-layout overrides theme/html-layout for that target.
    {
        var o = try cli.parseOptions(std.testing.allocator, &.{
            "boris",
            "--input", content_root,
            "--theme", theme_alpha,
            "--target", "docs=dist-docs",
            "--target-layout", "docs=" ++ layout_section,
            "--layout-rule", "docs", "id:index", layout_home,
        });
        defer o.deinit(std.testing.allocator);
        try expectEqual(@as(usize, 1), o.targets.items.len);
        try expectEqualStrings(layout_section, o.targets.items[0].layout_path.?);
        try expectEqualStrings(
            layout_section,
            target_mod.effectiveLayout(o.targets.items[0], o.html_layout),
        );
        // Unmatched page uses target fallback (section), not theme main.
        const s = try layout_select.selectLayout(
            "guides/getting-started",
            .satellite,
            o.targets.items[0].layout_rules,
            target_mod.effectiveLayout(o.targets.items[0], o.html_layout),
        );
        try expectEqual(.fallback, s.kind);
        try expectEqualStrings(layout_section, s.layout_path);
    }

    // HTML: no rules + product default layout still builds.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h4-default");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);
    // Tiny one-page content under workdir for product default layout.
    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Default Fallback
        \\---
        \\
        \\# Default
        \\
    );
    const content = try work.join("content");
    defer gpa.free(content);
    const stats = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = product_default_layout,
        .quiet = true,
    });
    try expectEqual(@as(usize, 1), stats.pages_written);
    try expect(work.fileExists("dist/index.html"));
}

// ---------------------------------------------------------------------------
// H5 — invalid paths, traversal, missing files, mixed theme roots
// ---------------------------------------------------------------------------

test "H5 mixed theme roots rejected at target validate and select preflight" {
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = layout_beta_main },
    };
    // Fallback is alpha main; rule is beta → MixedThemeRoots.
    try expectError(error.MixedThemeRoots, target_mod.rejectMixedThemeRoots(layout_main, &rules));

    // Managed + legacy mix.
    const mix = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = product_default_layout },
    };
    try expectError(error.MixedThemeRoots, target_mod.rejectMixedThemeRoots(layout_main, &mix));

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h5-mix");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);
    try expectError(error.MixedThemeRoots, compileWithRules(io, gpa, dist, &rules, layout_main, false));
    try expect(!work.fileExists("dist/index.html"));
}

test "H5 missing layout file fails without silent next-rule fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h5-missing");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);

    const missing = theme_alpha ++ "/layouts/does-not-exist.html";
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = missing },
        // Would win if product silently skipped missing exact — must not.
        .{ .kind = .role, .value = "trunk", .layout_path = layout_section },
    };
    // Any error is a fail-closed outcome; exact class is I/O or layout-load.
    const result = compileWithRules(io, gpa, dist, &rules, layout_main, false);
    try expect(std.meta.isError(result));
    try expect(!work.fileExists("dist/index.html"));
}

test "H5 traversal / cross-theme via .. is InvalidLayoutPath at every surface" {
    // Pure lexical reject (no filesystem).
    try expectError(
        error.InvalidLayoutPath,
        layout_select.validateLayoutPath(theme_alpha ++ "/layouts/../../themes/beta/layouts/main.html"),
    );
    try expectError(error.InvalidLayoutPath, layout_select.validateLayoutPath("../layouts/main.html"));
    try expectError(error.InvalidLayoutPath, layout_select.validateLayoutPath("/abs/main.html"));
    try expectError(error.InvalidLayoutPath, layout_select.validateLayoutPath("theme/./layouts/main.html"));

    // CLI: usage error before discovery.
    try expectError(error.InvalidValue, cli.parseOptions(std.testing.allocator, &.{
        "boris",
        "--layout-rule", "default", "id:index",
        theme_alpha ++ "/layouts/../../themes/beta/layouts/main.html",
        "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, cli.parseOptions(std.testing.allocator, &.{
        "boris", "--html-layout", "../layouts/main.html", "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, cli.parseOptions(std.testing.allocator, &.{
        "boris", "--target", "prod=dist/p", "--target-layout", "prod=../layouts/x.html",
    }));
    try expectError(error.InvalidValue, cli.parseOptions(std.testing.allocator, &.{
        "boris", "--theme", "../evil", "--html-dir", "d",
    }));

    // Library compile path rejects without publishing.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h5-trav");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);
    const cross = [_]layout_select.LayoutRule{
        .{
            .kind = .id,
            .value = "index",
            .layout_path = theme_alpha ++ "/layouts/../../themes/beta/layouts/main.html",
        },
    };
    try expectError(error.InvalidLayoutPath, compileWithRules(io, gpa, dist, &cross, layout_main, false));
    try expect(!work.fileExists("dist/index.html"));

    try expectError(error.InvalidLayoutPath, compile.compileHtmlSite(io, gpa, .{
        .content_root = content_root,
        .dist_dir = dist,
        .layout_path = "../layouts/main.html",
        .quiet = true,
    }));
    try expect(!work.fileExists("dist/index.html"));
}

test "H5 invalid selectors and duplicate selectors are usage errors at parse" {
    const gpa = std.testing.allocator;

    try expectError(error.InvalidValue, cli.parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "glob:ref*", layout_home, "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, cli.parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "role:branch", layout_home, "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, cli.parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "glob:**", layout_home, "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, cli.parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "id:", layout_home, "--html-dir", "d",
    }));
    try expectError(error.DuplicateFlag, cli.parseOptions(gpa, &.{
        "boris",
        "--layout-rule", "default", "id:index", layout_home,
        "--layout-rule", "default", "id:index", layout_section,
        "--html-dir", "d",
    }));
    try expectError(error.ConflictingFlags, cli.parseOptions(gpa, &.{
        "boris",
        "--layout-rule", "default", "id:index", layout_home,
        "--out", ".boris",
    }));
}

// ---------------------------------------------------------------------------
// H6 — multi-target isolation
// ---------------------------------------------------------------------------

test "H6 multi-target: isolated rules, markers, and cache namespaces" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h6-multi");
    defer work.cleanup();
    const dist_a = try work.join("site-a");
    defer gpa.free(dist_a);
    const dist_b = try work.join("site-b");
    defer gpa.free(dist_b);

    const rules_a = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = layout_home },
    };
    const rules_b = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = layout_alt },
        .{ .kind = .role, .value = "trunk", .layout_path = layout_section },
    };

    const targets = [_]target_mod.TargetSpec{
        .{
            .name = "alpha",
            .output_dir = dist_a,
            .layout_path = layout_main,
            .layout_rules = &rules_a,
        },
        .{
            .name = "beta",
            .output_dir = dist_b,
            .layout_path = layout_main,
            .layout_rules = &rules_b,
        },
    };

    // Full build for markers; then incremental for per-target cache namespaces.
    try compile.compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content_root,
        .layout_path = layout_main,
        .quiet = true,
    });

    const a_index = try work.readFile("site-a/index.html", gpa);
    defer gpa.free(a_index);
    try expectMarker(a_index, "home");

    const b_index = try work.readFile("site-b/index.html", gpa);
    defer gpa.free(b_index);
    try expectMarker(b_index, "alt");

    const a_guides = try work.readFile("site-a/guides.html", gpa);
    defer gpa.free(a_guides);
    try expectMarker(a_guides, "main"); // only id:index rule on alpha

    const b_guides = try work.readFile("site-b/guides.html", gpa);
    defer gpa.free(b_guides);
    try expectMarker(b_guides, "section");

    // Cache manifests are written only in incremental mode and stay target-local.
    try compile.compileHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content_root,
        .layout_path = layout_main,
        .incremental = true,
        .quiet = true,
    });
    try expect(work.fileExists("site-a/.boris-cache/manifest.json"));
    try expect(work.fileExists("site-b/.boris-cache/manifest.json"));
    const man_a = try work.readFile("site-a/.boris-cache/manifest.json", gpa);
    defer gpa.free(man_a);
    const man_b = try work.readFile("site-b/.boris-cache/manifest.json", gpa);
    defer gpa.free(man_b);
    try expect(std.mem.indexOf(u8, man_a, "boris-cache-v2-layout-rules") != null);
    try expect(std.mem.indexOf(u8, man_b, "boris-cache-v2-layout-rules") != null);
    try expect(std.mem.indexOf(u8, man_a, "selected_layout") != null);
    // Distinct selected layouts for index → manifests must differ.
    try expect(!std.mem.eql(u8, man_a, man_b));

    // Cross-target path isolation: beta must not write into alpha tree.
    // (validated by separate dist roots and distinct markers above)
}

// ---------------------------------------------------------------------------
// H7 — incremental rebuild after selected layout change
// ---------------------------------------------------------------------------

test "H7 incremental: changing selected layout rewrites page HTML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h7-inc-layout");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);

    const rules_v1 = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = layout_home },
    };
    const rules_v2 = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = layout_alt },
    };

    _ = try compileWithRules(io, gpa, dist, &rules_v1, layout_main, true);
    const html1 = try work.readFile("dist/index.html", gpa);
    defer gpa.free(html1);
    try expectMarker(html1, "home");

    // No-op with same rules.
    const stats_noop = try compileWithRules(io, gpa, dist, &rules_v1, layout_main, true);
    try expectEqual(@as(usize, 0), stats_noop.pages_written);

    // Change selected layout for index.
    const stats_change = try compileWithRules(io, gpa, dist, &rules_v2, layout_main, true);
    try expect(stats_change.pages_written >= 1);
    const html2 = try work.readFile("dist/index.html", gpa);
    defer gpa.free(html2);
    try expectMarker(html2, "alt");
    try expect(!std.mem.eql(u8, html1, html2));
}

// ---------------------------------------------------------------------------
// H8 — stale output cleanup after layout-rule / content changes
// ---------------------------------------------------------------------------

test "H8 stale cleanup: removed page HTML dropped; layout-rule change updates live pages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h8-stale");
    defer work.cleanup();

    // Local content tree so we can delete a page between builds.
    try work.writeFile(
        "content/index.md",
        \\---
        \\title: Home
        \\---
        \\
        \\# Home
        \\
    );
    try work.writeFile(
        "content/extra.md",
        \\---
        \\title: Extra
        \\---
        \\
        \\# Extra
        \\
    );
    try work.writeFile("theme/layouts/main.html", "<html><body data-layout=\"main\">{{content}}</body></html>\n");
    try work.writeFile("theme/layouts/home.html", "<html><body data-layout=\"home\">{{content}}</body></html>\n");
    try work.writeFile("theme/layouts/alt.html", "<html><body data-layout=\"alt\">{{content}}</body></html>\n");

    const content = try work.join("content");
    defer gpa.free(content);
    const dist = try work.join("dist");
    defer gpa.free(dist);
    const main_l = try work.join("theme/layouts/main.html");
    defer gpa.free(main_l);
    const home_l = try work.join("theme/layouts/home.html");
    defer gpa.free(home_l);
    const alt_l = try work.join("theme/layouts/alt.html");
    defer gpa.free(alt_l);

    const rules1 = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = home_l },
    };
    _ = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = main_l,
        .layout_rules = &rules1,
        .incremental = true,
        .quiet = true,
    });
    try expect(work.fileExists("dist/index.html"));
    try expect(work.fileExists("dist/extra.html"));
    {
        const h = try work.readFile("dist/index.html", gpa);
        defer gpa.free(h);
        try expectMarker(h, "home");
    }

    // Remove extra.md — full rebuild must scrub extra.html (stale cleanup).
    const extra_path = try work.join("content/extra.md");
    defer gpa.free(extra_path);
    try Io.Dir.cwd().deleteFile(io, extra_path);

    _ = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = main_l,
        .layout_rules = &rules1,
        .incremental = false, // full rebuild path for orphan HTML scrub
        .quiet = true,
    });
    try expect(work.fileExists("dist/index.html"));
    try expect(!work.fileExists("dist/extra.html"));

    // Layout-rule change: index moves home → alt; HTML must update (not leave home).
    const rules2 = [_]layout_select.LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = alt_l },
    };
    _ = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .layout_path = main_l,
        .layout_rules = &rules2,
        .incremental = true,
        .quiet = true,
    });
    const h2 = try work.readFile("dist/index.html", gpa);
    defer gpa.free(h2);
    try expectMarker(h2, "alt");
}

// ---------------------------------------------------------------------------
// H9 — full vs incremental byte-for-byte equivalence
// ---------------------------------------------------------------------------

test "H9 full vs incremental trees are byte-identical (published HTML + assets)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h9-full-inc");
    defer work.cleanup();
    const dist_full = try work.join("full");
    defer gpa.free(dist_full);
    const dist_inc = try work.join("inc");
    defer gpa.free(dist_inc);

    const rules = standardRules();
    _ = try compileWithRules(io, gpa, dist_full, &rules, layout_main, false);
    _ = try compileWithRules(io, gpa, dist_inc, &rules, layout_main, true);
    // Second incremental pass (no-op) must not drift.
    _ = try compileWithRules(io, gpa, dist_inc, &rules, layout_main, true);

    try treesByteIdentical(io, gpa, dist_full, dist_inc);
}

// ---------------------------------------------------------------------------
// H10 — repeated-run determinism
// ---------------------------------------------------------------------------

test "H10 repeated full builds are byte-identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h10-repeat");
    defer work.cleanup();
    const dist1 = try work.join("r1");
    defer gpa.free(dist1);
    const dist2 = try work.join("r2");
    defer gpa.free(dist2);
    const dist3 = try work.join("r3");
    defer gpa.free(dist3);

    const rules = standardRules();
    _ = try compileWithRules(io, gpa, dist1, &rules, layout_main, false);
    _ = try compileWithRules(io, gpa, dist2, &rules, layout_main, false);
    _ = try compileWithRules(io, gpa, dist3, &rules, layout_main, false);
    try treesByteIdentical(io, gpa, dist1, dist2);
    try treesByteIdentical(io, gpa, dist1, dist3);
}

test "H10 cache manifest stable across no-op incremental runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var work = try WorkDir.create(gpa, io, "h10-manifest");
    defer work.cleanup();
    const dist = try work.join("dist");
    defer gpa.free(dist);

    const rules = standardRules();
    _ = try compileWithRules(io, gpa, dist, &rules, layout_main, true);
    const m1 = try work.readFile("dist/.boris-cache/manifest.json", gpa);
    defer gpa.free(m1);
    _ = try compileWithRules(io, gpa, dist, &rules, layout_main, true);
    const m2 = try work.readFile("dist/.boris-cache/manifest.json", gpa);
    defer gpa.free(m2);
    try expectEqualStrings(m1, m2);
    try expect(std.mem.indexOf(u8, m1, "boris-cache-v2-layout-rules") != null);
    try expect(std.mem.indexOf(u8, m1, "selected_layout") != null);
}

// ---------------------------------------------------------------------------
// Bonus: more-specific glob wins; id override key is entity id not path
// ---------------------------------------------------------------------------

test "hostile: more literal glob segments win; entity id is match key" {
    const rules = [_]layout_select.LayoutRule{
        .{ .kind = .glob, .value = "*/*", .layout_path = layout_main },
        .{ .kind = .glob, .value = "reference/*", .layout_path = layout_ref },
        .{ .kind = .id, .value = "custom/home", .layout_path = layout_home },
    };
    const s = try layout_select.selectLayout("reference/configuration", .satellite, &rules, layout_section);
    try expectEqualStrings(layout_ref, s.layout_path);

    const s2 = try layout_select.selectLayout("custom/home", .trunk, &rules, layout_main);
    try expectEqual(.exact, s2.kind);
    try expectEqualStrings(layout_home, s2.layout_path);
}
