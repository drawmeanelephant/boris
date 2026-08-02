//! Deterministic target-local publication Touch Atlas evidence.
//!
//! This layer runs after the publication claims report has committed. It
//! derives a relationship index exclusively from the exact committed bytes of
//! `artifacts.json`, `checks.json`, and `claims.json`, validates every
//! cross-report binding and fixed registry, and atomically publishes one
//! deterministic report. It never rereads payloads, source content, caches,
//! deployment state, or the target tree, and it never invents provenance.

const std = @import("std");
const Io = std.Io;
const artifact_inventory = @import("artifact_inventory.zig");
const cache = @import("cache.zig");
const json_out = @import("json_out.zig");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");

pub const output_path = artifact_inventory.touches_output_path;
pub const report_format = "boris-publication-touches";
pub const schema_version: usize = 1;

/// Fixed v1 check identities, in canonical publication order.
pub const check_ids = [_][]const u8{ "artifact-integrity", "rendered-html", "rendered-search" };

/// Fixed v1 claim identities, in canonical publication order.
pub const claim_ids = [_][]const u8{
    "committed-artifacts-match-inventory",
    "rendered-html-passed-declared-audit",
    "rendered-search-matches-selected-html",
};

/// Fixed v1 limitation identities, in canonical publication order.
pub const limitation_ids = [_][]const u8{
    "target-local-only",
    "no-deployment-verification",
    "no-accessibility-verification",
    "no-prose-quality-verification",
    "no-universal-reproducibility-claim",
    "omitted-projections-not-certified",
};

/// The five limitations shared by every first-slice claim, in canonical order.
const generic_limitation_ids = limitation_ids[0..5];

/// The exact ordered limitation list attached to each claim.
const claim_limitation_ids = [_][]const []const u8{
    generic_limitation_ids,
    generic_limitation_ids,
    &limitation_ids,
};

const all_claim_ids = &claim_ids;
const search_claim_ids = claim_ids[2..3];

/// The exact ordered claim list each limitation applies to.
const limitation_applies_to_claims = [_][]const []const u8{
    all_claim_ids,
    all_claim_ids,
    all_claim_ids,
    all_claim_ids,
    all_claim_ids,
    search_claim_ids,
};

pub const Options = struct {
    /// Test-only fault injection. Production callers leave both false.
    test_fail_execution: bool = false,
    test_fail_write: bool = false,
    /// Test-only seam: invoked once after all three evidence handles are
    /// opened and before any byte is read. A test may replace files at this
    /// point; the already-opened handles must be unaffected.
    after_open: ?*const fn (?*anyopaque) void = null,
    after_open_context: ?*anyopaque = null,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidArtifactsReport,
    InvalidChecksReport,
    InvalidClaimsReport,
    StaleArtifactsBinding,
    StaleChecksBinding,
    StaleClaimsBinding,
    TouchesWriteFailed,
};

const FileBinding = struct {
    bytes: usize,
    sha256: [64]u8,
};

/// Selector pair plus the committed evidence digest the checks report recorded
/// for that pair. The digests are validated by recomputation over the
/// canonical inventory, never trusted from the report bytes alone.
const Scope = struct {
    subject_statuses: []const []const u8,
    subject_kinds: []const []const u8,
    subject_sha256: [64]u8,
    supporting_statuses: []const []const u8,
    supporting_kinds: []const []const u8,
    supporting_sha256: [64]u8,
};

const ParsedCheck = struct {
    id: []const u8,
    eligible: bool,
    ran: bool,
    status: []const u8,
    coverage: []const u8,
    scope: Scope,
    counts_eligible: usize,
    counts_checked: usize,
    counts_findings: usize,
    finding_offset: usize,
};

const ParsedSubject = struct {
    kind: []const u8,
    id: []const u8,
    target: ?[]const u8,
};

const ParsedFinding = struct {
    code: []const u8,
    severity: []const u8,
    subject: ParsedSubject,
};

const ParsedChecks = struct {
    artifact_binding: FileBinding,
    artifact_count: usize,
    checks: [3]ParsedCheck,
    findings: []ParsedFinding,
};

const ParsedEvidenceCounts = struct {
    eligible: usize,
    checked: usize,
    findings: usize,
};

const ParsedClaimEvidence = struct {
    check_id: []const u8,
    check_status: []const u8,
    coverage: []const u8,
    counts: ParsedEvidenceCounts,
    subject_sha256: [64]u8,
    supporting_sha256: [64]u8,
    checks_report_sha256: [64]u8,
    reason: ?[]const u8,
};

const ParsedClaim = struct {
    id: []const u8,
    statement: []const u8,
    status: []const u8,
    evidence: ParsedClaimEvidence,
    scope: SelectorScope,
    limitation_ids: []const []const u8,
};

/// The claims report's per-claim scope is the bound check's selector arrays
/// without digests; equality with the parsed check scope is validated.
const SelectorScope = struct {
    subject_statuses: []const []const u8,
    subject_kinds: []const []const u8,
    supporting_statuses: []const []const u8,
    supporting_kinds: []const []const u8,
};

const ParsedLimitation = struct {
    id: []const u8,
    statement: []const u8,
    applies_to_claims: []const []const u8,
    source: []const u8,
};

const ParsedClaims = struct {
    artifact_binding: FileBinding,
    artifact_count: usize,
    checks_binding: FileBinding,
    check_count: usize,
    finding_count: usize,
    claims: [3]ParsedClaim,
    limitations: [6]ParsedLimitation,
};

fn jsonTokenText(token: std.json.Token) ?[]const u8 {
    return switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        .number => |value| value,
        .allocated_number => |value| value,
        else => null,
    };
}

fn freeJsonToken(gpa: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |value| gpa.free(value),
        .allocated_number => |value| gpa.free(value),
        else => {},
    }
}

fn nextJsonToken(reader: *std.json.Reader) Error!std.json.Token {
    return reader.next() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidClaimsReport,
    };
}

fn nextJsonAllocToken(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    max_value_len: usize,
) Error!std.json.Token {
    return reader.nextAllocMax(gpa, .alloc_if_needed, max_value_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidClaimsReport,
    };
}

fn readJsonString(gpa: std.mem.Allocator, reader: *std.json.Reader) Error![]u8 {
    const token = reader.nextAllocMax(gpa, .alloc_always, 4 * 1024 * 1024) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidClaimsReport,
        };
    };
    switch (token) {
        .allocated_string => |value| return value,
        .string => |value| return gpa.dupe(u8, value),
        else => {
            freeJsonToken(gpa, token);
            return error.InvalidClaimsReport;
        },
    }
}

fn readJsonInteger(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!u64 {
    const token = try nextJsonAllocToken(gpa, reader, 64);
    defer freeJsonToken(gpa, token);
    const value = jsonTokenText(token) orelse return error.InvalidClaimsReport;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidClaimsReport;
}

fn readJsonBool(reader: *std.json.Reader) Error!bool {
    return switch (try nextJsonToken(reader)) {
        .true => true,
        .false => false,
        else => error.InvalidClaimsReport,
    };
}

fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn readJsonDigest(gpa: std.mem.Allocator, reader: *std.json.Reader) Error![64]u8 {
    const value = try readJsonString(gpa, reader);
    defer gpa.free(value);
    if (!validDigest(value)) return error.InvalidClaimsReport;
    var digest: [64]u8 = undefined;
    @memcpy(&digest, value);
    return digest;
}

fn readStringArray(gpa: std.mem.Allocator, reader: *std.json.Reader) Error![][]const u8 {
    switch (try nextJsonToken(reader)) {
        .array_begin => {},
        else => return error.InvalidClaimsReport,
    }
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| gpa.free(value);
        values.deinit(gpa);
    }
    while (true) {
        const token = try nextJsonToken(reader);
        defer freeJsonToken(gpa, token);
        switch (token) {
            .array_end => break,
            .string, .allocated_string => {},
            else => return error.InvalidClaimsReport,
        }
        const value = jsonTokenText(token) orelse return error.InvalidClaimsReport;
        try values.append(gpa, try gpa.dupe(u8, value));
    }
    return values.toOwnedSlice(gpa);
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn knownStatus(value: []const u8) bool {
    return containsString(&.{ "committed", "omitted-by-plan", "not-applicable" }, value);
}

fn knownKind(value: []const u8) bool {
    return containsString(
        &.{ "html-page", "theme-asset", "content-asset", "rendered-search", "sitemap", "rss", "llms" },
        value,
    );
}

fn knownCheckStatus(value: []const u8) bool {
    return containsString(&.{ "passed", "failed", "incomplete", "not-applicable" }, value);
}

fn knownCoverage(value: []const u8) bool {
    return containsString(&.{ "complete", "incomplete", "not-applicable" }, value);
}

fn knownFindingCode(value: []const u8) bool {
    return containsString(
        &.{
            "ARTIFACT_MISSING",         "ARTIFACT_SIZE_MISMATCH",  "ARTIFACT_DIGEST_MISMATCH",
            "HTML_PAGE_MISSING",        "HTML_MALFORMED",          "HTML_URL_MALFORMED",
            "HTML_LOCAL_ROUTE_MISSING", "HTML_LOCAL_ROUTE_ESCAPE", "HTML_FRAGMENT_MISSING",
            "HTML_DUPLICATE_ID",        "SEARCH_MISSING",          "SEARCH_MALFORMED",
            "SEARCH_DOCUMENT_MISSING",  "SEARCH_DOCUMENT_STALE",   "SEARCH_CONTENT_MISMATCH",
        },
        value,
    );
}

fn knownSeverity(value: []const u8) bool {
    return containsString(&.{ "error", "warning", "info" }, value);
}

/// Skip one complete JSON value starting at the reader's current position,
/// leaving the reader positioned after the value's closing token.
fn skipJsonValue(reader: *std.json.Reader) Error!void {
    const first = try nextJsonToken(reader);
    switch (first) {
        .object_begin, .array_begin => {
            var depth: usize = 1;
            while (depth > 0) {
                const token = try nextJsonToken(reader);
                switch (token) {
                    .object_begin, .array_begin => depth += 1,
                    .object_end, .array_end => depth -= 1,
                    .end_of_document => return error.InvalidClaimsReport,
                    else => {},
                }
            }
        },
        .end_of_document => return error.InvalidClaimsReport,
        else => {},
    }
}

fn parseSubjectAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!ParsedSubject {
    var subject = ParsedSubject{ .kind = &.{}, .id = &.{}, .target = null };
    errdefer {
        gpa.free(subject.kind);
        gpa.free(subject.id);
        if (subject.target) |value| gpa.free(value);
    }
    var have_kind = false;
    var have_id = false;
    var have_target = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "kind")) {
            if (have_kind) return error.InvalidClaimsReport;
            subject.kind = try readJsonString(gpa, reader);
            if (subject.kind.len == 0) return error.InvalidClaimsReport;
            have_kind = true;
        } else if (std.mem.eql(u8, key, "id")) {
            if (have_id) return error.InvalidClaimsReport;
            subject.id = try readJsonString(gpa, reader);
            if (subject.id.len == 0) return error.InvalidClaimsReport;
            have_id = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return error.InvalidClaimsReport;
            const token = try nextJsonAllocToken(gpa, reader, 4 * 1024 * 1024);
            defer freeJsonToken(gpa, token);
            switch (token) {
                .null => subject.target = null,
                .string => |value| {
                    if (value.len == 0) return error.InvalidClaimsReport;
                    subject.target = try gpa.dupe(u8, value);
                },
                .allocated_string => |value| {
                    if (value.len == 0) return error.InvalidClaimsReport;
                    subject.target = try gpa.dupe(u8, value);
                },
                else => return error.InvalidClaimsReport,
            }
            have_target = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_kind or !have_id or !have_target) return error.InvalidClaimsReport;
    return subject;
}

fn parseFindingAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!ParsedFinding {
    var code: []u8 = &.{};
    var severity: []u8 = &.{};
    var subject: ParsedSubject = undefined;
    var have_code = false;
    var have_severity = false;
    var have_subject = false;
    errdefer {
        if (have_code) gpa.free(code);
        if (have_severity) gpa.free(severity);
        if (have_subject) {
            gpa.free(subject.kind);
            gpa.free(subject.id);
            if (subject.target) |value| gpa.free(value);
        }
    }

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "code")) {
            if (have_code) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!knownFindingCode(value)) return error.InvalidClaimsReport;
            code = try gpa.dupe(u8, value);
            have_code = true;
        } else if (std.mem.eql(u8, key, "severity")) {
            if (have_severity) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!knownSeverity(value)) return error.InvalidClaimsReport;
            severity = try gpa.dupe(u8, value);
            have_severity = true;
        } else if (std.mem.eql(u8, key, "subject")) {
            if (have_subject) return error.InvalidClaimsReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidClaimsReport,
            }
            subject = try parseSubjectAfterBegin(gpa, reader);
            have_subject = true;
        } else if (std.mem.eql(u8, key, "domain") or
            std.mem.eql(u8, key, "confidence") or
            std.mem.eql(u8, key, "owner") or
            std.mem.eql(u8, key, "source_location") or
            std.mem.eql(u8, key, "output_location") or
            std.mem.eql(u8, key, "configuration_location") or
            std.mem.eql(u8, key, "evidence") or
            std.mem.eql(u8, key, "remediation") or
            std.mem.eql(u8, key, "fixability"))
        {
            try skipJsonValue(reader);
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_code or !have_severity or !have_subject) return error.InvalidClaimsReport;
    return .{ .code = code, .severity = severity, .subject = subject };
}

fn parseScopeAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!Scope {
    var scope = Scope{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .subject_sha256 = undefined,
        .supporting_statuses = &.{},
        .supporting_kinds = &.{},
        .supporting_sha256 = undefined,
    };
    errdefer freeScopeArrays(gpa, scope);
    var have_subject_statuses = false;
    var have_subject_kinds = false;
    var have_subject_sha256 = false;
    var have_supporting_statuses = false;
    var have_supporting_kinds = false;
    var have_supporting_sha256 = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidChecksReport;

        if (std.mem.eql(u8, key, "subject_statuses")) {
            if (have_subject_statuses) return error.InvalidChecksReport;
            scope.subject_statuses = try readStringArray(gpa, reader);
            have_subject_statuses = true;
        } else if (std.mem.eql(u8, key, "subject_kinds")) {
            if (have_subject_kinds) return error.InvalidChecksReport;
            scope.subject_kinds = try readStringArray(gpa, reader);
            have_subject_kinds = true;
        } else if (std.mem.eql(u8, key, "subject_sha256")) {
            if (have_subject_sha256) return error.InvalidChecksReport;
            scope.subject_sha256 = try readJsonDigest(gpa, reader);
            have_subject_sha256 = true;
        } else if (std.mem.eql(u8, key, "supporting_statuses")) {
            if (have_supporting_statuses) return error.InvalidChecksReport;
            scope.supporting_statuses = try readStringArray(gpa, reader);
            have_supporting_statuses = true;
        } else if (std.mem.eql(u8, key, "supporting_kinds")) {
            if (have_supporting_kinds) return error.InvalidChecksReport;
            scope.supporting_kinds = try readStringArray(gpa, reader);
            have_supporting_kinds = true;
        } else if (std.mem.eql(u8, key, "supporting_sha256")) {
            if (have_supporting_sha256) return error.InvalidChecksReport;
            scope.supporting_sha256 = try readJsonDigest(gpa, reader);
            have_supporting_sha256 = true;
        } else {
            return error.InvalidChecksReport;
        }
    }

    if (!have_subject_statuses or !have_subject_kinds or !have_subject_sha256 or
        !have_supporting_statuses or !have_supporting_kinds or !have_supporting_sha256)
        return error.InvalidChecksReport;
    for (scope.subject_statuses) |value| if (!knownStatus(value)) return error.InvalidChecksReport;
    for (scope.subject_kinds) |value| if (!knownKind(value)) return error.InvalidChecksReport;
    for (scope.supporting_statuses) |value| if (!knownStatus(value)) return error.InvalidChecksReport;
    for (scope.supporting_kinds) |value| if (!knownKind(value)) return error.InvalidChecksReport;
    return scope;
}

fn parseCheckAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!ParsedCheck {
    var check: ParsedCheck = undefined;
    check.id = &.{};
    check.eligible = false;
    check.ran = false;
    check.status = &.{};
    check.coverage = &.{};
    check.scope = Scope{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .subject_sha256 = undefined,
        .supporting_statuses = &.{},
        .supporting_kinds = &.{},
        .supporting_sha256 = undefined,
    };
    errdefer {
        gpa.free(check.id);
        gpa.free(check.status);
        gpa.free(check.coverage);
        // Free every scope element and every backing slice so a mid-parse
        // failure (e.g. on a tampered evidence block) never leaks under a
        // general-purpose allocator.
        freeScopeArrays(gpa, check.scope);
    }

    var have_id = false;
    var have_eligible = false;
    var have_ran = false;
    var have_status = false;
    var have_coverage = false;
    var have_scope = false;
    var have_counts = false;
    var have_offset = false;
    var counts_eligible: usize = 0;
    var counts_checked: usize = 0;
    var finding_count: usize = 0;
    var finding_offset: usize = 0;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidChecksReport;

        if (std.mem.eql(u8, key, "id")) {
            if (have_id) return error.InvalidChecksReport;
            check.id = try readJsonString(gpa, reader);
            have_id = true;
        } else if (std.mem.eql(u8, key, "eligible")) {
            if (have_eligible) return error.InvalidChecksReport;
            check.eligible = try readJsonBool(reader);
            have_eligible = true;
        } else if (std.mem.eql(u8, key, "ran")) {
            if (have_ran) return error.InvalidChecksReport;
            check.ran = try readJsonBool(reader);
            have_ran = true;
        } else if (std.mem.eql(u8, key, "status")) {
            if (have_status) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!knownCheckStatus(value)) return error.InvalidChecksReport;
            check.status = try gpa.dupe(u8, value);
            have_status = true;
        } else if (std.mem.eql(u8, key, "coverage")) {
            if (have_coverage) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!knownCoverage(value)) return error.InvalidChecksReport;
            check.coverage = try gpa.dupe(u8, value);
            have_coverage = true;
        } else if (std.mem.eql(u8, key, "scope")) {
            if (have_scope) return error.InvalidChecksReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidChecksReport,
            }
            check.scope = try parseScopeAfterBegin(gpa, reader);
            have_scope = true;
        } else if (std.mem.eql(u8, key, "counts")) {
            if (have_counts) return error.InvalidChecksReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidChecksReport,
            }
            var have_eligible_count = false;
            var have_checked_count = false;
            var have_finding_count = false;
            while (true) {
                const count_key_token = try nextJsonAllocToken(gpa, reader, 4096);
                switch (count_key_token) {
                    .object_end => break,
                    else => {},
                }
                defer freeJsonToken(gpa, count_key_token);
                const count_key = jsonTokenText(count_key_token) orelse return error.InvalidChecksReport;
                if (std.mem.eql(u8, count_key, "eligible")) {
                    if (have_eligible_count) return error.InvalidChecksReport;
                    const value = try readJsonInteger(gpa, reader);
                    if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
                    counts_eligible = @intCast(value);
                    have_eligible_count = true;
                } else if (std.mem.eql(u8, count_key, "checked")) {
                    if (have_checked_count) return error.InvalidChecksReport;
                    const value = try readJsonInteger(gpa, reader);
                    if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
                    counts_checked = @intCast(value);
                    have_checked_count = true;
                } else if (std.mem.eql(u8, count_key, "findings")) {
                    if (have_finding_count) return error.InvalidChecksReport;
                    const value = try readJsonInteger(gpa, reader);
                    if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
                    finding_count = @intCast(value);
                    have_finding_count = true;
                } else {
                    return error.InvalidChecksReport;
                }
            }
            if (!have_eligible_count or !have_checked_count or !have_finding_count)
                return error.InvalidChecksReport;
            have_counts = true;
        } else if (std.mem.eql(u8, key, "finding_offset")) {
            if (have_offset) return error.InvalidChecksReport;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
            finding_offset = @intCast(value);
            have_offset = true;
        } else {
            return error.InvalidChecksReport;
        }
    }

    if (!have_id or !have_eligible or !have_ran or !have_status or !have_coverage or
        !have_scope or !have_counts or !have_offset)
        return error.InvalidChecksReport;

    check.counts_eligible = counts_eligible;
    check.counts_checked = counts_checked;
    check.counts_findings = finding_count;
    check.finding_offset = finding_offset;
    return check;
}

fn hasDuplicate(values: []const []const u8) bool {
    for (values, 0..) |value, index| {
        for (values[index + 1 ..]) |other| {
            if (std.mem.eql(u8, value, other)) return true;
        }
    }
    return false;
}

/// The complete publication-check state matrix: status/coverage agreement,
/// `checked <= eligible`, fixed eligibility for the two always-selected
/// checks, and the rendered-search selection rules. Selector arrays must be
/// duplicate-free (the checks layer emits fixed canonical arrays).
fn validateCheckState(checks: *const [3]ParsedCheck) Error!void {
    for (checks) |check| {
        const coverage_agrees = if (std.mem.eql(u8, check.status, "passed") or
            std.mem.eql(u8, check.status, "failed"))
            std.mem.eql(u8, check.coverage, "complete")
        else if (std.mem.eql(u8, check.status, "incomplete"))
            std.mem.eql(u8, check.coverage, "incomplete")
        else if (std.mem.eql(u8, check.status, "not-applicable"))
            std.mem.eql(u8, check.coverage, "not-applicable")
        else
            false;
        if (!coverage_agrees) return error.InvalidChecksReport;
        if (check.counts_checked > check.counts_eligible) return error.InvalidChecksReport;
        if (hasDuplicate(check.scope.subject_statuses) or
            hasDuplicate(check.scope.subject_kinds) or
            hasDuplicate(check.scope.supporting_statuses) or
            hasDuplicate(check.scope.supporting_kinds))
            return error.InvalidChecksReport;
    }

    // artifact-integrity and rendered-html are always selected, eligible, and
    // run, and may never be not-applicable.
    for (checks[0..2]) |check| {
        if (!check.eligible or !check.ran) return error.InvalidChecksReport;
        if (std.mem.eql(u8, check.status, "not-applicable")) return error.InvalidChecksReport;
    }

    const search = checks[2];
    if (search.eligible) {
        if (!search.ran) return error.InvalidChecksReport;
        if (std.mem.eql(u8, search.status, "not-applicable")) return error.InvalidChecksReport;
        if (search.counts_eligible != 1) return error.InvalidChecksReport;
    } else {
        if (search.ran) return error.InvalidChecksReport;
        if (!std.mem.eql(u8, search.status, "not-applicable")) return error.InvalidChecksReport;
        if (search.counts_eligible != 0 or search.counts_checked != 0 or search.counts_findings != 0)
            return error.InvalidChecksReport;
    }
}

fn scopesEqual(a: Scope, b: SelectorScope) bool {
    if (a.subject_statuses.len != b.subject_statuses.len or
        a.subject_kinds.len != b.subject_kinds.len or
        a.supporting_statuses.len != b.supporting_statuses.len or
        a.supporting_kinds.len != b.supporting_kinds.len)
        return false;
    for (a.subject_statuses, b.subject_statuses) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    for (a.subject_kinds, b.subject_kinds) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    for (a.supporting_statuses, b.supporting_statuses) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    for (a.supporting_kinds, b.supporting_kinds) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Full publication-claim evidence parity against the parsed checks report:
/// exact positional check binding, evidence check status/coverage/counts and
/// scope digests equal the bound check, `checks_report_sha256` equal to the
/// exact current checks input digest, claim scope arrays equal the bound check
/// scope arrays, and claim status/reason follow the publication-claims mapping.
fn validateClaimsAgainstChecks(
    parsed_checks: *const ParsedChecks,
    checks_binding: FileBinding,
    parsed_claims: *const ParsedClaims,
) Error!void {
    for (parsed_claims.claims, 0..) |claim, index| {
        const check = parsed_checks.checks[index];
        if (!std.mem.eql(u8, claim.evidence.check_id, check.id)) return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, claim.evidence.check_status, check.status)) return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, claim.evidence.coverage, check.coverage)) return error.InvalidClaimsReport;
        if (claim.evidence.counts.eligible != check.counts_eligible or
            claim.evidence.counts.checked != check.counts_checked or
            claim.evidence.counts.findings != check.counts_findings)
            return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, &claim.evidence.subject_sha256, &check.scope.subject_sha256) or
            !std.mem.eql(u8, &claim.evidence.supporting_sha256, &check.scope.supporting_sha256))
            return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, &claim.evidence.checks_report_sha256, &checks_binding.sha256))
            return error.InvalidClaimsReport;
        if (!scopesEqual(check.scope, claim.scope)) return error.InvalidClaimsReport;

        const mapping = publication_claims.deriveStatus(check.status) orelse
            return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, claim.status, mapping.status)) return error.InvalidClaimsReport;
        if (mapping.reason == null) {
            if (claim.evidence.reason != null) return error.InvalidClaimsReport;
        } else {
            const actual = claim.evidence.reason orelse return error.InvalidClaimsReport;
            if (!std.mem.eql(u8, actual, mapping.reason.?)) return error.InvalidClaimsReport;
        }
    }
}

/// Apply the parsed subject/supporting selectors to the canonical inventory,
/// recompute both scope digests with the publication-check record encoding,
/// and require `counts.eligible` to equal the selected subject count. Uses
/// inventory metadata only; never rereads payloads.
fn validateChecksAgainstInventory(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    checks: *const [3]ParsedCheck,
) Error!void {
    for (checks) |check| {
        var subject_selected: usize = 0;
        for (inventory.records) |record| {
            if (selected(record, check.scope.subject_statuses, check.scope.subject_kinds))
                subject_selected += 1;
        }
        if (subject_selected != check.counts_eligible) return error.InvalidChecksReport;
        const subject_digest = try publication_checks.scopeDigest(
            gpa,
            inventory,
            check.scope.subject_statuses,
            check.scope.subject_kinds,
        );
        if (!std.mem.eql(u8, &subject_digest, &check.scope.subject_sha256))
            return error.InvalidChecksReport;

        const supporting_digest = try publication_checks.scopeDigest(
            gpa,
            inventory,
            check.scope.supporting_statuses,
            check.scope.supporting_kinds,
        );
        if (!std.mem.eql(u8, &supporting_digest, &check.scope.supporting_sha256))
            return error.InvalidChecksReport;
    }

    // A selected rendered-search check must have exactly one eligible search
    // artifact; the subject selector application above already requires its
    // eligible count to be 1, and the state matrix requires eligible=true. The
    // selected subject set must therefore resolve to exactly one committed
    // rendered-search record.
    if (checks[2].eligible) {
        var search_selected: usize = 0;
        for (inventory.records) |record| {
            if (selected(record, checks[2].scope.subject_statuses, checks[2].scope.subject_kinds))
                search_selected += 1;
        }
        if (search_selected != 1) return error.InvalidChecksReport;
    }
}

/// Shared artifact-binding parser. `fail_error` lets the checks stream surface
/// failures as `InvalidChecksReport` while the claims stream surfaces the same
/// malformed binding as `InvalidClaimsReport` (Greptile's remap contract).
fn parseArtifactsBindingAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_target: []const u8,
    fail_error: Error,
) Error!struct { binding: FileBinding, artifact_count: usize } {
    var have_path = false;
    var have_bytes = false;
    var have_sha256 = false;
    var have_format = false;
    var have_version = false;
    var have_target = false;
    var have_artifact_count = false;
    var binding: FileBinding = undefined;
    var artifact_count: usize = 0;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return fail_error;

        if (std.mem.eql(u8, key, "path")) {
            if (have_path) return fail_error;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, artifact_inventory.output_path)) return fail_error;
            have_path = true;
        } else if (std.mem.eql(u8, key, "bytes")) {
            if (have_bytes) return fail_error;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return fail_error;
            binding.bytes = @intCast(value);
            have_bytes = true;
        } else if (std.mem.eql(u8, key, "sha256")) {
            if (have_sha256) return fail_error;
            binding.sha256 = try readJsonDigest(gpa, reader);
            have_sha256 = true;
        } else if (std.mem.eql(u8, key, "format")) {
            if (have_format) return fail_error;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, artifact_inventory.artifact_format)) return fail_error;
            have_format = true;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (have_version) return fail_error;
            if (try readJsonInteger(gpa, reader) != artifact_inventory.schema_version)
                return fail_error;
            have_version = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return fail_error;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (value.len == 0 or !std.mem.eql(u8, value, expected_target))
                return fail_error;
            have_target = true;
        } else if (std.mem.eql(u8, key, "artifact_count")) {
            if (have_artifact_count) return fail_error;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return fail_error;
            artifact_count = @intCast(value);
            have_artifact_count = true;
        } else {
            return fail_error;
        }
    }

    if (!have_path or !have_bytes or !have_sha256 or !have_format or
        !have_version or !have_target or !have_artifact_count)
        return fail_error;
    return .{ .binding = binding, .artifact_count = artifact_count };
}

fn parseChecksBindingAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_target: []const u8,
) Error!struct { binding: FileBinding, check_count: usize, finding_count: usize } {
    var have_path = false;
    var have_bytes = false;
    var have_sha256 = false;
    var have_format = false;
    var have_version = false;
    var have_target = false;
    var have_check_count = false;
    var have_finding_count = false;
    var binding: FileBinding = undefined;
    var check_count: usize = 0;
    var finding_count: usize = 0;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "path")) {
            if (have_path) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, publication_checks.output_path)) return error.InvalidClaimsReport;
            have_path = true;
        } else if (std.mem.eql(u8, key, "bytes")) {
            if (have_bytes) return error.InvalidClaimsReport;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidClaimsReport;
            binding.bytes = @intCast(value);
            have_bytes = true;
        } else if (std.mem.eql(u8, key, "sha256")) {
            if (have_sha256) return error.InvalidClaimsReport;
            binding.sha256 = try readJsonDigest(gpa, reader);
            have_sha256 = true;
        } else if (std.mem.eql(u8, key, "format")) {
            if (have_format) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, publication_checks.report_format)) return error.InvalidClaimsReport;
            have_format = true;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (have_version) return error.InvalidClaimsReport;
            if (try readJsonInteger(gpa, reader) != publication_checks.schema_version)
                return error.InvalidClaimsReport;
            have_version = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (value.len == 0 or !std.mem.eql(u8, value, expected_target))
                return error.InvalidClaimsReport;
            have_target = true;
        } else if (std.mem.eql(u8, key, "check_count")) {
            if (have_check_count) return error.InvalidClaimsReport;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidClaimsReport;
            check_count = @intCast(value);
            have_check_count = true;
        } else if (std.mem.eql(u8, key, "finding_count")) {
            if (have_finding_count) return error.InvalidClaimsReport;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidClaimsReport;
            finding_count = @intCast(value);
            have_finding_count = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_path or !have_bytes or !have_sha256 or !have_format or
        !have_version or !have_target or !have_check_count or !have_finding_count)
        return error.InvalidClaimsReport;
    return .{ .binding = binding, .check_count = check_count, .finding_count = finding_count };
}

fn parseClaimScopeAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!SelectorScope {
    var scope = SelectorScope{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .supporting_statuses = &.{},
        .supporting_kinds = &.{},
    };
    errdefer freeSelectorScopeArrays(gpa, scope);
    var have_subject_statuses = false;
    var have_subject_kinds = false;
    var have_supporting_statuses = false;
    var have_supporting_kinds = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "subject_statuses")) {
            if (have_subject_statuses) return error.InvalidClaimsReport;
            scope.subject_statuses = try readStringArray(gpa, reader);
            have_subject_statuses = true;
        } else if (std.mem.eql(u8, key, "subject_kinds")) {
            if (have_subject_kinds) return error.InvalidClaimsReport;
            scope.subject_kinds = try readStringArray(gpa, reader);
            have_subject_kinds = true;
        } else if (std.mem.eql(u8, key, "supporting_statuses")) {
            if (have_supporting_statuses) return error.InvalidClaimsReport;
            scope.supporting_statuses = try readStringArray(gpa, reader);
            have_supporting_statuses = true;
        } else if (std.mem.eql(u8, key, "supporting_kinds")) {
            if (have_supporting_kinds) return error.InvalidClaimsReport;
            scope.supporting_kinds = try readStringArray(gpa, reader);
            have_supporting_kinds = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_subject_statuses or !have_subject_kinds or
        !have_supporting_statuses or !have_supporting_kinds)
        return error.InvalidClaimsReport;
    for (scope.subject_statuses) |value| if (!knownStatus(value)) return error.InvalidClaimsReport;
    for (scope.subject_kinds) |value| if (!knownKind(value)) return error.InvalidClaimsReport;
    for (scope.supporting_statuses) |value| if (!knownStatus(value)) return error.InvalidClaimsReport;
    for (scope.supporting_kinds) |value| if (!knownKind(value)) return error.InvalidClaimsReport;
    return scope;
}

fn parseClaimAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_check_id: []const u8,
) Error!ParsedClaim {
    var claim: ParsedClaim = undefined;
    claim.id = &.{};
    claim.statement = &.{};
    claim.status = &.{};
    // Initialize every evidence field to an empty, free-safe state so the
    // errdefer path never frees uninitialized pointers when the claim fails
    // mid-parse (e.g. on a tampered evidence block).
    claim.evidence = .{
        .check_id = &.{},
        .check_status = &.{},
        .coverage = &.{},
        .counts = .{ .eligible = 0, .checked = 0, .findings = 0 },
        .subject_sha256 = undefined,
        .supporting_sha256 = undefined,
        .checks_report_sha256 = undefined,
        .reason = null,
    };
    claim.scope = SelectorScope{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .supporting_statuses = &.{},
        .supporting_kinds = &.{},
    };
    claim.limitation_ids = &.{};
    errdefer freeParsedClaim(gpa, claim);

    var have_id = false;
    var have_statement = false;
    var have_status = false;
    var have_evidence = false;
    var have_scope = false;
    var have_limitation_ids = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "id")) {
            if (have_id) return error.InvalidClaimsReport;
            claim.id = try readJsonString(gpa, reader);
            have_id = true;
        } else if (std.mem.eql(u8, key, "statement")) {
            if (have_statement) return error.InvalidClaimsReport;
            claim.statement = try readJsonString(gpa, reader);
            if (claim.statement.len == 0) return error.InvalidClaimsReport;
            have_statement = true;
        } else if (std.mem.eql(u8, key, "status")) {
            if (have_status) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!containsString(&.{ "verified", "failed", "not-verified" }, value))
                return error.InvalidClaimsReport;
            claim.status = try gpa.dupe(u8, value);
            have_status = true;
        } else if (std.mem.eql(u8, key, "evidence")) {
            if (have_evidence) return error.InvalidClaimsReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidClaimsReport,
            }
            claim.evidence = try parseEvidenceAfterBegin(gpa, reader, expected_check_id);
            have_evidence = true;
        } else if (std.mem.eql(u8, key, "scope")) {
            if (have_scope) return error.InvalidClaimsReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidClaimsReport,
            }
            claim.scope = try parseClaimScopeAfterBegin(gpa, reader);
            have_scope = true;
        } else if (std.mem.eql(u8, key, "limitation_ids")) {
            if (have_limitation_ids) return error.InvalidClaimsReport;
            claim.limitation_ids = try readStringArray(gpa, reader);
            have_limitation_ids = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_id or !have_statement or !have_status or !have_evidence or
        !have_scope or !have_limitation_ids)
        return error.InvalidClaimsReport;
    return claim;
}

fn parseEvidenceAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_check_id: []const u8,
) Error!ParsedClaimEvidence {
    var evidence: ParsedClaimEvidence = undefined;
    evidence.check_id = &.{};
    evidence.check_status = &.{};
    evidence.coverage = &.{};
    evidence.counts = .{ .eligible = 0, .checked = 0, .findings = 0 };
    evidence.subject_sha256 = undefined;
    evidence.supporting_sha256 = undefined;
    evidence.checks_report_sha256 = undefined;
    evidence.reason = null;
    errdefer {
        gpa.free(evidence.check_id);
        gpa.free(evidence.check_status);
        gpa.free(evidence.coverage);
        if (evidence.reason) |value| gpa.free(value);
    }

    var have_check_id = false;
    var have_check_status = false;
    var have_coverage = false;
    var have_counts = false;
    var have_subject_sha256 = false;
    var have_supporting_sha256 = false;
    var have_checks_report_sha256 = false;
    var have_reason = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "check_id")) {
            if (have_check_id) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, expected_check_id)) return error.InvalidClaimsReport;
            evidence.check_id = try gpa.dupe(u8, value);
            have_check_id = true;
        } else if (std.mem.eql(u8, key, "check_status")) {
            if (have_check_status) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!knownCheckStatus(value)) return error.InvalidClaimsReport;
            evidence.check_status = try gpa.dupe(u8, value);
            have_check_status = true;
        } else if (std.mem.eql(u8, key, "coverage")) {
            if (have_coverage) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!knownCoverage(value)) return error.InvalidClaimsReport;
            evidence.coverage = try gpa.dupe(u8, value);
            have_coverage = true;
        } else if (std.mem.eql(u8, key, "counts")) {
            if (have_counts) return error.InvalidClaimsReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidClaimsReport,
            }
            var have_eligible = false;
            var have_checked = false;
            var have_findings = false;
            while (true) {
                const count_key_token = try nextJsonAllocToken(gpa, reader, 4096);
                switch (count_key_token) {
                    .object_end => break,
                    else => {},
                }
                defer freeJsonToken(gpa, count_key_token);
                const count_key = jsonTokenText(count_key_token) orelse return error.InvalidClaimsReport;
                const value = try readJsonInteger(gpa, reader);
                if (value > std.math.maxInt(usize)) return error.InvalidClaimsReport;
                if (std.mem.eql(u8, count_key, "eligible")) {
                    if (have_eligible) return error.InvalidClaimsReport;
                    evidence.counts.eligible = @intCast(value);
                    have_eligible = true;
                } else if (std.mem.eql(u8, count_key, "checked")) {
                    if (have_checked) return error.InvalidClaimsReport;
                    evidence.counts.checked = @intCast(value);
                    have_checked = true;
                } else if (std.mem.eql(u8, count_key, "findings")) {
                    if (have_findings) return error.InvalidClaimsReport;
                    evidence.counts.findings = @intCast(value);
                    have_findings = true;
                } else {
                    return error.InvalidClaimsReport;
                }
            }
            if (!have_eligible or !have_checked or !have_findings) return error.InvalidClaimsReport;
            have_counts = true;
        } else if (std.mem.eql(u8, key, "subject_sha256")) {
            if (have_subject_sha256) return error.InvalidClaimsReport;
            evidence.subject_sha256 = try readJsonDigest(gpa, reader);
            have_subject_sha256 = true;
        } else if (std.mem.eql(u8, key, "supporting_sha256")) {
            if (have_supporting_sha256) return error.InvalidClaimsReport;
            evidence.supporting_sha256 = try readJsonDigest(gpa, reader);
            have_supporting_sha256 = true;
        } else if (std.mem.eql(u8, key, "checks_report_sha256")) {
            if (have_checks_report_sha256) return error.InvalidClaimsReport;
            evidence.checks_report_sha256 = try readJsonDigest(gpa, reader);
            have_checks_report_sha256 = true;
        } else if (std.mem.eql(u8, key, "reason")) {
            if (have_reason) return error.InvalidClaimsReport;
            const token = try nextJsonAllocToken(gpa, reader, 4 * 1024 * 1024);
            defer freeJsonToken(gpa, token);
            switch (token) {
                .null => evidence.reason = null,
                .string => |value| {
                    if (value.len == 0) return error.InvalidClaimsReport;
                    evidence.reason = try gpa.dupe(u8, value);
                },
                .allocated_string => |value| {
                    if (value.len == 0) return error.InvalidClaimsReport;
                    evidence.reason = try gpa.dupe(u8, value);
                },
                else => return error.InvalidClaimsReport,
            }
            have_reason = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_check_id or !have_check_status or !have_coverage or !have_counts or
        !have_subject_sha256 or !have_supporting_sha256 or !have_checks_report_sha256 or
        !have_reason)
        return error.InvalidClaimsReport;
    return evidence;
}

fn parseLimitationAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!ParsedLimitation {
    var limitation: ParsedLimitation = undefined;
    limitation.id = &.{};
    limitation.statement = &.{};
    limitation.applies_to_claims = &.{};
    limitation.source = &.{};
    errdefer freeParsedLimitation(gpa, limitation);

    var have_id = false;
    var have_statement = false;
    var have_applies_to_claims = false;
    var have_source = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "id")) {
            if (have_id) return error.InvalidClaimsReport;
            limitation.id = try readJsonString(gpa, reader);
            have_id = true;
        } else if (std.mem.eql(u8, key, "statement")) {
            if (have_statement) return error.InvalidClaimsReport;
            limitation.statement = try readJsonString(gpa, reader);
            if (limitation.statement.len == 0) return error.InvalidClaimsReport;
            have_statement = true;
        } else if (std.mem.eql(u8, key, "applies_to_claims")) {
            if (have_applies_to_claims) return error.InvalidClaimsReport;
            limitation.applies_to_claims = try readStringArray(gpa, reader);
            have_applies_to_claims = true;
        } else if (std.mem.eql(u8, key, "source")) {
            if (have_source) return error.InvalidClaimsReport;
            limitation.source = try readJsonString(gpa, reader);
            if (limitation.source.len == 0) return error.InvalidClaimsReport;
            have_source = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_id or !have_statement or !have_applies_to_claims or !have_source)
        return error.InvalidClaimsReport;
    return limitation;
}

/// Strictly parse the committed checks report. Canonical check metadata, the
/// subject/supporting selector vocabularies, and the finding metadata are
/// retained; finding bodies beyond code/severity/subject are skipped.
pub fn parseChecksStream(
    gpa: std.mem.Allocator,
    input: *std.Io.Reader,
    expected_target: []const u8,
) Error!ParsedChecks {
    // The shared streaming helpers map scanner failures to
    // InvalidClaimsReport; a failure while reading the checks report must
    // surface as InvalidChecksReport instead.
    return parseChecksStreamInner(gpa, input, expected_target) catch |err| switch (err) {
        error.InvalidClaimsReport => error.InvalidChecksReport,
        else => err,
    };
}

fn parseChecksStreamInner(
    gpa: std.mem.Allocator,
    input: *std.Io.Reader,
    expected_target: []const u8,
) Error!ParsedChecks {
    if (expected_target.len == 0) return error.InvalidChecksReport;
    var reader = std.json.Reader.init(gpa, input);
    defer reader.deinit();

    switch (try nextJsonToken(&reader)) {
        .object_begin => {},
        else => return error.InvalidChecksReport,
    }

    var have_format = false;
    var have_version = false;
    var have_target = false;
    var have_artifact_inventory = false;
    var have_checks = false;
    var have_findings = false;
    var artifact_binding: FileBinding = undefined;
    var artifact_count: usize = 0;
    var checks: [3]ParsedCheck = undefined;
    var checks_filled: usize = 0;
    errdefer for (checks[0..checks_filled]) |*check| freeParsedCheck(gpa, check);
    var findings: std.ArrayList(ParsedFinding) = .empty;
    defer {
        for (findings.items) |finding| freeParsedFinding(gpa, finding);
        findings.deinit(gpa);
    }

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, &reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidChecksReport;

        if (std.mem.eql(u8, key, "format")) {
            if (have_format) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, &reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, publication_checks.report_format)) return error.InvalidChecksReport;
            have_format = true;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (have_version) return error.InvalidChecksReport;
            if (try readJsonInteger(gpa, &reader) != publication_checks.schema_version)
                return error.InvalidChecksReport;
            have_version = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, &reader);
            defer gpa.free(value);
            if (value.len == 0 or !std.mem.eql(u8, value, expected_target)) return error.InvalidChecksReport;
            have_target = true;
        } else if (std.mem.eql(u8, key, "artifact_inventory")) {
            if (have_artifact_inventory) return error.InvalidChecksReport;
            switch (try nextJsonToken(&reader)) {
                .object_begin => {},
                else => return error.InvalidChecksReport,
            }
            const parsed = try parseArtifactsBindingAfterBegin(gpa, &reader, expected_target, error.InvalidChecksReport);
            artifact_binding = parsed.binding;
            artifact_count = parsed.artifact_count;
            have_artifact_inventory = true;
        } else if (std.mem.eql(u8, key, "checks")) {
            if (have_checks) return error.InvalidChecksReport;
            switch (try nextJsonToken(&reader)) {
                .array_begin => {},
                else => return error.InvalidChecksReport,
            }
            while (true) {
                switch (try nextJsonToken(&reader)) {
                    .array_end => break,
                    .object_begin => {
                        if (checks_filled == checks.len) return error.InvalidChecksReport;
                        checks[checks_filled] = try parseCheckAfterBegin(gpa, &reader);
                        checks_filled += 1;
                    },
                    else => return error.InvalidChecksReport,
                }
            }
            if (checks_filled != checks.len) return error.InvalidChecksReport;
            have_checks = true;
        } else if (std.mem.eql(u8, key, "findings")) {
            if (have_findings) return error.InvalidChecksReport;
            switch (try nextJsonToken(&reader)) {
                .array_begin => {},
                else => return error.InvalidChecksReport,
            }
            while (true) {
                switch (try nextJsonToken(&reader)) {
                    .array_end => break,
                    .object_begin => {
                        const finding = try parseFindingAfterBegin(gpa, &reader);
                        errdefer freeParsedFinding(gpa, finding);
                        try findings.append(gpa, finding);
                    },
                    else => return error.InvalidChecksReport,
                }
            }
            have_findings = true;
        } else {
            return error.InvalidChecksReport;
        }
    }

    if (!have_format or !have_version or !have_target or
        !have_artifact_inventory or !have_checks or !have_findings)
        return error.InvalidChecksReport;
    if (try nextJsonToken(&reader) != .end_of_document) return error.InvalidChecksReport;

    for (checks, 0..) |check, index| {
        if (!std.mem.eql(u8, check.id, check_ids[index])) return error.InvalidChecksReport;
    }
    try validateCheckState(&checks);
    if (checks[0].finding_offset != 0) return error.InvalidChecksReport;
    for (checks[1..], 0..) |*check, index| {
        const previous = checks[index];
        const expected_offset = std.math.add(
            usize,
            previous.finding_offset,
            previous.counts_findings,
        ) catch return error.InvalidChecksReport;
        if (check.finding_offset != expected_offset) return error.InvalidChecksReport;
    }
    const last = checks[checks.len - 1];
    const last_end = std.math.add(
        usize,
        last.finding_offset,
        last.counts_findings,
    ) catch return error.InvalidChecksReport;
    if (last_end != findings.items.len) return error.InvalidChecksReport;

    return .{
        .artifact_binding = artifact_binding,
        .artifact_count = artifact_count,
        .checks = checks,
        .findings = try findings.toOwnedSlice(gpa),
    };
}

fn freeScopeArrays(gpa: std.mem.Allocator, scope: Scope) void {
    for (scope.subject_statuses) |value| gpa.free(value);
    gpa.free(scope.subject_statuses);
    for (scope.subject_kinds) |value| gpa.free(value);
    gpa.free(scope.subject_kinds);
    for (scope.supporting_statuses) |value| gpa.free(value);
    gpa.free(scope.supporting_statuses);
    for (scope.supporting_kinds) |value| gpa.free(value);
    gpa.free(scope.supporting_kinds);
}

fn freeSelectorScopeArrays(gpa: std.mem.Allocator, scope: SelectorScope) void {
    for (scope.subject_statuses) |value| gpa.free(value);
    gpa.free(scope.subject_statuses);
    for (scope.subject_kinds) |value| gpa.free(value);
    gpa.free(scope.subject_kinds);
    for (scope.supporting_statuses) |value| gpa.free(value);
    gpa.free(scope.supporting_statuses);
    for (scope.supporting_kinds) |value| gpa.free(value);
    gpa.free(scope.supporting_kinds);
}

fn freeParsedCheck(gpa: std.mem.Allocator, check: *const ParsedCheck) void {
    gpa.free(check.id);
    gpa.free(check.status);
    gpa.free(check.coverage);
    freeScopeArrays(gpa, check.scope);
}

fn freeParsedFinding(gpa: std.mem.Allocator, finding: ParsedFinding) void {
    gpa.free(finding.code);
    gpa.free(finding.severity);
    gpa.free(finding.subject.kind);
    gpa.free(finding.subject.id);
    if (finding.subject.target) |value| gpa.free(value);
}

/// Strictly parse the committed claims report. Root bindings, canonical claim
/// metadata, claim-to-check bindings, and the bidirectional limitation
/// registries are retained; statement and scope prose is skipped.
pub fn parseClaimsStream(
    gpa: std.mem.Allocator,
    input: *std.Io.Reader,
    expected_target: []const u8,
) Error!ParsedClaims {
    if (expected_target.len == 0) return error.InvalidClaimsReport;
    var reader = std.json.Reader.init(gpa, input);
    defer reader.deinit();

    switch (try nextJsonToken(&reader)) {
        .object_begin => {},
        else => return error.InvalidClaimsReport,
    }

    var have_format = false;
    var have_version = false;
    var have_target = false;
    var have_artifact_inventory = false;
    var have_publication_checks = false;
    var have_claims = false;
    var have_limitations = false;
    var artifact_binding: FileBinding = undefined;
    var artifact_count: usize = 0;
    var checks_binding: FileBinding = undefined;
    var check_count: usize = 0;
    var finding_count: usize = 0;
    var claims: [3]ParsedClaim = undefined;
    var claims_filled: usize = 0;
    errdefer for (claims[0..claims_filled]) |claim| freeParsedClaim(gpa, claim);
    var limitations: [6]ParsedLimitation = undefined;
    var limitations_filled: usize = 0;
    errdefer for (limitations[0..limitations_filled]) |limitation| freeParsedLimitation(gpa, limitation);

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, &reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidClaimsReport;

        if (std.mem.eql(u8, key, "format")) {
            if (have_format) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, &reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, publication_claims.report_format)) return error.InvalidClaimsReport;
            have_format = true;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (have_version) return error.InvalidClaimsReport;
            if (try readJsonInteger(gpa, &reader) != publication_claims.schema_version)
                return error.InvalidClaimsReport;
            have_version = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, &reader);
            defer gpa.free(value);
            if (value.len == 0 or !std.mem.eql(u8, value, expected_target)) return error.InvalidClaimsReport;
            have_target = true;
        } else if (std.mem.eql(u8, key, "artifact_inventory")) {
            if (have_artifact_inventory) return error.InvalidClaimsReport;
            switch (try nextJsonToken(&reader)) {
                .object_begin => {},
                else => return error.InvalidClaimsReport,
            }
            const parsed = try parseArtifactsBindingAfterBegin(gpa, &reader, expected_target, error.InvalidClaimsReport);
            artifact_binding = parsed.binding;
            artifact_count = parsed.artifact_count;
            have_artifact_inventory = true;
        } else if (std.mem.eql(u8, key, "publication_checks")) {
            if (have_publication_checks) return error.InvalidClaimsReport;
            switch (try nextJsonToken(&reader)) {
                .object_begin => {},
                else => return error.InvalidClaimsReport,
            }
            const parsed = try parseChecksBindingAfterBegin(gpa, &reader, expected_target);
            checks_binding = parsed.binding;
            check_count = parsed.check_count;
            finding_count = parsed.finding_count;
            have_publication_checks = true;
        } else if (std.mem.eql(u8, key, "claims")) {
            if (have_claims) return error.InvalidClaimsReport;
            switch (try nextJsonToken(&reader)) {
                .array_begin => {},
                else => return error.InvalidClaimsReport,
            }
            while (true) {
                switch (try nextJsonToken(&reader)) {
                    .array_end => break,
                    .object_begin => {
                        if (claims_filled == claims.len) return error.InvalidClaimsReport;
                        claims[claims_filled] = try parseClaimAfterBegin(gpa, &reader, check_ids[claims_filled]);
                        claims_filled += 1;
                    },
                    else => return error.InvalidClaimsReport,
                }
            }
            if (claims_filled != claims.len) return error.InvalidClaimsReport;
            have_claims = true;
        } else if (std.mem.eql(u8, key, "limitations")) {
            if (have_limitations) return error.InvalidClaimsReport;
            switch (try nextJsonToken(&reader)) {
                .array_begin => {},
                else => return error.InvalidClaimsReport,
            }
            while (true) {
                switch (try nextJsonToken(&reader)) {
                    .array_end => break,
                    .object_begin => {
                        if (limitations_filled == limitations.len) return error.InvalidClaimsReport;
                        limitations[limitations_filled] = try parseLimitationAfterBegin(gpa, &reader);
                        limitations_filled += 1;
                    },
                    else => return error.InvalidClaimsReport,
                }
            }
            if (limitations_filled != limitations.len) return error.InvalidClaimsReport;
            have_limitations = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_format or !have_version or !have_target or
        !have_artifact_inventory or !have_publication_checks or
        !have_claims or !have_limitations)
        return error.InvalidClaimsReport;
    if (try nextJsonToken(&reader) != .end_of_document) return error.InvalidClaimsReport;

    for (claims, 0..) |claim, index| {
        if (!std.mem.eql(u8, claim.id, claim_ids[index])) return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, claim.statement, publication_claims.claim_statements[index]))
            return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, claim.evidence.check_id, check_ids[index])) return error.InvalidClaimsReport;
        if (claim.limitation_ids.len != claim_limitation_ids[index].len) return error.InvalidClaimsReport;
        for (claim.limitation_ids, claim_limitation_ids[index]) |actual, expected| {
            if (!std.mem.eql(u8, actual, expected)) return error.InvalidClaimsReport;
        }
    }
    for (limitations, 0..) |limitation, index| {
        if (!std.mem.eql(u8, limitation.id, limitation_ids[index])) return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, limitation.statement, publication_claims.limitation_rows[index].statement))
            return error.InvalidClaimsReport;
        if (!std.mem.eql(u8, limitation.source, publication_claims.limitation_rows[index].source))
            return error.InvalidClaimsReport;
        if (limitation.applies_to_claims.len != publication_claims.limitation_rows[index].applies_to_claims.len)
            return error.InvalidClaimsReport;
        for (limitation.applies_to_claims, publication_claims.limitation_rows[index].applies_to_claims) |actual, expected| {
            if (!std.mem.eql(u8, actual, expected)) return error.InvalidClaimsReport;
        }
    }
    // Bidirectional agreement between claim rows and limitation rows: every
    // claim limitation reference resolves to a limitation that lists the
    // claim, and every limitation applicability reference resolves to a claim
    // that lists the limitation. Both directions are checked from the parsed
    // arrays, not just from the fixed registry constants.
    for (claims, 0..) |claim, claim_index| {
        for (claim.limitation_ids) |limitation_id| {
            const limitation_index = indexOfString(&limitation_ids, limitation_id) orelse
                return error.InvalidClaimsReport;
            if (!containsString(limitations[limitation_index].applies_to_claims, claim_ids[claim_index]))
                return error.InvalidClaimsReport;
        }
    }
    for (limitations, 0..) |limitation, limitation_index| {
        for (limitation.applies_to_claims) |claim_id| {
            const claim_index = indexOfString(&claim_ids, claim_id) orelse
                return error.InvalidClaimsReport;
            if (!containsString(claims[claim_index].limitation_ids, limitation_ids[limitation_index]))
                return error.InvalidClaimsReport;
        }
    }

    return .{
        .artifact_binding = artifact_binding,
        .artifact_count = artifact_count,
        .checks_binding = checks_binding,
        .check_count = check_count,
        .finding_count = finding_count,
        .claims = claims,
        .limitations = limitations,
    };
}

fn freeParsedClaim(gpa: std.mem.Allocator, claim: ParsedClaim) void {
    gpa.free(claim.id);
    gpa.free(claim.statement);
    gpa.free(claim.status);
    gpa.free(claim.evidence.check_id);
    gpa.free(claim.evidence.check_status);
    gpa.free(claim.evidence.coverage);
    if (claim.evidence.reason) |value| gpa.free(value);
    for (claim.scope.subject_statuses) |value| gpa.free(value);
    gpa.free(claim.scope.subject_statuses);
    for (claim.scope.subject_kinds) |value| gpa.free(value);
    gpa.free(claim.scope.subject_kinds);
    for (claim.scope.supporting_statuses) |value| gpa.free(value);
    gpa.free(claim.scope.supporting_statuses);
    for (claim.scope.supporting_kinds) |value| gpa.free(value);
    gpa.free(claim.scope.supporting_kinds);
    for (claim.limitation_ids) |value| gpa.free(value);
    gpa.free(claim.limitation_ids);
}

fn freeParsedLimitation(gpa: std.mem.Allocator, limitation: ParsedLimitation) void {
    gpa.free(limitation.id);
    gpa.free(limitation.statement);
    for (limitation.applies_to_claims) |value| gpa.free(value);
    gpa.free(limitation.applies_to_claims);
    gpa.free(limitation.source);
}

fn indexOfString(values: []const []const u8, wanted: []const u8) ?usize {
    for (values, 0..) |value, index| {
        if (std.mem.eql(u8, value, wanted)) return index;
    }
    return null;
}

/// One no-follow open per evidence input. The exact same opened regular-file
/// handle is read twice: a first streaming pass counts and hashes every byte,
/// then the handle is rewound and the exact same byte stream is handed to the
/// streaming JSON parser. A path replaced after the open can never mix
/// evidence versions, and the bytes counted and hashed are exactly the bytes
/// parsed.
const EvidenceInput = struct {
    file: Io.File = undefined,
    pass1_buffer: [64 * 1024]u8 = undefined,
    pass1: Io.File.Reader = undefined,
    digest: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    count: usize = 0,
    pass2_buffer: [64 * 1024]u8 = undefined,
    pass2: Io.File.Reader = undefined,

    fn open(self: *EvidenceInput, io: Io, root: Io.Dir, path: []const u8, missing_error: Error) Error!void {
        self.* = .{};
        self.file = publication_checks.openFileNoFollow(io, root, path) catch
            return missing_error;
        self.pass1 = self.file.readerStreaming(io, &self.pass1_buffer);
    }

    fn hashPass(self: *EvidenceInput, fail_error: Error) Error!void {
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = self.pass1.interface.readSliceShort(&chunk) catch
                return fail_error;
            if (n == 0) break;
            self.digest.update(chunk[0..n]);
            self.count = std.math.add(usize, self.count, n) catch return fail_error;
        }
    }

    fn rewindForParse(self: *EvidenceInput, io: Io, fail_error: Error) Error!void {
        io.vtable.fileSeekTo(io.userdata, self.file, 0) catch
            return fail_error;
        self.pass2 = self.file.readerStreaming(io, &self.pass2_buffer);
    }

    fn close(self: *EvidenceInput, io: Io) void {
        self.file.close(io);
    }

    fn finish(self: *EvidenceInput) FileBinding {
        var digest: [32]u8 = undefined;
        self.digest.final(&digest);
        return .{ .bytes = self.count, .sha256 = cache.hexDigest(digest) };
    }
};

const NodeKind = enum {
    target,
    artifact,
    check,
    finding,
    claim,
    limitation,

    fn name(self: NodeKind) []const u8 {
        return switch (self) {
            .target => "target",
            .artifact => "artifact",
            .check => "check",
            .finding => "finding",
            .claim => "claim",
            .limitation => "limitation",
        };
    }
};

const EdgeKind = enum {
    target_owns_artifact,
    artifact_subject_of_check,
    artifact_supports_check,
    check_reported_finding,
    check_supports_claim,
    claim_limited_by,

    fn name(self: EdgeKind) []const u8 {
        return switch (self) {
            .target_owns_artifact => "target-owns-artifact",
            .artifact_subject_of_check => "artifact-subject-of-check",
            .artifact_supports_check => "artifact-supports-check",
            .check_reported_finding => "check-reported-finding",
            .check_supports_claim => "check-supports-claim",
            .claim_limited_by => "claim-limited-by",
        };
    }
};

const Node = struct {
    kind: NodeKind,
    id: []const u8,
};

const Edge = struct {
    kind: EdgeKind,
    from: []const u8,
    to: []const u8,
};

fn selected(
    record: artifact_inventory.Record,
    statuses: []const []const u8,
    kinds: []const []const u8,
) bool {
    if (statuses.len == 0 and kinds.len == 0) return false;
    return (statuses.len == 0 or containsString(statuses, record.status.name())) and
        (kinds.len == 0 or containsString(kinds, record.kind.name()));
}

/// Build `prefix ++ value` without `allocPrint`, so the emitter discipline's
/// audited-encoder rule (which forbids `allocPrint` in emitter modules) stays
/// satisfied. `std.mem.concat` only returns Allocator errors.
fn concatId(gpa: std.mem.Allocator, prefix: []const u8, value: []const u8) Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ prefix, value });
}

/// Build `finding:{check_id}:{ordinal}` without `allocPrint`.
fn findingNodeId(gpa: std.mem.Allocator, check_id: []const u8, ordinal: usize) Error![]u8 {
    var buffer: [64]u8 = undefined;
    const ordinal_text = std.fmt.bufPrint(&buffer, "{d}", .{ordinal}) catch return error.OutOfMemory;
    return std.mem.concat(gpa, u8, &.{ "finding:", check_id, ":", ordinal_text });
}

fn findingOwningCheck(
    checks: *const [3]ParsedCheck,
    finding_index: usize,
) ?usize {
    for (checks, 0..) |check, check_index| {
        const start = check.finding_offset;
        const end = std.math.add(usize, start, check.counts_findings) catch continue;
        if (finding_index >= start and finding_index < end) return check_index;
    }
    return null;
}

/// Free every node ID in the slice, skipping the static "target" literal,
/// without freeing the backing slice itself.
fn freeNodes(gpa: std.mem.Allocator, nodes: []const Node) void {
    for (nodes) |node| {
        if (!std.mem.eql(u8, node.id, "target")) gpa.free(@constCast(node.id));
    }
}

/// Free every edge endpoint string in the slice, skipping the static
/// "target" literal on `from`, without freeing the backing slice itself.
fn freeEdges(gpa: std.mem.Allocator, edges: []const Edge) void {
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.from, "target")) gpa.free(@constCast(edge.from));
        gpa.free(@constCast(edge.to));
    }
}

fn buildNodesAndEdges(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
) Error!struct { nodes: []Node, edges: []Edge } {
    const checks = &parsed_checks.checks;
    const findings = parsed_checks.findings;
    const claims = &parsed_claims.claims;
    const limitations = &parsed_claims.limitations;

    // Node count: 1 target + artifacts + 3 checks + findings + 3 claims + 6 limitations.
    const node_count = 1 + inventory.records.len + 3 + findings.len + 3 + 6;
    var nodes: std.ArrayList(Node) = .empty;
    // If any later node allocation fails, free every ID already owned by the
    // node list before deinitializing its backing storage.
    errdefer {
        freeNodes(gpa, nodes.items);
        nodes.deinit(gpa);
    }
    try nodes.ensureTotalCapacity(gpa, node_count);

    nodes.appendAssumeCapacity(.{ .kind = .target, .id = "target" });
    for (inventory.records) |record| {
        const id = try concatId(gpa, "artifact:", record.path);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .artifact, .id = id });
    }
    for (checks) |check| {
        const id = try concatId(gpa, "check:", check.id);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .check, .id = id });
    }
    for (findings, 0..) |_, finding_index| {
        const check_index = findingOwningCheck(checks, finding_index) orelse
            return error.InvalidChecksReport;
        const check_id = checks[check_index].id;
        const ordinal = finding_index - checks[check_index].finding_offset;
        const id = try findingNodeId(gpa, check_id, ordinal);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .finding, .id = id });
    }
    for (claims) |claim| {
        const id = try concatId(gpa, "claim:", claim.id);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .claim, .id = id });
    }
    for (limitations) |limitation| {
        const id = try concatId(gpa, "limitation:", limitation.id);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .limitation, .id = id });
    }
    if (nodes.items.len != node_count) return error.InvalidChecksReport;

    // Edges in canonical kind order.
    var edges: std.ArrayList(Edge) = .empty;
    // If any later edge fails, release every owned from/to string already
    // appended before deinitializing the edge list.
    errdefer {
        freeEdges(gpa, edges.items);
        edges.deinit(gpa);
    }

    // 1. target-owns-artifact, one edge per inventory record in inventory
    // order. `from` is the static "target" literal and must not be freed.
    for (inventory.records) |record| {
        const to = try concatId(gpa, "artifact:", record.path);
        errdefer gpa.free(to);
        try edges.append(gpa, .{ .kind = .target_owns_artifact, .from = "target", .to = to });
    }

    // 2. artifact-subject-of-check: all subject edges first, artifact index
    // then fixed check index (edge-kind-major canonical order).
    for (inventory.records) |record| {
        for (checks) |check| {
            if (selected(record, check.scope.subject_statuses, check.scope.subject_kinds)) {
                const from = try concatId(gpa, "artifact:", record.path);
                errdefer gpa.free(from);
                const to = try concatId(gpa, "check:", check.id);
                errdefer gpa.free(to);
                try edges.append(gpa, .{ .kind = .artifact_subject_of_check, .from = from, .to = to });
            }
        }
    }

    // 3. artifact-supports-check: all supporting edges after every subject
    // edge, artifact index then fixed check index.
    for (inventory.records) |record| {
        for (checks) |check| {
            if (selected(record, check.scope.supporting_statuses, check.scope.supporting_kinds)) {
                const from = try concatId(gpa, "artifact:", record.path);
                errdefer gpa.free(from);
                const to = try concatId(gpa, "check:", check.id);
                errdefer gpa.free(to);
                try edges.append(gpa, .{ .kind = .artifact_supports_check, .from = from, .to = to });
            }
        }
    }

    // 4. check-reported-finding, source = fixed check index, dest = root
    // finding order.
    for (findings, 0..) |_, finding_index| {
        const check_index = findingOwningCheck(checks, finding_index) orelse
            return error.InvalidChecksReport;
        const check_id = checks[check_index].id;
        const ordinal = finding_index - checks[check_index].finding_offset;
        const from = try concatId(gpa, "check:", check_id);
        errdefer gpa.free(from);
        const to = try findingNodeId(gpa, check_id, ordinal);
        errdefer gpa.free(to);
        try edges.append(gpa, .{ .kind = .check_reported_finding, .from = from, .to = to });
    }

    // 5. check-supports-claim, one edge per fixed claim binding.
    for (claims) |claim| {
        const from = try concatId(gpa, "check:", claim.evidence.check_id);
        errdefer gpa.free(from);
        const to = try concatId(gpa, "claim:", claim.id);
        errdefer gpa.free(to);
        try edges.append(gpa, .{ .kind = .check_supports_claim, .from = from, .to = to });
    }

    // 6. claim-limited-by, claim order first, then each claim's ordered
    // limitation list.
    for (claims) |claim| {
        for (claim.limitation_ids) |limitation_id| {
            const from = try concatId(gpa, "claim:", claim.id);
            errdefer gpa.free(from);
            const to = try concatId(gpa, "limitation:", limitation_id);
            errdefer gpa.free(to);
            try edges.append(gpa, .{ .kind = .claim_limited_by, .from = from, .to = to });
        }
    }

    // Transfer ownership of both completed lists. Each transfer is recorded
    // immediately so a failure on the second transfer releases the first
    // slice; on success the caller owns both.
    const owned_nodes = try nodes.toOwnedSlice(gpa);
    errdefer {
        freeNodes(gpa, owned_nodes);
        gpa.free(owned_nodes);
    }
    const owned_edges = try edges.toOwnedSlice(gpa);
    return .{ .nodes = owned_nodes, .edges = owned_edges };
}

fn nodeKindOf(id: []const u8) ?NodeKind {
    if (std.mem.eql(u8, id, "target")) return .target;
    if (std.mem.startsWith(u8, id, "artifact:")) return .artifact;
    if (std.mem.startsWith(u8, id, "check:")) return .check;
    if (std.mem.startsWith(u8, id, "finding:")) return .finding;
    if (std.mem.startsWith(u8, id, "claim:")) return .claim;
    if (std.mem.startsWith(u8, id, "limitation:")) return .limitation;
    return null;
}

fn edgePermits(edge: Edge, from_kind: NodeKind, to_kind: NodeKind) bool {
    return switch (edge.kind) {
        .target_owns_artifact => from_kind == .target and to_kind == .artifact,
        .artifact_subject_of_check => from_kind == .artifact and to_kind == .check,
        .artifact_supports_check => from_kind == .artifact and to_kind == .check,
        .check_reported_finding => from_kind == .check and to_kind == .finding,
        .check_supports_claim => from_kind == .check and to_kind == .claim,
        .claim_limited_by => from_kind == .claim and to_kind == .limitation,
    };
}

/// Expected canonical node id sequence for the parsed evidence. Mirrors the
/// derivation order so `validateGraph` can prove node order matches the
/// contract rather than trusting the emitted order.
fn expectedNodeIds(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
) Error![][]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    // Every entry is an owned allocation: validateGraph frees each id with
    // gpa, so the literal "target" must be duplicated, not borrowed. If any
    // later append fails, release every string already stored before
    // deinitializing the backing storage.
    errdefer {
        for (ids.items) |id| gpa.free(id);
        ids.deinit(gpa);
    }
    {
        const target_id = try gpa.dupe(u8, "target");
        errdefer gpa.free(target_id);
        try ids.append(gpa, target_id);
    }
    for (inventory.records) |record| {
        const id = try concatId(gpa, "artifact:", record.path);
        errdefer gpa.free(id);
        try ids.append(gpa, id);
    }
    for (parsed_checks.checks) |check| {
        const id = try concatId(gpa, "check:", check.id);
        errdefer gpa.free(id);
        try ids.append(gpa, id);
    }
    for (parsed_checks.findings, 0..) |_, finding_index| {
        const check_index = findingOwningCheck(&parsed_checks.checks, finding_index) orelse
            return error.InvalidChecksReport;
        const check_id = parsed_checks.checks[check_index].id;
        const ordinal = finding_index - parsed_checks.checks[check_index].finding_offset;
        const id = try findingNodeId(gpa, check_id, ordinal);
        errdefer gpa.free(id);
        try ids.append(gpa, id);
    }
    for (parsed_claims.claims) |claim| {
        const id = try concatId(gpa, "claim:", claim.id);
        errdefer gpa.free(id);
        try ids.append(gpa, id);
    }
    for (parsed_claims.limitations) |limitation| {
        const id = try concatId(gpa, "limitation:", limitation.id);
        errdefer gpa.free(id);
        try ids.append(gpa, id);
    }
    return try ids.toOwnedSlice(gpa);
}

/// Expected canonical edge sequence for the parsed evidence, in edge-kind-major
/// order with the contract's source/destination evidence-index ordering.
fn expectedEdges(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
) Error![]Edge {
    var edges: std.ArrayList(Edge) = .empty;
    // Same ownership rules as the builder: every from/to is owned except the
    // static "target" literal, and a failure at any later append releases
    // every endpoint string already stored before the backing storage is
    // deinitialized.
    errdefer {
        freeEdges(gpa, edges.items);
        edges.deinit(gpa);
    }

    for (inventory.records) |record| {
        const to = try concatId(gpa, "artifact:", record.path);
        errdefer gpa.free(to);
        try edges.append(gpa, .{ .kind = .target_owns_artifact, .from = "target", .to = to });
    }
    for (inventory.records) |record| {
        for (parsed_checks.checks) |check| {
            if (selected(record, check.scope.subject_statuses, check.scope.subject_kinds)) {
                const from = try concatId(gpa, "artifact:", record.path);
                errdefer gpa.free(from);
                const to = try concatId(gpa, "check:", check.id);
                errdefer gpa.free(to);
                try edges.append(gpa, .{ .kind = .artifact_subject_of_check, .from = from, .to = to });
            }
        }
    }
    for (inventory.records) |record| {
        for (parsed_checks.checks) |check| {
            if (selected(record, check.scope.supporting_statuses, check.scope.supporting_kinds)) {
                const from = try concatId(gpa, "artifact:", record.path);
                errdefer gpa.free(from);
                const to = try concatId(gpa, "check:", check.id);
                errdefer gpa.free(to);
                try edges.append(gpa, .{ .kind = .artifact_supports_check, .from = from, .to = to });
            }
        }
    }
    for (parsed_checks.findings, 0..) |_, finding_index| {
        const check_index = findingOwningCheck(&parsed_checks.checks, finding_index) orelse
            return error.InvalidChecksReport;
        const check_id = parsed_checks.checks[check_index].id;
        const ordinal = finding_index - parsed_checks.checks[check_index].finding_offset;
        const from = try concatId(gpa, "check:", check_id);
        errdefer gpa.free(from);
        const to = try findingNodeId(gpa, check_id, ordinal);
        errdefer gpa.free(to);
        try edges.append(gpa, .{ .kind = .check_reported_finding, .from = from, .to = to });
    }
    for (parsed_claims.claims) |claim| {
        const from = try concatId(gpa, "check:", claim.evidence.check_id);
        errdefer gpa.free(from);
        const to = try concatId(gpa, "claim:", claim.id);
        errdefer gpa.free(to);
        try edges.append(gpa, .{ .kind = .check_supports_claim, .from = from, .to = to });
    }
    for (parsed_claims.claims) |claim| {
        for (claim.limitation_ids) |limitation_id| {
            const from = try concatId(gpa, "claim:", claim.id);
            errdefer gpa.free(from);
            const to = try concatId(gpa, "limitation:", limitation_id);
            errdefer gpa.free(to);
            try edges.append(gpa, .{ .kind = .claim_limited_by, .from = from, .to = to });
        }
    }
    return try edges.toOwnedSlice(gpa);
}

/// Runtime graph invariants that JSON Schema cannot express. Takes the caller
/// allocator, builds an ID-to-declared-kind map from the actual nodes, and
/// validates: unique node IDs; each node ID pattern agreeing with its declared
/// kind; every edge endpoint resolving to an actual node; permitted edge
/// directions using the declared kinds; unique `(kind, from, to)` tuples;
/// node order and edge order matching the contract; and node/edge
/// cardinalities agreeing with the parsed evidence and derived selections.
fn validateGraph(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
    nodes: []const Node,
    edges: []const Edge,
) Error!void {
    var key_arena = std.heap.ArenaAllocator.init(gpa);
    defer key_arena.deinit();
    const key_gpa = key_arena.allocator();

    var seen_ids: std.StringHashMapUnmanaged(NodeKind) = .empty;
    defer seen_ids.deinit(gpa);
    for (nodes) |node| {
        if (seen_ids.contains(node.id)) return error.InvalidChecksReport;
        const declared = node.kind;
        const patterned = nodeKindOf(node.id) orelse return error.InvalidChecksReport;
        if (declared != patterned) return error.InvalidChecksReport;
        try seen_ids.put(gpa, node.id, declared);
    }

    var seen_tuples: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_tuples.deinit(gpa);
    for (edges) |edge| {
        const from_kind = seen_ids.get(edge.from) orelse return error.InvalidChecksReport;
        const to_kind = seen_ids.get(edge.to) orelse return error.InvalidChecksReport;
        if (!edgePermits(edge, from_kind, to_kind)) return error.InvalidChecksReport;
        const tuple = try std.mem.concat(
            key_gpa,
            u8,
            &.{ edge.kind.name(), "\x00", edge.from, "\x00", edge.to },
        );
        if (seen_tuples.contains(tuple)) return error.InvalidChecksReport;
        try seen_tuples.put(gpa, tuple, {});
    }

    // Canonical order and cardinality against the parsed evidence. Each
    // expected array is built in its own scope with a `defer` that runs on
    // both success and failure, so every allocation is freed exactly once and
    // a later error can never double-free an earlier array. The arena owns
    // only the tuple keys used for uniqueness checks.
    {
        const expected_ids = try expectedNodeIds(gpa, inventory, parsed_checks, parsed_claims);
        defer {
            for (expected_ids) |id| gpa.free(id);
            gpa.free(expected_ids);
        }
        if (expected_ids.len != nodes.len) return error.InvalidChecksReport;
        for (expected_ids, nodes) |expected_id, node| {
            if (!std.mem.eql(u8, expected_id, node.id)) return error.InvalidChecksReport;
        }
    }
    {
        const expected_edge_list = try expectedEdges(gpa, inventory, parsed_checks, parsed_claims);
        defer {
            for (expected_edge_list) |edge| {
                if (!std.mem.eql(u8, edge.from, "target")) gpa.free(@constCast(edge.from));
                gpa.free(@constCast(edge.to));
            }
            gpa.free(expected_edge_list);
        }
        if (expected_edge_list.len != edges.len) return error.InvalidChecksReport;
        for (expected_edge_list, edges) |expected, edge| {
            if (expected.kind != edge.kind or
                !std.mem.eql(u8, expected.from, edge.from) or
                !std.mem.eql(u8, expected.to, edge.to))
                return error.InvalidChecksReport;
        }
    }
}

fn writeInputBlock(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
    binding: FileBinding,
    format: []const u8,
    version: usize,
    target: []const u8,
    count_keys: []const struct { key: []const u8, value: usize },
) !void {
    try out.appendSlice(gpa, "    \"");
    try out.appendSlice(gpa, label);
    try out.appendSlice(gpa, "\": {\n      \"path\": ");
    try json_out.writeString(out, gpa, path);
    try out.appendSlice(gpa, ",\n      \"bytes\": ");
    try json_out.writeUsize(out, gpa, binding.bytes);
    try out.appendSlice(gpa, ",\n      \"sha256\": ");
    try json_out.writeString(out, gpa, &binding.sha256);
    try out.appendSlice(gpa, ",\n      \"format\": ");
    try json_out.writeString(out, gpa, format);
    try out.appendSlice(gpa, ",\n      \"schema_version\": ");
    try json_out.writeUsize(out, gpa, version);
    try out.appendSlice(gpa, ",\n      \"target\": ");
    try json_out.writeString(out, gpa, target);
    for (count_keys) |count_key| {
        try out.appendSlice(gpa, ",\n      \"");
        try out.appendSlice(gpa, count_key.key);
        try out.appendSlice(gpa, "\": ");
        try json_out.writeUsize(out, gpa, count_key.value);
    }
    try out.appendSlice(gpa, "\n    }");
}

fn writeFindingSubject(out: *std.ArrayList(u8), gpa: std.mem.Allocator, subject: ParsedSubject) !void {
    try out.appendSlice(gpa, "{\n          \"kind\": ");
    try json_out.writeString(out, gpa, subject.kind);
    try out.appendSlice(gpa, ",\n          \"id\": ");
    try json_out.writeString(out, gpa, subject.id);
    try out.appendSlice(gpa, ",\n          \"target\": ");
    if (subject.target) |target| {
        try json_out.writeString(out, gpa, target);
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, "\n        }");
}

fn writeNode(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    node: Node,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
    target: []const u8,
) !void {
    try out.appendSlice(gpa, "    {\n      \"kind\": ");
    try json_out.writeString(out, gpa, node.kind.name());
    try out.appendSlice(gpa, ",\n      \"id\": ");
    try json_out.writeString(out, gpa, node.id);
    try out.appendSlice(gpa, ",\n      \"metadata\": {");

    switch (node.kind) {
        .target => {
            try out.appendSlice(gpa, "\n        \"target\": ");
            try json_out.writeString(out, gpa, target);
            try out.appendSlice(gpa, "\n      }");
        },
        .artifact => {
            const artifact_index = artifactIndexOf(inventory, node.id) orelse return error.InvalidChecksReport;
            const record = inventory.records[artifact_index];
            try out.appendSlice(gpa, "\n        \"inventory_index\": ");
            try json_out.writeUsize(out, gpa, artifact_index);
            try out.appendSlice(gpa, ",\n        \"path\": ");
            try json_out.writeString(out, gpa, record.path);
            try out.appendSlice(gpa, ",\n        \"kind\": ");
            try json_out.writeString(out, gpa, record.kind.name());
            try out.appendSlice(gpa, ",\n        \"status\": ");
            try json_out.writeString(out, gpa, record.status.name());
            try out.appendSlice(gpa, ",\n        \"required\": ");
            try json_out.writeBool(out, gpa, record.required);
            try out.appendSlice(gpa, "\n      }");
        },
        .check => {
            const check_index = checkIndexOf(node.id) orelse return error.InvalidChecksReport;
            const check = parsed_checks.checks[check_index];
            try out.appendSlice(gpa, "\n        \"check_index\": ");
            try json_out.writeUsize(out, gpa, check_index);
            try out.appendSlice(gpa, ",\n        \"check_id\": ");
            try json_out.writeString(out, gpa, check.id);
            try out.appendSlice(gpa, ",\n        \"status\": ");
            try json_out.writeString(out, gpa, check.status);
            try out.appendSlice(gpa, ",\n        \"coverage\": ");
            try json_out.writeString(out, gpa, check.coverage);
            try out.appendSlice(gpa, "\n      }");
        },
        .finding => {
            const finding_index = findingIndexOf(&parsed_checks.checks, node.id) orelse return error.InvalidChecksReport;
            const finding = parsed_checks.findings[finding_index];
            const check_index = findingOwningCheck(&parsed_checks.checks, finding_index) orelse
                return error.InvalidChecksReport;
            const check_id = parsed_checks.checks[check_index].id;
            const ordinal = finding_index - parsed_checks.checks[check_index].finding_offset;
            try out.appendSlice(gpa, "\n        \"finding_index\": ");
            try json_out.writeUsize(out, gpa, finding_index);
            try out.appendSlice(gpa, ",\n        \"check_id\": ");
            try json_out.writeString(out, gpa, check_id);
            try out.appendSlice(gpa, ",\n        \"check_finding_index\": ");
            try json_out.writeUsize(out, gpa, ordinal);
            try out.appendSlice(gpa, ",\n        \"code\": ");
            try json_out.writeString(out, gpa, finding.code);
            try out.appendSlice(gpa, ",\n        \"severity\": ");
            try json_out.writeString(out, gpa, finding.severity);
            try out.appendSlice(gpa, ",\n        \"subject\": ");
            try writeFindingSubject(out, gpa, finding.subject);
            try out.appendSlice(gpa, "\n      }");
        },
        .claim => {
            const claim_index = claimIndexOf(node.id) orelse return error.InvalidChecksReport;
            const claim = parsed_claims.claims[claim_index];
            try out.appendSlice(gpa, "\n        \"claim_index\": ");
            try json_out.writeUsize(out, gpa, claim_index);
            try out.appendSlice(gpa, ",\n        \"claim_id\": ");
            try json_out.writeString(out, gpa, claim.id);
            try out.appendSlice(gpa, ",\n        \"status\": ");
            try json_out.writeString(out, gpa, claim.status);
            try out.appendSlice(gpa, "\n      }");
        },
        .limitation => {
            const limitation_index = limitationIndexOf(node.id) orelse return error.InvalidChecksReport;
            const limitation = parsed_claims.limitations[limitation_index];
            try out.appendSlice(gpa, "\n        \"limitation_index\": ");
            try json_out.writeUsize(out, gpa, limitation_index);
            try out.appendSlice(gpa, ",\n        \"limitation_id\": ");
            try json_out.writeString(out, gpa, limitation.id);
            try out.appendSlice(gpa, ",\n        \"source\": ");
            try json_out.writeString(out, gpa, limitation.source);
            try out.appendSlice(gpa, "\n      }");
        },
    }
    try out.appendSlice(gpa, "\n    }");
}

fn artifactIndexOf(inventory: *const artifact_inventory.Inventory, id: []const u8) ?usize {
    const prefix = "artifact:";
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const path = id[prefix.len..];
    for (inventory.records, 0..) |record, index| {
        if (std.mem.eql(u8, record.path, path)) return index;
    }
    return null;
}

fn checkIndexOf(id: []const u8) ?usize {
    const prefix = "check:";
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const value = id[prefix.len..];
    for (check_ids, 0..) |check_id, index| {
        if (std.mem.eql(u8, value, check_id)) return index;
    }
    return null;
}

fn findingIndexOf(checks: *const [3]ParsedCheck, id: []const u8) ?usize {
    const prefix = "finding:";
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const rest = id[prefix.len..];
    const last_colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    const check_id = rest[0..last_colon];
    const ordinal_text = rest[last_colon + 1 ..];
    const ordinal = std.fmt.parseInt(usize, ordinal_text, 10) catch return null;
    const check_index = indexOfString(&check_ids, check_id) orelse return null;
    const root_index = std.math.add(usize, checks[check_index].finding_offset, ordinal) catch return null;
    const end = std.math.add(usize, checks[check_index].finding_offset, checks[check_index].counts_findings) catch return null;
    if (root_index >= end) return null;
    return root_index;
}

fn claimIndexOf(id: []const u8) ?usize {
    const prefix = "claim:";
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const value = id[prefix.len..];
    for (claim_ids, 0..) |claim_id, index| {
        if (std.mem.eql(u8, value, claim_id)) return index;
    }
    return null;
}

fn limitationIndexOf(id: []const u8) ?usize {
    const prefix = "limitation:";
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const value = id[prefix.len..];
    for (limitation_ids, 0..) |limitation_id, index| {
        if (std.mem.eql(u8, value, limitation_id)) return index;
    }
    return null;
}

fn writeEdge(out: *std.ArrayList(u8), gpa: std.mem.Allocator, edge: Edge) !void {
    try out.appendSlice(gpa, "    {\n      \"kind\": ");
    try json_out.writeString(out, gpa, edge.kind.name());
    try out.appendSlice(gpa, ",\n      \"from\": ");
    try json_out.writeString(out, gpa, edge.from);
    try out.appendSlice(gpa, ",\n      \"to\": ");
    try json_out.writeString(out, gpa, edge.to);
    try out.appendSlice(gpa, "\n    }");
}

fn writeReport(
    gpa: std.mem.Allocator,
    target: []const u8,
    artifacts_binding: FileBinding,
    checks_binding: FileBinding,
    claims_binding: FileBinding,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
    nodes: []const Node,
    edges: []const Edge,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, report_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"target\": ");
    try json_out.writeString(&out, gpa, target);
    try out.appendSlice(gpa, ",\n  \"inputs\": {\n");
    try writeInputBlock(&out, gpa, "artifacts", artifact_inventory.output_path, artifacts_binding, artifact_inventory.artifact_format, artifact_inventory.schema_version, target, &.{.{ .key = "artifact_count", .value = inventory.records.len }});
    try out.appendSlice(gpa, ",\n");
    try writeInputBlock(&out, gpa, "checks", publication_checks.output_path, checks_binding, publication_checks.report_format, publication_checks.schema_version, target, &.{
        .{ .key = "check_count", .value = parsed_checks.checks.len },
        .{ .key = "finding_count", .value = parsed_checks.findings.len },
    });
    try out.appendSlice(gpa, ",\n");
    try writeInputBlock(&out, gpa, "claims", publication_claims.output_path, claims_binding, publication_claims.report_format, publication_claims.schema_version, target, &.{
        .{ .key = "claim_count", .value = parsed_claims.claims.len },
        .{ .key = "limitation_count", .value = parsed_claims.limitations.len },
    });
    try out.appendSlice(gpa, "\n  },\n  \"nodes\": [\n");
    for (nodes, 0..) |node, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        try writeNode(&out, gpa, node, inventory, parsed_checks, parsed_claims, target);
    }
    try out.appendSlice(gpa, "\n  ],\n  \"edges\": [\n");
    for (edges, 0..) |edge, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        try writeEdge(&out, gpa, edge);
    }
    try out.appendSlice(gpa, "\n  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Read the committed inventory, checks, and claims reports, derive the
/// canonical Touch Atlas, and atomically replace the target-local report. Any
/// error before `replace` preserves an existing report and leaves payloads,
/// artifacts, checks, and claims committed.
pub fn writeAfterClaims(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    options: Options,
) Error!void {
    if (options.test_fail_execution) return error.InvalidClaimsReport;
    var report_arena = std.heap.ArenaAllocator.init(gpa);
    defer report_arena.deinit();
    const report_gpa = report_arena.allocator();

    var artifacts_input: EvidenceInput = .{};
    try artifacts_input.open(io, root, artifact_inventory.output_path, error.InvalidArtifactsReport);
    defer artifacts_input.close(io);
    var checks_input: EvidenceInput = .{};
    try checks_input.open(io, root, publication_checks.output_path, error.InvalidChecksReport);
    defer checks_input.close(io);
    var claims_input: EvidenceInput = .{};
    try claims_input.open(io, root, publication_claims.output_path, error.InvalidClaimsReport);
    defer claims_input.close(io);
    if (options.after_open) |hook| hook(options.after_open_context);

    try artifacts_input.hashPass(error.InvalidArtifactsReport);
    try artifacts_input.rewindForParse(io, error.InvalidArtifactsReport);
    var inventory = artifact_inventory.parseStream(report_gpa, &artifacts_input.pass2.interface, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifactsReport,
    };
    defer inventory.deinit();
    const artifacts_binding = artifacts_input.finish();

    try checks_input.hashPass(error.InvalidChecksReport);
    try checks_input.rewindForParse(io, error.InvalidChecksReport);
    const parsed_checks = try parseChecksStream(report_gpa, &checks_input.pass2.interface, target);
    const checks_binding = checks_input.finish();

    try claims_input.hashPass(error.InvalidClaimsReport);
    try claims_input.rewindForParse(io, error.InvalidClaimsReport);
    const parsed_claims = try parseClaimsStream(report_gpa, &claims_input.pass2.interface, target);
    const claims_binding = claims_input.finish();

    if (parsed_checks.artifact_binding.bytes != artifacts_binding.bytes or
        !std.mem.eql(u8, &parsed_checks.artifact_binding.sha256, &artifacts_binding.sha256) or
        parsed_checks.artifact_count != inventory.records.len)
        return error.StaleArtifactsBinding;
    if (parsed_claims.artifact_binding.bytes != artifacts_binding.bytes or
        !std.mem.eql(u8, &parsed_claims.artifact_binding.sha256, &artifacts_binding.sha256) or
        parsed_claims.artifact_count != inventory.records.len)
        return error.StaleClaimsBinding;
    if (parsed_claims.checks_binding.bytes != checks_binding.bytes or
        !std.mem.eql(u8, &parsed_claims.checks_binding.sha256, &checks_binding.sha256) or
        parsed_claims.check_count != parsed_checks.checks.len or
        parsed_claims.finding_count != parsed_checks.findings.len)
        return error.StaleChecksBinding;

    // Cross-report semantic validation, in strict order: check semantics
    // first (digests and counts against the canonical inventory), then full
    // claim evidence parity against the parsed checks report.
    try validateChecksAgainstInventory(report_gpa, &inventory, &parsed_checks.checks);
    try validateClaimsAgainstChecks(&parsed_checks, checks_binding, &parsed_claims);

    const derived = try buildNodesAndEdges(report_gpa, &inventory, &parsed_checks, &parsed_claims);
    try validateGraph(report_gpa, &inventory, &parsed_checks, &parsed_claims, derived.nodes, derived.edges);

    const report = writeReport(
        report_gpa,
        target,
        artifacts_binding,
        checks_binding,
        claims_binding,
        &inventory,
        &parsed_checks,
        &parsed_claims,
        derived.nodes,
        derived.edges,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
        error.InvalidChecksReport => return error.InvalidChecksReport,
    };

    var atomic = root.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true }) catch {
        return error.TouchesWriteFailed;
    };
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(report) catch return error.TouchesWriteFailed;
    writer.interface.flush() catch return error.TouchesWriteFailed;
    if (options.test_fail_write) return error.TouchesWriteFailed;
    atomic.replace(io) catch return error.TouchesWriteFailed;
}

// ---------------------------------------------------------------------------
// Test fixtures and end-to-end evidence derivation tests.
// ---------------------------------------------------------------------------

const test_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

const TestFindingSpec = struct {
    code: []const u8,
    severity: []const u8 = "error",
    subject_kind: []const u8 = "artifact",
    subject_id: []const u8,
    subject_target: ?[]const u8 = "default",
};

const TestCheckSpec = struct {
    status: []const u8 = "passed",
    coverage: []const u8 = "complete",
    /// `null` derives the eligible/checked counts from the inventory selectors
    /// exactly as the checks layer computes them; explicit values (used by
    /// tamper tests) emit exactly what is given.
    eligible: ?usize = null,
    checked: ?usize = null,
    report_eligible: bool = true,
    report_ran: bool = true,
    /// `null` computes the real scope digests over the canonical inventory;
    /// explicit values emit the given digest so tamper tests can prove
    /// digest/selector inconsistency is rejected.
    subject_sha256: ?[]const u8 = null,
    supporting_sha256: ?[]const u8 = null,
    subject_statuses: []const []const u8 = &.{"committed"},
    subject_kinds: []const []const u8 = &.{},
    supporting_statuses: []const []const u8 = &.{},
    supporting_kinds: []const []const u8 = &.{},
    findings: []const TestFindingSpec = &.{},
};

const TestFixtureSpec = struct {
    target: []const u8 = "default",
    artifact_count: usize = 1,
    checks: [3]TestCheckSpec = .{
        .{ .subject_kinds = &.{} },
        .{ .subject_kinds = &.{"html-page"} },
        // The default rendered-search check is unselected (no search artifact
        // is configured in the canonical fixture), matching the publication
        // layer's state matrix: not eligible, did not run, not-applicable,
        // zero counts, empty subject selectors.
        .{
            .subject_statuses = &.{},
            .subject_kinds = &.{},
            .supporting_statuses = &.{"committed"},
            .supporting_kinds = &.{"html-page"},
            .status = "not-applicable",
            .coverage = "not-applicable",
            .eligible = 0,
            .checked = 0,
            .report_eligible = false,
            .report_ran = false,
        },
    },
};

fn recordFor(
    path: []const u8,
    kind: artifact_inventory.Kind,
    bytes: []const u8,
) artifact_inventory.Record {
    return recordForStatus(path, kind, bytes, .committed);
}

fn recordForStatus(
    path: []const u8,
    kind: artifact_inventory.Kind,
    bytes: []const u8,
    status: artifact_inventory.Status,
) artifact_inventory.Record {
    return .{
        .path = path,
        .kind = kind,
        .producer = kind.producerName(),
        .required = true,
        .status = status,
        .bytes = bytes.len,
        .sha256 = cache.hexDigest(cache.hashBytes(bytes)),
        .format_version = if (kind == .rendered_search) "1" else null,
    };
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

fn buildArtifactsBytes(
    gpa: std.mem.Allocator,
    target: []const u8,
    records: []const artifact_inventory.Record,
) ![]u8 {
    const ordered = try gpa.dupe(artifact_inventory.Record, records);
    defer gpa.free(ordered);
    std.mem.sort(artifact_inventory.Record, ordered, {}, artifact_inventory.recordLess);
    var inventory = artifact_inventory.Inventory{ .gpa = gpa, .target = target, .records = ordered };
    return artifact_inventory.render(gpa, &inventory);
}

fn writeFindingJson(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    finding: TestFindingSpec,
) !void {
    try out.appendSlice(gpa, "{\"code\": \"");
    try out.appendSlice(gpa, finding.code);
    try out.appendSlice(gpa, "\", \"domain\": \"artifact\", \"severity\": \"");
    try out.appendSlice(gpa, finding.severity);
    try out.appendSlice(gpa, "\", \"confidence\": \"certain\", \"owner\": \"publication\", \"subject\": {\"kind\": \"");
    try out.appendSlice(gpa, finding.subject_kind);
    try out.appendSlice(gpa, "\", \"id\": \"");
    try out.appendSlice(gpa, finding.subject_id);
    try out.appendSlice(gpa, "\", \"target\": ");
    if (finding.subject_target) |value| {
        try json_out.writeString(out, gpa, value);
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, "}, \"source_location\": {\"path\": \"a.md\", \"line\": 1, \"column\": 1}, \"output_location\": {\"path\": \"a.html\", \"line\": 1, \"column\": 1}, \"configuration_location\": null, \"evidence\": {\"observed\": \"x\", \"expected\": \"y\", \"related\": []}, \"remediation\": \"fix\", \"fixability\": \"regenerate\"}");
}

const DerivedCheck = struct {
    eligible: usize,
    checked: usize,
    subject_sha256: [64]u8,
    supporting_sha256: [64]u8,
};

fn digestFromText(text: []const u8) [64]u8 {
    var digest: [64]u8 = undefined;
    @memcpy(&digest, text[0..64]);
    return digest;
}

fn countSelected(
    inventory: *const artifact_inventory.Inventory,
    statuses: []const []const u8,
    kinds: []const []const u8,
) usize {
    var count: usize = 0;
    for (inventory.records) |record| {
        if (selected(record, statuses, kinds)) count += 1;
    }
    return count;
}

/// Derive a check's eligible/checked counts and both scope digests exactly as
/// the checks layer derives them from the canonical inventory: eligible is
/// the selected subject count (unless the spec overrides it), checked is
/// eligible (unless overridden or the check is not-applicable), and the
/// digests recompute the publication-check record encoding. Tamper tests can
/// override any field to emit intentionally inconsistent evidence.
fn deriveCheck(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    check: TestCheckSpec,
) !DerivedCheck {
    const subject_selected = countSelected(inventory, check.subject_statuses, check.subject_kinds);
    const eligible = check.eligible orelse subject_selected;
    const checked = check.checked orelse (if (std.mem.eql(u8, check.status, "not-applicable")) 0 else eligible);
    const subject_sha256 = if (check.subject_sha256) |text|
        digestFromText(text)
    else
        try publication_checks.scopeDigest(gpa, inventory, check.subject_statuses, check.subject_kinds);
    const supporting_sha256 = if (check.supporting_sha256) |text|
        digestFromText(text)
    else
        try publication_checks.scopeDigest(gpa, inventory, check.supporting_statuses, check.supporting_kinds);
    return .{
        .eligible = eligible,
        .checked = checked,
        .subject_sha256 = subject_sha256,
        .supporting_sha256 = supporting_sha256,
    };
}

fn writeTestStringArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    values: []const []const u8,
) !void {
    try out.append(gpa, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try out.appendSlice(gpa, ", ");
        try json_out.writeString(out, gpa, value);
    }
    try out.append(gpa, ']');
}

fn buildChecksBytes(
    gpa: std.mem.Allocator,
    artifacts_bytes: []const u8,
    spec: TestFixtureSpec,
) ![]u8 {
    const digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    var inventory = try artifact_inventory.parse(gpa, artifacts_bytes, spec.target);
    defer inventory.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"format\": \"boris-publication-checks\",\n  \"schema_version\": 1,\n  \"target\": \"");
    try out.appendSlice(gpa, spec.target);
    try out.appendSlice(gpa, "\",\n  \"artifact_inventory\": {\n    \"path\": \"_boris/proof/artifacts.json\",\n    \"bytes\": ");
    try json_out.writeUsize(&out, gpa, artifacts_bytes.len);
    try out.appendSlice(gpa, ",\n    \"sha256\": \"");
    try out.appendSlice(gpa, &digest);
    try out.appendSlice(gpa, "\",\n    \"format\": \"boris-publication-artifacts\",\n    \"schema_version\": 1,\n    \"target\": \"");
    try out.appendSlice(gpa, spec.target);
    try out.appendSlice(gpa, "\",\n    \"artifact_count\": ");
    try json_out.writeUsize(&out, gpa, spec.artifact_count);
    try out.appendSlice(gpa, "\n  },\n  \"checks\": [\n");
    var offset: usize = 0;
    for (spec.checks, 0..) |check, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        const derived = try deriveCheck(gpa, &inventory, check);
        try out.appendSlice(gpa, "    {\n      \"id\": \"");
        try out.appendSlice(gpa, check_ids[index]);
        try out.appendSlice(gpa, "\",\n      \"eligible\": ");
        try out.appendSlice(gpa, if (check.report_eligible) "true" else "false");
        try out.appendSlice(gpa, ",\n      \"ran\": ");
        try out.appendSlice(gpa, if (check.report_ran) "true" else "false");
        try out.appendSlice(gpa, ",\n      \"status\": \"");
        try out.appendSlice(gpa, check.status);
        try out.appendSlice(gpa, "\",\n      \"coverage\": \"");
        try out.appendSlice(gpa, check.coverage);
        try out.appendSlice(gpa, "\",\n      \"scope\": {\n        \"subject_statuses\": [");
        for (check.subject_statuses, 0..) |value, value_index| {
            if (value_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, value);
        }
        try out.appendSlice(gpa, "],\n        \"subject_kinds\": [");
        for (check.subject_kinds, 0..) |value, value_index| {
            if (value_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, value);
        }
        try out.appendSlice(gpa, "],\n        \"subject_sha256\": \"");
        try out.appendSlice(gpa, &derived.subject_sha256);
        try out.appendSlice(gpa, "\",\n        \"supporting_statuses\": [");
        for (check.supporting_statuses, 0..) |value, value_index| {
            if (value_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, value);
        }
        try out.appendSlice(gpa, "],\n        \"supporting_kinds\": [");
        for (check.supporting_kinds, 0..) |value, value_index| {
            if (value_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, value);
        }
        try out.appendSlice(gpa, "],\n        \"supporting_sha256\": \"");
        try out.appendSlice(gpa, &derived.supporting_sha256);
        try out.appendSlice(gpa, "\"\n      },\n      \"counts\": {\"eligible\": ");
        try json_out.writeUsize(&out, gpa, derived.eligible);
        try out.appendSlice(gpa, ", \"checked\": ");
        try json_out.writeUsize(&out, gpa, derived.checked);
        try out.appendSlice(gpa, ", \"findings\": ");
        try json_out.writeUsize(&out, gpa, check.findings.len);
        try out.appendSlice(gpa, "},\n      \"finding_offset\": ");
        try json_out.writeUsize(&out, gpa, offset);
        try out.appendSlice(gpa, "\n    }");
        offset += check.findings.len;
    }
    try out.appendSlice(gpa, "\n  ],\n  \"findings\": [");
    var finding_index: usize = 0;
    for (spec.checks) |check| {
        for (check.findings) |finding| {
            if (finding_index > 0) try out.appendSlice(gpa, ", ");
            try writeFindingJson(&out, gpa, finding);
            finding_index += 1;
        }
    }
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn claimStatusFor(check: TestCheckSpec) []const u8 {
    if (std.mem.eql(u8, check.status, "passed")) return "verified";
    if (std.mem.eql(u8, check.status, "failed")) return "failed";
    return "not-verified";
}

fn buildClaimsBytes(
    gpa: std.mem.Allocator,
    artifacts_bytes: []const u8,
    checks_bytes: []const u8,
    spec: TestFixtureSpec,
) ![]u8 {
    const artifacts_digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    const checks_digest = cache.hexDigest(cache.hashBytes(checks_bytes));
    var inventory = try artifact_inventory.parse(gpa, artifacts_bytes, spec.target);
    defer inventory.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"format\": \"boris-publication-claims\",\n  \"schema_version\": 1,\n  \"target\": \"");
    try out.appendSlice(gpa, spec.target);
    try out.appendSlice(gpa, "\",\n  \"artifact_inventory\": {\n    \"path\": \"_boris/proof/artifacts.json\",\n    \"bytes\": ");
    try json_out.writeUsize(&out, gpa, artifacts_bytes.len);
    try out.appendSlice(gpa, ",\n    \"sha256\": \"");
    try out.appendSlice(gpa, &artifacts_digest);
    try out.appendSlice(gpa, "\",\n    \"format\": \"boris-publication-artifacts\",\n    \"schema_version\": 1,\n    \"target\": \"");
    try out.appendSlice(gpa, spec.target);
    try out.appendSlice(gpa, "\",\n    \"artifact_count\": ");
    try json_out.writeUsize(&out, gpa, spec.artifact_count);
    try out.appendSlice(gpa, "\n  },\n  \"publication_checks\": {\n    \"path\": \"_boris/proof/checks.json\",\n    \"bytes\": ");
    try json_out.writeUsize(&out, gpa, checks_bytes.len);
    try out.appendSlice(gpa, ",\n    \"sha256\": \"");
    try out.appendSlice(gpa, &checks_digest);
    try out.appendSlice(gpa, "\",\n    \"format\": \"boris-publication-checks\",\n    \"schema_version\": 1,\n    \"target\": \"");
    try out.appendSlice(gpa, spec.target);
    try out.appendSlice(gpa, "\",\n    \"check_count\": 3,\n    \"finding_count\": ");
    var findings_total: usize = 0;
    for (spec.checks) |check| findings_total += check.findings.len;
    try json_out.writeUsize(&out, gpa, findings_total);
    try out.appendSlice(gpa, "\n  },\n  \"claims\": [\n");
    for (spec.checks, 0..) |check, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        const derived = try deriveCheck(gpa, &inventory, check);
        try out.appendSlice(gpa, "    {\n      \"id\": \"");
        try out.appendSlice(gpa, claim_ids[index]);
        try out.appendSlice(gpa, "\",\n      \"statement\": ");
        try json_out.writeString(&out, gpa, publication_claims.claim_statements[index]);
        try out.appendSlice(gpa, ",\n      \"status\": \"");
        try out.appendSlice(gpa, claimStatusFor(check));
        try out.appendSlice(gpa, "\",\n      \"evidence\": {\n        \"check_id\": \"");
        try out.appendSlice(gpa, check_ids[index]);
        try out.appendSlice(gpa, "\",\n        \"check_status\": \"");
        try out.appendSlice(gpa, check.status);
        try out.appendSlice(gpa, "\",\n        \"coverage\": \"");
        try out.appendSlice(gpa, check.coverage);
        try out.appendSlice(gpa, "\",\n        \"counts\": {\"eligible\": ");
        try json_out.writeUsize(&out, gpa, derived.eligible);
        try out.appendSlice(gpa, ", \"checked\": ");
        try json_out.writeUsize(&out, gpa, derived.checked);
        try out.appendSlice(gpa, ", \"findings\": ");
        try json_out.writeUsize(&out, gpa, check.findings.len);
        try out.appendSlice(gpa, "},\n        \"subject_sha256\": \"");
        try out.appendSlice(gpa, &derived.subject_sha256);
        try out.appendSlice(gpa, "\",\n        \"supporting_sha256\": \"");
        try out.appendSlice(gpa, &derived.supporting_sha256);
        try out.appendSlice(gpa, "\",\n        \"checks_report_sha256\": \"");
        try out.appendSlice(gpa, &checks_digest);
        try out.appendSlice(gpa, "\",\n        \"reason\": ");
        if (std.mem.eql(u8, check.status, "passed")) {
            try json_out.writeNull(&out, gpa);
        } else if (std.mem.eql(u8, check.status, "failed")) {
            try json_out.writeString(&out, gpa, "check-failed");
        } else if (std.mem.eql(u8, check.status, "incomplete")) {
            try json_out.writeString(&out, gpa, "check-incomplete");
        } else {
            try json_out.writeString(&out, gpa, "check-not-applicable");
        }
        try out.appendSlice(gpa, "\n      },\n      \"scope\": {\n        \"subject_statuses\": ");
        try writeTestStringArray(&out, gpa, check.subject_statuses);
        try out.appendSlice(gpa, ",\n        \"subject_kinds\": ");
        try writeTestStringArray(&out, gpa, check.subject_kinds);
        try out.appendSlice(gpa, ",\n        \"supporting_statuses\": ");
        try writeTestStringArray(&out, gpa, check.supporting_statuses);
        try out.appendSlice(gpa, ",\n        \"supporting_kinds\": ");
        try writeTestStringArray(&out, gpa, check.supporting_kinds);
        try out.appendSlice(gpa, "\n      },\n      \"limitation_ids\": [");
        for (claim_limitation_ids[index], 0..) |limitation_id, limitation_index| {
            if (limitation_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, limitation_id);
        }
        try out.appendSlice(gpa, "]\n    }");
    }
    try out.appendSlice(gpa, "\n  ],\n  \"limitations\": [\n");
    for (limitation_ids, 0..) |limitation_id, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        const row = publication_claims.limitation_rows[index];
        try out.appendSlice(gpa, "    {\n      \"id\": ");
        try json_out.writeString(&out, gpa, limitation_id);
        try out.appendSlice(gpa, ",\n      \"statement\": ");
        try json_out.writeString(&out, gpa, row.statement);
        try out.appendSlice(gpa, ",\n      \"applies_to_claims\": ");
        try writeTestStringArray(&out, gpa, row.applies_to_claims);
        try out.appendSlice(gpa, ",\n      \"source\": ");
        try json_out.writeString(&out, gpa, row.source);
        try out.appendSlice(gpa, "\n    }");
    }
    try out.appendSlice(gpa, "\n  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn prepareTarget(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    prefix: []const u8,
    records: []const artifact_inventory.Record,
    spec: TestFixtureSpec,
) !void {
    const artifacts_path = try std.mem.concat(gpa, u8, &.{ prefix, "/_boris/proof/artifacts.json" });
    defer gpa.free(artifacts_path);
    const artifacts = try buildArtifactsBytes(gpa, spec.target, records);
    defer gpa.free(artifacts);
    try writePayload(io, root, artifacts_path, artifacts);

    const checks_path = try std.mem.concat(gpa, u8, &.{ prefix, "/_boris/proof/checks.json" });
    defer gpa.free(checks_path);
    const checks = try buildChecksBytes(gpa, artifacts, spec);
    defer gpa.free(checks);
    try writePayload(io, root, checks_path, checks);

    const claims_path = try std.mem.concat(gpa, u8, &.{ prefix, "/_boris/proof/claims.json" });
    defer gpa.free(claims_path);
    const claims = try buildClaimsBytes(gpa, artifacts, checks, spec);
    defer gpa.free(claims);
    try writePayload(io, root, claims_path, claims);
}

fn openSubdir(io: Io, root: Io.Dir, prefix: []const u8) !Io.Dir {
    var dir = try root.openDir(io, prefix, .{});
    errdefer dir.close(io);
    return dir;
}

fn runTouches(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    prefix: []const u8,
    target: []const u8,
    options: Options,
) ![]u8 {
    var dir = try openSubdir(io, root, prefix);
    defer dir.close(io);
    try writeAfterClaims(io, gpa, dir, target, options);
    return readPayload(io, dir, gpa, output_path);
}

fn nodeCount(touches_root: std.json.ObjectMap) usize {
    return touches_root.get("nodes").?.array.items.len;
}

fn edgeCount(touches_root: std.json.ObjectMap) usize {
    return touches_root.get("edges").?.array.items.len;
}

fn findNode(touches_root: std.json.ObjectMap, id: []const u8) ?std.json.Value {
    for (touches_root.get("nodes").?.array.items) |node| {
        if (std.mem.eql(u8, node.object.get("id").?.string, id)) return node;
    }
    return null;
}

fn hasEdge(touches_root: std.json.ObjectMap, kind: []const u8, from: []const u8, to: []const u8) bool {
    for (touches_root.get("edges").?.array.items) |edge| {
        if (std.mem.eql(u8, edge.object.get("kind").?.string, kind) and
            std.mem.eql(u8, edge.object.get("from").?.string, from) and
            std.mem.eql(u8, edge.object.get("to").?.string, to)) return true;
    }
    return false;
}

test "clean graph derivation emits the full canonical node and edge vocabulary" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("_boris/search/search-index.json", .rendered_search, "{}"),
    };
    // The fixture configures a rendered-search artifact, so the search check
    // is selected (eligible, ran) with exactly one eligible search artifact.
    const spec = TestFixtureSpec{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);

    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("default", root.get("target").?.string);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 0 + 3 + 6), nodeCount(root));
    try std.testing.expectEqual(@as(usize, 2 + 4 + 1 + 0 + 3 + 16), edgeCount(root));

    const target_node = findNode(root, "target").?;
    try std.testing.expectEqualStrings("target", target_node.object.get("kind").?.string);
    try std.testing.expectEqualStrings("default", target_node.object.get("metadata").?.object.get("target").?.string);
    try std.testing.expect(findNode(root, "artifact:index.html") != null);
    try std.testing.expect(findNode(root, "artifact:_boris/search/search-index.json") != null);
    try std.testing.expect(findNode(root, "check:artifact-integrity") != null);
    try std.testing.expect(findNode(root, "check:rendered-html") != null);
    try std.testing.expect(findNode(root, "check:rendered-search") != null);
    try std.testing.expect(findNode(root, "claim:committed-artifacts-match-inventory") != null);
    try std.testing.expect(findNode(root, "claim:rendered-html-passed-declared-audit") != null);
    try std.testing.expect(findNode(root, "claim:rendered-search-matches-selected-html") != null);
    try std.testing.expect(findNode(root, "limitation:target-local-only") != null);
    try std.testing.expect(findNode(root, "limitation:omitted-projections-not-certified") != null);

    // All six edge kinds appear; endpoint ordering is canonical.
    try std.testing.expect(hasEdge(root, "target-owns-artifact", "target", "artifact:index.html"));
    try std.testing.expect(hasEdge(root, "artifact-subject-of-check", "artifact:index.html", "check:artifact-integrity"));
    try std.testing.expect(hasEdge(root, "artifact-supports-check", "artifact:index.html", "check:rendered-search"));
    try std.testing.expect(hasEdge(root, "check-supports-claim", "check:rendered-search", "claim:rendered-search-matches-selected-html"));
    try std.testing.expect(hasEdge(root, "claim-limited-by", "claim:committed-artifacts-match-inventory", "limitation:target-local-only"));
    try std.testing.expect(hasEdge(root, "claim-limited-by", "claim:rendered-search-matches-selected-html", "limitation:omitted-projections-not-certified"));
    try std.testing.expect(!hasEdge(root, "check-reported-finding", "check:artifact-integrity", "finding:artifact-integrity:0"));

    // The search-index subject edges follow artifact index then check index.
    const edges = root.get("edges").?.array.items;
    var subject_count: usize = 0;
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.object.get("kind").?.string, "artifact-subject-of-check")) subject_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), subject_count);
}

test "failed checks produce finding nodes, check ranges, and stable finding ids" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("broken.html", .html_page, "<main"),
        recordFor("_boris/search/search-index.json", .rendered_search, "{}"),
        recordFor("assets/site.css", .theme_asset, "css"),
        recordForStatus("assets/legacy.css", .theme_asset, "legacy", .omitted_by_plan),
    };
    const spec = TestFixtureSpec{
        .artifact_count = 5,
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "failed", .findings = &.{
                .{ .code = "ARTIFACT_DIGEST_MISMATCH", .severity = "error", .subject_kind = "artifact", .subject_id = "broken.html" },
            } },
            .{ .subject_kinds = &.{"html-page"}, .status = "failed", .findings = &.{
                .{ .code = "HTML_FRAGMENT_MISSING", .severity = "error", .subject_kind = "html-page", .subject_id = "index.html" },
            } },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "failed", .findings = &.{
                .{ .code = "SEARCH_CONTENT_MISMATCH", .severity = "error", .subject_kind = "rendered-search", .subject_id = "_boris/search/search-index.json" },
            } },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);

    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1 + 5 + 3 + 3 + 3 + 6), nodeCount(root));
    // 5 owns + 7 subject (committed-only: integrity 4, html-page 2, search 1)
    // + 2 supporting (html-page) + 3 findings + 3 claims + 16 limitations.
    try std.testing.expectEqual(@as(usize, 5 + 7 + 2 + 3 + 3 + 16), edgeCount(root));

    const f0 = findNode(root, "finding:artifact-integrity:0").?;
    const f0_metadata = f0.object.get("metadata").?.object;
    try std.testing.expectEqual(@as(i64, 0), f0_metadata.get("finding_index").?.integer);
    try std.testing.expectEqualStrings("artifact-integrity", f0_metadata.get("check_id").?.string);
    try std.testing.expectEqual(@as(i64, 0), f0_metadata.get("check_finding_index").?.integer);
    try std.testing.expectEqualStrings("ARTIFACT_DIGEST_MISMATCH", f0_metadata.get("code").?.string);
    try std.testing.expectEqualStrings("artifact", f0_metadata.get("subject").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("broken.html", f0_metadata.get("subject").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("default", f0_metadata.get("subject").?.object.get("target").?.string);

    const f1 = findNode(root, "finding:rendered-html:0").?;
    try std.testing.expectEqual(@as(i64, 1), f1.object.get("metadata").?.object.get("finding_index").?.integer);
    const f2 = findNode(root, "finding:rendered-search:0").?;
    try std.testing.expectEqual(@as(i64, 2), f2.object.get("metadata").?.object.get("finding_index").?.integer);

    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:artifact-integrity", "finding:artifact-integrity:0"));
    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:rendered-html", "finding:rendered-html:0"));
    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:rendered-search", "finding:rendered-search:0"));

    // The omitted-by-plan artifact stays a node with a target edge but no
    // subject edges, and never becomes a finding subject.
    try std.testing.expect(findNode(root, "artifact:assets/legacy.css") != null);
    try std.testing.expect(hasEdge(root, "target-owns-artifact", "target", "artifact:assets/legacy.css"));
}

test "multiple findings per check keep stable local ordinals" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const spec = TestFixtureSpec{
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "failed", .findings = &.{
                .{ .code = "ARTIFACT_SIZE_MISMATCH", .subject_id = "index.html" },
                .{ .code = "ARTIFACT_DIGEST_MISMATCH", .subject_id = "index.html" },
            } },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);

    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1 + 1 + 3 + 2 + 3 + 6), nodeCount(root));
    try std.testing.expect(findNode(root, "finding:artifact-integrity:0") != null);
    try std.testing.expect(findNode(root, "finding:artifact-integrity:1") != null);
    try std.testing.expect(findNode(root, "finding:artifact-integrity:0").?.object.get("metadata").?.object.get("check_finding_index").?.integer == 0);
    try std.testing.expect(findNode(root, "finding:artifact-integrity:1").?.object.get("metadata").?.object.get("check_finding_index").?.integer == 1);
    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:artifact-integrity", "finding:artifact-integrity:0"));
    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:artifact-integrity", "finding:artifact-integrity:1"));
    // The not-applicable search check has no findings and no subject edges.
    try std.testing.expect(!hasEdge(root, "artifact-subject-of-check", "artifact:index.html", "check:rendered-search"));
}

test "selector matching honors empty wildcards and empty-vs-empty semantics" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("assets/site.css", .theme_asset, "css"),
        recordFor("omitted.html", .html_page, "omitted"),
    };
    // artifact-integrity: subject committed+wildcard kinds; rendered-html:
    // subject committed+html-page; rendered-search: subject committed+
    // rendered-search, supporting committed+html-page. The omitted-by-plan
    // record is kept as a node but never selected.
    const rendered_bytes = try buildArtifactsBytes(gpa, "default", &records);
    defer gpa.free(rendered_bytes);
    var inventory = try artifact_inventory.parse(gpa, rendered_bytes, "default");
    defer inventory.deinit();
    inventory.records[2].status = .omitted_by_plan;
    const artifacts = try artifact_inventory.render(gpa, &inventory);
    defer gpa.free(artifacts);
    // No rendered-search artifact exists in this fixture, so the search check
    // is unselected: not eligible, did not run, not-applicable, zero counts,
    // and no subject selectors (matching the publication-layer state matrix).
    const spec = TestFixtureSpec{
        .artifact_count = 3,
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "passed" },
            .{ .subject_kinds = &.{"html-page"} },
            .{
                .subject_statuses = &.{},
                .subject_kinds = &.{},
                .supporting_statuses = &.{"committed"},
                .supporting_kinds = &.{"html-page"},
                .status = "not-applicable",
                .coverage = "not-applicable",
                .eligible = 0,
                .checked = 0,
                .report_eligible = false,
                .report_ran = false,
            },
        },
    };
    // Rebuild the evidence tree from the modified inventory bytes.
    try writePayload(io, tmp.dir, "target/_boris/proof/artifacts.json", artifacts);
    const checks = try buildChecksBytes(gpa, artifacts, spec);
    defer gpa.free(checks);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", checks);
    const claims = try buildClaimsBytes(gpa, artifacts, checks, spec);
    defer gpa.free(claims);
    try writePayload(io, tmp.dir, "target/_boris/proof/claims.json", claims);

    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // Subject edges: committed wildcard kinds -> integrity (2), committed
    // html-page -> rendered-html (1). Supporting: committed html-page ->
    // rendered-search (1). Omitted record never selected.
    try std.testing.expect(hasEdge(root, "artifact-subject-of-check", "artifact:index.html", "check:artifact-integrity"));
    try std.testing.expect(hasEdge(root, "artifact-subject-of-check", "artifact:assets/site.css", "check:artifact-integrity"));
    try std.testing.expect(hasEdge(root, "artifact-subject-of-check", "artifact:index.html", "check:rendered-html"));
    try std.testing.expect(hasEdge(root, "artifact-supports-check", "artifact:index.html", "check:rendered-search"));
    try std.testing.expect(!hasEdge(root, "artifact-subject-of-check", "artifact:omitted.html", "check:artifact-integrity"));
    try std.testing.expect(!hasEdge(root, "artifact-supports-check", "artifact:assets/site.css", "check:rendered-search"));
    try std.testing.expect(findNode(root, "artifact:omitted.html") != null);
}

test "empty selector pair selects nothing while a single empty dimension wildcards" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("assets/site.css", .theme_asset, "css"),
    };
    // No rendered-search artifact is configured, so the search check is
    // unselected; its supporting selector pair is empty (empty pair -> empty),
    // matching the state matrix for an unselected search.
    const spec = TestFixtureSpec{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{
                .subject_statuses = &.{},
                .subject_kinds = &.{},
                .supporting_statuses = &.{},
                .supporting_kinds = &.{},
                .status = "not-applicable",
                .coverage = "not-applicable",
                .eligible = 0,
                .checked = 0,
                .report_eligible = false,
                .report_ran = false,
            },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // No supporting edges anywhere: all supporting selector pairs are empty.
    for (root.get("edges").?.array.items) |edge| {
        try std.testing.expect(!std.mem.eql(u8, edge.object.get("kind").?.string, "artifact-supports-check"));
    }
}

test "rendered search not applicable omits the search artifact node and subject edge" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("assets/site.css", .theme_asset, "css"),
    };
    const spec = TestFixtureSpec{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(findNode(root, "artifact:_boris/search/search-index.json") == null);
    try std.testing.expect(!hasEdge(root, "artifact-subject-of-check", "artifact:index.html", "check:rendered-search"));
    // The not-applicable check still has a check node and claim binding edge.
    try std.testing.expect(findNode(root, "check:rendered-search") != null);
    try std.testing.expect(hasEdge(root, "check-supports-claim", "check:rendered-search", "claim:rendered-search-matches-selected-html"));
}

test "incomplete checks emit incomplete coverage without inventing findings" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("missing.html", .html_page, "missing"),
    };
    const spec = TestFixtureSpec{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "incomplete", .coverage = "incomplete", .checked = 1, .findings = &.{
                .{ .code = "ARTIFACT_MISSING", .subject_id = "missing.html" },
            } },
            .{ .subject_kinds = &.{"html-page"}, .status = "incomplete", .coverage = "incomplete", .checked = 1, .findings = &.{
                .{ .code = "HTML_PAGE_MISSING", .subject_kind = "html-page", .subject_id = "missing.html" },
            } },
            // No search artifact: the search check is unselected and did not
            // run, so it invents no findings and no search subject edges.
            .{
                .subject_statuses = &.{},
                .subject_kinds = &.{},
                .supporting_statuses = &.{},
                .supporting_kinds = &.{},
                .status = "not-applicable",
                .coverage = "not-applicable",
                .eligible = 0,
                .checked = 0,
                .report_eligible = false,
                .report_ran = false,
            },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 2 + 3 + 6), nodeCount(root));
    const check_node = findNode(root, "check:artifact-integrity").?;
    try std.testing.expectEqualStrings("incomplete", check_node.object.get("metadata").?.object.get("status").?.string);
    try std.testing.expectEqualStrings("incomplete", check_node.object.get("metadata").?.object.get("coverage").?.string);
    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:artifact-integrity", "finding:artifact-integrity:0"));
    try std.testing.expect(hasEdge(root, "check-reported-finding", "check:rendered-html", "finding:rendered-html:0"));
}

test "incomplete checks map claims to not-verified with the fixed claim registry" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const spec = TestFixtureSpec{
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "incomplete", .coverage = "incomplete", .checked = 0, .findings = &.{
                .{ .code = "ARTIFACT_MISSING", .subject_id = "gone.html" },
            } },
            .{ .subject_kinds = &.{"html-page"} },
            // Unselected search (no search artifact): not eligible, did not
            // run, not-applicable, zero counts.
            .{
                .subject_statuses = &.{},
                .subject_kinds = &.{},
                .supporting_statuses = &.{},
                .supporting_kinds = &.{},
                .status = "not-applicable",
                .coverage = "not-applicable",
                .eligible = 0,
                .checked = 0,
                .report_eligible = false,
                .report_ran = false,
            },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const claim0 = findNode(root, "claim:committed-artifacts-match-inventory").?;
    try std.testing.expectEqualStrings("not-verified", claim0.object.get("metadata").?.object.get("status").?.string);
}

test "touches report is byte-deterministic across sequential rebuilds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    const first = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(first);
    const second = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}

test "touches report is byte-identical across sequential and concurrent derivation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "a", &records, .{});
    try prepareTarget(io, gpa, tmp.dir, "b", &records, .{});

    const sequential = try runTouches(io, gpa, tmp.dir, "a", "default", .{});
    defer gpa.free(sequential);

    const ThreadArgs = struct {
        io: Io,
        gpa: std.mem.Allocator,
        root: Io.Dir,
        error_value: ?anyerror = null,
    };
    var args = ThreadArgs{ .io = io, .gpa = gpa, .root = tmp.dir };
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(thread_args: *ThreadArgs) void {
            const bytes = runTouches(thread_args.io, thread_args.gpa, thread_args.root, "b", "default", .{}) catch |err| {
                thread_args.error_value = err;
                return;
            };
            thread_args.gpa.free(bytes);
        }
    }.run, .{&args});
    thread.join();
    try std.testing.expect(args.error_value == null);

    var dir = try openSubdir(io, tmp.dir, "b");
    defer dir.close(io);
    const concurrent = try readPayload(io, dir, gpa, output_path);
    defer gpa.free(concurrent);
    try std.testing.expectEqualSlices(u8, sequential, concurrent);
}

test "exact input bindings survive replacement of the opened evidence paths" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    const control = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(control);

    // Replace all three evidence paths with garbage after the handles are
    // opened. A path-based implementation would fail loudly on re-open; the
    // single opened no-follow handle per input must be unaffected, so the
    // atlas is byte-identical to the no-replacement run.
    const replacer = PathReplacer{ .io = io, .root = tmp.dir };
    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{ .after_open = PathReplacer.run, .after_open_context = @constCast(&replacer) });
    defer gpa.free(touches);
    try std.testing.expectEqualSlices(u8, control, touches);
}

const PathReplacer = struct {
    io: Io,
    root: Io.Dir,

    fn run(context: ?*anyopaque) void {
        const self: *const PathReplacer = @ptrCast(@alignCast(context.?));
        replace(self, "target/_boris/proof/artifacts.json");
        replace(self, "target/_boris/proof/checks.json");
        replace(self, "target/_boris/proof/claims.json");
    }

    fn replace(self: *const PathReplacer, path: []const u8) void {
        self.root.deleteFile(self.io, path) catch {};
        self.root.writeFile(self.io, .{ .sub_path = path, .data = "replaced garbage" }) catch {};
    }
};

test "write fault injection preserves the prior touches report byte-for-byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    const first = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(first);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(
        error.TouchesWriteFailed,
        writeAfterClaims(io, gpa, dir, "default", .{ .test_fail_write = true }),
    );
    const after = try readPayload(io, dir, gpa, output_path);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, first, after);
}

test "execution fault injection fails before any touches report is written" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(
        error.InvalidClaimsReport,
        writeAfterClaims(io, gpa, dir, "default", .{ .test_fail_execution = true }),
    );
    try std.testing.expectError(error.FileNotFound, dir.access(io, output_path, .{}));
}

test "stale artifact binding is rejected without replacing touches" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    const rendered = try buildArtifactsBytes(gpa, "default", &records);
    defer gpa.free(rendered);
    const changed = try std.mem.concat(gpa, u8, &.{ rendered, "\n" });
    defer gpa.free(changed);
    try writePayload(io, dir, artifact_inventory.output_path, changed);
    try std.testing.expectError(error.StaleArtifactsBinding, writeAfterClaims(io, gpa, dir, "default", .{}));
    try std.testing.expectError(error.FileNotFound, dir.access(io, output_path, .{}));
}

test "stale checks binding is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    const checks = try readPayload(io, dir, gpa, publication_checks.output_path);
    defer gpa.free(checks);
    const changed = try std.mem.concat(gpa, u8, &.{ checks, "\n" });
    defer gpa.free(changed);
    try writePayload(io, dir, publication_checks.output_path, changed);
    try std.testing.expectError(error.StaleChecksBinding, writeAfterClaims(io, gpa, dir, "default", .{}));
}

test "stale claims binding is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
    defer gpa.free(claims);
    // Rewrite the claims file so its embedded artifact binding no longer
    // matches the committed artifacts report: declare one extra artifact.
    const mutated = try std.mem.replaceOwned(
        u8,
        gpa,
        claims,
        "\"artifact_count\": 1",
        "\"artifact_count\": 2",
    );
    defer gpa.free(mutated);
    try writePayload(io, dir, publication_claims.output_path, mutated);
    try std.testing.expectError(error.StaleClaimsBinding, writeAfterClaims(io, gpa, dir, "default", .{}));
}

test "wrong target, wrong format, and wrong version are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};

    {
        try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        // Artifacts are parsed first, so a target mismatch surfaces there.
        try std.testing.expectError(error.InvalidArtifactsReport, writeAfterClaims(io, gpa, dir, "prod", .{}));
    }
    {
        const spec = TestFixtureSpec{ .target = "default" };
        try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        const checks = try readPayload(io, dir, gpa, publication_checks.output_path);
        defer gpa.free(checks);
        const mutated = try std.mem.replaceOwned(
            u8,
            gpa,
            checks,
            "boris-publication-checks",
            "boris-other",
        );
        defer gpa.free(mutated);
        try writePayload(io, dir, publication_checks.output_path, mutated);
        try std.testing.expectError(error.InvalidChecksReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
    {
        const spec = TestFixtureSpec{ .target = "default" };
        try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
        defer gpa.free(claims);
        const mutated = try std.mem.replaceOwned(u8, gpa, claims, "\"schema_version\": 1", "\"schema_version\": 2");
        defer gpa.free(mutated);
        try writePayload(io, dir, publication_claims.output_path, mutated);
        try std.testing.expectError(error.InvalidClaimsReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
}

test "malformed finding ranges and integer overflow are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};

    {
        try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        const checks = try readPayload(io, dir, gpa, publication_checks.output_path);
        defer gpa.free(checks);
        const mutated = try std.mem.replaceOwned(u8, gpa, checks, "\"finding_offset\": 0", "\"finding_offset\": 3");
        defer gpa.free(mutated);
        try writePayload(io, dir, publication_checks.output_path, mutated);
        try std.testing.expectError(error.InvalidChecksReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
    {
        // Hostile checks report with offsets/counts near maxInt(usize).
        const artifacts = try buildArtifactsBytes(gpa, "default", &records);
        defer gpa.free(artifacts);
        try writePayload(io, tmp.dir, "target/_boris/proof/artifacts.json", artifacts);
        const hostile = try buildHostileChecksBytes(gpa, artifacts);
        defer gpa.free(hostile);
        try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", hostile);
        const claims = try buildClaimsBytes(gpa, artifacts, hostile, .{});
        defer gpa.free(claims);
        try writePayload(io, tmp.dir, "target/_boris/proof/claims.json", claims);
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        try std.testing.expectError(error.InvalidChecksReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
}

fn buildHostileChecksBytes(gpa: std.mem.Allocator, artifacts_bytes: []const u8) ![]u8 {
    const digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
    const max_minus_one = "18446744073709551614";
    const max_value = "18446744073709551615";
    const scope = "{\"subject_statuses\": [\"committed\"], \"subject_kinds\": [], \"subject_sha256\": \"" ++ test_digest ++ "\", \"supporting_statuses\": [\"committed\"], \"supporting_kinds\": [], \"supporting_sha256\": \"" ++ test_digest ++ "\"}";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"format\": \"boris-publication-checks\",\n  \"schema_version\": 1,\n  \"target\": \"default\",\n  \"artifact_inventory\": {\n    \"path\": \"_boris/proof/artifacts.json\",\n    \"bytes\": ");
    try json_out.writeUsize(&out, gpa, artifacts_bytes.len);
    try out.appendSlice(gpa, ",\n    \"sha256\": \"");
    try out.appendSlice(gpa, &digest);
    try out.appendSlice(gpa, "\",\n    \"format\": \"boris-publication-artifacts\",\n    \"schema_version\": 1,\n    \"target\": \"default\",\n    \"artifact_count\": 1\n  },\n  \"checks\": [\n    {\"id\": \"artifact-integrity\", \"eligible\": true, \"ran\": true, \"status\": \"passed\", \"coverage\": \"complete\", \"scope\": ");
    try out.appendSlice(gpa, scope);
    try out.appendSlice(gpa, ", \"counts\": {\"eligible\": 1, \"checked\": 1, \"findings\": ");
    try out.appendSlice(gpa, max_minus_one);
    try out.appendSlice(gpa, "}, \"finding_offset\": 0},\n    {\"id\": \"rendered-html\", \"eligible\": true, \"ran\": true, \"status\": \"passed\", \"coverage\": \"complete\", \"scope\": ");
    try out.appendSlice(gpa, scope);
    try out.appendSlice(gpa, ", \"counts\": {\"eligible\": 1, \"checked\": 1, \"findings\": ");
    try out.appendSlice(gpa, max_minus_one);
    try out.appendSlice(gpa, "}, \"finding_offset\": ");
    try out.appendSlice(gpa, max_minus_one);
    try out.appendSlice(gpa, "},\n    {\"id\": \"rendered-search\", \"eligible\": true, \"ran\": true, \"status\": \"passed\", \"coverage\": \"complete\", \"scope\": ");
    try out.appendSlice(gpa, scope);
    try out.appendSlice(gpa, ", \"counts\": {\"eligible\": 1, \"checked\": 1, \"findings\": 0}, \"finding_offset\": ");
    try out.appendSlice(gpa, max_value);
    try out.appendSlice(gpa, "}\n  ],\n  \"findings\": []\n}\n");
    return out.toOwnedSlice(gpa);
}

test "cross-wired claim-to-check binding and broken limitation references are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};

    {
        try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
        defer gpa.free(claims);
        const mutated = try std.mem.replaceOwned(
            u8,
            gpa,
            claims,
            "\"check_id\": \"artifact-integrity\"",
            "\"check_id\": \"rendered-html\"",
        );
        defer gpa.free(mutated);
        try writePayload(io, dir, publication_claims.output_path, mutated);
        try std.testing.expectError(error.InvalidClaimsReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
    {
        try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
        defer gpa.free(claims);
        const mutated = try std.mem.replaceOwned(
            u8,
            gpa,
            claims,
            "\"limitation_ids\": [\"target-local-only\"",
            "\"limitation_ids\": [\"nonexistent\"",
        );
        defer gpa.free(mutated);
        try writePayload(io, dir, publication_claims.output_path, mutated);
        try std.testing.expectError(error.InvalidClaimsReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
    {
        try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
        defer gpa.free(claims);
        const mutated = try std.mem.replaceOwned(
            u8,
            gpa,
            claims,
            "\"applies_to_claims\": [\"committed-artifacts-match-inventory\", \"rendered-html-passed-declared-audit\", \"rendered-search-matches-selected-html\"]",
            "\"applies_to_claims\": [\"committed-artifacts-match-inventory\"]",
        );
        defer gpa.free(mutated);
        try writePayload(io, dir, publication_claims.output_path, mutated);
        try std.testing.expectError(error.InvalidClaimsReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    }
}

test "no trailing JSON is tolerated after any report" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    const checks = try readPayload(io, dir, gpa, publication_checks.output_path);
    defer gpa.free(checks);
    const trailing = try std.mem.concat(gpa, u8, &.{ checks, " {} extra" });
    defer gpa.free(trailing);
    try writePayload(io, dir, publication_checks.output_path, trailing);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterClaims(io, gpa, dir, "default", .{}));

    // Restore the committed checks bytes so the claims variant starts from a
    // healthy evidence set and the failure comes from claims.json alone.
    try writePayload(io, dir, publication_checks.output_path, checks);
    const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
    defer gpa.free(claims);
    const claims_trailing = try std.mem.concat(gpa, u8, &.{ claims, " {} extra" });
    defer gpa.free(claims_trailing);
    try writePayload(io, dir, publication_claims.output_path, claims_trailing);
    try std.testing.expectError(error.InvalidClaimsReport, writeAfterClaims(io, gpa, dir, "default", .{}));
}

fn expectJsonStrings(value: std.json.Value, expected: []const []const u8) !void {
    const items = value.array.items;
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |want, index| try std.testing.expectEqualStrings(want, items[index].string);
}

test "publication touches runtime vocabulary matches its draft 2020-12 schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const schema_bytes = try readPayload(io, Io.Dir.cwd(), gpa, "docs/contracts/schemas/publication-touches-1.schema.json");
    defer gpa.free(schema_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", root.get("$schema").?.string);
    try std.testing.expectEqualStrings(report_format, root.get("properties").?.object.get("format").?.object.get("const").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("properties").?.object.get("schema_version").?.object.get("const").?.integer);
    try expectJsonStrings(root.get("required").?, &.{ "format", "schema_version", "target", "inputs", "nodes", "edges" });

    const defs = root.get("$defs").?.object;
    try expectJsonStrings(defs.get("inputs").?.object.get("required").?, &.{ "artifacts", "checks", "claims" });
    try expectJsonStrings(defs.get("input_common").?.object.get("required").?, &.{ "path", "bytes", "sha256", "format", "schema_version", "target" });
    try expectJsonStrings(defs.get("artifacts_input").?.object.get("allOf").?.array.items[1].object.get("required").?, &.{"artifact_count"});
    try expectJsonStrings(defs.get("checks_input").?.object.get("allOf").?.array.items[1].object.get("required").?, &.{ "check_count", "finding_count" });
    try expectJsonStrings(defs.get("claims_input").?.object.get("allOf").?.array.items[1].object.get("required").?, &.{ "claim_count", "limitation_count" });

    try expectJsonStrings(defs.get("target_node").?.object.get("required").?, &.{ "kind", "id", "metadata" });
    try expectJsonStrings(defs.get("artifact_node").?.object.get("properties").?.object.get("metadata").?.object.get("required").?, &.{ "inventory_index", "path", "kind", "status", "required" });
    try expectJsonStrings(defs.get("check_node").?.object.get("properties").?.object.get("metadata").?.object.get("required").?, &.{ "check_index", "check_id", "status", "coverage" });
    try expectJsonStrings(defs.get("finding_node").?.object.get("properties").?.object.get("metadata").?.object.get("required").?, &.{ "finding_index", "check_id", "check_finding_index", "code", "severity", "subject" });
    try expectJsonStrings(defs.get("subject").?.object.get("required").?, &.{ "kind", "id", "target" });
    try expectJsonStrings(defs.get("claim_node").?.object.get("properties").?.object.get("metadata").?.object.get("required").?, &.{ "claim_index", "claim_id", "status" });
    try expectJsonStrings(defs.get("limitation_node").?.object.get("properties").?.object.get("metadata").?.object.get("required").?, &.{ "limitation_index", "limitation_id", "source" });

    try expectJsonStrings(defs.get("artifact_kind").?.object.get("enum").?, &.{ "html-page", "theme-asset", "content-asset", "rendered-search", "sitemap", "rss", "llms" });
    try expectJsonStrings(defs.get("artifact_status").?.object.get("enum").?, &.{ "committed", "omitted-by-plan", "not-applicable" });
    try expectJsonStrings(defs.get("check_id").?.object.get("enum").?, &.{ "artifact-integrity", "rendered-html", "rendered-search" });
    try expectJsonStrings(defs.get("check_status").?.object.get("enum").?, &.{ "passed", "failed", "incomplete", "not-applicable" });
    try expectJsonStrings(defs.get("coverage").?.object.get("enum").?, &.{ "complete", "incomplete", "not-applicable" });
    try expectJsonStrings(defs.get("claim_id").?.object.get("enum").?, &.{
        "committed-artifacts-match-inventory",
        "rendered-html-passed-declared-audit",
        "rendered-search-matches-selected-html",
    });
    try expectJsonStrings(defs.get("claim_status").?.object.get("enum").?, &.{ "verified", "failed", "not-verified" });
    try expectJsonStrings(defs.get("limitation_id").?.object.get("enum").?, &.{
        "target-local-only",
        "no-deployment-verification",
        "no-accessibility-verification",
        "no-prose-quality-verification",
        "no-universal-reproducibility-claim",
        "omitted-projections-not-certified",
    });

    const edge_def_order = [_][]const u8{ "target_owns_artifact", "artifact_subject_of_check", "artifact_supports_check", "check_reported_finding", "check_supports_claim", "claim_limited_by" };
    for (edge_def_order) |kind| {
        try std.testing.expect(defs.get(kind) != null);
    }
}

test "fixed registries keep canonical order and agree with the claims module" {
    try std.testing.expectEqual(@as(usize, 3), check_ids.len);
    try std.testing.expectEqual(@as(usize, 3), claim_ids.len);
    try std.testing.expectEqual(@as(usize, 6), limitation_ids.len);
    try std.testing.expectEqualStrings(check_ids[0], "artifact-integrity");
    try std.testing.expectEqualStrings(check_ids[2], "rendered-search");
    try std.testing.expectEqualStrings(claim_ids[0], publication_claims.claim_ids[0]);
    try std.testing.expectEqualStrings(claim_ids[2], publication_claims.claim_ids[2]);
    try std.testing.expectEqualStrings(limitation_ids[0], publication_claims.limitation_ids[0]);
    try std.testing.expectEqualStrings(limitation_ids[5], publication_claims.limitation_ids[5]);
    try std.testing.expectEqual(@as(usize, 5), claim_limitation_ids[0].len);
    try std.testing.expectEqual(@as(usize, 6), claim_limitation_ids[2].len);
    try std.testing.expectEqualStrings(claim_limitation_ids[2][5], limitation_ids[5]);
    for (limitation_applies_to_claims[0..5]) |claims| try std.testing.expectEqual(@as(usize, 3), claims.len);
    try std.testing.expectEqual(@as(usize, 1), limitation_applies_to_claims[5].len);
    try std.testing.expectEqualStrings(limitation_applies_to_claims[5][0], claim_ids[2]);
}

/// Minimal valid parsed evidence context for pure graph-validation tests.
const GraphContext = struct {
    io: Io,
    gpa: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    inventory: artifact_inventory.Inventory,
    parsed_checks: ParsedChecks,
    parsed_claims: ParsedClaims,

    fn deinit(self: *GraphContext) void {
        self.inventory.deinit();
        freeParsedChecks(self.gpa, &self.parsed_checks);
        freeParsedClaims(self.gpa, &self.parsed_claims);
        self.tmp.cleanup();
    }
};

fn freeParsedChecks(gpa: std.mem.Allocator, parsed: *const ParsedChecks) void {
    for (parsed.checks) |check| freeParsedCheck(gpa, &check);
    for (parsed.findings) |finding| freeParsedFinding(gpa, finding);
    gpa.free(parsed.findings);
}

fn freeParsedClaims(gpa: std.mem.Allocator, parsed: *const ParsedClaims) void {
    for (parsed.claims) |claim| freeParsedClaim(gpa, claim);
    for (parsed.limitations) |limitation| freeParsedLimitation(gpa, limitation);
}

fn makeGraphContext(
    io: Io,
    gpa: std.mem.Allocator,
    records: []const artifact_inventory.Record,
    spec: TestFixtureSpec,
) !GraphContext {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try prepareTarget(io, gpa, tmp.dir, "target", records, spec);
    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);

    const artifacts_path = try std.mem.concat(gpa, u8, &.{ "target/", artifact_inventory.output_path });
    defer gpa.free(artifacts_path);
    const checks_path = try std.mem.concat(gpa, u8, &.{ "target/", publication_checks.output_path });
    defer gpa.free(checks_path);
    const claims_path = try std.mem.concat(gpa, u8, &.{ "target/", publication_claims.output_path });
    defer gpa.free(claims_path);

    const artifacts = try readPayload(io, tmp.dir, gpa, artifacts_path);
    defer gpa.free(artifacts);
    const checks = try readPayload(io, tmp.dir, gpa, checks_path);
    defer gpa.free(checks);
    const claims = try readPayload(io, tmp.dir, gpa, claims_path);
    defer gpa.free(claims);

    var artifacts_reader = std.Io.Reader.fixed(artifacts);
    var inventory = try artifact_inventory.parseStream(gpa, &artifacts_reader, spec.target);
    errdefer inventory.deinit();
    var checks_reader = std.Io.Reader.fixed(checks);
    const parsed_checks = try parseChecksStream(gpa, &checks_reader, spec.target);
    errdefer freeParsedChecks(gpa, &parsed_checks);
    var claims_reader = std.Io.Reader.fixed(claims);
    const parsed_claims = try parseClaimsStream(gpa, &claims_reader, spec.target);
    errdefer freeParsedClaims(gpa, &parsed_claims);

    return .{
        .io = io,
        .gpa = gpa,
        .tmp = tmp,
        .inventory = inventory,
        .parsed_checks = parsed_checks,
        .parsed_claims = parsed_claims,
    };
}

test "node kind/id mismatch is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .artifact, .id = "target" },
        .{ .kind = .check, .id = "artifact:index.html" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &.{}),
    );
}

test "duplicate node ids are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .target, .id = "target" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &.{}),
    );
}

test "duplicate edge tuples are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .artifact, .id = "artifact:index.html" },
    };
    const edges = [_]Edge{
        .{ .kind = .target_owns_artifact, .from = "target", .to = "artifact:index.html" },
        .{ .kind = .target_owns_artifact, .from = "target", .to = "artifact:index.html" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &edges),
    );
}

test "dangling edge endpoints are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .check, .id = "check:artifact-integrity" },
    };
    const edges = [_]Edge{
        .{ .kind = .check_supports_claim, .from = "check:artifact-integrity", .to = "claim:missing" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &edges),
    );
}

test "an edge kind connecting forbidden node kinds is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .claim, .id = "claim:committed-artifacts-match-inventory" },
    };
    const edges = [_]Edge{
        .{ .kind = .target_owns_artifact, .from = "target", .to = "claim:committed-artifacts-match-inventory" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &edges),
    );
}

test "wrong edge direction is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .artifact, .id = "artifact:index.html" },
    };
    // target-owns-artifact must be target -> artifact; reversed is forbidden.
    const edges = [_]Edge{
        .{ .kind = .target_owns_artifact, .from = "artifact:index.html", .to = "target" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &edges),
    );
}

/// Free a graph produced by `buildNodesAndEdges` under a general-purpose
/// allocator: every node id, every edge endpoint string, and the two backing
/// arrays. The literal "target" id is not allocated and must not be freed.
fn freeNodesAndEdges(gpa: std.mem.Allocator, nodes: []Node, edges: []Edge) void {
    freeNodes(gpa, nodes);
    gpa.free(nodes);
    freeEdges(gpa, edges);
    gpa.free(edges);
}

test "reordered nodes are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    var nodes = try buildNodesAndEdges(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer freeNodesAndEdges(gpa, nodes.nodes, nodes.edges);
    // Swap the first two nodes (target and first artifact).
    std.mem.swap(Node, &nodes.nodes[0], &nodes.nodes[1]);
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, nodes.nodes, nodes.edges),
    );
}

test "reordered edge kinds are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    var nodes = try buildNodesAndEdges(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer freeNodesAndEdges(gpa, nodes.nodes, nodes.edges);
    try std.testing.expect(nodes.edges.len >= 2);
    // Swap a target-owns edge with a later subject edge.
    std.mem.swap(Edge, &nodes.edges[0], &nodes.edges[nodes.edges.len - 1]);
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, nodes.nodes, nodes.edges),
    );
}

test "source-major order violation is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    var nodes = try buildNodesAndEdges(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer freeNodesAndEdges(gpa, nodes.nodes, nodes.edges);
    try std.testing.expect(nodes.edges.len >= 4);
    // Within one edge kind, source index must be primary. Swap a subject edge
    // for a later artifact ahead of one for an earlier artifact.
    std.mem.swap(Edge, &nodes.edges[1], &nodes.edges[2]);
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, nodes.nodes, nodes.edges),
    );
}

// Negative control: the validator is reached through a test seam that hands
// it a graph with one dangling generated edge. This proves the runtime
// invariant (every edge endpoint exists) is actually enforced, not just
// documented.
test "test seam: a single dangling generated edge fails validation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .check, .id = "check:artifact-integrity" },
    };
    const edges = [_]Edge{
        .{ .kind = .check_reported_finding, .from = "check:artifact-integrity", .to = "finding:artifact-integrity:9" },
    };
    try std.testing.expectError(
        error.InvalidChecksReport,
        validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, &nodes, &edges),
    );
}

// Canonical edge-kind-major negative control. With an early html-page artifact
// that supports rendered-search and a later rendered-search artifact that stays
// a subject of artifact-integrity, the contract requires every
// `artifact-subject-of-check` edge (ordered by artifact index then check index)
// to precede every `artifact-supports-check` edge. The pre-fix interleaved
// derivation emitted the support edge for the early artifact before the later
// artifact's subject edges, which this exact-order assertion rejects.
test "edge derivation is edge-kind-major with artifact index then check index" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("a.html", .html_page, "<main></main>"),
        recordFor("z-search.json", .rendered_search, "{}"),
    };
    const spec = TestFixtureSpec{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        },
    };
    try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    const touches = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(touches);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, touches, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const edges = root.get("edges").?.array.items;
    try std.testing.expectEqual(@as(usize, 2 + 4 + 1 + 0 + 3 + 16), edges.len);

    const expected_artifact_edges = [_][]const u8{
        "target-owns-artifact|target|artifact:a.html",
        "target-owns-artifact|target|artifact:z-search.json",
        "artifact-subject-of-check|artifact:a.html|check:artifact-integrity",
        "artifact-subject-of-check|artifact:a.html|check:rendered-html",
        "artifact-subject-of-check|artifact:z-search.json|check:artifact-integrity",
        "artifact-subject-of-check|artifact:z-search.json|check:rendered-search",
        "artifact-supports-check|artifact:a.html|check:rendered-search",
    };
    for (expected_artifact_edges, 0..) |expected, index| {
        const edge = edges[index].object;
        var buffer: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{s}|{s}|{s}", .{
            edge.get("kind").?.string,
            edge.get("from").?.string,
            edge.get("to").?.string,
        }) catch return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected, label);
    }
    // The remaining edges are check-supports-claim (3), then claim-limited-by.
    for (edges[7..10]) |edge| {
        try std.testing.expectEqualStrings("check-supports-claim", edge.object.get("kind").?.string);
    }
    for (edges[10..]) |edge| {
        try std.testing.expectEqualStrings("claim-limited-by", edge.object.get("kind").?.string);
    }
}

const wrong_digest_64 = "0" ** 64;

/// Semantic-tamper control: rebuild the evidence tree from a spec whose check
/// semantics are invalid while every root byte binding stays self-consistent,
/// then prove `writeAfterClaims` rejects with `InvalidChecksReport` and the
/// prior `touches.json` survives byte-for-byte.
fn expectChecksTamperRejected(
    io: Io,
    gpa: std.mem.Allocator,
    records: []const artifact_inventory.Record,
    clean: TestFixtureSpec,
    tampered: TestFixtureSpec,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try prepareTarget(io, gpa, tmp.dir, "target", records, clean);
    const prior = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(prior);
    try prepareTarget(io, gpa, tmp.dir, "target", records, tampered);
    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    const after = try readPayload(io, dir, gpa, output_path);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, prior, after);
}

// Every case keeps root byte bindings correct (claims.json is rebuilt from the
// tampered checks bytes) so the rejection comes from semantic check
// validation, not from a stale binding.
test "checks semantic tampering is rejected and preserves the prior touches" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const one = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const search_pair = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("_boris/search/search-index.json", .rendered_search, "{}"),
    };
    const clean = TestFixtureSpec{};
    const clean_search = TestFixtureSpec{ .artifact_count = 2 };
    const unselected_search = TestCheckSpec{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .supporting_statuses = &.{"committed"},
        .supporting_kinds = &.{"html-page"},
        .status = "not-applicable",
        .coverage = "not-applicable",
        .eligible = 0,
        .checked = 0,
        .report_eligible = false,
        .report_ran = false,
    };

    // 1. eligible=false + ran=false + passed.
    {
        const tampered = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{}, .report_eligible = false, .report_ran = false, .status = "passed" },
            .{ .subject_kinds = &.{"html-page"} },
            unselected_search,
        } };
        try expectChecksTamperRejected(io, gpa, &one, clean, tampered);
    }
    // 2. checked > eligible.
    {
        const tampered = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{}, .eligible = 1, .checked = 2, .status = "passed" },
            .{ .subject_kinds = &.{"html-page"} },
            unselected_search,
        } };
        try expectChecksTamperRejected(io, gpa, &one, clean, tampered);
    }
    // 3. Selected search with eligible count 0.
    {
        const tampered = TestFixtureSpec{ .artifact_count = 2, .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "passed", .coverage = "complete", .eligible = 0 },
        } };
        try expectChecksTamperRejected(io, gpa, &search_pair, clean_search, tampered);
    }
    // 3b. Selected search with eligible count 2.
    {
        const tampered = TestFixtureSpec{ .artifact_count = 2, .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "passed", .coverage = "complete", .eligible = 2 },
        } };
        try expectChecksTamperRejected(io, gpa, &search_pair, clean_search, tampered);
    }
    // 4. Unselected search with ran=true.
    {
        const tampered = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_statuses = &.{}, .subject_kinds = &.{}, .supporting_statuses = &.{"committed"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = true },
        } };
        try expectChecksTamperRejected(io, gpa, &one, clean, tampered);
    }
    // 5. Subject digest inconsistent with selectors.
    {
        const tampered = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{}, .subject_sha256 = wrong_digest_64 },
            .{ .subject_kinds = &.{"html-page"} },
            unselected_search,
        } };
        try expectChecksTamperRejected(io, gpa, &one, clean, tampered);
    }
    // 6. Supporting digest inconsistent with selectors.
    {
        const tampered = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{}, .supporting_sha256 = wrong_digest_64 },
            .{ .subject_kinds = &.{"html-page"} },
            unselected_search,
        } };
        try expectChecksTamperRejected(io, gpa, &one, clean, tampered);
    }
    // 7. counts.eligible inconsistent with the selector result.
    {
        const tampered = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{}, .eligible = 99 },
            .{ .subject_kinds = &.{"html-page"} },
            unselected_search,
        } };
        try expectChecksTamperRejected(io, gpa, &one, clean, tampered);
    }
}

const TamperError = std.mem.Allocator.Error || error{TestUnexpectedResult};

/// Replace the first `"<field>": "<64 hex>"` value in the claims bytes with a
/// wrong digest, keeping every other byte identical so root bindings survive.
fn tamperClaimsDigestField(
    gpa: std.mem.Allocator,
    claims: []const u8,
    field: []const u8,
) TamperError![]u8 {
    const needle = try std.mem.concat(gpa, u8, &.{ "\"", field, "\": \"" });
    defer gpa.free(needle);
    const pos = std.mem.indexOf(u8, claims, needle) orelse return error.TestUnexpectedResult;
    const value_start = pos + needle.len;
    var out = try gpa.dupe(u8, claims);
    errdefer gpa.free(out);
    @memcpy(out[value_start .. value_start + 64], wrong_digest_64);
    return out;
}

/// Claims coordinated-tamper control: establish a prior touches report, tamper
/// one semantic field of claims.json while keeping every root byte binding
/// intact, and prove the atlas rejects with `InvalidClaimsReport` while the
/// prior report survives byte-for-byte.
fn expectClaimsTamperRejected(
    io: Io,
    gpa: std.mem.Allocator,
    records: []const artifact_inventory.Record,
    spec: TestFixtureSpec,
    tamper: *const fn (gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try prepareTarget(io, gpa, tmp.dir, "target", records, spec);
    const prior = try runTouches(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(prior);
    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    const claims = try readPayload(io, dir, gpa, publication_claims.output_path);
    defer gpa.free(claims);
    const mutated = try tamper(gpa, claims);
    defer gpa.free(mutated);
    try writePayload(io, dir, publication_claims.output_path, mutated);
    try std.testing.expectError(error.InvalidClaimsReport, writeAfterClaims(io, gpa, dir, "default", .{}));
    const after = try readPayload(io, dir, gpa, output_path);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, prior, after);
}

fn tamperClaimStatusToVerified(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"status\": \"failed\"", "\"status\": \"verified\"");
}

fn tamperEvidenceCheckStatus(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"check_status\": \"passed\"", "\"check_status\": \"incomplete\"");
}

fn tamperEvidenceCoverage(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"coverage\": \"complete\"", "\"coverage\": \"incomplete\"");
}

fn tamperEvidenceCounts(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"checked\": 1", "\"checked\": 2");
}

fn tamperEvidenceSubjectDigest(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return tamperClaimsDigestField(gpa, claims, "subject_sha256");
}

fn tamperEvidenceChecksReportDigest(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return tamperClaimsDigestField(gpa, claims, "checks_report_sha256");
}

fn tamperEvidenceReason(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"reason\": null", "\"reason\": \"check-failed\"");
}

fn tamperClaimScope(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"subject_statuses\": [\"committed\"]", "\"subject_statuses\": []");
}

fn tamperClaimStatement(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"statement\": \"Every committed", "\"statement\": \"Tampered");
}

fn tamperLimitationStatement(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(u8, gpa, claims, "\"statement\": \"These claims describe", "\"statement\": \"Tampered");
}

fn tamperLimitationSource(gpa: std.mem.Allocator, claims: []const u8) TamperError![]u8 {
    return std.mem.replaceOwned(
        u8,
        gpa,
        claims,
        "\"source\": \"docs/contracts/publication-checks.md#authority-and-transaction-boundary\"",
        "\"source\": \"tampered-source\"",
    );
}

// Eleven coordinated claims tamper cases. Root byte bindings are always
// updated so the failure comes from `validateClaimsAgainstChecks` or the
// strict statement/source registries, never from a stale binding.
test "claims coordinated tampering is rejected and preserves the prior touches" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const one = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const unselected_search = TestCheckSpec{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .supporting_statuses = &.{"committed"},
        .supporting_kinds = &.{"html-page"},
        .status = "not-applicable",
        .coverage = "not-applicable",
        .eligible = 0,
        .checked = 0,
        .report_eligible = false,
        .report_ran = false,
    };
    const clean = TestFixtureSpec{};

    // 1. Failed check + verified claim: the check is failed, but the claim
    // claims verified. The claim mapping must reject.
    {
        const failed_spec = TestFixtureSpec{ .checks = .{
            .{ .subject_kinds = &.{}, .status = "failed", .coverage = "complete", .findings = &.{
                .{ .code = "ARTIFACT_DIGEST_MISMATCH", .subject_id = "index.html" },
            } },
            .{ .subject_kinds = &.{"html-page"} },
            unselected_search,
        } };
        try expectClaimsTamperRejected(io, gpa, &one, failed_spec, tamperClaimStatusToVerified);
    }
    // 2. Wrong evidence check_status.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperEvidenceCheckStatus);
    // 3. Wrong evidence coverage.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperEvidenceCoverage);
    // 4. Wrong evidence counts.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperEvidenceCounts);
    // 5. Wrong evidence scope digest.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperEvidenceSubjectDigest);
    // 6. Wrong per-claim checks_report_sha256.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperEvidenceChecksReportDigest);
    // 7. Wrong reason.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperEvidenceReason);
    // 8. Claim scope differs from check scope.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperClaimScope);
    // 9. Wrong claim statement.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperClaimStatement);
    // 10. Wrong limitation statement.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperLimitationStatement);
    // 11. Wrong limitation source.
    try expectClaimsTamperRejected(io, gpa, &one, clean, tamperLimitationSource);
}

// Parser leak controls under `std.testing.allocator`: success paths free
// every allocated string and backing slice, and mid-parse failures release
// every partial allocation through `errdefer`. `skipJsonValue` reads only
// non-allocating scanner tokens (slices into the scanner's internal buffer),
// so skipping nested finding bodies can never leak allocated tokens under a
// general-purpose allocator.
test "checks and claims parsers are leak-free under std.testing.allocator" {
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const artifacts = try buildArtifactsBytes(gpa, "default", &records);
    defer gpa.free(artifacts);
    const checks = try buildChecksBytes(gpa, artifacts, .{});
    defer gpa.free(checks);
    const claims = try buildClaimsBytes(gpa, artifacts, checks, .{});
    defer gpa.free(claims);

    // Success paths: parse and fully free.
    {
        var reader = std.Io.Reader.fixed(checks);
        const parsed = try parseChecksStream(gpa, &reader, "default");
        freeParsedChecks(gpa, &parsed);
    }
    {
        var reader = std.Io.Reader.fixed(claims);
        const parsed = try parseClaimsStream(gpa, &reader, "default");
        freeParsedClaims(gpa, &parsed);
    }

    // Mid-parse failure paths: truncated streams reject with no leaks.
    {
        const cut = checks.len / 2;
        var reader = std.Io.Reader.fixed(checks[0..cut]);
        try std.testing.expectError(error.InvalidChecksReport, parseChecksStream(gpa, &reader, "default"));
    }
    {
        const cut = claims.len / 2;
        var reader = std.Io.Reader.fixed(claims[0..cut]);
        try std.testing.expectError(error.InvalidClaimsReport, parseClaimsStream(gpa, &reader, "default"));
    }
    // Truncate inside the findings body, which exercises skipping nested
    // values mid-parse.
    {
        const pos = std.mem.indexOf(u8, checks, "\"findings\"") orelse return error.TestUnexpectedResult;
        const cut = pos + 8;
        var reader = std.Io.Reader.fixed(checks[0..cut]);
        try std.testing.expectError(error.InvalidChecksReport, parseChecksStream(gpa, &reader, "default"));
    }
}

// ---------------------------------------------------------------------------
// Graph construction ownership under a failing allocator.
//
// `buildNodesAndEdges` and the expected-graph helpers must release every
// completed allocation when a later allocation fails, under a
// general-purpose allocator. Each test below injects an OutOfMemory at one
// exact allocation index (deterministic for the fixed fixtures) and requires
// the error to surface with zero leaks and zero double frees; the
// `std.testing.allocator` teardown check fails the test otherwise.
// ---------------------------------------------------------------------------

const unselected_search_spec = TestCheckSpec{
    .subject_statuses = &.{},
    .subject_kinds = &.{},
    .supporting_statuses = &.{"committed"},
    .supporting_kinds = &.{"html-page"},
    .status = "not-applicable",
    .coverage = "not-applicable",
    .eligible = 0,
    .checked = 0,
    .report_eligible = false,
    .report_ran = false,
};

const finding_spec = TestFixtureSpec{ .checks = .{
    .{ .subject_kinds = &.{}, .status = "failed", .coverage = "complete", .findings = &.{
        .{ .code = "ARTIFACT_DIGEST_MISMATCH", .subject_id = "index.html" },
    } },
    .{ .subject_kinds = &.{"html-page"} },
    unselected_search_spec,
} };

/// Run `buildNodesAndEdges` under a failing allocator that fails at exactly
/// the given allocation index and require OutOfMemory with no leaks.
fn expectGraphAllocFailure(
    io: Io,
    gpa: std.mem.Allocator,
    records: []const artifact_inventory.Record,
    spec: TestFixtureSpec,
    fail_index: usize,
) !void {
    var ctx = try makeGraphContext(io, gpa, records, spec);
    defer ctx.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
    try std.testing.expectError(
        error.OutOfMemory,
        buildNodesAndEdges(failing.allocator(), &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims),
    );
}

/// Sweep every allocation index from 0 upward: each induced failure must be
/// OutOfMemory and leak-free, and the first successful build must free
/// cleanly. Returns the total allocation count a successful build performs.
fn sweepGraphAllocations(
    io: Io,
    gpa: std.mem.Allocator,
    records: []const artifact_inventory.Record,
    spec: TestFixtureSpec,
) !usize {
    var ctx = try makeGraphContext(io, gpa, records, spec);
    defer ctx.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        // Retain the exact allocator value so the successful result is freed
        // through the same wrapper that constructed it.
        const allocator = failing.allocator();
        const graph = buildNodesAndEdges(allocator, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        freeNodesAndEdges(allocator, graph.nodes, graph.edges);
        return fail_index;
    }
}

/// Independent failing-allocator sweep totals for each expected-graph
/// helper. Pinning every count separately (instead of a combined sum) keeps
/// allocation movement between helpers visible: a helper that silently grows
/// while another shrinks would leave a combined total unchanged.
const SweepHelperCounts = struct {
    expected_node_ids: usize,
    expected_edges: usize,
    validate_graph: usize,
};

/// Sweep every allocation index for the expected-graph helpers and for
/// `validateGraph`; each induced failure must be OutOfMemory and leak-free.
/// Returns the exact allocation count of a fully successful call for each
/// helper. `validateGraph` returns no owned allocations, so its ordinary
/// internal cleanup remains sufficient; the two slice-returning helpers free
/// every successful result through the exact wrapper allocator that built it.
fn sweepExpectedGraphHelpers(io: Io, gpa: std.mem.Allocator, records: []const artifact_inventory.Record) !SweepHelperCounts {
    var ctx = try makeGraphContext(io, gpa, records, .{});
    defer ctx.deinit();
    const total_ids = blk: {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            const ids = expectedNodeIds(allocator, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            for (ids) |id| allocator.free(id);
            allocator.free(ids);
            break :blk fail_index;
        }
    };
    const total_edges = blk: {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            const allocator = failing.allocator();
            const edges = expectedEdges(allocator, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            freeEdges(allocator, edges);
            allocator.free(edges);
            break :blk fail_index;
        }
    };
    const total_validate = blk: {
        const graph = try buildNodesAndEdges(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
        defer freeNodesAndEdges(gpa, graph.nodes, graph.edges);
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            _ = validateGraph(failing.allocator(), &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, graph.nodes, graph.edges) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            break :blk fail_index;
        }
    };
    return .{
        .expected_node_ids = total_ids,
        .expected_edges = total_edges,
        .validate_graph = total_validate,
    };
}

test "graph construction is OOM-clean when an artifact node ID allocation fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    // Allocation index 1 is the first artifact node ID (`artifact:` concat);
    // index 0 is the node-list backing storage.
    try expectGraphAllocFailure(io, gpa, &records, .{}, 1);
}

test "graph construction is OOM-clean when a finding node ID allocation fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    // Finding node IDs follow target, artifact, and the three check IDs:
    // indices 0 (backing), 1 (artifact), 2-4 (checks), 5 (finding).
    try expectGraphAllocFailure(io, gpa, &records, finding_spec, 5);
}

test "graph construction is OOM-clean when a node allocation fails after completed nodes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    // Index 2 is the first check ID: target and the artifact node are already
    // completed, so the failure must free those completed IDs too.
    try expectGraphAllocFailure(io, gpa, &records, .{}, 2);
}

test "graph construction is OOM-clean when an edge `to` allocation fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    // Index 14 is the first edge's `to` (target-owns-artifact). The `from`
    // literal "target" is static and must not be freed.
    try expectGraphAllocFailure(io, gpa, &records, .{}, 14);
}

test "graph construction is OOM-clean when an edge `from` allocation fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    // Index 16 is the first owned edge `from` (first artifact-subject-of-check
    // edge), after the completed target-owns edge at index 14/15.
    try expectGraphAllocFailure(io, gpa, &records, .{}, 16);
}

test "graph construction is OOM-clean when an edge allocation fails after completed edges" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    // Index 18 is the second subject edge's `from`; by then the target-owns
    // and first subject edge are fully appended, so all owned endpoint
    // strings already stored must be released before the list is
    // deinitialized.
    try expectGraphAllocFailure(io, gpa, &records, .{}, 18);
}

test "graph construction, expected helpers, and validation succeed leak-free under std.testing.allocator" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    const graph = try buildNodesAndEdges(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer freeNodesAndEdges(gpa, graph.nodes, graph.edges);
    try validateGraph(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims, graph.nodes, graph.edges);
    const ids = try expectedNodeIds(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer {
        for (ids) |id| gpa.free(id);
        gpa.free(ids);
    }
    const edges = try expectedEdges(gpa, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer {
        freeEdges(gpa, edges);
        gpa.free(edges);
    }
}

test "graph construction is OOM-clean at every allocation point" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try std.testing.expectEqual(@as(usize, 65), try sweepGraphAllocations(io, gpa, &records, .{}));
}

test "graph construction with findings is OOM-clean at every allocation point" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    try std.testing.expectEqual(@as(usize, 68), try sweepGraphAllocations(io, gpa, &records, finding_spec));
}

test "expected graph helpers and validateGraph are OOM-clean at every allocation point" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const counts = try sweepExpectedGraphHelpers(io, gpa, &records);
    // Allocation-count determinism: each helper's exact count is pinned for
    // the fixed fixture, so growth or shrinkage in any single helper fails
    // the build even when another helper moves the other way. OOM sweep
    // coverage and ownership correctness are proven by the sweep loop itself
    // (every induced failure is OutOfMemory and leak-free under
    // std.testing.allocator); these counts are allocator behavior, not
    // output semantics.
    try std.testing.expectEqual(@as(usize, 17), counts.expected_node_ids);
    try std.testing.expectEqual(@as(usize, 50), counts.expected_edges);
    try std.testing.expectEqual(@as(usize, 77), counts.validate_graph);
}

test "successful sweep results free through the exact wrapper allocator" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    var ctx = try makeGraphContext(io, gpa, &records, .{});
    defer ctx.deinit();
    // Stand-in for the sweep loop's successful iteration: a FailingAllocator
    // whose fail_index is never reached still reports every allocation
    // through the wrapper. Successful results must be destroyed through that
    // same wrapper (never the backing gpa); the std.testing.allocator
    // teardown check fails on any leak or double free.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = std.math.maxInt(usize) });
    const allocator = failing.allocator();
    const graph = try buildNodesAndEdges(allocator, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer freeNodesAndEdges(allocator, graph.nodes, graph.edges);
    const ids = try expectedNodeIds(allocator, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    const edges = try expectedEdges(allocator, &ctx.inventory, &ctx.parsed_checks, &ctx.parsed_claims);
    defer {
        freeEdges(allocator, edges);
        allocator.free(edges);
    }
}
