//! Shared test helpers moved verbatim from compile.zig's test region.
//! Referenced by the compile_*_test.zig siblings; wired via the trailing
//! import block in compile.zig (the test root for `test-compile`).

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
const readFileAlloc = compile.readFileAlloc;

pub fn readAllFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

pub fn writeTreeFile(io: Io, root_rel: []const u8, rel: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const full = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root_rel, rel });
    defer std.testing.allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| {
        try cwd.createDirPath(io, parent);
    }
    try cwd.writeFile(io, .{ .sub_path = full, .data = data });
}

pub fn readArtifactInventory(io: Io, gpa: std.mem.Allocator, dist_dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_dir, artifact_inventory.output_path });
    defer gpa.free(path);
    return readFileAlloc(io, Io.Dir.cwd(), path, gpa);
}

pub fn readTargetPayload(io: Io, gpa: std.mem.Allocator, dist_dir: []const u8, path: []const u8) ![]u8 {
    const full_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dist_dir, path });
    defer gpa.free(full_path);
    return readFileAlloc(io, Io.Dir.cwd(), full_path, gpa);
}

pub fn findArtifactRecord(root: std.json.Value, path: []const u8) ?std.json.Value {
    const artifacts = root.object.get("artifacts") orelse return null;
    for (artifacts.array.items) |record| {
        if (std.mem.eql(u8, record.object.get("path").?.string, path)) return record;
    }
    return null;
}

pub fn expectArtifactRecord(
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

pub fn expectArtifactInventoryShape(
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

pub fn expectPublicationChecksShape(
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

/// Slice the `NAV<…>ENDNAV` segment of the test layout's output.
pub fn navSegment(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "NAV<") orelse return "";
    const end = std.mem.indexOf(u8, bytes, ">ENDNAV") orelse return "";
    if (end < start) return "";
    return bytes[start + 4 .. end];
}

/// Slice the `BREAD<…>ENDBREAD` segment of the test layout's output.
pub fn crumbSegment(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "BREAD<") orelse return "";
    const end = std.mem.indexOf(u8, bytes, ">ENDBREAD") orelse return "";
    if (end < start) return "";
    return bytes[start + 6 .. end];
}

/// Slice the `NAV<…>ENDNAV` segment of this test's layout output.
pub fn navSegmentForDepthTest(bytes: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, bytes, "NAV<") orelse return "";
    const end = std.mem.indexOf(u8, bytes, ">ENDNAV") orelse return "";
    if (end < start) return "";
    return bytes[start + 4 .. end];
}
pub fn expectDirTreesEqual(io: Io, gpa: std.mem.Allocator, left_rel: []const u8, right_rel: []const u8) !void {
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

pub fn expectPublicationClaimsShape(
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
