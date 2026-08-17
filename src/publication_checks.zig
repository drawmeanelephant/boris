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
    UnexpectedDoctorFinding,
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
    if (statuses.len == 0 and kinds.len == 0) return false;
    return (statuses.len == 0 or containsString(statuses, record.status.name())) and
        (kinds.len == 0 or containsString(kinds, record.kind.name()));
}

/// Recompute the deterministic scope digest for the given selector pair over
/// the canonical inventory. This is the exact record encoding the checks
/// report commits: for every selected record in inventory order, update
/// `path`, NUL, kind name, NUL, decimal byte count, NUL, hex sha256, LF.
/// The touches layer reuses this narrow helper so recomputed digests can never
/// drift from what the checks contract recorded.
pub fn scopeDigest(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    statuses: []const []const u8,
    kinds: []const []const u8,
) ![64]u8 {
    _ = gpa;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (inventory.records) |record| {
        if (!selected(record, statuses, kinds)) continue;
        hasher.update(record.path);
        hasher.update(&[_]u8{0});
        hasher.update(record.kind.name());
        hasher.update(&[_]u8{0});
        var bytes_buffer: [32]u8 = undefined;
        const bytes_text = std.fmt.bufPrint(&bytes_buffer, "{d}", .{record.bytes}) catch unreachable;
        hasher.update(bytes_text);
        hasher.update(&[_]u8{0});
        hasher.update(&record.sha256);
        hasher.update("\n");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return cache.hexDigest(digest);
}

pub fn openFileNoFollow(
    io: Io,
    root: Io.Dir,
    path: []const u8,
) !Io.File {
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
    return current_dir.openFile(io, basename, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
}

const StreamedFile = struct {
    bytes: usize,
    sha256: [64]u8,
    payload: ?[]u8,
};

/// Stream a target-relative file with no-follow, resolve-beneath handles and
/// bounded memory, returning its exact byte count, lowercase SHA-256, and
/// optionally its complete payload. Shared by the checks and claims evidence
/// layers so both read evidence files through identical handles.
pub fn streamFileNoFollow(
    io: Io,
    root: Io.Dir,
    payload_gpa: std.mem.Allocator,
    path: []const u8,
    collect: bool,
) !StreamedFile {
    var file = try openFileNoFollow(io, root, path);
    defer file.close(io);

    var payload: std.ArrayList(u8) = .empty;
    defer if (collect) payload.deinit(payload_gpa);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var input_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: usize = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&input_buffer);
        if (count == 0) break;
        hasher.update(input_buffer[0..count]);
        bytes = std.math.add(usize, bytes, count) catch return error.FileTooBig;
        if (collect) try payload.appendSlice(payload_gpa, input_buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .bytes = bytes,
        .sha256 = cache.hexDigest(digest),
        .payload = if (collect) try payload.toOwnedSlice(payload_gpa) else null,
    };
}

fn parseInventoryFile(
    io: Io,
    root: Io.Dir,
    gpa: std.mem.Allocator,
    target: []const u8,
) Error!artifact_inventory.Inventory {
    var file = openFileNoFollow(io, root, artifact_inventory.output_path) catch return error.InvalidInventory;
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &reader_buffer);
    return artifact_inventory.parseStream(gpa, &file_reader.interface, target) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInventory,
    };
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

fn isHtmlCode(code: doctor.Code) bool {
    return switch (code) {
        .HTML_PAGE_MISSING,
        .HTML_MALFORMED,
        .HTML_URL_MALFORMED,
        .HTML_LOCAL_ROUTE_MISSING,
        .HTML_LOCAL_ROUTE_ESCAPE,
        .HTML_FRAGMENT_MISSING,
        .HTML_DUPLICATE_ID,
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
    family: enum { html, search },
) !usize {
    const before = destination.items.len;
    for (source) |finding| {
        const include = switch (family) {
            .html => isHtmlCode(finding.code),
            .search => isSearchCode(finding.code),
        };
        const known_other_family = switch (family) {
            .html => isSearchCode(finding.code),
            .search => isHtmlCode(finding.code),
        };
        if (include) {
            try destination.append(gpa, finding);
        } else if (!known_other_family) return error.UnexpectedDoctorFinding;
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

const InventoryBinding = struct {
    bytes: usize,
    sha256: [64]u8,
};

fn writeReport(
    gpa: std.mem.Allocator,
    target: []const u8,
    inventory_binding: InventoryBinding,
    inventory: *const artifact_inventory.Inventory,
    checks: []const Check,
    findings: []const doctor.Finding,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, report_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"target\": ");
    try json_out.writeString(&out, gpa, target);
    try out.appendSlice(gpa, ",\n  \"artifact_inventory\": {\n    \"path\": ");
    try json_out.writeString(&out, gpa, artifact_inventory.output_path);
    try out.appendSlice(gpa, ",\n    \"bytes\": ");
    try json_out.writeUsize(&out, gpa, inventory_binding.bytes);
    try out.appendSlice(gpa, ",\n    \"sha256\": ");
    try json_out.writeString(&out, gpa, &inventory_binding.sha256);
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
    report_gpa: std.mem.Allocator,
    payload_gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    inventory_binding: InventoryBinding,
) Error![]u8 {
    var inventory = try parseInventoryFile(io, root, report_gpa, target);
    defer inventory.deinit();

    var findings: std.ArrayList(doctor.Finding) = .empty;
    defer findings.deinit(report_gpa);
    var page_paths: std.ArrayList([]const u8) = .empty;
    defer page_paths.deinit(report_gpa);
    var route_paths: std.ArrayList([]const u8) = .empty;
    defer route_paths.deinit(report_gpa);
    var search_record_index: ?usize = null;
    for (inventory.records, 0..) |record, index| {
        if (record.status != .committed) continue;
        try route_paths.append(report_gpa, record.path);
        if (record.kind == .html_page) try page_paths.append(report_gpa, record.path);
        if (record.kind == .rendered_search) {
            if (search_record_index != null) return error.MultipleRenderedSearchArtifacts;
            search_record_index = index;
        }
    }

    var analysis_builder = doctor.TargetAnalysisBuilder.init(report_gpa, .{
        .target_name = target,
        .pages = &.{},
        .expected_page_paths = page_paths.items,
        .intended_route_paths = route_paths.items,
        .search_page_paths = page_paths.items,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    defer if (!analysis_builder.finished) analysis_builder.deinit();

    var committed_count: usize = 0;
    var checked_count: usize = 0;
    var missing_count: usize = 0;
    var search_checked = false;
    var search_payload: ?[]u8 = null;
    defer if (search_payload) |bytes| payload_gpa.free(bytes);
    const integrity_offset = findings.items.len;

    for (inventory.records) |record| {
        if (record.status != .committed) continue;
        committed_count += 1;
        const streamed = streamFileNoFollow(
            io,
            root,
            payload_gpa,
            record.path,
            record.kind == .html_page or record.kind == .rendered_search,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                missing_count += 1;
                try appendArtifactFinding(
                    &findings,
                    report_gpa,
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
        checked_count += 1;

        if (streamed.bytes != record.bytes) {
            var observed_buffer: [64]u8 = undefined;
            var expected_buffer: [64]u8 = undefined;
            const observed = std.fmt.bufPrint(&observed_buffer, "{d} bytes", .{streamed.bytes}) catch unreachable;
            const expected = std.fmt.bufPrint(&expected_buffer, "{d} bytes", .{record.bytes}) catch unreachable;
            try appendArtifactFinding(&findings, report_gpa, .ARTIFACT_SIZE_MISMATCH, target, record, observed, expected);
        }
        if (!std.mem.eql(u8, &streamed.sha256, &record.sha256)) {
            try appendArtifactFinding(
                &findings,
                report_gpa,
                .ARTIFACT_DIGEST_MISMATCH,
                target,
                record,
                &streamed.sha256,
                &record.sha256,
            );
        }

        if (record.kind == .html_page) {
            const bytes = streamed.payload.?;
            defer payload_gpa.free(bytes);
            analysis_builder.addPage(record.path, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CheckerExecutionFailed,
            };
        } else if (record.kind == .rendered_search) {
            search_payload = streamed.payload.?;
            search_checked = true;
        }
    }

    const integrity_findings = findings.items.len - integrity_offset;
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
        .scope = .{
            .subject_statuses = &committed_statuses,
            .subject_kinds = &no_kinds,
            .subject_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &no_kinds),
            .supporting_statuses = &no_statuses,
            .supporting_kinds = &no_kinds,
            .supporting_sha256 = emptyDigest(),
        },
        .counts = .{ .eligible = committed_count, .checked = checked_count, .findings = integrity_findings },
        .finding_offset = integrity_offset,
    };

    const search_input: doctor.SearchInput = if (search_record_index == null)
        .not_configured
    else if (search_checked)
        .{ .selected = search_payload.? }
    else
        .selected_missing;
    var analysis = analysis_builder.finish(search_input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    defer analysis.deinit();

    const html_offset = findings.items.len;
    const html_findings = appendFilteredFindings(&findings, report_gpa, analysis.findings, .html) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    const html_coverage_value = doctor.coverageFor(&analysis, "rendered_html") catch return error.CheckerExecutionFailed;
    const html_coverage: Coverage = switch (html_coverage_value.status) {
        .checked => .complete,
        .incomplete => .incomplete,
        .not_configured, .not_in_scope => .complete,
    };
    const html_check = Check{
        .id = "rendered-html",
        .eligible = true,
        .ran = true,
        .status = completedStatus(html_coverage, findings.items[html_offset..][0..html_findings]),
        .coverage = html_coverage,
        .scope = .{
            .subject_statuses = &committed_statuses,
            .subject_kinds = &html_page_kinds,
            .subject_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &html_page_kinds),
            .supporting_statuses = &committed_statuses,
            .supporting_kinds = &no_kinds,
            .supporting_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &no_kinds),
        },
        .counts = .{ .eligible = page_paths.items.len, .checked = page_paths.items.len - analysis_builder.missing_expected_pages, .findings = html_findings },
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
                .supporting_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &html_page_kinds),
            },
            .counts = .{ .eligible = 0, .checked = 0, .findings = 0 },
            .finding_offset = search_offset,
        };
    } else {
        const search_findings = appendFilteredFindings(&findings, report_gpa, analysis.findings, .search) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CheckerExecutionFailed,
        };
        const search_coverage_value = doctor.coverageFor(&analysis, "artifact.search") catch return error.CheckerExecutionFailed;
        const search_coverage: Coverage = switch (search_coverage_value.status) {
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
                .subject_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &rendered_search_kinds),
                .supporting_statuses = &committed_statuses,
                .supporting_kinds = &html_page_kinds,
                .supporting_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &html_page_kinds),
            },
            .counts = .{ .eligible = 1, .checked = if (search_checked) 1 else 0, .findings = search_findings },
            .finding_offset = search_offset,
        };
    }

    const checks = [_]Check{ integrity_check, html_check, search_check };
    return writeReport(report_gpa, target, inventory_binding, &inventory, &checks, findings.items) catch |err| switch (err) {
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

    const inventory_binding = streamFileNoFollow(io, root, gpa, artifact_inventory.output_path, false) catch {
        return error.InvalidInventory;
    };

    const report = try buildReport(io, report_gpa, gpa, root, target, .{
        .bytes = inventory_binding.bytes,
        .sha256 = inventory_binding.sha256,
    });

    var atomic = root.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true }) catch {
        return error.ChecksWriteFailed;
    };
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(report) catch return error.ChecksWriteFailed;
    writer.interface.flush() catch return error.ChecksWriteFailed;
    if (options.test_fail_write) return error.ChecksWriteFailed;
    atomic.replace(io) catch return error.ChecksWriteFailed;
}

pub const Payload = struct {
    path: []const u8,
    bytes: []const u8,
};

fn lookupPayload(payloads: []const Payload, path: []const u8) ?[]const u8 {
    for (payloads) |payload| {
        if (std.mem.eql(u8, payload.path, path)) return payload.bytes;
    }
    return null;
}

/// Build the checks report from inventory JSON and in-memory payload bytes.
/// Same checker set as `writeAfterCommit`; no host directory is opened.
pub fn renderFromPayloads(
    gpa: std.mem.Allocator,
    target: []const u8,
    inventory_bytes: []const u8,
    payloads: []const Payload,
) Error![]u8 {
    var report_arena = std.heap.ArenaAllocator.init(gpa);
    defer report_arena.deinit();
    const report_gpa = report_arena.allocator();

    var inventory = artifact_inventory.parse(report_gpa, inventory_bytes, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInventory,
    };
    defer inventory.deinit();

    const inventory_binding = InventoryBinding{
        .bytes = inventory_bytes.len,
        .sha256 = cache.hexDigest(cache.hashBytes(inventory_bytes)),
    };

    var findings: std.ArrayList(doctor.Finding) = .empty;
    defer findings.deinit(report_gpa);
    var page_paths: std.ArrayList([]const u8) = .empty;
    defer page_paths.deinit(report_gpa);
    var route_paths: std.ArrayList([]const u8) = .empty;
    defer route_paths.deinit(report_gpa);
    var search_record_index: ?usize = null;
    for (inventory.records, 0..) |record, index| {
        if (record.status != .committed) continue;
        try route_paths.append(report_gpa, record.path);
        if (record.kind == .html_page) try page_paths.append(report_gpa, record.path);
        if (record.kind == .rendered_search) {
            if (search_record_index != null) return error.MultipleRenderedSearchArtifacts;
            search_record_index = index;
        }
    }

    var analysis_builder = doctor.TargetAnalysisBuilder.init(report_gpa, .{
        .target_name = target,
        .pages = &.{},
        .expected_page_paths = page_paths.items,
        .intended_route_paths = route_paths.items,
        .search_page_paths = page_paths.items,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    defer if (!analysis_builder.finished) analysis_builder.deinit();

    var committed_count: usize = 0;
    var checked_count: usize = 0;
    var missing_count: usize = 0;
    var search_checked = false;
    var search_payload: ?[]const u8 = null;
    const integrity_offset = findings.items.len;

    for (inventory.records) |record| {
        if (record.status != .committed) continue;
        committed_count += 1;
        const payload = lookupPayload(payloads, record.path) orelse {
            missing_count += 1;
            try appendArtifactFinding(
                &findings,
                report_gpa,
                .ARTIFACT_MISSING,
                target,
                record,
                "committed artifact file is missing",
                "a regular file beneath the target root",
            );
            continue;
        };
        checked_count += 1;
        const digest = cache.hexDigest(cache.hashBytes(payload));

        if (payload.len != record.bytes) {
            var observed_buffer: [64]u8 = undefined;
            var expected_buffer: [64]u8 = undefined;
            const observed = std.fmt.bufPrint(&observed_buffer, "{d} bytes", .{payload.len}) catch unreachable;
            const expected = std.fmt.bufPrint(&expected_buffer, "{d} bytes", .{record.bytes}) catch unreachable;
            try appendArtifactFinding(&findings, report_gpa, .ARTIFACT_SIZE_MISMATCH, target, record, observed, expected);
        }
        if (!std.mem.eql(u8, &digest, &record.sha256)) {
            try appendArtifactFinding(
                &findings,
                report_gpa,
                .ARTIFACT_DIGEST_MISMATCH,
                target,
                record,
                &digest,
                &record.sha256,
            );
        }

        if (record.kind == .html_page) {
            analysis_builder.addPage(record.path, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CheckerExecutionFailed,
            };
        } else if (record.kind == .rendered_search) {
            search_payload = payload;
            search_checked = true;
        }
    }

    const integrity_findings = findings.items.len - integrity_offset;
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
        .scope = .{
            .subject_statuses = &committed_statuses,
            .subject_kinds = &no_kinds,
            .subject_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &no_kinds),
            .supporting_statuses = &no_statuses,
            .supporting_kinds = &no_kinds,
            .supporting_sha256 = emptyDigest(),
        },
        .counts = .{ .eligible = committed_count, .checked = checked_count, .findings = integrity_findings },
        .finding_offset = integrity_offset,
    };

    const search_input: doctor.SearchInput = if (search_record_index == null)
        .not_configured
    else if (search_checked)
        .{ .selected = search_payload.? }
    else
        .selected_missing;
    var analysis = analysis_builder.finish(search_input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    defer analysis.deinit();

    const html_offset = findings.items.len;
    const html_findings = appendFilteredFindings(&findings, report_gpa, analysis.findings, .html) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CheckerExecutionFailed,
    };
    const html_coverage_value = doctor.coverageFor(&analysis, "rendered_html") catch return error.CheckerExecutionFailed;
    const html_coverage: Coverage = switch (html_coverage_value.status) {
        .checked => .complete,
        .incomplete => .incomplete,
        .not_configured, .not_in_scope => .complete,
    };
    const html_check = Check{
        .id = "rendered-html",
        .eligible = true,
        .ran = true,
        .status = completedStatus(html_coverage, findings.items[html_offset..][0..html_findings]),
        .coverage = html_coverage,
        .scope = .{
            .subject_statuses = &committed_statuses,
            .subject_kinds = &html_page_kinds,
            .subject_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &html_page_kinds),
            .supporting_statuses = &committed_statuses,
            .supporting_kinds = &no_kinds,
            .supporting_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &no_kinds),
        },
        .counts = .{ .eligible = page_paths.items.len, .checked = page_paths.items.len - analysis_builder.missing_expected_pages, .findings = html_findings },
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
                .supporting_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &html_page_kinds),
            },
            .counts = .{ .eligible = 0, .checked = 0, .findings = 0 },
            .finding_offset = search_offset,
        };
    } else {
        const search_findings = appendFilteredFindings(&findings, report_gpa, analysis.findings, .search) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CheckerExecutionFailed,
        };
        const search_coverage_value = doctor.coverageFor(&analysis, "artifact.search") catch return error.CheckerExecutionFailed;
        const search_coverage: Coverage = switch (search_coverage_value.status) {
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
                .subject_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &rendered_search_kinds),
                .supporting_statuses = &committed_statuses,
                .supporting_kinds = &html_page_kinds,
                .supporting_sha256 = try scopeDigest(report_gpa, &inventory, &committed_statuses, &html_page_kinds),
            },
            .counts = .{ .eligible = 1, .checked = if (search_checked) 1 else 0, .findings = search_findings },
            .finding_offset = search_offset,
        };
    }

    const checks = [_]Check{ integrity_check, html_check, search_check };
    const report = writeReport(report_gpa, target, inventory_binding, &inventory, &checks, findings.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
    return gpa.dupe(u8, report);
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

test "scope selector dimensions support empty, status-only, kind-only, exact, and no-match scopes" {
    const gpa = std.testing.allocator;
    const page_digest = cache.hexDigest(cache.hashBytes("page"));
    const asset_digest = cache.hexDigest(cache.hashBytes("asset"));
    const omitted_digest = cache.hexDigest(cache.hashBytes("omitted"));
    var inventory = artifact_inventory.Inventory{
        .gpa = gpa,
        .target = "public",
        .records = try gpa.dupe(artifact_inventory.Record, &.{
            .{ .path = "asset.txt", .kind = .theme_asset, .producer = "theme-assets", .required = true, .status = .committed, .bytes = 5, .sha256 = asset_digest, .format_version = null },
            .{ .path = "index.html", .kind = .html_page, .producer = "html-render", .required = true, .status = .committed, .bytes = 4, .sha256 = page_digest, .format_version = null },
            .{ .path = "omitted.html", .kind = .html_page, .producer = "html-render", .required = false, .status = .omitted_by_plan, .bytes = 7, .sha256 = omitted_digest, .format_version = null },
        }),
    };
    defer inventory.deinit();

    const empty = try scopeDigest(gpa, &inventory, &.{}, &.{});
    const status_only = try scopeDigest(gpa, &inventory, &.{"committed"}, &.{});
    const kind_only = try scopeDigest(gpa, &inventory, &.{}, &.{"html-page"});
    const exact = try scopeDigest(gpa, &inventory, &.{"committed"}, &.{"html-page"});
    const no_match = try scopeDigest(gpa, &inventory, &.{"not-applicable"}, &.{"html-page"});

    try std.testing.expectEqualStrings(&empty, &cache.hexDigest(cache.hashBytes("")));
    try std.testing.expect(!std.mem.eql(u8, &status_only, &empty));
    try std.testing.expect(!std.mem.eql(u8, &kind_only, &status_only));
    try std.testing.expect(!std.mem.eql(u8, &exact, &kind_only));
    try std.testing.expect(!std.mem.eql(u8, &exact, &status_only));
    try std.testing.expectEqualStrings(&no_match, &empty);
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

    const reserved_claims = prefix ++ "{\"path\":\"_boris/proof/claims.json\",\"kind\":\"sitemap\",\"producer\":\"sitemap\",\"required\":true,\"status\":\"committed\",\"bytes\":0,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"format_version\":null}" ++ suffix;
    try std.testing.expectError(error.InvalidInventoryPath, artifact_inventory.parse(gpa, reserved_claims, "public"));

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
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var input_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const count = try reader.interface.readSliceShort(&input_buffer);
        if (count == 0) break;
        try output.appendSlice(gpa, input_buffer[0..count]);
    }
    return output.toOwnedSlice(gpa);
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

const LiveBoundedAllocator = struct {
    backing: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *LiveBoundedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LiveBoundedAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.limit -| self.live) return null;
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveBoundedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > self.limit -| self.live) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) self.live += new_len - memory.len else self.live -= memory.len - new_len;
        self.peak = @max(self.peak, self.live);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveBoundedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > self.limit -| self.live) return null;
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) self.live += new_len - memory.len else self.live -= memory.len - new_len;
        self.peak = @max(self.peak, self.live);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveBoundedAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.live -= memory.len;
    }
};

fn objectAt(value: std.json.Value, key: []const u8) std.json.Value {
    return value.object.get(key).?;
}

fn expectJsonStrings(value: std.json.Value, expected: []const []const u8) !void {
    const items = value.array.items;
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |want, index| try std.testing.expectEqualStrings(want, items[index].string);
}

test "publication report runtime vocabulary matches its draft 2020-12 schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const schema_bytes = try readPayload(io, Io.Dir.cwd(), gpa, "docs/contracts/schemas/publication-checks-1.schema.json");
    defer gpa.free(schema_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", root.get("$schema").?.string);
    try std.testing.expectEqualStrings(report_format, root.get("properties").?.object.get("format").?.object.get("const").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("properties").?.object.get("schema_version").?.object.get("const").?.integer);
    try expectJsonStrings(root.get("required").?, &.{ "format", "schema_version", "target", "artifact_inventory", "checks", "findings" });

    const checks_schema = root.get("properties").?.object.get("checks").?.object;
    try std.testing.expectEqual(@as(i64, 3), checks_schema.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 3), checks_schema.get("maxItems").?.integer);
    try std.testing.expect(!checks_schema.get("items").?.bool);
    const prefix = checks_schema.get("prefixItems").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), prefix.len);
    const check_ids = [_][]const u8{ "artifact-integrity", "rendered-html", "rendered-search" };
    for (prefix, check_ids) |position, expected_id| {
        try std.testing.expectEqualStrings(expected_id, position.object.get("properties").?.object.get("id").?.object.get("const").?.string);
    }

    const defs = root.get("$defs").?.object;
    try expectJsonStrings(defs.get("status").?.object.get("enum").?, &.{ "committed", "omitted-by-plan", "not-applicable" });
    try expectJsonStrings(defs.get("kind").?.object.get("enum").?, &.{ "html-page", "theme-asset", "content-asset", "rendered-search", "sitemap", "rss", "llms" });
    try expectJsonStrings(defs.get("check").?.object.get("properties").?.object.get("status").?.object.get("enum").?, &.{ "passed", "failed", "incomplete", "not-applicable" });
    try expectJsonStrings(defs.get("check").?.object.get("properties").?.object.get("coverage").?.object.get("enum").?, &.{ "complete", "incomplete", "not-applicable" });
    try expectJsonStrings(defs.get("inventory_binding").?.object.get("required").?, &.{ "path", "bytes", "sha256", "format", "schema_version", "target", "artifact_count" });
    try expectJsonStrings(defs.get("scope").?.object.get("required").?, &.{ "subject_statuses", "subject_kinds", "subject_sha256", "supporting_statuses", "supporting_kinds", "supporting_sha256" });
    try expectJsonStrings(defs.get("counts").?.object.get("required").?, &.{ "eligible", "checked", "findings" });
    try expectJsonStrings(defs.get("check").?.object.get("required").?, &.{ "id", "eligible", "ran", "status", "coverage", "scope", "counts", "finding_offset" });
    try expectJsonStrings(defs.get("finding").?.object.get("properties").?.object.get("code").?.object.get("enum").?, &.{
        "ARTIFACT_MISSING",         "ARTIFACT_SIZE_MISMATCH",  "ARTIFACT_DIGEST_MISMATCH",
        "HTML_PAGE_MISSING",        "HTML_MALFORMED",          "HTML_URL_MALFORMED",
        "HTML_LOCAL_ROUTE_MISSING", "HTML_LOCAL_ROUTE_ESCAPE", "HTML_FRAGMENT_MISSING",
        "HTML_DUPLICATE_ID",        "SEARCH_MISSING",          "SEARCH_MALFORMED",
        "SEARCH_DOCUMENT_MISSING",  "SEARCH_DOCUMENT_STALE",   "SEARCH_CONTENT_MISMATCH",
    });
    try expectJsonStrings(defs.get("finding").?.object.get("properties").?.object.get("domain").?.object.get("enum").?, &.{ "rendered_html", "artifact" });
    try expectJsonStrings(defs.get("finding").?.object.get("properties").?.object.get("severity").?.object.get("enum").?, &.{ "error", "warning", "info" });
    try expectJsonStrings(defs.get("finding").?.object.get("properties").?.object.get("confidence").?.object.get("enum").?, &.{ "certain", "high", "limited" });
    try expectJsonStrings(defs.get("finding").?.object.get("properties").?.object.get("owner").?.object.get("enum").?, &.{ "content", "theme", "publication", "configuration", "unknown" });
    try expectJsonStrings(defs.get("finding").?.object.get("properties").?.object.get("fixability").?.object.get("enum").?, &.{ "source_edit", "layout_edit", "configuration_edit", "regenerate", "not_actionable" });
    try expectJsonStrings(defs.get("finding").?.object.get("required").?, &.{ "code", "domain", "severity", "confidence", "owner", "subject", "source_location", "output_location", "configuration_location", "evidence", "remediation", "fixability" });
    const finding_properties = defs.get("finding").?.object.get("properties").?.object;
    try expectJsonStrings(finding_properties.get("subject").?.object.get("required").?, &.{ "kind", "id", "target" });
    try expectJsonStrings(finding_properties.get("evidence").?.object.get("required").?, &.{ "observed", "expected", "related" });
    try expectJsonStrings(defs.get("location").?.object.get("required").?, &.{ "path", "line", "column" });
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

test "publication checks retain bounded metadata instead of the aggregate payload set" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const html = "<main data-boris-search-root><h1 id=home>Page</h1><p>Body.</p></main>";
    var pages: std.ArrayList(doctor.PageInput) = .empty;
    defer {
        for (pages.items) |page| gpa.free(page.path);
        pages.deinit(gpa);
    }
    var records: std.ArrayList(artifact_inventory.Record) = .empty;
    defer {
        for (records.items) |record| {
            if (record.kind != .html_page and !std.mem.eql(u8, record.path, search_index.output_path)) gpa.free(record.path);
        }
        records.deinit(gpa);
    }

    var page_index: usize = 0;
    while (page_index < 64) : (page_index += 1) {
        var path_buffer: [64]u8 = undefined;
        const path = try gpa.dupe(u8, std.fmt.bufPrint(&path_buffer, "pages/{d:0>3}.html", .{page_index}) catch unreachable);
        try pages.append(gpa, .{ .path = path, .html = html });
        try writePayload(io, tmp.dir, path, html);
        try records.append(gpa, recordFor(path, .html_page, html));
    }

    var large_asset: [512 * 1024]u8 = undefined;
    @memset(&large_asset, 'x');
    var asset_index: usize = 0;
    while (asset_index < 4) : (asset_index += 1) {
        var path_buffer: [64]u8 = undefined;
        const path = try gpa.dupe(u8, std.fmt.bufPrint(&path_buffer, "assets/blob-{d}.bin", .{asset_index}) catch unreachable);
        try writePayload(io, tmp.dir, path, &large_asset);
        try records.append(gpa, recordFor(path, .theme_asset, &large_asset));
    }

    const search_bytes = try makeSearch(gpa, pages.items);
    defer gpa.free(search_bytes);
    try writePayload(io, tmp.dir, search_index.output_path, search_bytes);
    try records.append(gpa, recordFor(search_index.output_path, .rendered_search, search_bytes));
    const inventory_bytes = try writeInventory(io, gpa, tmp.dir, "public", records.items);
    defer gpa.free(inventory_bytes);

    const combined_payload_bytes = html.len * pages.items.len + large_asset.len * 4 + search_bytes.len;
    var bounded = LiveBoundedAllocator{ .backing = gpa, .limit = 2 * 1024 * 1024 };
    try std.testing.expect(combined_payload_bytes > bounded.limit);
    try writeAfterCommit(io, bounded.allocator(), tmp.dir, "public", .{});
    try std.testing.expect(bounded.peak < bounded.limit);
    try std.testing.expect(bounded.live <= bounded.limit);
    const report = try readPayload(io, tmp.dir, gpa, output_path);
    defer gpa.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
    defer parsed.deinit();
    const checks = parsed.value.object.get("checks").?.array.items;
    for (checks) |check| try std.testing.expectEqualStrings("passed", objectAt(check, "status").string);
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
    var proof = try tmp.dir.openDir(io, "_boris/proof", .{ .iterate = true });
    defer proof.close(io);
    var proof_entries: usize = 0;
    var proof_iterator = proof.iterate();
    while (try proof_iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        proof_entries += 1;
        try std.testing.expect(std.mem.eql(u8, entry.name, "artifacts.json") or std.mem.eql(u8, entry.name, "checks.json"));
    }
    try std.testing.expectEqual(@as(usize, 2), proof_entries);
    try std.testing.expectError(
        error.CheckerExecutionFailed,
        writeAfterCommit(io, gpa, tmp.dir, "public", .{ .test_fail_execution = true }),
    );
}
