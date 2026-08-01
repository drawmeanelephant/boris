//! Deterministic, target-local publication-check evidence.
//!
//! This module runs only after the HTML target and its authoritative artifact
//! inventory have committed. It reads that inventory as the sole ownership
//! declaration, rechecks the declared bytes without following symlinks, feeds
//! the exact HTML bytes into Doctor, and atomically publishes one report.

const std = @import("std");
const Io = std.Io;
const artifact_inventory = @import("artifact_inventory.zig");
const cache = @import("cache.zig");
const doctor = @import("doctor.zig");
const json_out = @import("json_out.zig");
const search_index = @import("search_index.zig");

pub const output_path = artifact_inventory.checks_output_path;
pub const report_format = "boris-publication-checks";
pub const schema_version: usize = 1;

pub const Status = enum {
    passed,
    failed,
    incomplete,
    not_applicable,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .passed => "passed",
            .failed => "failed",
            .incomplete => "incomplete",
            .not_applicable => "not-applicable",
        };
    }
};

pub const Coverage = enum {
    complete,
    incomplete,
    not_applicable,

    pub fn name(self: Coverage) []const u8 {
        return switch (self) {
            .complete => "complete",
            .incomplete => "incomplete",
            .not_applicable => "not-applicable",
        };
    }
};

pub const Scope = struct {
    subject_statuses: []const []const u8,
    subject_kinds: []const []const u8,
    subject_sha256: [64]u8,
    supporting_statuses: []const []const u8,
    supporting_kinds: []const []const u8,
    supporting_sha256: [64]u8,
};

pub const Counts = struct {
    eligible: usize,
    checked: usize,
    findings: usize,
};

pub const Check = struct {
    id: []const u8,
    eligible: bool,
    ran: bool,
    status: Status,
    coverage: Coverage,
    scope: Scope,
    counts: Counts,
    finding_offset: usize,
};

pub const Options = struct {
    /// Test-only fault injection. Production callers leave both false.
    test_fail_execution: bool = false,
    test_fail_write: bool = false,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidInventory,
    CheckerExecutionFailed,
    ChecksWriteFailed,
    UnsafeArtifactPath,
    MultipleRenderedSearchArtifacts,
};

const committed_statuses = [_][]const u8{"committed"};
const html_page_kinds = [_][]const u8{"html-page"};
const rendered_search_kinds = [_][]const u8{"rendered-search"};
const no_kinds = [_][]const u8{};
const no_statuses = [_][]const u8{};

fn emptyDigest() [64]u8 {
    return cache.hexDigest(cache.hashBytes(""));
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn selected(
    record: artifact_inventory.Record,
    statuses: []const []const u8,
    kinds: []const []const u8,
) bool {
    return (statuses.len == 0 or containsString(statuses, record.status.name())) and
        (kinds.len == 0 or containsString(kinds, record.kind.name()));
}

fn scopeDigest(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    statuses: []const []const u8,
    kinds: []const []const u8,
) ![64]u8 {
    var material: std.ArrayList(u8) = .empty;
    defer material.deinit(gpa);

    for (inventory.records) |record| {
        if (!selected(record, statuses, kinds)) continue;
        try material.appendSlice(gpa, record.path);
        try material.append(gpa, 0);
        try material.appendSlice(gpa, record.kind.name());
        try material.append(gpa, 0);
        var bytes_buffer: [32]u8 = undefined;
        const bytes_text = std.fmt.bufPrint(&bytes_buffer, "{d}", .{record.bytes}) catch unreachable;
        try material.appendSlice(gpa, bytes_text);
        try material.append(gpa, 0);
        try material.appendSlice(gpa, &record.sha256);
        try material.append(gpa, '\n');
    }
    return cache.hexDigest(cache.hashBytes(material.items));
}

fn readFileNoFollow(
    io: Io,
    root: Io.Dir,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (!artifact_inventory.validateRelativePath(path)) return error.UnsafeArtifactPath;

    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
    var current_dir = root;
    var owned_dir: ?Io.Dir = null;
    defer if (owned_dir) |dir| dir.close(io);

    if (last_slash) |last| {
        var segments = std.mem.splitScalar(u8, path[0..last], '/');
        while (segments.next()) |segment| {
            const stat = try current_dir.statFile(io, segment, .{ .follow_symlinks = false });
            if (stat.kind == .sym_link) return error.UnsafeArtifactPath;
            if (stat.kind != .directory) return error.UnsafeArtifactPath;
            const next_dir = try current_dir.openDir(io, segment, .{ .follow_symlinks = false });
            if (owned_dir) |dir| dir.close(io);
            owned_dir = next_dir;
            current_dir = next_dir;
        }
    }

    const basename = if (last_slash) |last| path[last + 1 ..] else path;
    const stat = try current_dir.statFile(io, basename, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link or stat.kind != .file) return error.UnsafeArtifactPath;
    var file = try current_dir.openFile(io, basename, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .unlimited);
}

fn appendArtifactFinding(
    findings: *std.ArrayList(doctor.Finding),
    gpa: std.mem.Allocator,
    code: doctor.Code,
    target: []const u8,
    record: artifact_inventory.Record,
    observed: []const u8,
    expected: []const u8,
) !void {
    try doctor.appendFinding(findings, gpa, .{
        .code = code,
        .owner = .publication,
        .subject_kind = "artifact",
        .subject_id = record.path,
        .target = target,
        .output_location = .{ .path = record.path, .line = 1, .column = 1 },
        .observed = observed,
        .expected = expected,
        .fixability = .regenerate,
    });
}

fn isSearchCode(code: doctor.Code) bool {
    return switch (code) {
        .SEARCH_MISSING,
        .SEARCH_MALFORMED,
        .SEARCH_DOCUMENT_MISSING,
        .SEARCH_DOCUMENT_STALE,
        .SEARCH_CONTENT_MISMATCH,
        => true,
        else => false,
    };
}

fn hasFailingFinding(findings: []const doctor.Finding) bool {
    for (findings) |finding| {
        if (finding.severity == .warning or finding.severity == .@"error") return true;
    }
    return false;
}

fn completedStatus(coverage: Coverage, findings: []const doctor.Finding) Status {
    if (coverage == .incomplete) return .incomplete;
    return if (hasFailingFinding(findings)) .failed else .passed;
}

fn appendFilteredFindings(
    destination: *std.ArrayList(doctor.Finding),
    gpa: std.mem.Allocator,
    source: []const doctor.Finding,
    want_search: bool,
) !usize {
    const before = destination.items.len;
    for (source) |finding| {
        if (isSearchCode(finding.code) == want_search) {
            try destination.append(gpa, finding);
        }
    }
    return destination.items.len - before;
}

fn writeStringArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    values: []const []const u8,
) !void {
    try out.append(gpa, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try out.append(gpa, ',');
        try json_out.writeString(out, gpa, value);
    }
    try out.append(gpa, ']');
}

fn writeScope(out: *std.ArrayList(u8), gpa: std.mem.Allocator, scope: Scope) !void {
    try out.appendSlice(gpa, "{\n        \"subject_statuses\": ");
    try writeStringArray(out, gpa, scope.subject_statuses);
    try out.appendSlice(gpa, ",\n        \"subject_kinds\": ");
    try writeStringArray(out, gpa, scope.subject_kinds);
    try out.appendSlice(gpa, ",\n        \"subject_sha256\": ");
    try json_out.writeString(out, gpa, &scope.subject_sha256);
    try out.appendSlice(gpa, ",\n        \"supporting_statuses\": ");
    try writeStringArray(out, gpa, scope.supporting_statuses);
    try out.appendSlice(gpa, ",\n        \"supporting_kinds\": ");
    try writeStringArray(out, gpa, scope.supporting_kinds);
    try out.appendSlice(gpa, ",\n        \"supporting_sha256\": ");
    try json_out.writeString(out, gpa, &scope.supporting_sha256);
    try out.appendSlice(gpa, "\n      }");
}

fn writeCheck(out: *std.ArrayList(u8), gpa: std.mem.Allocator, check: Check) !void {
    try out.appendSlice(gpa, "    {\n      \"id\": ");
    try json_out.writeString(out, gpa, check.id);
    try out.appendSlice(gpa, ",\n      \"eligible\": ");
    try json_out.writeBool(out, gpa, check.eligible);
    try out.appendSlice(gpa, ",\n      \"ran\": ");
    try json_out.writeBool(out, gpa, check.ran);
    try out.appendSlice(gpa, ",\n      \"status\": ");
    try json_out.writeString(out, gpa, check.status.name());
    try out.appendSlice(gpa, ",\n      \"coverage\": ");
    try json_out.writeString(out, gpa, check.coverage.name());
    try out.appendSlice(gpa, ",\n      \"scope\": ");
    try writeScope(out, gpa, check.scope);
    try out.appendSlice(gpa, ",\n      \"counts\": {\"eligible\": ");
    try json_out.writeUsize(out, gpa, check.counts.eligible);
    try out.appendSlice(gpa, ", \"checked\": ");
    try json_out.writeUsize(out, gpa, check.counts.checked);
    try out.appendSlice(gpa, ", \"findings\": ");
    try json_out.writeUsize(out, gpa, check.counts.findings);
    try out.appendSlice(gpa, "},\n      \"finding_offset\": ");
    try json_out.writeUsize(out, gpa, check.finding_offset);
    try out.appendSlice(gpa, "\n    }");
}

fn writeReport(
    gpa: std.mem.Allocator,
    target: []const u8,
    inventory_bytes: []const u8,
    inventory: *const artifact_inventory.Inventory,
    checks: []const Check,
    findings: []const doctor.Finding,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const inventory_digest = cache.hexDigest(cache.hashBytes(inventory_bytes));

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, report_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"target\": ");
    try json_out.writeString(&out, gpa, target);
    try out.appendSlice(gpa, ",\n  \"artifact_inventory\": {\n    \"path\": ");
    try json_out.writeString(&out, gpa, artifact_inventory.output_path);
    try out.appendSlice(gpa, ",\n    \"bytes\": ");
    try json_out.writeUsize(&out, gpa, inventory_bytes.len);
    try out.appendSlice(gpa, ",\n    \"sha256\": ");
    try json_out.writeString(&out, gpa, &inventory_digest);
    try out.appendSlice(gpa, ",\n    \"format\": ");
    try json_out.writeString(&out, gpa, artifact_inventory.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, artifact_inventory.schema_version);
    try out.appendSlice(gpa, ",\n    \"target\": ");
    try json_out.writeString(&out, gpa, inventory.target);
    try out.appendSlice(gpa, ",\n    \"artifact_count\": ");
    try json_out.writeUsize(&out, gpa, inventory.records.len);
    try out.appendSlice(gpa, "\n  },\n  \"checks\": [\n");
    for (checks, 0..) |check, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        try writeCheck(&out, gpa, check);
    }
    try out.appendSlice(gpa, "\n  ],\n  \"findings\": [");
    for (findings, 0..) |finding, index| {
        if (index == 0) try out.append(gpa, '\n');
        if (index > 0) try out.appendSlice(gpa, ",\n");
        try out.appendSlice(gpa, "    ");
        try doctor.writeFindingJson(&out, gpa, finding);
    }
    if (findings.len > 0) try out.append(gpa, '\n');
    try out.appendSlice(gpa, "  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn buildReport(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    inventory_bytes: []const u8,
) Error![]u8 {
    var inventory = artifact_inventory.parse(gpa, inventory_bytes, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInventory,
    };
    defer inventory.deinit();

    var findings: std.ArrayList(doctor.Finding) = .empty;
    defer findings.deinit(gpa);

    const payloads = try gpa.alloc(?[]u8, inventory.records.len);
    defer {
        for (payloads) |payload| if (payload) |bytes| gpa.free(bytes);
        gpa.free(payloads);
    }
    @memset(payloads, null);

    var committed_count: usize = 0;
    var checked_count: usize = 0;
    var missing_count: usize = 0;
    const integrity_offset = findings.items.len;
    for (inventory.records, 0..) |record, index| {
        if (record.status != .committed) continue;
        committed_count += 1;
        const bytes = readFileNoFollow(io, root, gpa, record.path) catch |err| switch (err) {
            error.FileNotFound => {
                missing_count += 1;
                try appendArtifactFinding(
                    &findings,
                    gpa,
                    .ARTIFACT_MISSING,
                    target,
                    record,
                    "committed artifact file is missing",
                    "a regular file beneath the target root",
                );
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CheckerExecutionFailed,
        };
        payloads[index] = bytes;
        checked_count += 1;

        if (bytes.len != record.bytes) {
            var observed_buffer: [64]u8 = undefined;
            var expected_buffer: [64]u8 = undefined;
            const observed = std.fmt.bufPrint(&observed_buffer, "{d} bytes", .{bytes.len}) catch unreachable;
            const expected = std.fmt.bufPrint(&expected_buffer, "{d} bytes", .{record.bytes}) catch unreachable;
            try appendArtifactFinding(
                &findings,
                gpa,
                .ARTIFACT_SIZE_MISMATCH,
                target,
                record,
                observed,
                expected,
            );
        }

        const actual_digest = cache.hexDigest(cache.hashBytes(bytes));
        if (!std.mem.eql(u8, &actual_digest, &record.sha256)) {
            try appendArtifactFinding(
                &findings,
                gpa,
                .ARTIFACT_DIGEST_MISMATCH,
                target,
                record,
                &actual_digest,
                &record.sha256,
            );
        }
    }
    const integrity_findings = findings.items.len - integrity_offset;
    const integrity_scope = Scope{
        .subject_statuses = &committed_statuses,
        .subject_kinds = &no_kinds,
        .subject_sha256 = try scopeDigest(gpa, &inventory, &committed_statuses, &no_kinds),
        .supporting_statuses = &no_statuses,
        .supporting_kinds = &no_kinds,
        .supporting_sha256 = emptyDigest(),
    };
    const integrity_coverage: Coverage = if (missing_count > 0) .incomplete else .complete;
    const integrity_check = Check{
        .id = "artifact-integrity",
        .eligible = true,
        .ran = true,
        .status = if (integrity_coverage == .incomplete)
            .incomplete
        else if (integrity_findings > 0)
            .failed
        else
            .passed,
        .coverage = integrity_coverage,
        .scope = integrity_scope,
        .counts = .{ .eligible = committed_count, .checked = checked_count, .findings = integrity_findings },
        .finding_offset = integrity_offset,
    };

    var page_paths: std.ArrayList([]const u8) = .empty;
    defer page_paths.deinit(gpa);
    var route_paths: std.ArrayList([]const u8) = .empty;
    defer route_paths.deinit(gpa);
    var pages: std.ArrayList(doctor.PageInput) = .empty;
    defer pages.deinit(gpa);
    var search_record_index: ?usize = null;
    for (inventory.records, 0..) |record, index| {
        if (record.status != .committed) continue;
        try route_paths.append(gpa, record.path);
        if (record.kind == .html_page) {
            try page_paths.append(gpa, record.path);
            if (payloads[index]) |bytes| try pages.append(gpa, .{ .path = record.path, .html = bytes });
        }
        if (record.kind == .rendered_search) {
            if (search_record_index != null) return error.MultipleRenderedSearchArtifacts;
            search_record_index = index;
        }
    }

    var search_input: doctor.SearchInput = .not_configured;
    if (search_record_index) |index| {
        search_input = if (payloads[index]) |bytes| .{ .selected = bytes } else .selected_missing;
    }

    var analysis = doctor.analyzeTarget(gpa, .{
        .target_name = target,
        .pages = pages.items,
        .expected_page_paths = page_paths.items,
        .intended_route_paths = route_paths.items,
        .search_page_paths = page_paths.items,
        .search = search_input,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    defer analysis.deinit();

    const html_offset = findings.items.len;
    const html_findings = try appendFilteredFindings(&findings, gpa, analysis.findings, false);
    const html_coverage: Coverage = switch (analysis.coverage[0].status) {
        .checked => .complete,
        .incomplete => .incomplete,
        .not_configured, .not_in_scope => .complete,
    };
    const html_scope = Scope{
        .subject_statuses = &committed_statuses,
        .subject_kinds = &html_page_kinds,
        .subject_sha256 = try scopeDigest(gpa, &inventory, &committed_statuses, &html_page_kinds),
        .supporting_statuses = &committed_statuses,
        .supporting_kinds = &no_kinds,
        .supporting_sha256 = try scopeDigest(gpa, &inventory, &committed_statuses, &no_kinds),
    };
    const html_check = Check{
        .id = "rendered-html",
        .eligible = true,
        .ran = true,
        .status = completedStatus(html_coverage, findings.items[html_offset..][0..html_findings]),
        .coverage = html_coverage,
        .scope = html_scope,
        .counts = .{ .eligible = page_paths.items.len, .checked = pages.items.len, .findings = html_findings },
        .finding_offset = html_offset,
    };

    const search_offset = findings.items.len;
    var search_check: Check = undefined;
    if (search_record_index == null) {
        search_check = .{
            .id = "rendered-search",
            .eligible = false,
            .ran = false,
            .status = .not_applicable,
            .coverage = .not_applicable,
            .scope = .{
                .subject_statuses = &committed_statuses,
                .subject_kinds = &rendered_search_kinds,
                .subject_sha256 = emptyDigest(),
                .supporting_statuses = &committed_statuses,
                .supporting_kinds = &html_page_kinds,
                .supporting_sha256 = try scopeDigest(gpa, &inventory, &committed_statuses, &html_page_kinds),
            },
            .counts = .{ .eligible = 0, .checked = 0, .findings = 0 },
            .finding_offset = search_offset,
        };
    } else {
        const search_findings = try appendFilteredFindings(&findings, gpa, analysis.findings, true);
        const search_coverage: Coverage = switch (analysis.coverage[1].status) {
            .checked => .complete,
            .incomplete => .incomplete,
            .not_configured, .not_in_scope => .incomplete,
        };
        search_check = .{
            .id = "rendered-search",
            .eligible = true,
            .ran = true,
            .status = completedStatus(search_coverage, findings.items[search_offset..][0..search_findings]),
            .coverage = search_coverage,
            .scope = .{
                .subject_statuses = &committed_statuses,
                .subject_kinds = &rendered_search_kinds,
                .subject_sha256 = try scopeDigest(gpa, &inventory, &committed_statuses, &rendered_search_kinds),
                .supporting_statuses = &committed_statuses,
                .supporting_kinds = &html_page_kinds,
                .supporting_sha256 = try scopeDigest(gpa, &inventory, &committed_statuses, &html_page_kinds),
            },
            .counts = .{ .eligible = 1, .checked = if (payloads[search_record_index.?] != null) 1 else 0, .findings = search_findings },
            .finding_offset = search_offset,
        };
    }

    const checks = [_]Check{ integrity_check, html_check, search_check };
    return writeReport(gpa, target, inventory_bytes, &inventory, &checks, findings.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
}

/// Read the committed inventory, run all selected checks, and atomically
/// replace the target-local report. Any error before `replace` preserves an
/// existing report.
pub fn writeAfterCommit(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    options: Options,
) Error!void {
    if (options.test_fail_execution) return error.CheckerExecutionFailed;
    var report_arena = std.heap.ArenaAllocator.init(gpa);
    defer report_arena.deinit();
    const report_gpa = report_arena.allocator();

    const inventory_bytes = readFileNoFollow(io, root, report_gpa, artifact_inventory.output_path) catch {
        return error.InvalidInventory;
    };

    const report = try buildReport(io, report_gpa, root, target, inventory_bytes);
    if (options.test_fail_write) return error.ChecksWriteFailed;

    var atomic = root.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true }) catch {
        return error.ChecksWriteFailed;
    };
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(report) catch return error.ChecksWriteFailed;
    writer.interface.flush() catch return error.ChecksWriteFailed;
    atomic.replace(io) catch return error.ChecksWriteFailed;
}

test "scope digests use canonical records and distinguish the empty set" {
    const gpa = std.testing.allocator;
    const digest = cache.hexDigest(cache.hashBytes("page"));
    var inventory = artifact_inventory.Inventory{
        .gpa = gpa,
        .target = "public",
        .records = try gpa.dupe(artifact_inventory.Record, &.{
            .{
                .path = "index.html",
                .kind = .html_page,
                .producer = "html-render",
                .required = true,
                .status = .committed,
                .bytes = 4,
                .sha256 = digest,
                .format_version = null,
            },
        }),
    };
    defer inventory.deinit();
    const selected_digest = try scopeDigest(gpa, &inventory, &committed_statuses, &html_page_kinds);
    const empty_digest = try scopeDigest(gpa, &inventory, &committed_statuses, &rendered_search_kinds);
    try std.testing.expectEqualStrings(
        "26828f9ac134ae3c542737bf374ef4a62068961f348eba9bc5d3ca582c37d791",
        &selected_digest,
    );
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &empty_digest,
    );
}

test "inventory parser rejects malformed, unsafe, duplicate, and reserved records" {
    const gpa = std.testing.allocator;
    const record =
        "{\"path\":\"index.html\",\"kind\":\"html-page\",\"producer\":\"html-render\",\"required\":true,\"status\":\"committed\",\"bytes\":0,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"format_version\":null}";
    const prefix = "{\"format\":\"boris-publication-artifacts\",\"schema_version\":1,\"target\":\"public\",\"artifacts\":[";
    const suffix = "]}";

    try std.testing.expectError(error.InvalidInventory, artifact_inventory.parse(gpa, "{", "public"));

    const unsafe = prefix ++ "{\"path\":\"../index.html\",\"kind\":\"html-page\",\"producer\":\"html-render\",\"required\":true,\"status\":\"committed\",\"bytes\":0,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"format_version\":null}" ++ suffix;
    try std.testing.expectError(error.InvalidInventoryPath, artifact_inventory.parse(gpa, unsafe, "public"));

    const reserved = prefix ++ "{\"path\":\"_boris/proof/checks.json\",\"kind\":\"sitemap\",\"producer\":\"sitemap\",\"required\":true,\"status\":\"committed\",\"bytes\":0,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"format_version\":null}" ++ suffix;
    try std.testing.expectError(error.InvalidInventoryPath, artifact_inventory.parse(gpa, reserved, "public"));

    const duplicate = prefix ++ record ++ "," ++ record ++ suffix;
    try std.testing.expectError(error.DuplicateInventoryPath, artifact_inventory.parse(gpa, duplicate, "public"));
}

test "inventory parser rejects unsupported versions and target drift" {
    const gpa = std.testing.allocator;
    const unsupported = "{\"format\":\"boris-publication-artifacts\",\"schema_version\":2,\"target\":\"public\",\"artifacts\":[]}";
    try std.testing.expectError(error.UnsupportedInventoryVersion, artifact_inventory.parse(gpa, unsupported, "public"));

    const mismatch = "{\"format\":\"boris-publication-artifacts\",\"schema_version\":1,\"target\":\"private\",\"artifacts\":[]}";
    try std.testing.expectError(error.InventoryTargetMismatch, artifact_inventory.parse(gpa, mismatch, "public"));
}

fn writePayload(io: Io, root: Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try root.createDirPath(io, parent);
    try root.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn readPayload(io: Io, root: Io.Dir, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .unlimited);
}

fn recordFor(
    path: []const u8,
    kind: artifact_inventory.Kind,
    bytes: []const u8,
) artifact_inventory.Record {
    return .{
        .path = path,
        .kind = kind,
        .producer = kind.producerName(),
        .required = true,
        .status = .committed,
        .bytes = bytes.len,
        .sha256 = cache.hexDigest(cache.hashBytes(bytes)),
        .format_version = if (kind == .rendered_search) "1" else null,
    };
}

fn writeInventory(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    records: []const artifact_inventory.Record,
) ![]u8 {
    const ordered = try gpa.dupe(artifact_inventory.Record, records);
    defer gpa.free(ordered);
    std.mem.sort(artifact_inventory.Record, ordered, {}, artifact_inventory.recordLess);
    var inventory = artifact_inventory.Inventory{
        .gpa = gpa,
        .target = target,
        .records = ordered,
    };
    const bytes = try artifact_inventory.render(gpa, &inventory);
    try writePayload(io, root, artifact_inventory.output_path, bytes);
    gpa.free(bytes);
    return try readPayload(io, root, gpa, artifact_inventory.output_path);
}

fn freeSearchDocument(gpa: std.mem.Allocator, document: search_index.Document) void {
    gpa.free(document.path);
    gpa.free(document.title);
    for (document.sections) |section| {
        gpa.free(section.heading);
        gpa.free(section.fragment);
        gpa.free(section.text);
        gpa.free(section.code);
    }
    gpa.free(document.sections);
}

fn makeSearch(
    gpa: std.mem.Allocator,
    pages: []const doctor.PageInput,
) ![]u8 {
    const documents = try gpa.alloc(search_index.Document, pages.len);
    var filled: usize = 0;
    defer {
        for (documents[0..filled]) |document| freeSearchDocument(gpa, document);
        gpa.free(documents);
    }
    for (pages, 0..) |page, index| {
        documents[index] = try search_index.indexHtml(gpa, page.path, page.html, false);
        filled = index + 1;
    }
    return search_index.writeJson(gpa, documents);
}

fn objectAt(value: std.json.Value, key: []const u8) std.json.Value {
    return value.object.get(key).?;
}

test "clean checks publish all three executions deterministically" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const index_html = "<main data-boris-search-root><h1 id=home>Home</h1><p>Hello.</p></main>";
    const guide_html = "<main data-boris-search-root><h1 id=guide>Guide</h1><a href=index.html#home>Home</a></main>";
    const pages = [_]doctor.PageInput{
        .{ .path = "guide.html", .html = guide_html },
        .{ .path = "index.html", .html = index_html },
    };
    const search_bytes = try makeSearch(gpa, &pages);
    defer gpa.free(search_bytes);

    try writePayload(io, tmp.dir, "guide.html", guide_html);
    try writePayload(io, tmp.dir, "index.html", index_html);
    try writePayload(io, tmp.dir, search_index.output_path, search_bytes);
    const records = [_]artifact_inventory.Record{
        recordFor("guide.html", .html_page, guide_html),
        recordFor("index.html", .html_page, index_html),
        recordFor(search_index.output_path, .rendered_search, search_bytes),
    };
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
    defer gpa.free(inventory_bytes);

    try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
    const first = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(first);
    try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
    const second = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, first, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("public", root.get("target").?.string);
    const binding = root.get("artifact_inventory").?.object;
    try std.testing.expectEqualStrings(artifact_inventory.output_path, binding.get("path").?.string);
    const binding_digest = cache.hexDigest(cache.hashBytes(inventory_bytes));
    try std.testing.expectEqualStrings(&binding_digest, binding.get("sha256").?.string);

    const checks = root.get("checks").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), checks.len);
    try std.testing.expectEqualStrings("artifact-integrity", objectAt(checks[0], "id").string);
    try std.testing.expectEqualStrings("rendered-html", objectAt(checks[1], "id").string);
    try std.testing.expectEqualStrings("rendered-search", objectAt(checks[2], "id").string);
    for (checks) |check| {
        try std.testing.expectEqualStrings("passed", objectAt(check, "status").string);
        try std.testing.expectEqualStrings("complete", objectAt(check, "coverage").string);
    }
    try std.testing.expectEqual(@as(usize, 0), root.get("findings").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), objectAt(checks[0], "finding_offset").integer);
    try std.testing.expectEqual(@as(i64, 0), objectAt(checks[1], "finding_offset").integer);
    try std.testing.expectEqual(@as(i64, 0), objectAt(checks[2], "finding_offset").integer);
}

fn reportHasCode(root: std.json.ObjectMap, code: []const u8) bool {
    for (root.get("findings").?.array.items) |finding| {
        if (std.mem.eql(u8, objectAt(finding, "code").string, code)) return true;
    }
    return false;
}

fn reportHasSubject(root: std.json.ObjectMap, id: []const u8) bool {
    for (root.get("findings").?.array.items) |finding| {
        if (std.mem.eql(u8, objectAt(objectAt(finding, "subject"), "id").string, id)) return true;
    }
    return false;
}

test "artifact integrity distinguishes missing, size, and same-size digest failures" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original_html = "<main data-boris-search-root><h1>Home</h1></main>";
    const changed_html = "<main data-boris-search-root><h1>Hone</h1></main>";
    try writePayload(io, tmp.dir, "index.html", changed_html);
    try writePayload(io, tmp.dir, "assets/site.css", "new bytes");
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, original_html),
        recordFor("assets/site.css", .theme_asset, "old"),
        recordFor("missing.html", .html_page, "missing"),
    };
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
    defer gpa.free(inventory_bytes);

    try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
    const report = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const checks = root.get("checks").?.array.items;
    try std.testing.expectEqualStrings("incomplete", objectAt(checks[0], "status").string);
    try std.testing.expectEqualStrings("incomplete", objectAt(checks[0], "coverage").string);
    try std.testing.expectEqualStrings("incomplete", objectAt(checks[1], "status").string);
    try std.testing.expectEqualStrings("incomplete", objectAt(checks[1], "coverage").string);
    try std.testing.expect(reportHasCode(root, "ARTIFACT_MISSING"));
    try std.testing.expect(reportHasCode(root, "ARTIFACT_SIZE_MISMATCH"));
    try std.testing.expect(reportHasCode(root, "ARTIFACT_DIGEST_MISMATCH"));
    try std.testing.expect(reportHasCode(root, "HTML_PAGE_MISSING"));
}

test "rendered HTML uses only inventory ownership and reuses Doctor findings" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const html =
        "<main data-boris-search-root>" ++
        "<h1 id=home>Home</h1><div id=dup></div><span id=dup></span>" ++
        "<a href=missing.html>missing</a><a href=#gone>fragment</a>" ++
        "<a href=../escape.html>escape</a><a href=bad%2>bad</a>" ++
        "</main>";
    const extra = "<main><a href=missing-from-extra.html>deployment</a></main>";
    try writePayload(io, tmp.dir, "index.html", html);
    try writePayload(io, tmp.dir, "deployment.html", extra);
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, html)};
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
    defer gpa.free(inventory_bytes);

    try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
    const report = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const checks = root.get("checks").?.array.items;
    try std.testing.expectEqualStrings("failed", objectAt(checks[1], "status").string);
    try std.testing.expectEqualStrings("complete", objectAt(checks[1], "coverage").string);
    try std.testing.expect(reportHasCode(root, "HTML_LOCAL_ROUTE_MISSING"));
    try std.testing.expect(reportHasCode(root, "HTML_LOCAL_ROUTE_ESCAPE"));
    try std.testing.expect(reportHasCode(root, "HTML_URL_MALFORMED"));
    try std.testing.expect(reportHasCode(root, "HTML_FRAGMENT_MISSING"));
    try std.testing.expect(reportHasCode(root, "HTML_DUPLICATE_ID"));
    try std.testing.expect(!reportHasSubject(root, "deployment"));
    try std.testing.expectEqualStrings("not-applicable", objectAt(checks[2], "status").string);
    try std.testing.expectEqualStrings("not-applicable", objectAt(checks[2], "coverage").string);
}

test "malformed HTML makes rendered coverage incomplete" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const malformed = "<main";
    try writePayload(io, tmp.dir, "index.html", malformed);
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, malformed)};
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
    defer gpa.free(inventory_bytes);

    try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
    const report = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed.deinit();
    const checks = parsed.value.object.get("checks").?.array.items;
    try std.testing.expectEqualStrings("incomplete", objectAt(checks[1], "status").string);
    try std.testing.expectEqualStrings("incomplete", objectAt(checks[1], "coverage").string);
    try std.testing.expect(reportHasCode(parsed.value.object, "HTML_MALFORMED"));
}

test "rendered search selection reports missing, malformed, and stale inputs" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const html = "<main data-boris-search-root><h1 id=home>Home</h1></main>";
    const pages = [_]doctor.PageInput{.{ .path = "index.html", .html = html }};

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writePayload(io, tmp.dir, "index.html", html);
        const expected_search = "{\"format\":\"boris-rendered-search-index\"}";
        const records = [_]artifact_inventory.Record{
            recordFor("index.html", .html_page, html),
            recordFor(search_index.output_path, .rendered_search, expected_search),
        };
        const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
        defer gpa.free(inventory_bytes);
        try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
        const report = try readPayload(io, tmp.dir, gpa, output_path);
        defer gpa.free(report);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const checks = root.get("checks").?.array.items;
        try std.testing.expectEqualStrings("incomplete", objectAt(checks[2], "status").string);
        try std.testing.expectEqualStrings("incomplete", objectAt(checks[2], "coverage").string);
        try std.testing.expect(reportHasCode(root, "SEARCH_MISSING"));
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const malformed = "not-json";
        try writePayload(io, tmp.dir, "index.html", html);
        try writePayload(io, tmp.dir, search_index.output_path, malformed);
        const records = [_]artifact_inventory.Record{
            recordFor("index.html", .html_page, html),
            recordFor(search_index.output_path, .rendered_search, malformed),
        };
        const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
        defer gpa.free(inventory_bytes);
        try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
        const report = try readPayload(io, tmp.dir, gpa, output_path);
        defer gpa.free(report);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const checks = root.get("checks").?.array.items;
        try std.testing.expectEqualStrings("passed", objectAt(checks[0], "status").string);
        try std.testing.expectEqualStrings("incomplete", objectAt(checks[2], "status").string);
        try std.testing.expect(reportHasCode(root, "SEARCH_MALFORMED"));
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const stale =
            "{\n  \"format\": \"boris-rendered-search-index\",\n  \"schema_version\": 1,\n" ++
            "  \"documents\": [{\"path\":\"index.html\",\"title\":\"Wrong\",\"sections\":[]}]\n}\n";
        try writePayload(io, tmp.dir, "index.html", html);
        try writePayload(io, tmp.dir, search_index.output_path, stale);
        const records = [_]artifact_inventory.Record{
            recordFor("index.html", .html_page, html),
            recordFor(search_index.output_path, .rendered_search, stale),
        };
        const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
        defer gpa.free(inventory_bytes);
        try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
        const report = try readPayload(io, tmp.dir, gpa, output_path);
        defer gpa.free(report);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const checks = root.get("checks").?.array.items;
        try std.testing.expectEqualStrings("failed", objectAt(checks[2], "status").string);
        try std.testing.expectEqualStrings("complete", objectAt(checks[2], "coverage").string);
        try std.testing.expect(reportHasCode(root, "SEARCH_CONTENT_MISMATCH"));
    }

    _ = pages;
}

test "zero-page HTML target is eligible and a selected empty search can pass" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const empty_search = "{\n  \"format\": \"boris-rendered-search-index\",\n  \"schema_version\": 1,\n  \"documents\": [\n  ]\n}\n";
    try writePayload(io, tmp.dir, search_index.output_path, empty_search);
    const records = [_]artifact_inventory.Record{recordFor(search_index.output_path, .rendered_search, empty_search)};
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
    defer gpa.free(inventory_bytes);
    try writeAfterCommit(io, gpa, tmp.dir, "public", .{});
    const report = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed.deinit();
    const checks = parsed.value.object.get("checks").?.array.items;
    try std.testing.expectEqualStrings("passed", objectAt(checks[1], "status").string);
    try std.testing.expectEqual(@as(i64, 0), objectAt(objectAt(checks[1], "counts"), "eligible").integer);
    try std.testing.expectEqualStrings("passed", objectAt(checks[2], "status").string);
}

test "invalid inventory and atomic write failure preserve a prior report" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const prior = "prior-report\n";
    try writePayload(io, tmp.dir, artifact_inventory.output_path, "not-json");
    try writePayload(io, tmp.dir, output_path, prior);
    try std.testing.expectError(error.InvalidInventory, writeAfterCommit(io, gpa, tmp.dir, "public", .{}));
    const after_invalid = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(after_invalid);
    try std.testing.expectEqualStrings(prior, after_invalid);

    const html = "<main data-boris-search-root><h1>Home</h1></main>";
    try writePayload(io, tmp.dir, "index.html", html);
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, html)};
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", &records);
    defer gpa.free(inventory_bytes);
    try std.testing.expectError(
        error.ChecksWriteFailed,
        writeAfterCommit(io, gpa, tmp.dir, "public", .{ .test_fail_write = true }),
    );
    const after_write_failure = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(after_write_failure);
    try std.testing.expectEqualStrings(prior, after_write_failure);
    try std.testing.expectError(
        error.CheckerExecutionFailed,
        writeAfterCommit(io, gpa, tmp.dir, "public", .{ .test_fail_execution = true }),
    );
}
