const std = @import("std");
const Io = std.Io;
const generator = @import("fixture_generator");
const publication_checks = @import("publication_checks.zig");

const PoisonCase = struct {
    barb: []const u8,
    code: ?[]const u8,
    owner: ?[]const u8,
    coverage_check: []const u8,
    coverage: []const u8,
};

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

fn findingFor(findings: []const std.json.Value, code: []const u8) ?std.json.ObjectMap {
    for (findings) |finding| {
        const object = switch (finding) {
            .object => |value| value,
            else => continue,
        };
        const actual = switch (object.get("code") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, actual, code)) return object;
    }
    return null;
}

fn checkFor(checks: []const std.json.Value, id: []const u8) !std.json.ObjectMap {
    for (checks) |check| {
        const object = switch (check) {
            .object => |value| value,
            else => continue,
        };
        const actual = switch (object.get("id") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (std.mem.eql(u8, actual, id)) return object;
    }
    return error.MissingCheck;
}

fn expectFindingOwner(findings: []const std.json.Value, code: []const u8, owner: []const u8) !void {
    const object = findingFor(findings, code) orelse return error.MissingFinding;
    try std.testing.expectEqualStrings(owner, object.get("owner").?.string);
}

fn expectCheckCoverage(checks: []const std.json.Value, id: []const u8, coverage: []const u8) !void {
    const object = try checkFor(checks, id);
    try std.testing.expectEqualStrings(coverage, object.get("coverage").?.string);
}

fn expectedOwner(code: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, code, "HTML_LOCAL_ROUTE_MISSING") or
        std.mem.eql(u8, code, "HTML_FRAGMENT_MISSING") or
        std.mem.eql(u8, code, "HTML_DUPLICATE_ID") or
        std.mem.eql(u8, code, "HTML_MALFORMED")) return "unknown";
    if (std.mem.eql(u8, code, "ARTIFACT_MISSING") or
        std.mem.eql(u8, code, "ARTIFACT_SIZE_MISMATCH") or
        std.mem.eql(u8, code, "ARTIFACT_DIGEST_MISMATCH") or
        std.mem.eql(u8, code, "HTML_PAGE_MISSING") or
        std.mem.eql(u8, code, "SEARCH_DOCUMENT_MISSING") or
        std.mem.eql(u8, code, "SEARCH_CONTENT_MISMATCH")) return "publication";
    return null;
}

fn allowedFinding(case: PoisonCase, code: []const u8) bool {
    if (case.code) |expected| {
        if (std.mem.eql(u8, code, expected)) return true;
    }
    if (std.mem.eql(u8, case.barb, "html_missing_local_route") or
        std.mem.eql(u8, case.barb, "html_missing_fragment"))
    {
        return std.mem.eql(u8, code, "ARTIFACT_SIZE_MISMATCH") or
            std.mem.eql(u8, code, "ARTIFACT_DIGEST_MISMATCH") or
            std.mem.eql(u8, code, "SEARCH_CONTENT_MISMATCH");
    }
    if (std.mem.eql(u8, case.barb, "html_duplicate_id") or
        std.mem.eql(u8, case.barb, "html_unclosed_structure"))
    {
        return std.mem.eql(u8, code, "ARTIFACT_SIZE_MISMATCH") or
            std.mem.eql(u8, code, "ARTIFACT_DIGEST_MISMATCH");
    }
    if (std.mem.eql(u8, case.barb, "artifact_missing")) {
        return std.mem.eql(u8, code, "HTML_PAGE_MISSING") or
            std.mem.eql(u8, code, "SEARCH_DOCUMENT_MISSING");
    }
    if (std.mem.eql(u8, case.barb, "search_stale_title")) {
        return std.mem.eql(u8, code, "ARTIFACT_SIZE_MISMATCH") or
            std.mem.eql(u8, code, "ARTIFACT_DIGEST_MISMATCH");
    }
    return false;
}

fn expectAllowedFindings(findings: []const std.json.Value, case: PoisonCase) !void {
    for (findings) |finding| {
        const code = finding.object.get("code").?.string;
        if (!allowedFinding(case, code)) return error.UnexpectedFinding;
        try expectFindingOwner(findings, code, expectedOwner(code).?);
    }
}

fn pathExists(io: Io, root: Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

fn runPoisonCase(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    case: PoisonCase,
) !void {
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
    try std.testing.expectEqual(@as(usize, 1), generated.assignments.len);
    try std.testing.expectEqualStrings(case.barb, @tagName(generated.assignments[0].kind));

    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, "results/boris-output" });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);
    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});

    const report_bytes = try readPayload(io, output, allocator, publication_checks.output_path);
    defer allocator.free(report_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, report_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const checks = root.get("checks").?.array.items;
    const findings = root.get("findings").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), checks.len);
    try expectCheckCoverage(checks, case.coverage_check, case.coverage);

    if (case.code) |code| {
        try expectFindingOwner(findings, code, case.owner.?);
    } else {
        try std.testing.expectEqual(@as(usize, 0), findings.len);
    }
    try expectAllowedFindings(findings, case);
}

test "mild poison fixture exercises all publication-check evidence barbs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const default_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-checks-mild-poison-defaults",
        .{tmp.sub_path},
    );
    defer allocator.free(default_fixture);
    var defaults = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = default_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
    });
    defer {
        allocator.free(defaults.assignments);
        defaults.profile.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 8), defaults.assignments.len);
    try std.testing.expectEqual(@as(usize, 24), defaults.page_count);

    const cases = [_]PoisonCase{
        .{ .barb = "html_missing_local_route", .code = "HTML_LOCAL_ROUTE_MISSING", .owner = "unknown", .coverage_check = "rendered-html", .coverage = "complete" },
        .{ .barb = "html_missing_fragment", .code = "HTML_FRAGMENT_MISSING", .owner = "unknown", .coverage_check = "rendered-html", .coverage = "complete" },
        .{ .barb = "html_duplicate_id", .code = "HTML_DUPLICATE_ID", .owner = "unknown", .coverage_check = "rendered-html", .coverage = "complete" },
        .{ .barb = "html_unclosed_structure", .code = "HTML_MALFORMED", .owner = "unknown", .coverage_check = "rendered-html", .coverage = "incomplete" },
        .{ .barb = "artifact_missing", .code = "ARTIFACT_MISSING", .owner = "publication", .coverage_check = "artifact-integrity", .coverage = "incomplete" },
        .{ .barb = "artifact_digest_mismatch", .code = "ARTIFACT_DIGEST_MISMATCH", .owner = "publication", .coverage_check = "artifact-integrity", .coverage = "complete" },
        .{ .barb = "search_stale_title", .code = "SEARCH_CONTENT_MISMATCH", .owner = "publication", .coverage_check = "rendered-search", .coverage = "complete" },
        .{ .barb = "deployment_owned_extra", .code = null, .owner = null, .coverage_check = "rendered-html", .coverage = "complete" },
    };

    for (cases, 0..) |case, index| {
        const fixture_path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/tmp/{s}/publication-checks-mild-poison-{d}",
            .{ tmp.sub_path, index },
        );
        defer allocator.free(fixture_path);
        try runPoisonCase(io, allocator, fixture_path, case);
    }

    const combined_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-checks-owned-extra",
        .{tmp.sub_path},
    );
    defer allocator.free(combined_fixture);
    const combined_barbs = [_][]const u8{ "html_missing_local_route", "deployment_owned_extra" };
    var combined = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = combined_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &combined_barbs,
    });
    defer {
        allocator.free(combined.assignments);
        combined.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = combined_fixture,
        .boris_path = "./zig-out/bin/boris",
    });

    const combined_absolute = try fixtureAbsolute(io, allocator, combined_fixture);
    defer allocator.free(combined_absolute);
    const combined_output_absolute = try std.fs.path.join(allocator, &.{ combined_absolute, "results/boris-output" });
    defer allocator.free(combined_output_absolute);
    var combined_output = try Io.Dir.openDirAbsolute(io, combined_output_absolute, .{});
    defer combined_output.close(io);
    try std.testing.expect(pathExists(io, combined_output, "robots.txt"));
    try publication_checks.writeAfterCommit(io, allocator, combined_output, "default", .{});
    const combined_report_bytes = try readPayload(io, combined_output, allocator, publication_checks.output_path);
    defer allocator.free(combined_report_bytes);
    var combined_parsed = try std.json.parseFromSlice(std.json.Value, allocator, combined_report_bytes, .{});
    defer combined_parsed.deinit();
    const combined_findings = combined_parsed.value.object.get("findings").?.array.items;
    const combined_case = PoisonCase{
        .barb = "html_missing_local_route",
        .code = "HTML_LOCAL_ROUTE_MISSING",
        .owner = "unknown",
        .coverage_check = "rendered-html",
        .coverage = "complete",
    };
    try expectAllowedFindings(combined_findings, combined_case);
    try expectFindingOwner(combined_findings, "HTML_LOCAL_ROUTE_MISSING", "unknown");

    try generator.republishCleanFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = combined_fixture,
        .boris_path = "./zig-out/bin/boris",
    });
    const clean_absolute = try std.fs.path.join(allocator, &.{ combined_absolute, "results/republish-clean-output" });
    defer allocator.free(clean_absolute);
    var clean = try Io.Dir.openDirAbsolute(io, clean_absolute, .{});
    defer clean.close(io);
    try std.testing.expect(!pathExists(io, clean, "robots.txt"));
    try publication_checks.writeAfterCommit(io, allocator, clean, "default", .{});
    const clean_report_bytes = try readPayload(io, clean, allocator, publication_checks.output_path);
    defer allocator.free(clean_report_bytes);
    var clean_parsed = try std.json.parseFromSlice(std.json.Value, allocator, clean_report_bytes, .{});
    defer clean_parsed.deinit();
    const clean_root = clean_parsed.value.object;
    try std.testing.expectEqual(@as(usize, 0), clean_root.get("findings").?.array.items.len);
    for (clean_root.get("checks").?.array.items) |check| {
        try std.testing.expectEqualStrings("passed", check.object.get("status").?.string);
        try std.testing.expectEqualStrings("complete", check.object.get("coverage").?.string);
    }
}
