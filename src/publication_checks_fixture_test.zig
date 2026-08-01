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

// --- B03: requested worker passthrough determinism --------------------------
// These tests run the installed Boris binary through generator.runFixture with
// different `--jobs` values and prove the publication bytes and recorded
// evidence are identical except for `execution.requestedJobs`.

const JobEvidence = struct {
    run_json: []u8,
    checks_json: []u8,
    snapshot_jsonl: []u8,
    index_html: []u8,
    search_json: ?[]u8,
    artifacts_json: []u8,
    output_abs: []u8,
    jobs: usize,

    fn deinit(self: *JobEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.run_json);
        allocator.free(self.checks_json);
        allocator.free(self.snapshot_jsonl);
        allocator.free(self.index_html);
        if (self.search_json) |bytes| allocator.free(bytes);
        allocator.free(self.artifacts_json);
        allocator.free(self.output_abs);
        self.* = undefined;
    }
};

fn collectTreeFiles(io: Io, allocator: std.mem.Allocator, dir: Io.Dir, prefix: []const u8, files: *std.ArrayList([]u8)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            try collectTreeFiles(io, allocator, child, rel, files);
            allocator.free(rel);
        } else if (entry.kind == .file) {
            try files.append(allocator, rel);
        } else {
            allocator.free(rel);
            return error.UnsafeTree;
        }
    }
}

fn treesByteEqual(io: Io, allocator: std.mem.Allocator, a: Io.Dir, b: Io.Dir) !bool {
    var a_files: std.ArrayList([]u8) = .empty;
    defer {
        for (a_files.items) |f| allocator.free(f);
        a_files.deinit(allocator);
    }
    try collectTreeFiles(io, allocator, a, "", &a_files);
    std.sort.heap([]u8, a_files.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var b_files: std.ArrayList([]u8) = .empty;
    defer {
        for (b_files.items) |f| allocator.free(f);
        b_files.deinit(allocator);
    }
    try collectTreeFiles(io, allocator, b, "", &b_files);
    std.sort.heap([]u8, b_files.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    if (a_files.items.len != b_files.items.len) return false;
    for (a_files.items, b_files.items) |af, bf| {
        if (!std.mem.eql(u8, af, bf)) return false;
        const bytes_a = try readPayload(io, a, allocator, af);
        defer allocator.free(bytes_a);
        const bytes_b = try readPayload(io, b, allocator, bf);
        defer allocator.free(bytes_b);
        if (!std.mem.eql(u8, bytes_a, bytes_b)) return false;
    }
    return true;
}

/// Normalization helper: parse a `run.json`/`republish-clean.json` record and
/// replace only `execution.requestedJobs` with a canonical value, then
/// re-serialize deterministically so the remaining parsed evidence can be
/// compared byte-for-byte.
fn normalizedRunEvidence(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const exec_val = parsed.value.object.getPtr("execution") orelse return error.InvalidRunEvidence;
    const exec_map = switch (exec_val.*) {
        .object => |*object| object,
        else => return error.InvalidRunEvidence,
    };
    _ = try exec_map.put(allocator, "requestedJobs", .{ .integer = 1 });
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &out.writer);
    const buffered = out.writer.buffered();
    const copy = try allocator.dupe(u8, buffered);
    return copy;
}

fn captureJobsRun(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_rel: []const u8,
    jobs: usize,
) !JobEvidence {
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_rel,
        .boris_path = "./zig-out/bin/boris",
        .jobs = jobs,
    });
    const fixture_abs = try fixtureAbsolute(io, allocator, fixture_rel);
    defer allocator.free(fixture_abs);
    const output_abs = try std.fs.path.join(allocator, &.{ fixture_abs, "results/boris-output" });
    defer allocator.free(output_abs);
    var output = try Io.Dir.openDirAbsolute(io, output_abs, .{ .iterate = true });
    defer output.close(io);
    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});

    const index_html = try readPayload(io, output, allocator, "index.html");
    const artifacts_json = try readPayload(io, output, allocator, "_boris/proof/artifacts.json");
    const checks_json = try readPayload(io, output, allocator, publication_checks.output_path);
    var search_json: ?[]u8 = null;
    if (pathExists(io, output, "_boris/search/search-index.json")) {
        search_json = try readPayload(io, output, allocator, "_boris/search/search-index.json");
    }

    var fixture = try Io.Dir.openDirAbsolute(io, fixture_abs, .{});
    defer fixture.close(io);
    const run_json = try readPayload(io, fixture, allocator, "results/run.json");
    const snapshot_jsonl = try readPayload(io, fixture, allocator, "results/output-snapshot.jsonl");

    // The recorded evidence value must equal the exact value placed in the
    // Boris argument vector by generator.buildBorisInvocation for this run.
    var recorded = try std.json.parseFromSlice(std.json.Value, allocator, run_json, .{});
    defer recorded.deinit();
    const execution = switch (recorded.value.object.get("execution") orelse return error.InvalidRunEvidence) {
        .object => |object| object,
        else => return error.InvalidRunEvidence,
    };
    const recorded_jobs = switch (execution.get("requestedJobs") orelse return error.InvalidRunEvidence) {
        .integer => |value| value,
        else => return error.InvalidRunEvidence,
    };
    try std.testing.expectEqual(@as(i64, @intCast(jobs)), recorded_jobs);

    return .{
        .run_json = run_json,
        .checks_json = checks_json,
        .snapshot_jsonl = snapshot_jsonl,
        .index_html = index_html,
        .search_json = search_json,
        .artifacts_json = artifacts_json,
        .output_abs = try allocator.dupe(u8, output_abs),
        .jobs = jobs,
    };
}

fn expectCrossJobsDeterministic(
    io: Io,
    allocator: std.mem.Allocator,
    a: JobEvidence,
    b: JobEvidence,
) !void {
    try std.testing.expect(a.jobs != b.jobs);
    // The complete records may differ only where the requested worker value is
    // recorded: raw bytes differ, normalized parsed evidence is identical.
    try std.testing.expect(!std.mem.eql(u8, a.run_json, b.run_json));
    const norm_a = try normalizedRunEvidence(allocator, a.run_json);
    defer allocator.free(norm_a);
    const norm_b = try normalizedRunEvidence(allocator, b.run_json);
    defer allocator.free(norm_b);
    try std.testing.expectEqualSlices(u8, norm_a, norm_b);

    // Every Boris-owned payload byte is identical across worker counts.
    var out_a = try Io.Dir.openDirAbsolute(io, a.output_abs, .{ .iterate = true });
    defer out_a.close(io);
    var out_b = try Io.Dir.openDirAbsolute(io, b.output_abs, .{ .iterate = true });
    defer out_b.close(io);
    try std.testing.expect(try treesByteEqual(io, allocator, out_a, out_b));

    // checks.json and the full-tree snapshot are byte-identical.
    try std.testing.expectEqualSlices(u8, a.checks_json, b.checks_json);
    try std.testing.expectEqualSlices(u8, a.snapshot_jsonl, b.snapshot_jsonl);

    // Direct byte comparisons for representative payloads.
    try std.testing.expectEqualSlices(u8, a.index_html, b.index_html);
    try std.testing.expectEqualSlices(u8, a.artifacts_json, b.artifacts_json);
    if (a.search_json) |a_search| {
        try std.testing.expect(b.search_json != null);
        try std.testing.expectEqualSlices(u8, a_search, b.search_json.?);
    } else {
        try std.testing.expect(b.search_json == null);
    }
}

fn expectSameJobsIdentical(
    io: Io,
    allocator: std.mem.Allocator,
    a: JobEvidence,
    b: JobEvidence,
) !void {
    try std.testing.expectEqual(@as(usize, a.jobs), b.jobs);
    // Repeated runs with the same requested jobs must be fully byte-identical,
    // including the recorded worker value.
    try std.testing.expectEqualSlices(u8, a.run_json, b.run_json);
    var out_a = try Io.Dir.openDirAbsolute(io, a.output_abs, .{ .iterate = true });
    defer out_a.close(io);
    var out_b = try Io.Dir.openDirAbsolute(io, b.output_abs, .{ .iterate = true });
    defer out_b.close(io);
    try std.testing.expect(try treesByteEqual(io, allocator, out_a, out_b));
    try std.testing.expectEqualSlices(u8, a.checks_json, b.checks_json);
    try std.testing.expectEqualSlices(u8, a.snapshot_jsonl, b.snapshot_jsonl);
}

fn generateJobsFixture(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_rel: []const u8,
    profile: []const u8,
    pages: usize,
) !void {
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_rel,
        .pages = pages,
        .seed = 20260801,
        .profile_selector = profile,
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
}

test "mild-poison-v1 publication bytes are identical across requested jobs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/jobs-mild", .{tmp.sub_path});
    defer allocator.free(fixture_rel);

    var runs: [3]JobEvidence = undefined;
    const jobs_values = [_]usize{ 1, 4, 8 };
    for (jobs_values, 0..) |jobs, index| {
        const run_fixture = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ fixture_rel, jobs });
        defer allocator.free(run_fixture);
        try generateJobsFixture(io, allocator, run_fixture, "mild-poison-v1", 24);
        runs[index] = try captureJobsRun(io, allocator, run_fixture, jobs);
    }
    defer for (&runs) |*run| run.deinit(allocator);

    for (0..runs.len) |i| {
        for (i + 1..runs.len) |j| {
            try expectCrossJobsDeterministic(io, allocator, runs[i], runs[j]);
        }
    }

    // All eight mild-poison barbs retain the same targets and expected findings
    // across jobs: the applied mutations list is recorded identically.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, runs[0].run_json, .{});
    defer parsed.deinit();
    const applied = switch (parsed.value.object.get("appliedPostPublishMutations") orelse return error.InvalidRunEvidence) {
        .array => |array| array.items,
        else => return error.InvalidRunEvidence,
    };
    try std.testing.expectEqual(@as(usize, 8), applied.len);
    for (applied) |mutation| {
        const object = switch (mutation) {
            .object => |value| value,
            else => return error.InvalidRunEvidence,
        };
        const name = switch (object.get("name") orelse return error.InvalidRunEvidence) {
            .string => |value| value,
            else => return error.InvalidRunEvidence,
        };
        try std.testing.expect(mutationIsMildPoison(name));
    }
}

fn mutationIsMildPoison(name: []const u8) bool {
    const mild = [_][]const u8{
        "html_missing_local_route",
        "html_missing_fragment",
        "html_duplicate_id",
        "html_unclosed_structure",
        "artifact_missing",
        "artifact_digest_mismatch",
        "search_stale_title",
        "deployment_owned_extra",
    };
    for (mild) |m| if (std.mem.eql(u8, m, name)) return true;
    return false;
}

test "preserved-edge-v1 publication bytes are identical across requested jobs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/jobs-preserved", .{tmp.sub_path});
    defer allocator.free(fixture_rel);

    var runs: [2]JobEvidence = undefined;
    const jobs_values = [_]usize{ 1, 4 };
    for (jobs_values, 0..) |jobs, index| {
        const run_fixture = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ fixture_rel, jobs });
        defer allocator.free(run_fixture);
        try generateJobsFixture(io, allocator, run_fixture, "preserved-edge-v1", 24);
        runs[index] = try captureJobsRun(io, allocator, run_fixture, jobs);
    }
    defer for (&runs) |*run| run.deinit(allocator);
    try expectCrossJobsDeterministic(io, allocator, runs[0], runs[1]);
}

test "clean ideal-site publication bytes are identical across requested jobs including above page count" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/jobs-clean", .{tmp.sub_path});
    defer allocator.free(fixture_rel);

    // A requested count greater than the 24-page fixture (64) must not change
    // publication bytes; the value is only the requested upper bound.
    var runs: [3]JobEvidence = undefined;
    const jobs_values = [_]usize{ 1, 4, 64 };
    for (jobs_values, 0..) |jobs, index| {
        const run_fixture = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ fixture_rel, jobs });
        defer allocator.free(run_fixture);
        try generateJobsFixture(io, allocator, run_fixture, "readme-realistic-v1", 24);
        runs[index] = try captureJobsRun(io, allocator, run_fixture, jobs);
    }
    defer for (&runs) |*run| run.deinit(allocator);

    for (0..runs.len) |i| {
        for (i + 1..runs.len) |j| {
            try expectCrossJobsDeterministic(io, allocator, runs[i], runs[j]);
        }
    }
}

test "republish-clean evidence is identical across requested jobs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/jobs-republish", .{tmp.sub_path});
    defer allocator.free(fixture_rel);

    var runs: [2]JobEvidence = undefined;
    const jobs_values = [_]usize{ 1, 4 };
    for (jobs_values, 0..) |jobs, index| {
        const run_fixture = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ fixture_rel, jobs });
        defer allocator.free(run_fixture);
        try generateJobsFixture(io, allocator, run_fixture, "readme-realistic-v1", 24);
        try generator.republishCleanFixture(.{
            .io = io,
            .allocator = allocator,
            .fixture_path = run_fixture,
            .boris_path = "./zig-out/bin/boris",
            .jobs = jobs,
        });
        const fixture_abs = try fixtureAbsolute(io, allocator, run_fixture);
        defer allocator.free(fixture_abs);
        const clean_abs = try std.fs.path.join(allocator, &.{ fixture_abs, "results/republish-clean-output" });
        defer allocator.free(clean_abs);
        var fixture = try Io.Dir.openDirAbsolute(io, fixture_abs, .{});
        defer fixture.close(io);
        const record = try readPayload(io, fixture, allocator, "results/republish-clean.json");
        var clean = try Io.Dir.openDirAbsolute(io, clean_abs, .{ .iterate = true });
        defer clean.close(io);
        try publication_checks.writeAfterCommit(io, allocator, clean, "default", .{});
        const clean_checks = try readPayload(io, clean, allocator, publication_checks.output_path);
        const snapshot = try readPayload(io, clean, allocator, "index.html");
        runs[index] = .{
            .run_json = record,
            .checks_json = clean_checks,
            .snapshot_jsonl = try allocator.dupe(u8, ""),
            .index_html = snapshot,
            .search_json = null,
            .artifacts_json = try allocator.dupe(u8, ""),
            .output_abs = try allocator.dupe(u8, clean_abs),
            .jobs = jobs,
        };
    }
    defer for (&runs) |*run| run.deinit(allocator);
    try expectCrossJobsDeterministic(io, allocator, runs[0], runs[1]);
}

test "repeated runs with the same requested jobs are byte-identical" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/jobs-repeat", .{tmp.sub_path});
    defer allocator.free(fixture_rel);

    var runs: [2]JobEvidence = undefined;
    const jobs_values = [_]usize{ 4, 4 };
    for (jobs_values, 0..) |jobs, index| {
        const run_fixture = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ fixture_rel, index });
        defer allocator.free(run_fixture);
        try generateJobsFixture(io, allocator, run_fixture, "mild-poison-v1", 24);
        runs[index] = try captureJobsRun(io, allocator, run_fixture, jobs);
    }
    defer for (&runs) |*run| run.deinit(allocator);
    try expectSameJobsIdentical(io, allocator, runs[0], runs[1]);
}
