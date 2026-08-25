const std = @import("std");
const Io = std.Io;
const generator = @import("fixture_generator");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");

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

fn runClaimsForFixture(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    output_relative: []const u8,
    barb: ?[]const u8,
) !void {
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, output_relative });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);

    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});
    try publication_claims.writeAfterChecks(io, allocator, output, "default", .{});

    const claims_bytes = try readPayload(io, output, allocator, publication_claims.output_path);
    defer allocator.free(claims_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, claims_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(publication_claims.report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, publication_claims.schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("default", root.get("target").?.string);
    const claims = root.get("claims").?.array.items;
    const limitations = root.get("limitations").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), claims.len);
    try std.testing.expectEqual(@as(usize, 6), limitations.len);

    const checks_bytes = try readPayload(io, output, allocator, publication_checks.output_path);
    defer allocator.free(checks_bytes);
    var checks_parsed = try std.json.parseFromSlice(std.json.Value, allocator, checks_bytes, .{});
    defer checks_parsed.deinit();
    const checks = checks_parsed.value.object.get("checks").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), checks.len);

    for (claims, checks, publication_claims.claim_ids) |claim, check, expected_id| {
        const check_id = check.object.get("id").?.string;
        try std.testing.expectEqualStrings(expected_id, claim.object.get("id").?.string);
        const claim_status = claim.object.get("status").?.string;
        const evidence = claim.object.get("evidence").?.object;
        try std.testing.expectEqualStrings(check_id, evidence.get("check_id").?.string);
        try std.testing.expectEqualStrings(check.object.get("status").?.string, evidence.get("check_status").?.string);
        const check_status = check.object.get("status").?.string;
        if (std.mem.eql(u8, check_status, "passed")) {
            try std.testing.expectEqualStrings("verified", claim_status);
            try std.testing.expect(evidence.get("reason").? == .null);
        } else if (std.mem.eql(u8, check_status, "failed")) {
            try std.testing.expectEqualStrings("failed", claim_status);
            try std.testing.expectEqualStrings("check-failed", evidence.get("reason").?.string);
        } else if (std.mem.eql(u8, check_status, "incomplete")) {
            try std.testing.expectEqualStrings("not-verified", claim_status);
            try std.testing.expectEqualStrings("check-incomplete", evidence.get("reason").?.string);
        } else {
            try std.testing.expectEqualStrings("not-verified", claim_status);
            try std.testing.expectEqualStrings("check-not-applicable", evidence.get("reason").?.string);
        }
    }

    if (barb) |selected| {
        if (std.mem.eql(u8, selected, "artifact_digest_mismatch")) {
            try std.testing.expectEqualStrings(
                "failed",
                claims[0].object.get("status").?.string,
            );
            try std.testing.expectEqualStrings(
                "verified",
                claims[1].object.get("status").?.string,
            );
        } else if (std.mem.eql(u8, selected, "html_unclosed_structure")) {
            try std.testing.expectEqualStrings(
                "not-verified",
                claims[1].object.get("status").?.string,
            );
        } else if (std.mem.eql(u8, selected, "search_stale_title")) {
            try std.testing.expectEqualStrings(
                "failed",
                claims[2].object.get("status").?.string,
            );
        }
    } else {
        for (claims) |claim| {
            try std.testing.expectEqualStrings("verified", claim.object.get("status").?.string);
        }
    }
}

test "mild-poison fixture claims track the checks evidence and clean republish verifies all" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        barb: []const u8,
        output_relative: []const u8,
    }{
        .{ .barb = "artifact_digest_mismatch", .output_relative = "results/boris-output" },
        .{ .barb = "html_unclosed_structure", .output_relative = "results/boris-output" },
        .{ .barb = "search_stale_title", .output_relative = "results/boris-output" },
    };
    for (cases, 0..) |case, index| {
        const fixture_path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/tmp/{s}/publication-claims-mild-poison-{d}",
            .{ tmp.sub_path, index },
        );
        defer allocator.free(fixture_path);
        const selected = [_][]const u8{case.barb};
        var generated = try generator.generate(.{
            .io = io,
            .allocator = allocator,
            .output_path = fixture_path,
            .pages = 24,
            .seed = 20260801,
            .profile_selector = "mild-poison-v1",
            .barb_names = &selected,
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
        try runClaimsForFixture(io, allocator, fixture_path, case.output_relative, case.barb);
    }

    const clean_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-claims-clean",
        .{tmp.sub_path},
    );
    defer allocator.free(clean_fixture);
    var clean_generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = clean_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(clean_generated.assignments);
        clean_generated.profile.deinit(allocator);
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
    try runClaimsForFixture(io, allocator, clean_fixture, "results/republish-clean-output", null);
}
