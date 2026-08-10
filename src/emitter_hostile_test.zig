//! End-to-end gate: hostile content must not break the shape of published
//! machine-facing artifacts.
//!
//! This is the half of the injection work that has to outlive the specific
//! findings that motivated it. It does not check that `rag_emit.zig` escapes
//! correctly; it compiles hostile trees and then reads **every file the build
//! published**, asking `artifact_invariants.zig` whether the container is still
//! intact. A future emitter is covered the moment its output lands in the same
//! directory, and an artifact type with no registered checker fails outright.
//!
//! Trees come from `fixtures/hostile-output/*/content`. Adding one is a
//! directory, not a code change.

const std = @import("std");
const Io = std.Io;
const invariants = @import("artifact_invariants.zig");
const rag = @import("rag.zig");
const context = @import("context.zig");

const fixture_root = "fixtures/hostile-output";
const output_root = "test-output";

fn scratchDir(gpa: std.mem.Allocator, io: Io, label: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, output_root);
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const suffix = std.fmt.bytesToHex(&rnd, .lower);
    const rel = try std.fmt.allocPrint(gpa, "{s}/hostile-{s}-{s}", .{ output_root, label, suffix });
    errdefer gpa.free(rel);
    try cwd.createDirPath(io, rel);
    return rel;
}

/// Walk everything under `root` and collect invariant violations. Verbatim
/// document subtrees (`content/`, `system/`, working pack bodies) are raw
/// author content by design and are skipped: the fidelity contract, not the
/// emitter-containment invariant, governs them.
fn auditTree(gpa: std.mem.Allocator, io: Io, root: []const u8, allowed_keys: []const []const u8, out: *std.ArrayList(invariants.Violation), paths: *std.ArrayList([]u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, "content/") or std.mem.startsWith(u8, entry.path, "system/")) continue;
        // Working packs are complete verbatim authoring documents; only the
        // emitter-generated machine files are audited in working mode.
        if (!std.mem.endsWith(u8, entry.path, ".md") and !std.mem.endsWith(u8, entry.path, ".jsonl") and !std.mem.endsWith(u8, entry.path, ".json")) continue;
        if (std.mem.startsWith(u8, entry.path, "working-") and !std.mem.endsWith(u8, entry.path, ".json")) continue;
        const owned_path = try gpa.dupe(u8, entry.path);
        try paths.append(gpa, owned_path);

        var file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const bytes = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(bytes);

        try invariants.check(gpa, owned_path, bytes, allowed_keys, out);
    }
}

fn expectNoViolations(gpa: std.mem.Allocator, io: Io, tree: []const u8, root: []const u8, allowed_keys: []const []const u8) !void {
    var violations: std.ArrayList(invariants.Violation) = .empty;
    defer invariants.deinitAll(&violations, gpa);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    try auditTree(gpa, io, root, allowed_keys, &violations, &paths);
    try std.testing.expect(paths.items.len > 0);

    if (violations.items.len > 0) {
        std.debug.print("\nartifact invariant violations for {s}:\n", .{tree});
        for (violations.items) |v| {
            std.debug.print("  {s}:{d}: {s} — {s}\n", .{ v.path, v.line, @tagName(v.kind), v.detail });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "hostile content cannot break the shape of any published artifact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fixtures = try Io.Dir.cwd().openDir(io, fixture_root, .{ .iterate = true });
    defer fixtures.close(io);

    var trees: std.ArrayList([]u8) = .empty;
    defer {
        for (trees.items) |t| gpa.free(t);
        trees.deinit(gpa);
    }
    {
        var it = fixtures.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try trees.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]u8, trees.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    // A silently empty fixture directory would make this test vacuously green.
    try std.testing.expect(trees.items.len >= 3);

    for (trees.items) |tree| {
        const content = try std.fmt.allocPrint(gpa, "{s}/{s}/content", .{ fixture_root, tree });
        defer gpa.free(content);

        // A tree carrying this marker is refused at ingest instead of being
        // published safely — the two are different guarantees and the fixture
        // says which one it is testing.
        const marker = try std.fmt.allocPrint(gpa, "{s}/{s}/REJECT-AT-INGEST", .{ fixture_root, tree });
        defer gpa.free(marker);
        const expect_rejection = blk: {
            var f = Io.Dir.cwd().openFile(io, marker, .{}) catch break :blk false;
            f.close(io);
            break :blk true;
        };

        if (expect_rejection) {
            const out = try scratchDir(gpa, io, tree);
            defer gpa.free(out);
            defer Io.Dir.cwd().deleteTree(io, out) catch {};
            var r = try rag.run(io, gpa, .{ .content_root = content, .out_dir = out, .quiet = true });
            defer r.deinit();
            try std.testing.expect(!r.compile.ok);
            var saw_unicode = false;
            for (r.compile.diagnostics.items) |d| {
                if (d.code == .EUNICODE and d.severity == .error_) saw_unicode = true;
            }
            try std.testing.expect(saw_unicode);
            continue;
        }

        const rag_out = try scratchDir(gpa, io, tree);
        defer gpa.free(rag_out);
        defer Io.Dir.cwd().deleteTree(io, rag_out) catch {};
        {
            // Complete-corpus emitter files (INDEX, UPLOAD-GUIDE, graph docs,
            // catalog) are emitter-generated containers; verbatim content and
            // system subtrees are excluded by the audit filter above.
            var r = try rag.run(io, gpa, .{ .content_root = content, .out_dir = rag_out, .complete = true, .quiet = true });
            defer r.deinit();
            try std.testing.expect(r.compile.ok);
        }
        try expectNoViolations(gpa, io, tree, rag_out, &invariants.rag_frontmatter_keys);

        // Working mode: the machine sidecar files must still be intact JSON.
        const work_out = try scratchDir(gpa, io, tree);
        defer gpa.free(work_out);
        defer Io.Dir.cwd().deleteTree(io, work_out) catch {};
        {
            var r = try rag.run(io, gpa, .{ .content_root = content, .out_dir = work_out, .quiet = true });
            defer r.deinit();
            try std.testing.expect(r.compile.ok);
        }
        try expectNoViolations(gpa, io, tree, work_out, &invariants.rag_frontmatter_keys);

        const ctx_out = try scratchDir(gpa, io, tree);
        defer gpa.free(ctx_out);
        defer Io.Dir.cwd().deleteTree(io, ctx_out) catch {};
        {
            var r = try context.run(io, gpa, .{ .content_root = content, .out_dir = ctx_out, .quiet = true });
            defer r.deinit();
            try std.testing.expect(r.compile.ok);
        }
        try expectNoViolations(gpa, io, tree, ctx_out, &invariants.context_frontmatter_keys);
    }
}

test "legitimate punctuation survives the emitters unmangled" {
    // A security fix that mangles ordinary documentation is a product bug. The
    // titles below are real authoring, not payloads, and must reach the corpus
    // with their characters intact.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const out = try scratchDir(gpa, io, "legit");
    defer gpa.free(out);
    defer Io.Dir.cwd().deleteTree(io, out) catch {};
    {
        var r = try rag.run(io, gpa, .{
            .content_root = fixture_root ++ "/legitimate-punctuation/content",
            .out_dir = out,
            .complete = true,
            .quiet = true,
        });
        defer r.deinit();
        try std.testing.expect(r.compile.ok);
    }

    var dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer dir.close(io);
    // Complete-corpus pages are verbatim authoring documents, so the needles
    // are the author's own frontmatter lines.
    const expectations = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "content/pages/international.md", .needle = "title: 日本語のドキュメント — مرحبا — Release 🎉" },
        .{ .path = "content/pages/prose.md", .needle = "title: Pipes | tables | and other punctuation in a real title" },
        .{ .path = "content/pages/prose.md", .needle = "tags: [docs, \"release 2026\"]" },
    };
    for (expectations) |want| {
        var file = try dir.openFile(io, want.path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const bytes = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(bytes);
        if (std.mem.indexOf(u8, bytes, want.needle) == null) {
            std.debug.print("\nmissing from {s}:\n  {s}\n", .{ want.path, want.needle });
            return error.LegitimateContentMangled;
        }
    }
}
