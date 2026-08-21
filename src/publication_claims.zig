//! Deterministic claims-and-limitations evidence for one HTML target.
//!
//! This layer runs after the publication checks report has committed. It
//! derives exactly three fixed claims and six fixed limitations from the
//! committed artifact inventory and the committed checks report, binds both to
//! their exact current bytes, and atomically publishes one report. It performs
//! no page, artifact, deployment, accessibility, or content-quality checks of
//! its own and never invents evidence for a check that did not run.

const std = @import("std");
const Io = std.Io;
const artifact_inventory = @import("artifact_inventory.zig");
const cache = @import("cache.zig");
const json_out = @import("json_out.zig");
const publication_checks = @import("publication_checks.zig");
const json_stream = @import("publication_json_stream.zig");
const evidence_mod = @import("publication_evidence.zig");

pub const output_path = artifact_inventory.claims_output_path;
pub const report_format = "boris-publication-claims";
pub const schema_version: usize = 1;

/// Fixed first-slice claim identities, in canonical order. Each claim is bound
/// to the check of the same array position.
pub const claim_ids = [_][]const u8{
    "committed-artifacts-match-inventory",
    "rendered-html-passed-declared-audit",
    "rendered-search-matches-selected-html",
};

const check_ids = [_][]const u8{ "artifact-integrity", "rendered-html", "rendered-search" };

/// Exact canonical claim statements, indexed by `claim_ids`. The touches layer
/// validates that a claims report's statements match these bytes exactly.
pub const claim_statements = [_][]const u8{
    "Every committed artifact record selected by the artifact-integrity check was inspected and matched its declared byte count and SHA-256 digest.",
    "Every committed HTML page selected by the rendered-html check completed the declared structural, route, fragment, and duplicate-ID audit within that check's scope.",
    "The single selected rendered-search artifact matched the committed HTML page set and derived rendered-search content inspected by the rendered-search check.",
};

pub const ClaimStatus = enum {
    verified,
    failed,
    not_verified,

    pub fn name(self: ClaimStatus) []const u8 {
        return switch (self) {
            .verified => "verified",
            .failed => "failed",
            .not_verified => "not-verified",
        };
    }
};

/// Fixed first-slice limitation identities, in canonical order.
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

/// The omitted-projection limitation applies only to the rendered-search
/// claim, which is the only projection-bound first-slice claim.
const search_claim_id = claim_ids[2..3];

/// One canonical limitation row: exact statement, authoritative source
/// location, and the ordered claims it applies to. The touches layer emits
/// `source` into the atlas, so it validates rows against these exact values.
pub const LimitationRow = struct {
    statement: []const u8,
    source: []const u8,
    applies_to_claims: []const []const u8,
};

const all_claim_ids = &claim_ids;

/// Exact canonical limitation rows, indexed by `limitation_ids`.
pub const limitation_rows = [_]LimitationRow{
    .{
        .statement = "These claims describe one selected local HTML target after its commit and say nothing about any other target or environment.",
        .source = "docs/contracts/publication-checks.md#authority-and-transaction-boundary",
        .applies_to_claims = all_claim_ids,
    },
    .{
        .statement = "No deployment was performed or verified; local generation cannot verify deployed behavior.",
        .source = "docs/contracts/publication-model.md#verification-vocabulary-and-claims",
        .applies_to_claims = all_claim_ids,
    },
    .{
        .statement = "No accessibility audit was performed for any page or artifact in this target.",
        .source = "docs/contracts/publication-model.md#projections",
        .applies_to_claims = all_claim_ids,
    },
    .{
        .statement = "No prose, writing, or documentation-quality judgment was made.",
        .source = "docs/contracts/publication-model.md#verification-vocabulary-and-claims",
        .applies_to_claims = all_claim_ids,
    },
    .{
        .statement = "Deterministic bytes on one recorded environment are not universal reproducibility.",
        .source = "docs/contracts/publication-model.md#verification-vocabulary-and-claims",
        .applies_to_claims = all_claim_ids,
    },
    .{
        .statement = "An omitted or unselected projection remains explicitly unverified and is not certified by this report.",
        .source = "docs/contracts/publication-model.md#the-conductor-rule",
        .applies_to_claims = search_claim_id,
    },
};

/// The limitation set attached to each claim, in canonical limitation order.
const claim_limitation_ids = [_][]const []const u8{
    generic_limitation_ids,
    generic_limitation_ids,
    &limitation_ids,
};

pub const Options = struct {
    /// Test-only fault injection. Production callers leave both false.
    test_fail_execution: bool = false,
    test_fail_write: bool = false,
    /// Test-only seam: invoked once after both evidence handles are opened
    /// and before any byte is read. A test may replace files at this point;
    /// the already-opened handles must be unaffected.
    after_open: ?*const fn (?*anyopaque) void = null,
    after_open_context: ?*anyopaque = null,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidArtifactsReport,
    InvalidChecksReport,
    StaleChecksBinding,
    ClaimsWriteFailed,
};

const FileBinding = evidence_mod.FileBinding;

const Scope = struct {
    subject_statuses: []const []const u8,
    subject_kinds: []const []const u8,
    supporting_statuses: []const []const u8,
    supporting_kinds: []const []const u8,
};

const ParsedCheck = struct {
    id: []const u8,
    eligible: bool,
    ran: bool,
    status: []const u8,
    coverage: []const u8,
    counts: struct {
        eligible: usize,
        checked: usize,
        findings: usize,
    },
    finding_offset: usize,
    scope: Scope,
    subject_sha256: [64]u8,
    supporting_sha256: [64]u8,
};

const ParsedChecks = struct {
    artifact_binding: FileBinding,
    artifact_count: usize,
    checks: [3]ParsedCheck,
    findings_count: usize,
};

fn jsonTokenText(token: std.json.Token) ?[]const u8 {
    return json_stream.jsonTokenText(token);
}

fn freeJsonToken(gpa: std.mem.Allocator, token: std.json.Token) void {
    return json_stream.freeJsonToken(gpa, token);
}

fn nextJsonToken(reader: *std.json.Reader) Error!std.json.Token {
    return json_stream.nextJsonToken(Error, reader, error.InvalidChecksReport);
}

fn nextJsonAllocToken(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    max_value_len: usize,
) Error!std.json.Token {
    return json_stream.nextJsonAllocToken(Error, gpa, reader, max_value_len, error.InvalidChecksReport);
}

fn readJsonString(gpa: std.mem.Allocator, reader: *std.json.Reader) Error![]u8 {
    return json_stream.readJsonString(Error, gpa, reader, error.InvalidChecksReport);
}

fn readJsonInteger(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!u64 {
    return json_stream.readJsonInteger(Error, gpa, reader, error.InvalidChecksReport);
}

fn readJsonBool(reader: *std.json.Reader) Error!bool {
    return json_stream.readJsonBool(Error, reader, error.InvalidChecksReport);
}

fn validDigest(value: []const u8) bool {
    return json_stream.validDigest(value);
}

fn readJsonDigest(gpa: std.mem.Allocator, reader: *std.json.Reader) Error![64]u8 {
    return json_stream.readJsonDigest(Error, gpa, reader, error.InvalidChecksReport);
}

fn readStringArray(gpa: std.mem.Allocator, reader: *std.json.Reader) Error![][]const u8 {
    return json_stream.readStringArray(Error, gpa, reader, error.InvalidChecksReport);
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    return json_stream.containsString(values, wanted);
}

fn knownStatus(value: []const u8) bool {
    return json_stream.knownStatus(value);
}

fn knownKind(value: []const u8) bool {
    return json_stream.knownKind(value);
}

const ParsedScope = struct {
    scope: Scope,
    subject_sha256: [64]u8,
    supporting_sha256: [64]u8,
};

fn parseScopeAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) Error!ParsedScope {
    var subject_statuses: [][]const u8 = &.{};
    var subject_kinds: [][]const u8 = &.{};
    var supporting_statuses: [][]const u8 = &.{};
    var supporting_kinds: [][]const u8 = &.{};
    errdefer {
        for (subject_statuses) |value| gpa.free(value);
        for (subject_kinds) |value| gpa.free(value);
        for (supporting_statuses) |value| gpa.free(value);
        for (supporting_kinds) |value| gpa.free(value);
    }
    var subject_sha256: [64]u8 = undefined;
    var supporting_sha256: [64]u8 = undefined;
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
            subject_statuses = try readStringArray(gpa, reader);
            have_subject_statuses = true;
        } else if (std.mem.eql(u8, key, "subject_kinds")) {
            if (have_subject_kinds) return error.InvalidChecksReport;
            subject_kinds = try readStringArray(gpa, reader);
            have_subject_kinds = true;
        } else if (std.mem.eql(u8, key, "subject_sha256")) {
            if (have_subject_sha256) return error.InvalidChecksReport;
            subject_sha256 = try readJsonDigest(gpa, reader);
            have_subject_sha256 = true;
        } else if (std.mem.eql(u8, key, "supporting_statuses")) {
            if (have_supporting_statuses) return error.InvalidChecksReport;
            supporting_statuses = try readStringArray(gpa, reader);
            have_supporting_statuses = true;
        } else if (std.mem.eql(u8, key, "supporting_kinds")) {
            if (have_supporting_kinds) return error.InvalidChecksReport;
            supporting_kinds = try readStringArray(gpa, reader);
            have_supporting_kinds = true;
        } else if (std.mem.eql(u8, key, "supporting_sha256")) {
            if (have_supporting_sha256) return error.InvalidChecksReport;
            supporting_sha256 = try readJsonDigest(gpa, reader);
            have_supporting_sha256 = true;
        } else {
            return error.InvalidChecksReport;
        }
    }

    if (!have_subject_statuses or !have_subject_kinds or !have_subject_sha256 or
        !have_supporting_statuses or !have_supporting_kinds or !have_supporting_sha256)
        return error.InvalidChecksReport;
    for (subject_statuses) |value| if (!knownStatus(value)) return error.InvalidChecksReport;
    for (subject_kinds) |value| if (!knownKind(value)) return error.InvalidChecksReport;
    for (supporting_statuses) |value| if (!knownStatus(value)) return error.InvalidChecksReport;
    for (supporting_kinds) |value| if (!knownKind(value)) return error.InvalidChecksReport;

    return .{
        .scope = Scope{
            .subject_statuses = subject_statuses,
            .subject_kinds = subject_kinds,
            .supporting_statuses = supporting_statuses,
            .supporting_kinds = supporting_kinds,
        },
        .subject_sha256 = subject_sha256,
        .supporting_sha256 = supporting_sha256,
    };
}

fn freeParsedCheck(gpa: std.mem.Allocator, check: ParsedCheck) void {
    gpa.free(check.id);
    gpa.free(check.status);
    gpa.free(check.coverage);
    for (check.scope.subject_statuses) |value| gpa.free(value);
    for (check.scope.subject_kinds) |value| gpa.free(value);
    for (check.scope.supporting_statuses) |value| gpa.free(value);
    for (check.scope.supporting_kinds) |value| gpa.free(value);
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
    errdefer freeParsedCheck(gpa, check);

    var have_id = false;
    var have_eligible = false;
    var have_ran = false;
    var have_status = false;
    var have_coverage = false;
    var have_scope = false;
    var have_counts = false;
    var have_offset = false;
    var eligible_count: usize = 0;
    var checked_count: usize = 0;
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
            if (!containsString(&.{ "passed", "failed", "incomplete", "not-applicable" }, value))
                return error.InvalidChecksReport;
            check.status = try gpa.dupe(u8, value);
            have_status = true;
        } else if (std.mem.eql(u8, key, "coverage")) {
            if (have_coverage) return error.InvalidChecksReport;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!containsString(&.{ "complete", "incomplete", "not-applicable" }, value))
                return error.InvalidChecksReport;
            check.coverage = try gpa.dupe(u8, value);
            have_coverage = true;
        } else if (std.mem.eql(u8, key, "scope")) {
            if (have_scope) return error.InvalidChecksReport;
            switch (try nextJsonToken(reader)) {
                .object_begin => {},
                else => return error.InvalidChecksReport,
            }
            const parsed_scope = try parseScopeAfterBegin(gpa, reader);
            check.scope = parsed_scope.scope;
            check.subject_sha256 = parsed_scope.subject_sha256;
            check.supporting_sha256 = parsed_scope.supporting_sha256;
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
                    eligible_count = @intCast(value);
                    have_eligible_count = true;
                } else if (std.mem.eql(u8, count_key, "checked")) {
                    if (have_checked_count) return error.InvalidChecksReport;
                    const value = try readJsonInteger(gpa, reader);
                    if (value > std.math.maxInt(usize)) return error.InvalidChecksReport;
                    checked_count = @intCast(value);
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

    check.counts = .{
        .eligible = eligible_count,
        .checked = checked_count,
        .findings = finding_count,
    };
    check.finding_offset = finding_offset;
    return check;
}

fn parseBindingAfterBegin(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    expected_target: []const u8,
) Error!struct {
    binding: FileBinding,
    artifact_count: usize,
} {
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

fn countArrayElements(reader: *std.json.Reader) Error!usize {
    switch (try nextJsonToken(reader)) {
        .array_begin => {},
        else => return error.InvalidChecksReport,
    }
    var depth: usize = 0;
    var count: usize = 0;
    while (true) {
        const token = try nextJsonToken(reader);
        switch (token) {
            .array_begin => {
                // A nested array is structural content of a finding object;
                // a top-level array element is not a finding object.
                if (depth == 0) return error.InvalidChecksReport;
                depth += 1;
            },
            .object_begin => {
                if (depth == 0) count += 1;
                depth += 1;
            },
            .array_end => {
                if (depth == 0) return count;
                depth -= 1;
            },
            .object_end => {
                if (depth == 0) return error.InvalidChecksReport;
                depth -= 1;
            },
            .end_of_document => return error.InvalidChecksReport,
            else => {
                // Every top-level element must be a finding object; scalars
                // nested inside one are skipped structurally.
                if (depth == 0) return error.InvalidChecksReport;
            },
        }
    }
}

/// Validate complete check-state consistency: every combination must be
/// contract-coherent, and impossible or self-contradicting states are
/// rejected as `InvalidChecksReport`.
fn validateCheckState(checks: *const [3]ParsedCheck) Error!void {
    for (checks) |check| {
        if (check.counts.checked > check.counts.eligible) return error.InvalidChecksReport;
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

    // artifact-integrity and rendered-html are selected for every valid
    // inventory; a not-applicable report for either is self-contradicting.
    for (checks[0..2]) |check| {
        if (!check.eligible or !check.ran) return error.InvalidChecksReport;
        if (std.mem.eql(u8, check.status, "not-applicable") or
            std.mem.eql(u8, check.coverage, "not-applicable"))
            return error.InvalidChecksReport;
    }

    const search = checks[2];
    if (search.eligible) {
        if (!search.ran) return error.InvalidChecksReport;
        if (std.mem.eql(u8, search.status, "not-applicable") or
            std.mem.eql(u8, search.coverage, "not-applicable"))
            return error.InvalidChecksReport;
        if (search.counts.eligible != 1) return error.InvalidChecksReport;
    } else {
        if (search.ran) return error.InvalidChecksReport;
        if (!std.mem.eql(u8, search.status, "not-applicable") or
            !std.mem.eql(u8, search.coverage, "not-applicable"))
            return error.InvalidChecksReport;
        if (search.counts.eligible != 0 or search.counts.checked != 0 or
            search.counts.findings != 0)
            return error.InvalidChecksReport;
    }
}

/// Strictly parse the committed checks report. Only canonical check metadata
/// and the findings count are retained; finding bytes are never kept.
pub fn parseChecksStream(
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
    var binding: FileBinding = undefined;
    var artifact_count: usize = 0;
    var checks: [3]ParsedCheck = undefined;
    var checks_filled: usize = 0;
    errdefer for (checks[0..checks_filled]) |check| freeParsedCheck(gpa, check);
    var findings_count: usize = 0;

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
            if (value.len == 0) return error.InvalidChecksReport;
            if (!std.mem.eql(u8, value, expected_target)) return error.InvalidChecksReport;
            have_target = true;
        } else if (std.mem.eql(u8, key, "artifact_inventory")) {
            if (have_artifact_inventory) return error.InvalidChecksReport;
            switch (try nextJsonToken(&reader)) {
                .object_begin => {},
                else => return error.InvalidChecksReport,
            }
            const parsed = try parseBindingAfterBegin(gpa, &reader, expected_target);
            binding = parsed.binding;
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
            findings_count = try countArrayElements(&reader);
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
    for (checks[1..], 0..) |check, index| {
        const previous = checks[index];
        const expected_offset = std.math.add(
            usize,
            previous.finding_offset,
            previous.counts.findings,
        ) catch return error.InvalidChecksReport;
        if (check.finding_offset != expected_offset) return error.InvalidChecksReport;
    }
    const last = checks[checks.len - 1];
    const last_end = std.math.add(
        usize,
        last.finding_offset,
        last.counts.findings,
    ) catch return error.InvalidChecksReport;
    if (last_end != findings_count) return error.InvalidChecksReport;

    return .{
        .artifact_binding = binding,
        .artifact_count = artifact_count,
        .checks = checks,
        .findings_count = findings_count,
    };
}

/// One no-follow open per evidence input. The exact same opened regular-file
/// handle is read twice: a first streaming pass counts and hashes every byte,
/// then the handle is rewound and the exact same byte stream is handed to the
/// streaming JSON parser. A path replaced after the open can never mix
/// evidence versions, and the bytes counted and hashed are exactly the bytes
/// parsed.
const EvidenceInput = evidence_mod.EvidenceInput(Error);

const Derivation = struct {
    status: ClaimStatus,
    reason: ?[]const u8,
};

fn derive(check: ParsedCheck) Derivation {
    if (std.mem.eql(u8, check.status, "passed")) return .{ .status = .verified, .reason = null };
    if (std.mem.eql(u8, check.status, "failed")) return .{ .status = .failed, .reason = "check-failed" };
    if (std.mem.eql(u8, check.status, "incomplete"))
        return .{ .status = .not_verified, .reason = "check-incomplete" };
    if (std.mem.eql(u8, check.status, "not-applicable"))
        return .{ .status = .not_verified, .reason = "check-not-applicable" };
    unreachable;
}

/// Narrow public mapping the touches layer uses to validate that a claims
/// report's status and reason follow the publication-claims contract exactly:
/// `passed -> verified` with no reason; `failed -> failed / check-failed`;
/// `incomplete -> not-verified / check-incomplete`; and `not-applicable ->
/// not-verified / check-not-applicable`. Returns null for an unknown check
/// status so callers can reject it.
pub fn deriveStatus(check_status: []const u8) ?struct { status: []const u8, reason: ?[]const u8 } {
    if (std.mem.eql(u8, check_status, "passed")) return .{ .status = "verified", .reason = null };
    if (std.mem.eql(u8, check_status, "failed")) return .{ .status = "failed", .reason = "check-failed" };
    if (std.mem.eql(u8, check_status, "incomplete"))
        return .{ .status = "not-verified", .reason = "check-incomplete" };
    if (std.mem.eql(u8, check_status, "not-applicable"))
        return .{ .status = "not-verified", .reason = "check-not-applicable" };
    return null;
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

fn writeArtifactInventoryBlock(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    binding: FileBinding,
    inventory: *const artifact_inventory.Inventory,
) !void {
    try out.appendSlice(gpa, "{\n    \"path\": ");
    try json_out.writeString(out, gpa, artifact_inventory.output_path);
    try out.appendSlice(gpa, ",\n    \"bytes\": ");
    try json_out.writeUsize(out, gpa, binding.bytes);
    try out.appendSlice(gpa, ",\n    \"sha256\": ");
    try json_out.writeString(out, gpa, &binding.sha256);
    try out.appendSlice(gpa, ",\n    \"format\": ");
    try json_out.writeString(out, gpa, artifact_inventory.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(out, gpa, artifact_inventory.schema_version);
    try out.appendSlice(gpa, ",\n    \"target\": ");
    try json_out.writeString(out, gpa, inventory.target);
    try out.appendSlice(gpa, ",\n    \"artifact_count\": ");
    try json_out.writeUsize(out, gpa, inventory.records.len);
    try out.appendSlice(gpa, "\n  }");
}

fn writePublicationChecksBlock(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    binding: FileBinding,
    target: []const u8,
    checks: *const ParsedChecks,
) !void {
    try out.appendSlice(gpa, "{\n    \"path\": ");
    try json_out.writeString(out, gpa, publication_checks.output_path);
    try out.appendSlice(gpa, ",\n    \"bytes\": ");
    try json_out.writeUsize(out, gpa, binding.bytes);
    try out.appendSlice(gpa, ",\n    \"sha256\": ");
    try json_out.writeString(out, gpa, &binding.sha256);
    try out.appendSlice(gpa, ",\n    \"format\": ");
    try json_out.writeString(out, gpa, publication_checks.report_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(out, gpa, publication_checks.schema_version);
    try out.appendSlice(gpa, ",\n    \"target\": ");
    try json_out.writeString(out, gpa, target);
    try out.appendSlice(gpa, ",\n    \"check_count\": ");
    try json_out.writeUsize(out, gpa, checks.checks.len);
    try out.appendSlice(gpa, ",\n    \"finding_count\": ");
    try json_out.writeUsize(out, gpa, checks.findings_count);
    try out.appendSlice(gpa, "\n  }");
}

fn writeClaimEvidence(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    check: ParsedCheck,
    derivation: Derivation,
    checks_sha256: *const [64]u8,
) !void {
    try out.appendSlice(gpa, "{\n        \"check_id\": ");
    try json_out.writeString(out, gpa, check.id);
    try out.appendSlice(gpa, ",\n        \"check_status\": ");
    try json_out.writeString(out, gpa, check.status);
    try out.appendSlice(gpa, ",\n        \"coverage\": ");
    try json_out.writeString(out, gpa, check.coverage);
    try out.appendSlice(gpa, ",\n        \"counts\": {\"eligible\": ");
    try json_out.writeUsize(out, gpa, check.counts.eligible);
    try out.appendSlice(gpa, ", \"checked\": ");
    try json_out.writeUsize(out, gpa, check.counts.checked);
    try out.appendSlice(gpa, ", \"findings\": ");
    try json_out.writeUsize(out, gpa, check.counts.findings);
    try out.appendSlice(gpa, "},\n        \"subject_sha256\": ");
    try json_out.writeString(out, gpa, &check.subject_sha256);
    try out.appendSlice(gpa, ",\n        \"supporting_sha256\": ");
    try json_out.writeString(out, gpa, &check.supporting_sha256);
    try out.appendSlice(gpa, ",\n        \"checks_report_sha256\": ");
    try json_out.writeString(out, gpa, checks_sha256);
    try out.appendSlice(gpa, ",\n        \"reason\": ");
    if (derivation.reason) |reason| {
        try json_out.writeString(out, gpa, reason);
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, "\n      }");
}

fn writeClaimScope(out: *std.ArrayList(u8), gpa: std.mem.Allocator, scope: Scope) !void {
    try out.appendSlice(gpa, "{\n        \"subject_statuses\": ");
    try writeStringArray(out, gpa, scope.subject_statuses);
    try out.appendSlice(gpa, ",\n        \"subject_kinds\": ");
    try writeStringArray(out, gpa, scope.subject_kinds);
    try out.appendSlice(gpa, ",\n        \"supporting_statuses\": ");
    try writeStringArray(out, gpa, scope.supporting_statuses);
    try out.appendSlice(gpa, ",\n        \"supporting_kinds\": ");
    try writeStringArray(out, gpa, scope.supporting_kinds);
    try out.appendSlice(gpa, "\n      }");
}

fn writeReport(
    gpa: std.mem.Allocator,
    target: []const u8,
    artifact_binding: FileBinding,
    inventory: *const artifact_inventory.Inventory,
    checks_binding: FileBinding,
    checks: *const ParsedChecks,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, report_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"target\": ");
    try json_out.writeString(&out, gpa, target);
    try out.appendSlice(gpa, ",\n  \"artifact_inventory\": ");
    try writeArtifactInventoryBlock(&out, gpa, artifact_binding, inventory);
    try out.appendSlice(gpa, ",\n  \"publication_checks\": ");
    try writePublicationChecksBlock(&out, gpa, checks_binding, target, checks);
    try out.appendSlice(gpa, ",\n  \"claims\": [");
    for (checks.checks, 0..) |check, index| {
        const derivation = derive(check);
        try out.appendSlice(gpa, if (index == 0) "\n" else ",\n");
        try out.appendSlice(gpa, "    {\n      \"id\": ");
        try json_out.writeString(&out, gpa, claim_ids[index]);
        try out.appendSlice(gpa, ",\n      \"statement\": ");
        try json_out.writeString(&out, gpa, claim_statements[index]);
        try out.appendSlice(gpa, ",\n      \"status\": ");
        try json_out.writeString(&out, gpa, derivation.status.name());
        try out.appendSlice(gpa, ",\n      \"evidence\": ");
        try writeClaimEvidence(&out, gpa, check, derivation, &checks_binding.sha256);
        try out.appendSlice(gpa, ",\n      \"scope\": ");
        try writeClaimScope(&out, gpa, check.scope);
        try out.appendSlice(gpa, ",\n      \"limitation_ids\": ");
        try writeStringArray(&out, gpa, claim_limitation_ids[index]);
        try out.appendSlice(gpa, "\n    }");
    }
    try out.appendSlice(gpa, "\n  ],\n  \"limitations\": [");
    for (limitation_ids, limitation_rows, 0..) |id, row, index| {
        try out.appendSlice(gpa, if (index == 0) "\n" else ",\n");
        try out.appendSlice(gpa, "    {\n      \"id\": ");
        try json_out.writeString(&out, gpa, id);
        try out.appendSlice(gpa, ",\n      \"statement\": ");
        try json_out.writeString(&out, gpa, row.statement);
        try out.appendSlice(gpa, ",\n      \"applies_to_claims\": ");
        try writeStringArray(&out, gpa, row.applies_to_claims);
        try out.appendSlice(gpa, ",\n      \"source\": ");
        try json_out.writeString(&out, gpa, row.source);
        try out.appendSlice(gpa, "\n    }");
    }
    try out.appendSlice(gpa, "\n  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Read the committed inventory and checks report, derive the fixed claims
/// and limitations, and atomically replace the target-local report. Any error
/// before `replace` preserves an existing report.
pub fn writeAfterChecks(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    options: Options,
) Error!void {
    if (options.test_fail_execution) return error.InvalidChecksReport;
    var report_arena = std.heap.ArenaAllocator.init(gpa);
    defer report_arena.deinit();
    const report_gpa = report_arena.allocator();

    var artifacts_input: EvidenceInput = .{};
    try artifacts_input.open(io, root, artifact_inventory.output_path, error.InvalidArtifactsReport);
    defer artifacts_input.close(io);
    try artifacts_input.hashPass(error.InvalidArtifactsReport);
    try artifacts_input.rewindForParse(io, error.InvalidArtifactsReport);
    var inventory = artifact_inventory.parseStream(report_gpa, &artifacts_input.pass2.interface, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifactsReport,
    };
    defer inventory.deinit();
    const artifact_binding = artifacts_input.finish();

    var checks_input: EvidenceInput = .{};
    try checks_input.open(io, root, publication_checks.output_path, error.InvalidChecksReport);
    defer checks_input.close(io);
    if (options.after_open) |hook| hook(options.after_open_context);
    try checks_input.hashPass(error.InvalidChecksReport);
    try checks_input.rewindForParse(io, error.InvalidChecksReport);
    const parsed_checks = try parseChecksStream(report_gpa, &checks_input.pass2.interface, target);
    const checks_binding = checks_input.finish();

    if (parsed_checks.artifact_binding.bytes != artifact_binding.bytes or
        !std.mem.eql(u8, &parsed_checks.artifact_binding.sha256, &artifact_binding.sha256))
        return error.StaleChecksBinding;
    if (parsed_checks.artifact_count != inventory.records.len) return error.StaleChecksBinding;

    const report = writeReport(
        report_gpa,
        target,
        artifact_binding,
        &inventory,
        checks_binding,
        &parsed_checks,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };

    var atomic = root.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true }) catch {
        return error.ClaimsWriteFailed;
    };
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(report) catch return error.ClaimsWriteFailed;
    writer.interface.flush() catch return error.ClaimsWriteFailed;
    if (options.test_fail_write) return error.ClaimsWriteFailed;
    atomic.replace(io) catch return error.ClaimsWriteFailed;
}

/// Derive the claims report from committed inventory and checks bytes.
/// Same derivation as `writeAfterChecks`; no host directory is opened.
pub fn renderFromBytes(
    gpa: std.mem.Allocator,
    target: []const u8,
    inventory_bytes: []const u8,
    checks_bytes: []const u8,
) Error![]u8 {
    var report_arena = std.heap.ArenaAllocator.init(gpa);
    defer report_arena.deinit();
    const report_gpa = report_arena.allocator();

    var inventory_input = std.Io.Reader.fixed(inventory_bytes);
    var inventory = artifact_inventory.parseStream(report_gpa, &inventory_input, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifactsReport,
    };
    defer inventory.deinit();
    const artifact_binding = FileBinding{
        .bytes = inventory_bytes.len,
        .sha256 = cache.hexDigest(cache.hashBytes(inventory_bytes)),
    };

    var checks_input = std.Io.Reader.fixed(checks_bytes);
    const parsed_checks = try parseChecksStream(report_gpa, &checks_input, target);
    const checks_binding = FileBinding{
        .bytes = checks_bytes.len,
        .sha256 = cache.hexDigest(cache.hashBytes(checks_bytes)),
    };

    if (parsed_checks.artifact_binding.bytes != artifact_binding.bytes or
        !std.mem.eql(u8, &parsed_checks.artifact_binding.sha256, &artifact_binding.sha256))
        return error.StaleChecksBinding;
    if (parsed_checks.artifact_count != inventory.records.len) return error.StaleChecksBinding;

    const report = writeReport(
        report_gpa,
        target,
        artifact_binding,
        &inventory,
        checks_binding,
        &parsed_checks,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
    return gpa.dupe(u8, report);
}

test "derivation maps every check status to the mechanical claim vocabulary" {
    const cases = [_]struct {
        status: []const u8,
        expected: ClaimStatus,
        reason: ?[]const u8,
    }{
        .{ .status = "passed", .expected = .verified, .reason = null },
        .{ .status = "failed", .expected = .failed, .reason = "check-failed" },
        .{ .status = "incomplete", .expected = .not_verified, .reason = "check-incomplete" },
        .{ .status = "not-applicable", .expected = .not_verified, .reason = "check-not-applicable" },
    };
    for (cases) |case| {
        const check = ParsedCheck{
            .id = "artifact-integrity",
            .eligible = true,
            .ran = true,
            .status = case.status,
            .coverage = "complete",
            .counts = .{ .eligible = 0, .checked = 0, .findings = 0 },
            .finding_offset = 0,
            .scope = Scope{
                .subject_statuses = &.{},
                .subject_kinds = &.{},
                .supporting_statuses = &.{},
                .supporting_kinds = &.{},
            },
            .subject_sha256 = undefined,
            .supporting_sha256 = undefined,
        };
        const derivation = derive(check);
        try std.testing.expectEqual(case.expected, derivation.status);
        if (case.reason) |expected_reason| {
            try std.testing.expectEqualStrings(expected_reason, derivation.reason.?);
        } else {
            try std.testing.expect(derivation.reason == null);
        }
    }
}

test "publication claims runtime vocabulary matches its draft 2020-12 schema" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const schema_bytes = try readPayload(io, Io.Dir.cwd(), gpa, "docs/contracts/schemas/publication-claims-1.schema.json");
    defer gpa.free(schema_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", root.get("$schema").?.string);
    try std.testing.expectEqualStrings(report_format, root.get("properties").?.object.get("format").?.object.get("const").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("properties").?.object.get("schema_version").?.object.get("const").?.integer);
    try expectJsonStrings(root.get("required").?, &.{ "format", "schema_version", "target", "artifact_inventory", "publication_checks", "claims", "limitations" });

    const claims_schema = root.get("properties").?.object.get("claims").?.object;
    try std.testing.expectEqual(@as(i64, 3), claims_schema.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 3), claims_schema.get("maxItems").?.integer);
    try std.testing.expect(!claims_schema.get("items").?.bool);
    const claim_prefix = claims_schema.get("prefixItems").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), claim_prefix.len);
    for (claim_prefix, claim_ids) |position, expected_id| {
        const pinned = position.object.get("properties").?.object;
        try std.testing.expectEqualStrings(expected_id, pinned.get("id").?.object.get("const").?.string);
    }
    // Every claim position pins its statement, its evidence check binding,
    // and its exact ordered limitation id list with no extras.
    for (claim_prefix, 0..) |position, index| {
        const pinned = position.object.get("properties").?.object;
        try std.testing.expectEqualStrings(claim_statements[index], pinned.get("statement").?.object.get("const").?.string);
        try std.testing.expectEqualStrings(check_ids[index], pinned.get("evidence").?.object.get("properties").?.object.get("check_id").?.object.get("const").?.string);
        const pinned_limitations = pinned.get("limitation_ids").?.object;
        const pins = pinned_limitations.get("prefixItems").?.array.items;
        try std.testing.expectEqual(claim_limitation_ids[index].len, pins.len);
        try std.testing.expect(!pinned_limitations.get("items").?.bool);
        try std.testing.expectEqual(@as(i64, @intCast(claim_limitation_ids[index].len)), pinned_limitations.get("minItems").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(claim_limitation_ids[index].len)), pinned_limitations.get("maxItems").?.integer);
        for (pins, claim_limitation_ids[index]) |pin, expected_id| {
            try std.testing.expectEqualStrings(expected_id, pin.object.get("const").?.string);
        }
    }

    const limitations_schema = root.get("properties").?.object.get("limitations").?.object;
    try std.testing.expectEqual(@as(i64, 6), limitations_schema.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 6), limitations_schema.get("maxItems").?.integer);
    const limitation_prefix = limitations_schema.get("prefixItems").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), limitation_prefix.len);
    for (limitation_prefix, limitation_ids) |position, expected_id| {
        const pinned = position.object.get("properties").?.object;
        try std.testing.expectEqualStrings(expected_id, pinned.get("id").?.object.get("const").?.string);
    }
    // Every limitation position pins its statement, its source, and its exact
    // ordered claim applicability list with no extras.
    for (limitation_prefix, 0..) |position, index| {
        const pinned = position.object.get("properties").?.object;
        try std.testing.expectEqualStrings(limitation_rows[index].statement, pinned.get("statement").?.object.get("const").?.string);
        try std.testing.expectEqualStrings(limitation_rows[index].source, pinned.get("source").?.object.get("const").?.string);
        const pinned_applies = pinned.get("applies_to_claims").?.object;
        const pins = pinned_applies.get("prefixItems").?.array.items;
        try std.testing.expectEqual(limitation_rows[index].applies_to_claims.len, pins.len);
        try std.testing.expect(!pinned_applies.get("items").?.bool);
        try std.testing.expectEqual(@as(i64, @intCast(limitation_rows[index].applies_to_claims.len)), pinned_applies.get("minItems").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(limitation_rows[index].applies_to_claims.len)), pinned_applies.get("maxItems").?.integer);
        for (pins, limitation_rows[index].applies_to_claims) |pin, expected_id| {
            try std.testing.expectEqualStrings(expected_id, pin.object.get("const").?.string);
        }
    }

    const defs = root.get("$defs").?.object;
    try expectJsonStrings(defs.get("claim").?.object.get("properties").?.object.get("status").?.object.get("enum").?, &.{ "verified", "failed", "not-verified" });
    const evidence = defs.get("evidence").?.object;
    try expectJsonStrings(evidence.get("properties").?.object.get("check_status").?.object.get("enum").?, &.{ "passed", "failed", "incomplete", "not-applicable" });
    try expectJsonStrings(evidence.get("properties").?.object.get("coverage").?.object.get("enum").?, &.{ "complete", "incomplete", "not-applicable" });
    {
        const reason_enum = evidence.get("properties").?.object.get("reason").?.object.get("enum").?.array.items;
        try std.testing.expectEqual(@as(usize, 4), reason_enum.len);
        try std.testing.expect(reason_enum[0] == .null);
        try std.testing.expectEqualStrings("check-failed", reason_enum[1].string);
        try std.testing.expectEqualStrings("check-incomplete", reason_enum[2].string);
        try std.testing.expectEqualStrings("check-not-applicable", reason_enum[3].string);
    }
    try expectJsonStrings(evidence.get("required").?, &.{ "check_id", "check_status", "coverage", "counts", "subject_sha256", "supporting_sha256", "checks_report_sha256", "reason" });
    try expectJsonStrings(defs.get("checks_binding").?.object.get("required").?, &.{ "path", "bytes", "sha256", "format", "schema_version", "target", "check_count", "finding_count" });
    try expectJsonStrings(defs.get("scope").?.object.get("required").?, &.{ "subject_statuses", "subject_kinds", "supporting_statuses", "supporting_kinds" });
    try expectJsonStrings(defs.get("counts").?.object.get("required").?, &.{ "eligible", "checked", "findings" });
    try expectJsonStrings(defs.get("claim").?.object.get("required").?, &.{ "id", "statement", "status", "evidence", "scope", "limitation_ids" });
}

test "fixed registries keep canonical order and mutually consistent references" {
    try std.testing.expectEqual(@as(usize, 3), claim_ids.len);
    try std.testing.expectEqual(@as(usize, 3), check_ids.len);
    try std.testing.expectEqual(@as(usize, 6), limitation_ids.len);
    try std.testing.expectEqual(@as(usize, 6), limitation_rows.len);
    try std.testing.expectEqualStrings(limitation_ids[0], generic_limitation_ids[0]);
    try std.testing.expectEqualStrings(limitation_ids[4], generic_limitation_ids[4]);
    try std.testing.expectEqualStrings(limitation_ids[5], "omitted-projections-not-certified");
    try std.testing.expectEqualStrings(claim_ids[2], search_claim_id[0]);
    for (limitation_rows) |row| {
        for (row.applies_to_claims) |claim_id| {
            try std.testing.expect(containsString(&claim_ids, claim_id));
        }
    }
    try std.testing.expectEqual(@as(usize, 6), claim_limitation_ids[2].len);
    try std.testing.expectEqual(@as(usize, 5), claim_limitation_ids[0].len);
    try std.testing.expectEqualStrings(claim_limitation_ids[2][5], limitation_ids[5]);
}

// ---------------------------------------------------------------------------
// End-to-end evidence derivation tests.
// ---------------------------------------------------------------------------

const test_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

const TestCheckSpec = struct {
    status: []const u8 = "passed",
    coverage: []const u8 = "complete",
    eligible: usize = 1,
    checked: usize = 1,
    findings: usize = 0,
    report_eligible: bool = true,
    report_ran: bool = true,
    subject_statuses: []const []const u8 = &.{"committed"},
    subject_kinds: []const []const u8 = &.{},
    supporting_statuses: []const []const u8 = &.{},
    supporting_kinds: []const []const u8 = &.{},
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

fn writePayload(io: Io, root: Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try root.createDirPath(io, parent);
    try root.writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Hostile checks report with finding offsets and counts near `maxInt(usize)`:
/// the second range addition overflows, and the report must be rejected with
/// `InvalidChecksReport` instead of panicking.
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

/// Test helper for the path-replacement seam: replaces both evidence paths
/// (unlink + fresh file, so the opened handles keep the original inodes)
/// with garbage once the handles are opened.
const PathReplacer = struct {
    io: Io,
    root: Io.Dir,

    fn run(context: ?*anyopaque) void {
        const self: *const PathReplacer = @ptrCast(@alignCast(context.?));
        replace(self, "target/_boris/proof/artifacts.json");
        replace(self, "target/_boris/proof/checks.json");
    }

    fn replace(self: *const PathReplacer, path: []const u8) void {
        _ = self.root.deleteFile(self.io, path) catch {};
        _ = self.root.writeFile(self.io, .{ .sub_path = path, .data = "not json" }) catch {};
    }
};

fn expectJsonStrings(value: std.json.Value, expected: []const []const u8) !void {
    const items = value.array.items;
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |want, index| try std.testing.expectEqualStrings(want, items[index].string);
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

fn buildChecksBytes(gpa: std.mem.Allocator, artifacts_bytes: []const u8, spec: TestFixtureSpec) ![]u8 {
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
        try out.appendSlice(gpa, "\",\n      \"scope\": {\n        \"subject_statuses\": [\"committed\"],\n        \"subject_kinds\": [");
        for (check.subject_kinds, 0..) |kind, kind_index| {
            if (kind_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, kind);
        }
        try out.appendSlice(gpa, "],\n        \"subject_sha256\": \"");
        try out.appendSlice(gpa, test_digest);
        try out.appendSlice(gpa, "\",\n        \"supporting_statuses\": [\"committed\"],\n        \"supporting_kinds\": [");
        for (check.supporting_kinds, 0..) |kind, kind_index| {
            if (kind_index > 0) try out.appendSlice(gpa, ", ");
            try json_out.writeString(&out, gpa, kind);
        }
        try out.appendSlice(gpa, "],\n        \"supporting_sha256\": \"");
        try out.appendSlice(gpa, test_digest);
        try out.appendSlice(gpa, "\"\n      },\n      \"counts\": {\"eligible\": ");
        try json_out.writeUsize(&out, gpa, check.eligible);
        try out.appendSlice(gpa, ", \"checked\": ");
        try json_out.writeUsize(&out, gpa, check.checked);
        try out.appendSlice(gpa, ", \"findings\": ");
        try json_out.writeUsize(&out, gpa, check.findings);
        try out.appendSlice(gpa, "},\n      \"finding_offset\": ");
        try json_out.writeUsize(&out, gpa, offset);
        try out.appendSlice(gpa, "\n    }");
        offset += check.findings;
    }
    var findings_total: usize = 0;
    for (spec.checks) |check| findings_total += check.findings;
    try out.appendSlice(gpa, "\n  ],\n  \"findings\": [");
    var finding_index: usize = 0;
    while (finding_index < findings_total) : (finding_index += 1) {
        try out.appendSlice(gpa, "{\"code\": \"TEST\"}");
        if (finding_index + 1 < findings_total) try out.appendSlice(gpa, ", ");
    }
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn prepareTarget(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    prefix: []const u8,
    records: []const artifact_inventory.Record,
    spec: TestFixtureSpec,
) ![]u8 {
    const artifacts_path = try std.mem.concat(gpa, u8, &.{ prefix, "/_boris/proof/artifacts.json" });
    defer gpa.free(artifacts_path);
    const artifacts = try buildArtifactsBytes(gpa, spec.target, records);
    defer gpa.free(artifacts);
    try writePayload(io, root, artifacts_path, artifacts);

    const checks_path = try std.mem.concat(gpa, u8, &.{ prefix, "/_boris/proof/checks.json" });
    defer gpa.free(checks_path);
    const checks = try buildChecksBytes(gpa, artifacts, spec);
    try writePayload(io, root, checks_path, checks);
    return checks;
}

fn openSubdir(io: Io, root: Io.Dir, prefix: []const u8) !Io.Dir {
    var dir = try root.openDir(io, prefix, .{});
    errdefer dir.close(io);
    return dir;
}

fn runClaims(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    prefix: []const u8,
    target: []const u8,
    options: Options,
) ![]u8 {
    var dir = try openSubdir(io, root, prefix);
    defer dir.close(io);
    try writeAfterChecks(io, gpa, dir, target, options);
    return readPayload(io, dir, gpa, output_path);
}

fn claimStatus(claims_root: std.json.ObjectMap, index: usize) []const u8 {
    return claims_root.get("claims").?.array.items[index].object.get("status").?.string;
}

fn claimReason(claims_root: std.json.ObjectMap, index: usize) ?[]const u8 {
    const reason = claims_root.get("claims").?.array.items[index].object.get("evidence").?.object.get("reason").?;
    return switch (reason) {
        .string => |value| value,
        .null => null,
        else => null,
    };
}

fn expectAllVerified(claims_root: std.json.ObjectMap) !void {
    for (0..claim_ids.len) |index| {
        try std.testing.expectEqualStrings("verified", claimStatus(claims_root, index));
        try std.testing.expect(claimReason(claims_root, index) == null);
    }
}

test "writeAfterChecks derives an all-pass claims report with fixed registry order" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{
        recordFor("index.html", .html_page, "<main></main>"),
        recordFor("_boris/search/search-index.json", .rendered_search, "{}"),
    };
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{ .artifact_count = 2 });
    defer gpa.free(checks);

    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(claims);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, claims, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("default", root.get("target").?.string);
    const artifact_count = root.get("artifact_inventory").?.object.get("artifact_count").?.integer;
    try std.testing.expectEqual(@as(i64, 2), artifact_count);
    const check_count = root.get("publication_checks").?.object.get("check_count").?.integer;
    try std.testing.expectEqual(@as(i64, 3), check_count);
    try std.testing.expectEqual(@as(usize, 3), root.get("claims").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 6), root.get("limitations").?.array.items.len);
    try expectAllVerified(root);
    for (0..claim_ids.len) |index| {
        const claim = root.get("claims").?.array.items[index].object;
        try std.testing.expectEqualStrings(claim_ids[index], claim.get("id").?.string);
        const evidence = claim.get("evidence").?.object;
        try std.testing.expectEqualStrings(check_ids[index], evidence.get("check_id").?.string);
        const checks_binding = root.get("publication_checks").?.object;
        const evidence_binding = evidence.get("checks_report_sha256").?.string;
        try std.testing.expectEqualStrings(checks_binding.get("sha256").?.string, evidence_binding);
    }
    for (0..limitation_ids.len) |index| {
        const limitation = root.get("limitations").?.array.items[index].object;
        try std.testing.expectEqualStrings(limitation_ids[index], limitation.get("id").?.string);
    }
    const search_limitations = root.get("claims").?.array.items[2].object.get("limitation_ids").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), search_limitations.len);
    try std.testing.expectEqualStrings(limitation_ids[5], search_limitations[5].string);
}

test "claims report is byte-deterministic across sequential rebuilds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const first = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(first);
    const second = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}

test "claims report is byte-identical across sequential and concurrent derivation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks_a = try prepareTarget(io, gpa, tmp.dir, "a", &records, .{});
    defer gpa.free(checks_a);
    const checks_b = try prepareTarget(io, gpa, tmp.dir, "b", &records, .{});
    defer gpa.free(checks_b);

    const sequential = try runClaims(io, gpa, tmp.dir, "a", "default", .{});
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
            const bytes = runClaims(thread_args.io, thread_args.gpa, thread_args.root, "b", "default", .{}) catch |err| {
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

test "failed checks map to failed claims with a stable reason" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const spec = TestFixtureSpec{
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"}, .status = "failed", .findings = 1 },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        },
    };
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    defer gpa.free(checks);

    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(claims);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, claims, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("verified", claimStatus(root, 0));
    try std.testing.expectEqualStrings("failed", claimStatus(root, 1));
    try std.testing.expectEqualStrings("check-failed", claimReason(root, 1).?);
    try std.testing.expectEqualStrings("verified", claimStatus(root, 2));
    const evidence = root.get("claims").?.array.items[1].object.get("evidence").?.object;
    try std.testing.expectEqual(@as(i64, 1), evidence.get("counts").?.object.get("findings").?.integer);
    try std.testing.expectEqualStrings("failed", evidence.get("check_status").?.string);
}

test "incomplete checks map to not-verified claims with a stable reason" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const spec = TestFixtureSpec{
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "incomplete", .coverage = "incomplete", .checked = 0 },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        },
    };
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    defer gpa.free(checks);

    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(claims);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, claims, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("not-verified", claimStatus(root, 0));
    try std.testing.expectEqualStrings("check-incomplete", claimReason(root, 0).?);
    try std.testing.expectEqualStrings("verified", claimStatus(root, 1));
    try std.testing.expectEqualStrings("verified", claimStatus(root, 2));
}

test "not-applicable rendered-search maps only the search claim to not-verified" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const spec = TestFixtureSpec{
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
        },
    };
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, spec);
    defer gpa.free(checks);

    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(claims);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, claims, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("verified", claimStatus(root, 0));
    try std.testing.expectEqualStrings("verified", claimStatus(root, 1));
    try std.testing.expectEqualStrings("not-verified", claimStatus(root, 2));
    try std.testing.expectEqualStrings("check-not-applicable", claimReason(root, 2).?);
    const evidence = root.get("claims").?.array.items[2].object.get("evidence").?.object;
    try std.testing.expectEqualStrings("not-applicable", evidence.get("check_status").?.string);
    try std.testing.expectEqualStrings("not-applicable", evidence.get("coverage").?.string);
}

test "a stale checks-to-inventory binding is detected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    const rendered = try buildArtifactsBytes(gpa, "default", &records);
    defer gpa.free(rendered);
    const changed = try std.mem.concat(gpa, u8, &.{ rendered, "\n" });
    defer gpa.free(changed);
    try writePayload(io, dir, artifact_inventory.output_path, changed);
    try std.testing.expectError(error.StaleChecksBinding, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "an artifact-count mismatch is detected as a stale binding" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{ .artifact_count = 9 });
    defer gpa.free(checks);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.StaleChecksBinding, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "invalid checks report format is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(
        u8,
        gpa,
        checks,
        "boris-publication-checks",
        "boris-other",
    );
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "unsupported checks schema version is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(u8, gpa, checks, "\"schema_version\": 1", "\"schema_version\": 2");
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "a checks report for a different target is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(
        u8,
        gpa,
        checks,
        "  \"target\": \"default\"",
        "  \"target\": \"prod\"",
    );
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "a checks report with an unknown check id is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(u8, gpa, checks, "\"rendered-html\"", "\"rendered-htmlx\"");
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "a checks report with non-canonical check order is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(u8, gpa, checks, "\"rendered-html\"", "\"rendered-search\"");
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "malformed finding offset ranges are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(u8, gpa, checks, "\"finding_offset\": 0", "\"finding_offset\": 3");
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "a findings total that disagrees with check counts is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(
        u8,
        gpa,
        checks,
        "\"findings\": [",
        "\"findings\": [{\"code\": \"TEST\"}, ",
    );
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "a missing checks report is rejected without touching claims" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try dir.deleteFile(io, publication_checks.output_path);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
    try std.testing.expectError(error.FileNotFound, dir.access(io, output_path, .{}));
}

test "an invalid artifacts report is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePayload(io, tmp.dir, "target/_boris/proof/artifacts.json", "not json");
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", "{\"format\": \"boris-publication-checks\"}");

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidArtifactsReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "a missing artifacts report is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try dir.deleteFile(io, artifact_inventory.output_path);
    try std.testing.expectError(error.InvalidArtifactsReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "execution fault injection fails before any claims report is written" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(
        error.InvalidChecksReport,
        writeAfterChecks(io, gpa, dir, "default", .{ .test_fail_execution = true }),
    );
    try std.testing.expectError(error.FileNotFound, dir.access(io, output_path, .{}));
}

test "write fault injection preserves the prior claims report byte-for-byte" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const first = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(first);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(
        error.ClaimsWriteFailed,
        writeAfterChecks(io, gpa, dir, "default", .{ .test_fail_write = true }),
    );

    const after = try readPayload(io, dir, gpa, output_path);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, first, after);
}

test "an empty target produces a valid report with only the search claim not verified" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &.{}, .{
        .artifact_count = 0,
        .checks = .{
            .{ .subject_kinds = &.{}, .eligible = 0, .checked = 0 },
            .{ .subject_kinds = &.{"html-page"}, .eligible = 0, .checked = 0 },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
        },
    });
    defer gpa.free(checks);

    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(claims);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, claims, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 0), root.get("artifact_inventory").?.object.get("artifact_count").?.integer);
    try std.testing.expectEqualStrings("verified", claimStatus(root, 0));
    try std.testing.expectEqualStrings("verified", claimStatus(root, 1));
    try std.testing.expectEqualStrings("not-verified", claimStatus(root, 2));
    try std.testing.expectEqualStrings("check-not-applicable", claimReason(root, 2).?);
}

test "claim evidence carries the exact checks report binding" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(claims);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, claims, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const checks_binding = root.get("publication_checks").?.object;
    const checks_path = "target/_boris/proof/checks.json";
    const on_disk = try readPayload(io, tmp.dir, gpa, checks_path);
    defer gpa.free(on_disk);
    const on_disk_digest = cache.hexDigest(cache.hashBytes(on_disk));
    try std.testing.expectEqualStrings(&on_disk_digest, checks_binding.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(on_disk.len)), checks_binding.get("bytes").?.integer);
    const artifact_binding = root.get("artifact_inventory").?.object;
    const artifacts_path = "target/_boris/proof/artifacts.json";
    const artifacts_on_disk = try readPayload(io, tmp.dir, gpa, artifacts_path);
    defer gpa.free(artifacts_on_disk);
    const artifacts_digest = cache.hexDigest(cache.hashBytes(artifacts_on_disk));
    try std.testing.expectEqualStrings(&artifacts_digest, artifact_binding.get("sha256").?.string);
}

test "evidence binding survives replacement of the opened evidence paths" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const control = try runClaims(io, gpa, tmp.dir, "target", "default", .{});
    defer gpa.free(control);

    // Replace both evidence paths with garbage after the handles are opened.
    // A path-based implementation would fail loudly on re-open; the single
    // opened no-follow handle per input must be unaffected, so the claims
    // report is byte-identical to the no-replacement run. The claims output
    // path itself is never replaced.
    const replacer = PathReplacer{ .io = io, .root = tmp.dir };
    const claims = try runClaims(io, gpa, tmp.dir, "target", "default", .{ .after_open = PathReplacer.run, .after_open_context = @constCast(&replacer) });
    defer gpa.free(claims);
    try std.testing.expectEqualSlices(u8, control, claims);
}

test "impossible check states are rejected as InvalidChecksReport" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        checks: [3]TestCheckSpec,
    }{
        .{ .name = "checked exceeds eligible", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"}, .eligible = 0, .checked = 1 },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "passed with incomplete coverage", .checks = .{
            .{ .subject_kinds = &.{}, .coverage = "incomplete" },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "failed with incomplete coverage", .checks = .{
            .{ .subject_kinds = &.{}, .status = "failed", .coverage = "incomplete" },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "incomplete with complete coverage", .checks = .{
            .{ .subject_kinds = &.{}, .status = "incomplete", .coverage = "complete", .checked = 0 },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "not-applicable with complete coverage", .checks = .{
            .{ .subject_kinds = &.{}, .status = "not-applicable", .coverage = "complete", .checked = 0 },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "unknown status", .checks = .{
            .{ .subject_kinds = &.{}, .status = "passedx" },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "artifact-integrity not-applicable", .checks = .{
            .{ .subject_kinds = &.{}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "rendered-html not-applicable", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        } },
        .{ .name = "selected search did not run", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .report_ran = false },
        } },
        .{ .name = "selected search not-applicable", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0 },
        } },
        .{ .name = "selected search with zero eligible records", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .eligible = 0, .checked = 0 },
        } },
        .{ .name = "unselected search still ran", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .eligible = 0, .checked = 0, .report_eligible = false },
        } },
        .{ .name = "unselected search reported passed", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .eligible = 0, .checked = 0, .report_eligible = false, .report_ran = false },
        } },
        .{ .name = "unselected search with nonzero counts", .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"}, .status = "not-applicable", .coverage = "not-applicable", .report_eligible = false, .report_ran = false },
        } },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const checks = try prepareTarget(io, gpa, tmp.dir, "target", &.{recordFor("index.html", .html_page, "<main></main>")}, .{ .checks = case.checks });
        defer gpa.free(checks);
        try std.testing.expectError(error.InvalidChecksReport, runClaims(io, gpa, tmp.dir, "target", "default", .{}));
    }
}

test "a checks report whose embedded artifact_inventory target disagrees is rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
    defer gpa.free(checks);

    const mutated = try std.mem.replaceOwned(
        u8,
        gpa,
        checks,
        "\n    \"target\": \"default\"",
        "\n    \"target\": \"prod\"",
    );
    defer gpa.free(mutated);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "finding offset arithmetic near maxInt(usize) is rejected without overflow" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
    const artifacts = try buildArtifactsBytes(gpa, "default", &records);
    defer gpa.free(artifacts);
    try writePayload(io, tmp.dir, "target/_boris/proof/artifacts.json", artifacts);

    const hostile = try buildHostileChecksBytes(gpa, artifacts);
    defer gpa.free(hostile);
    try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", hostile);

    var dir = try openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
}

test "non-object finding elements are rejected" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const poisoned = [_][]const u8{
        "null",
        "42",
        "\"finding\"",
        "true",
        "[]",
    };
    for (poisoned) |element| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const records = [_]artifact_inventory.Record{recordFor("index.html", .html_page, "<main></main>")};
        const checks = try prepareTarget(io, gpa, tmp.dir, "target", &records, .{});
        defer gpa.free(checks);

        const replacement = try std.mem.concat(gpa, u8, &.{ "\"findings\": [", element, "]" });
        defer gpa.free(replacement);
        const mutated = try std.mem.replaceOwned(
            u8,
            gpa,
            checks,
            "\"findings\": []",
            replacement,
        );
        defer gpa.free(mutated);
        try writePayload(io, tmp.dir, "target/_boris/proof/checks.json", mutated);

        var dir = try openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        try std.testing.expectError(error.InvalidChecksReport, writeAfterChecks(io, gpa, dir, "default", .{}));
    }
}
