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

const Scope = struct {
    subject_statuses: []const []const u8,
    subject_kinds: []const []const u8,
    supporting_statuses: []const []const u8,
    supporting_kinds: []const []const u8,
};

const ParsedCheck = struct {
    id: []const u8,
    status: []const u8,
    coverage: []const u8,
    scope: Scope,
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

const ParsedClaim = struct {
    id: []const u8,
    status: []const u8,
    evidence_check_id: []const u8,
    limitation_ids: []const []const u8,
};

const ParsedLimitation = struct {
    id: []const u8,
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
        .supporting_statuses = &.{},
        .supporting_kinds = &.{},
    };
    errdefer {
        for (scope.subject_statuses) |value| gpa.free(value);
        for (scope.subject_kinds) |value| gpa.free(value);
        for (scope.supporting_statuses) |value| gpa.free(value);
        for (scope.supporting_kinds) |value| gpa.free(value);
    }
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
            const digest = try readJsonDigest(gpa, reader);
            _ = digest;
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
            const digest = try readJsonDigest(gpa, reader);
            _ = digest;
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
    check.status = &.{};
    check.coverage = &.{};
    check.scope = Scope{
        .subject_statuses = &.{},
        .subject_kinds = &.{},
        .supporting_statuses = &.{},
        .supporting_kinds = &.{},
    };
    errdefer {
        gpa.free(check.id);
        gpa.free(check.status);
        gpa.free(check.coverage);
        for (check.scope.subject_statuses) |value| gpa.free(value);
        for (check.scope.subject_kinds) |value| gpa.free(value);
        for (check.scope.supporting_statuses) |value| gpa.free(value);
        for (check.scope.supporting_kinds) |value| gpa.free(value);
    }

    var have_id = false;
    var have_eligible = false;
    var have_ran = false;
    var have_status = false;
    var have_coverage = false;
    var have_scope = false;
    var have_counts = false;
    var have_offset = false;
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
            _ = try readJsonBool(reader);
            have_eligible = true;
        } else if (std.mem.eql(u8, key, "ran")) {
            if (have_ran) return error.InvalidChecksReport;
            _ = try readJsonBool(reader);
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
                    have_eligible_count = true;
                } else if (std.mem.eql(u8, count_key, "checked")) {
                    if (have_checked_count) return error.InvalidChecksReport;
                    const value = try readJsonInteger(gpa, reader);
                    if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
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

    check.counts_findings = finding_count;
    check.finding_offset = finding_offset;
    return check;
}

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
    }
}

fn parseArtifactsBindingAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_target: []const u8,
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
        const key = jsonTokenText(key_token) orelse return error.InvalidChecksReport;

        if (std.mem.eql(u8, key, "path")) {
            if (have_path) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, artifact_inventory.output_path)) return error.InvalidChecksReport;
            have_path = true;
        } else if (std.mem.eql(u8, key, "bytes")) {
            if (have_bytes) return error.InvalidChecksReport;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
            binding.bytes = @intCast(value);
            have_bytes = true;
        } else if (std.mem.eql(u8, key, "sha256")) {
            if (have_sha256) return error.InvalidChecksReport;
            binding.sha256 = try readJsonDigest(gpa, reader);
            have_sha256 = true;
        } else if (std.mem.eql(u8, key, "format")) {
            if (have_format) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, artifact_inventory.artifact_format)) return error.InvalidChecksReport;
            have_format = true;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (have_version) return error.InvalidChecksReport;
            if (try readJsonInteger(gpa, reader) != artifact_inventory.schema_version)
                return error.InvalidChecksReport;
            have_version = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (value.len == 0 or !std.mem.eql(u8, value, expected_target))
                return error.InvalidChecksReport;
            have_target = true;
        } else if (std.mem.eql(u8, key, "artifact_count")) {
            if (have_artifact_count) return error.InvalidChecksReport;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
            artifact_count = @intCast(value);
            have_artifact_count = true;
        } else {
            return error.InvalidChecksReport;
        }
    }

    if (!have_path or !have_bytes or !have_sha256 or !have_format or
        !have_version or !have_target or !have_artifact_count)
        return error.InvalidChecksReport;
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

fn parseClaimAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_check_id: []const u8,
) Error!ParsedClaim {
    var claim: ParsedClaim = undefined;
    claim.id = &.{};
    claim.status = &.{};
    claim.evidence_check_id = &.{};
    claim.limitation_ids = &.{};
    errdefer {
        gpa.free(claim.id);
        gpa.free(claim.status);
        gpa.free(claim.evidence_check_id);
        for (claim.limitation_ids) |value| gpa.free(value);
    }

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
            try skipJsonValue(reader);
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
            claim.evidence_check_id = try parseEvidenceCheckIdAfterBegin(gpa, reader, expected_check_id);
            have_evidence = true;
        } else if (std.mem.eql(u8, key, "scope")) {
            if (have_scope) return error.InvalidClaimsReport;
            try skipJsonValue(reader);
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

fn parseEvidenceCheckIdAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_check_id: []const u8,
) Error![]u8 {
    var check_id: []u8 = &.{};
    errdefer gpa.free(check_id);
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
            check_id = try gpa.dupe(u8, value);
            have_check_id = true;
        } else if (std.mem.eql(u8, key, "check_status") or std.mem.eql(u8, key, "coverage")) {
            if (std.mem.eql(u8, key, "check_status") and have_check_status) return error.InvalidClaimsReport;
            if (std.mem.eql(u8, key, "coverage") and have_coverage) return error.InvalidClaimsReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (std.mem.eql(u8, key, "check_status")) {
                if (!knownCheckStatus(value)) return error.InvalidClaimsReport;
                have_check_status = true;
            } else {
                if (!knownCoverage(value)) return error.InvalidClaimsReport;
                have_coverage = true;
            }
        } else if (std.mem.eql(u8, key, "counts")) {
            if (have_counts) return error.InvalidClaimsReport;
            try skipJsonValue(reader);
            have_counts = true;
        } else if (std.mem.eql(u8, key, "subject_sha256") or
            std.mem.eql(u8, key, "supporting_sha256") or
            std.mem.eql(u8, key, "checks_report_sha256"))
        {
            const digest = try readJsonDigest(gpa, reader);
            _ = digest;
            if (std.mem.eql(u8, key, "subject_sha256")) {
                if (have_subject_sha256) return error.InvalidClaimsReport;
                have_subject_sha256 = true;
            } else if (std.mem.eql(u8, key, "supporting_sha256")) {
                if (have_supporting_sha256) return error.InvalidClaimsReport;
                have_supporting_sha256 = true;
            } else {
                if (have_checks_report_sha256) return error.InvalidClaimsReport;
                have_checks_report_sha256 = true;
            }
        } else if (std.mem.eql(u8, key, "reason")) {
            if (have_reason) return error.InvalidClaimsReport;
            try skipJsonValue(reader);
            have_reason = true;
        } else {
            return error.InvalidClaimsReport;
        }
    }

    if (!have_check_id or !have_check_status or !have_coverage or !have_counts or
        !have_subject_sha256 or !have_supporting_sha256 or !have_checks_report_sha256 or
        !have_reason)
        return error.InvalidClaimsReport;
    return check_id;
}

fn parseLimitationAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!ParsedLimitation {
    var limitation: ParsedLimitation = undefined;
    limitation.id = &.{};
    limitation.applies_to_claims = &.{};
    limitation.source = &.{};
    errdefer {
        gpa.free(limitation.id);
        for (limitation.applies_to_claims) |value| gpa.free(value);
        gpa.free(limitation.source);
    }

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
            try skipJsonValue(reader);
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
            const parsed = try parseArtifactsBindingAfterBegin(gpa, &reader, expected_target);
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

fn freeParsedCheck(gpa: std.mem.Allocator, check: *const ParsedCheck) void {
    gpa.free(check.id);
    gpa.free(check.status);
    gpa.free(check.coverage);
    for (check.scope.subject_statuses) |value| gpa.free(value);
    for (check.scope.subject_kinds) |value| gpa.free(value);
    for (check.scope.supporting_statuses) |value| gpa.free(value);
    for (check.scope.supporting_kinds) |value| gpa.free(value);
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
            const parsed = try parseArtifactsBindingAfterBegin(gpa, &reader, expected_target);
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
        if (!std.mem.eql(u8, claim.evidence_check_id, check_ids[index])) return error.InvalidClaimsReport;
        if (claim.limitation_ids.len != claim_limitation_ids[index].len) return error.InvalidClaimsReport;
        for (claim.limitation_ids, claim_limitation_ids[index]) |actual, expected| {
            if (!std.mem.eql(u8, actual, expected)) return error.InvalidClaimsReport;
        }
    }
    for (limitations, 0..) |limitation, index| {
        if (!std.mem.eql(u8, limitation.id, limitation_ids[index])) return error.InvalidClaimsReport;
        if (limitation.applies_to_claims.len != limitation_applies_to_claims[index].len)
            return error.InvalidClaimsReport;
        for (limitation.applies_to_claims, limitation_applies_to_claims[index]) |actual, expected| {
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
    gpa.free(claim.status);
    gpa.free(claim.evidence_check_id);
    for (claim.limitation_ids) |value| gpa.free(value);
}

fn freeParsedLimitation(gpa: std.mem.Allocator, limitation: ParsedLimitation) void {
    gpa.free(limitation.id);
    for (limitation.applies_to_claims) |value| gpa.free(value);
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
    errdefer nodes.deinit(gpa);
    try nodes.ensureTotalCapacity(gpa, node_count);

    nodes.appendAssumeCapacity(.{ .kind = .target, .id = "target" });
    for (inventory.records, 0..) |record, index| {
        const id = try concatId(gpa, "artifact:", record.path);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .artifact, .id = id });
        _ = index;
    }
    for (checks, 0..) |check, index| {
        const id = try concatId(gpa, "check:", check.id);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .check, .id = id });
        _ = index;
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
    for (claims, 0..) |claim, index| {
        const id = try concatId(gpa, "claim:", claim.id);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .claim, .id = id });
        _ = index;
    }
    for (limitations, 0..) |limitation, index| {
        const id = try concatId(gpa, "limitation:", limitation.id);
        errdefer gpa.free(id);
        nodes.appendAssumeCapacity(.{ .kind = .limitation, .id = id });
        _ = index;
    }
    if (nodes.items.len != node_count) return error.InvalidChecksReport;

    // Edges in canonical kind order.
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(gpa);

    // 1. target-owns-artifact, one edge per inventory record in inventory order.
    for (inventory.records) |record| {
        try edges.append(gpa, .{
            .kind = .target_owns_artifact,
            .from = "target",
            .to = try concatId(gpa, "artifact:", record.path),
        });
    }

    // 2/3. artifact-subject-of-check and artifact-supports-check, artifact
    // index first, then fixed check index.
    for (inventory.records, 0..) |record, artifact_index| {
        for (checks, 0..) |check, check_index| {
            if (selected(record, check.scope.subject_statuses, check.scope.subject_kinds)) {
                try edges.append(gpa, .{
                    .kind = .artifact_subject_of_check,
                    .from = try concatId(gpa, "artifact:", record.path),
                    .to = try concatId(gpa, "check:", check.id),
                });
            }
            if (selected(record, check.scope.supporting_statuses, check.scope.supporting_kinds)) {
                try edges.append(gpa, .{
                    .kind = .artifact_supports_check,
                    .from = try concatId(gpa, "artifact:", record.path),
                    .to = try concatId(gpa, "check:", check.id),
                });
            }
            _ = artifact_index;
            _ = check_index;
        }
    }

    // 4. check-reported-finding, source = fixed check index, dest = root
    // finding order.
    for (findings, 0..) |_, finding_index| {
        const check_index = findingOwningCheck(checks, finding_index) orelse
            return error.InvalidChecksReport;
        const check_id = checks[check_index].id;
        const ordinal = finding_index - checks[check_index].finding_offset;
        try edges.append(gpa, .{
            .kind = .check_reported_finding,
            .from = try concatId(gpa, "check:", check_id),
            .to = try findingNodeId(gpa, check_id, ordinal),
        });
    }

    // 5. check-supports-claim, one edge per fixed claim binding.
    for (claims, 0..) |claim, claim_index| {
        try edges.append(gpa, .{
            .kind = .check_supports_claim,
            .from = try concatId(gpa, "check:", claim.evidence_check_id),
            .to = try concatId(gpa, "claim:", claim.id),
        });
        _ = claim_index;
    }

    // 6. claim-limited-by, claim order first, then each claim's ordered
    // limitation list.
    for (claims, 0..) |claim, claim_index| {
        for (claim.limitation_ids) |limitation_id| {
            try edges.append(gpa, .{
                .kind = .claim_limited_by,
                .from = try concatId(gpa, "claim:", claim.id),
                .to = try concatId(gpa, "limitation:", limitation_id),
            });
        }
        _ = claim_index;
    }

    return .{
        .nodes = try nodes.toOwnedSlice(gpa),
        .edges = try edges.toOwnedSlice(gpa),
    };
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

/// Runtime graph invariants that JSON Schema cannot express: unique node ids,
/// every edge endpoint exists, every edge kind connects permitted node kinds,
/// and every `(kind, from, to)` tuple is unique.
fn validateGraph(nodes: []const Node, edges: []const Edge) Error!void {
    var key_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer key_arena.deinit();
    const key_gpa = key_arena.allocator();

    var seen_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_ids.deinit(std.heap.page_allocator);
    for (nodes) |node| {
        if (seen_ids.contains(node.id)) return error.InvalidChecksReport;
        try seen_ids.put(std.heap.page_allocator, node.id, {});
    }

    var seen_tuples: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_tuples.deinit(std.heap.page_allocator);
    for (edges) |edge| {
        const from_kind = nodeKindOf(edge.from) orelse return error.InvalidChecksReport;
        const to_kind = nodeKindOf(edge.to) orelse return error.InvalidChecksReport;
        if (!edgePermits(edge, from_kind, to_kind)) return error.InvalidChecksReport;
        if (!seen_ids.contains(edge.from) or !seen_ids.contains(edge.to))
            return error.InvalidChecksReport;
        const tuple = try std.mem.concat(
            key_gpa,
            u8,
            &.{ edge.kind.name(), "\x00", edge.from, "\x00", edge.to },
        );
        if (seen_tuples.contains(tuple)) return error.InvalidChecksReport;
        try seen_tuples.put(std.heap.page_allocator, tuple, {});
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

    const derived = try buildNodesAndEdges(report_gpa, &inventory, &parsed_checks, &parsed_claims);
    try validateGraph(derived.nodes, derived.edges);

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
    eligible: usize = 1,
    checked: usize = 1,
    report_eligible: bool = true,
    report_ran: bool = true,
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
        .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
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

fn buildChecksBytes(
    gpa: std.mem.Allocator,
    artifacts_bytes: []const u8,
    spec: TestFixtureSpec,
) ![]u8 {
    const digest = cache.hexDigest(cache.hashBytes(artifacts_bytes));
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
        try out.appendSlice(gpa, test_digest);
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
        try out.appendSlice(gpa, test_digest);
        try out.appendSlice(gpa, "\"\n      },\n      \"counts\": {\"eligible\": ");
        try json_out.writeUsize(&out, gpa, check.eligible);
        try out.appendSlice(gpa, ", \"checked\": ");
        try json_out.writeUsize(&out, gpa, check.checked);
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
        try out.appendSlice(gpa, "    {\n      \"id\": \"");
        try out.appendSlice(gpa, claim_ids[index]);
        try out.appendSlice(gpa, "\",\n      \"statement\": \"statement-");
        try out.appendSlice(gpa, claim_ids[index]);
        try out.appendSlice(gpa, "\",\n      \"status\": \"");
        try out.appendSlice(gpa, claimStatusFor(check));
        try out.appendSlice(gpa, "\",\n      \"evidence\": {\n        \"check_id\": \"");
        try out.appendSlice(gpa, check_ids[index]);
        try out.appendSlice(gpa, "\",\n        \"check_status\": \"");
        try out.appendSlice(gpa, check.status);
        try out.appendSlice(gpa, "\",\n        \"coverage\": \"");
        try out.appendSlice(gpa, check.coverage);
        try out.appendSlice(gpa, "\",\n        \"counts\": {\"eligible\": ");
        try json_out.writeUsize(&out, gpa, check.eligible);
        try out.appendSlice(gpa, ", \"checked\": ");
        try json_out.writeUsize(&out, gpa, check.checked);
        try out.appendSlice(gpa, ", \"findings\": ");
        try json_out.writeUsize(&out, gpa, check.findings.len);
        try out.appendSlice(gpa, "},\n        \"subject_sha256\": \"");
        try out.appendSlice(gpa, test_digest);
        try out.appendSlice(gpa, "\",\n        \"supporting_sha256\": \"");
        try out.appendSlice(gpa, test_digest);
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
        try out.appendSlice(gpa, "\n      },\n      \"scope\": {\n        \"subject_statuses\": [\"committed\"],\n        \"subject_kinds\": [],\n        \"supporting_statuses\": [],\n        \"supporting_kinds\": []\n      },\n      \"limitation_ids\": [");
        for (claim_limitation_ids[index], 0..) |limitation_id, limitation_index| {
            if (limitation_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, limitation_id);
        }
        try out.appendSlice(gpa, "]\n    }");
    }
    try out.appendSlice(gpa, "\n  ],\n  \"limitations\": [\n");
    for (limitation_ids, 0..) |limitation_id, index| {
        if (index > 0) try out.appendSlice(gpa, ",\n");
        try out.appendSlice(gpa, "    {\n      \"id\": \"");
        try out.appendSlice(gpa, limitation_id);
        try out.appendSlice(gpa, "\",\n      \"statement\": \"statement-");
        try out.appendSlice(gpa, limitation_id);
        try out.appendSlice(gpa, "\",\n      \"applies_to_claims\": [");
        for (limitation_applies_to_claims[index], 0..) |claim_id, claim_index| {
            if (claim_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, claim_id);
        }
        try out.appendSlice(gpa, "],\n      \"source\": \"docs/contracts/publication-model.md#verification-vocabulary-and-claims\"\n    }");
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
    try prepareTarget(io, gpa, tmp.dir, "target", &records, .{ .artifact_count = 2 });

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
    const spec = TestFixtureSpec{
        .artifact_count = 3,
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "passed" },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
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
    // rendered-search with no supporting selectors at all: empty pair -> empty.
    const spec = TestFixtureSpec{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_statuses = &.{}, .supporting_kinds = &.{} },
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
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
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
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
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

test "duplicate node ids are rejected" {
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .target, .id = "target" },
    };
    try std.testing.expectError(error.InvalidChecksReport, validateGraph(&nodes, &.{}));
}

test "duplicate edge tuples are rejected" {
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .artifact, .id = "artifact:index.html" },
    };
    const edges = [_]Edge{
        .{ .kind = .target_owns_artifact, .from = "target", .to = "artifact:index.html" },
        .{ .kind = .target_owns_artifact, .from = "target", .to = "artifact:index.html" },
    };
    try std.testing.expectError(error.InvalidChecksReport, validateGraph(&nodes, &edges));
}

test "dangling edge endpoints are rejected" {
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .check, .id = "check:artifact-integrity" },
    };
    // The claim node is never emitted; the edge must not resolve.
    const edges = [_]Edge{
        .{ .kind = .check_supports_claim, .from = "check:artifact-integrity", .to = "claim:missing" },
    };
    try std.testing.expectError(error.InvalidChecksReport, validateGraph(&nodes, &edges));
}

test "an edge kind connecting forbidden node kinds is rejected" {
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .claim, .id = "claim:committed-artifacts-match-inventory" },
    };
    // target-owns-artifact must connect target -> artifact, never target -> claim.
    const edges = [_]Edge{
        .{ .kind = .target_owns_artifact, .from = "target", .to = "claim:committed-artifacts-match-inventory" },
    };
    try std.testing.expectError(error.InvalidChecksReport, validateGraph(&nodes, &edges));
}

// Negative control: the validator is reached through a test seam that hands
// it a graph with one dangling generated edge. This proves the runtime
// invariant (every edge endpoint exists) is actually enforced, not just
// documented.
test "test seam: a single dangling generated edge fails validation" {
    const nodes = [_]Node{
        .{ .kind = .target, .id = "target" },
        .{ .kind = .check, .id = "check:artifact-integrity" },
    };
    const edges = [_]Edge{
        .{ .kind = .check_reported_finding, .from = "check:artifact-integrity", .to = "finding:artifact-integrity:9" },
    };
    try std.testing.expectError(error.InvalidChecksReport, validateGraph(&nodes, &edges));
}
