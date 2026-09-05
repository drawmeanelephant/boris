//! `boris proof verify` — publication-check enforcement as a product command
//! (#840). Reads the committed checks report from a target's proof directory
//! and applies an explicit severity policy: error findings block by default,
//! warnings count and stay visible, and individual codes can be promoted to
//! blocking. Chrome-only: the target tree is never mutated.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const publication_touches = @import("publication_touches.zig");

pub const Policy = struct {
    /// Error findings above this cap fail the verification (default 0).
    max_errors: usize = 0,
    /// Warning findings above this cap fail the verification; null means
    /// warnings are counted and reported but never fatal.
    max_warnings: ?usize = null,
    /// Codes promoted to blocking regardless of severity.
    block_codes: []const []const u8 = &.{},
};

pub const Evaluation = struct {
    pass: bool,
    passed_checks: usize,
    not_applicable: usize,
    errors: usize,
    warnings: usize,
    info: usize,
    /// Human-readable policy violations, one per breached cap or blocked code.
    violations: []const []u8,
    /// The one-line checks verdict (the same composition the build prints).
    verdict: []u8,
};

/// Apply the policy to the parsed checks report. Pure: no I/O, no printing.
pub fn evaluatePolicy(
    gpa: std.mem.Allocator,
    checks: []const publication_touches.ParsedCheck,
    findings: []const publication_touches.ParsedFinding,
    policy: Policy,
) !Evaluation {
    var passed: usize = 0;
    var not_applicable: usize = 0;
    var errors: usize = 0;
    var warnings: usize = 0;
    var info: usize = 0;
    for (checks) |check| {
        if (std.mem.eql(u8, check.status, "passed")) {
            passed += 1;
            continue;
        }
        if (std.mem.eql(u8, check.status, "not-applicable")) {
            not_applicable += 1;
            continue;
        }
        for (findings[check.finding_offset..][0..check.counts_findings]) |f| {
            if (std.mem.eql(u8, f.severity, "error")) {
                errors += 1;
            } else if (std.mem.eql(u8, f.severity, "warning")) {
                warnings += 1;
            } else {
                info += 1;
            }
        }
    }

    var violations: std.ArrayList([]u8) = .empty;
    errdefer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    if (errors > policy.max_errors) {
        try violations.append(gpa, try std.fmt.allocPrint(
            gpa,
            "{d} error(s) exceed --max-errors {d}",
            .{ errors, policy.max_errors },
        ));
    }
    if (policy.max_warnings) |cap| {
        if (warnings > cap) {
            try violations.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{d} warning(s) exceed --max-warnings {d}",
                .{ warnings, cap },
            ));
        }
    }
    for (findings) |f| {
        var blocked = false;
        for (policy.block_codes) |code| {
            if (std.mem.eql(u8, f.code, code)) blocked = true;
        }
        if (!blocked) continue;
        // One violation per distinct blocked code, not per finding.
        var already = false;
        for (violations.items) |v| {
            if (std.mem.indexOf(u8, v, f.code) != null) already = true;
        }
        if (already) continue;
        try violations.append(gpa, try std.fmt.allocPrint(
            gpa,
            "blocked code {s} present ({s})",
            .{ f.code, f.severity },
        ));
    }

    const verdict = try publication_touches.formatChecksVerdict(gpa, checks, findings);
    const pass = violations.items.len == 0;
    return .{
        .pass = pass,
        .passed_checks = passed,
        .not_applicable = not_applicable,
        .errors = errors,
        .warnings = warnings,
        .info = info,
        .violations = try violations.toOwnedSlice(gpa),
        .verdict = verdict,
    };
}

pub fn deinitEvaluation(gpa: std.mem.Allocator, evaluation: *Evaluation) void {
    for (evaluation.violations) |v| gpa.free(v);
    gpa.free(evaluation.violations);
    gpa.free(evaluation.verdict);
}

// Verify one target's committed proof. Exit mapping per the CLI contract:
// success, content failure (policy exceeded), or I/O failure (proof report
// missing or unparsable — fail-closed: missing evidence never passes).
test "evaluatePolicy applies the severity policy (#840)" {
    const gpa = std.testing.allocator;
    const passed = publication_touches.ParsedCheck{ .id = "artifact-integrity", .eligible = true, .ran = true, .status = "passed", .coverage = "complete", .scope = undefined, .counts_eligible = 1, .counts_checked = 1, .counts_findings = 0, .finding_offset = 0 };
    const html_failed = publication_touches.ParsedCheck{ .id = "rendered-html", .eligible = true, .ran = true, .status = "failed", .coverage = "complete", .scope = undefined, .counts_eligible = 1, .counts_checked = 1, .counts_findings = 2, .finding_offset = 0 };
    const findings = [_]publication_touches.ParsedFinding{
        .{ .code = "HTML_FRAGMENT_MISSING", .severity = "error", .subject = .{ .kind = "page", .id = "index", .target = null } },
        .{ .code = "HTML_DUPLICATE_ID", .severity = "warning", .subject = .{ .kind = "page", .id = "index", .target = null } },
    };
    const checks = [_]publication_touches.ParsedCheck{ html_failed, passed, passed };

    // Default policy: the error finding blocks; the warning alone would not.
    var ev = try evaluatePolicy(gpa, &checks, &findings, .{});
    defer deinitEvaluation(gpa, &ev);
    try std.testing.expect(!ev.pass);
    try std.testing.expectEqual(@as(usize, 1), ev.errors);
    try std.testing.expectEqual(@as(usize, 1), ev.warnings);
    try std.testing.expectEqualStrings("1 error(s) exceed --max-errors 0", ev.violations[0]);

    // All-passed report passes under any cap.
    const all_passed = [_]publication_touches.ParsedCheck{ passed, passed, passed };
    var ev_ok = try evaluatePolicy(gpa, &all_passed, &.{}, .{ .max_warnings = 0 });
    defer deinitEvaluation(gpa, &ev_ok);
    try std.testing.expect(ev_ok.pass);

    // --max-warnings 0 promotes the warning to a violation.
    var ev_warn = try evaluatePolicy(gpa, &checks, &findings, .{ .max_warnings = 0 });
    defer deinitEvaluation(gpa, &ev_warn);
    try std.testing.expect(!ev_warn.pass);
    try std.testing.expectEqual(@as(usize, 2), ev_warn.violations.len);

    // --block-code promotes a warning-severity code by identity: with no
    // error findings, the blocked code is the only violation.
    const html_failed_warn = publication_touches.ParsedCheck{ .id = "rendered-html", .eligible = true, .ran = true, .status = "failed", .coverage = "complete", .scope = undefined, .counts_eligible = 1, .counts_checked = 1, .counts_findings = 1, .finding_offset = 0 };
    const warn_only = [_]publication_touches.ParsedFinding{.{ .code = "HTML_DUPLICATE_ID", .severity = "warning", .subject = .{ .kind = "page", .id = "index", .target = null } }};
    const warn_checks = [_]publication_touches.ParsedCheck{ html_failed_warn, passed, passed };
    var ev_block = try evaluatePolicy(gpa, &warn_checks, &warn_only, .{ .block_codes = &.{"HTML_DUPLICATE_ID"} });
    defer deinitEvaluation(gpa, &ev_block);
    try std.testing.expect(!ev_block.pass);
    try std.testing.expectEqual(@as(usize, 1), ev_block.violations.len);
    try std.testing.expect(std.mem.indexOf(u8, ev_block.violations[0], "HTML_DUPLICATE_ID") != null);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: cli.Options) cli.ExitCode {
    const dir = opts.proof_dir;
    const path = std.mem.concat(gpa, u8, &.{ dir, "/_boris/proof/checks.json" }) catch return .io_error;
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = publication_touches.readPayload(io, Io.Dir.cwd(), a, path) catch |err| {
        std.debug.print("error: cannot verify: {s} is not readable: {s}\n", .{ path, @errorName(err) });
        std.debug.print("remediation: build the target first, or pass --html-dir DIR for a target whose _boris/proof/ exists\n", .{});
        return .io_error;
    };
    // The report is target-bound: bind to the target name the committed
    // bytes declare, so any target's proof verifies without extra flags.
    var parsed_root = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch {
        std.debug.print("error: cannot verify: {s} is not a parsable checks report\n", .{path});
        return .io_error;
    };
    const target_name = if (parsed_root.value == .object)
        switch (parsed_root.value.object.get("target") orelse .null) {
            .string => |t| t,
            else => null,
        }
    else
        null;
    if (target_name == null) {
        std.debug.print("error: cannot verify: {s} has no target field\n", .{path});
        return .io_error;
    }
    var stream: std.Io.Reader = .fixed(bytes);
    const parsed = publication_touches.parseChecksStream(a, &stream, target_name.?) catch {
        std.debug.print("error: cannot verify: {s} is not a parsable checks report\n", .{path});
        return .io_error;
    };

    var evaluation = evaluatePolicy(
        gpa,
        &parsed.checks,
        parsed.findings,
        .{
            .max_errors = opts.proof_max_errors,
            .max_warnings = opts.proof_max_warnings,
            .block_codes = opts.proof_block_codes.items,
        },
    ) catch return .io_error;
    defer deinitEvaluation(gpa, &evaluation);

    if (!opts.quiet) {
        std.debug.print("boris proof verify: {s}\n", .{path});
        std.debug.print("  {s}\n", .{evaluation.verdict});
        for (evaluation.violations) |v| {
            std.debug.print("  policy: {s}\n", .{v});
        }
        std.debug.print("verdict: {s}\n", .{if (evaluation.pass) "pass" else "fail"});
    } else if (!evaluation.pass) {
        // A nonzero exit must always explain itself, even under --quiet.
        for (evaluation.violations) |v| {
            std.debug.print("policy: {s}\n", .{v});
        }
    }

    return if (evaluation.pass) .success else .content_error;
}
