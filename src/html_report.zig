//! Deterministic JSON renderer for the HTML-path diagnostics report
//! (`build` / `validate --report PATH`).
//!
//! The top-level shape mirrors the IR `build-report.json` contract
//! (`schemaVersion`, `ok`, `errorCount`, `diagnostics` …) so tooling that
//! already consumes the IR report can treat the HTML report the same way.
//! Each diagnostic object uses the exact key order of the IR diagnostic
//! object (`severity, code, message, remediation, sourcePath, line, column,
//! id`), per the #421 contract.
//!
//! The report is written on both success and failure. Diagnostics are sorted
//! deterministically by the collector contract (`diag.sortDiagnostics`)
//! before this renderer runs.

const std = @import("std");
const diag = @import("diag.zig");
const json_out = @import("json_out.zig");

/// Schema version pinned by `docs/contracts/schemas/html-build-report-0.2.0.schema.json`.
pub const schema_version = "html-build-report-0.2.0";

/// One publication-check verdict mirrored into the optional proofPack
/// section (#741). `status` uses the committed checks.json spelling.
pub const ProofCheck = struct {
    id: []const u8,
    status: []const u8,
};

pub const ProofSection = struct {
    /// Target-relative path of the committed checks report (caller-owned).
    path: []const u8,
    checks: []const ProofCheck,

    pub fn allPassed(self: ProofSection) bool {
        for (self.checks) |check| {
            if (std.mem.eql(u8, check.status, "failed") or
                std.mem.eql(u8, check.status, "incomplete")) return false;
        }
        return true;
    }
};

pub const Report = struct {
    ok: bool,
    content_root: []const u8,
    out_dir: []const u8,
    diagnostics: []const diag.Diagnostic,
    /// Optional publication-check mirror (#741); present only when the run
    /// committed target evidence and `_boris/proof/checks.json` was readable.
    proof: ?ProofSection = null,

    pub fn errorCount(self: *const Report) usize {
        return diag.countErrors(self.diagnostics);
    }
};

pub fn renderHtmlReport(gpa: std.mem.Allocator, compiler_id: []const u8, report: Report) ![]u8 {
    return renderHtmlReportVcs(gpa, compiler_id, "", report);
}

/// `renderHtmlReport` with the build-provenance token (#776): the VCS
/// revision the producing binary was compiled from, or "" when unknown.
/// Emitted additively after `compilerId` so key order stays stable.
pub fn renderHtmlReportVcs(gpa: std.mem.Allocator, compiler_id: []const u8, vcs_revision: []const u8, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"compilerId\": ");
    try json_out.writeString(&buf, gpa, compiler_id);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    // Additive build provenance (#776); "" when the binary carries no token.
    try buf.appendSlice(gpa, "\"vcsRevision\": ");
    try json_out.writeString(&buf, gpa, vcs_revision);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"ok\": ");
    try json_out.writeBool(&buf, gpa, report.ok);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"contentRoot\": ");
    try json_out.writeString(&buf, gpa, report.content_root);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"outDir\": ");
    try json_out.writeString(&buf, gpa, report.out_dir);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"errorCount\": ");
    try json_out.writeUsize(&buf, gpa, report.errorCount());
    if (report.proof) |proof| {
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"proofPack\": {\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "\"path\": ");
        try json_out.writeString(&buf, gpa, proof.path);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "\"allPassed\": ");
        try json_out.writeBool(&buf, gpa, proof.allPassed());
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "\"checks\": ");
        if (proof.checks.len == 0) {
            try buf.appendSlice(gpa, "[]\n");
        } else {
            try buf.appendSlice(gpa, "[ ");
            for (proof.checks, 0..) |check, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try buf.appendSlice(gpa, "{\"id\": ");
                try json_out.writeString(&buf, gpa, check.id);
                try buf.appendSlice(gpa, ", \"status\": ");
                try json_out.writeString(&buf, gpa, check.status);
                try buf.appendSlice(gpa, "}");
            }
            try buf.appendSlice(gpa, " ]\n");
        }
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "}");
    }
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"diagnostics\": ");
    if (report.diagnostics.len == 0) {
        try buf.appendSlice(gpa, "[]\n");
    } else {
        try buf.appendSlice(gpa, "[\n");
        for (report.diagnostics, 0..) |d, i| {
            try json_out.indent(&buf, gpa, 2);
            try buf.appendSlice(gpa, "{\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"severity\": ");
            try json_out.writeString(&buf, gpa, d.severity.jsonName());
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"code\": ");
            try json_out.writeString(&buf, gpa, d.code.name());
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"message\": ");
            try json_out.writeString(&buf, gpa, d.message);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"remediation\": ");
            try json_out.writeString(&buf, gpa, d.remediation);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"sourcePath\": ");
            if (d.source_path.len == 0)
                try json_out.writeNull(&buf, gpa)
            else
                try json_out.writeString(&buf, gpa, d.source_path);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"line\": ");
            try json_out.writeOptionalU32(&buf, gpa, d.line);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"column\": ");
            try json_out.writeOptionalU32(&buf, gpa, d.column);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"id\": ");
            if (d.id.len == 0)
                try json_out.writeNull(&buf, gpa)
            else
                try json_out.writeString(&buf, gpa, d.id);
            try buf.appendSlice(gpa, "\n");
            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, '}');
            if (i + 1 < report.diagnostics.len) try buf.append(gpa, ',');
            try buf.append(gpa, '\n');
        }
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "]\n");
    }
    try buf.appendSlice(gpa, "}\n");
    return try buf.toOwnedSlice(gpa);
}

test "html report renders deterministic shape with diagnostics" {
    const gpa = std.testing.allocator;
    var diags = [_]diag.Diagnostic{
        .{
            .severity = .error_,
            .code = .ELAYOUTDUPLICATEMARKER,
            .message = "failed to load layout themes/x.html: LayoutDuplicateMarker",
            .remediation = "Keep exactly one marker per slot in the layout template",
            .source_path = "themes/x/layouts/main.html",
        },
        .{
            .severity = .error_,
            .code = .EINCLUDEMISSING,
            .message = "include target \"missing.md\" not found or unreadable",
            .remediation = "Create the include file under the content root or fix the path",
            .source_path = "content/index.md",
            .line = 3,
            .column = 5,
            .id = "index",
        },
    };
    const rendered = try renderHtmlReport(gpa, "boris/0.8.1", .{
        .ok = false,
        .content_root = "content",
        .out_dir = "dist",
        .diagnostics = &diags,
    });
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schemaVersion\": \"html-build-report-0.2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"errorCount\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"code\": \"ELAYOUTDUPLICATEMARKER\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"sourcePath\": \"content/index.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"line\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"column\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"id\": \"index\"") != null);
    // Diagnostic object key order is pinned: severity before code before message.
    const first_diag = std.mem.indexOf(u8, rendered, "\"severity\": \"error\"").?;
    const code_pos = std.mem.indexOf(u8, rendered, "\"code\": \"ELAYOUTDUPLICATEMARKER\"").?;
    try std.testing.expect(first_diag < code_pos);
}

test "html report renders empty diagnostics as ok" {
    const gpa = std.testing.allocator;
    const rendered = try renderHtmlReport(gpa, "boris/0.8.1", .{
        .ok = true,
        .content_root = "content",
        .out_dir = "dist",
        .diagnostics = &.{},
    });
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"errorCount\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"diagnostics\": []") != null);
    // No evidence published → no proofPack section.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"proofPack\"") == null);
}

test "#741: proofPack mirrors check verdicts with allPassed=false on failure" {
    const gpa = std.testing.allocator;
    const checks = [_]ProofCheck{
        .{ .id = "artifact-integrity", .status = "passed" },
        .{ .id = "rendered-html", .status = "passed" },
        .{ .id = "rendered-search", .status = "failed" },
    };
    const rendered = try renderHtmlReport(gpa, "boris/0.8.1", .{
        .ok = true,
        .content_root = "content",
        .out_dir = "dist",
        .diagnostics = &.{},
        .proof = .{ .path = "_boris/proof/checks.json", .checks = &checks },
    });
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered,
        \\  "proofPack": {
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"path\": \"_boris/proof/checks.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"allPassed\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"id\": \"rendered-search\", \"status\": \"failed\"") != null);
    // proofPack sits between errorCount and diagnostics; key order is pinned.
    const proof_pos = std.mem.indexOf(u8, rendered, "\"proofPack\"").?;
    const error_pos = std.mem.indexOf(u8, rendered, "\"errorCount\"").?;
    const diag_pos = std.mem.indexOf(u8, rendered, "\"diagnostics\"").?;
    try std.testing.expect(error_pos < proof_pos and proof_pos < diag_pos);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, rendered, .{});
    defer parsed.deinit();
    const proof_pack = parsed.value.object.get("proofPack").?.object;
    try std.testing.expectEqual(false, proof_pack.get("allPassed").?.bool);
    try std.testing.expectEqual(@as(usize, 3), proof_pack.get("checks").?.array.items.len);
}

test "#741: proofPack allPassed tolerates not-applicable checks" {
    const gpa = std.testing.allocator;
    const checks = [_]ProofCheck{
        .{ .id = "artifact-integrity", .status = "passed" },
        .{ .id = "rendered-search", .status = "not-applicable" },
    };
    const rendered = try renderHtmlReport(gpa, "boris/0.8.1", .{
        .ok = true,
        .content_root = "content",
        .out_dir = "dist",
        .diagnostics = &.{},
        .proof = .{ .path = "_boris/proof/checks.json", .checks = &checks },
    });
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"allPassed\": true") != null);
}
