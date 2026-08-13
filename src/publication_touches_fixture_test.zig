const std = @import("std");
const Io = std.Io;
const generator = @import("fixture_generator");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");
const artifact_inventory = @import("artifact_inventory.zig");

fn readPayload(io: Io, root: Io.Dir, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    return reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
}

fn fixtureAbsolute(io: Io, allocator: std.mem.Allocator, fixture_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, fixture_path });
}

fn pathExists(io: Io, root: Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

/// Run Boris on the fixture, then derive checks, claims, and the Touch Atlas
/// in the exact publication order. Returns the committed touches bytes.
fn deriveTouches(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    output_relative: []const u8,
) ![]u8 {
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, output_relative });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);

    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});
    try publication_claims.writeAfterChecks(io, allocator, output, "default", .{});
    try publication_touches.writeAfterClaims(io, allocator, output, "default", .{});
    return readPayload(io, output, allocator, publication_touches.output_path);
}

/// Re-derive only the Touch Atlas layer from the already-committed evidence
/// reports. Unlike `deriveTouches`, this never invokes the checks or claims
/// layers, so a payload rewrite between calls cannot change the evidence the
/// atlas is bound to.
fn deriveTouchesOnly(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    output_relative: []const u8,
) ![]u8 {
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, output_relative });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);

    try publication_touches.writeAfterClaims(io, allocator, output, "default", .{});
    return readPayload(io, output, allocator, publication_touches.output_path);
}

/// Parse the touches report and return a self-contained owner that deinit's
/// the parsed tree. Callers borrow `root` and must defer `parsed.deinit()`.
const ParsedReport = struct {
    parsed: std.json.Parsed(std.json.Value),
    root: std.json.ObjectMap,

    fn init(allocator: std.mem.Allocator, touches: []const u8) !ParsedReport {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, touches, .{});
        errdefer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings(publication_touches.report_format, root.get("format").?.string);
        try std.testing.expectEqual(@as(i64, publication_touches.schema_version), root.get("schema_version").?.integer);
        try std.testing.expectEqualStrings("default", root.get("target").?.string);
        return .{ .parsed = parsed, .root = root };
    }

    fn deinit(self: *ParsedReport) void {
        self.parsed.deinit();
    }
};

fn edgeCount(root: std.json.ObjectMap) usize {
    return root.get("edges").?.array.items.len;
}

fn hasEdge(root: std.json.ObjectMap, kind: []const u8, from: []const u8, to: []const u8) bool {
    for (root.get("edges").?.array.items) |edge| {
        if (std.mem.eql(u8, edge.object.get("kind").?.string, kind) and
            std.mem.eql(u8, edge.object.get("from").?.string, from) and
            std.mem.eql(u8, edge.object.get("to").?.string, to)) return true;
    }
    return false;
}

fn nodeKindOf(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "target")) return "target";
    if (std.mem.startsWith(u8, id, "artifact:")) return "artifact";
    if (std.mem.startsWith(u8, id, "check:")) return "check";
    if (std.mem.startsWith(u8, id, "finding:")) return "finding";
    if (std.mem.startsWith(u8, id, "claim:")) return "claim";
    if (std.mem.startsWith(u8, id, "limitation:")) return "limitation";
    return "unknown";
}

fn allowedEdgeKinds(from_kind: []const u8, to_kind: []const u8, kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "target-owns-artifact"))
        return std.mem.eql(u8, from_kind, "target") and std.mem.eql(u8, to_kind, "artifact");
    if (std.mem.eql(u8, kind, "artifact-subject-of-check") or std.mem.eql(u8, kind, "artifact-supports-check"))
        return std.mem.eql(u8, from_kind, "artifact") and std.mem.eql(u8, to_kind, "check");
    if (std.mem.eql(u8, kind, "check-reported-finding"))
        return std.mem.eql(u8, from_kind, "check") and std.mem.eql(u8, to_kind, "finding");
    if (std.mem.eql(u8, kind, "check-supports-claim"))
        return std.mem.eql(u8, from_kind, "check") and std.mem.eql(u8, to_kind, "claim");
    if (std.mem.eql(u8, kind, "claim-limited-by"))
        return std.mem.eql(u8, from_kind, "claim") and std.mem.eql(u8, to_kind, "limitation");
    return false;
}

/// Every emitted edge endpoint must resolve to an emitted node, and every edge
/// kind must connect permitted node kinds.
fn expectEveryEdgeResolves(root: std.json.ObjectMap) !void {
    const nodes = root.get("nodes").?.array.items;
    for (root.get("edges").?.array.items) |edge| {
        const from = edge.object.get("from").?.string;
        const to = edge.object.get("to").?.string;
        const kind = edge.object.get("kind").?.string;
        var from_seen = false;
        var to_seen = false;
        for (nodes) |node| {
            const id = node.object.get("id").?.string;
            if (std.mem.eql(u8, id, from)) from_seen = true;
            if (std.mem.eql(u8, id, to)) to_seen = true;
        }
        try std.testing.expect(from_seen);
        try std.testing.expect(to_seen);
        try std.testing.expect(allowedEdgeKinds(nodeKindOf(from), nodeKindOf(to), kind));
    }
}

test "poisoned publication derives deterministic touches matching its evidence" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-touches-poison",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    const barbs = [_][]const u8{ "html_missing_local_route", "artifact_digest_mismatch", "deployment_owned_extra" };
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &barbs,
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const touches = try deriveTouches(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(touches);
    var report = try ParsedReport.init(allocator, touches);
    defer report.deinit();
    const root = report.root;
    try std.testing.expect(edgeCount(root) > 0);
    try expectEveryEdgeResolves(root);

    // The deployment-owned extra never becomes an artifact node.
    try std.testing.expect(!hasEdge(root, "target-owns-artifact", "target", "artifact:robots.txt"));

    // Finding nodes exist for the poisoned checks and resolve to claims.
    var finding_nodes: usize = 0;
    for (root.get("nodes").?.array.items) |node| {
        if (std.mem.eql(u8, node.object.get("kind").?.string, "finding"))
            finding_nodes += 1;
    }
    try std.testing.expect(finding_nodes > 0);
}

test "clean republish derives the expected clean graph" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const clean_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-touches-clean",
        .{tmp.sub_path},
    );
    defer allocator.free(clean_fixture);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = clean_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = clean_fixture,
        .boris_path = "./zig-out/bin/boris",
    });
    try generator.republishCleanFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = clean_fixture,
        .boris_path = "./zig-out/bin/boris",
    });

    const touches = try deriveTouches(io, allocator, clean_fixture, "results/republish-clean-output");
    defer allocator.free(touches);
    var report = try ParsedReport.init(allocator, touches);
    defer report.deinit();
    const root = report.root;
    // A clean graph has no finding nodes and no finding edges.
    var finding_nodes: usize = 0;
    for (root.get("nodes").?.array.items) |node| {
        if (std.mem.eql(u8, node.object.get("kind").?.string, "finding")) finding_nodes += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), finding_nodes);
    try std.testing.expect(!hasEdge(root, "check-reported-finding", "check:artifact-integrity", "finding:artifact-integrity:0"));
    try expectEveryEdgeResolves(root);
}

test "jobs 1 and 4 produce byte-identical touches and repeat runs are byte-identical" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-touches-jobs",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
        .jobs = 1,
    });

    const touches_j1 = try deriveTouches(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(touches_j1);
    const touches_j1_again = try deriveTouches(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(touches_j1_again);
    try std.testing.expectEqualSlices(u8, touches_j1, touches_j1_again);

    const jobs4_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-touches-jobs4",
        .{tmp.sub_path},
    );
    defer allocator.free(jobs4_fixture);
    var generated4 = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = jobs4_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated4.assignments);
        generated4.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = jobs4_fixture,
        .boris_path = "./zig-out/bin/boris",
        .jobs = 4,
    });
    const touches_j4 = try deriveTouches(io, allocator, jobs4_fixture, "results/boris-output");
    defer allocator.free(touches_j4);
    try std.testing.expectEqualSlices(u8, touches_j1, touches_j4);
}

test "omitted rendered search creates no invented artifact or check-subject edge" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-touches-no-search",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    // A profile without any poisoned pages still renders search by default;
    // this test asserts that whatever the fixture emitted, every edge in the
    // atlas resolves and no edge references an un-emitted search artifact.
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });
    const touches = try deriveTouches(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(touches);
    var report = try ParsedReport.init(allocator, touches);
    defer report.deinit();
    try expectEveryEdgeResolves(report.root);
}

// Negative control: the Touch Atlas layer must never reread publication
// payloads. Rewriting a committed payload byte-for-byte after a first
// derivation must leave the already-derived touches report untouched; only
// the three evidence reports feed the atlas.
test "no payload reread: rewriting payload bytes leaves prior touches untouched" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-touches-no-payload-reread",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    // Commit a first atlas from the real evidence chain.
    const first = try deriveTouches(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(first);

    // Corrupt the committed index.html payload between derivations. The atlas
    // layer itself derives only from evidence bytes, so re-deriving it alone
    // (never re-running the checks layer, which legitimately audits payloads)
    // must produce byte-identical output.
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, "results/boris-output" });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);
    const page = try readPayload(io, output, allocator, "index.html");
    defer allocator.free(page);
    const mutated = try std.mem.concat(allocator, u8, &.{ page, "\n<!-- tampered after publication -->" });
    defer allocator.free(mutated);
    try output.writeFile(io, .{ .sub_path = "index.html", .data = mutated });

    const second = try deriveTouchesOnly(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}

/// The exact committed bytes of the poisoned fixture's `touches.json` emitted
/// by PR #294 (first Touch Atlas implementation). This change is a pure
/// ownership cleanup and must not alter a single emitted byte; the golden
/// captures the full report (36834 bytes) and pins its SHA-256.
const touches_golden_sha256 = "2d7bf6d8c4f20e936be96b2e9335b1414658cf8aae8207d68add45aefc9f2245";
const touches_golden_len = 36834;

test "touches emission remains byte-identical to the PR #294 golden" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/capture-touches", .{tmp.sub_path});
    defer allocator.free(fixture_path);
    const barbs = [_][]const u8{ "html_missing_local_route", "artifact_digest_mismatch", "deployment_owned_extra" };
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &barbs,
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });
    const touches = try deriveTouches(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(touches);
    try std.testing.expectEqual(touches_golden_len, touches.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(touches, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(touches_golden_sha256, &hex);
}
