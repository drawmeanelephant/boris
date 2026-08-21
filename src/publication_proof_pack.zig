const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const json_out = @import("json_out.zig");
const artifact_inventory = @import("artifact_inventory.zig");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");
const evidence_mod = @import("publication_evidence.zig");
const proof_json = @import("proof_pack_json.zig");
const proof_html = @import("proof_pack_html.zig");
const proof_txn = @import("proof_pack_transaction.zig");

comptime {
    _ = proof_txn;
}

pub const output_path = artifact_inventory.proof_pack_output_path;
pub const index_output_path = artifact_inventory.proof_index_output_path;
pub const report_format = "boris-publication-proof-pack";
pub const schema_version: usize = 1;

pub const Options = struct {
    /// Test-only fault injection: fail before derivation completes. Production
    /// callers leave every fault injection false.
    test_fail_execution: bool = false,
    /// Test-only failure while writing `proof-pack.json.tmp`.
    test_fail_json_tmp_write: bool = false,
    /// Test-only failure while writing `index.html.tmp`.
    test_fail_html_tmp_write: bool = false,
    /// Test-only failure before the first preservation rename (moving the
    /// current pair aside as `.prev`).
    test_fail_preserve_prior: bool = false,
    /// Test-only failure after `index.html` was preserved but before
    /// `proof-pack.json` is preserved (contract preservation order).
    test_fail_preserve_json: bool = false,
    /// Test-only failure reported after both current files were preserved as
    /// `.prev` (i.e. after preserving JSON, the last preservation rename),
    /// before any install rename; recovery must restore both preserved files.
    test_fail_preserve_after: bool = false,
    /// Test-only failure reported after the new `index.html` is renamed into
    /// place (the rename itself may have completed; recovery must remove a
    /// newly installed HTML whose prior state was absent or restore a
    /// preserved one).
    test_fail_install_html: bool = false,
    /// Test-only failure reported after the new `proof-pack.json` is renamed
    /// into place (the rename itself may have completed; recovery must remove
    /// a newly installed JSON whose prior state was absent or restore a
    /// preserved one).
    test_fail_install_json: bool = false,
    /// Test-only failure while restoring the prior `index.html` from `.prev`.
    test_fail_restore_html: bool = false,
    /// Test-only failure while restoring the prior `proof-pack.json` from `.prev`.
    test_fail_restore_json: bool = false,
    /// Test-only failure while removing a newly installed `index.html` whose
    /// prior state was absent.
    test_fail_remove_html: bool = false,
    /// Test-only failure while removing a newly installed `proof-pack.json`
    /// whose prior state was absent.
    test_fail_remove_json: bool = false,
    /// Test-only seam: invoked once after all four evidence handles are opened
    /// and before any byte is read. A test may replace files at this point;
    /// the already-opened handles must remain authoritative.
    after_open: ?*const fn (?*anyopaque) void = null,
    after_open_context: ?*anyopaque = null,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidArtifactsReport,
    InvalidChecksReport,
    InvalidClaimsReport,
    InvalidTouchesReport,
    StaleArtifactsBinding,
    StaleChecksBinding,
    StaleClaimsBinding,
    StaleTouchesBinding,
    JsonTmpWriteFailed,
    HtmlTmpWriteFailed,
    PreservePriorFailed,
    PreserveHtmlFailed,
    PreserveJsonFailed,
    PreserveAfterFailed,
    InstallHtmlFailed,
    InstallJsonFailed,
    RestoreHtmlFailed,
    RestoreJsonFailed,
    RemoveHtmlFailed,
    RemoveJsonFailed,
    ProofPackWriteFailed,
    // The shared evidence parsers are typed with the touches writer's error
    // set, which includes its own write failure; that error can never be
    // produced on the parse path but must be a member for the union to type.
    TouchesWriteFailed,
};

const FileBinding = publication_touches.FileBinding;
const ParsedCheck = publication_touches.ParsedCheck;
const ParsedClaim = publication_touches.ParsedClaim;
const ParsedLimitation = publication_touches.ParsedLimitation;
const ParsedChecks = publication_touches.ParsedChecks;
const ParsedClaims = publication_touches.ParsedClaims;
const ParsedTouches = publication_touches.ParsedTouches;
const Node = publication_touches.Node;
const Edge = publication_touches.Edge;
const EdgeKind = publication_touches.EdgeKind;

/// One no-follow open per evidence input, mirroring the touches layer: the
/// exact same opened regular-file handle is read twice (hash pass, then a
/// rewound parse pass), so a path replaced after the open can never mix
/// evidence versions.
const EvidenceInput = evidence_mod.EvidenceInput(Error);

fn bindingEqual(a: FileBinding, b: FileBinding) bool {
    return evidence_mod.bindingEqual(a, b);
}

/// Derive the overall presentation status by the contract's exact ordered rule
/// set, using only check and claim statuses copied from the committed
/// evidence. Never upgrades a check or claim; never invents a pass.
fn deriveOverallStatus(checks: *const [3]ParsedCheck, claims: *const [3]ParsedClaim) []const u8 {
    var all_na = true;
    for (checks) |check| {
        if (!std.mem.eql(u8, check.status, "not-applicable")) {
            all_na = false;
            break;
        }
    }
    if (all_na) return "not-applicable";
    for (checks) |check| {
        if (std.mem.eql(u8, check.status, "incomplete")) return "incomplete";
    }
    for (checks) |check| {
        if (std.mem.eql(u8, check.status, "failed")) return "attention-required";
    }
    for (claims) |claim| {
        if (std.mem.eql(u8, claim.status, "failed") or
            std.mem.eql(u8, claim.status, "not-verified"))
            return "attention-required";
    }
    return "verified";
}

fn statusBannerClass(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "verified")) return "verified";
    if (std.mem.eql(u8, status, "attention-required")) return "attention";
    if (std.mem.eql(u8, status, "incomplete")) return "incomplete";
    return "na";
}

fn statusTitleSuffix(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "verified")) return "(clean)";
    if (std.mem.eql(u8, status, "attention-required")) return "(attention required)";
    if (std.mem.eql(u8, status, "incomplete")) return "(incomplete)";
    return "(not applicable)";
}

fn statusCssClass(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "verified") or std.mem.eql(u8, status, "committed") or
        std.mem.eql(u8, status, "passed"))
        return "status-verified";
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "error"))
        return "status-failed";
    if (std.mem.eql(u8, status, "incomplete") or std.mem.eql(u8, status, "warning"))
        return "status-incomplete";
    return "status-na";
}

/// Render the `attention-required` explanation paragraph from the exact
/// committed check, claim, and finding states. Never states that a check
/// failed unless one did; never tells the reader to review findings when
/// there are none. Each sentence is derived from a verified fact:
///
/// - a failed check (with findings, the findings are referenced);
/// - a failed claim (a claim is not supported);
/// - a not-verified claim (a claim could not be verified; if the bound
///   rendered-search check is not-applicable, that is stated as the cause).
///
/// If no specific fact can be named (e.g. attention-required with zero
/// findings and no failed claim), a neutral sentence is emitted instead of
/// an invented cause.
fn renderHtmlAttentionExplanation(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    model: *const Model,
) !void {
    var failed_checks: usize = 0;
    var failed_claims: usize = 0;
    var not_verified_claims: usize = 0;
    var search_na = false;
    for (model.parsed_checks.checks) |check| {
        if (std.mem.eql(u8, check.status, "failed")) failed_checks += 1;
        if (std.mem.eql(u8, check.id, "rendered-search") and
            std.mem.eql(u8, check.status, "not-applicable"))
            search_na = true;
    }
    for (model.parsed_claims.claims) |claim| {
        if (std.mem.eql(u8, claim.status, "failed")) failed_claims += 1;
        if (std.mem.eql(u8, claim.status, "not-verified")) not_verified_claims += 1;
    }
    const finding_count = model.parsed_checks.findings.len;

    try out.appendSlice(gpa, "  <p>");
    var first = true;
    if (failed_checks > 0) {
        try out.appendSlice(gpa, "At least one check failed");
        if (finding_count > 0) {
            try out.appendSlice(gpa, " and reported findings; review the findings below");
        }
        first = false;
    }
    if (failed_claims > 0) {
        if (!first) try out.appendSlice(gpa, ". ");
        try out.appendSlice(gpa, "At least one claim is not supported");
        first = false;
    }
    if (not_verified_claims > 0) {
        if (!first) try out.appendSlice(gpa, ". ");
        if (search_na) {
            try out.appendSlice(gpa, "A claim could not be verified because the rendered-search check is not-applicable for this target");
        } else {
            try out.appendSlice(gpa, "At least one claim could not be verified");
        }
        first = false;
    }
    if (first) {
        // No specific cause is present in the evidence (for example
        // attention-required with zero findings and no failed claim): state
        // the need for attention without inventing a reason.
        try out.appendSlice(gpa, "This publication's evidence requires attention before it should be relied upon");
    }
    try out.appendSlice(gpa, ".</p>\n");
}

/// Build the presentation model in an arena and render both outputs. The
/// derivation never re-observes the target: every row and total is derived
/// from the four validated evidence reports and the committed Touch Atlas.
const Inputs = struct {
    artifacts: FileBinding,
    checks: FileBinding,
    claims: FileBinding,
    touches: FileBinding,
};

const Model = struct {
    arena: std.heap.ArenaAllocator,
    target: []const u8,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
    parsed_touches: *const ParsedTouches,
    overall_status: []const u8,
    bindings: Inputs,
};

fn validateAllBindings(
    artifacts_binding: FileBinding,
    checks_binding: FileBinding,
    claims_binding: FileBinding,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
    parsed_touches: *const ParsedTouches,
) Error!void {
    if (!bindingEqual(parsed_checks.artifact_binding, artifacts_binding) or
        parsed_checks.artifact_count != inventory.records.len)
        return error.StaleArtifactsBinding;
    if (!bindingEqual(parsed_claims.artifact_binding, artifacts_binding) or
        parsed_claims.artifact_count != inventory.records.len)
        return error.StaleArtifactsBinding;
    if (!bindingEqual(parsed_claims.checks_binding, checks_binding) or
        parsed_claims.check_count != parsed_checks.checks.len or
        parsed_claims.finding_count != parsed_checks.findings.len)
        return error.StaleChecksBinding;
    if (!bindingEqual(parsed_touches.artifacts_binding, artifacts_binding) or
        parsed_touches.artifact_count != inventory.records.len)
        return error.StaleArtifactsBinding;
    if (!bindingEqual(parsed_touches.checks_binding, checks_binding) or
        parsed_touches.check_count != parsed_checks.checks.len or
        parsed_touches.finding_count != parsed_checks.findings.len)
        return error.StaleChecksBinding;
    if (!bindingEqual(parsed_touches.claims_binding, claims_binding) or
        parsed_touches.claim_count != parsed_claims.claims.len or
        parsed_touches.limitation_count != parsed_claims.limitations.len)
        return error.StaleClaimsBinding;
}

fn validateSemantics(
    gpa: std.mem.Allocator,
    inventory: *const artifact_inventory.Inventory,
    parsed_checks: *const ParsedChecks,
    parsed_claims: *const ParsedClaims,
    parsed_touches: *const ParsedTouches,
    checks_binding: FileBinding,
) Error!void {
    try publication_touches.validateChecksAgainstInventory(gpa, inventory, &parsed_checks.checks);
    try publication_touches.validateClaimsAgainstChecks(parsed_checks, checks_binding, parsed_claims);
    try publication_touches.validateGraph(gpa, inventory, parsed_checks, parsed_claims, parsed_touches.nodes, parsed_touches.edges);
}

fn renderPairAndInstall(
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    model: *const Model,
    artifacts_binding: FileBinding,
    checks_binding: FileBinding,
    claims_binding: FileBinding,
    touches_binding: FileBinding,
    options: Options,
) Error!void {
    const json_bytes = renderJson(gpa, model, artifacts_binding, checks_binding, claims_binding, touches_binding) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
        error.InvalidChecksReport => return error.InvalidChecksReport,
    };
    var json_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json_bytes, &json_digest, .{});
    const json_sha256 = cache.hexDigest(json_digest);
    const html_bytes = renderHtml(gpa, model, json_sha256) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
        error.InvalidChecksReport => return error.InvalidChecksReport,
    };
    try installPair(io, root, json_bytes, html_bytes, options);
}

/// Write `proof-pack.json` and `index.html` after the Touch Atlas commits.
/// Every output is derived from the exact committed artifacts, checks,
/// claims, and touches bytes; a derivation, stale-binding, parser, render,
/// I/O, or transaction failure keeps the committed target and evidence and
/// leaves any prior presentation pair restored (or explicitly reported as
/// possibly split/absent when restoration itself fails).
pub fn writeAfterTouches(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    target: []const u8,
    options: Options,
) Error!void {
    if (options.test_fail_execution) return error.InvalidTouchesReport;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_gpa = arena.allocator();

    // Open all four evidence files before reading any of them.
    var artifacts_input: EvidenceInput = .{};
    try artifacts_input.open(io, root, artifact_inventory.output_path, error.InvalidArtifactsReport);
    defer artifacts_input.close(io);
    var checks_input: EvidenceInput = .{};
    try checks_input.open(io, root, publication_checks.output_path, error.InvalidChecksReport);
    defer checks_input.close(io);
    var claims_input: EvidenceInput = .{};
    try claims_input.open(io, root, publication_claims.output_path, error.InvalidClaimsReport);
    defer claims_input.close(io);
    var touches_input: EvidenceInput = .{};
    try touches_input.open(io, root, publication_touches.output_path, error.InvalidTouchesReport);
    defer touches_input.close(io);
    if (options.after_open) |hook| hook(options.after_open_context);

    try artifacts_input.hashPass(error.InvalidArtifactsReport);
    try artifacts_input.rewindForParse(io, error.InvalidArtifactsReport);
    var inventory = artifact_inventory.parseStream(arena_gpa, &artifacts_input.pass2.interface, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifactsReport,
    };
    const artifacts_binding = artifacts_input.finish();

    try checks_input.hashPass(error.InvalidChecksReport);
    try checks_input.rewindForParse(io, error.InvalidChecksReport);
    const parsed_checks = try publication_touches.parseChecksStream(arena_gpa, &checks_input.pass2.interface, target);
    const checks_binding = checks_input.finish();

    try claims_input.hashPass(error.InvalidClaimsReport);
    try claims_input.rewindForParse(io, error.InvalidClaimsReport);
    const parsed_claims = try publication_touches.parseClaimsStream(arena_gpa, &claims_input.pass2.interface, target);
    const claims_binding = claims_input.finish();

    try touches_input.hashPass(error.InvalidTouchesReport);
    try touches_input.rewindForParse(io, error.InvalidTouchesReport);
    const parsed_touches = try publication_touches.parseTouchesStream(
        arena_gpa,
        &touches_input.pass2.interface,
        target,
        &inventory,
        &parsed_checks,
        &parsed_claims,
    );
    const touches_binding = touches_input.finish();

    try validateAllBindings(artifacts_binding, checks_binding, claims_binding, &inventory, &parsed_checks, &parsed_claims, &parsed_touches);
    try validateSemantics(arena_gpa, &inventory, &parsed_checks, &parsed_claims, &parsed_touches, checks_binding);

    const model = Model{
        .arena = arena,
        .target = target,
        .inventory = &inventory,
        .parsed_checks = &parsed_checks,
        .parsed_claims = &parsed_claims,
        .parsed_touches = &parsed_touches,
        .overall_status = deriveOverallStatus(&parsed_checks.checks, &parsed_claims.claims),
        .bindings = .{
            .artifacts = artifacts_binding,
            .checks = checks_binding,
            .claims = claims_binding,
            .touches = touches_binding,
        },
    };

    try renderPairAndInstall(arena_gpa, io, root, &model, artifacts_binding, checks_binding, claims_binding, touches_binding, options);
}

// ---------------------------------------------------------------------------
// JSON renderer (canonical member and array order, exact-byte golden format).
// ---------------------------------------------------------------------------

fn writeStringArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    values: []const []const u8,
    indent: usize,
) !void {
    return proof_json.writeStringArray(out, gpa, values, indent);
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
    try json_out.indent(out, gpa, 2);
    try json_out.writeString(out, gpa, label);
    try out.appendSlice(gpa, ": {\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"path\": ");
    try json_out.writeString(out, gpa, path);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"bytes\": ");
    try json_out.writeUsize(out, gpa, binding.bytes);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"sha256\": ");
    try json_out.writeString(out, gpa, &binding.sha256);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"format\": ");
    try json_out.writeString(out, gpa, format);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"schema_version\": ");
    try json_out.writeUsize(out, gpa, version);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"target\": ");
    try json_out.writeString(out, gpa, target);
    for (count_keys) |count_key| {
        try out.appendSlice(gpa, ",\n");
        try json_out.indent(out, gpa, 3);
        try json_out.writeString(out, gpa, count_key.key);
        try out.appendSlice(gpa, ": ");
        try json_out.writeUsize(out, gpa, count_key.value);
    }
    try out.appendSlice(gpa, "\n");
    try json_out.indent(out, gpa, 2);
    try out.append(gpa, '}');
}

fn renderJson(
    gpa: std.mem.Allocator,
    model: *const Model,
    artifacts_binding: FileBinding,
    checks_binding: FileBinding,
    claims_binding: FileBinding,
    touches_binding: FileBinding,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n");
    try json_out.indent(&out, gpa, 1);
    try out.appendSlice(gpa, "\"format\": ");
    try json_out.writeString(&out, gpa, report_format);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(&out, gpa, 1);
    try out.appendSlice(gpa, "\"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(&out, gpa, 1);
    try out.appendSlice(gpa, "\"target\": ");
    try json_out.writeString(&out, gpa, model.target);
    try out.appendSlice(gpa, ",\n");

    try out.appendSlice(gpa, "  \"inputs\": {\n");
    try writeInputBlock(&out, gpa, "artifacts", artifact_inventory.output_path, artifacts_binding, artifact_inventory.artifact_format, artifact_inventory.schema_version, model.target, &.{.{ .key = "artifact_count", .value = model.inventory.records.len }});
    try out.appendSlice(gpa, ",\n");
    try writeInputBlock(&out, gpa, "checks", publication_checks.output_path, checks_binding, publication_checks.report_format, publication_checks.schema_version, model.target, &.{
        .{ .key = "check_count", .value = model.parsed_checks.checks.len },
        .{ .key = "finding_count", .value = model.parsed_checks.findings.len },
    });
    try out.appendSlice(gpa, ",\n");
    try writeInputBlock(&out, gpa, "claims", publication_claims.output_path, claims_binding, publication_claims.report_format, publication_claims.schema_version, model.target, &.{
        .{ .key = "claim_count", .value = model.parsed_claims.claims.len },
        .{ .key = "limitation_count", .value = model.parsed_claims.limitations.len },
    });
    try out.appendSlice(gpa, ",\n");
    try writeInputBlock(&out, gpa, "touches", publication_touches.output_path, touches_binding, publication_touches.report_format, publication_touches.schema_version, model.target, &.{
        .{ .key = "node_count", .value = model.parsed_touches.nodes.len },
        .{ .key = "edge_count", .value = model.parsed_touches.edges.len },
    });
    try out.appendSlice(gpa, "\n  },\n");

    try renderSummary(&out, gpa, model);
    try renderArtifacts(&out, gpa, model);
    try renderChecks(&out, gpa, model);
    try renderFindings(&out, gpa, model);
    try renderClaims(&out, gpa, model);
    try renderLimitations(&out, gpa, model);
    try renderRelationships(&out, gpa, model);
    try renderPresentation(&out, gpa, model);

    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn renderSummary(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    var artifacts_total: usize = 0;
    var committed: usize = 0;
    var omitted: usize = 0;
    var na_artifact: usize = 0;
    var by_kind = [_]usize{0} ** 7;
    for (model.inventory.records) |record| {
        artifacts_total += 1;
        switch (record.status) {
            .committed => committed += 1,
            .omitted_by_plan => omitted += 1,
            .not_applicable => na_artifact += 1,
        }
        by_kind[@intFromEnum(record.kind)] += 1;
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var incomplete_check: usize = 0;
    var na_check: usize = 0;
    var complete_cov: usize = 0;
    var incomplete_cov: usize = 0;
    var na_cov: usize = 0;
    for (model.parsed_checks.checks) |check| {
        if (std.mem.eql(u8, check.status, "passed")) passed += 1;
        if (std.mem.eql(u8, check.status, "failed")) failed += 1;
        if (std.mem.eql(u8, check.status, "incomplete")) incomplete_check += 1;
        if (std.mem.eql(u8, check.status, "not-applicable")) na_check += 1;
        if (std.mem.eql(u8, check.coverage, "complete")) complete_cov += 1;
        if (std.mem.eql(u8, check.coverage, "incomplete")) incomplete_cov += 1;
        if (std.mem.eql(u8, check.coverage, "not-applicable")) na_cov += 1;
    }

    var error_findings: usize = 0;
    var warning_findings: usize = 0;
    var info_findings: usize = 0;
    for (model.parsed_checks.findings) |finding| {
        if (std.mem.eql(u8, finding.severity, "error")) error_findings += 1;
        if (std.mem.eql(u8, finding.severity, "warning")) warning_findings += 1;
        if (std.mem.eql(u8, finding.severity, "info")) info_findings += 1;
    }

    var verified_claims: usize = 0;
    var failed_claims: usize = 0;
    var not_verified_claims: usize = 0;
    for (model.parsed_claims.claims) |claim| {
        if (std.mem.eql(u8, claim.status, "verified")) verified_claims += 1;
        if (std.mem.eql(u8, claim.status, "failed")) failed_claims += 1;
        if (std.mem.eql(u8, claim.status, "not-verified")) not_verified_claims += 1;
    }

    try out.appendSlice(gpa, "  \"summary\": {\n");
    try out.appendSlice(gpa, "    \"artifacts\": {\n");
    try out.appendSlice(gpa, "      \"total\": ");
    try json_out.writeUsize(out, gpa, artifacts_total);
    try out.appendSlice(gpa, ",\n      \"by_status\": {\n");
    try out.appendSlice(gpa, "        \"committed\": ");
    try json_out.writeUsize(out, gpa, committed);
    try out.appendSlice(gpa, ",\n        \"omitted-by-plan\": ");
    try json_out.writeUsize(out, gpa, omitted);
    try out.appendSlice(gpa, ",\n        \"not-applicable\": ");
    try json_out.writeUsize(out, gpa, na_artifact);
    try out.appendSlice(gpa, "\n      },\n      \"by_kind\": {\n");
    const kind_names = [_][]const u8{ "html-page", "theme-asset", "content-asset", "rendered-search", "sitemap", "rss", "llms" };
    for (kind_names, 0..) |name, index| {
        try out.appendSlice(gpa, "        ");
        try json_out.writeString(out, gpa, name);
        try out.appendSlice(gpa, ": ");
        try json_out.writeUsize(out, gpa, by_kind[index]);
        if (index + 1 < kind_names.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "      }\n    },\n    \"checks\": {\n");
    try out.appendSlice(gpa, "      \"total\": ");
    try json_out.writeUsize(out, gpa, model.parsed_checks.checks.len);
    try out.appendSlice(gpa, ",\n      \"by_status\": {\n");
    try out.appendSlice(gpa, "        \"passed\": ");
    try json_out.writeUsize(out, gpa, passed);
    try out.appendSlice(gpa, ",\n        \"failed\": ");
    try json_out.writeUsize(out, gpa, failed);
    try out.appendSlice(gpa, ",\n        \"incomplete\": ");
    try json_out.writeUsize(out, gpa, incomplete_check);
    try out.appendSlice(gpa, ",\n        \"not-applicable\": ");
    try json_out.writeUsize(out, gpa, na_check);
    try out.appendSlice(gpa, "\n      },\n      \"by_coverage\": {\n");
    try out.appendSlice(gpa, "        \"complete\": ");
    try json_out.writeUsize(out, gpa, complete_cov);
    try out.appendSlice(gpa, ",\n        \"incomplete\": ");
    try json_out.writeUsize(out, gpa, incomplete_cov);
    try out.appendSlice(gpa, ",\n        \"not-applicable\": ");
    try json_out.writeUsize(out, gpa, na_cov);
    try out.appendSlice(gpa, "\n      }\n    },\n    \"findings\": {\n");
    try out.appendSlice(gpa, "      \"total\": ");
    try json_out.writeUsize(out, gpa, model.parsed_checks.findings.len);
    try out.appendSlice(gpa, ",\n      \"by_severity\": {\n");
    try out.appendSlice(gpa, "        \"error\": ");
    try json_out.writeUsize(out, gpa, error_findings);
    try out.appendSlice(gpa, ",\n        \"warning\": ");
    try json_out.writeUsize(out, gpa, warning_findings);
    try out.appendSlice(gpa, ",\n        \"info\": ");
    try json_out.writeUsize(out, gpa, info_findings);
    try out.appendSlice(gpa, "\n      }\n    },\n    \"claims\": {\n");
    try out.appendSlice(gpa, "      \"total\": ");
    try json_out.writeUsize(out, gpa, model.parsed_claims.claims.len);
    try out.appendSlice(gpa, ",\n      \"by_status\": {\n");
    try out.appendSlice(gpa, "        \"verified\": ");
    try json_out.writeUsize(out, gpa, verified_claims);
    try out.appendSlice(gpa, ",\n        \"failed\": ");
    try json_out.writeUsize(out, gpa, failed_claims);
    try out.appendSlice(gpa, ",\n        \"not-verified\": ");
    try json_out.writeUsize(out, gpa, not_verified_claims);
    try out.appendSlice(gpa, "\n      }\n    },\n");
    try out.appendSlice(gpa, "    \"limitation_count\": ");
    try json_out.writeUsize(out, gpa, model.parsed_claims.limitations.len);
    try out.appendSlice(gpa, ",\n    \"relationship_node_count\": ");
    try json_out.writeUsize(out, gpa, model.parsed_touches.nodes.len);
    try out.appendSlice(gpa, ",\n    \"relationship_edge_count\": ");
    try json_out.writeUsize(out, gpa, model.parsed_touches.edges.len);
    try out.appendSlice(gpa, ",\n    \"overall_presentation_status\": ");
    try json_out.writeString(out, gpa, model.overall_status);
    try out.appendSlice(gpa, "\n  },\n");
}

fn stripPrefix(value: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, value, prefix)) return value[prefix.len..];
    return value;
}

/// Collect related check ids (without the `check:` prefix) for an artifact,
/// from validated Touch Atlas edges only, in canonical edge order.
fn relatedCheckIdsForArtifact(
    gpa: std.mem.Allocator,
    model: *const Model,
    artifact_id: []const u8,
) ![][]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| gpa.free(id);
        ids.deinit(gpa);
    }
    for (model.parsed_touches.edges) |edge| {
        if (edge.kind != .artifact_subject_of_check and edge.kind != .artifact_supports_check) continue;
        if (!std.mem.eql(u8, edge.from, artifact_id)) continue;
        try ids.append(gpa, try gpa.dupe(u8, stripPrefix(edge.to, "check:")));
    }
    return ids.toOwnedSlice(gpa);
}

/// Collect related claim ids (without the `claim:` prefix) for an artifact,
/// from the claims supported by its related checks, in canonical edge order.
fn relatedClaimIdsForArtifact(
    gpa: std.mem.Allocator,
    model: *const Model,
    artifact_id: []const u8,
) ![][]const u8 {
    var related_checks: std.ArrayList([]const u8) = .empty;
    defer related_checks.deinit(gpa);
    for (model.parsed_touches.edges) |edge| {
        if (edge.kind != .artifact_subject_of_check and edge.kind != .artifact_supports_check) continue;
        if (!std.mem.eql(u8, edge.from, artifact_id)) continue;
        try related_checks.append(gpa, edge.to);
    }
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| gpa.free(id);
        ids.deinit(gpa);
    }
    for (related_checks.items) |check_id| {
        for (model.parsed_touches.edges) |edge| {
            if (edge.kind != .check_supports_claim) continue;
            if (!std.mem.eql(u8, edge.from, check_id)) continue;
            try ids.append(gpa, try gpa.dupe(u8, stripPrefix(edge.to, "claim:")));
        }
    }
    return ids.toOwnedSlice(gpa);
}

fn writeRelationArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    label: []const u8,
    values: []const []const u8,
) !void {
    try json_out.indent(out, gpa, 3);
    try json_out.writeString(out, gpa, label);
    try out.appendSlice(gpa, ": ");
    try writeStringArray(out, gpa, values, 3);
}

fn renderArtifacts(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"artifacts\": [\n");
    for (model.inventory.records, 0..) |record, index| {
        const artifact_id = try std.mem.concat(gpa, u8, &.{ "artifact:", record.path });
        defer gpa.free(artifact_id);
        const related_checks = try relatedCheckIdsForArtifact(gpa, model, artifact_id);
        defer {
            for (related_checks) |id| gpa.free(id);
            gpa.free(related_checks);
        }
        const related_claims = try relatedClaimIdsForArtifact(gpa, model, artifact_id);
        defer {
            for (related_claims) |id| gpa.free(id);
            gpa.free(related_claims);
        }

        try out.appendSlice(gpa, "    {\n");
        try out.appendSlice(gpa, "      \"inventory_index\": ");
        try json_out.writeUsize(out, gpa, index);
        try out.appendSlice(gpa, ",\n      \"path\": ");
        try json_out.writeString(out, gpa, record.path);
        try out.appendSlice(gpa, ",\n      \"kind\": ");
        try json_out.writeString(out, gpa, record.kind.name());
        try out.appendSlice(gpa, ",\n      \"status\": ");
        try json_out.writeString(out, gpa, record.status.name());
        try out.appendSlice(gpa, ",\n      \"required\": ");
        try json_out.writeBool(out, gpa, record.required);
        if (record.status == .committed) {
            try out.appendSlice(gpa, ",\n      \"bytes\": ");
            try json_out.writeUsize(out, gpa, record.bytes);
            try out.appendSlice(gpa, ",\n      \"sha256\": ");
            try json_out.writeString(out, gpa, &record.sha256);
        }
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "related_check_ids", related_checks);
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "related_claim_ids", related_claims);
        try out.appendSlice(gpa, "\n    }");
        if (index + 1 < model.inventory.records.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ],\n");
}

fn renderChecks(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"checks\": [\n");
    for (model.parsed_checks.checks, 0..) |check, check_index| {
        const check_id = try std.mem.concat(gpa, u8, &.{ "check:", check.id });
        defer gpa.free(check_id);

        var finding_ids: std.ArrayList([]const u8) = .empty;
        defer finding_ids.deinit(gpa);
        var subject_artifacts: std.ArrayList([]const u8) = .empty;
        defer subject_artifacts.deinit(gpa);
        var supporting_artifacts: std.ArrayList([]const u8) = .empty;
        defer supporting_artifacts.deinit(gpa);
        var supported_claims: std.ArrayList([]const u8) = .empty;
        defer supported_claims.deinit(gpa);

        for (model.parsed_touches.edges) |edge| {
            if (edge.kind == .check_reported_finding and std.mem.eql(u8, edge.from, check_id)) {
                try finding_ids.append(gpa, edge.to);
            } else if (edge.kind == .artifact_subject_of_check and std.mem.eql(u8, edge.to, check_id)) {
                try subject_artifacts.append(gpa, edge.from);
            } else if (edge.kind == .artifact_supports_check and std.mem.eql(u8, edge.to, check_id)) {
                try supporting_artifacts.append(gpa, edge.from);
            } else if (edge.kind == .check_supports_claim and std.mem.eql(u8, edge.from, check_id)) {
                try supported_claims.append(gpa, edge.to);
            }
        }

        try out.appendSlice(gpa, "    {\n");
        try out.appendSlice(gpa, "      \"check_index\": ");
        try json_out.writeUsize(out, gpa, check_index);
        try out.appendSlice(gpa, ",\n      \"check_id\": ");
        try json_out.writeString(out, gpa, check.id);
        try out.appendSlice(gpa, ",\n      \"status\": ");
        try json_out.writeString(out, gpa, check.status);
        try out.appendSlice(gpa, ",\n      \"coverage\": ");
        try json_out.writeString(out, gpa, check.coverage);
        try out.appendSlice(gpa, ",\n      \"eligible\": ");
        try json_out.writeBool(out, gpa, check.eligible);
        try out.appendSlice(gpa, ",\n      \"ran\": ");
        try json_out.writeBool(out, gpa, check.ran);
        try out.appendSlice(gpa, ",\n      \"counts\": {\n");
        try out.appendSlice(gpa, "        \"eligible\": ");
        try json_out.writeUsize(out, gpa, check.counts_eligible);
        try out.appendSlice(gpa, ",\n        \"checked\": ");
        try json_out.writeUsize(out, gpa, check.counts_checked);
        try out.appendSlice(gpa, ",\n        \"findings\": ");
        try json_out.writeUsize(out, gpa, check.counts_findings);
        try out.appendSlice(gpa, "\n      },\n");
        try writeRelationArray(out, gpa, "finding_ids", finding_ids.items);
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "subject_artifact_ids", subject_artifacts.items);
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "supporting_artifact_ids", supporting_artifacts.items);
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "supported_claim_ids", supported_claims.items);
        try out.appendSlice(gpa, "\n    }");
        if (check_index + 1 < model.parsed_checks.checks.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ],\n");
}

fn renderFindings(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"findings\": [\n");
    for (model.parsed_checks.findings, 0..) |finding, index| {
        const owning_check = owningCheck(model.parsed_checks, index) orelse
            return error.InvalidChecksReport;
        const ordinal = index - model.parsed_checks.checks[owning_check].finding_offset;
        const finding_id = try findingNodeId(gpa, model.parsed_checks.checks[owning_check].id, ordinal);
        defer gpa.free(finding_id);

        try out.appendSlice(gpa, "    {\n");
        try out.appendSlice(gpa, "      \"finding_index\": ");
        try json_out.writeUsize(out, gpa, index);
        try out.appendSlice(gpa, ",\n      \"finding_id\": ");
        try json_out.writeString(out, gpa, finding_id);
        try out.appendSlice(gpa, ",\n      \"check_id\": ");
        try json_out.writeString(out, gpa, model.parsed_checks.checks[owning_check].id);
        try out.appendSlice(gpa, ",\n      \"code\": ");
        try json_out.writeString(out, gpa, finding.code);
        try out.appendSlice(gpa, ",\n      \"severity\": ");
        try json_out.writeString(out, gpa, finding.severity);
        try out.appendSlice(gpa, ",\n      \"subject\": {\n");
        try out.appendSlice(gpa, "        \"kind\": ");
        try json_out.writeString(out, gpa, finding.subject.kind);
        try out.appendSlice(gpa, ",\n        \"id\": ");
        try json_out.writeString(out, gpa, finding.subject.id);
        try out.appendSlice(gpa, ",\n        \"target\": ");
        if (finding.subject.target) |subject_target| {
            try json_out.writeString(out, gpa, subject_target);
        } else {
            try json_out.writeNull(out, gpa);
        }
        try out.appendSlice(gpa, "\n      }\n    }");
        if (index + 1 < model.parsed_checks.findings.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ],\n");
}

fn owningCheck(checks: *const ParsedChecks, finding_index: usize) ?usize {
    for (checks.checks, 0..) |check, check_index| {
        const start = check.finding_offset;
        const end = std.math.add(usize, start, check.counts_findings) catch continue;
        if (finding_index >= start and finding_index < end) return check_index;
    }
    return null;
}

fn findingNodeId(gpa: std.mem.Allocator, check_id: []const u8, ordinal: usize) ![]u8 {
    var buffer: [64]u8 = undefined;
    const ordinal_text = std.fmt.bufPrint(&buffer, "{d}", .{ordinal}) catch return error.OutOfMemory;
    return std.mem.concat(gpa, u8, &.{ "finding:", check_id, ":", ordinal_text });
}

fn renderClaims(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"claims\": [\n");
    for (model.parsed_claims.claims, 0..) |claim, index| {
        try out.appendSlice(gpa, "    {\n");
        try out.appendSlice(gpa, "      \"claim_index\": ");
        try json_out.writeUsize(out, gpa, index);
        try out.appendSlice(gpa, ",\n      \"claim_id\": ");
        try json_out.writeString(out, gpa, claim.id);
        try out.appendSlice(gpa, ",\n      \"statement\": ");
        try json_out.writeString(out, gpa, claim.statement);
        try out.appendSlice(gpa, ",\n      \"status\": ");
        try json_out.writeString(out, gpa, claim.status);
        try out.appendSlice(gpa, ",\n      \"evidence_check_id\": ");
        try json_out.writeString(out, gpa, claim.evidence.check_id);
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "limitation_ids", claim.limitation_ids);
        try out.appendSlice(gpa, "\n    }");
        if (index + 1 < model.parsed_claims.claims.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ],\n");
}

fn renderLimitations(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"limitations\": [\n");
    for (model.parsed_claims.limitations, 0..) |limitation, index| {
        try out.appendSlice(gpa, "    {\n");
        try out.appendSlice(gpa, "      \"limitation_index\": ");
        try json_out.writeUsize(out, gpa, index);
        try out.appendSlice(gpa, ",\n      \"limitation_id\": ");
        try json_out.writeString(out, gpa, limitation.id);
        try out.appendSlice(gpa, ",\n      \"statement\": ");
        try json_out.writeString(out, gpa, limitation.statement);
        try out.appendSlice(gpa, ",\n      \"source\": ");
        try json_out.writeString(out, gpa, limitation.source);
        try out.appendSlice(gpa, ",\n");
        try writeRelationArray(out, gpa, "applies_to_claim_ids", limitation.applies_to_claims);
        try out.appendSlice(gpa, "\n    }");
        if (index + 1 < model.parsed_claims.limitations.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ],\n");
}

fn renderRelationships(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"relationships\": {\n");
    try out.appendSlice(gpa, "    \"node_ids\": ");
    var node_ids: std.ArrayList([]const u8) = .empty;
    defer node_ids.deinit(gpa);
    for (model.parsed_touches.nodes) |node| try node_ids.append(gpa, node.id);
    try writeStringArray(out, gpa, node_ids.items, 2);
    try out.appendSlice(gpa, ",\n    \"groups\": [\n");

    const group_kinds = [_]EdgeKind{
        .target_owns_artifact,
        .artifact_subject_of_check,
        .artifact_supports_check,
        .check_reported_finding,
        .check_supports_claim,
        .claim_limited_by,
    };
    for (group_kinds, 0..) |kind, group_index| {
        try out.appendSlice(gpa, "      {\n");
        try out.appendSlice(gpa, "        \"edge_kind\": ");
        try json_out.writeString(out, gpa, kind.name());
        try out.appendSlice(gpa, ",\n        \"edges\": [\n");
        var first_in_group = true;
        for (model.parsed_touches.edges) |edge| {
            if (edge.kind != kind) continue;
            if (!first_in_group) try out.appendSlice(gpa, ",\n");
            first_in_group = false;
            try out.appendSlice(gpa, "          { \"from\": ");
            try json_out.writeString(out, gpa, edge.from);
            try out.appendSlice(gpa, ", \"to\": ");
            try json_out.writeString(out, gpa, edge.to);
            try out.appendSlice(gpa, " }");
        }
        try out.appendSlice(gpa, "\n        ]\n      }");
        if (group_index + 1 < group_kinds.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "    ]\n  },\n");
}

fn renderPresentation(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  \"presentation\": {\n");
    try out.appendSlice(gpa, "    \"overall_status\": ");
    try json_out.writeString(out, gpa, model.overall_status);
    try out.appendSlice(gpa, ",\n    \"status_vocabulary\": [\n");
    const vocabulary = [_][]const u8{ "verified", "attention-required", "incomplete", "not-applicable" };
    for (vocabulary, 0..) |status, index| {
        try out.appendSlice(gpa, "      ");
        try json_out.writeString(out, gpa, status);
        if (index + 1 < vocabulary.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "    ]\n  }\n");
}

// ---------------------------------------------------------------------------
// HTML renderer (deterministic static UTF-8; no JS, no remote resources).
// ---------------------------------------------------------------------------

/// Write a decimal number into the HTML buffer without `.print` (the emitter
/// discipline requires every emitter write to pass through an audited encoder
/// or a literal append; `bufPrint` into a local buffer and `appendSlice` keeps
/// that discipline).
fn writeHtmlNumber(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
    return proof_html.writeHtmlNumber(out, gpa, value);
}

fn escapeHtml(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    return proof_html.escapeHtml(out, gpa, value);
}

fn writeHtmlEscaped(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    return proof_html.writeHtmlEscaped(out, gpa, value);
}

fn writeHtmlCode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    return proof_html.writeHtmlCode(out, gpa, value);
}

fn joinHtmlList(out: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const []const u8, fallback: []const u8) !void {
    return proof_html.joinHtmlList(out, gpa, values, fallback);
}

const embedded_css = proof_html.embedded_css;

fn renderHtml(
    gpa: std.mem.Allocator,
    model: *const Model,
    json_sha256: [64]u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n");
    try out.appendSlice(gpa, "<meta charset=\"utf-8\">\n");
    try out.appendSlice(gpa, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try out.appendSlice(gpa, "<meta name=\"proof-pack-sha256\" content=\"");
    try out.appendSlice(gpa, &json_sha256);
    try out.appendSlice(gpa, "\">\n");
    try out.appendSlice(gpa, "<title>Publication Proof Pack — ");
    try writeHtmlEscaped(&out, gpa, model.target);
    try out.appendSlice(gpa, " ");
    try writeHtmlEscaped(&out, gpa, statusTitleSuffix(model.overall_status));
    try out.appendSlice(gpa, "</title>\n<style>\n");
    try out.appendSlice(gpa, embedded_css);
    try out.appendSlice(gpa, "\n</style>\n</head>\n<body>\n<header>\n");
    try out.appendSlice(gpa, "  <h1>Publication Proof Pack</h1>\n  <p class=\"meta\">\n");
    try out.appendSlice(gpa, "    <code>format: boris-publication-proof-pack</code> ·\n");
    try out.appendSlice(gpa, "    <code>schema_version: 1</code> ·\n");
    try out.appendSlice(gpa, "    target <code>");
    try writeHtmlEscaped(&out, gpa, model.target);
    try out.appendSlice(gpa, "</code>\n  </p>\n");
    try out.appendSlice(gpa, "  <div class=\"banner ");
    try out.appendSlice(gpa, statusBannerClass(model.overall_status));
    try out.appendSlice(gpa, "\" id=\"banner\">Overall presentation status: ");
    try writeHtmlEscaped(&out, gpa, model.overall_status);
    try out.appendSlice(gpa, "</div>\n");
    if (std.mem.eql(u8, model.overall_status, "attention-required")) {
        try renderHtmlAttentionExplanation(&out, gpa, model);
    } else if (std.mem.eql(u8, model.overall_status, "incomplete")) {
        try out.appendSlice(gpa, "  <p>At least one check is incomplete, so this publication's evidence does not cover every declared scope.</p>\n");
    } else if (std.mem.eql(u8, model.overall_status, "not-applicable")) {
        try out.appendSlice(gpa, "  <p>Every check is not-applicable for this target; no checks ran and no claim is certified.</p>\n");
    }
    try out.appendSlice(gpa, "</header>\n\n<nav aria-label=\"Contents\">\n  <ul>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#summary\">Summary</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#claims\">Claims</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#limitations\">Limitations</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#findings\">Findings</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#checks\">Checks</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#artifacts\">Artifacts</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#relationships\">Relationships</a></li>\n");
    try out.appendSlice(gpa, "    <li><a href=\"#inputs\">Inputs</a></li>\n");
    try out.appendSlice(gpa, "  </ul>\n</nav>\n\n<main>\n");

    try renderHtmlSummary(&out, gpa, model);
    try renderHtmlClaims(&out, gpa, model);
    try renderHtmlLimitations(&out, gpa, model);
    try renderHtmlFindings(&out, gpa, model);
    try renderHtmlChecks(&out, gpa, model);
    try renderHtmlArtifacts(&out, gpa, model);
    try renderHtmlRelationships(&out, gpa, model);
    try renderHtmlInputs(&out, gpa, model);

    try out.appendSlice(gpa, "</main>\n\n<footer>\n  <p>\n");
    try out.appendSlice(gpa, "    This page is a deterministic static rendering of <code>_boris/proof/proof-pack.json</code>\n");
    try out.appendSlice(gpa, "    (target <code>");
    try writeHtmlEscaped(&out, gpa, model.target);
    try out.appendSlice(gpa, "</code>). It requires no JavaScript, loads no remote resources,\n");
    try out.appendSlice(gpa, "    and is printable. A rendered page is not a new verification claim.\n  </p>\n</footer>\n</body>\n</html>\n");
    return out.toOwnedSlice(gpa);
}

fn renderHtmlSummary(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    var artifacts_total: usize = 0;
    var committed: usize = 0;
    var omitted: usize = 0;
    var na_artifact: usize = 0;
    var by_kind = [_]usize{0} ** 7;
    for (model.inventory.records) |record| {
        artifacts_total += 1;
        switch (record.status) {
            .committed => committed += 1,
            .omitted_by_plan => omitted += 1,
            .not_applicable => na_artifact += 1,
        }
        by_kind[@intFromEnum(record.kind)] += 1;
    }
    var passed: usize = 0;
    var failed: usize = 0;
    var incomplete_check: usize = 0;
    var na_check: usize = 0;
    var complete_cov: usize = 0;
    var incomplete_cov: usize = 0;
    var na_cov: usize = 0;
    for (model.parsed_checks.checks) |check| {
        if (std.mem.eql(u8, check.status, "passed")) passed += 1;
        if (std.mem.eql(u8, check.status, "failed")) failed += 1;
        if (std.mem.eql(u8, check.status, "incomplete")) incomplete_check += 1;
        if (std.mem.eql(u8, check.status, "not-applicable")) na_check += 1;
        if (std.mem.eql(u8, check.coverage, "complete")) complete_cov += 1;
        if (std.mem.eql(u8, check.coverage, "incomplete")) incomplete_cov += 1;
        if (std.mem.eql(u8, check.coverage, "not-applicable")) na_cov += 1;
    }
    var error_findings: usize = 0;
    var warning_findings: usize = 0;
    var info_findings: usize = 0;
    for (model.parsed_checks.findings) |finding| {
        if (std.mem.eql(u8, finding.severity, "error")) error_findings += 1;
        if (std.mem.eql(u8, finding.severity, "warning")) warning_findings += 1;
        if (std.mem.eql(u8, finding.severity, "info")) info_findings += 1;
    }
    var verified_claims: usize = 0;
    var failed_claims: usize = 0;
    var not_verified_claims: usize = 0;
    for (model.parsed_claims.claims) |claim| {
        if (std.mem.eql(u8, claim.status, "verified")) verified_claims += 1;
        if (std.mem.eql(u8, claim.status, "failed")) failed_claims += 1;
        if (std.mem.eql(u8, claim.status, "not-verified")) not_verified_claims += 1;
    }

    try out.appendSlice(gpa, "  <section id=\"summary\">\n    <h2>Summary</h2>\n    <div class=\"table-wrap\">\n    <table>\n      <tbody>\n");
    try out.appendSlice(gpa, "        <tr><th>Artifacts</th><td>");
    try writeHtmlNumber(out, gpa, artifacts_total);
    try out.appendSlice(gpa, " total — committed ");
    try writeHtmlNumber(out, gpa, committed);
    try out.appendSlice(gpa, ", omitted-by-plan ");
    try writeHtmlNumber(out, gpa, omitted);
    try out.appendSlice(gpa, ", not-applicable ");
    try writeHtmlNumber(out, gpa, na_artifact);
    try out.appendSlice(gpa, " (html-page ");
    try writeHtmlNumber(out, gpa, by_kind[0]);
    try out.appendSlice(gpa, ", theme-asset ");
    try writeHtmlNumber(out, gpa, by_kind[1]);
    try out.appendSlice(gpa, ", content-asset ");
    try writeHtmlNumber(out, gpa, by_kind[2]);
    try out.appendSlice(gpa, ", rendered-search ");
    try writeHtmlNumber(out, gpa, by_kind[3]);
    try out.appendSlice(gpa, ", sitemap ");
    try writeHtmlNumber(out, gpa, by_kind[4]);
    try out.appendSlice(gpa, ", rss ");
    try writeHtmlNumber(out, gpa, by_kind[5]);
    try out.appendSlice(gpa, ", llms ");
    try writeHtmlNumber(out, gpa, by_kind[6]);
    try out.appendSlice(gpa, ")</td></tr>\n");
    try out.appendSlice(gpa, "        <tr><th>Checks</th><td>");
    try writeHtmlNumber(out, gpa, model.parsed_checks.checks.len);
    try out.appendSlice(gpa, " total — passed ");
    try writeHtmlNumber(out, gpa, passed);
    try out.appendSlice(gpa, ", failed ");
    try writeHtmlNumber(out, gpa, failed);
    try out.appendSlice(gpa, ", incomplete ");
    try writeHtmlNumber(out, gpa, incomplete_check);
    try out.appendSlice(gpa, ", not-applicable ");
    try writeHtmlNumber(out, gpa, na_check);
    try out.appendSlice(gpa, " (coverage complete ");
    try writeHtmlNumber(out, gpa, complete_cov);
    try out.appendSlice(gpa, ", coverage incomplete ");
    try writeHtmlNumber(out, gpa, incomplete_cov);
    try out.appendSlice(gpa, ", coverage not-applicable ");
    try writeHtmlNumber(out, gpa, na_cov);
    try out.appendSlice(gpa, ")</td></tr>\n");
    try out.appendSlice(gpa, "        <tr><th>Findings</th><td>");
    try writeHtmlNumber(out, gpa, model.parsed_checks.findings.len);
    try out.appendSlice(gpa, " total — error ");
    try writeHtmlNumber(out, gpa, error_findings);
    try out.appendSlice(gpa, ", warning ");
    try writeHtmlNumber(out, gpa, warning_findings);
    try out.appendSlice(gpa, ", info ");
    try writeHtmlNumber(out, gpa, info_findings);
    try out.appendSlice(gpa, "</td></tr>\n");
    try out.appendSlice(gpa, "        <tr><th>Claims</th><td>");
    try writeHtmlNumber(out, gpa, model.parsed_claims.claims.len);
    try out.appendSlice(gpa, " total — verified ");
    try writeHtmlNumber(out, gpa, verified_claims);
    try out.appendSlice(gpa, ", failed ");
    try writeHtmlNumber(out, gpa, failed_claims);
    try out.appendSlice(gpa, ", not-verified ");
    try writeHtmlNumber(out, gpa, not_verified_claims);
    try out.appendSlice(gpa, "</td></tr>\n");
    try out.appendSlice(gpa, "        <tr><th>Limitations</th><td>");
    try writeHtmlNumber(out, gpa, model.parsed_claims.limitations.len);
    try out.appendSlice(gpa, "</td></tr>\n");
    try out.appendSlice(gpa, "        <tr><th>Relationship graph</th><td>");
    try writeHtmlNumber(out, gpa, model.parsed_touches.nodes.len);
    try out.appendSlice(gpa, " nodes, ");
    try writeHtmlNumber(out, gpa, model.parsed_touches.edges.len);
    try out.appendSlice(gpa, " edges</td></tr>\n");
    try out.appendSlice(gpa, "        <tr><th>Overall presentation status</th><td class=\"");
    try out.appendSlice(gpa, statusCssClass(model.overall_status));
    try out.appendSlice(gpa, "\">");
    try writeHtmlEscaped(out, gpa, model.overall_status);
    try out.appendSlice(gpa, "</td></tr>\n");
    try out.appendSlice(gpa, "      </tbody>\n    </table>\n    </div>\n  </section>\n\n");
}

fn renderHtmlInputs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"inputs\">\n    <h2>Inputs</h2>\n    <p>The Proof Pack is derived exclusively from the exact committed bytes of the four evidence reports below; nothing is reread or re-derived from source, payload, or deployment state.</p>\n    <div class=\"table-wrap\">\n    <table>\n      <thead>\n        <tr><th>input</th><th>path</th><th>bytes</th><th>sha256</th><th>format</th><th>schema</th><th>target</th></tr>\n      </thead>\n      <tbody>\n");
    const rows = [_]struct {
        label: []const u8,
        path: []const u8,
        binding: FileBinding,
        format: []const u8,
        version: usize,
        target: []const u8,
    }{
        .{ .label = "artifacts", .path = artifact_inventory.output_path, .binding = model.bindings.artifacts, .format = artifact_inventory.artifact_format, .version = artifact_inventory.schema_version, .target = model.target },
        .{ .label = "checks", .path = publication_checks.output_path, .binding = model.bindings.checks, .format = publication_checks.report_format, .version = publication_checks.schema_version, .target = model.target },
        .{ .label = "claims", .path = publication_claims.output_path, .binding = model.bindings.claims, .format = publication_claims.report_format, .version = publication_claims.schema_version, .target = model.target },
        .{ .label = "touches", .path = publication_touches.output_path, .binding = model.bindings.touches, .format = publication_touches.report_format, .version = publication_touches.schema_version, .target = model.target },
    };
    for (rows) |row| {
        try out.appendSlice(gpa, "        <tr><td>");
        try writeHtmlEscaped(out, gpa, row.label);
        try out.appendSlice(gpa, "</td><td><code>");
        try writeHtmlEscaped(out, gpa, row.path);
        try out.appendSlice(gpa, "</code></td><td>");
        try writeHtmlNumber(out, gpa, row.binding.bytes);
        try out.appendSlice(gpa, "</td><td><code>");
        try writeHtmlEscaped(out, gpa, &row.binding.sha256);
        try out.appendSlice(gpa, "</code></td><td><code>");
        try writeHtmlEscaped(out, gpa, row.format);
        try out.appendSlice(gpa, "</code></td><td>");
        try writeHtmlNumber(out, gpa, row.version);
        try out.appendSlice(gpa, "</td><td><code>");
        try writeHtmlEscaped(out, gpa, row.target);
        try out.appendSlice(gpa, "</code></td></tr>\n");
    }
    try out.appendSlice(gpa, "      </tbody>\n    </table>\n    </div>\n  </section>\n\n");
}

fn renderHtmlArtifacts(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"artifacts\">\n    <h2>Artifacts</h2>\n    <details>\n      <summary>Artifact inventory (");
    try writeHtmlNumber(out, gpa, model.inventory.records.len);
    try out.appendSlice(gpa, " records)</summary>\n    <div class=\"table-wrap\">\n    <table>\n      <thead>\n        <tr>\n          <th>#</th><th>Path</th><th>Kind</th><th>Status</th><th>Required</th><th>Bytes</th><th>SHA-256</th><th>Related checks</th><th>Related claims</th>\n        </tr>\n      </thead>\n      <tbody>\n");
    for (model.inventory.records, 0..) |record, index| {
        const artifact_id = try std.mem.concat(gpa, u8, &.{ "artifact:", record.path });
        defer gpa.free(artifact_id);
        const related_checks = try relatedCheckIdsForArtifact(gpa, model, artifact_id);
        defer {
            for (related_checks) |id| gpa.free(id);
            gpa.free(related_checks);
        }
        const related_claims = try relatedClaimIdsForArtifact(gpa, model, artifact_id);
        defer {
            for (related_claims) |id| gpa.free(id);
            gpa.free(related_claims);
        }
        try out.appendSlice(gpa, "        <tr>\n          <td>");
        try writeHtmlNumber(out, gpa, index);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlCode(out, gpa, record.path);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlEscaped(out, gpa, record.kind.name());
        try out.appendSlice(gpa, "</td>\n          <td class=\"");
        try out.appendSlice(gpa, statusCssClass(record.status.name()));
        try out.appendSlice(gpa, "\">");
        try writeHtmlEscaped(out, gpa, record.status.name());
        try out.appendSlice(gpa, "</td>\n          <td>");
        try out.appendSlice(gpa, if (record.required) "yes" else "no");
        try out.appendSlice(gpa, "</td>\n");
        if (record.status == .committed) {
            try out.appendSlice(gpa, "          <td>");
            try writeHtmlNumber(out, gpa, record.bytes);
            try out.appendSlice(gpa, "</td>\n          <td class=\"mono\">");
            try out.appendSlice(gpa, &record.sha256);
            try out.appendSlice(gpa, "</td>\n");
        } else {
            try out.appendSlice(gpa, "          <td colspan=\"2\" class=\"empty\">no committed bytes — omitted from this target</td>\n");
        }
        try out.appendSlice(gpa, "          <td>");
        try joinHtmlList(out, gpa, related_checks, "—");
        try out.appendSlice(gpa, "</td>\n          <td>");
        try joinHtmlList(out, gpa, related_claims, "—");
        try out.appendSlice(gpa, "</td>\n        </tr>\n");
    }
    try out.appendSlice(gpa, "      </tbody>\n    </table>\n    </div>\n    <p>Records that are not committed carry no committed-byte properties; no zero values are invented for them.</p>\n    </details>\n  </section>\n\n");
}

fn renderHtmlChecks(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"checks\">\n    <h2>Checks</h2>\n    <div class=\"table-wrap\">\n    <table>\n      <thead>\n        <tr>\n          <th>#</th><th>Check</th><th>Status</th><th>Coverage</th><th>Eligible</th><th>Ran</th><th>Counts (eligible / checked / findings)</th><th>Subject artifacts</th><th>Supporting artifacts</th><th>Supported claims</th>\n        </tr>\n      </thead>\n      <tbody>\n");
    for (model.parsed_checks.checks, 0..) |check, check_index| {
        const check_id = try std.mem.concat(gpa, u8, &.{ "check:", check.id });
        defer gpa.free(check_id);
        var finding_ids: std.ArrayList([]const u8) = .empty;
        defer finding_ids.deinit(gpa);
        var subject_artifacts: std.ArrayList([]const u8) = .empty;
        defer subject_artifacts.deinit(gpa);
        var supporting_artifacts: std.ArrayList([]const u8) = .empty;
        defer supporting_artifacts.deinit(gpa);
        var supported_claims: std.ArrayList([]const u8) = .empty;
        defer supported_claims.deinit(gpa);
        for (model.parsed_touches.edges) |edge| {
            if (edge.kind == .check_reported_finding and std.mem.eql(u8, edge.from, check_id)) {
                try finding_ids.append(gpa, edge.to);
            } else if (edge.kind == .artifact_subject_of_check and std.mem.eql(u8, edge.to, check_id)) {
                try subject_artifacts.append(gpa, edge.from);
            } else if (edge.kind == .artifact_supports_check and std.mem.eql(u8, edge.to, check_id)) {
                try supporting_artifacts.append(gpa, edge.from);
            } else if (edge.kind == .check_supports_claim and std.mem.eql(u8, edge.from, check_id)) {
                try supported_claims.append(gpa, edge.to);
            }
        }
        try out.appendSlice(gpa, "        <tr>\n          <td>");
        try writeHtmlNumber(out, gpa, check_index);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlCode(out, gpa, check.id);
        try out.appendSlice(gpa, "</td>\n          <td class=\"");
        try out.appendSlice(gpa, statusCssClass(check.status));
        try out.appendSlice(gpa, "\">");
        try writeHtmlEscaped(out, gpa, check.status);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlEscaped(out, gpa, check.coverage);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try out.appendSlice(gpa, if (check.eligible) "yes" else "no");
        try out.appendSlice(gpa, "</td>\n          <td>");
        try out.appendSlice(gpa, if (check.ran) "yes" else "no");
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlNumber(out, gpa, check.counts_eligible);
        try out.appendSlice(gpa, " / ");
        try writeHtmlNumber(out, gpa, check.counts_checked);
        try out.appendSlice(gpa, " / ");
        try writeHtmlNumber(out, gpa, check.counts_findings);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try joinHtmlList(out, gpa, subject_artifacts.items, "—");
        try out.appendSlice(gpa, "</td>\n          <td>");
        try joinHtmlList(out, gpa, supporting_artifacts.items, "—");
        try out.appendSlice(gpa, "</td>\n          <td>");
        try joinHtmlList(out, gpa, supported_claims.items, "—");
        try out.appendSlice(gpa, "</td>\n        </tr>\n");
    }
    try out.appendSlice(gpa, "      </tbody>\n    </table>\n    </div>\n  </section>\n\n");
}

fn renderHtmlFindings(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"findings\">\n    <h2>Findings</h2>\n");
    if (model.parsed_checks.findings.len == 0) {
        try out.appendSlice(gpa, "    <p class=\"empty\">No findings were recorded for this target. This section is intentionally empty; the absence of findings is not a claim of excellence.</p>\n  </section>\n\n");
        return;
    }
    try out.appendSlice(gpa, "    <div class=\"table-wrap\">\n    <table>\n      <thead>\n        <tr><th>#</th><th>Finding</th><th>Check</th><th>Code</th><th>Severity</th><th>Subject</th></tr>\n      </thead>\n      <tbody>\n");
    for (model.parsed_checks.findings, 0..) |finding, index| {
        const owning = owningCheck(model.parsed_checks, index) orelse
            return error.InvalidChecksReport;
        const ordinal = index - model.parsed_checks.checks[owning].finding_offset;
        const finding_id = try findingNodeId(gpa, model.parsed_checks.checks[owning].id, ordinal);
        defer gpa.free(finding_id);
        try out.appendSlice(gpa, "        <tr>\n          <td>");
        try writeHtmlNumber(out, gpa, index);
        try out.appendSlice(gpa, "</td>\n          <td class=\"mono\">");
        try writeHtmlEscaped(out, gpa, finding_id);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlCode(out, gpa, model.parsed_checks.checks[owning].id);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlCode(out, gpa, finding.code);
        try out.appendSlice(gpa, "</td>\n          <td class=\"");
        try out.appendSlice(gpa, statusCssClass(finding.severity));
        try out.appendSlice(gpa, "\">");
        try writeHtmlEscaped(out, gpa, finding.severity);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlEscaped(out, gpa, finding.subject.kind);
        try out.appendSlice(gpa, " <code>");
        try writeHtmlEscaped(out, gpa, finding.subject.id);
        try out.appendSlice(gpa, "</code> (target ");
        if (finding.subject.target) |subject_target| {
            try writeHtmlEscaped(out, gpa, subject_target);
        } else {
            try out.appendSlice(gpa, "—");
        }
        try out.appendSlice(gpa, ")</td>\n        </tr>\n");
    }
    try out.appendSlice(gpa, "      </tbody>\n    </table>\n    </div>\n    <p>No finding-to-artifact relationship is inferred from path resemblance; the subjects above are copied verbatim from the checks evidence.</p>\n  </section>\n\n");
}

fn renderHtmlClaims(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"claims\">\n    <h2>Claims</h2>\n    <div class=\"table-wrap\">\n    <table>\n      <thead>\n        <tr><th>#</th><th>Claim</th><th>Status</th><th>Evidence check</th><th>Statement</th><th>Limitations</th></tr>\n      </thead>\n      <tbody>\n");
    for (model.parsed_claims.claims, 0..) |claim, index| {
        try out.appendSlice(gpa, "        <tr>\n          <td>");
        try writeHtmlNumber(out, gpa, index);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlCode(out, gpa, claim.id);
        try out.appendSlice(gpa, "</td>\n          <td class=\"");
        try out.appendSlice(gpa, statusCssClass(claim.status));
        try out.appendSlice(gpa, "\">");
        try writeHtmlEscaped(out, gpa, claim.status);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlCode(out, gpa, claim.evidence.check_id);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlEscaped(out, gpa, claim.statement);
        try out.appendSlice(gpa, "</td>\n          <td>");
        try writeHtmlNumber(out, gpa, claim.limitation_ids.len);
        try out.appendSlice(gpa, "</td>\n        </tr>\n");
    }
    try out.appendSlice(gpa, "      </tbody>\n    </table>\n    </div>\n  </section>\n\n");
}

fn renderHtmlLimitations(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"limitations\">\n    <h2>Limitations</h2>\n");
    if (std.mem.eql(u8, model.overall_status, "verified")) {
        try out.appendSlice(gpa, "    <p>Limitations remain visible even though all claims are verified. Each claim is bounded by the limitations below; a verified claim inherits their scope.</p>\n");
    } else {
        try out.appendSlice(gpa, "    <p>The failed claims are still bounded by their limitations. A failed or unverified claim inherits the same scope limits as any other claim.</p>\n");
    }
    try out.appendSlice(gpa, "    <ul class=\"plain\">\n");
    for (model.parsed_claims.limitations) |limitation| {
        try out.appendSlice(gpa, "      <li><strong>");
        try writeHtmlCode(out, gpa, limitation.id);
        try out.appendSlice(gpa, "</strong> — ");
        try writeHtmlEscaped(out, gpa, limitation.statement);
        try out.appendSlice(gpa, " <span class=\"src\">source: ");
        try writeHtmlEscaped(out, gpa, limitation.source);
        try out.appendSlice(gpa, "</span></li>\n");
    }
    try out.appendSlice(gpa, "    </ul>\n  </section>\n\n");
}

/// One brief human explanation per edge kind, shown beside each group. The
/// explanations never rename the exact kind strings and never infer a new
/// relationship: they only restate what the closed v1 edge vocabulary means.
const edge_kind_explanations = [_][]const u8{
    "The target includes this artifact inventory record.",
    "The artifact is part of the check's declared subject scope.",
    "The artifact is supporting evidence used by the check.",
    "The finding was reported by this check.",
    "The claim is bound to evidence from this check. This does not imply the check passed.",
    "The limitation restricts the scope of this claim.",
};

fn renderHtmlRelationships(out: *std.ArrayList(u8), gpa: std.mem.Allocator, model: *const Model) !void {
    try out.appendSlice(gpa, "  <section id=\"relationships\">\n    <h2>Relationships</h2>\n    <p>");
    try writeHtmlNumber(out, gpa, model.parsed_touches.nodes.len);
    try out.appendSlice(gpa, " nodes and ");
    try writeHtmlNumber(out, gpa, model.parsed_touches.edges.len);
    try out.appendSlice(gpa, " edges");
    try out.appendSlice(gpa, ", grouped by Touch Atlas edge kind. Every edge below is an exact Touch Atlas edge; nothing is inferred.</p>\n");

    // The node inventory is a genuinely large area; collapse it behind native
    // <details> with the exact count in the summary label.
    try out.appendSlice(gpa, "    <details>\n      <summary>Relationship nodes (");
    try writeHtmlNumber(out, gpa, model.parsed_touches.nodes.len);
    try out.appendSlice(gpa, ")</summary>\n      <ul class=\"plain\">\n");
    for (model.parsed_touches.nodes) |node| {
        try out.appendSlice(gpa, "        <li>");
        try writeHtmlEscaped(out, gpa, node.id);
        try out.appendSlice(gpa, "</li>\n");
    }
    try out.appendSlice(gpa, "      </ul>\n    </details>\n");

    const group_kinds = [_]EdgeKind{
        .target_owns_artifact,
        .artifact_subject_of_check,
        .artifact_supports_check,
        .check_reported_finding,
        .check_supports_claim,
        .claim_limited_by,
    };
    for (group_kinds, edge_kind_explanations) |kind, explanation| {
        var count: usize = 0;
        for (model.parsed_touches.edges) |edge| {
            if (edge.kind == kind) count += 1;
        }
        // Each edge group is a potentially large area; collapse it behind
        // native <details> with the exact edge count in the summary label.
        try out.appendSlice(gpa, "    <details>\n      <summary>");
        try writeHtmlEscaped(out, gpa, kind.name());
        try out.appendSlice(gpa, " (");
        try writeHtmlNumber(out, gpa, count);
        try out.appendSlice(gpa, " edges)</summary>\n");
        try out.appendSlice(gpa, "      <p class=\"edge-explain\">");
        try writeHtmlEscaped(out, gpa, explanation);
        try out.appendSlice(gpa, "</p>\n");
        if (count == 0) {
            try out.appendSlice(gpa, "      <p class=\"empty\">No edges are present in this relationship group.</p>\n");
            try out.appendSlice(gpa, "    </details>\n");
            continue;
        }
        try out.appendSlice(gpa, "      <ul class=\"plain\">\n");
        for (model.parsed_touches.edges) |edge| {
            if (edge.kind != kind) continue;
            try out.appendSlice(gpa, "        <li>");
            try writeHtmlEscaped(out, gpa, edge.from);
            try out.appendSlice(gpa, " → ");
            try writeHtmlEscaped(out, gpa, edge.to);
            try out.appendSlice(gpa, "</li>\n");
        }
        try out.appendSlice(gpa, "      </ul>\n    </details>\n");
    }
    try out.appendSlice(gpa, "  </section>\n\n");
}

// ---------------------------------------------------------------------------
// First-slice staged transaction.
// ---------------------------------------------------------------------------

fn pathExists(io: Io, root: Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

fn writeTmpFile(
    io: Io,
    root: Io.Dir,
    path: []const u8,
    bytes: []const u8,
    fail_error: Error,
) Error!void {
    var atomic = root.createFileAtomic(io, path, .{ .replace = true, .make_path = true }) catch {
        return fail_error;
    };
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return fail_error;
    writer.interface.flush() catch return fail_error;
    atomic.replace(io) catch return fail_error;
}

/// Stream-compare a temporary file against the already-rendered expected
/// bytes without allocating a second output-sized buffer. The comparison
/// detects different bytes, a truncated temporary file, extra trailing
/// bytes, and read failure, all reported as the handled `fail_error`. There
/// is no Proof Pack byte maximum on this path. (A read-failure probe after
/// the expected bytes also catches a file that grew mid-read.)
fn verifyTmpBytes(
    io: Io,
    root: Io.Dir,
    path: []const u8,
    expected: []const u8,
    fail_error: Error,
) Error!void {
    var file = root.openFile(io, path, .{}) catch return fail_error;
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);

    var index: usize = 0;
    var chunk: [64 * 1024]u8 = undefined;
    while (index < expected.len) {
        const remaining = expected.len - index;
        const want = chunk[0..@min(chunk.len, remaining)];
        const n = reader.interface.readSliceShort(want) catch return fail_error;
        if (n == 0) return fail_error; // truncated temporary file
        if (!std.mem.eql(u8, chunk[0..n], expected[index .. index + n])) return fail_error;
        index += n;
    }
    // Any byte past the expected length is an extra-trailing-bytes failure.
    var probe: [1]u8 = undefined;
    const extra = reader.interface.readSliceShort(&probe) catch return fail_error;
    if (extra != 0) return fail_error;
}

fn readFileAlloc(io: Io, root: Io.Dir, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    return reader.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024));
}

/// Exact original-state tracker for the pair transaction. Every boolean is
/// derived from the observed filesystem state before any rename, so rollback
/// can restore the exact original existence and bytes of both paths.
const PairState = struct {
    /// The committed `proof-pack.json` existed when the generation began.
    json_original_existed: bool,
    /// The committed `index.html` existed when the generation began.
    html_original_existed: bool,
    /// The original `proof-pack.json` was moved to `.prev`.
    json_preserved: bool,
    /// The original `index.html` was moved to `.prev`.
    html_preserved: bool,
    /// A new `index.html` was renamed into place.
    html_installed: bool,
    /// A new `proof-pack.json` was renamed into place.
    json_installed: bool,
};

/// The first-slice generation transaction:
///
/// 1. write and verify both temporary sibling files (streaming compare);
/// 2. snapshot the original pair state;
/// 3. move the current pair aside in the contract order (`index.html` first,
///    then `proof-pack.json`); any failure here rolls back every preservation
///    rename that already succeeded;
/// 4. install `index.html` first;
/// 5. install the authoritative `proof-pack.json` last (commit point);
/// 6. delete the `.prev` files.
///
/// On a synchronous failure, rollback restores the exact original state:
/// an originally-present file is restored from `.prev`; an originally-absent
/// file has any newly installed current file removed, so a new file is never
/// left paired with an absent or stale partner. When rollback itself fails,
/// the `.prev` files are kept and the specific restore/remove error is
/// propagated so the caller reports the pair as possibly split or absent.
/// This transaction makes no multi-file atomic-visibility claim.
fn installPair(
    io: Io,
    root: Io.Dir,
    json_bytes: []const u8,
    html_bytes: []const u8,
    options: Options,
) Error!void {

    // 1. Write and verify both temporary files. The verification streams the
    // sibling against the exact committed bytes, so a partial, truncated,
    // altered, or extended temporary write is a handled synchronous failure
    // without a second output-sized allocation.
    try writeTmpFile(io, root, artifact_inventory.proof_pack_tmp_path, json_bytes, error.JsonTmpWriteFailed);
    if (options.test_fail_json_tmp_write) return error.JsonTmpWriteFailed;
    try verifyTmpBytes(io, root, artifact_inventory.proof_pack_tmp_path, json_bytes, error.JsonTmpWriteFailed);
    try writeTmpFile(io, root, artifact_inventory.proof_index_tmp_path, html_bytes, error.HtmlTmpWriteFailed);
    if (options.test_fail_html_tmp_write) return error.HtmlTmpWriteFailed;
    try verifyTmpBytes(io, root, artifact_inventory.proof_index_tmp_path, html_bytes, error.HtmlTmpWriteFailed);

    // 2. Snapshot the exact original state before any rename.
    var state = PairState{
        .json_original_existed = pathExists(io, root, artifact_inventory.proof_pack_output_path),
        .html_original_existed = pathExists(io, root, artifact_inventory.proof_index_output_path),
        .json_preserved = false,
        .html_preserved = false,
        .html_installed = false,
        .json_installed = false,
    };

    // 3. Preserve the current pair in the contract order: `index.html` first,
    // then `proof-pack.json`. A failure before the first rename leaves
    // nothing to roll back; a failure after a rename restores every rename
    // that already succeeded.
    if (options.test_fail_preserve_prior) return error.PreservePriorFailed;
    if (state.html_original_existed) {
        root.rename(artifact_inventory.proof_index_output_path, root, artifact_inventory.proof_index_prev_path, io) catch return error.PreserveHtmlFailed;
        state.html_preserved = true;
    }
    if (options.test_fail_preserve_json) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.PreserveJsonFailed;
    }
    if (state.json_original_existed) {
        root.rename(artifact_inventory.proof_pack_output_path, root, artifact_inventory.proof_pack_prev_path, io) catch {
            rollbackPair(io, root, &state, options) catch |err| return err;
            return error.PreserveJsonFailed;
        };
        state.json_preserved = true;
    }
    if (options.test_fail_preserve_after) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.PreserveAfterFailed;
    }

    // 4. Install the new `index.html` first. The fault injection fires after
    // the rename (which may have completed), so recovery must remove a newly
    // installed HTML whose prior state was absent or restore a preserved one.
    root.rename(artifact_inventory.proof_index_tmp_path, root, artifact_inventory.proof_index_output_path, io) catch {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallHtmlFailed;
    };
    state.html_installed = true;
    if (options.test_fail_install_html) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallHtmlFailed;
    }

    // 5. Install the authoritative `proof-pack.json` last (commit point).
    root.rename(artifact_inventory.proof_pack_tmp_path, root, artifact_inventory.proof_pack_output_path, io) catch {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallJsonFailed;
    };
    state.json_installed = true;
    if (options.test_fail_install_json) {
        rollbackPair(io, root, &state, options) catch |err| return err;
        return error.InstallJsonFailed;
    }

    // 6. Delete the `.prev` siblings after full success. They are removed
    // unconditionally (not only when this run preserved a prior pair): a
    // previous failed run can leave durable `.prev` files behind when its own
    // restoration failed, and `.prev` files must never survive a successful
    // generation.
    root.deleteFile(io, artifact_inventory.proof_index_prev_path) catch {};
    root.deleteFile(io, artifact_inventory.proof_pack_prev_path) catch {};
}

/// Restore the exact original pair state. For each member: when the original
/// file existed (and was preserved), rename its `.prev` file back into place;
/// when the original file did not exist, remove any newly installed current
/// file so nothing is left where nothing was before. The specific restore or
/// remove error is returned on failure so the caller can report the pair as
/// possibly split or absent.
fn rollbackPair(
    io: Io,
    root: Io.Dir,
    state: *const PairState,
    options: Options,
) Error!void {
    if (state.html_preserved) {
        if (options.test_fail_restore_html) return error.RestoreHtmlFailed;
        root.rename(artifact_inventory.proof_index_prev_path, root, artifact_inventory.proof_index_output_path, io) catch return error.RestoreHtmlFailed;
    } else if (state.html_installed) {
        // The original had no `index.html`; remove the newly installed file.
        if (options.test_fail_remove_html) return error.RemoveHtmlFailed;
        root.deleteFile(io, artifact_inventory.proof_index_output_path) catch return error.RemoveHtmlFailed;
    }
    if (state.json_preserved) {
        if (options.test_fail_restore_json) return error.RestoreJsonFailed;
        root.rename(artifact_inventory.proof_pack_prev_path, root, artifact_inventory.proof_pack_output_path, io) catch return error.RestoreJsonFailed;
    } else if (state.json_installed) {
        // The original had no `proof-pack.json`; remove the newly installed file.
        if (options.test_fail_remove_json) return error.RemoveJsonFailed;
        root.deleteFile(io, artifact_inventory.proof_pack_output_path) catch return error.RemoveJsonFailed;
    }
}

// ---------------------------------------------------------------------------
// Module tests: determinism, canonical structure, HTML/JSON parity, escaping,
// the staged transaction with fault injection, the open-handle seam, and
// resource correctness under std.testing.allocator and failing-allocator
// sweeps. Fixtures reuse the touches module's shared in-memory evidence
// builders so every spec is byte-consistent across all four reports.
// ---------------------------------------------------------------------------

const ProofOutput = struct {
    json: []u8,
    html: []u8,

    fn deinit(self: *ProofOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.json);
        gpa.free(self.html);
    }
};

fn runProofPack(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    prefix: []const u8,
    target: []const u8,
    records: []const artifact_inventory.Record,
    spec: publication_touches.TestFixtureSpec,
    options: Options,
) !ProofOutput {
    try publication_touches.prepareTarget(io, gpa, root, prefix, records, spec);
    var dir = try publication_touches.openSubdir(io, root, prefix);
    defer dir.close(io);
    try publication_touches.writeAfterClaims(io, gpa, dir, target, .{});
    try writeAfterTouches(io, gpa, dir, target, options);
    const json = try readFileAlloc(io, dir, gpa, output_path);
    errdefer gpa.free(json);
    const html = try readFileAlloc(io, dir, gpa, index_output_path);
    return .{ .json = json, .html = html };
}

fn cleanRecords() [2]artifact_inventory.Record {
    return .{
        publication_touches.recordFor("index.html", .html_page, "<main></main>"),
        publication_touches.recordFor("_boris/search/search-index.json", .rendered_search, "{}"),
    };
}

fn cleanSpec() publication_touches.TestFixtureSpec {
    return .{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{} },
            .{ .subject_kinds = &.{"html-page"} },
            .{ .subject_kinds = &.{"rendered-search"}, .supporting_kinds = &.{"html-page"} },
        },
    };
}

fn failedRecords() [3]artifact_inventory.Record {
    return .{
        publication_touches.recordFor("index.html", .html_page, "<main></main>"),
        publication_touches.recordFor("broken.html", .html_page, "<main"),
        publication_touches.recordFor("_boris/search/search-index.json", .rendered_search, "{}"),
    };
}

fn failedSpec() publication_touches.TestFixtureSpec {
    return .{
        .artifact_count = 3,
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
}

fn incompleteSpec() publication_touches.TestFixtureSpec {
    return .{
        .artifact_count = 2,
        .checks = .{
            .{ .subject_kinds = &.{}, .status = "incomplete", .coverage = "incomplete", .checked = 1, .findings = &.{
                .{ .code = "ARTIFACT_MISSING", .subject_id = "missing.html" },
            } },
            .{ .subject_kinds = &.{"html-page"}, .status = "incomplete", .coverage = "incomplete", .checked = 1, .findings = &.{
                .{ .code = "HTML_PAGE_MISSING", .subject_kind = "html-page", .subject_id = "missing.html" },
            } },
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
}

fn notApplicableSpec() publication_touches.TestFixtureSpec {
    // Only the rendered-search check may be not-applicable; the checks
    // contract requires artifact-integrity and rendered-html to always be
    // eligible and run. So the search-not-applicable fixture passes the
    // first two checks and leaves the search check unselected.
    return .{
        .artifact_count = 1,
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
}

test "clean fixture derives the canonical verified Proof Pack" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Identity.
    try std.testing.expectEqualStrings(report_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("default", root.get("target").?.string);

    // Canonical root member order.
    const expected_order = [_][]const u8{
        "format", "schema_version", "target", "inputs",      "summary",       "artifacts",
        "checks", "findings",       "claims", "limitations", "relationships", "presentation",
    };
    var iterator = root.iterator();
    var order_index: usize = 0;
    while (iterator.next()) |entry| {
        try std.testing.expect(order_index < expected_order.len);
        try std.testing.expectEqualStrings(expected_order[order_index], entry.key_ptr.*);
        order_index += 1;
    }
    try std.testing.expectEqual(expected_order.len, order_index);

    // Inputs bind every committed evidence report.
    const inputs = root.get("inputs").?.object;
    try std.testing.expect(inputs.get("artifacts") != null);
    try std.testing.expect(inputs.get("checks") != null);
    try std.testing.expect(inputs.get("claims") != null);
    try std.testing.expect(inputs.get("touches") != null);

    // Fixed rows: 2 artifacts, 3 checks, 0 findings, 3 claims, 6 limitations.
    try std.testing.expectEqual(@as(usize, 2), root.get("artifacts").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("checks").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), root.get("findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("claims").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 6), root.get("limitations").?.array.items.len);

    // Relationships: exact node order and the six canonical edge groups.
    const relationships = root.get("relationships").?.object;
    const node_ids = relationships.get("node_ids").?.array.items;
    try std.testing.expectEqualStrings("target", node_ids[0].string);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 0 + 3 + 6), node_ids.len);
    const groups = relationships.get("groups").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), groups.len);
    const group_kinds = [_][]const u8{
        "target-owns-artifact",
        "artifact-subject-of-check",
        "artifact-supports-check",
        "check-reported-finding",
        "check-supports-claim",
        "claim-limited-by",
    };
    for (groups, 0..) |group, index| {
        try std.testing.expectEqualStrings(group_kinds[index], group.object.get("edge_kind").?.string);
    }

    // Summary and presentation agree exactly with the model's status.
    try std.testing.expectEqualStrings(
        "verified",
        root.get("presentation").?.object.get("overall_status").?.string,
    );
    try std.testing.expectEqualStrings(
        "verified",
        root.get("summary").?.object.get("overall_presentation_status").?.string,
    );
}

test "failed, incomplete, and not-applicable fixtures derive their exact statuses" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const records = failedRecords();
        var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, failedSpec(), .{});
        defer out.deinit(gpa);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings("attention-required", root.get("presentation").?.object.get("overall_status").?.string);
        const findings = root.get("findings").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), findings.len);
        for (findings) |finding| {
            try std.testing.expectEqualStrings("error", finding.object.get("severity").?.string);
        }
        try std.testing.expectEqualStrings(
            "attention-required",
            root.get("summary").?.object.get("overall_presentation_status").?.string,
        );
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const records = [_]artifact_inventory.Record{
            publication_touches.recordFor("index.html", .html_page, "<main></main>"),
            publication_touches.recordFor("missing.html", .html_page, "missing"),
        };
        var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, incompleteSpec(), .{});
        defer out.deinit(gpa);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings("incomplete", root.get("presentation").?.object.get("overall_status").?.string);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const records = [_]artifact_inventory.Record{
            publication_touches.recordFor("index.html", .html_page, "<main></main>"),
        };
        var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, notApplicableSpec(), .{});
        defer out.deinit(gpa);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        // A not-applicable search check still produces a `not-verified` claim,
        // so the contract's ordered rule set resolves to `attention-required`
        // (rule 3). The `not-applicable` overall status is unreachable under
        // the fixed v1 registry because artifact-integrity and rendered-html
        // are always applicable; rule 1 is pinned directly by the synthetic
        // all-NA unit test below.
        try std.testing.expectEqualStrings("attention-required", root.get("presentation").?.object.get("overall_status").?.string);
    }
}

test "deriveOverallStatus rule 1: all not-applicable checks yield not-applicable" {
    // The v1 check registry can never produce an all-not-applicable check set
    // in practice, so this direct unit test pins the contract's summary rule 1
    // with synthetic values. `deriveOverallStatus` reads only check and claim
    // statuses, so the remaining struct fields are zeroed.
    var checks = [3]publication_touches.ParsedCheck{
        std.mem.zeroes(publication_touches.ParsedCheck),
        std.mem.zeroes(publication_touches.ParsedCheck),
        std.mem.zeroes(publication_touches.ParsedCheck),
    };
    checks[0].status = "not-applicable";
    checks[1].status = "not-applicable";
    checks[2].status = "not-applicable";
    var claims = [3]publication_touches.ParsedClaim{
        std.mem.zeroes(publication_touches.ParsedClaim),
        std.mem.zeroes(publication_touches.ParsedClaim),
        std.mem.zeroes(publication_touches.ParsedClaim),
    };
    try std.testing.expectEqualStrings("not-applicable", deriveOverallStatus(&checks, &claims));

    // Once a single check is not not-applicable, rule 1 no longer applies; a
    // not-verified claim then resolves to attention-required (rule 3), never
    // back to not-applicable.
    checks[1].status = "passed";
    claims[0].status = "not-verified";
    try std.testing.expectEqualStrings("attention-required", deriveOverallStatus(&checks, &claims));
}

test "repeated generation emits byte-identical JSON and HTML" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var first = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer first.deinit(gpa);
    var second = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer second.deinit(gpa);
    try std.testing.expectEqualSlices(u8, first.json, second.json);
    try std.testing.expectEqualSlices(u8, first.html, second.html);
}

test "HTML embeds the exact JSON digest and mirrors model facts" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    // The embedded digest is the SHA-256 of the exact committed JSON bytes.
    const needle = "<meta name=\"proof-pack-sha256\" content=\"";
    const at = std.mem.indexOf(u8, out.html, needle) orelse return error.MissingDigest;
    const hex_start = at + needle.len;
    try std.testing.expect(hex_start + 64 <= out.html.len);
    const embedded = out.html[hex_start .. hex_start + 64];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.json, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualSlices(u8, &expected, embedded);

    // Every copied fact renders: target, status, input bindings, and rows.
    try std.testing.expect(std.mem.indexOf(u8, out.html, "default") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "verified") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "_boris/proof/artifacts.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "_boris/proof/touches.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "check:rendered-html") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "claim:rendered-html-passed-declared-audit") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.html, "limitation:target-local-only") != null);
}

// Strengthened HTML parity: assert both the required facts AND the absence of
// unsupported statements for clean, failed, incomplete, and
// search-not-applicable models. The explanation paragraphs must be derived
// from the exact evidence, never invented.
test "HTML explanation paragraphs are derived from evidence and never invent states" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const ModelCase = struct {
        name: []const u8,
        records: []const artifact_inventory.Record,
        spec: publication_touches.TestFixtureSpec,
        required: []const []const u8,
        forbidden: []const []const u8,
    };
    const cases = [_]ModelCase{
        .{
            .name = "clean",
            .records = &cleanRecords(),
            .spec = cleanSpec(),
            .required = &.{ "Overall presentation status: verified", "No edges are present in this relationship group." },
            // A verified model must never claim a check failed or that a
            // claim is unsupported.
            .forbidden = &.{ "At least one check failed", "At least one claim is not supported", "could not be verified", "requires attention" },
        },
        .{
            .name = "failed",
            .records = &failedRecords(),
            .spec = failedSpec(),
            .required = &.{
                "Overall presentation status: attention-required",
                "At least one check failed",
                "At least one claim is not supported",
            },
            .forbidden = &.{"requires attention before"},
        },
        .{
            .name = "incomplete",
            .records = &cleanRecords(),
            .spec = incompleteSpec(),
            .required = &.{
                "Overall presentation status: incomplete",
                "At least one check is incomplete",
                "No edges are present in this relationship group.",
            },
            .forbidden = &.{ "At least one check failed", "could not be verified" },
        },
        .{
            .name = "search-not-applicable",
            .records = &[_]artifact_inventory.Record{publication_touches.recordFor("index.html", .html_page, "<main></main>")},
            .spec = notApplicableSpec(),
            .required = &.{
                "Overall presentation status: attention-required",
                "A claim could not be verified because the rendered-search check is not-applicable for this target",
                "No edges are present in this relationship group.",
            },
            // Zero findings: the reader must never be told to review findings.
            .forbidden = &.{ "review the findings below", "At least one check failed", "At least one claim is not supported" },
        },
    };

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var out = try runProofPack(io, gpa, tmp.dir, "target", "default", case.records, case.spec, .{});
        defer out.deinit(gpa);
        for (case.required) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, out.html, needle) != null);
        }
        for (case.forbidden) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, out.html, needle) == null);
        }
    }
}

// ---------------------------------------------------------------------------
// HTML presentation regression tests: stable anchors, reading order, details
// usage, edge-kind explanations, print disclosure, and self-contained output.
// The JSON model bytes are pinned separately by the fixture golden; these
// tests pin the presentation layer over identical models.
// ---------------------------------------------------------------------------

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return count;
}

/// The canonical HTML section/navigation reading order.
const html_reading_order = [_][]const u8{
    "summary", "claims", "limitations", "findings", "checks", "artifacts", "relationships", "inputs",
};

/// Slice one `<section id="X">` block (up to the next `<section id=`), or
/// the whole document when X is the last section.
fn htmlSectionSlice(html: []const u8, anchor: []const u8) ![]const u8 {
    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "<section id=\"{s}\">", .{anchor});
    const start = std.mem.indexOf(u8, html, marker) orelse return error.MissingSection;
    const content_start = start + marker.len;
    const next = std.mem.indexOf(u8, html[content_start..], "<section id=\"") orelse
        return html[content_start..];
    return html[content_start .. content_start + next];
}

/// Assert `needle` appears in `html` after the same escaping the renderer
/// applies to text (so apostrophes, quotes, and angle brackets match the
/// emitted bytes, not the raw value).
fn expectHtmlContains(gpa: std.mem.Allocator, html: []const u8, needle: []const u8) !void {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    try escapeHtml(&escaped, gpa, needle);
    try std.testing.expect(std.mem.indexOf(u8, html, escaped.items) != null);
}

test "HTML keeps every stable anchor and navigation links match the reading order" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    // Every stable anchor appears exactly once as a <section id="...">.
    for (html_reading_order) |anchor| {
        var marker_buf: [64]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "<section id=\"{s}\">", .{anchor});
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(out.html, marker));
    }

    // The navigation block lists every anchor href in reading order.
    const nav_start = std.mem.indexOf(u8, out.html, "<nav") orelse return error.MissingNav;
    const nav_end = std.mem.indexOfPos(u8, out.html, nav_start, "</nav>") orelse return error.MissingNavEnd;
    const nav = out.html[nav_start..nav_end];
    var nav_pos: usize = 0;
    for (html_reading_order) |anchor| {
        var href_buf: [64]u8 = undefined;
        const href = try std.fmt.bufPrint(&href_buf, "href=\"#{s}\"", .{anchor});
        const at = std.mem.indexOfPos(u8, nav, nav_pos, href) orelse return error.MissingNavLink;
        try std.testing.expect(at >= nav_pos);
        nav_pos = at + href.len;
    }

    // Section order inside <main> matches the reading order.
    const main_start = std.mem.indexOf(u8, out.html, "<main>") orelse return error.MissingMain;
    var section_pos: usize = main_start;
    for (html_reading_order) |anchor| {
        var marker_buf: [64]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "<section id=\"{s}\">", .{anchor});
        const at = std.mem.indexOfPos(u8, out.html, section_pos, marker) orelse return error.MissingSection;
        try std.testing.expect(at >= section_pos);
        section_pos = at + marker.len;
    }
}

test "claims, limitations, findings, checks, summary, and inputs stay visible; artifacts and relationships use details only as intended" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    // Sections that must never be wrapped in <details>.
    const always_visible = [_][]const u8{ "summary", "claims", "limitations", "findings", "checks", "inputs" };
    for (always_visible) |anchor| {
        const section = try htmlSectionSlice(out.html, anchor);
        try std.testing.expect(std.mem.indexOf(u8, section, "<details") == null);
    }

    // Artifacts: exactly one <details> (the inventory) with an exact-count
    // summary label.
    const artifacts = try htmlSectionSlice(out.html, "artifacts");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(artifacts, "<details>"));
    var artifact_buf: [64]u8 = undefined;
    const artifact_summary = try std.fmt.bufPrint(&artifact_buf, "Artifact inventory ({d} records)", .{records.len});
    try std.testing.expect(std.mem.indexOf(u8, artifacts, artifact_summary) != null);

    // Relationships: one nodes <details> plus six edge-group <details>.
    const relationships = try htmlSectionSlice(out.html, "relationships");
    try std.testing.expectEqual(@as(usize, 7), countOccurrences(relationships, "<details>"));
    var nodes_buf: [64]u8 = undefined;
    const nodes_summary = try std.fmt.bufPrint(
        &nodes_buf,
        "Relationship nodes ({d})",
        .{1 + records.len + 3 + 0 + 3 + 6},
    );
    try std.testing.expect(std.mem.indexOf(u8, relationships, nodes_summary) != null);
}

test "all six exact edge-kind strings and their explanations remain present" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    const kinds = [_][]const u8{
        "target-owns-artifact",
        "artifact-subject-of-check",
        "artifact-supports-check",
        "check-reported-finding",
        "check-supports-claim",
        "claim-limited-by",
    };
    const explanations = [_][]const u8{
        "The target includes this artifact inventory record.",
        "The artifact is part of the check's declared subject scope.",
        "The artifact is supporting evidence used by the check.",
        "The finding was reported by this check.",
        "The claim is bound to evidence from this check. This does not imply the check passed.",
        "The limitation restricts the scope of this claim.",
    };
    for (kinds) |kind| {
        try std.testing.expect(std.mem.indexOf(u8, out.html, kind) != null);
    }
    for (explanations) |explanation| {
        try expectHtmlContains(gpa, out.html, explanation);
    }
}

test "every node, edge, and artifact renders exactly once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const rel = root.get("relationships").?.object;
    const node_ids = rel.get("node_ids").?.array.items;
    const groups = rel.get("groups").?.array.items;
    const rel_section = try htmlSectionSlice(out.html, "relationships");

    // Nodes: every node id renders exactly once inside the nodes list.
    const nodes_block_start = std.mem.indexOf(u8, rel_section, "<summary>Relationship nodes (") orelse
        return error.MissingNodesBlock;
    const nodes_block = rel_section[nodes_block_start..];
    const nodes_end = std.mem.indexOf(u8, nodes_block, "</details>") orelse return error.MissingNodesEnd;
    const nodes_list = nodes_block[0..nodes_end];
    for (node_ids) |node| {
        var buf: [256]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "<li>{s}</li>", .{node.string});
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(nodes_list, needle));
    }

    // Edges: every edge tuple renders exactly once inside its group, and the
    // summary label carries the exact edge count.
    for (groups) |group| {
        const kind = group.object.get("edge_kind").?.string;
        const edges = group.object.get("edges").?.array.items;
        var summary_buf: [96]u8 = undefined;
        const summary = try std.fmt.bufPrint(&summary_buf, "<summary>{s} ({d} edges)</summary>", .{ kind, edges.len });
        const group_start = std.mem.indexOf(u8, rel_section, summary) orelse return error.MissingGroup;
        const group_block = rel_section[group_start..];
        const group_end = std.mem.indexOf(u8, group_block, "</details>") orelse return error.MissingGroupEnd;
        const group_slice = group_block[0..group_end];
        try std.testing.expectEqual(edges.len, countOccurrences(group_slice, "<li>"));
        for (edges) |edge| {
            const from = edge.object.get("from").?.string;
            const to = edge.object.get("to").?.string;
            var buf: [512]u8 = undefined;
            const needle = try std.fmt.bufPrint(&buf, "<li>{s} → {s}</li>", .{ from, to });
            try std.testing.expectEqual(@as(usize, 1), countOccurrences(group_slice, needle));
        }
    }

    // Artifacts: every artifact path renders exactly once in the inventory.
    const artifacts_section = try htmlSectionSlice(out.html, "artifacts");
    for (root.get("artifacts").?.array.items) |row| {
        const path = row.object.get("path").?.string;
        var buf: [512]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "<code>{s}</code>", .{path});
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(artifacts_section, needle));
    }
}

test "claim, limitation, finding, check, artifact, node, and edge totals are unchanged and mirrored in HTML" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const rel = root.get("relationships").?.object;

    // JSON totals stay fixed for the clean fixture.
    try std.testing.expectEqual(@as(usize, 2), root.get("artifacts").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("checks").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), root.get("findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("claims").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 6), root.get("limitations").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 0 + 3 + 6), rel.get("node_ids").?.array.items.len);

    // The summary section mirrors the same totals in HTML.
    const summary_section = try htmlSectionSlice(out.html, "summary");
    try std.testing.expect(std.mem.indexOf(u8, summary_section, "Checks</th><td>3 total") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_section, "Claims</th><td>3 total") != null);
}

test "exact claim statements, statuses, evidence bindings, and claim-to-limitation relationships are unchanged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const claims = root.get("claims").?.array.items;
    const claims_section = try htmlSectionSlice(out.html, "claims");
    for (claims, 0..) |claim, index| {
        // Exact statements and statuses remain unchanged and render verbatim.
        const statement = claim.object.get("statement").?.string;
        try std.testing.expectEqualStrings(publication_claims.claim_statements[index], statement);
        try expectHtmlContains(gpa, claims_section, statement);
        const status = claim.object.get("status").?.string;
        try std.testing.expectEqualStrings("verified", status);
        try expectHtmlContains(gpa, claims_section, status);
        // Evidence binding unchanged and rendered.
        const evidence_check = claim.object.get("evidence_check_id").?.string;
        try std.testing.expectEqualStrings(publication_touches.check_ids[index], evidence_check);
        try std.testing.expect(std.mem.indexOf(u8, claims_section, evidence_check) != null);
        // Claim-to-limitation relationships unchanged (canonical row shape).
        const limitation_ids = claim.object.get("limitation_ids").?.array.items;
        const expected = if (index == 2)
            publication_claims.limitation_ids[0..]
        else
            publication_claims.limitation_ids[0..5];
        try std.testing.expectEqual(expected.len, limitation_ids.len);
        for (limitation_ids, expected) |actual, want| {
            try std.testing.expectEqualStrings(want, actual.string);
        }
    }

    // Input evidence bindings render their exact paths and digests.
    const inputs_section = try htmlSectionSlice(out.html, "inputs");
    const inputs = root.get("inputs").?.object;
    var input_iterator = inputs.iterator();
    while (input_iterator.next()) |entry| {
        const path = entry.value_ptr.object.get("path").?.string;
        try std.testing.expect(std.mem.indexOf(u8, inputs_section, path) != null);
        const sha = entry.value_ptr.object.get("sha256").?.string;
        try std.testing.expect(std.mem.indexOf(u8, inputs_section, sha) != null);
    }
}

test "HTML contains no scripts or remote resources and is valid UTF-8" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    const forbidden = [_][]const u8{
        "<script",
        "http://",
        "https://",
        "@import",
        "url(",
        "<img",
        "src=",
        "onerror",
        "onload",
    };
    for (forbidden) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, out.html, needle) == null);
    }
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.html));
}

test "print rules expose the content of closed details elements" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);

    const style_start = std.mem.indexOf(u8, out.html, "<style>") orelse return error.MissingStyle;
    const style_end = std.mem.indexOf(u8, out.html, "</style>") orelse return error.MissingStyleEnd;
    const css = out.html[style_start .. style_end + "</style>".len];
    const print_at = std.mem.indexOf(u8, css, "@media print") orelse return error.MissingPrintRule;
    const print_css = css[print_at..];
    // The print block must force every non-summary direct child of a details
    // element to display so collapsed content prints. A bare
    // `details { display: block }` rule alone would not expose the interior.
    // The `details::details-content` pseudo-element must also be explicitly
    // forced to visible because some browsers' UA stylesheets hide the
    // disclosure content container via `content-visibility: hidden`.
    try std.testing.expect(std.mem.indexOf(u8, print_css, "details::details-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "content-visibility: visible !important") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "details > :not(summary)") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "display: block !important") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "nav { display: none; }") != null);
    // Wide tables scroll on screen but must not clip in print.
    try std.testing.expect(std.mem.indexOf(u8, print_css, ".table-wrap { overflow: visible; }") != null);
}

test "hostile values are escaped in HTML text and attributes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Unit-level: every hostile byte escapes in both contexts.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try escapeHtml(&out, gpa, "&<>\"'");
        try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;&#39;", out.items);
    }

    // End-to-end: a hostile finding code and artifact path never leak raw.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const records = [_]artifact_inventory.Record{
            publication_touches.recordFor("index.html", .html_page, "<main></main>"),
            publication_touches.recordFor("a&b\"c<d>'e.html", .html_page, "<main"),
        };
        // Finding codes are a CLOSED registry, so the hostile bytes ride in
        // the artifact path and finding subject id instead; the code itself
        // must be a known registry member.
        const spec = publication_touches.TestFixtureSpec{
            .artifact_count = 2,
            .checks = .{
                .{ .subject_kinds = &.{}, .status = "failed", .findings = &.{
                    .{ .code = "ARTIFACT_DIGEST_MISMATCH", .severity = "error", .subject_kind = "artifact", .subject_id = "a&b\"c<d>'e.html" },
                } },
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
        var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, spec, .{});
        defer out.deinit(gpa);
        // The hostile path escapes in text and attribute contexts everywhere
        // it renders (artifact row, finding subject, relationship nodes and
        // edges); no raw hostile bytes or injected markup survive.
        try std.testing.expect(std.mem.indexOf(u8, out.html, "a&amp;b&quot;c&lt;d&gt;&#39;e.html") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.html, "<script>") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.html, "a&b\"c<d>'e.html") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.html, "X&<>") == null);
    }
}

test "transaction fault injection preserves the prior pair at every phase" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer prior.deinit(gpa);

    var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
    defer dir.close(io);

    // Failures before installation leave the prior pair untouched.
    const pre_install_cases = [_]struct { options: Options, err: anyerror }{
        .{ .options = .{ .test_fail_execution = true }, .err = error.InvalidTouchesReport },
        .{ .options = .{ .test_fail_json_tmp_write = true }, .err = error.JsonTmpWriteFailed },
        .{ .options = .{ .test_fail_html_tmp_write = true }, .err = error.HtmlTmpWriteFailed },
        .{ .options = .{ .test_fail_preserve_prior = true }, .err = error.PreservePriorFailed },
    };
    for (pre_install_cases) |case| {
        try std.testing.expectError(case.err, writeAfterTouches(io, gpa, dir, "default", case.options));
        const json = try readFileAlloc(io, dir, gpa, output_path);
        defer gpa.free(json);
        const html = try readFileAlloc(io, dir, gpa, index_output_path);
        defer gpa.free(html);
        try std.testing.expectEqualSlices(u8, prior.json, json);
        try std.testing.expectEqualSlices(u8, prior.html, html);
    }

    // Failures after an install restore the prior pair when recovery succeeds.
    const post_install_cases = [_]struct { options: Options, err: anyerror }{
        .{ .options = .{ .test_fail_install_html = true }, .err = error.InstallHtmlFailed },
        .{ .options = .{ .test_fail_install_json = true }, .err = error.InstallJsonFailed },
    };
    for (post_install_cases) |case| {
        try std.testing.expectError(case.err, writeAfterTouches(io, gpa, dir, "default", case.options));
        const json = try readFileAlloc(io, dir, gpa, output_path);
        defer gpa.free(json);
        const html = try readFileAlloc(io, dir, gpa, index_output_path);
        defer gpa.free(html);
        try std.testing.expectEqualSlices(u8, prior.json, json);
        try std.testing.expectEqualSlices(u8, prior.html, html);
    }

    // A recovery failure surfaces the restore error (so the compile layer can
    // print the contract's "recovery failed; the pair may be split or absent"
    // diagnostic) and leaves durable `.prev` evidence where possible.
    try std.testing.expectError(
        error.RestoreHtmlFailed,
        writeAfterTouches(io, gpa, dir, "default", .{ .test_fail_install_html = true, .test_fail_restore_html = true }),
    );
    try std.testing.expect(pathExists(io, dir, artifact_inventory.proof_index_prev_path));
    try std.testing.expect(pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
    // The prior run already left both outputs absent (its restoration failed),
    // so this run preserves nothing: the install-json fault surfaces directly
    // and the durable `.prev` evidence from the failed restoration remains.
    try std.testing.expectError(
        error.InstallJsonFailed,
        writeAfterTouches(io, gpa, dir, "default", .{ .test_fail_install_json = true, .test_fail_restore_json = true }),
    );
    try std.testing.expect(pathExists(io, dir, artifact_inventory.proof_pack_prev_path));

    // A clean re-run restores a matching digest pair and deletes the leftovers.
    var after = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer after.deinit(gpa);
    try std.testing.expectEqualSlices(u8, prior.json, after.json);
    try std.testing.expectEqualSlices(u8, prior.html, after.html);
    try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_index_prev_path));
    try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
}

/// Exact original-state capture for the transaction state matrix: the
/// committed existence and bytes of both pair paths at a moment in time.
const CapturedPairState = struct {
    json_exists: bool,
    html_exists: bool,
    json_bytes: []u8,
    html_bytes: []u8,

    fn capture(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) !CapturedPairState {
        return .{
            .json_exists = pathExists(io, dir, output_path),
            .html_exists = pathExists(io, dir, index_output_path),
            .json_bytes = if (pathExists(io, dir, output_path)) try readFileAlloc(io, dir, gpa, output_path) else &.{},
            .html_bytes = if (pathExists(io, dir, index_output_path)) try readFileAlloc(io, dir, gpa, index_output_path) else &.{},
        };
    }

    fn deinit(self: *CapturedPairState, gpa: std.mem.Allocator) void {
        if (self.json_exists) gpa.free(self.json_bytes);
        if (self.html_exists) gpa.free(self.html_bytes);
    }

    /// Assert the pair currently matches this captured state exactly: the
    /// same existence for both paths and the same bytes for every file that
    /// existed. A file that was absent must be absent again.
    fn expectEqual(self: *const CapturedPairState, io: Io, gpa: std.mem.Allocator, dir: Io.Dir) !void {
        try std.testing.expectEqual(self.json_exists, pathExists(io, dir, output_path));
        try std.testing.expectEqual(self.html_exists, pathExists(io, dir, index_output_path));
        if (self.json_exists) {
            const after = try readFileAlloc(io, dir, gpa, output_path);
            defer gpa.free(after);
            try std.testing.expectEqualSlices(u8, self.json_bytes, after);
        }
        if (self.html_exists) {
            const after = try readFileAlloc(io, dir, gpa, index_output_path);
            defer gpa.free(after);
            try std.testing.expectEqualSlices(u8, self.html_bytes, after);
        }
    }
};

// Every handled transaction failure with a successful rollback, over every
// initial pair state (neither, only JSON, only HTML, both): the rollback
// must restore the exact original existence and bytes of both paths and
// leave no `.prev` files behind.
test "transaction state matrix: every handled failure restores the exact original pair state" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = cleanRecords();
    const spec = cleanSpec();

    const HandledCase = struct { options: Options, err: anyerror };
    const handled = [_]HandledCase{
        .{ .options = .{ .test_fail_preserve_json = true }, .err = error.PreserveJsonFailed },
        .{ .options = .{ .test_fail_preserve_after = true }, .err = error.PreserveAfterFailed },
        .{ .options = .{ .test_fail_install_html = true }, .err = error.InstallHtmlFailed },
        .{ .options = .{ .test_fail_install_json = true }, .err = error.InstallJsonFailed },
    };
    const states = [_]struct { json: bool, html: bool }{
        .{ .json = false, .html = false },
        .{ .json = true, .html = false },
        .{ .json = false, .html = true },
        .{ .json = true, .html = true },
    };

    for (handled) |case| {
        for (states) |state| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, spec, .{});
            defer prior.deinit(gpa);
            var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
            defer dir.close(io);
            // Shape the initial state from the fresh committed pair.
            if (!state.json) dir.deleteFile(io, output_path) catch {};
            if (!state.html) dir.deleteFile(io, index_output_path) catch {};
            var original = try CapturedPairState.capture(io, gpa, dir);
            defer original.deinit(gpa);
            try std.testing.expectEqual(state.json, original.json_exists);
            try std.testing.expectEqual(state.html, original.html_exists);

            try std.testing.expectError(case.err, writeAfterTouches(io, gpa, dir, "default", case.options));
            try original.expectEqual(io, gpa, dir);
            // A successful rollback must not leave durable `.prev` files.
            try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_index_prev_path));
            try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
        }
    }
}

// A rollback failure surfaces its specific recovery error (so the compile
// layer prints the "pair may be split or absent" diagnostic) and keeps
// durable `.prev` evidence where the original file existed.
test "transaction rollback failures surface specific recovery errors and keep .prev evidence" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const records = cleanRecords();
    const spec = cleanSpec();

    // Restore failures need an originally-present file to restore.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, spec, .{});
        defer prior.deinit(gpa);
        var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        try std.testing.expectError(
            error.RestoreHtmlFailed,
            writeAfterTouches(io, gpa, dir, "default", .{ .test_fail_install_html = true, .test_fail_restore_html = true }),
        );
        try std.testing.expect(pathExists(io, dir, artifact_inventory.proof_index_prev_path));
        try std.testing.expect(pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, spec, .{});
        defer prior.deinit(gpa);
        var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        try std.testing.expectError(
            error.RestoreJsonFailed,
            writeAfterTouches(io, gpa, dir, "default", .{ .test_fail_install_json = true, .test_fail_restore_json = true }),
        );
        // HTML was restored first; the JSON restore failed, leaving the JSON
        // `.prev` durable.
        try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_index_prev_path));
        try std.testing.expect(pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
    }

    // Remove failures need a newly installed file whose prior state was
    // absent. Start from the neither state so both files are newly installed.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, spec, .{});
        defer prior.deinit(gpa);
        var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        dir.deleteFile(io, output_path) catch {};
        dir.deleteFile(io, index_output_path) catch {};
        try std.testing.expectError(
            error.RemoveHtmlFailed,
            writeAfterTouches(io, gpa, dir, "default", .{ .test_fail_install_html = true, .test_fail_remove_html = true }),
        );
        // No `.prev` to preserve: nothing originally existed.
        try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_index_prev_path));
        try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, spec, .{});
        defer prior.deinit(gpa);
        var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
        defer dir.close(io);
        dir.deleteFile(io, output_path) catch {};
        dir.deleteFile(io, index_output_path) catch {};
        try std.testing.expectError(
            error.RemoveJsonFailed,
            writeAfterTouches(io, gpa, dir, "default", .{ .test_fail_install_json = true, .test_fail_remove_json = true }),
        );
        try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_index_prev_path));
        try std.testing.expect(!pathExists(io, dir, artifact_inventory.proof_pack_prev_path));
    }
}

// The streaming temporary-file comparison detects every divergence mode
// (different bytes, truncation, extra trailing bytes, read failure) with no
// Proof Pack byte maximum and no second output-sized allocation.
test "streaming temporary verification detects mismatch, truncation, extension, and read failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = artifact_inventory.proof_pack_tmp_path;

    // Exact match passes.
    try writeTmpFile(io, tmp.dir, path, "hello world", error.JsonTmpWriteFailed);
    try verifyTmpBytes(io, tmp.dir, path, "hello world", error.JsonTmpWriteFailed);

    // Different bytes fail.
    try writeTmpFile(io, tmp.dir, path, "hello world", error.JsonTmpWriteFailed);
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, "hello worle", error.JsonTmpWriteFailed),
    );

    // A truncated temporary file fails.
    try writeTmpFile(io, tmp.dir, path, "hello", error.JsonTmpWriteFailed);
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, "hello world", error.JsonTmpWriteFailed),
    );

    // Extra trailing bytes fail.
    try writeTmpFile(io, tmp.dir, path, "hello world extra", error.JsonTmpWriteFailed);
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, "hello world", error.JsonTmpWriteFailed),
    );

    // A read failure (missing file) fails.
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, "hello world", error.JsonTmpWriteFailed),
    );
}

test "streaming temporary verification spans reader-buffer boundaries" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = artifact_inventory.proof_pack_tmp_path;

    // A payload crossing the 64 KiB reader-buffer boundary.
    const size: usize = 64 * 1024 + 1234;
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @intCast((i % 251) & 0xff);
    try writeTmpFile(io, tmp.dir, path, bytes, error.JsonTmpWriteFailed);
    try verifyTmpBytes(io, tmp.dir, path, bytes, error.JsonTmpWriteFailed);

    // An altered byte past the first chunk is still caught.
    const altered = try gpa.dupe(u8, bytes);
    defer gpa.free(altered);
    altered[size - 1] ^= 1;
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, altered, error.JsonTmpWriteFailed),
    );

    // A file shorter than the expected payload fails (truncation past a
    // chunk boundary).
    const longer = try gpa.alloc(u8, size + 512);
    defer gpa.free(longer);
    @memcpy(longer[0..size], bytes);
    @memset(longer[size..], 0x7f);
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, longer, error.JsonTmpWriteFailed),
    );

    // Extra trailing bytes beyond the expected length are caught: write the
    // extended file to disk and expect only the original payload.
    try writeTmpFile(io, tmp.dir, path, longer, error.JsonTmpWriteFailed);
    try std.testing.expectError(
        error.JsonTmpWriteFailed,
        verifyTmpBytes(io, tmp.dir, path, bytes, error.JsonTmpWriteFailed),
    );
}

/// File-scope seam helper (declared outside the test so the struct can
/// reference its own type): replaces the four evidence paths with garbage
/// after the handles are opened.
const TestPathReplacer = struct {
    io: Io,
    root: Io.Dir,

    fn run(context: ?*anyopaque) void {
        const self: *const TestPathReplacer = @ptrCast(@alignCast(context.?));
        replace(self, "target/_boris/proof/artifacts.json");
        replace(self, "target/_boris/proof/checks.json");
        replace(self, "target/_boris/proof/claims.json");
        replace(self, "target/_boris/proof/touches.json");
    }

    fn replace(self: *const TestPathReplacer, path: []const u8) void {
        self.root.deleteFile(self.io, path) catch {};
        self.root.writeFile(self.io, .{ .sub_path = path, .data = "replaced garbage" }) catch {};
    }
};

test "after-open seam: replaced evidence paths never affect the opened handles" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var control = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer control.deinit(gpa);

    // Replace all four evidence paths with garbage after the handles are
    // opened. A path-based implementation would fail loudly on re-open; the
    // single opened no-follow handle per input must be unaffected, so the
    // pack is byte-identical to the no-replacement run.
    const replacer = TestPathReplacer{ .io = io, .root = tmp.dir };
    var replaced = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{
        .after_open = TestPathReplacer.run,
        .after_open_context = @constCast(&replacer),
    });
    defer replaced.deinit(gpa);
    try std.testing.expectEqualSlices(u8, control.json, replaced.json);
    try std.testing.expectEqualSlices(u8, control.html, replaced.html);
}

test "stale and malformed evidence is rejected without replacing the prior pair" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer prior.deinit(gpa);

    var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
    defer dir.close(io);

    // A malformed touches report is rejected and the prior pair stays intact.
    try publication_touches.writePayload(io, dir, publication_touches.output_path, "{ not json");
    try std.testing.expectError(error.InvalidTouchesReport, writeAfterTouches(io, gpa, dir, "default", .{}));
    const json = try readFileAlloc(io, dir, gpa, output_path);
    defer gpa.free(json);
    const html = try readFileAlloc(io, dir, gpa, index_output_path);
    defer gpa.free(html);
    try std.testing.expectEqualSlices(u8, prior.json, json);
    try std.testing.expectEqualSlices(u8, prior.html, html);

    // A target mismatch is rejected without touching the pair. Artifacts are
    // parsed first, so the artifacts report's embedded target is the first
    // disagreement and the run fails with InvalidArtifactsReport before any
    // touches parsing begins.
    try std.testing.expectError(
        error.InvalidArtifactsReport,
        writeAfterTouches(io, gpa, dir, "other-target", .{}),
    );
    const json2 = try readFileAlloc(io, dir, gpa, output_path);
    defer gpa.free(json2);
    try std.testing.expectEqualSlices(u8, prior.json, json2);
}

// ---------------------------------------------------------------------------
// Permanent semantic-rejection negative controls at the Proof Pack layer.
// The touches-layer suite pins the shared parsers and graph validator; these
// pin the same rejections through `writeAfterTouches`, which re-opens and
// re-validates all four committed evidence reports before deriving the pair.
// Every case keeps the tampered file well-formed (or repairs the downstream
// embedded bindings) so the rejection must come from semantic validation,
// never merely from the first digest mismatch, and the prior pair must
// survive byte-for-byte.
// ---------------------------------------------------------------------------

/// Replace every occurrence of `find` in one committed evidence report with
/// `replace` and write the result back under the same path. The needle must
/// exist, so a fixture-format drift fails the test loudly instead of silently
/// weakening the control.
fn replaceEvidenceBytes(
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    path: []const u8,
    find: []const u8,
    replace: []const u8,
) !void {
    const original = try publication_touches.readPayload(io, dir, gpa, path);
    defer gpa.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, find) != null);
    const mutated = try std.mem.replaceOwned(u8, gpa, original, find, replace);
    defer gpa.free(mutated);
    try publication_touches.writePayload(io, dir, path, mutated);
}

/// Derive a healthy target with its prior pair, apply one byte-level tamper
/// to the committed evidence, and prove `writeAfterTouches` rejects with
/// exactly `expected` while the prior pair stays byte-identical.
fn expectEvidenceTamperRejected(
    io: Io,
    gpa: std.mem.Allocator,
    records: []const artifact_inventory.Record,
    spec: publication_touches.TestFixtureSpec,
    tamper: anytype,
    expected: anyerror,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var prior = try runProofPack(io, gpa, tmp.dir, "target", "default", records, spec, .{});
    defer prior.deinit(gpa);
    var dir = try publication_touches.openSubdir(io, tmp.dir, "target");
    defer dir.close(io);
    try tamper.run(io, gpa, dir);
    try std.testing.expectError(expected, writeAfterTouches(io, gpa, dir, "default", .{}));
    const json = try readFileAlloc(io, dir, gpa, output_path);
    defer gpa.free(json);
    const html = try readFileAlloc(io, dir, gpa, index_output_path);
    defer gpa.free(html);
    try std.testing.expectEqualSlices(u8, prior.json, json);
    try std.testing.expectEqualSlices(u8, prior.html, html);
}

test "proof pack layer rejects artifact, check, and claim semantic tampering" {
    const tio = std.testing.io;
    const tgpa = std.testing.allocator;
    const clean = cleanRecords();
    const clean_spec = cleanSpec();
    const failed = failedRecords();
    const failed_spec = failedSpec();

    // 1. artifacts.json content changed while the outer JSON stays valid: the
    // direct artifact binding no longer agrees with the embedded bindings.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                const original = try publication_touches.readPayload(io, dir, gpa, artifact_inventory.output_path);
                defer gpa.free(original);
                const mutated = try std.mem.concat(gpa, u8, &.{ original, "\n" });
                defer gpa.free(mutated);
                try publication_touches.writePayload(io, dir, artifact_inventory.output_path, mutated);
            }
        }, error.StaleArtifactsBinding);
    }

    // 2. checks.json status changed, with every downstream embedded checks
    // binding repaired so the digest checks pass: the semantic node-metadata
    // cross-check must reject, not a stale-binding check.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                const checks_path = publication_checks.output_path;
                const claims_path = publication_claims.output_path;
                const touches_path = publication_touches.output_path;
                const checks = try publication_touches.readPayload(io, dir, gpa, checks_path);
                defer gpa.free(checks);
                const old_checks_digest = cache.hexDigest(cache.hashBytes(checks));
                const mutated_checks = try std.mem.replaceOwned(u8, gpa, checks, "\"status\": \"passed\"", "\"status\": \"failed\"");
                defer gpa.free(mutated_checks);
                try publication_touches.writePayload(io, dir, checks_path, mutated_checks);
                const new_checks_digest = cache.hexDigest(cache.hashBytes(mutated_checks));

                // Repair the checks binding inside claims.json.
                const claims = try publication_touches.readPayload(io, dir, gpa, claims_path);
                defer gpa.free(claims);
                const old_claims_digest = cache.hexDigest(cache.hashBytes(claims));
                const repaired_claims = try std.mem.replaceOwned(u8, gpa, claims, &old_checks_digest, &new_checks_digest);
                defer gpa.free(repaired_claims);
                try publication_touches.writePayload(io, dir, claims_path, repaired_claims);
                const new_claims_digest = cache.hexDigest(cache.hashBytes(repaired_claims));

                // Repair both the checks and claims bindings inside touches.json.
                const touches = try publication_touches.readPayload(io, dir, gpa, touches_path);
                defer gpa.free(touches);
                const repaired_checks = try std.mem.replaceOwned(u8, gpa, touches, &old_checks_digest, &new_checks_digest);
                defer gpa.free(repaired_checks);
                const repaired_touches = try std.mem.replaceOwned(u8, gpa, repaired_checks, &old_claims_digest, &new_claims_digest);
                defer gpa.free(repaired_touches);
                try publication_touches.writePayload(io, dir, touches_path, repaired_touches);
            }
        }, error.InvalidTouchesReport);
    }

    // 3. checks.json finding ranges overlap: the contiguous-range chain check
    // must reject, not a stale-binding check.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &failed, failed_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_checks.output_path, "\"finding_offset\": 1", "\"finding_offset\": 0");
            }
        }, error.InvalidChecksReport);
    }

    // 4. claims.json claim-to-check binding rewired to another check: the
    // positional evidence cross-check must reject.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_claims.output_path, "\"check_id\": \"artifact-integrity\"", "\"check_id\": \"rendered-html\"");
            }
        }, error.InvalidClaimsReport);
    }

    // 5. claims.json limitation source changed: the fixed limitation registry
    // must reject.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_claims.output_path, "\"source\": \"docs/contracts/publication-checks.md#authority-and-transaction-boundary\"", "\"source\": \"wrong\"");
            }
        }, error.InvalidClaimsReport);
    }
}

test "proof pack layer rejects Touch Atlas graph and node semantic tampering" {
    const tio = std.testing.io;
    const tgpa = std.testing.allocator;
    const clean = cleanRecords();
    const clean_spec = cleanSpec();

    // 6. touches.json artifact node metadata changed without changing the
    // node ID: the strict metadata cross-check against the inventory rejects.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_touches.output_path, "\"status\": \"committed\",\n        \"required\": true", "\"status\": \"not-applicable\",\n        \"required\": true");
            }
        }, error.InvalidTouchesReport);
    }

    // 7. touches.json missing one edge: the canonical graph comparison rejects.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_touches.output_path, "    {\n      \"kind\": \"target-owns-artifact\",\n      \"from\": \"target\",\n      \"to\": \"artifact:_boris/search/search-index.json\"\n    },\n", "");
            }
        }, error.InvalidChecksReport);
    }

    // 8. touches.json extra edge (duplicate tuple): the graph validator
    // rejects duplicates and cardinality drift.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                const find = "    {\n      \"kind\": \"target-owns-artifact\",\n      \"from\": \"target\",\n      \"to\": \"artifact:_boris/search/search-index.json\"\n    }";
                try replaceEvidenceBytes(io, gpa, dir, publication_touches.output_path, find, find ++ ",\n" ++ find);
            }
        }, error.InvalidChecksReport);
    }

    // 9. touches.json edge endpoints swapped: the edge-kind permit check
    // rejects the reversed direction.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_touches.output_path, "\"kind\": \"target-owns-artifact\",\n      \"from\": \"target\",\n      \"to\": \"artifact:_boris/search/search-index.json\"", "\"kind\": \"target-owns-artifact\",\n      \"from\": \"artifact:_boris/search/search-index.json\",\n      \"to\": \"target\"");
            }
        }, error.InvalidTouchesReport);
    }

    // 10. touches.json node whose declared kind does not match its id: the
    // closed registry and metadata-shape validation rejects.
    {
        try expectEvidenceTamperRejected(tio, tgpa, &clean, clean_spec, struct {
            fn run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) anyerror!void {
                try replaceEvidenceBytes(io, gpa, dir, publication_touches.output_path, "\"kind\": \"claim\",\n      \"id\": \"claim:committed-artifacts-match-inventory\"", "\"kind\": \"check\",\n      \"id\": \"claim:committed-artifacts-match-inventory\"");
            }
        }, error.InvalidTouchesReport);
    }
}

fn proofPackAllocationCase(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    const gpa = allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const records = cleanRecords();
    var out = try runProofPack(io, gpa, tmp.dir, "target", "default", &records, cleanSpec(), .{});
    defer out.deinit(gpa);
}

test "full derivation is allocation-failure safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, proofPackAllocationCase, .{});
}
