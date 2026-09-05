//! Static passthrough tests (#804): `--static-dir` copies a declared
//! directory byte-identically into the HTML target root, declares the files
//! as `static-file` artifact-inventory records, fails loudly on missing dirs,
//! symlinks, unsafe paths, and collisions, and scrubs stale files on rebuild.

const std = @import("std");
const Io = std.Io;
const compile = @import("compile.zig");
const compileHtmlSite = compile.compileHtmlSite;
const kit = @import("compile_test_kit.zig");
const target_mod = @import("target.zig");
const static_files = @import("static_files.zig");
const publication_checks = @import("publication_checks.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

const index_md =
    \\---
    \\title: Home
    \\status: published
    \\---
    \\
    \\# Home
    \\
    \\Welcome.
    \\
;

fn writeFile(rel: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) try cwd.createDirPath(io, parent);
    }
    try cwd.writeFile(io, .{ .sub_path = rel, .data = data });
}

fn readFileAlloc(rel: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    return cwd.readFileAlloc(io, rel, gpa, .unlimited);
}

test "static passthrough: byte-identical root copy, inventory record, and validation" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/sp", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(aa, "{s}/content", .{base});
    const static_dir = try std.fmt.allocPrint(aa, "{s}/static", .{base});
    const dist = try std.fmt.allocPrint(aa, "{s}/dist", .{base});

    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.md", .{content}), index_md);
    const robots_body = "User-agent: *\nDisallow:\n";
    const security_body = "Contact: mailto:security@example.test\n";
    try writeFile(try std.fmt.allocPrint(aa, "{s}/robots.txt", .{static_dir}), robots_body);
    try writeFile(try std.fmt.allocPrint(aa, "{s}/.well-known/security.txt", .{static_dir}), security_body);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    });

    const robots = try readFileAlloc(try std.fmt.allocPrint(aa, "{s}/robots.txt", .{dist}));
    defer gpa.free(robots);
    try std.testing.expectEqualStrings(robots_body, robots);
    const security = try readFileAlloc(try std.fmt.allocPrint(aa, "{s}/.well-known/security.txt", .{dist}));
    defer gpa.free(security);
    try std.testing.expectEqualStrings(security_body, security);

    const inv_bytes = try kit.readArtifactInventory(io, gpa, dist);
    defer gpa.free(inv_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inv_bytes, .{});
    defer parsed.deinit();
    try kit.expectArtifactRecord(parsed.value, "robots.txt", "static-file", "static-files", robots_body);
    try kit.expectArtifactRecord(parsed.value, ".well-known/security.txt", "static-file", "static-files", security_body);
    const robots_record = kit.findArtifactRecord(parsed.value, "robots.txt").?;
    try std.testing.expectEqualStrings("static", robots_record.object.get("semantics").?.string);

    // The zero-write preflight accepts the same configuration.
    const targets = [_]target_mod.TargetSpec{.{ .name = "default", .output_dir = dist }};
    try compile.validateHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .quiet = true,
        .static_dir = static_dir,
    });
}

test "static passthrough: missing directory fails loudly" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/sp-missing", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(aa, "{s}/content", .{base});
    const static_dir = try std.fmt.allocPrint(aa, "{s}/nope", .{base});
    const dist = try std.fmt.allocPrint(aa, "{s}/dist", .{base});

    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.md", .{content}), index_md);
    try std.testing.expectError(error.StaticDirMissing, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    }));

    const targets = [_]target_mod.TargetSpec{.{ .name = "default", .output_dir = dist }};
    // The multi-target wrap reports usage-class failures as its generic
    // LayoutSelectionFailed sentinel; the single-target path above preserves
    // the exact error.
    try std.testing.expectError(error.LayoutSelectionFailed, compile.validateHtmlSiteMulti(io, gpa, &targets, .{
        .content_root = content,
        .quiet = true,
        .static_dir = static_dir,
    }));
}

test "static passthrough: page collision and compiler-owned namespace fail loudly" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/sp-collide", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(aa, "{s}/content", .{base});
    const dist = try std.fmt.allocPrint(aa, "{s}/dist", .{base});
    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.md", .{content}), index_md);

    const static_dir = try std.fmt.allocPrint(aa, "{s}/static", .{base});
    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.html", .{static_dir}), "shadow\n");
    try std.testing.expectError(error.StaticPathCollision, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    }));

    const owned_dir = try std.fmt.allocPrint(aa, "{s}/static-owned", .{base});
    try writeFile(try std.fmt.allocPrint(aa, "{s}/_boris/proof/x.txt", .{owned_dir}), "nope\n");
    try std.testing.expectError(error.StaticPathUnsafe, compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = owned_dir,
    }));
}

test "static passthrough: stale file scrubbed on rebuild" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/sp-scrub", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(aa, "{s}/content", .{base});
    const static_dir = try std.fmt.allocPrint(aa, "{s}/static", .{base});
    const dist = try std.fmt.allocPrint(aa, "{s}/dist", .{base});

    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.md", .{content}), index_md);
    try writeFile(try std.fmt.allocPrint(aa, "{s}/keep.txt", .{static_dir}), "keep\n");
    try writeFile(try std.fmt.allocPrint(aa, "{s}/stale.txt", .{static_dir}), "stale\n");

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    });
    const stale = try readFileAlloc(try std.fmt.allocPrint(aa, "{s}/stale.txt", .{dist}));
    defer gpa.free(stale);
    try std.testing.expectEqualStrings("stale\n", stale);

    const cwd = Io.Dir.cwd();
    try cwd.deleteFile(io, try std.fmt.allocPrint(aa, "{s}/stale.txt", .{static_dir}));
    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    });
    const full_stale = try std.fmt.allocPrint(aa, "{s}/stale.txt", .{dist});
    const stat = cwd.statFile(io, full_stale, .{}) catch null;
    try std.testing.expect(stat == null);

    // The kept file survives and stays declared.
    const keep = try readFileAlloc(try std.fmt.allocPrint(aa, "{s}/keep.txt", .{dist}));
    defer gpa.free(keep);
    try std.testing.expectEqualStrings("keep\n", keep);
    const inv_bytes = try kit.readArtifactInventory(io, gpa, dist);
    defer gpa.free(inv_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inv_bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(kit.findArtifactRecord(parsed.value, "keep.txt") != null);
    try std.testing.expect(kit.findArtifactRecord(parsed.value, "stale.txt") == null);
}

test "static passthrough: declared .html survives full rebuilds (#866)" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/sp-html", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(aa, "{s}/content", .{base});
    const static_dir = try std.fmt.allocPrint(aa, "{s}/static", .{base});
    const dist = try std.fmt.allocPrint(aa, "{s}/dist", .{base});

    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.md", .{content}), index_md);
    const embed_body = "<html><body>embed page</body></html>\n";
    try writeFile(try std.fmt.allocPrint(aa, "{s}/robots.txt", .{static_dir}), "User-agent: *\n");
    try writeFile(try std.fmt.allocPrint(aa, "{s}/embed.html", .{static_dir}), embed_body);

    const options: compile.CompileOptions = .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    };
    _ = try compileHtmlSite(io, gpa, options);
    _ = try compileHtmlSite(io, gpa, options);

    // The declared passthrough file is still committed after the second
    // full build (the stale-output walker must not delete it).
    const embed = try readFileAlloc(try std.fmt.allocPrint(aa, "{s}/embed.html", .{dist}));
    defer gpa.free(embed);
    try std.testing.expectEqualStrings(embed_body, embed);
    const inv_bytes = try kit.readArtifactInventory(io, gpa, dist);
    defer gpa.free(inv_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inv_bytes, .{});
    defer parsed.deinit();
    try kit.expectArtifactRecord(parsed.value, "embed.html", "static-file", "static-files", embed_body);

    const checks_bytes = try kit.readTargetPayload(io, gpa, dist, publication_checks.output_path);
    defer gpa.free(checks_bytes);
    try kit.expectPublicationChecksShape(gpa, checks_bytes, "default");
}

test "static passthrough: empty declared directory commits no records" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}/sp-empty", .{tmp.sub_path});
    const content = try std.fmt.allocPrint(aa, "{s}/content", .{base});
    const static_dir = try std.fmt.allocPrint(aa, "{s}/static", .{base});
    const dist = try std.fmt.allocPrint(aa, "{s}/dist", .{base});

    try writeFile(try std.fmt.allocPrint(aa, "{s}/index.md", .{content}), index_md);
    try Io.Dir.cwd().createDirPath(io, static_dir);

    _ = try compileHtmlSite(io, gpa, .{
        .content_root = content,
        .dist_dir = dist,
        .quiet = true,
        .static_dir = static_dir,
    });
    const inv_bytes = try kit.readArtifactInventory(io, gpa, dist);
    defer gpa.free(inv_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, inv_bytes, .{});
    defer parsed.deinit();
    const artifacts = parsed.value.object.get("artifacts").?.array;
    for (artifacts.items) |record| {
        try std.testing.expect(!std.mem.eql(u8, record.object.get("kind").?.string, "static-file"));
    }
}

// Referenced so the module import stays meaningful when other helpers change.
comptime {
    _ = static_files;
}
